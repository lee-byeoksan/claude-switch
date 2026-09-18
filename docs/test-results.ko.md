# 조사 결과, 테스트 결과, 남은 제한 사항

작성일: 2026-09-18
대상: Claude Desktop 2.2553.0 (com.anthropic.claudefordesktop), macOS 26.5.2, Xcode 16.4 / Swift 6.1.2

## 1. 조사 결과 (app.asar를 임시 폴더에 추출해 읽기 전용으로 분석)

| 항목 | 확인 내용 | 근거 |
|---|---|---|
| userData 기본 경로 비교 | `path.normalize(app.getPath("userData"))`와 `~/Library/Application Support/Claude` 문자열 비교. symlink는 통과 | index.pre.js의 `J1()` |
| 파일 접근 헬퍼(SafeRoot) | 루트 경로의 symlink를 최대 40단계 따라간 뒤 realpath로 연다. UNC/WSL 대상만 거부 | 공통 청크의 `ai()`, `SafeRoot.open` |
| 경계 아래 symlink 검사 | 등록된 루트 아래의 중간 구성요소가 symlink이면 거부. 오류 문구에 "config root 전체를 symlink로 옮기는 것은 지원"이라고 명시. 루트 자체는 검사하지 않음 | `xi()`, `Ude()` |
| 로그인 상태 저장 위치 | `<userData>/config.json`의 `oauth:tokenCache`, `oauth:tokenCacheV2`, `lastKnownAccountUuid` 키와 Chromium Cookies. 값은 확인하지 않음 | 키 이름만 열람 |
| 키체인 | 계정별 항목 없음. Electron safeStorage와 Cookies 암호화 키인 "Claude Safe Storage" 하나만 존재하며 앱 이름 기준이라 모든 프로필이 공유 | `security dump-keychain` 메타데이터 |
| Cowork 세션 데이터 | `<userData>/local-agent-mode-sessions/<accountUuid>/<orgUuid>` 로 계정별 분리. 사용자 파일 루트는 `~/Documents/Claude` 등 userData 밖 | 코드와 폴더 구조 |
| Cowork VM 번들 | `vm_bundles/claudevm.bundle`에 읽기 전용 이미지(rootfs, vmlinuz, initrd)와 상태(sessiondata.img, efivars.fd, VM 식별자)가 섞여 있음. 앱 패키지에 압축 이미지 없음 | 폴더 내용과 코드 |
| 앱 내 multiAccount 기능 | 렌더러 플래그에 `multiAccount: unavailable`로 존재. 향후 공식 지원 가능성 있음 | 실행 인자 |
| 프로세스 구성 | Claude 본체, Helper 4~6개, chrome_crashpad_handler, MCP 확장용 `disclaimer`와 그 자식(uv/python). `chrome-native-host`는 Chrome이 띄우며 데이터 폴더 파일을 열지 않음 | ps, libproc 스캔 |

결론: symlink로 userData 루트를 교체하는 방식은 코드상 허용되며, 프로필 폴더 내부에는 symlink를 두지 않는다. VM 번들은 프로필 간 공유하지 않는다.

## 2. 설계 요약

- `~/Library/Application Support/Claude`를 symlink로 두고 대상을 `ClaudeProfiles/profiles/<이름-id>/`로 전환.
- 전환 순서: 잠금 → 상태 검증 → Claude 정상 종료 요청(AppleEvent) → 프로세스 소멸 확인(실행 파일 경로 + 열린 파일 스캔) → journal 기록 → 임시 링크 생성 후 rename으로 원자적 교체 → 교체 직후 재검사(교체 전에 시작된 프로세스가 있으면 롤백) → manifest 갱신 → Claude 실행.
- 첫 등록: APFS `clonefile`로 백업 복제 → 항목 수 검증 → `renamex_np(RENAME_EXCL)`로 이동 → 링크 생성. 링크 실패 시 이동을 되돌림.
- 되돌리기: 링크를 별도 이름으로 옮긴 뒤 프로필 폴더를 원래 경로로 이동. 실패 시 링크 복원.
- 삭제 연산 없음. 유일한 unlink 대상은 앱이 만든 symlink 파일이며 lstat으로 symlink임을 확인한 뒤에만 지운다.
- 모든 폴더 0700, 기록 파일 0600. flock 잠금, journal 기반 시작 시 복구, 단일 인스턴스 확인.

