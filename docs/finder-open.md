# Finder에서 Sony ARW 열기

v0.6.0 빌드61 소스 이후의 변경입니다. 이 변경의 macOS 빌드/설치 파일은 아직 검증하지 않았습니다.

## 동작 및 권한

- 앱 번들의 Info.plist에 Sony의 `com.sony.arw-raw-image`만 Viewer/Alternate로 등록합니다. 표준 `public.camera-raw-image` 전체의 처리 앱으로 등록하거나 기본 앱을 프로그램에서 변경하지 않습니다.
- 앱 설치 후 Launch Services가 번들을 검색하면 Finder의 ‘다음으로 열기’에 J♡S가 표시됩니다. `swift run`은 설치된 앱 번들의 문서 연결 검증을 대신하지 않습니다.
- 기본 앱 설정: Finder에서 ARW 선택 → 정보 가져오기(⌘I) → 다음으로 열기 → J♡S → 모두 변경. 이는 사용자가 ARW 유형에 적용하는 설정입니다.
- 실행 전 받은 URL은 앱 창 준비 후 처리하고, 실행 중에는 기존 브라우저 창을 사용합니다. 여러 파일을 한 번에 열면 첫 ARW를 선택합니다. 이름 변경/휴지통 작업 중이면 상태 표시로 재시도를 안내합니다.
- 상위 폴더를 기존 비동기 목록/정렬 경로로 읽고 요청한 파일을 선택합니다. 태그 필터는 해제하며 숨김 ARW는 보이도록 합니다. 같은 폴더에서는 목록과 이미지 캐시를 재사용합니다. 최대 내장 JPEG 추출 및 이미지 파이프라인은 변경하지 않습니다.
- Debug/Release 모두 기존 `ENABLE_APP_SANDBOX=NO` 유지. Finder 파일 URL과 폴더 URL의 보안 범위 접근은 FolderLease가 비동기 작업 동안 유지하고 시작에 성공한 URL만 종료합니다. 파일 접근 허가가 형제 파일/상위 폴더 권한까지 제공한다고 가정하지 않습니다.
- macOS가 상위 폴더 읽기를 거부하면 해당 폴더를 선택하는 NSOpenPanel로 사용자의 접근 승인을 받습니다. 취소하거나 다른 폴더를 선택하면 임의로 권한을 확장하지 않습니다. 영구 보안 범위 북마크나 전체 디스크 접근은 추가하지 않습니다.
- SD/외장 드라이브 사용 목적 문구를 추가했습니다. 드라이브 분리 후 기존 갱신/캐시 무효화 동작은 유지합니다.

## macOS 검증 절차

Xcode 15+, macOS 13+, Apple Silicon Mac에서 새 빌드 번호로 수행하세요.

```bash
export PHOTOSELECT_ARW_SAMPLE_DIRECTORY="${TMPDIR:-/tmp}/photoselect-raw-samples"
bash scripts/fetch-raw-test-samples.sh
bash scripts/validate-macos.sh
# PHOTOSELECT_BUILD_NUMBER에 기존 배포보다 큰 새 번호 지정
PHOTOSELECT_BUILD_NUMBER=62 bash scripts/package-macos.sh
```

배포 브랜치의 기존 Actions도 동일한 패키징과 Release RAW 검사 4개를 수행합니다. 새 Finder XCTest 3개는 전체 Debug XCTest에 포함됩니다. 이 중 2개는 선택/창 재사용/폴더 전환/일반 JPEG 탐색을 확인하고, 1개는 실제 Sony ARW의 내장 JPEG 미리보기를 확인합니다. 테스트 메서드 직접 호출만으로 Launch Services 이벤트나 실물 저장장치의 권한 처리가 검증되지는 않습니다.

1. 새 DMG를 설치하고 이전 앱 인스턴스를 모두 종료합니다. 같은 앱의 중복 설치를 피하세요.
2. 내부 디스크의 실제 ARW를 ‘다음으로 열기 → J♡S’로 엽니다. 한 브라우저 창에서 상위 폴더가 열리고 해당 ARW의 이름과 미리보기가 일치하는지 확인합니다.
3. 위의 정보 가져오기 절차로 ARW의 기본 앱을 선택한 후 앱 종료 상태에서 ARW를 더블클릭합니다. JPEG 및 다른 제조사 RAW의 기본 앱은 변경되지 않았는지 확인합니다.
4. 앱 실행 중 다른 폴더의 ARW를 열고 창 개수가 늘지 않는지 확인합니다. 최소화 상태, 큰 사진 창 표시 중, 같은 폴더의 다른 ARW, 빠른 연속 열기도 확인합니다.
5. 태그 필터를 켠 뒤 태그 없는 ARW를 Finder에서 엽니다. 필터가 해제되고 정확한 파일이 선택되는지 확인합니다.
6. 실제 SD 카드와 외장 SSD에서 각각 실행 전/실행 중 열기를 확인합니다. 접근 허용/거부/폴더 승인 취소를 확인합니다. 폴더 접근 승인 시 같은 상위 폴더를 선택하고 인접 사진 탐색도 확인합니다. 저장장치 분리 후 오류 안내, 재연결 후 다시 열기를 확인합니다.
7. 기존 RAW 색/확대/탐색 속도, 태그 저장 후 재실행 복원, 테스트용 사진 휴지통 이동, 정렬 및 일괄 이름 변경을 확인합니다.
8. DMG arm64/서명/마운트 검증이 통과한 뒤 업로드하고 실제 다운로드 SHA-256을 비교합니다. 기존 빌드61 DMG를 새 기능 결과물로 사용하지 않습니다.

현재 Linux에서 패키징 실패 처리 테스트 9개는 통과했습니다. macOS XCTest, Launch Services, 실제 GUI/RAW/외장 장치 및 새 DMG는 미검증입니다. 현재 GitHub Actions API 접근은 Forbidden이므로 이 환경에서는 원격 빌드를 시작하지 못했습니다.
