#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swift test --scratch-path .build/check 2>&1 | tee build/core-tests.log
if [[ "$(uname -s)" == Darwin ]]; then
    /usr/bin/plutil -lint Resources/Info.plist Resources/local.boggart.helper.plist
    swift build --configuration release --scratch-path .build/check-release 2>&1 | tee build/macos-release-build.log
    swift build --configuration release --scratch-path .build/check-validation -Xswiftc -DBOGGART_HARDWARE_TESTING 2>&1 | tee build/macos-validation-build.log
    echo 'Компиляция обоих вариантов закончена. Приложение и помощник не запускались, настройки сна не менялись.'
else
    while IFS= read -r -d '' file; do
        swiftc -frontend -parse -target arm64-apple-macosx13.0 "$file"
    done < <(find Sources -name '*.swift' -print0)
    echo 'Проверены ядро и грамматика macOS-файлов. Apple SDK и аппаратные проверки здесь недоступны.'
fi
python3 Scripts/audit.py