## 3. 자동 테스트 (임시 폴더, 가짜 Claude 컨트롤러)

`scripts/build.sh --test`

결과: 32개 테스트 통과, 실패 0.

AccountCore (26개)
- 등록: 백업 생성과 검증, 이동, 링크, 권한 0700, 계정 힌트 표시, 종료 요청 1회와 재실행 1회
- 등록 거부: 이미 링크 상태, Claude가 종료되지 않음(원본과 백업 폴더 모두 변경 없음)
- A↔B↔A 전환과 데이터 분리(각 프로필의 marker 파일이 섞이지 않음)
- 전환 거부: 프로세스 잔존, 파일을 열고 있는 프로세스, 일반 폴더 상태, 알 수 없는 대상 링크
- 제외 프로세스(chrome-native-host) 무시
- 전환 도중 Claude 재실행(경쟁 조건) 감지 시 롤백
- 끊어진 링크 재연결
- 등록 해제(현재 프로필 차단, 폴더 보관), 재등록, 이름 변경(폴더명 유지, 잘못된 이름 거부), 미등록 폴더 목록과 가져오기
- 되돌리기(일반 폴더 복원, 다른 프로필 유지, 임시 링크 잔존 없음)
- 잠금 충돌, 미완료 journal이 있으면 작업 차단
- 복구: 등록 중단(이동 후 링크 전), 등록 중단(이동 전, 불완전 백업은 삭제하지 않고 안내), 전환 중단(manifest 동기화, 오래된 임시 링크 정리), 되돌리기 중단
- 파일 안전성: 일반 폴더 위에 링크를 덮어쓰지 않음, 기존 대상 위로 이동하지 않음, clone 복제본의 독립성, 잘못된 config.json 무시

MenuModel (6개, 로직 실행 없이 UI 모델만 검증)
- 링크 상태 메뉴 구성(현재 프로필 체크·비활성, 현재 프로필 등록 해제 차단, 보관 프로필 재등록)
- 미등록 상태(등록 항목만 노출, 프로필 추가 비활성)
- 작업 중 상태(변경 항목 비활성)
- 미등록 폴더와 미완료 작업 표시
- 상태 읽기 실패 시에도 종료 항목 제공
- 긴 프로필 이름 줄임

## 4. 빌드된 앱 확인

- `build/ClaudeSwitch.app` 생성, ad-hoc 서명 검증 통과.
- 실제 시스템에서 `--scan` 실행: 실행 중인 Claude 본체와 Helper, disclaimer, 데이터 폴더 파일을 열고 있는 MCP 프로세스(uv/python)를 정확히 나열함. Spotlight 인덱서(mdworker_shared)가 파일 보유 목록에 잡혀 시스템 경로 프로세스를 제외하도록 수정함.
- 테스트 모드(`CLAUDE_SWITCH_APP_SUPPORT_DIR` 환경 변수, 실제 Claude를 건드리지 않음)로 가짜 데이터 폴더에 대해 앱을 실행: 상태 항목 생성, 충돌 없이 유지됨.
- 메뉴를 실제로 열어 항목을 눌러 보는 자동화는 이 세션에서 AppleScript와 화면 캡처 권한이 없어 수행하지 못함. 메뉴 구성은 MenuModel 테스트로 검증했고, 실제 클릭 흐름은 사용자 확인이 필요함.

### 발견된 결함과 수정

- 첫 실사용에서 메뉴 항목을 눌러도 아무 일도 일어나지 않았다. 원인은 `#selector(ActionTarget.perform(_:))`가 NSObject의 `performSelector:`로 해석된 것. 메서드를 `invokeMenuAction(_:)`으로 바꿔 해결했다.
- 재발 방지로 `--self-test-menu` 명령을 추가했다. NSMenu 경로로 활성 항목을 전송해 핸들러 수신 개수를 비교한다. 결과: 전송 5, 수신 5.

