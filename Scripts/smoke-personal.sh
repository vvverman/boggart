#!/bin/bash
# Настоящий XPC с root-помощником на одноразовом CI Mac, без команд удержания сна.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin && "${CI:-}" == true ]] || exit 1
: "${BOGGART_CI_IDENTITY:?}" "${BOGGART_CI_KEYCHAIN:?}" "${BOGGART_CI_CERT_DIGEST:?}"
APP=/Applications/Boggart.app
PROBE=/Applications/BoggartCIProbe.app
[[ ! -e "$APP" && ! -e "$PROBE" ]] || { echo 'Не заменяем установленные приложения.' >&2; exit 1; }
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/boggart-probe.XXXXXX")"
cleanup() {
    sudo /bin/launchctl bootout system/local.boggart.helper >/dev/null 2>&1 || true
    if [[ -x "$PROBE/Contents/MacOS/Boggart" ]]; then
        "$PROBE/Contents/MacOS/Boggart" unregister >/dev/null 2>&1 || true
    fi
    sudo /bin/rm -rf "$APP" "$PROBE"
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT
/usr/bin/pmset -g custom > "$WORK/settings-before"
/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ { print }' > "$WORK/disabled-before"
sudo /usr/bin/ditto build/Boggart.app "$APP"
/usr/bin/ditto build/Boggart.app "$WORK/Probe.app"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" Scripts/PackageProbe.swift -o "$WORK/Probe.app/Contents/MacOS/Boggart" \
    -framework Foundation -framework ServiceManagement
/usr/bin/codesign --force --options runtime --timestamp=none --keychain "$BOGGART_CI_KEYCHAIN" \
    --sign "$BOGGART_CI_IDENTITY" --identifier local.boggart.app \
    --requirements "=designated => identifier \"local.boggart.app\" and certificate leaf = H\"$BOGGART_CI_CERT_DIGEST\"" "$WORK/Probe.app"
sudo /usr/bin/ditto "$WORK/Probe.app" "$PROBE"
# Валидная подпись, но чужой identifier: root-служба обязана отклонить клиента.
cp "$PROBE/Contents/MacOS/Boggart" "$WORK/UnauthorizedProbe"
/usr/bin/codesign --force --options runtime --timestamp=none --keychain "$BOGGART_CI_KEYCHAIN" \
    --sign "$BOGGART_CI_IDENTITY" --identifier local.boggart.unauthorized "$WORK/UnauthorizedProbe"
# Не позволяем проверкам зависеть от сертификата, доверенного только на CI.
/usr/bin/security find-certificate -c "$BOGGART_CI_IDENTITY" -p "$BOGGART_CI_KEYCHAIN" > "$WORK/public.pem"
sudo /usr/bin/security remove-trusted-cert -d "$WORK/public.pem"
echo 'SIGNER_NOT_INSTALLED_AS_TRUSTED_FOR_RUNTIME_CHECKS'
"$APP/Contents/MacOS/Boggart" --validate-bundle
# Проверяем реальный API регистрации, но не подтверждаем разрешение за пользователя.
"$PROBE/Contents/MacOS/Boggart" register
"$PROBE/Contents/MacOS/Boggart" unregister
sleep 2
# Для независимой проверки XPC CI запускает ТОТ ЖЕ помощник через launchd.
# Этот тестовый plist не входит в дистрибутив; приложение использует SMAppService.
python3 - "$WORK/helper.plist" "$APP" <<'PY'
import plistlib, sys
app = sys.argv[2]
with open(app + '/Contents/Library/LaunchDaemons/local.boggart.helper.plist', 'rb') as f:
    job = plistlib.load(f)
job.pop('BundleProgram')
job['ProgramArguments'] = [app + '/Contents/MacOS/BoggartHelper']
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(job, f)
PY
sudo /usr/sbin/chown root:wheel "$WORK/helper.plist"
sudo /bin/chmod 644 "$WORK/helper.plist"
sudo /bin/launchctl bootstrap system "$WORK/helper.plist"
sleep 2
"$PROBE/Contents/MacOS/Boggart" xpc "$BOGGART_CI_CERT_DIGEST"
"$WORK/UnauthorizedProbe" reject "$BOGGART_CI_CERT_DIGEST"
sudo /bin/launchctl bootout system/local.boggart.helper
# Проверяем запуск реального SwiftUI-приложения, не нажимая «Не спать».
/usr/bin/open -g "$APP"
sleep 4
PID="$(/usr/bin/pgrep -f '^/Applications/Boggart.app/Contents/MacOS/Boggart$' | head -1)"
[[ -n "$PID" ]] || { echo 'Приложение не осталось запущенным.' >&2; exit 1; }
echo 'NATIVE_APP_LAUNCH_OK'
/bin/kill -TERM "$PID"
sleep 1
/usr/bin/pmset -g custom > "$WORK/settings-after"
/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ { print }' > "$WORK/disabled-after"
diff -u "$WORK/settings-before" "$WORK/settings-after"
diff -u "$WORK/disabled-before" "$WORK/disabled-after"
echo 'POWER_SETTINGS_UNCHANGED; NO_SLEEP_SESSION_STARTED'
