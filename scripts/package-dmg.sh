#!/bin/bash
# 설치용 DMG를 만든다. 결과: build/ClaudeSwitch-<버전>.dmg
# 사용법: scripts/package-dmg.sh   (먼저 scripts/build.sh 로 build/ClaudeSwitch.app 을 만든다)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/ClaudeSwitch.app"
[[ -d "$APP_DIR" ]] || "$ROOT/scripts/build.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")"
DMG="$ROOT/build/ClaudeSwitch-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/ClaudeSwitch.app"
chmod -R a+rX "$STAGING/ClaudeSwitch.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/설치 안내.txt" <<'TXT'
Claude Switch 설치

1. ClaudeSwitch.app 을 Applications 폴더로 끌어다 놓습니다.
2. 처음 열 때 "확인되지 않은 개발자" 경고가 나오면 Finder 에서 앱을 우클릭한 뒤 "열기"를 선택합니다.
   macOS 15 이상에서는 시스템 설정 > 개인정보 보호 및 보안 > "그래도 열기" 를 눌러야 할 수 있습니다.
3. Claude 를 실행하고 Claude 메뉴 > 서비스 > Claude Switch (기본 단축키 Cmd+Ctrl+S) 로 프로필 창을 엽니다.

첫 실행 후 "기존 Claude 데이터를 첫 프로필로 등록" 을 하면 현재 로그인 상태가 첫 프로필이 됩니다.
자세한 내용: https://github.com/lee-byeoksan/claude-switch
TXT

hdiutil create -volname "Claude Switch" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
echo "DMG 생성: $DMG"
