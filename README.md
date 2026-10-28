# GlaNce

macOS 메뉴바에서 바로 여는 거울 카메라 앱.
메뉴바 아이콘을 누르면 말풍선 팝오버로 카메라가 켜지고, 얼굴 확인과 사진 촬영을 할 수 있다.

## 기능

- 메뉴바 아이콘 클릭 → 말풍선 팝오버로 카메라 미리보기 (16:9)
- 거울처럼 좌우반전된 화면, 저장 사진도 동일하게 반전
- 팝오버를 잡고 끌어내리면 항상 위에 떠 있는 창으로 분리
- 스페이스바 또는 셔터 버튼으로 촬영, 기본 `사진/GlaNce` 폴더에 JPG 저장
- 저장 위치 변경 가능 (앱을 다시 켜도 유지)
- 사진 좌하단에 날짜와 도시 이름 워터마크 (예: `2026.10.27   SEJONG`)
- 팝오버나 분리 창이 닫히면 카메라 자동 종료
- 분리 창 사용 중에는 제어 센터 비디오 효과(센터 스테이지, 인물 사진 모드 등) 사용 가능

## 요구 사항

- macOS 13 Ventura 이상
- Apple Silicon, Intel 모두 지원

## 설치

### 방법 1. 앱 다운로드

1. [Releases](../../releases)에서 `GlaNce.zip` 다운로드 후 압축 해제
2. `GlaNce.app`을 응용 프로그램 폴더로 이동
3. 처음 실행하면 "확인되지 않은 개발자" 경고가 뜬다.
   시스템 설정 > 개인정보 보호 및 보안 > 하단의 **그래도 열기** 클릭
   (또는 터미널에서 `xattr -dr com.apple.quarantine /Applications/GlaNce.app`)

Apple 개발자 인증서로 공증하지 않은 개인 프로젝트라 처음 한 번 이 과정이 필요하다.

### 방법 2. 소스에서 빌드

Xcode 없이 Command Line Tools만 있으면 된다.

```bash
xcode-select --install          # 처음 한 번만
git clone https://github.com/Hong-Hyun-00/GlaNce.git
cd GlaNce
./build.sh                      # ~/Applications/GlaNce.app 생성
open ~/Applications/GlaNce.app
```

## 사용법

| 동작 | 방법 |
|---|---|
| 카메라 열기/닫기 | 메뉴바 카메라 아이콘 클릭 |
| 사진 촬영 | 스페이스바 또는 우하단 셔터 버튼 |
| 저장 폴더 열기 | 우하단 폴더 버튼 → 폴더 열기 |
| 저장 위치 변경 | 우하단 폴더 버튼 → 저장 위치 변경… |
| 떠 있는 창으로 분리 | 팝오버 영상을 잡고 아래로 드래그 |
| 앱 종료 | 우상단 전원 버튼 |

처음 실행 시 카메라와 위치 권한을 요청한다. 위치를 거부하면 워터마크에 날짜만 들어간다.
로그인할 때 자동으로 켜려면 시스템 설정 > 일반 > 로그인 항목에 `GlaNce.app`을 추가한다.

## 구조

```
GlaNce.swift   앱 전체 소스 (AppKit NSStatusItem + NSPopover, SwiftUI 뷰, AVFoundation, CoreLocation)
Info.plist     번들 정보, 카메라·위치 권한 문구, Dock 아이콘 숨김(LSUIElement)
make_icon.swift  앱 아이콘(반사된 g) 1024px PNG 생성
build.sh       swiftc로 Universal 빌드 → 아이콘 .icns 생성 → .app 번들 생성 → ad-hoc 서명
```

## 기술 메모

- `AVCaptureSession` + `AVCaptureVideoPreviewLayer`로 미리보기, `AVCapturePhotoOutput`으로 촬영
- 좌우반전은 세션이 실제로 시작된 뒤(`didStartRunningNotification`) preview connection에 적용
- 저장 시 Core Image로 16:9 중앙 크롭 → 좌우반전 → Core Graphics로 워터마크 합성
- 위치는 `CLLocationManager.requestLocation()` 1회 요청 후 `CLGeocoder`로 도시 이름 변환
