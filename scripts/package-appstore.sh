#!/bin/bash
# Empaqueta la versión de la Mac App Store para subirla a App Store Connect: build/appstore/SaySo-<versión>.pkg
#
# Necesita, en este Mac (los crea quien tiene la cuenta de desarrollador; ver docs/app-store.md):
#   - el certificado «Apple Distribution» (o «3rd Party Mac Developer Application») en el Llavero;
#   - el certificado «Mac Installer Distribution» («3rd Party Mac Developer Installer»);
#   - el perfil de aprovisionamiento «Mac App Store» del identificador de la app.
#
# Uso: SAYSO_PROFILE=/ruta/SaySo_AppStore.provisionprofile scripts/package-appstore.sh
# Opcional: SAYSO_STORE_BUNDLE_ID (por defecto com.pepebits.sayso).
# El .pkg se sube con la app Transporter. Cada subida necesita un CFBundleVersion mayor (scripts/Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${SAYSO_PROFILE:?Falta SAYSO_PROFILE: la ruta del perfil de aprovisionamiento «Mac App Store».}"
BUNDLE_ID="${SAYSO_STORE_BUNDLE_ID:-com.pepebits.sayso}"
[ -f "$PROFILE" ] || { echo "No existe el perfil: $PROFILE" >&2; exit 1; }

# Identidades del Llavero: solo se buscan por tipo, no se imprimen.
APP_SIGN="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Distribution|3rd Party Mac Developer Application/ {print $2; exit}')"
PKG_SIGN="$(security find-identity -v | awk -F'"' '/Mac Installer Distribution|3rd Party Mac Developer Installer/ {print $2; exit}')"
[ -n "$APP_SIGN" ] || { echo "Falta el certificado «Apple Distribution» en el Llavero." >&2; exit 1; }
[ -n "$PKG_SIGN" ] || { echo "Falta el certificado «Mac Installer Distribution» en el Llavero." >&2; exit 1; }

# El perfil tiene que ser de esta app, de la tienda (sin lista de dispositivos) y estar vigente.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$WORK/profile.plist")"
[ "$APP_IDENTIFIER" = "$TEAM.$BUNDLE_ID" ] || { echo "El perfil es de «${APP_IDENTIFIER#*.}», no de $BUNDLE_ID." >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$WORK/profile.plist" >/dev/null 2>&1; then
    echo "Ese perfil es de desarrollo (lleva dispositivos): hace falta uno de distribución «Mac App Store»." >&2; exit 1
fi
# Fechas ISO 8601 en UTC: se comparan como texto.
EXPIRES="$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")"
if [[ "$EXPIRES" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
    echo "El perfil ha caducado ($EXPIRES)." >&2; exit 1
fi

# Compilación de la tienda, en release, con el identificador y el nombre de verdad. Se firma ad hoc
# y aquí se vuelve a firmar con el certificado de distribución.
# Va a su propia carpeta: no pisa «SaySo Store.app», la de pruebas con otro identificador.
OUT="build/appstore"
APP="$OUT/SaySo.app"
rm -rf "${OUT:?}"
mkdir -p "$OUT"
SAYSO_STORE_BUNDLE_ID="$BUNDLE_ID" SAYSO_STORE_NAME="SaySo" SAYSO_SIGN_ID="-" SAYSO_STORE_APP="$APP" \
    scripts/make-appstore.sh release
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Los derechos de la tienda, más el identificador de la app y del equipo, que exige el perfil.
ENTITLEMENTS="$WORK/SaySo.entitlements"
cp scripts/SaySo.appstore.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"

codesign --force --sign "$APP_SIGN" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
# Sin Sparkle y con el sandbox: si no, la tienda lo rechaza.
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "La app firmada no lleva el sandbox." >&2; exit 1; }
if otool -L "$APP/Contents/MacOS/SaySo" | grep -qi sparkle; then echo "La app aún enlaza Sparkle." >&2; exit 1; fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PKG="$OUT/SaySo-$VERSION-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "$PKG_SIGN" "$PKG"
pkgutil --check-signature "$PKG" >/dev/null
echo "Listo: $PKG ($BUNDLE_ID $VERSION, build $BUILD). Súbelo con Transporter."