### 런처 확장 (프로필 선택 창, 서비스 메뉴, 종료 감지)

- `LauncherPolicy`(순수 상태 기계) 6개 테스트: 시작 시 미실행이면 창 표시, Claude 실행 시 창 숨김, 종료 후 유예 뒤 재확인, 전환 중 종료 무시, 자동 표시 설정 끔, 사용자가 닫은 창 재숨김 없음.
- `PanelModel` 5개 테스트: 현재 프로필 체크와 실행 중 비활성, 미실행 시 현재 프로필 선택 가능, 작업 중 비활성, 미등록 안내, 오류 상태.
- 관리 전용 메뉴와 설정 토글 1개 테스트.
- `--self-test-menu`: 전송 6, 수신 6.
- 서비스 등록 확인: `pbs -dump`에 `switchProfile` 서비스가 `NSRequiredContext.NSApplicationIdentifier = com.anthropic.claudefordesktop`로 등록됨. 처음에는 빌드 폴더 복사본을 가리켜 `lsregister -u`로 정리하고 설치본(`~/Applications`)을 가리키도록 맞춤. build.sh `--install`이 같은 절차를 수행함.
- 사용자 확인 완료(2026-09-18): 선택 창에서 프로필 전환 동작, Claude 종료 후 선택 창 자동 표시 동작.
- 사용자 확인에서 발견된 결함: 선택 창의 "관리" 버튼이 빈 풀다운 메뉴만 열었음. 일반 버튼에서 관리 메뉴를 띄우도록 수정.
- Claude 메뉴 > 서비스 항목 표시와 로그인 항목 승인은 아직 사용자 확인 전.

### 선택 창 재설계 (SwiftUI, Active/Inactive 탭, Removed)

- `PanelModel` 6개 테스트: 현재 프로필 최상단 정렬과 계정 힌트, 현재 프로필의 보관·제거 차단, 미실행 시 현재 프로필 실행 가능, Inactive 행 동작, 작업 중 비활성, 안내 문구 3종.
- `moveToTrash` 2개 테스트: 현재 프로필 거부, 폴더는 휴지통(테스트에서는 가짜 휴지통)으로 이동하고 내용 유지, 백업 폴더 유지, Inactive 프로필도 제거 가능.
- Removed는 영구 삭제가 아니라 macOS 휴지통 이동이며 확인 대화상자를 거친다.
- 앱 아이콘은 `scripts/make-icon.swift`가 로컬 Claude.app 아이콘에 전환 배지를 합성해 만들며 저장소에는 포함하지 않는다. 비상업 개인 용도라는 사용자 결정에 따른 것으로, 공개 배포 시 상표 문제는 사용자가 판단해야 한다.
- 총 47개 테스트 통과. SwiftUI 화면 자체의 렌더링은 사용자 확인이 필요하다.

### 용량 정리와 VM 이미지 복제

- 코드 확인: delta 업데이트는 기존 `rootfs.img.zst`를 `.deltabase`로 이름을 바꿔 기준으로 삼고, 풀어서 delta를 적용한 뒤 sha256으로 검증하고 새 `.zst`를 저장한다. `.zst`가 없으면 전체 다운로드로 떨어진다. 업데이트는 실행 중 수정된 rootfs.img가 아니라 `.zst`에서 재구성하므로, 실행 중 rootfs 변경은 업데이트마다 버려진다.
- 파일 시간 확인: Cowork 실행마다 rootfs.img, sessiondata.img, vmIP, .cowork-adopted가 바뀐다. 따라서 symlink 공유는 불가하고 clone 방식을 택했다.
- 복제 단위: 이미지 4개, 압축 캐시 4개, 마커 8개. 세션 데이터·efivars·VM 식별자는 제외. 이미지와 캐시를 먼저, 마커를 마지막에 복사해 중간에 끊겨도 마커가 새 버전을 주장하지 않는다.
- 핵심 테스트 10개: 계획 대상 선정(마커 다름·번들 없음), 원본 없음, 원본 대체(현재 프로필에 번들 없으면 가장 최근 마커), 복제 내용과 세션 보존, 원본 사용 중 미루기, 선택 대상만 복제, 용량 분류, 캐시 삭제 조건, VM 이미지 삭제 범위와 현재 프로필 차단, 백업 휴지통 이동. 화면 모델 3개.
- 실제 시스템: 자동 복제가 board 프로필의 이미지(마커 8825…)를 3개 프로필에 복사했고 여유 공간은 40 GB 그대로였다(clone 확인). 현재 프로필은 Claude 실행 중이라 제외됐다.
- 미검증: 복제된 번들만 있는 프로필에서 Cowork를 켰을 때 Claude가 다운로드 없이 VM을 부팅하는지. 사용자가 새 프로필에서 Cowork를 켜 확인해야 한다.

