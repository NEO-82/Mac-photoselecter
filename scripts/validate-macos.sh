#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'macOS 13+ 및 Xcode가 필요합니다. Linux에서는 AppKit 빌드/테스트를 실행할 수 없습니다.' >&2
    exit 2
fi
xcodebuild -version
xcodebuild -project PhotoSelect.xcodeproj -scheme PhotoSelect -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build
swift test --parallel --jobs 2
