#!/bin/bash
# Build on macOS using Xcode; output is an ad-hoc-signed personal test build.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_dir"
app_name='정광이의 MAC 포토셀렉터'

if [[ "$(uname -s)" != Darwin ]]; then
    echo '설치 파일 생성에는 macOS와 Xcode 15 이상이 필요합니다. Linux에서는 생성할 수 없습니다.' >&2
    exit 2
fi

version="${PHOTOSELECT_VERSION:-0.1.0}"
build_number="${PHOTOSELECT_BUILD_NUMBER:-1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo '버전은 0.1.0 형태, 빌드 번호는 양의 정수를 사용하세요.' >&2
    exit 2
fi

for tool in xcodebuild xcrun codesign ditto hdiutil shasum plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "필수 도구를 찾을 수 없습니다: $tool (Xcode를 설치하고 최초 실행을 완료하세요)." >&2
        exit 2
    fi
done
xcodebuild -version
xcrun --find swift >/dev/null
xcrun --find lipo >/dev/null

artifact_name="PhotoSelect-${version}-${build_number}-arm64"
output_dir="$repo_dir/dist/$artifact_name"
if [[ -e "$output_dir" ]]; then
    echo "기존 결과물을 보존합니다: $output_dir" >&2
    echo '다시 만들려면 PHOTOSELECT_BUILD_NUMBER를 늘리거나 기존 결과물을 옮겨 주세요.' >&2
    exit 2
fi

mkdir -p "$repo_dir/.build" "$repo_dir/dist"
# The lock protects output publication and concurrent invocations from Finder.
lock_dir="$repo_dir/.build/package.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "다른 패키징 작업이 실행 중이거나 중단된 잠금이 남아 있습니다: $lock_dir" >&2
    exit 2
fi
work_dir=''
mounted=0
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$mounted" -eq 1 ]]; then
        if ! hdiutil detach "$work_dir/mount"; then
            echo "설치 이미지 분리 실패: $work_dir/mount — 이 작업 폴더를 보존합니다." >&2
            rmdir "$lock_dir" || true
            exit 1
        fi
    fi
    if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi
    rmdir "$lock_dir" || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Recheck under the lock so another completed invocation cannot be overwritten.
if [[ -e "$output_dir" ]]; then
    echo "기존 결과물을 보존합니다: $output_dir" >&2
    exit 2
fi
work_dir="$(mktemp -d "$repo_dir/.build/package.XXXXXXXX")"
mkdir -p "$work_dir/image" "$work_dir/artifacts" "$work_dir/mount"

echo '1/5 XCTest 실행'
xcrun swift test --parallel --jobs 2

echo '2/5 Apple Silicon Release 앱 빌드'
xcodebuild -project PhotoSelect.xcodeproj -scheme PhotoSelect -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work_dir/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" build

app_path="$work_dir/image/$app_name.app"
ditto "$work_dir/DerivedData/Build/Products/Release/$app_name.app" "$app_path"
binary_path="$app_path/Contents/MacOS/PhotoSelect"
if [[ ! -x "$binary_path" ]] || [[ ! -s "$app_path/Contents/Info.plist" ]]; then
    echo '빌드된 앱 번들의 실행 파일 또는 Info.plist가 없습니다.' >&2
    exit 1
fi
if [[ "$(xcrun lipo -archs "$binary_path")" != arm64 ]]; then
    echo 'arm64 전용 실행 파일이 아닙니다. 설치 이미지 생성을 중단합니다.' >&2
    exit 1
fi
for name_key in CFBundleName CFBundleDisplayName; do
    if [[ "$(plutil -extract "$name_key" raw -o - "$app_path/Contents/Info.plist")" != "$app_name" ]]; then
        echo "앱 표시 이름 검증 실패: $name_key" >&2
        exit 1
    fi
done
if [[ "$(plutil -extract CFBundleIconFile raw -o - "$app_path/Contents/Info.plist")" != AppIcon.icns ]] \
    || [[ ! -s "$app_path/Contents/Resources/AppIcon.icns" ]] \
    || [[ "$(head -c 4 "$app_path/Contents/Resources/AppIcon.icns")" != icns ]]; then
    echo '앱 아이콘 누락 또는 잘못된 ICNS 파일입니다.' >&2
    exit 1
fi
echo "앱 이름 및 골든리트리버 아이콘 확인: $app_name"

echo '3/5 로컬 테스트용 앱 서명 및 검증'
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --strict --verbose=2 "$app_path"
ln -s /Applications "$work_dir/image/Applications"
cat > "$work_dir/image/설치 안내.txt" <<'INSTALL'
정광이의 MAC 포토셀렉터 — Apple Silicon용 개인 테스트 빌드

요구 사항: M1 이상 Mac, macOS 13 이상. 설치 후 실행에는 Xcode가 필요하지 않습니다.

설치: 정광이의 MAC 포토셀렉터.app을 Applications 폴더로 끌어 넣은 뒤 디스크 이미지를 추출하세요.
제거: 앱을 종료한 뒤 응용 프로그램 폴더의 정광이의 MAC 포토셀렉터.app을 휴지통으로 옮기세요.
이전 PhotoSelect.app이 설치돼 있으면 종료한 뒤 이전 앱을 휴지통으로 옮기고 새 이름의 앱을 넣으세요.
사진 파일은 앱 설치/제거 과정에서 변경하지 않습니다.

이 빌드는 로컬 ad-hoc 서명이며 Apple Developer ID 서명 및 공증은 포함하지 않습니다.
다운로드한 앱은 Gatekeeper에 의해 차단될 수 있습니다. 출처를 확인한 경우 macOS
시스템 설정 > 개인정보 보호 및 보안의 '확인 없이 열기' 안내를 따르세요.
일반 사용자에게 경고 없이 배포하려면 Developer ID 서명 및 Apple 공증이 별도로 필요합니다.

사진 폴더를 선택하고 썸네일을 더블클릭하세요.
←/→ 사진 탐색, 마우스 왼쪽 버튼을 누르는 동안 100% 확대, 놓으면 복귀, Esc 목록 복귀.
실제 ARW 호환성 및 성능은 아직 실기기 검증이 필요합니다.
INSTALL

echo '4/5 DMG 생성 및 내부 앱 검증'
dmg_path="$work_dir/artifacts/$artifact_name.dmg"
hdiutil create -volname "$app_name" -srcfolder "$work_dir/image" -fs HFS+ -format UDZO "$dmg_path"
hdiutil verify "$dmg_path"
hdiutil attach -readonly -nobrowse -mountpoint "$work_dir/mount" "$dmg_path"
mounted=1
codesign --verify --strict --verbose=2 "$work_dir/mount/$app_name.app"
if [[ "$(readlink "$work_dir/mount/Applications")" != /Applications ]]; then
    echo '설치 이미지의 Applications 링크가 올바르지 않습니다.' >&2
    exit 1
fi
hdiutil detach "$work_dir/mount"
mounted=0

echo '5/5 체크섬 생성 및 결과 저장'
(
    cd "$work_dir/artifacts"
    shasum -a 256 "$artifact_name.dmg" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
mv "$work_dir/artifacts" "$output_dir"
echo "완료: $output_dir/$artifact_name.dmg"
echo "설치 이미지를 열고 $app_name.app을 Applications로 끌어 넣으세요."
echo '이 결과물은 Developer ID 서명 및 Apple 공증이 없는 개인 테스트용입니다.'
