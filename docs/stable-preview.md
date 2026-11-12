# 0.5.0 — 일관된 ARW 카메라 JPEG 표시

## 수정 전 원인

기준 소스 `4645bde617de95d8d8636259ace2f743548b1b0c`, 복구 번들 `/workspace/checkpoints/photoselect-before-stable-preview.bundle`의 무결성을 확인했다.

| 단계 | 기존 데이터와 디코딩 경로 |
| --- | --- |
| 썸네일 | ARW ImageIO 내장 썸네일, 최대320px. 작은 별도 JPEG일 수 있음 |
| 최초 미리보기/큰 창 | ARW ImageIO 내장 이미지, 최대2560px 요청. 최대 크기 JPEG를 보장하지 않음 |
| 확대 중 최종 이미지 | CIRAWFilter + CIContext로 센서 RAW를 새로 현상한 비동기 결과가 기존 이미지를 덮어씀 |

마우스를 누른 채 사진을 넘기는 동안에도 확대 상태가 유지되므로 새 사진의 첫 JPEG 뒤에 RAW 현상 결과가 도착할 수 있었다. 카메라 JPEG와 Apple RAW 렌더링은 색/노이즈/선명도가 다를 수 있다. 또한 작은 JPEG를 RAW 센서 크기로 간주해 확대하던 좌표 계산은 실제 초점 판별 해상도를 과장했다.

## 변경 경로

1. `EmbeddedPreview.swift`에서 TIFF IFD0/다음 IFD/SubIFD/Exif/Sony MakerNote의 JPEG를 조사해 완전한 JPEG 중 픽셀 면적이 가장 큰 것을 선택한다. 처음 발견한1616px 프리뷰에서 탐색을 끝내지 않는다. 압축 번호가JPEG여도 CFA/14비트 센서 strip은 후보에서 제외하며, SOF3 lossless Bayer 타일을 카메라 JPEG로 간주하지 않는다. 작은 썸네일뿐이면 오류를 안내하며 RAW 현상으로 대체하지 않는다.
2. `ImagePipeline.swift`는 ARW 센서 픽셀을 ImageIO/Core Image로 디코딩하지 않는다. 추출한 카메라 JPEG만 디코딩한다. JPEG ICC가 최우선이며 JPEG Exif와 바깥 ARW Exif/Interop 색 공간 힌트를 확인한 뒤 명시적인 sRGB 비트맵으로 변환한다. 태그 없는 알 수 없는 색 공간은 sRGB 가정임을 메타데이터에 남긴다.
3. 썸네일도 같은 JPEG의 주 이미지를 축소하고 같은 색 변환을 사용한다. 별도 Exif 썸네일은 사용하지 않는다. 큰 보기와 확대는 같은 디코딩 이미지/캐시 키를 공유한다.
4. `Browser.swift`는 자동 `.full`/RAW 교체를 요청하지 않는다. 현재 사진과 앞뒤 한 장을 즉시 비동기 요청하고, 겹치는 프리페치는 공유·우선순위 승격한다. 과거 UI 구독만 취소하며 유효한 이웃 작업을 매 전환마다 취소하지 않는다. 캐시가 있으면 동기 조회로 바로 표시하고, 없으면 작은 사진을 늘리는 대신 준비 상태를 표시한다.
5. `Viewer.swift`의 100%는 실제 JPEG1픽셀=디스플레이 물리1픽셀이다. RAW JPEG의 맞춤 보기도 물리1:1 이상으로 늘리지 않는다. 기존 마우스 타이머/드래그/더블클릭/ESC/방향키 동작은 변경하지 않는다. 오른쪽 미리보기의 비율과 실제 픽셀 제한도 같은 원칙을 따른다.

## 자원 제한

디스플레이 LRU512MiB, 썸네일 LRU96MiB. 현재 선택 비트맵은 UI와 같은 객체를 고정하며 이 예산 밖이다. 각 파이프라인의 압축 JPEG 캐시는64MiB/4개로 제한한다. 각 큐는 동시2작업이며 프로세스 전체 상한은 아니다. 실행 중 디코더/색 변환 버퍼와 GPU 메모리는 별도다. 폴더 변경/새로고침/장치 변경은 캐시를 무효화한다. 큰 단일 JPEG와 잘못된 구조는 크기/파싱 한도에 따라 실패한다.

