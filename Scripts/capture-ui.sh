#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRATCH="$ROOT/.build/ui-acceptance"
swift build -c release --scratch-path "$SCRATCH" --product Boggart \
    -Xswiftc -DBOGGART_UI_TESTING -Xswiftc -DBOGGART_PERSONAL_BUILD -Xswiftc -DBOGGART_HARDWARE_TESTING > build/ui-build.log 2>&1 || { tail -80 build/ui-build.log; exit 1; }
BIN="$(swift build -c release --show-bin-path --scratch-path "$SCRATCH")"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/boggart-ui.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# AppKit/UserNotifications получают настоящий bundle. Это отдельная тестовая
# копия без регистрации службы и операций питания, не пользовательский дистрибутив.
/usr/bin/ditto build/Boggart.app "$WORK/Boggart.app"
cp "$BIN/Boggart" "$WORK/Boggart.app/Contents/MacOS/Boggart"
/usr/bin/codesign --force --deep --sign - "$WORK/Boggart.app"
python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], check=True, timeout=30)' \
    "$WORK/Boggart.app/Contents/MacOS/Boggart" --capture-ui "$ROOT/build/visuals"
