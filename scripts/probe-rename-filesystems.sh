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
' "$image"
}
detach_owned_image() {
    [[ -n "$image" ]] || return 0
    local device
    device="$(owned_image_device)" || return 1
    if [[ -n "$device" ]]; then
        # Spotlight or the test runner can briefly retain a just-remounted
        # image. Retry, then force only this script's disposable image device.
        # Never apply this fallback to a physical or user-selected volume.
        if hdiutil detach "$device"; then return 0; fi
        sleep 2
        device="$(owned_image_device)" || return 1
        [[ -n "$device" ]] || return 0
        if hdiutil detach "$device"; then return 0; fi
        device="$(owned_image_device)" || return 1
        [[ -n "$device" ]] || return 0
        [[ "$image" == "$base/"*.sparseimage && -f "$image" && "$device" =~ ^/dev/disk[0-9]+$ ]] || return 1
        echo "Detaching busy disposable test image only: $image ($device)"
        hdiutil detach -force "$device"
    fi
}
cleanup() {
    local owned
    for owned in "$base"/*.sparseimage; do
        [[ -f "$owned" ]] || continue
        image="$owned"
        detach_owned_image || return
    done
    rm -rf "$base"
}
trap cleanup EXIT
mkdir -p .build
for fs in APFS HFS+ ExFAT; do
    label="${fs//+/plus}"
    image="$base/$label.sparseimage"
    mount_path="$base/mount-$label"
    mkdir "$mount_path"
    echo "Creating disposable filesystem image: $fs"
    hdiutil create -size 256m -type SPARSE -layout GPTSPUD -fs "$fs" -volname "J-S-$label" "$image"
    hdiutil attach -nobrowse -mountpoint "$mount_path" "$image"
    diskutil info "$mount_path" | sed -n '/File System Personality/p;/Type (Bundle)/p;/Read-Only Volume/p'
    xcrun swift scripts/probe-rename-filesystems.swift "$mount_path" ".build/filesystem-probe-$label.json"
    PHOTOSELECT_RENAME_TEST_VOLUME="$mount_path" PHOTOSELECT_RENAME_TEST_IMAGE="$image" \
        PHOTOSELECT_RENAME_TEST_REPORT="$PWD/.build/filesystem-integration-$label.json" \
        xcrun swift test --jobs 2 --parallel --num-workers 1 --filter FilesystemRenameTests \
        --xunit-output ".build/filesystem-$label-results.xml"
    python3 - ".build/filesystem-$label-results.xml" <<'PYTEST'
import sys, xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter('testcase'))
assert len(cases) == 7, len(cases)
assert not any(c.find(t) is not None for c in cases for t in ('failure', 'error', 'skipped'))
PYTEST
    detach_owned_image
    mount_path=""
    image=""
done
