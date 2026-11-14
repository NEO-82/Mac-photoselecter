#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || exit 2
base="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/js-filesystem-probe.XXXXXX")"
mount_path=""
cleanup() {
    if [[ -n "$mount_path" ]]; then hdiutil detach "$mount_path" || return; fi
    rm -rf "$base"
}
trap cleanup EXIT
mkdir -p .build
for fs in APFS HFS+ ExFAT; do
    label="${fs//+/plus}"
    image="$base/$label.sparseimage"
    mount_path="$base/mount-$label"
    mkdir "$mount_path"
    hdiutil create -quiet -size 256m -type SPARSE -layout GPTSPUD -fs "$fs" -volname "J-S-$label" "$image"
    hdiutil attach -nobrowse -mountpoint "$mount_path" "$image"
    diskutil info "$mount_path" | sed -n '/File System Personality/p;/Type (Bundle)/p;/Read-Only Volume/p'
    xcrun swift scripts/probe-rename-filesystems.swift "$mount_path" ".build/filesystem-probe-$label.json"
    PHOTOSELECT_RENAME_TEST_VOLUME="$mount_path" PHOTOSELECT_RENAME_TEST_IMAGE="$image" \
        PHOTOSELECT_RENAME_TEST_REPORT="$PWD/.build/filesystem-integration-$label.json" \
        xcrun swift test --jobs 2 --filter FilesystemRenameTests \
        --xunit-output ".build/filesystem-$label-results.xml"
    python3 - ".build/filesystem-$label-results.xml" <<'PYTEST'
import sys, xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter('testcase'))
assert len(cases) == 6, len(cases)
assert not any(c.find(t) is not None for c in cases for t in ('failure', 'error', 'skipped'))
PYTEST
    hdiutil detach "$mount_path"
    mount_path=""
done
