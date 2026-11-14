# J♡S

Jeonggwang ♡ Seoa.

Apple Silicon(M1 이상), macOS 13+용 Swift/AppKit 사진 탐색기입니다. ARW/JPG/JPEG를 지원합니다.

[J♡S v0.6.0 설치 파일 다운로드 (.dmg)](https://github.com/NEO-82/Mac-photoselecter/raw/070b36c4980e8ff4bb3a7c5e2ee295264c70ee3b/downloads/J-S-0.6.0-arm64.dmg)

현재 버전은 Finder Sony ARW 파일 연결을 추가한 **v0.6.0 빌드65**입니다. [Finder 열기·기본 앱 설정·119개 XCTest 및 설치 파일 검증](docs/finder-open.md). 대량 목록 처리·정렬·일괄 이름 변경은 유지합니다. [기존 기능·사용법·복구 절차](docs/file-management.md).

DMG를 열고 **J♡S.app**을 Applications로 끌어 넣으세요. 실행에는 Xcode가 필요하지 않습니다.
기존 `정광이의 MAC 포토셀렉터.app`, `PhotoSelect.app`, J♡S를 모두 종료하세요. J♡S.app을 Applications에 넣은 뒤 이전 이름의 **앱 번들만** 휴지통으로 옮기세요. 이름이 달라 자동 교체되지 않을 수 있습니다. Dock의 이전 바로가기도 J♡S로 다시 등록하세요. `~/Library/Application Support/dev.photoselect.app/tags.json`과 사용자 설정은 삭제하지 말고, 앱 정리 도구의 관련 데이터 삭제 기능은 사용하지 마세요.
Developer ID 서명/Apple 공증이 없는 개인 테스트용입니다. macOS가 차단하면 출처를 확인한 후 개인정보 보호 및 보안의 실행 허용 안내를 따르세요.

## 사용

화면 최상단 macOS 메뉴 막대에 **파일·보기·사진·윈도우** 메뉴를 제공합니다. 창 안의 작은 도구바 아래에 세 영역이 나란히 배치됩니다. 하단 오른쪽에는 `Made with Seoa ♡` 크레딧을 고정 표시합니다.
파일 메뉴의 폴더 열기는 `⌘O`, 새로고침은 `⌘R`, 상위 폴더는 `⌘↑`, 선택 사진 크게 보기는 보기 메뉴 또는 Return입니다.

- **왼쪽:** 홈·데스크탑·이 Mac·저장장치 파일 트리. 폴더와 일반 파일을 시스템 아이콘으로 표시하며, 폴더를 선택하면 해당 폴더의 사진을 비동기로 읽습니다. 일반 파일은 이미지로 디코딩하지 않습니다. 화살표는 펼치기·접기, 이름은 폴더 선택이며, 분할선을 드래그한 폭과 펼친 경로를 유지합니다.
- **가운데:** 현재 폴더의 폴더·사진·일반 파일을 한 그리드에 표시합니다. 폴더는 먼저 정렬하며 더블클릭 또는 Return으로 진입합니다. 일반 파일을 선택하면 오른쪽에 시스템 아이콘·파일명·확장자를 표시합니다. ARW/JPG 및 PNG/HEIC/TIFF/GIF/BMP 이미지는 썸네일과 미리보기를 제공합니다. 파일명은 아래에 두 줄까지, 전체 이름은 툴팁으로 확인합니다.
- **오른쪽:** 선택한 사진의 미리보기와 아래쪽 파일명. 기본 폭은 창의 약 22%(최대 320pt)이며 원본 사진 크기와 관계없이 맞춰 표시합니다.
- **더블클릭:** Dock과 메뉴 막대를 제외한 사용 가능 영역 전체를 채우는 일반 창으로 사진을 엽니다. 크기 조절이 가능하며 별도 전체 화면 Space를 만들지 않습니다.
- **←/→:** 이전/다음 사진. 왼쪽 마우스를 길게 누르면 실제 표시 JPEG의 물리 픽셀 1:1 확대, 드래그로 부분 확인, 놓으면 맞춤 보기. 정지한 누름은 시스템 더블클릭 판별 시간 후 확대하며 드래그는 즉시 확대합니다. 빠른 더블클릭은 먼저 확대되지 않고 목록으로 복귀합니다. 누른 채 사진을 넘겨도 확대를 유지합니다.
- **Delete / fn+Delete:** 현재 한 장을 macOS 휴지통으로 이동하고 다음 사진을 표시합니다. 마지막 사진이면 이전 사진, 한 장도 없으면 목록으로 돌아갑니다.
- **`\`:** 태그 켜기/끄기. 한글 키보드의 같은 위치 `₩` 키도 지원합니다. 썸네일·미리보기·큰 사진 창 오른쪽 위에 빨간 네모를 표시합니다.
- **정렬:** 목록 상단의 파일 이름순·촬영 시간순·크기순. 같은 버튼을 누르면 ↑/↓가 바뀌며 다른 기준은 ↑부터 시작합니다. 촬영 정보가 없는 사진은 항상 뒤쪽, 동률은 이름순입니다. 선택과 태그 필터를 유지하고 큰 사진 창도 같은 순서로 탐색합니다.
- **일괄 이름 변경:** 도구바에서 현재 폴더의 전체 사진에 연속 번호를 붙입니다. 태그 필터·숨김 표시와 관계없이 모든 사진이 대상이며 하위 폴더·문서·macOS `._` 파일은 제외합니다. 미리보기와 충돌을 확인한 뒤 실행하세요. 확장자와 이미지 내용은 보존하며 태그는 새 경로로 연결합니다. [사용법·복구 방법·검증 범위](docs/file-management.md).
- **태그된 사진만 보기:** 가운데 목록 상단 체크 버튼으로 현재 폴더의 태그 사진만 표시합니다. 큰 사진 창의 방향키도 필터 목록만 탐색하며, 태그 해제 시 다음 사진(마지막이면 이전 사진)으로 이동합니다. 마지막 태그가 없어지면 목록으로 돌아갑니다. 필터 전환은 기존 캐시와 태그 데이터를 유지합니다.
- **Esc / 큰 사진 창 더블클릭:** 현재 사진과 폴더 선택을 유지하며 목록으로 돌아갑니다. 첫 누름 확대·드래그·놓기와 그리드 더블클릭은 유지합니다.
- **보기 메뉴:** 숨김 파일 표시(`⌘⇧.`), 시스템/라이트/다크 테마 선택. 앱 기본값은 다크이며 선택 사진은 은은한 로즈 색으로 강조합니다.

태그와 삭제는 파일 목록 또는 큰 사진 창에 키보드 초점이 있을 때 작동합니다. Delete/태그의 키 자동 반복은 무시합니다.
휴지통 이동은 확인 창 없이 한 장씩 실행하며, 실패 시 영구 삭제로 대체하지 않습니다. RAW/JPEG 동명 쌍은 독립 파일입니다.
태그는 원본을 수정하지 않고 `~/Library/Application Support/dev.photoselect.app/tags.json`에 원자적으로 저장합니다. 앱을 다시 열거나 Mac을 정상 재부팅한 뒤 같은 사진 폴더를 선택하면 태그를 복원합니다. 마지막 태그 직후 앱을 종료해도 대기 중인 저장을 마친 뒤 정상 종료합니다.
프로그램과 큰 사진 창은 화면의 논리 포인트 크기에 맞춰 열고, 모니터 이동·분리·배율 변경 시 화면 안으로 조정합니다. 열린 뷰어에서 직접 조절한 크기는 같은 화면에서 다른 사진을 열어도 유지합니다.
Dock 자동 가리기는 macOS 설정을 따릅니다. 데스크탑 접근이 거부됐었다면 **폴더 열기**로 데스크탑을 다시 선택하세요. 새 접근 권한으로 실패 캐시를 비우고 폴더를 다시 읽습니다.

자세한 저장 방식·휴지통·수동 테스트는 [사용 및 검증 안내](docs/browsing-tags-trash.md)를 참고하세요.

## 빌드 및 설치 파일 생성

macOS 13+, Xcode 15+가 필요합니다. 외부 패키지, 서버, API 키는 필요하지 않습니다.

1. `PhotoSelect.xcodeproj` → `PhotoSelect` 스킴 → `My Mac`으로 Run.
2. `bash scripts/validate-macos.sh`로 앱 빌드와 Swift Package XCTest 실행.
3. `설치파일-만들기.command`를 더블클릭하거나 `bash scripts/package-macos.sh`로 테스트·Release 빌드·DMG 검증 실행.

기본 결과물은 `dist/J-S-0.6.0-1-arm64/J-S-0.6.0-1-arm64.dmg`와 `SHA256SUMS`입니다.
다시 만들 때는 `PHOTOSELECT_BUILD_NUMBER=2 bash scripts/package-macos.sh`처럼 빌드 번호를 늘리세요.
Swift Package 개발 실행은 `swift run PhotoSelect`도 지원합니다. 배포용 앱과 아이콘은 Xcode 프로젝트로 만듭니다.
각 작업은 격리된 체크아웃을 사용하므로 별도 worktree는 필요하지 않습니다.

아이콘은 사용자가 제공한 공식 1024×1024 사진 이미지이며, `Resources/AppIcon.png`에서 기존 스크립트로 16–1024픽셀 ICNS를 생성합니다. [원본 일치·번들/Finder 검증 기록](docs/official-app-icon.md).
앱은 로컬 개발용으로 샌드박스를 활성화하지 않았으며 Developer ID 서명·공증은 아직 구성하지 않았습니다.
[패키징 안내](docs/packaging.md)와 [빌드·테스트 기록](docs/validation.md)을 참고하세요.

## 구조 및 제한

- `App.swift`: 앱 생명주기, 이름, 표준 메뉴, 종료 전 태그 저장 대기
- `Browser.swift`: 3영역 화면, 썸네일/미리보기, 선택·태그·휴지통 UI 연결
- `FolderTree.swift`: 지연 로딩 폴더 트리와 접근 수명
- `PhotoModel.swift`: 지원 파일, 삭제 후 선택 상태, 화면별 창/분할 크기, Retina 확대 좌표
- `PhotoActions.swift`: 별도 태그 JSON, 비동기 macOS 휴지통 이동
- `EmbeddedPreview.swift`: ARW에서 최대 내장 카메라 JPEG/방향/색 공간을 안전하게 추출
- `ImagePipeline.swift`: 같은 JPEG의 sRGB 변환, 현재/앞뒤 비동기 준비, 공유 작업과 예산 제한 캐시
- `Viewer.swift`: 일반 창 뷰어, 누름 확대, 키보드 동작과 태그 표시
- `PhotoSorting.swift`: 비동기 EXIF 메타데이터 캐시와 사진 정렬
- `BatchRename.swift`, `BatchRenameWindow.swift`: 전체 사진 이름 변경 미리보기·충돌 검사·복구 기록·태그 연결

숨김 파일은 탐색기에서 기본 숨김이며 보기 메뉴로 표시할 수 있습니다. 숨김 항목은 보기 메뉴로 켤 수 있습니다. 심볼릭 링크와 하위 폴더 내부의 사진은 현재 폴더 목록에 포함하지 않습니다. 새로고침으로 변경 내용을 반영합니다.
영구 폴더 북마크를 저장하지 않으므로 앱 재시작 시 홈에서 시작합니다. 외부에서 파일을 이동/이름 변경하면 태그는 자동 추적하지 않습니다.
편집·AI 분석·파일 복사는 구현하지 않습니다. 사진 내용은 수정하지 않으며, 명시적인 휴지통 이동과 일괄 이름 변경으로 파일 경로만 바꿉니다.

[Retina·RAW·캐시 설계](docs/architecture.md)를 참고하세요. 모든 Sony ARW 변형을 지원한다고 주장하지 않습니다.
모든 ARW 변형의 호환성, M1 Pro의 2,000–3,000장 실제 촬영 폴더 성능·장시간 메모리, 실제 입력 장치·외장 드라이브 분리와 휴지통 복구는 실기기 확인이 필요합니다.

0.4.0은 [macOS 빌드 #21](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43038529075)에서 XCTest **61개**, arm64 Release 앱 빌드, 앱 서명 및 DMG 검증을 통과했습니다. 실제 다운로드 HTTP 200과 SHA-256 일치도 확인했습니다. 테스트는 Intel macOS/Xcode 16.4에서 실행했으며 실제 M1 Pro 실행·Sony ARW 호환성·대량 사진 성능·외장 저장장치 검증은 별도입니다. [화면 캡처·변경 파일·검증 결과·실기기 절차](docs/soft-romantic-pro.md)를 참고하세요.

0.4.1은 About 크레딧을 `Made with Seoa ♡`와 11pt 로즈 색상으로 변경했습니다. [실제 소스 위치·About UI 캡처·62개 테스트 결과](docs/about-seoa.md)를 확인하세요.

0.5.0은 ARW 표시 중 작은 JPEG가 RAW 현상 결과로 바뀌는 경로를 제거했습니다. 처음부터 최대 내장 JPEG를 표시하고 썸네일/큰 보기/확대의 색 처리를 통일합니다. [macOS 빌드 #26](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43144031701)에서 회귀 **85개**와 최적화 실제 ARW 검사 **3개**가 통과했습니다. 내장 JPEG가 센서보다 작으면 센서 기준100%로 확대하지 않고 제한을 표시합니다. [원인·실제 Sony 검증·속도 측정](docs/stable-preview.md).

0.5.1은 공식 앱 아이콘을 교체한 버전입니다. 뷰어/UI 소스와 기존 아이콘 생성 스크립트·Xcode 빌드 단계는 유지했습니다. [macOS 빌드 #27](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43147070222)에서 회귀85개·Release 검사3개와 ICNS10종/원본 일치 검증이 통과했습니다.

0.5.2는 메인 창 하단 크레딧과 폴더·사진·일반 파일을 함께 보여 주는 브라우저를 제공합니다. [macOS 빌드 #32](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43230004616)에서 XCTest **86개**, Release Sony RAW 검사 **3개**, arm64 빌드·ad-hoc 서명·DMG 검증을 통과했습니다. 실제 다운로드 HTTP 200과 SHA-256 일치도 확인했습니다. [UI 화면과 검증 기록](docs/finder-browser.md).

0.5.3은 **태그된 사진만 보기** 필터를 추가했습니다. [macOS 빌드 #40](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43365236450)에서 XCTest **88개**, Release Sony RAW 검사 **3개**, arm64 빌드·서명·DMG 검증을 통과했습니다. 실제 다운로드 HTTP 200과 SHA-256 일치도 확인했습니다. [변경 파일·필터 검증·화면 캡처](docs/tagged-filter.md).

0.5.4는 표시 이름만 **J♡S**로 변경합니다. Bundle Identifier와 기존 태그·설정 저장 구조 및 v0.5.3 기능은 유지합니다. [macOS 빌드 #41](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43370039453)에서 XCTest **89개**, Release RAW 검사 **3개**, arm64 앱·아이콘·이름·서명·DMG 검증이 통과했습니다. [안전한 교체·변경 파일·검증 기록](docs/js-branding.md).

0.5.5는 사진 전환 중 이전 프레임 유지, 메모리 바이트 기반 최근 사진 캐시 확대와 방향별 프리페치/작업 공유를 개선합니다. macOS 빌드 #48에서 XCTest **92개**, Release RAW·탐색 검사 **4개**, arm64 앱·서명·DMG 검증을 통과했습니다. CI의 Release 캐시 적중 적용 최대 **18.27ms**, 빈 draw **0회**이며 M1 Pro의 실제 촬영 폴더 성능은 별도 확인이 필요합니다. [원인·변경 파일·전체 측정값·메모리 비용·남은 지연](docs/navigation-performance.md).

0.6.0은 2,000/3,000장 목록 검사, 이름·EXIF 촬영 시간·크기 정렬, 전체 사진 일괄 이름 변경과 태그 연결·중단 복구를 추가합니다. [macOS 빌드 #61](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43451626978)에서 XCTest **116개**, Release RAW/탐색 **4개**, arm64 앱·서명·아이콘·DMG 검증이 통과했습니다. 실제 다운로드 SHA-256도 일치합니다. CI Release 캐시 적중 적용 최대 **12.03ms**, 빈 draw **0회**이며 새 버전의 M1 Pro·3,000장 실제 RAW 폴더·장시간 메모리 검증은 남아 있습니다. [검증 범위와 상세 결과](docs/file-management.md).
