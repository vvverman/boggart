#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRATCH="$ROOT/.build/ui-acceptance"
swift build -c release --scratch-path "$SCRATCH" --product Boggart \
    -Xswiftc -DBOGGART_UI_TESTING -Xswiftc -DBOGGART_PERSONAL_BUILD -Xswiftc -DBOGGART_HARDWARE_TESTING > build/ui-build.log 2>&1 || { tail -80 build/ui-build.log; exit 1; }
BIN="$(swift build -c release --show-bin-path --scratch-path "$SCRATCH")"
python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], check=True, timeout=30)' "$BIN/Boggart" --capture-ui "$ROOT/build/visuals"
