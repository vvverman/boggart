#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Установка доступна только на Mac.' >&2; exit 1; }
if [[ -e /Library/LaunchDaemons/local.boggart.helper.plist || -e /Library/PrivilegedHelperTools/local.boggart.helper ]]; then
    echo 'Обнаружен помощник версии 0.1/0.2. Сначала остановите старый Боггарт и выполните его «Удалить.command».' >&2
    echo 'Новая версия не присваивает прежний глобальный запрет сна и не удаляет его журнал.' >&2
    exit 1
fi
if [[ -e /Applications/Boggart.app ]]; then
    echo 'Приложение уже установлено. В 0.4 и новее: Настройки → Диагностика → Обновить из файла.' >&2
    echo 'Для перехода с 0.3 используйте однократную миграцию из README. Установщик не трогает действующую службу.' >&2
    echo 'Установщик не заменяет работающий привилегированный помощник.' >&2
    exit 1
fi
"$ROOT/Scripts/build.sh"
/usr/bin/osascript - "$ROOT/build/Boggart.app" <<'APPLESCRIPT'
on run arguments
    set sourceApp to item 1 of arguments
    set targetApp to "/Applications/Boggart.app"
    set command to "/usr/bin/ditto " & quoted form of sourceApp & " " & quoted form of targetApp & " && /usr/sbin/chown -R root:wheel " & quoted form of targetApp & " && /bin/chmod -R go-w " & quoted form of targetApp
    do shell script command with administrator privileges
end run
APPLESCRIPT
/usr/bin/codesign --verify --deep --strict /Applications/Boggart.app
/usr/bin/open /Applications/Boggart.app
echo 'Приложение установлено. Для регистрации помощника нажмите «Подготовить Боггарт…» в его панели. Удержание само не включается.'
