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
    hdiutil detach "$mount_path"
    mount_path=""
done

# Diagnostic-only gate: do not publish a patch installer before a safe strategy is implemented.
echo 'Filesystem probes finished; compatibility implementation is pending.' >&2
exit 3
