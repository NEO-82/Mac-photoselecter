# J♡S v0.5.4

공식 표시 이름은 **J♡S** (Jeonggwang ♡ Seoa)입니다. 하트는 U+2661 `♡`이며, 하단 크레딧 `Made with Seoa ♡`와 공식 커플 사진 아이콘은 유지합니다.

Finder/Dock의 번들 이름은 `J♡S.app`, Info.plist의 CFBundleName/CFBundleDisplayName과 Xcode PRODUCT_NAME은 `J♡S`입니다. 메뉴, About, 메인 창과 사진 창의 앱 이름 부분은 같은 AppBranding 표시 이름을 사용합니다. 배포 파일은 영문 이름 `J-S-0.5.4-arm64.dmg`입니다.

실행 파일 `PhotoSelect`, Swift 모듈/프로젝트/소스 디렉터리는 그대로입니다. Bundle Identifier `dev.photoselect.app`, 태그 경로 `~/Library/Application Support/dev.photoselect.app/tags.json`, version 1 JSON, UserDefaults 키와 저장 도메인, 파일 접근 방식은 변경하지 않았습니다. App.swift의 실행 코드 변경은 표시 이름 상수 한 곳뿐이며 태그·필터·뷰어·파일 접근·이미지 처리 구현 파일은 v0.5.3과 바이트 단위로 동일합니다. 추가 테스트는 v0.5.3 형식의 JSON을 읽은 뒤 원본 데이터가 바뀌지 않았는지 확인합니다. 기존 태그 복원 및 필터 통합 테스트도 계속 실행합니다.

## 기존 앱 교체

1. 기존 `정광이의 MAC 포토셀렉터.app`, `PhotoSelect.app`, J♡S를 모두 종료하여 대기 중 태그 저장을 마칩니다.
2. DMG의 **J♡S.app**을 Applications에 넣습니다. 표시 이름이 달라 기존 앱이 자동 교체되지 않을 수 있습니다.
3. 이전 이름의 **앱 번들만** 휴지통으로 옮깁니다. Dock의 이전 바로가기를 제거하고 Applications의 J♡S를 다시 등록합니다. 두 앱을 동시에 실행하지 않습니다.
4. `~/Library/Application Support/dev.photoselect.app` 및 사용자 설정은 삭제하지 않습니다. 앱 정리 도구로 관련 데이터를 함께 삭제하지 않습니다.

기존 [v0.5.3 DMG](../downloads/PhotoSelect-0.5.3-arm64.dmg)는 바이트 단위로 보존했습니다. [빌드 40 검증 기록](../downloads/v0.5.3-build40/)도 별도로 보존했습니다. 원본 검증 기록과 설치 파일은 기존 불변 커밋으로도 계속 확인할 수 있습니다.

## 변경 파일

- `Sources/PhotoSelect/App.swift`: 표시 이름 상수.
- `Resources/Info.plist`, Xcode 프로젝트 및 공유 스킴: 번들 표시 이름, 제품 이름, 버전 0.5.4. Bundle Identifier/실행 파일/모듈은 유지.
- `scripts/package-macos.sh`, `scripts/publish-installer-result.sh`, `.github/workflows/package-macos.yml`: 새 번들·영문 DMG 이름, 설치 안내, 버전별 체크섬.
- `scripts/test-packaging.py`, `scripts/verify-app-icon.swift`, `Tests/PhotoSelectTests/PhotoActionsTests.swift`: 이름·아이콘·호환성 검증.
- README, 설치·검증 문서 및 이전 배포 기록 보존 디렉터리.

실제 Apple Silicon Mac 설치 실행과 Dock/물리 입력/외장장치 동작 확인은 별도입니다. macOS CI는 Intel 러너에서 테스트하고 arm64 앱을 교차 빌드합니다. 설치 파일은 개인 테스트용 ad-hoc 서명이며 Developer ID 서명/Apple 공증은 포함하지 않습니다.

## 최종 검증 결과

[macOS 빌드 #41](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43370039453) — 소스 `e63baf308acc4b1e0791e76418073177bd31f7de`.

- XCTest **89개**: 실패·오류·건너뜀 없음. v0.5.3 JSON 읽기/불변성, 태그 저장·복원, 태그 필터 ON/OFF·뷰어·삭제·1,500장 검사 포함.
- Release Sony ARW 회귀 검사 **3개** 통과.
- Xcode arm64 Release 빌드, ad-hoc 서명, DMG 무결성·읽기 전용 마운트·내부 앱 서명 검증 통과.
- 마운트된 `J♡S.app`의 CFBundleName/DisplayName **J♡S**, Bundle Identifier **dev.photoselect.app**, 실행 파일 **PhotoSelect** 확인.
- 기존 공식 아이콘의 SHA-256 동일, ICNS 10종 및 원본 일치 검사 통과.
- Linux 패키징 제어 흐름 검사 **9개**, Bash 구문 및 diff 검사 통과. Linux 검사는 실제 macOS 검증을 대체하지 않음.

[새 DMG 다운로드](https://github.com/NEO-82/Mac-photoselecter/raw/fd38fcee8e317824ac81ec2f6e7aa19ad8e6e266/downloads/J-S-0.5.4-arm64.dmg) · [체크섬](https://github.com/NEO-82/Mac-photoselecter/raw/fd38fcee8e317824ac81ec2f6e7aa19ad8e6e266/downloads/SHA256SUMS-0.5.4)

실제 다운로드 HTTP **200**, **3,797,693바이트**, SHA-256 일치:

```text
0f3e7791054f2ba5717b0b4c07ce1e4d40e0430e83ffd7241ce6a5fa54896ce5  J-S-0.5.4-arm64.dmg
```

[다운로드 검증 JSON](../downloads/download-verification-0.5.4.json), [번들 이름·아이콘 검사](../downloads/icon-validation.json), [XCTest](../downloads/xctest-results.xml), [Release RAW 검사](../downloads/release-preview-results.xml), [빌드 로그](../downloads/build.log).

About UI 테스트에서도 **J♡S**와 기존 `Made with Seoa ♡` 크레딧을 확인했습니다. 테스트 호스트의 About 캡처는 배포 앱의 버전·아이콘 증거로 사용하지 않으며, 설치 번들의 이름·버전·아이콘 검증은 위 `icon-validation.json`을 기준으로 합니다.
