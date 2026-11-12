#!/bin/bash
# Public regression media permission and pinned origins: docs/stable-preview.md.
set -euo pipefail
sample_dir="${PHOTOSELECT_ARW_SAMPLE_DIRECTORY:-${TMPDIR:-/tmp}/photoselect-raw-samples}"
mkdir -p "$sample_dir"
fetch() {
    local name="$1" checksum="$2" url="$3" target="$sample_dir/$1"
    if [[ -f "$target" ]] && printf '%s  %s\n' "$checksum" "$target" | shasum -a 256 -c - >/dev/null 2>&1; then
        return
    fi
    curl -fLsS --retry 2 --connect-timeout 20 --max-time 180 "$url" -o "$target.partial"
    printf '%s  %s\n' "$checksum" "$target.partial" | shasum -a 256 -c -
    mv "$target.partial" "$target"
}
fetch 'Sony-A7M3.arw' '87a502c37ea76d1128aa5773356142951a2249f9797e1ddad4d817d42cf5cc15' \
    'https://raw.githubusercontent.com/drewnoakes/metadata-extractor-images/7b56b649039c57903bcd5cbe9846ab81eb518ec4/arw/Sony%20ILCE-7M3%20(A7M3).arw'
fetch 'Sony-A7M4.ARW' '9b01e699daab4cd2a457c7e6fec206d4d907e9cbfc3464944dca38b547cb086f' \
    'https://raw.githubusercontent.com/drewnoakes/metadata-extractor-images/7b56b649039c57903bcd5cbe9846ab81eb518ec4/arw/Sony%20ILCE-7M4%20(A7M4).ARW'
