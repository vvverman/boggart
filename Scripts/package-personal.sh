#!/bin/bash
# Готовая личная сборка без Developer ID. Не заменяет нотариализованный выпуск.
# Временный ключ существует только на одноразовом CI Mac и не попадает в архивы.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin && "${CI:-}" == true ]] || {
    echo 'Этот сценарий предназначен для одноразового macOS runner в CI.' >&2; exit 1;
}
mkdir -p build dist
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/boggart-signing.XXXXXX")"
KEYCHAIN="$WORK/signing.keychain-db"
PASSWORD="$(openssl rand -hex 24)"
CERT="$WORK/certificate.pem"
IDENTITY="Boggart Personal Build ${GITHUB_RUN_ID:-local}"
cleanup() {
    /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT
cat > "$WORK/openssl.cnf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = Boggart Personal Build
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
openssl req -new -newkey rsa:3072 -x509 -sha256 -nodes -days 3650 \
    -config "$WORK/openssl.cnf" -subj "/CN=$IDENTITY/" \
    -keyout "$WORK/key.pem" -out "$CERT" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$CERT" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
/usr/bin/security create-keychain -p "$PASSWORD" "$KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 3600 "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
/usr/bin/security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
# Доверие существует лишь на временном runner; в пользовательской поставке нет
# сертификатов для установки, профилей доверия или приватных ключей.
sudo /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
DIGEST="$(openssl x509 -in "$CERT" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
export BOGGART_CI_IDENTITY="$IDENTITY" BOGGART_CI_KEYCHAIN="$KEYCHAIN" BOGGART_CI_CERT_DIGEST="$DIGEST"
FLAGS=(-Xswiftc -DBOGGART_HARDWARE_TESTING -Xswiftc -DBOGGART_PERSONAL_BUILD)
ARCHS=(--arch arm64 --arch x86_64)
SCRATCH="$ROOT/.build/personal"
swift build -c release --scratch-path "$SCRATCH" "${ARCHS[@]}" "${FLAGS[@]}" 2>&1 | tee build/personal-build.log
BIN="$(swift build --show-bin-path -c release --scratch-path "$SCRATCH" "${ARCHS[@]}" "${FLAGS[@]}")"
APP="$ROOT/build/Boggart.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Boggart" "$APP/Contents/MacOS/Boggart"
cp "$BIN/BoggartHelper" "$APP/Contents/MacOS/BoggartHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/local.boggart.helper.plist "$APP/Contents/Library/LaunchDaemons/"
/usr/libexec/PlistBuddy -c 'Set :BoggartHardwareTesting true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Боггарт' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :BoggartDistribution string personal-preview' "$APP/Contents/Info.plist"
# Явное требование закрепляет точный сертификат и идентификатор каждого компонента.
sign() {
    /usr/bin/codesign --force --options runtime --timestamp=none --keychain "$KEYCHAIN" \
        --sign "$IDENTITY" --identifier "$2" \
        --requirements "=designated => identifier \"$2\" and certificate leaf = H\"$DIGEST\"" "$1"
}
sign "$APP/Contents/MacOS/BoggartHelper" local.boggart.helper
sign "$APP" local.boggart.app
/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$APP"
/usr/bin/lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/Boggart"
/usr/bin/lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/BoggartHelper"
"$APP/Contents/MacOS/Boggart" --validate-bundle
./Scripts/smoke-personal.sh 2>&1 | tee build/personal-smoke.log
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$WORK/image"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/Boggart.app"
ln -s /Applications "$STAGE/Программы"
cp Docs/Установка-личной-сборки.txt "$STAGE/Установка.txt"
/usr/bin/hdiutil create -volname "Боггарт $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Boggart-$VERSION.dmg"
/usr/bin/hdiutil verify "dist/Boggart-$VERSION.dmg"
/usr/bin/ditto -c -k --keepParent "$APP" "dist/Boggart-$VERSION.zip"
cp Docs/Установка-личной-сборки.txt dist/Установка.txt
(cd dist && /usr/bin/shasum -a 256 "Boggart-$VERSION.dmg" "Boggart-$VERSION.zip" > SHA256SUMS.txt)
# В артефакты попадают только готовые пакеты, текст и публичные журналы.
printf 'PACKAGED: %s\n' "dist/Boggart-$VERSION.dmg"
