#!/bin/bash
# Выпуск выполняет разработчик на Mac. Пользователь получает .dmg, не сборщик.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo 'Для выпуска нужен Mac с Xcode и сертификатом Developer ID.' >&2; exit 1; }
[[ "${BOGGART_HARDWARE_TESTING:-0}" == 0 ]] || { echo 'Проверочную сборку нельзя публиковать как готовый выпуск.' >&2; exit 1; }
python3 Scripts/release_gate.py
: "${BOGGART_SIGNING_IDENTITY:?Укажите Developer ID Application в BOGGART_SIGNING_IDENTITY.}"
: "${BOGGART_NOTARY_PROFILE:?Укажите имя профиля notarytool из Связки ключей в BOGGART_NOTARY_PROFILE.}"
./Scripts/check.sh
export BOGGART_ARCHITECTURE="${BOGGART_ARCHITECTURE:-arm64}"
./Scripts/build.sh
APP="$ROOT/build/Boggart.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SIGNATURE="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
    echo 'Для распространения нужна подпись Developer ID Application, не Apple Development.' >&2; exit 1;
}
mkdir -p "$ROOT/dist"
TEMP="$(mktemp -d "$ROOT/build/release.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$TEMP/Boggart.zip"
# Учётные данные читаются из Связки ключей; в исходниках и архиве их нет.
xcrun notarytool submit "$TEMP/Boggart.zip" --keychain-profile "$BOGGART_NOTARY_PROFILE" --wait --output-format json > "$ROOT/build/notary-app.json"
python3 - "$ROOT/build/notary-app.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    raise SystemExit('Нотариальная проверка приложения не пройдена. Проверьте журнал notarytool.')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
mkdir "$TEMP/image"
/usr/bin/ditto "$APP" "$TEMP/image/Boggart.app"
ln -s /Applications "$TEMP/image/Программы"
cat > "$TEMP/image/Установка.txt" <<'TEXT'
Боггарт
Перетащите Boggart.app в папку «Программы» и откройте его.
В панели нажмите «Подготовить Боггарт…». После настройки удержание не включается автоматически.
Для обновления версии 0.4 и новее: Настройки → Диагностика → Обновить из файла…
Не перетаскивайте обновление поверх работающего приложения с активной сессией.
Для удаления: Настройки → Диагностика → Удалить Боггарт…
TEXT
DMG="$ROOT/dist/Boggart-$VERSION.dmg"
/usr/bin/hdiutil create -volname "Боггарт $VERSION" -srcfolder "$TEMP/image" -ov -format UDZO "$DMG"
/usr/bin/codesign --force --timestamp --sign "$BOGGART_SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$BOGGART_NOTARY_PROFILE" --wait --output-format json > "$ROOT/build/notary-dmg.json"
python3 - "$ROOT/build/notary-dmg.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    raise SystemExit('Нотариальная проверка образа не пройдена. Образ не публиковать.')
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
/usr/bin/shasum -a 256 "$DMG" > "$DMG.sha256"
printf '\nПодписанный и нотариально проверенный дистрибутив: %s\n' "$DMG"
echo 'Публикация на сайт или в репозиторий не выполнялась.'
