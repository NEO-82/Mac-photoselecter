# macOS 설치 파일

## 전달 원칙

기능 개선 작업의 최종 결과는 Apple Silicon용 `.dmg`로 빌드하고 이 저장소의 `downloads/`에 업로드한다. 소스 또는 빌드 스크립트만 제공한 상태를 완성본으로 표시하지 않는다. macOS XCTest, Release arm64 빌드, 앱 서명 및 DMG 무결성 검증을 통과한 뒤 실제 다운로드와 SHA-256 일치까지 확인하고 링크를 제공한다. 빌드 실패 시 원인을 수정하고 재실행하며, 이전 버전 파일을 새 변경분의 결과로 안내하지 않는다.

## 현재 상태

현재 배포는 **J♡S v0.5.4 빌드 41**입니다. [최신 DMG·교체 안내·검증 기록](js-branding.md)을 참고하세요. 아래 0.5.3/0.5.2 기록과 설치 파일은 보존했습니다.

0.5.3 빌드 40의 태그 필터 설치 파일과 XCTest 88개·Release RAW 3개·서명·DMG·다운로드 검증은 [최종 0.5.3 검증 기록](tagged-filter.md#최종-검증과-설치-파일)을 참고하세요.

## 이전 0.5.2 검증 기록

0.5.2 빌드 32를 GitHub의 Intel macOS 러너(Xcode 16.4)에서 생성했습니다.
[빌드 실행 #32](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43230004616)에서 XCTest **86개**와 Release Sony RAW 검사 **3개**가 실패·건너뜀 없이 통과했습니다.
arm64 전용 Release 앱 빌드, 앱 이름·공식 아이콘, ad-hoc 서명, DMG 무결성, 읽기 전용 마운트 후 앱 서명 검증도 통과했습니다.

[설치용 DMG 다운로드](https://github.com/NEO-82/Mac-photoselecter/raw/e08e654d8253176f71d68a2555024a4ac911c60c/downloads/PhotoSelect-0.5.2-arm64.dmg)

실제 다운로드 HTTP **200**, **3,790,026바이트**, SHA-256 일치를 확인했습니다.

```text
98d00a6be0a4ffd91f477b5a91cb0bb69dc5e30b7e1e20146d43a24859d912b9  PhotoSelect-0.5.2-arm64.dmg
```

설치 파일과 [SHA256SUMS](https://github.com/NEO-82/Mac-photoselecter/blob/e08e654d8253176f71d68a2555024a4ac911c60c/downloads/SHA256SUMS)는 같은 불변 커밋을 참조합니다.
[UI 화면·파일별 테스트 결과·클라우드 API 접근 진단](finder-browser.md)과 [다운로드 검증 기록](../downloads/download-verification-0.5.2.json)을 참고하세요.

`PhotoSelect-Mac-BuildKit.zip`이 제공된 경우 소스와 아래 스크립트만 들어 있는 빌드 묶음입니다.
완성된 `.app` 또는 `.dmg`로 오인하지 마세요.

## 가장 간단한 생성 방법

1. M1 이상 Mac에 Xcode 15 이상을 설치하고 한 번 실행해 초기 설정을 완료합니다.
2. 소스 묶음을 압축 해제하고 `설치파일-만들기.command`를 더블클릭합니다.
   터미널에서 실행할 경우 저장소 디렉터리로 이동해 `bash scripts/package-macos.sh`를 실행합니다.
3. XCTest 및 Release 빌드가 성공하면 `dist` 폴더가 열립니다.
4. `J-S-0.5.4-1-arm64` 안의 `.dmg`를 열고 `J♡S.app`을 `Applications`로 끌어 넣습니다.
5. 디스크 이미지를 추출한 뒤 응용 프로그램 폴더에서 앱을 실행합니다.

완성된 앱의 실행 요건은 M1 이상, macOS 13 이상입니다. 앱 실행에는 Xcode나 Swift 설치가 필요하지 않습니다.
창·메뉴·Finder의 앱 이름은 `J♡S`이며, `Resources/AppIcon.png`의 사용자 제공 공식 사진 아이콘을 사용합니다.
Xcode의 `Build App Icon` 단계가 macOS `sips`/`iconutil`로 모든 크기를 만들고, 패키징 시 표시 이름과 ICNS 포함을 검증합니다.
기존 `PhotoSelect.app`을 사용 중이면 종료한 뒤 이전 앱을 휴지통으로 옮기고 새 이름의 앱을 설치하세요.
앱 제거는 앱을 종료한 후 응용 프로그램 폴더의 `J♡S.app`을 휴지통으로 옮기면 됩니다.
앱 설치/제거는 사진 파일을 수정하지 않습니다. 관리자 권한으로 실행하는 설치 스크립트는 사용하지 않습니다.

Xcode Command Line Tools만으로는 충분하지 않습니다. 여러 Xcode가 설치되어 있다면 Xcode Settings의
Locations → Command Line Tools에서 사용할 Xcode를 선택하세요.

## 결과물과 재실행

기본 결과물:

```text
dist/J-S-0.5.4-1-arm64/
  J-S-0.5.4-1-arm64.dmg
  SHA256SUMS
```

같은 버전/빌드 번호의 기존 결과물을 덮어쓰지 않습니다. 새로 빌드할 때 번호를 늘릴 수 있습니다.

```bash
PHOTOSELECT_VERSION=0.5.4 PHOTOSELECT_BUILD_NUMBER=2 bash scripts/package-macos.sh
```

DMG가 들어 있는 디렉터리에서 `shasum -a 256 -c SHA256SUMS`로 파일 전송 후 무결성을 확인할 수 있습니다.
체크섬은 파일 변경 감지용이며 배포자 신원을 보증하지 않습니다.

스크립트는 테스트·빌드·서명·arm64 확인·DMG 무결성 확인·읽기 전용 마운트·내부 앱 서명 검증을 수행합니다.
중간 단계 실패 시 최종 결과물을 저장하지 않습니다. 임시 빌드와 마운트는 종료 시 정리합니다.
강제 종료 등으로 `.build/package.lock`이 남았다면 다른 빌드가 실행 중이지 않은지 확인한 후 빈 잠금 폴더를 지우고 다시 실행합니다.
DMG 분리에 실패하면 해당 마운트 경로와 작업 폴더를 보존하고 오류를 표시합니다.

## 서명 범위

기본값은 Apple Silicon 앱의 로컬 실행을 위한 **ad-hoc 서명**입니다.
Apple Developer ID 서명, Hardened Runtime 기반 공증 제출, Apple 공증 티켓은 포함하지 않습니다.
이는 개인 테스트용 빌드이며 일반 배포용 공증 앱과 다릅니다.

다운로드한 앱이 Gatekeeper에 차단되면 출처를 확인한 경우에만 macOS 시스템 설정 → 개인정보 보호 및 보안의
**확인 없이 열기** 안내를 따르세요. 시스템 보안 설정 전체를 끄는 절차는 사용하지 않습니다.
여러 사용자에게 일반 배포하려면 별도 Developer ID 인증서와 Apple 공증 구성이 필요합니다.

## GitHub에서 생성

소스와 `.github/workflows/package-macos.yml`을 GitHub 저장소에 반영한 뒤:

1. Actions → **Build macOS installer** → Run workflow에서 버전을 입력합니다.
2. macOS 러너에서 테스트·빌드·패키징이 완료될 때까지 기다립니다.
3. 실행 결과의 Artifacts에서 `PhotoSelect-<버전>-arm64`를 내려받습니다.
4. 압축을 해제한 후 내부 `.dmg`를 사용합니다.

워크플로는 수동 실행하거나 `codex/macos-installer-download` 전달용 브랜치의 소스를 push하면 실행합니다.
전달용 브랜치에서는 빌드 로그/결과와 성공한 DMG를 `downloads/`에 저장하므로 작업에 저장소 쓰기 권한을 사용합니다.
`downloads/` 변경만으로는 재실행되지 않으며 GitHub Release를 게시하지 않습니다.
GitHub Actions 사용 가능 여부와 이용 한도는 해당 저장소 설정에 따릅니다.
빌드 성공 여부는 해당 실행 로그와 `downloads/build-status.json`을 확인하세요.

## 여기서 확인한 범위

- Bash 구문과 수동 GitHub Actions 워크플로 구조 검사.
- `python3 scripts/test-packaging.py`로 패키징 제어 흐름 테스트 9개 통과.
  테스트 도구 대역을 사용하며 실제 macOS 빌드·서명·DMG 검증이 아닙니다.
- 테스트 실패/빌드 실패/잘못된 CPU 아키텍처/DMG 검증 실패/마운트 후 서명 실패 때 결과물을 저장하지 않는지,
  임시 마운트를 정리하는지, 기존 결과물을 보존하는지 확인합니다.

앱 기능과 실제 설치 후 동작 확인은 [검증 체크리스트](validation.md)를 따릅니다.

## J♡S로 교체

기존 정광이의 MAC 포토셀렉터.app, PhotoSelect.app 및 J♡S를 종료하고 J♡S.app을 Applications에 설치하세요. 이전 이름의 앱은 자동 교체되지 않을 수 있습니다. 이전 **앱 번들만** 휴지통으로 옮기고 Dock 항목을 새 앱으로 등록하세요. `dev.photoselect.app` 식별자, Application Support의 tags.json, 사용자 설정은 그대로 사용하므로 관련 데이터를 삭제하거나 앱 정리 도구로 제거하지 마세요.
