#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/MacScope.app"

if ! "$APP/Contents/Resources/build-native.sh"; then
    echo
    echo "Сборка не завершилась. Лог: ~/Library/Logs/MacScope-build.log"
    echo "Если SDK отсутствует: xcode-select --install"
    echo "Если ошибка сохраняется — пришли вывод команд:"
    echo "  xcode-select -p"
    echo "  xcrun --sdk macosx --show-sdk-path"
    echo "  xcrun swiftc --version"
    echo
    read -r -p "Нажми Enter, чтобы закрыть окно..." _ || true
    exit 1
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" || echo "Подпись не выполнена; исполняемый файл уже собран."
fi
open "$APP"
echo "MacScope собран. В будущем открывай MacScope.app двойным кликом."
