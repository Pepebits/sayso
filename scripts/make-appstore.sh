#!/bin/bash
# Compila la versión para la Mac App Store y la empaqueta como build/SaySo Store.app, para probarla
# en sandbox en este Mac. No es la que se sube a la tienda: esa se firma con «Apple Distribution» y
# lleva perfil de aprovisionamiento.
# Uso: scripts/make-appstore.sh [debug|release]
#
# Usa un identificador propio (com.pepebits.sayso.store): sus datos (en su contenedor del sandbox),
# sus claves del Llavero y sus permisos de macOS no se mezclan con los de la versión normal.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BUNDLE_ID="${SAYSO_STORE_BUNDLE_ID:-com.pepebits.sayso.store}"
DISPLAY_NAME="${SAYSO_STORE_NAME:-SaySo Store}"
# Sin Sparkle y con la marca APPSTORE. Carpeta de compilación aparte: no invalida la normal.
export SAYSO_APPSTORE=1
SCRATCH=.build-appstore
# Sin Sparkle, SwiftPM lo quita de Package.resolved, que es el de la versión normal: se deja como estaba.
cp Package.resolved "$SCRATCH.resolved.bak" 2>/dev/null || true
trap 'mv -f "$SCRATCH.resolved.bak" Package.resolved 2>/dev/null || true' EXIT
swift build -c "$CONFIG" --product SaySo --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/SaySo"

APP="${SAYSO_STORE_APP:-build/SaySo Store.app}"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SaySo"
PLIST="$APP/Contents/Info.plist"
cp scripts/Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"
# Sparkle no va en esta versión, ni lo que lo configura.
for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUEnableAutomaticChecks NSAppleEventsUsageDescription; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
done
swift scripts/make-icon.swift "$APP/Contents/Resources" >/dev/null
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/brand/*.svg "$APP/Contents/Resources/"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"
# Manifiesto de privacidad que exige la tienda.
cp Resources/appstore/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# Con el mismo identificador que la versión DMG, sus datos pasan al contenedor al abrirla. Nunca en la
# de pruebas: moverían los datos de la app normal.
if [ "$BUNDLE_ID" = "com.pepebits.sayso" ]; then
    cp Resources/appstore/container-migration.plist "$APP/Contents/Resources/"
fi
find "$(dirname "$BIN")" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
if [ -d "$(dirname "$BIN")/Sparkle.framework" ] && grep -q Sparkle <(otool -L "$APP/Contents/MacOS/SaySo"); then
    echo "Error: el binario aún enlaza Sparkle" >&2; exit 1
fi

IDENTITIES="$(security find-identity -v -p codesigning)"
SIGN_ID="${SAYSO_SIGN_ID:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")}"
SIGN_ID="${SIGN_ID:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")}"
SIGN_ID="${SIGN_ID:--}"
codesign --force --deep --entitlements scripts/SaySo.appstore.entitlements --sign "$SIGN_ID" "$APP"
echo "Listo: $APP ($BUNDLE_ID, en sandbox)"