## 5. 실제 데이터 연결 상태

실제 `~/Library/Application Support/Claude`(약 12 GB)는 아직 건드리지 않았다. 첫 등록은 사용자의 Claude를 종료해야 하므로 사용자가 메뉴에서 직접 실행하도록 남겨 두었다. 실행 전 준비된 보호 수단:
- 등록 과정에서 APFS clone 백업이 자동 생성됨(즉시, 추가 용량 거의 없음)
- 되돌리기 메뉴와 `docs/복구안내.md`의 수동 절차
- 디스크 여유 약 53 GB (새 프로필당 VM 번들 약 10 GB 추가 필요)

## 6. 미검증 항목 (명확히 미검증)

- symlink 상태에서 로그인이 유지되는지 (코드 분석상 가능하나 실제 로그인으로 확인하지 않음)
- 새 프로필에서 로그인 후 Cowork 사용, 다른 프로필로 전환, 다시 돌아왔을 때 Cowork 세션과 VM이 정상 동작하는지
- Cowork 사용 중 정상 종료 요청 시 Claude가 대화상자를 띄우는지, 띄우면 앱은 시간 초과로 거부함(강제 종료 없음)
- Claude 업데이트 후에도 같은 경로 검사와 동작이 유지되는지. 업데이트 후 동작을 보장하지 않음

## 7. 알려진 제한 사항

- 서비스 항목은 Claude 메뉴 > 서비스 하위에 한 단계 들어가 있다. Claude 메뉴 최상위에 넣으려면 코드 주입이 필요해 제외했다.
- "Claude가 실행될 때 런처 자동 실행" 훅은 macOS에 없다. 로그인 시 실행으로 상주시키는 방식으로 대체했다.

- 동시 실행 미지원. 한 번에 한 프로필만 연결됨.
- 새 프로필은 빈 상태에서 시작하므로 확장 프로그램, 설정, VM 번들(약 10 GB)을 다시 내려받음.
- Cowork 작업 진행 여부를 감지하지 못함. 종료 전 안내만 제공.
- 데이터 폴더 파일을 열고 있는 프로세스(터미널 cwd 포함)가 있으면 전환을 거부함. 이는 의도된 보수적 동작.
- 백업은 clone 방식이라 원본과 블록을 공유함. 디스크 장애 대비 백업이 아님.
- 계정 힌트는 Claude가 기록한 UUID 앞 8자리이며 이메일이 아님. 프로필 이름과 실제 계정의 일치는 사용자가 확인해야 함.
- Claude 자체의 `multiAccount` 기능이 활성화되면 이 방식과 충돌할 수 있음.
- 앱은 ad-hoc 서명이라 처음 열 때 Gatekeeper 확인이 필요함.
- 프로세스 감지는 실행 파일 경로와 열린 파일 기준이라, 데이터 폴더 밖에서 실행되고 파일도 열지 않은 MCP 서버 잔여 프로세스는 감지하지 못함. 이런 프로세스는 데이터 폴더에 쓰지 않으므로 전환에 영향은 없음.

## 8. 초안 관련

요청에 언급된 `work/AccountMenu.swift` 초안은 작업 폴더에 존재하지 않았다(work/에는 무관한 orca 저장소만 있음). 새로 설계했다.
