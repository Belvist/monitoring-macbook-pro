#!/bin/bash
# Build the SwiftUI executable locally with the selected macOS SDK.
# Called both by the app launcher and by the explicit build command.
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
RES="$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/.MacScopeNative"
LOG="$HOME/Library/Logs/MacScope-build.log"
mkdir -p "$(dirname "$LOG")"

# xcrun --find swiftc returns the underlying binary. Unlike /usr/bin/swiftc,
# direct invocation may not infer the active macOS SDK. Supply it explicitly.
XCRUN="${MACSCOPE_XCRUN:-/usr/bin/xcrun}"
if [ ! -x "$XCRUN" ]; then
  echo "Не найдены инструменты разработчика. Выполни: xcode-select --install" >&2
  exit 78
fi

SDK="$($XCRUN --sdk macosx --show-sdk-path)"
SWIFTC="$($XCRUN --sdk macosx --find swiftc)"
if [ ! -d "$SDK" ] || [ ! -x "$SWIFTC" ]; then
  echo "macOS SDK или компилятор Swift недоступен. Проверь: xcode-select -p" >&2
  exit 78
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Неподдерживаемая архитектура Mac: $ARCH" >&2; exit 78 ;;
esac
# Do NOT use the host OS version here. Some toolchains select a newer target
# for which the installed Swift standard library cannot be found.
TARGET="${ARCH}-apple-macosx13.0"
TMP="$APP/Contents/MacOS/.MacScopeNative.tmp.$$"
trap 'rm -f "$TMP"' EXIT

{
  echo "Date: $(date)"
  echo "Swift: $SWIFTC"
  "$SWIFTC" --version
  echo "SDK: $SDK"
  echo "Target: $TARGET"
  echo "Compiling native SwiftUI executable..."
  "$SWIFTC" -swift-version 5 -Onone \
    -sdk "$SDK" -target "$TARGET" \
    "$RES/CoreLogic.swift" \
    "$RES/MacCollector.swift" \
    "$RES/MacScopeApp.swift" \
    -framework SwiftUI -framework AppKit -framework Combine \
    -o "$TMP"
} >"$LOG" 2>&1 || {
  echo "Ошибка компиляции. Последние строки лога:" >&2
  tail -n 35 "$LOG" >&2
  echo "Полный лог: $LOG" >&2
  exit 1
}

chmod 755 "$TMP"
mv -f "$TMP" "$BIN"
trap - EXIT
printf 'MacScope: SwiftUI executable built successfully (%s).\n' "$TARGET"
