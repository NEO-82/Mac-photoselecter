# 공식 앱 아이콘 적용 — 0.5.1

사용자가 제공한 `MacPhotoSelect_AppIcon_1024.zip`의 `MacPhotoSelect_AppIcon_1024.png`를 `Resources/AppIcon.png`로 그대로 복사했다. 재생성·크롭·색상/배경 변경은 하지 않았다.

- 원본/적용 PNG: 1024×1024 RGB, 1,610,721바이트.
- SHA-256: `f958eb4d4223c4c74b3684cbc9566bd25efadc77dcacdeecdbcc8e8e665b063f`.
- 원본에는 알파 채널이 없으며 제공한 테두리와 검은 모서리 배경도 보존했다.
- 수정 전 기준: `3be10231cd738d10791e07edb338afcd60215128`.
- 복구 체크포인트: `/workspace/checkpoints/photoselect-before-official-icon.bundle` (검증 완료).

## 변경 범위

`Sources/`, `Tests/`, `Resources/Info.plist`, `scripts/build-app-icon.sh`는 변경하지 않았다. 뷰어 기능·UI·앱 이름은 동일하다.
Xcode 프로젝트는 출시 버전 메타데이터만0.5.1로 갱신했으며, 기존 아이콘 빌드 단계의 입력/출력/실행 스크립트 구조는 유지했다.

기존 `build-app-icon.sh`가 PNG에서16–1024픽셀 아이콘을 생성하고 `iconutil`로 `AppIcon.icns`를 만든다. 앱 번들의 `CFBundleIconFile=AppIcon.icns`를 계속 사용하므로 Finder/Dock의 표준 아이콘 등록 경로를 유지한다. 기존 스크립트의 출력 문구에 남은 골든리트리버 명칭은 옛 로그 문구이며 실제 아트워크는 위 해시로 구분한다.

## 검증

추가한 `scripts/verify-app-icon.swift`는 앱 대상에 포함되지 않는 빌드 검증 도구다. 패키징된 DMG를 읽기 전용으로 마운트해 앱 번들의 아이콘 등록, ICNS의10개 기본/Retina 이미지(16–1024픽셀), 원본과 최대 이미지의 일치를 검사한다. macOS `NSWorkspace.icon(forFile:)`가 해석한 Finder 아이콘도 PNG로 저장한다.

[macOS 빌드 #27](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43147070222), 소스 `0c9505dc85750b9c23700600c5fde915bc7677f0`에서 다음을 확인했다.

- 회귀 XCTest85개, 최적화 실제 ARW 검사3개 통과. 기존 `Sources/`와 `Tests/` 파일의 수정은 없다.
- arm64 Release 앱 빌드, 앱 ad-hoc 서명과 DMG 무결성 검증 통과.
- 패키징된 앱의 `CFBundleIconFile=AppIcon.icns`와10개 기본/Retina 이미지 크기 확인.
- ICNS에서 추출한1024px 이미지와 원본을 같은 sRGB 비트맵으로 비교한 평균RGB 차이는0으로 픽셀 일치.
- CI에서 읽은 원본 PNG의 SHA-256이 ZIP에서 꺼낸 파일과 동일함을 확인.
- `NSWorkspace.icon(forFile:)`가 새 사진 이미지를 해석함을 확인하고 [Finder 이미지](../downloads/finder-icon.png)를 저장했다. Intel 호스트는 arm64 전용 앱을 실행할 수 없어 실행 제한 배지가 사진 위에 겹쳐 있다. 이 배지는 ICNS 원본에 들어 있지 않다. Apple Silicon Dock 실화면 검증으로 취급하지 않는다.

검증 데이터: [icon-validation.json](../downloads/icon-validation.json). ICNS 자체는 원본 사진과 일치하며, Intel에서 보여 주는 지원 아키텍처 배지를 없애기 위해 배포 아키텍처를 바꾸거나 앱 코드를 수정하지 않았다.

[0.5.1 설치 DMG](https://github.com/NEO-82/Mac-photoselecter/raw/refs/heads/codex/macos-installer-download/downloads/PhotoSelect-0.5.1-arm64.dmg): 실제 다운로드 HTTP200, 3,745,663바이트, SHA-256 `81f97a382be7b95cb755110ad103c064121ccc12fde9fcc8b83a18198ee2452b` 일치. 기존 앱을 종료하고 Applications의 앱으로 교체한 뒤 M1 Pro에서 Finder/Dock 표시를 확인한다.

 Intel macOS CI에서 arm64 앱은 직접 실행하지 않으므로 실제 Apple Silicon Dock 화면은 별도 확인 항목이다. 앱 이름/아이콘 파일 포함·서명/DMG 검증과 Dock 실화면 실행을 혼동하지 않는다.
