# 개선 및 검증 기록

## 복구 지점

수정 전 HEAD: `1a1ce8269f45f6df52a490eb29611338185a9794`.
이 환경의 `/workspace/checkpoints/photoselect-before-improvements.bundle`에 전체 Git 이력을 저장하고 `git bundle verify`로 검증했다. 작업 전 변경/미추적 파일은 없었다.
복구 시 현재 작업을 먼저 보관하고, `git clone /workspace/checkpoints/photoselect-before-improvements.bundle /workspace/PhotoSelect-recovered`로 별도 복원할 수 있다.

## 구현 범위

- 기존 3영역과 AppKit 구조 유지. 일반 파일 표시, 시스템 파일 아이콘, 폴더 우선 정렬, 보기 메뉴 숨김 파일 옵션 추가. 심볼릭 링크는 기존 보안 범위 정책에 따라 제외한다.
- 사진 목록은 기존 ARW/JPG/JPEG 필터와 이미지 파이프라인을 유지한다. 일반 파일 선택은 디코딩하지 않는다. 현재 폴더의 사진 선택은 기존 미리보기에 연결한다.
- 큰 사진 창에서 두 번째 mouseDown의 clickCount가 2이면 확대를 초기화하고 기존 닫기 콜백으로 복귀한다. 첫 누름 확대/드래그/놓기, ESC, 방향키와 그리드 더블클릭은 유지한다. 첫 누름 확대는 기존처럼 즉시 반응하므로 빠른 더블클릭의 첫 누름에서도 잠깐 확대될 수 있다. 두 번째 누름에서는 추가 확대/원본 요청을 하지 않는다.
- 기존 FileManager.trashItem 사용과 영구 삭제 fallback 부재를 확인했다. 실패 이유와 파일 보존 안내를 강화하고 성공 시 탐색기도 갱신한다. 영구 삭제 기능은 제공하지 않는다.
- 툴바 SF Symbols/크기 통일, 하단 상태 표시줄 분리, 둥근 로즈 선택 배경, 다크 기본값과 보기 메뉴의 라이트/시스템 테마, 표준 About 패널의 작은 크레딧 추가. 앱 이름/아이콘은 변경하지 않았다.
- 이 체크아웃에는 일괄 파일명 변경이 구현되어 있지 않다. 해당 기능을 제거하거나 변경하지 않았다.

## 실행한 검증

- `git diff --check`: 통과.
- `python3 scripts/test-packaging.py`: 9개 통과. 앱 동작을 검증하는 테스트가 아니다.
- `bash scripts/validate-macos.sh`: Linux 플랫폼 보호 절차에서 exit 2. 앱 빌드/XCTest는 실행되지 않았다.
- 혼합 일반 파일/사진 필터 테스트와 더블클릭 확대 충돌 테스트를 기존 XCTest 파일에 추가했다. macOS에서 실행 필요.
- Linux에는 Swift/Xcode/AppKit이 없으며 UI의 실제 렌더링, 성능, RAW 디코딩, 외장 장치 휴지통은 미검증이다. 판매 품질 또는 회귀 없음으로 판정할 수 없다.

## Apple Silicon Mac 검증 절차 (미실행)

1. macOS 13+, Xcode 15+에서 `bash scripts/validate-macos.sh` 실행. 모든 XCTest와 arm64 빌드가 통과하는지 확인.
2. 앱을 실행하고 실제 ARW/JPG 혼합 폴더에 PDF/MOV/DOCX/ZIP/하위 폴더/숨김 파일을 추가한다. 폴더 선택 시 사진만 그리드에 표시되고 일반 파일 선택은 디코딩 오류를 내지 않는지 확인. 숨김 옵션 on/off와 새로고침 확인.
3. 1,500장 이상 폴더에서 첫 표시/연속 전환/역방향 캐시 탐색 시간과 메모리를 이전 HEAD와 비교한다. 태그 저장 후 재시작하여 복원 확인.
4. 그리드 더블클릭으로 큰 창 진입. 누름 확대, 드래그, 놓기, 확대 중 방향키, 빠른 더블클릭, ESC를 각각 검증한다. 복귀 후 사진 선택/스크롤/폴더 유지 확인. Retina와 외장 모니터에서 반복한다.
5. 내부 SSD, APFS 외장 SSD, exFAT SD/USB에서 원본이 아닌 테스트 복사본을 휴지통으로 이동한다. Finder 휴지통에서 복원 가능하고 다음/마지막/유일한 사진 삭제 후 선택이 올바른지 확인한다. RAW/JPG 동명 쌍은 하나씩만 이동해야 한다.
6. 읽기 전용 매체/잠긴 파일/쓰기 권한 부족/휴지통 미지원 공유 볼륨에서 실패 메시지와 원본 보존을 확인한다. 이동 중 장치 분리도 테스트 복사본으로 확인한다. 실패 시 목록에서 제거되거나 영구 삭제되면 안 된다.
7. 창 최소/최대 폭, 시스템/다크/라이트 테마, 키보드 초점, 툴팁, About 크레딧을 확인한다. 실제 UI 검토 및 필요한 후속 조정 후 배포한다.

## 클라우드 시작 지침

기존 `/workspace/Mac-photoselecter` 체크아웃을 사용한다. 각 작업은 격리되어 있으므로 명시적 요청 없이 worktree를 만들지 않는다. 외부 패키지/서버/API 키는 필요 없다. Linux에서는 위 패키징 테스트만 실행할 수 있다. macOS에서는 위 검증 스크립트와 `swift run PhotoSelect` 또는 Xcode의 PhotoSelect 스킴을 사용한다. 환경 설정 도구가 draft 확인/저장 오류를 반환하여 재사용 start_skill 저장은 확인되지 않았다. 게시도 수행하지 않았다.

## 0.3.0 macOS 설치 파일 생성 요청

소스 `617eb5b2cf0ddd37f157e9059b359f156eb3c53f`를 전달용 브랜치에 업로드해 [macOS 빌드 #16](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43028430041)을 등록했다. 이 실행은 성공 시 기존 워크플로가 `downloads/PhotoSelect-0.3.0-arm64.dmg`, 체크섬과 빌드 결과를 자동 업로드한다. 2026-11-11 이 실행은 약 15분 대기 후 실패했다. GitHub는 `The job was not acquired by Runner of type hosted even after multiple attempts` 및 macOS arm64 용량 부족을 보고했다. 테스트/빌드 단계는 시작되지 않았고 새 DMG는 생성되지 않았다. 공식 runner-images의 지원 목록에서 확인한 `macos-15-intel` 실행기로 변경하는 후속 설정을 준비했다. macOS XCTest는 Intel에서 실행하며 Release 앱은 기존 ARCHS=arm64 설정과 lipo 검증을 유지한다. 후속 업로드 시 기존 Git 프록시 인증과 제공된 GitHub CLI 인증 모두 실패해 원격 적용/재빌드는 차단된 상태다. GitHub 연결 복구 후 아래 후속 설정 커밋을 업로드해야 한다. 후속 작업에서는 이 실행의 결과와 `downloads/build-status.json`의 source_commit을 확인하고, 실패 시 해당 로그를 분석한 뒤 수정/재빌드한다. 성공 시 실제 다운로드 SHA-256을 검증한 후 README의 최신 다운로드 링크와 검증 기록을 갱신한다. 기존 0.2.4 파일을 이번 변경분의 결과로 취급하지 않는다.
