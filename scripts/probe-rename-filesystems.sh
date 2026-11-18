#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || exit 2
base="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/js-filesystem-probe.XXXXXX")"
mount_path=""
image=""
owned_image_device() {
    hdiutil info -plist | python3 -c '
import os, plistlib, sys
images = plistlib.loads(sys.stdin.buffer.read()).get("images", [])
for item in images:
    if os.path.realpath(item.get("image-path", "")) == os.path.realpath(sys.argv[1]):
        entities = item.get("system-entities", [])
        if entities:
            print(entities[0].get("dev-entry", ""))
        break
' "$1"
}
detach_owned_image() {
    local selected_image="${1:-$image}"
    [[ -n "$selected_image" ]] || return 0
    local device
    device="$(owned_image_device "$selected_image")" || return 1
    if [[ -n "$device" ]]; then
        # Spotlight or the test runner can briefly retain a just-remounted
        # image. Retry, then force only this script's disposable image device.
        # Never apply this fallback to a physical or user-selected volume.
        if hdiutil detach "$device"; then return 0; fi
        sleep 2
        device="$(owned_image_device "$selected_image")" || return 1
        [[ -n "$device" ]] || return 0
        if hdiutil detach "$device"; then return 0; fi
        device="$(owned_image_device "$selected_image")" || return 1
        [[ -n "$device" ]] || return 0
        [[ "$selected_image" == "$base/"*.sparseimage && -f "$selected_image" && "$device" =~ ^/dev/disk[0-9]+$ ]] || return 1
        echo "Detaching busy disposable test image only: $selected_image ($device)"
        hdiutil detach -force "$device"
    fi
}
cleanup() {
    local owned
    for owned in "$base"/*.sparseimage; do
        [[ -f "$owned" ]] || continue
        detach_owned_image "$owned" || return
    done
    rm -rf "$base"
}
trap cleanup EXIT
mkdir -p .build
for fs in ExFAT APFS HFS+; do
    label="${fs//+/plus}"
    image="$base/$label.sparseimage"
    mount_path="$base/mount-$label"
    mkdir "$mount_path"
    echo "Creating disposable filesystem image: $fs"
    hdiutil create -size 2g -type SPARSE -layout GPTSPUD -fs "$fs" -volname "J-S-$label" "$image"
    hdiutil attach -nobrowse -mountpoint "$mount_path" "$image"
    diskutil info "$mount_path" | sed -n '/File System Personality/p;/Type (Bundle)/p;/Read-Only Volume/p'
    if [[ "$fs" == ExFAT ]]; then
        xcrun swift scripts/probe-copy-metadata.swift "$mount_path"
    fi
    xcrun swift scripts/probe-rename-filesystems.swift "$mount_path" ".build/filesystem-probe-$label.json"
    PHOTOSELECT_RENAME_TEST_VOLUME="$mount_path" PHOTOSELECT_RENAME_TEST_IMAGE="$image" \
        PHOTOSELECT_RENAME_TEST_REPORT="$PWD/.build/filesystem-integration-$label.json" \
        xcrun swift test --jobs 2 --parallel --num-workers 1 --filter FilesystemRenameTests \
        --xunit-output ".build/filesystem-$label-results.xml"
    python3 - ".build/filesystem-$label-results.xml" <<'PYTEST'
import sys, xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter('testcase'))
assert len(cases) == 12, len(cases)
assert not any(c.find(t) is not None for c in cases for t in ('failure', 'error', 'skipped'))
PYTEST
    peer_mount=""
    if [[ "$fs" == ExFAT ]]; then
        peer_image="$base/ExFAT-peer.sparseimage"
        peer_mount="$base/mount-ExFAT-peer"
        mkdir "$peer_mount"
        hdiutil create -size 2g -type SPARSE -layout GPTSPUD -fs ExFAT -volname "CopyPeer" "$peer_image"
        hdiutil attach -nobrowse -mountpoint "$peer_mount" "$peer_image"
    fi
    PHOTOSELECT_COPY_TEST_VOLUME="$mount_path" PHOTOSELECT_COPY_TEST_SECOND_EXFAT_VOLUME="$peer_mount" \
        xcrun swift test --jobs 2 --parallel --num-workers 1 --filter FileCopyTests \
        --xunit-output ".build/filecopy-$label-results.xml"
    python3 - ".build/filecopy-$label-results.xml" <<'PYCOPY'
import sys, xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter('testcase'))
assert len(cases) == 33, len(cases)
assert not any(c.find(t) is not None for c in cases for t in ('failure', 'error', 'skipped'))
names = {case.get('name', '').removesuffix('()') for case in cases}
assert 'testPhotosAndFolderTreesPreserveMetadataAndContentAcrossVolumes' in names
print('Verified 33 file copy checks against the mounted target volume, including reverse copy')
PYCOPY
    if [[ "$fs" == ExFAT ]]; then
        echo 'Verified photo and folder copies from APFS to ExFAT, ExFAT to APFS, and between distinct ExFAT images.'
        detach_owned_image "$peer_image"
    fi
    recovery="$PWD/.build/filesystem-recovery-$label.json"
    if [[ -f "$recovery" ]]; then
        detach_owned_image
        hdiutil attach -nobrowse -mountpoint "$mount_path" "$image"
        PHOTOSELECT_RENAME_TEST_VOLUME="$mount_path" PHOTOSELECT_RENAME_RECOVERY_RECEIPT="$recovery" \
            xcrun swift test --jobs 2 --parallel --num-workers 1 --filter FilesystemRenameTests.testVolumeContentIdentityRecovery \
            --xunit-output ".build/filesystem-recovery-$label-results.xml"
        python3 - "$recovery" ".build/filesystem-recovery-$label-results.xml" <<'PYRECOVERY'
import json, sys, xml.etree.ElementTree as ET
report = json.load(open(sys.argv[1]))
assert report['recoveredAfterReconnect'] and report['originalNamesBytesAndTagsPreserved']
cases = list(ET.parse(sys.argv[2]).getroot().iter('testcase'))
assert len(cases) == 1
assert not any(c.find(t) is not None for c in cases for t in ('failure', 'error', 'skipped'))
PYRECOVERY
    fi
    python3 - ".build/filesystem-integration-$label.json" ".build/filesystem-real14-$label.json" <<'PYRENAMED'
import json, sys
for path in sys.argv[1:]:
    report = json.load(open(path))
    assert report['allRenamed'] is True, 'This run requires successful renames, not a safe stop'
PYRENAMED
    receipt="$PWD/.build/filesystem-remount-$label.json"
    if [[ -f "$receipt" ]]; then
        # No XCTest worker may hold the exFAT image open during this check.
        # The receipt identifies the originals from the application's safe-stop
        # test, which deliberately keeps its fixture folder until this step.
        detach_owned_image
        hdiutil attach -nobrowse -mountpoint "$mount_path" "$image"
        python3 - "$receipt" "$mount_path" <<'PYREMOUNT'
import json, os, pathlib, sys
receipt = pathlib.Path(sys.argv[1])
report = json.loads(receipt.read_text())
mount = pathlib.Path(sys.argv[2]).resolve()
folder = pathlib.Path(report['folder']).resolve()
assert folder != mount and os.path.commonpath([folder, mount]) == str(mount)
assert folder.name.startswith('J-S-filesystem-test-')
assert report['files'] == ['A.ARW', 'B.JPG']
assert report['successfulRename'] is False
for name in report['files']:
    assert (folder / name).read_bytes() == name.encode('utf-8'), name
report.update(reconnected=True, originalNamesAndBytesPreserved=True)
receipt.write_text(json.dumps(report, indent=2) + '\n')
print('Verified originals from unsupported-volume app transaction after process exit and image reconnect')
PYREMOUNT
    fi
    detach_owned_image
    mount_path=""
    image=""
done
