# PhotoSelect — 1단계 MVP

Apple Silicon용 Swift/AppKit 사진 탐색기. macOS 13+, Xcode 15+가 필요합니다.
외부 패키지, 서버, API 키는 필요하지 않습니다. 원본 사진을 수정하지 않습니다.

## 설치 파일 만들기

**Xcode 15 이상이 설치된 Mac**에서 `설치파일-만들기.command`를 더블클릭하세요.
처음 설치한 Xcode라면 먼저 한 번 실행해 추가 구성 요소 설치와 사용권 동의를 완료해야 합니다.
터미널에서는 저장소 폴더에서 다음 한 줄을 실행할 수도 있습니다.

```bash
bash scripts/package-macos.sh
```

테스트 → arm64 Release 빌드 → 로컬 서명 → DMG 생성·검증을 순서대로 수행합니다.
성공하면 `dist/PhotoSelect-0.1.0-1-arm64/PhotoSelect-0.1.0-1-arm64.dmg`와 `SHA256SUMS`가 생성됩니다.
DMG를 열고 **PhotoSelect.app을 Applications로 끌어 넣으면 설치**됩니다. 설치 후 실행에는 Xcode가 필요하지 않습니다.
Developer ID 서명/Apple 공증이 없는 개인 테스트용이며 다운로드한 앱은 macOS에서 첫 실행을 차단할 수 있습니다.
자세한 설치·재빌드·GitHub 빌드 방법은 [패키징 안내](docs/packaging.md)를 참고하세요.

이 Linux 환경에서는 실제 DMG를 생성하지 못했습니다. `PhotoSelect-Mac-BuildKit.zip`은
Mac에서 위 절차를 실행하기 위한 **소스 묶음이며 완성된 설치 파일이 아닙니다**.

## 실행

1. Mac에서 `PhotoSelect.xcodeproj`를 열고 `PhotoSelect` 스킴, `My Mac`을 선택해 Run.
2. **폴더 열기**에서 사진 폴더를 선택. 왼쪽 하위 폴더는 더블클릭으로 진입하며 상위 폴더 버튼으로 돌아갑니다.
3. 오른쪽 사진 더블클릭 → 전체 화면. ←/→ 탐색, 왼쪽 버튼을 누르는 동안 100%, 드래그로 부분 확인, 놓으면 화면 맞춤, Esc로 목록 복귀.
4. `bash scripts/validate-macos.sh`로 앱 빌드 및 Swift Package XCTest 실행.
   테스트는 Xcode 앱 스킴에 포함되지 않으며 `swift test`로 실행합니다.

Swift Package도 Xcode에서 열거나 `swift run PhotoSelect`로 실행할 수 있습니다.
앱 번들은 Xcode 프로젝트를 사용하세요. 별도 worktree는 필요하지 않습니다.
기본 앱은 샌드박스를 활성화하지 않은 로컬 개발 빌드입니다. DMG는 개인 테스트용 로컬 서명을 사용하며,
일반 배포를 위한 Developer ID 서명·공증은 아직 구성하지 않았습니다.

## 구조

- `App.swift`: 앱 생명주기, 메뉴
- `Browser.swift`: 폴더 목록, 가상화된 썸네일 그리드, 탐색 요청 세대 관리
- `PhotoModel.swift`: 파일 선택, 폴더 접근 수명, 확대 좌표 계산
- `ImagePipeline.swift`: ImageIO 프리뷰/썸네일, Core Image RAW 렌더링, LRU 메모리 캐시
- `Viewer.swift`: 전체 화면 창, 입력 이벤트, 확대 그리기
- `Tests/PhotoSelectTests`: 확장자·동명 쌍·폴더 열거·확대 좌표·손상 파일 테스트

## 명시적인 기본 동작과 제한

- ARW/JPG/JPEG만, 대소문자 무시. 동명 RAW/JPEG는 독립 항목. 자연 파일명 순서, 끝에서 멈춤.
- 선택한 폴더의 파일만 표시하고 숨김 항목/심볼릭 링크는 제외합니다. 재귀 탐색하지 않습니다.
- 하위 폴더 목록을 통한 단순 탐색이며 Finder형 전체 디스크 트리는 아닙니다.
- 전체 화면은 사진을 더블클릭한 화면 크기의 테두리 없는 창입니다. macOS 별도 Full Screen Space는 생성하지 않습니다.
- 폴더 선택은 NSOpenPanel, 접근은 security-scoped URL의 수명을 관리합니다. 종료 후 선택을 복원하지 않으므로 영구 bookmark를 저장하지 않습니다.
- 폴더 내용 변경은 자동 감시하지 않습니다. 새로고침으로 캐시와 파일 목록을 갱신합니다.
- 저장장치 해제 알림은 안전을 위해 모든 캐시를 비우고 재선택을 안내합니다. 관련 없는 볼륨 해제에도 안내가 뜰 수 있습니다.
- 썸네일 실패는 경고 아이콘/툴팁, 파일 표시 실패는 뷰어 안내로 표시하며 방향키로 계속 탐색할 수 있습니다.
- 편집·태그·이름 변경·파일 복사/이동은 구현하지 않습니다.

상세 RAW/Retina 정의는 [설계 문서](docs/architecture.md), 실기기 확인 항목과 측정은 [검증 문서](docs/validation.md)를 참고하세요.

현재 Linux 클라우드에서는 macOS SDK/Xcode/Swift가 없어 컴파일, XCTest, GUI 및 ARW 실물 검증을 실행하지 못했습니다.
이 소스는 Mac에서 검증이 필요한 MVP 구현이며, 빌드 성공이나 성능 목표 달성을 주장하지 않습니다.
