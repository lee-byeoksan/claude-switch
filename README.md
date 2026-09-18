# Claude Switch

macOS에서 Claude Desktop 계정을 프로필 단위로 전환하는 도구입니다.
Claude.app은 하나만 설치하고 원본을 수정하지 않습니다.

## 동작 원리

- Claude는 `~/Library/Application Support/Claude`를 데이터 폴더로 사용합니다.
- Claude Switch는 이 경로를 symlink로 바꾸고, 링크 대상을 프로필 폴더(`~/Library/Application Support/ClaudeProfiles/profiles/...`)로 전환합니다.
- 전환할 때 Claude에 정상 종료를 요청하고, 관련 프로세스가 모두 사라진 것을 확인한 뒤에만 링크를 바꾸고 Claude를 다시 실행합니다. 강제 종료는 하지 않습니다.
- 로그인 정보는 프로필 폴더 안에 있고, 암호화 키는 키체인 항목 하나를 모든 프로필이 공유합니다. 키체인을 읽거나 쓰지 않습니다.

## 진입점

- Claude 메뉴 > 서비스 > **Claude Switch** (단축키 기본 Cmd+Ctrl+S, 설정에서 변경 가능). Claude가 앞에 있을 때만 표시됩니다.
- `~/Applications/ClaudeSwitch.app`을 다시 열면 선택 창이 열립니다.
- 메뉴 막대 아이콘은 기본으로 꺼져 있으며 설정에서 켤 수 있습니다.

선택 창에서는 프로필을 Active, Inactive, Removed 세 상태로 관리합니다. Removed는 폴더를 macOS 휴지통으로 옮기며 영구 삭제하지 않습니다.

## 용량

새 프로필은 Cowork VM 이미지(약 10 GB)를 다시 내려받는 대신, 다른 프로필의 이미지를 APFS clone으로 복사받습니다(자동 복제). 설정 > 용량 정리에서 프로필별 점유량, 캐시 삭제, VM 이미지 삭제, 백업 정리를 할 수 있습니다. 자세한 조건은 [사용 안내](docs/usage.ko.md)를 보세요.

## 빌드와 설치

요구 사항: macOS 13 이상, Xcode 16 이상 (Swift 5.9 이상).

```
scripts/build.sh --test --install
```

- `build/ClaudeSwitch.app`을 만들고 `~/Applications/ClaudeSwitch.app`으로 설치한 뒤 서비스 메뉴를 등록하고 실행합니다.
- `scripts/package-dmg.sh`는 배포용 `build/ClaudeSwitch-<버전>.dmg`를 만듭니다. ad-hoc 서명이라 처음 열 때 우클릭 > 열기 또는 시스템 설정의 "그래도 열기"가 필요합니다.
- 설정 팝오버 하단에 버전과 빌드 커밋 해시가 표시됩니다.
- ad-hoc 서명이라 처음 열 때 Finder에서 우클릭 후 "열기"가 필요할 수 있습니다.

## 문서

- [사용 안내](docs/usage.ko.md)
- [복구 안내](docs/recovery.ko.md)
- [조사·테스트 결과와 제한 사항](docs/test-results.ko.md)

## 구조

| 경로 | 내용 |
|---|---|
| `Sources/SwitchCore` | 프로필 등록·전환·복구 로직, 파일 조작, 프로세스 감시. AppKit 비의존 |
| `Sources/SwitchUI` | 메뉴·선택 창·런처 정책의 순수 모델. 로직 실행 없이 테스트 가능 |
| `Sources/ClaudeSwitch` | AppKit 앱: 선택 창, 서비스 핸들러, 설정, Claude 감시 |
| `Sources/CSystemShims` | libproc, clonefile, renamex_np 등 C 헤더 노출 |
| `Tests/` | XCTest. 임시 폴더와 가짜 Claude 컨트롤러로 실행 |
| `Resources/Info.plist` | LSUIElement, NSServices 등록 |
| `scripts/make-icon.swift` | Claude.app 아이콘에 전환 배지를 합성해 `Resources/AppIcon.icns` 생성. 생성물은 저장소에 포함되며 다시 만들 때만 실행 |

## 진단

```
~/Applications/ClaudeSwitch.app/Contents/MacOS/ClaudeSwitch --scan
```

현재 경로 상태와 Claude 관련 프로세스를 출력합니다.

## 제한 사항

- 동시 실행은 지원하지 않습니다. 전환에는 Claude 재실행이 필요합니다.
- 새 프로필은 빈 상태로 시작하므로 확장 프로그램과 Cowork VM 번들(약 10 GB)을 다시 내려받습니다.
- Cowork 작업 진행 여부는 감지하지 못합니다. 종료 전 안내만 제공합니다.
- Claude 업데이트 이후의 동작은 보장하지 않습니다. 자세한 내용은 [test-results.ko.md](docs/test-results.ko.md)를 보세요.

## 라이선스

MIT
