#!/bin/bash
# Claude Switch 빌드 스크립트.
# 사용법: scripts/build.sh [--test] [--install]
#   --test    빌드 전에 테스트 실행
#   --install ~/Applications/ClaudeSwitch.app 으로 설치하고 서비스 메뉴를 등록한 뒤 실행
# 결과: build/ClaudeSwitch.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$ROOT/.build"
MODULE_CACHE="$ROOT/.build/module-cache"
APP_DIR="$ROOT/build/ClaudeSwitch.app"
APP_NAME="ClaudeSwitch"

# debug(test)와 release가 같은 모듈 캐시를 쓰면 캐시가 오염되어 빌드가 실패한 적이 있어 구성별로 분리한다.
mkdir -p "$MODULE_CACHE/debug" "$MODULE_CACHE/release"
DEBUG_FLAGS=(--scratch-path "$SCRATCH" -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE/debug")
RELEASE_FLAGS=(-c release --scratch-path "$SCRATCH" -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE/release")

cd "$ROOT"
# 아이콘은 로컬에 설치된 Claude.app 아이콘에 전환 배지를 합성해 만든다. 저장소에는 포함하지 않는다.
CLAUDE_ICON="/Applications/Claude.app/Contents/Resources/electron.icns"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" && -f "$CLAUDE_ICON" ]]; then
    swift "$ROOT/scripts/make-icon.swift" "$CLAUDE_ICON" "$ROOT/Resources/AppIcon.icns"
fi

if [[ " $* " == *" --test "* ]]; then
    swift test "${DEBUG_FLAGS[@]}"
fi

swift build "${RELEASE_FLAGS[@]}"
BIN="$(swift build "${RELEASE_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# 버전 옆에 표시할 커밋 해시. 커밋되지 않은 변경이 있으면 -dirty 를 붙인다.
GIT_HASH="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then GIT_HASH="$GIT_HASH-dirty"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_HASH" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ClaudeSwitchCommit string $GIT_HASH" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 로컬 실행용 ad-hoc 서명. 배포용 서명이 아니다.
codesign --force --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"
echo "빌드 완료: $APP_DIR"

if [[ " $* " == *" --install "* ]]; then
    INSTALL_DIR="$HOME/Applications"
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    mkdir -p "$INSTALL_DIR"
    pkill -f "MacOS/$APP_NAME\$" || true
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
    # 빌드 폴더의 복사본이 아니라 설치본만 LaunchServices에 남도록 빌드 복사본은 지운다.
    "$LSREG" -u "$APP_DIR" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR"
    "$LSREG" -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
    /System/Library/CoreServices/pbs -update || true
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "설치 완료: $INSTALL_DIR/$APP_NAME.app"
fi
