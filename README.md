# Buggy Client

MS2 전용 클라이언트의 설치 및 업데이트 파일을 관리하는 비공식 배포 저장소입니다.
개인적 범위 내에서 사용자에게 동일한 클라이언트 환경을 제공하고, 변경된 파일만 선별하여 자동으로 업데이트를 실행합니다.

## 이용 방법

클라이언트 파일은 전용 런처를 통해 설치하거나 업데이트하는 것을 권장합니다.

1. 전용 런처 실행
2. 클라이언트 설치 경로 지정
3. 다운로드 또는 업데이트 실행
4. 파일 검사 완료 후 게임 실행

GitHub Release의 개별 파일을 직접 내려받거나 수정할 필요는 없습니다.

## 현재 배포 버전

* 클라이언트 버전: `3.0.0`
* 운영체제: Windows
* 배포 방식: GitHub Release
* 업데이트 정보: `latest.json`
* 버전별 파일 정보: `manifests/`

## 주의사항

* 배포 파일을 임의로 수정하면 실행 또는 업데이트가 실패할 수 있습니다.
* 설치 중에는 런처를 종료하거나 클라이언트 폴더를 변경하지 마세요.
* 업데이트 전에 실행 중인 게임 클라이언트를 종료하세요.
* 문제 발생 시 런처의 파일 검사 또는 복구 기능을 먼저 실행하세요.
* 이 저장소의 파일을 별도의 장소에 재배포하지 마세요.

## 저작권 안내

이 프로젝트는 비공식 유지보수 및 호환 환경 제공을 목적으로 합니다.

메이플스토리2 및 관련 명칭, 프로그램, 그래픽, 음원과 게임 데이터에 관한 권리는 각 권리자에게 있습니다. 이 저장소는 Nexon 또는 원저작권자와 공식적인 제휴 관계에 있지 않습니다.

배포 파일은 상업적 목적으로 제공되지 않으며, 접근 권한이 부여된 사용자의 개인적인 이용을 전제로 합니다.

---

## English

# Buggy Client Distribution

This is an unofficial distribution repository for installing and updating a dedicated MapleStory 2 client.

The client should be installed and updated through the dedicated launcher. The launcher compares local files with the distribution manifest and downloads only files that are missing or have changed.

### Current release

* Client version: `3.0.0`
* Platform: Windows
* Distribution: GitHub Releases
* Update metadata: `latest.json`
* Version manifests: `manifests/`

### Important notice

Do not manually modify or redistribute the distributed files. Close the game client before starting an update.

This is an unofficial project and is not affiliated with Nexon or the original rights holders. All rights to MapleStory 2 and its related software, assets, music, and game data belong to their respective owners. The files are provided without commercial purpose for limited personal use.
