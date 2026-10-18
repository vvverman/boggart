#!/bin/bash
# Обычное окно Finder: настоящие перетаскиваемые приложение и папка «Программы».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="${1:?Путь к .app}"; OUTPUT="${2:?Путь к .dmg}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/boggart-dmg.XXXXXX")"
MOUNT="$WORK/mount"; STAGE="$WORK/stage"
cleanup() { /usr/bin/hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$STAGE/.background" "$MOUNT"
/usr/bin/ditto "$APP" "$STAGE/Boggart.app"
ln -s /Applications "$STAGE/Программы"
cp build/visuals/installer-background.tiff "$STAGE/.background/background.tiff"
cp Docs/Установка-личной-сборки.txt "$STAGE/.background/Установка.txt"
/usr/bin/hdiutil create -volname "Боггарт $VERSION" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$WORK/editable.dmg" >/dev/null
/usr/bin/hdiutil attach -readwrite -nobrowse -noverify -mountpoint "$MOUNT" "$WORK/editable.dmg" >/dev/null
/usr/bin/osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set targetPath to item 1 of argv
    set targetFolder to POSIX file targetPath as alias
    tell application "Finder"
        open targetFolder
        set w to container window of targetFolder
        set current view of w to icon view
        set toolbar visible of w to false
        set statusbar visible of w to false
        set bounds of w to {100, 100, 820, 568}
        set opts to icon view options of w
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff" of targetFolder
        set position of item "Boggart.app" of targetFolder to {202, 232}
        set position of item "Программы" of targetFolder to {518, 232}
        update targetFolder without registering applications
        delay 2
        close w
        open targetFolder
        delay 1
    end tell
end run
APPLESCRIPT
sync
[[ -f "$MOUNT/.DS_Store" ]] || { echo 'Finder не сохранил оформление образа.' >&2; exit 1; }
cp "$MOUNT/.DS_Store" build/visuals/installer.DS_Store
/usr/sbin/screencapture -x -R100,100,720,468 build/visuals/installer-window.png >/dev/null 2>&1 || true
/usr/bin/osascript -e 'tell application "Finder" to close every window whose name starts with "Боггарт"' || true
/usr/bin/hdiutil detach "$MOUNT" -quiet
/usr/bin/hdiutil convert "$WORK/editable.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT" >/dev/null
/usr/bin/hdiutil verify "$OUTPUT"
echo 'FINDER_INSTALLER_LAYOUT_SAVED'