## 실제 Sony 회귀 자료

[metadata-extractor-images](https://github.com/drewnoakes/metadata-extractor-images/tree/7b56b649039c57903bcd5cbe9846ab81eb518ec4)의 공개 샘플을 사용했다. [README 허가](https://github.com/drewnoakes/metadata-extractor-images/blob/7b56b649039c57903bcd5cbe9846ab81eb518ec4/README.md): “You are free to use these media files however you wish.”
원본 ARW는 앱 저장소/DMG에 넣지 않으며 CI 임시 폴더에 내려받고 SHA-256을 검증한다. 재현은 `PHOTOSELECT_ARW_SAMPLE_DIRECTORY=<폴더> bash scripts/fetch-raw-test-samples.sh` 후 같은 환경 변수로 `swift test --parallel --jobs 2`를 실행한다.

| 카메라 | 확인한 JPEG/메타데이터 | SHA-256 |
| --- | --- | --- |
| A7M3 | 가장 큰 JPEG1616×1080, 방향8→1080×1616, RAW6000×4000, Adobe RGB(Interop R03) | `87a502c37ea76d1128aa5773356142951a2249f9797e1ddad4d817d42cf5cc15` |
| A7M4 | IFD0는1616×1080이지만 다른 IFD에7008×4672, sRGB, RAW와 같은 해상도 | `9b01e699daab4cd2a457c7e6fec206d4d907e9cbfc3464944dca38b547cb086f` |

두 파일의 JPEG 자체에는 ICC/Exif가 없어 바깥 색 공간/방향을 전달해야 한다. 형식 근거: [ExifTool JPEG 태그](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Exif.pm#L1149), [Sony MakerNote](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Sony.pm#L906).

## 성능 조사에서 추가로 보완한 부분

실제 A7M4는 TIFF 압축 번호7로 표시한14비트 CFA 센서 strip36,304,000바이트도 포함했다. 이를 프리뷰처럼 탐색하던 초기 구현은 Debug에서 추출만 약1195ms가 걸렸다. RGB/YCbCr8비트 JPEG strip만 등록하고 알려진 CFA 범위는 복구 탐색에서도 제외했다. 이는 RAW 현상과 별개인 불필요한 파일 탐색 비용이었다. JPEG 후보도8비트 DCT로 제한해 센서 타일을 선택하지 않도록 회귀 테스트를 추가했다.

## 검증과 제한

[macOS 빌드 #26](https://github.com/NEO-82/Mac-photoselecter/actions/runs/43144031701), 소스 `a1758b2146594396c26d266d1e443957176c7cc0`에서 **85개 회귀 테스트와 Release 실제 ARW 검사3개가 모두 통과**했다. 실제 샘플 생략 없이 실행했고, 최적화 검사3개 실행/오류/생략 여부를 xUnit 결과로 확인했다. Swift Testing의 별도0개 표시는 XCTest 실행 결과와 구분한다.

| 실제 샘플/처리 | Release 측정 |
| --- | ---: |
| A7M3 JPEG1080×1616, Adobe RGB→sRGB, 앱 캐시 없는 디코딩 | 83.90ms |
| A7M4 JPEG7008×4672, sRGB, 앱 캐시 없는 디코딩 | 481.87ms |
| A7M4 최대 JPEG 추출만 재실행(파일 캐시가 따뜻한 상태) | 4.68ms |
| A7M4 표시 캐시의 동기 조회만 | 0.090ms |
| 준비된 A7M4로 돌아가는 뷰어 선택 처리 | 18.93ms |

위 값은 Intel macOS/Xcode16.4의 단일 CI 실행에서 측정했다. 앱 캐시 없는 디코딩은 추출/디코딩/색 변환/완료 콜백을 포함하지만 OS 파일 캐시는 통제하지 않았다. 뷰어 선택은 명령 처리/비트맵 연결 시간이며 실제 모니터의 합성 완료 시간이 아니다. M1 Pro 실측이나 모든 파일/장치의 속도를 보장하지 않는다. UI 검사에 함께 사용한 JPG는 작은 합성 fixture이므로 그 시간을 실제 카메라 JPG 성능으로 일반화하지 않는다.

썸네일/표시의 평균 sRGB 채널 차이는 두 실제 샘플 모두 최대0.0015 미만(0–1 척도)이었다. 축소 이미지의 모든 픽셀이 원본과 같다는 뜻은 아니다. 확대 후 대기 중에는 같은 CGImage와 실제 전체 픽셀 데이터/색 공간이 유지되는 것을 검사했다. 이후 RAW 현상 결과로 바꾸는 코드 경로도 없다.

측정 원본: [A7M3](../downloads/arw-pipeline-A7M3.json), [A7M4](../downloads/arw-pipeline-A7M4.json), [뷰어](../downloads/arw-ui-evidence.json). 비교용 Debug 결과는 같은 이름의 `-debug.json`으로 별도 저장했다. CFA 제외 후 Debug 추출은52.42ms로 확인했다(제외 전 다른 CI 실행1195ms). 서로 다른 실행의 수치를 통제된 정밀 벤치마크로 해석하지 않는다.

arm64 Release 앱, ad-hoc 서명과 DMG 무결성/마운트 후 앱 검증도 통과했다. 실제 다운로드 HTTP200, 2,627,987바이트, SHA-256 `0021690df99d5c4f601ca1048c2fcf886409dbcdb75fc402a35f7713eed150bf` 일치. [Mac 설치 DMG](https://github.com/NEO-82/Mac-photoselecter/raw/refs/heads/codex/macos-installer-download/downloads/PhotoSelect-0.5.0-arm64.dmg). Apple 공증은 없는 개인 테스트용이다.

 검증에는 큰 JPEG 선택·ICC 우선·Adobe RGB 변환·8방향·캐시/취소·실제 Sony 두 파일·확대 중1.2초 이상 동일 CGImage/픽셀 유지·캐시 전환의 즉시 표시를 포함한다. 설정한 실제 샘플이 없으면 CI는 다운로드/검증에서 실패하며 실제 파일 검사를 생략한 상태로 통과시키지 않는다.

A7M3처럼 센서 해상도 JPEG가 없는 파일은 **RAW 센서 기준100% 초점 정확도를 제공할 수 없다**. JPEG 실제 픽셀1:1과 “RAW 원본 해상도 아님/초점 판별 제한”을 안내한다. RAW 현상이나 업스케일로 이를 숨기지 않는다. 내장 프리뷰가 작은 다른 카메라 변형도 같은 제한을 갖는다. 카메라별 호환성, M1 Pro 실기기의 cold I/O·외장 장치·장시간 메모리 실측은 별도 확인이 필요하다.


## M1 Pro에서 추가 확인

1. 기존 앱을 종료하고0.5.0 DMG의 앱으로 교체한다. 실제 Sony 촬영 폴더에서 같은 사진을 연 뒤 마우스 확대/놓기/누른 채 방향키/더블클릭/ESC를 확인한다.
2. 같은 사진을 수 초 유지해 선명도/색이 뒤늦게 바뀌지 않는지 확인한다. 이전/다음으로 왕복하고 로그의 preview cacheHit/latencyMs를 함께 확인한다. 캐시가 준비되지 않은 첫 사진은 준비 상태가 보일 수 있다.
3. 센서 크기 내장 JPEG가 있는 파일과 작은 JPEG만 있는 파일을 각각 확인한다. 작은 프리뷰를 RAW 센서100%로 오해하지 않도록 HUD의 해상도 제한을 확인한다.
4. 1,500장 이상 폴더에서 연속 탐색과 메모리를 실제 내장SSD/SD/외장장치별로 측정한다. 이번 CI는 장시간 메모리 안정성이나 해당 장치의 cold I/O를 측정한 결과가 아니다.
