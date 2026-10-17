#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo 'Для сборки приложения нужен Mac с Apple SDK. На Linux доступны только тесты ядра.' >&2; exit 1; }
xcrun --find swift >/dev/null || { echo 'Нужны инструменты разработки Xcode.' >&2; exit 1; }
MODE="${BOGGART_HARDWARE_TESTING:-0}"
[[ "$MODE" == 0 || "$MODE" == 1 ]] || { echo 'Неверный тип сборки.' >&2; exit 1; }
FLAGS=(-Xswiftc -DBOGGART_RELEASE_BUILD)
if [[ "$MODE" == 1 ]]; then
    FLAGS=(-Xswiftc -DBOGGART_HARDWARE_TESTING)
    echo 'ПРОВЕРОЧНАЯ СБОРКА: поддержка закрытой крышки ещё не подтверждена. Только для аппаратной проверки под наблюдением.'
else
    echo 'Обычная сборка: запуск разрешён только аппаратно подтверждённым конфигурациям.'
fi
IDENTITY="${BOGGART_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -E '"(Apple Development|Developer ID Application):' || true)"
    COUNT="$(printf '%s\n' "$IDENTITIES" | /usr/bin/grep -c '[A-F0-9]\{40\}' || true)"
    if [[ "$COUNT" == 1 ]]; then IDENTITY="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk '{print $2}')"; fi
fi
if [[ -z "$IDENTITY" ]]; then
    echo 'Укажите сертификат Apple Development или Developer ID Application:' >&2
    echo 'export BOGGART_SIGNING_IDENTITY="название или SHA-1 сертификата"' >&2
    echo 'Проверка кода без подписи: ./Проверить.command' >&2
    exit 1
fi
ARCHS=()
case "${BOGGART_ARCHITECTURE:-native}" in
    native) ;;
    arm64) ARCHS=(--arch arm64) ;;
    x86_64) ARCHS=(--arch x86_64) ;;
    universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo 'Допустимые архитектуры: native, arm64, x86_64, universal.' >&2; exit 1 ;;
esac
SCRATCH="$ROOT/.build/bundle-$MODE-${BOGGART_ARCHITECTURE:-native}"
swift build --configuration release --scratch-path "$SCRATCH" "${ARCHS[@]}" "${FLAGS[@]}"
BIN="$(swift build --show-bin-path --configuration release --scratch-path "$SCRATCH" "${ARCHS[@]}" "${FLAGS[@]}")"
APP="$ROOT/build/Boggart.app"
mkdir -p "$ROOT/build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Boggart" "$APP/Contents/MacOS/Boggart"
cp "$BIN/BoggartHelper" "$APP/Contents/MacOS/BoggartHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/local.boggart.helper.plist "$APP/Contents/Library/LaunchDaemons/"
if [[ "$MODE" == 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Set :BoggartHardwareTesting true' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Боггарт — проверочная сборка' "$APP/Contents/Info.plist"
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier local.boggart.helper "$APP/Contents/MacOS/BoggartHelper"
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier local.boggart.app "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -dr - "$APP" 2>&1
printf '\nСобрано: %s\n' "$APP"
echo 'Приложение не запускается автоматически. Ни регистрация помощника, ни изменение сна не выполнялись.'
