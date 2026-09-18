# 복구 안내

이 문서는 앱이 자동으로 해결하지 못하는 상황에서 손으로 되돌리는 방법을 설명합니다.
모든 명령은 Claude를 완전히 종료한 뒤 실행하세요. 삭제 명령은 없습니다. 이동과 링크 교체만 사용합니다.

경로 약어:

```
LIVE="$HOME/Library/Application Support/Claude"
ROOT="$HOME/Library/Application Support/ClaudeProfiles"
```

## 0. 현재 상태 파악

```
ls -la "$HOME/Library/Application Support" | grep -i claude
cat "$ROOT/manifest.json"
cat "$ROOT/journal.json" 2>/dev/null
tail -20 "$ROOT/account-menu.log"
```

- `Claude -> .../profiles/...` 형태면 링크 상태입니다.
- `Claude`가 일반 폴더면 프로필 미등록 상태입니다.
- `journal.json`이 있으면 작업 도중 중단된 것입니다. 앱을 다시 실행하면 자동 복구를 시도하고 결과를 알려 줍니다.

## 1. 앱을 쓰지 않고 원래 상태로 되돌리기

현재 링크가 가리키는 프로필 폴더를 원래 경로로 옮깁니다.

```
readlink "$LIVE"                 # 링크 대상 확인
TARGET="$(readlink "$LIVE")"
rm "$LIVE"                       # 링크만 제거됨. 폴더가 아님을 readlink로 먼저 확인
mv "$TARGET" "$LIVE"
```

`rm`은 링크 파일 하나만 지웁니다. `readlink` 결과가 비어 있으면 링크가 아니므로 실행하지 마세요.

## 2. 링크가 끊어졌거나 사라진 경우

프로필 폴더 목록을 보고 원하는 폴더로 다시 연결합니다.

```
ls "$ROOT/profiles"
ln -s "$ROOT/profiles/<폴더이름>" "$LIVE"
```

앱에서는 프로필을 선택하면 같은 일을 합니다.

## 3. 백업에서 되돌리기

첫 등록 때 만든 백업은 `$ROOT/backups/Claude-<날짜>`에 있습니다. 원본과 같은 내용의 복제본입니다.

```
ls "$ROOT/backups"
mv "$LIVE" "$LIVE.broken-$(date +%Y%m%d-%H%M%S)"   # 링크나 폴더를 이름만 바꿔 보관
mv "$ROOT/backups/Claude-<날짜>" "$LIVE"
```

백업은 clone 방식이라 원본과 블록을 공유합니다. 논리적 실수는 되돌릴 수 있지만 디스크 장애에 대한 백업은 아닙니다. 중요한 데이터는 Time Machine 등 별도 백업을 유지하세요.

## 4. manifest가 깨진 경우

`manifest.json`을 다른 이름으로 옮기고 앱을 실행하면 빈 상태로 시작합니다.
`profiles/` 안의 폴더는 "미등록 폴더 가져오기"로 다시 등록할 수 있습니다.

```
mv "$ROOT/manifest.json" "$ROOT/manifest.json.bak"
```

## 5. 작업 도중 앱이 종료된 경우

앱을 다시 실행하면 `journal.json`을 읽고 다음처럼 처리합니다.

| 작업 | 상황 | 처리 |
|---|---|---|
| 첫 등록 | 이동 전 | 원본 유지. 불완전할 수 있는 백업 폴더 경로를 안내 |
| 첫 등록 | 이동 후 링크 전 | 링크를 만들고 등록 마무리 |
| 전환 | 링크 교체 후 | 링크 대상에 맞춰 현재 프로필 기록 갱신 |
| 전환 | 링크 없음 | 대상 프로필로 다시 연결 |
| 되돌리기 | 링크 제거 후 이동 전 | 프로필 폴더를 원래 경로로 이동 |

판단할 수 없는 상태면 journal을 남기고 수동 복구를 안내합니다. 이때는 0번의 명령으로 상태를 확인하고 1번 또는 2번을 적용하세요.

## 6. 앱이 "프로세스가 실행 중"이라며 거부하는 경우

```
ClaudeSwitch.app/Contents/MacOS/ClaudeSwitch --scan
```

표시된 프로세스를 확인합니다. Claude 창의 확인 대화상자, 데이터 폴더를 현재 디렉터리로 잡고 있는 터미널, Claude가 띄운 MCP 서버가 흔한 원인입니다. 앱은 강제 종료하지 않으므로 직접 종료한 뒤 다시 시도하세요.

## 7. 프로필 폴더 정리

프로필 폴더와 백업은 앱이 절대 삭제하지 않습니다. 더 이상 필요 없으면 Finder에서 직접 삭제하세요.
현재 링크가 가리키는 폴더는 삭제하면 안 됩니다. `readlink "$LIVE"`로 먼저 확인하세요.
