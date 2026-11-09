# 정광이의 MAC 포토셀렉터

Apple Silicon(M1 이상), macOS 13+용 Swift/AppKit 사진 탐색기입니다. ARW/JPG/JPEG를 지원합니다.

[0.2.1 설치 파일 다운로드 (.dmg)](https://github.com/NEO-82/Mac-photoselecter/raw/refs/heads/codex/macos-installer-download/downloads/PhotoSelect-0.2.1-arm64.dmg)

DMG를 열고 **정광이의 MAC 포토셀렉터.app**을 Applications로 끌어 넣으세요. 실행에는 Xcode가 필요하지 않습니다.
기존 앱을 종료한 뒤 새 버전으로 교체하세요. 예전 `PhotoSelect.app`이 남아 있다면 이전 앱만 휴지통으로 옮기세요.
Developer ID 서명/Apple 공증이 없는 개인 테스트용입니다. macOS가 차단하면 출처를 확인한 후 개인정보 보호 및 보안의 실행 허용 안내를 따르세요.

## 사용

- **왼쪽:** 홈·데스크탑·이 Mac·저장장치 폴더 트리. 폴더를 선택하면 해당 폴더의 사진을 비동기로 읽습니다.
- **가운데:** 현재 폴더의 지원 사진 전체를 썸네일로 표시합니다. 파일명은 아래에 두 줄까지, 전체 이름은 툴팁으로 확인합니다.
- **오른쪽:** 선택한 사진의 미리보기와 아래쪽 파일명.
- **더블클릭:** Dock과 메뉴 막대를 가리지 않는 화면 크기의 일반 창으로 사진을 엽니다. 크기 조절이 가능하며 별도 전체 화면 Space를 만들지 않습니다.
- **←/→:** 이전/다음 사진. 왼쪽 마우스를 누른 동안 물리 픽셀 1:1 확대, 드래그로 부분 확인, 놓으면 맞춤 보기. 누른 채 사진을 넘겨도 확대를 유지합니다.
- **Delete / fn+Delete:** 현재 한 장을 macOS 휴지통으로 이동하고 다음 사진을 표시합니다. 마지막 사진이면 이전 사진, 한 장도 없으면 목록으로 돌아갑니다.
- **`\`:** 태그 켜기/끄기. 한글 키보드의 같은 위치 `₩` 키도 지원합니다. 썸네일·미리보기·큰 사진 창 오른쪽 위에 빨간 네모를 표시합니다.
- **Esc:** 큰 사진 창을 닫고 목록으로 돌아갑니다.

태그와 삭제는 파일 목록 또는 큰 사진 창에 키보드 초점이 있을 때 작동합니다. Delete/태그의 키 자동 반복은 무시합니다.
휴지통 이동은 확인 창 없이 한 장씩 실행하며, 실패 시 영구 삭제로 대체하지 않습니다. RAW/JPEG 동명 쌍은 독립 파일입니다.
태그는 원본을 수정하지 않고 `~/Library/Application Support/dev.photoselect.app/tags.json`에 원자적으로 저장합니다.
Dock 자동 가리기는 macOS 설정을 따릅니다. 데스크탑 접근이 거부됐었다면 **폴더 열기**로 데스크탑을 다시 선택하세요. 새 접근 권한으로 실패 캐시를 비우고 폴더를 다시 읽습니다.

자세한 저장 방식·휴지통·수동 테스트는 [사용 및 검증 안내](docs/browsing-tags-trash.md)를 참고하세요.

## 빌드 및 설치 파일 생성

macOS 13+, Xcode 15+가 필요합니다. 외부 패키지, 서버, API 키는 필요하지 않습니다.

1. `PhotoSelect.xcodeproj` → `PhotoSelect` 스킴 → `My Mac`으로 Run.
2. `bash scripts/validate-macos.sh`로 앱 빌드와 Swift Package XCTest 실행.
3. `설치파일-만들기.command`를 더블클릭하거나 `bash scripts/package-macos.sh`로 테스트·Release 빌드·DMG 검증 실행.

기본 결과물은 `dist/PhotoSelect-0.2.1-1-arm64/PhotoSelect-0.2.1-1-arm64.dmg`와 `SHA256SUMS`입니다.
다시 만들 때는 `PHOTOSELECT_BUILD_NUMBER=2 bash scripts/package-macos.sh`처럼 빌드 번호를 늘리세요.
Swift Package 개발 실행은 `swift run PhotoSelect`도 지원합니다. 배포용 앱과 아이콘은 Xcode 프로젝트로 만듭니다.
각 작업은 격리된 체크아웃을 사용하므로 별도 worktree는 필요하지 않습니다.

아이콘은 제공된 ‘정광이’ 골든리트리버 그림이며, `Resources/AppIcon.png`에서 16–1024픽셀 ICNS를 생성합니다.
앱은 로컬 개발용으로 샌드박스를 활성화하지 않았으며 Developer ID 서명·공증은 아직 구성하지 않았습니다.
[패키징 안내](docs/packaging.md)와 [빌드·테스트 기록](docs/validation.md)을 참고하세요.

## 구조 및 제한

- `App.swift`: 앱 생명주기, 이름, 메뉴
- `Browser.swift`: 3영역 화면, 썸네일/미리보기, 선택·태그·휴지통 UI 연결
- `FolderTree.swift`: 지연 로딩 폴더 트리와 접근 수명
- `PhotoModel.swift`: 지원 파일, 삭제 후 선택 상태, Retina 확대 좌표
- `PhotoActions.swift`: 별도 태그 JSON, 비동기 macOS 휴지통 이동
- `ImagePipeline.swift`: ImageIO/RAW 렌더링, 비동기 프리페치, 예산 제한 캐시
- `Viewer.swift`: 일반 창 뷰어, 누름 확대, 키보드 동작과 태그 표시

숨김 항목/심볼릭 링크와 하위 폴더의 파일은 현재 사진 목록에 포함하지 않습니다. 새로고침으로 변경 내용을 반영합니다.
영구 폴더 북마크를 저장하지 않으므로 앱 재시작 시 홈에서 시작합니다. 외부에서 파일을 이동/이름 변경하면 태그는 자동 추적하지 않습니다.
편집·AI 분석·태그 필터·파일 복사·일괄 이름 변경은 구현하지 않습니다. 명시적인 휴지통 이동 외에 원본 사진에 쓰지 않습니다.

[Retina·RAW·캐시 설계](docs/architecture.md)를 참고하세요. 모든 Sony ARW 변형을 지원한다고 주장하지 않습니다.
실제 ARW 호환성, M1 Pro의 1,500장 성능, 실제 입력 장치·외장 드라이브 분리와 휴지통 복구는 실기기 확인이 필요합니다.
