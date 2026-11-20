#!/bin/bash
# Prepara SaySo para compartirlo: compilación de lanzamiento, firma con Developer ID y runtime
# endurecido, imagen de disco y notarización de Apple. El resultado es build/SaySo-<versión>.dmg,
# que se abre con doble clic en cualquier Mac con Apple silicon.
#
# Requisitos, una sola vez (los haces tú, porque piden tu cuenta de Apple):
#   1. Certificado «Developer ID Application» en el Llavero:
#      Xcode → Settings → Accounts → tu equipo → Manage Certificates → + → Developer ID Application.
#   2. Credenciales de notarización guardadas en el Llavero con el nombre «sayso-notary»:
#      xcrun notarytool store-credentials sayso-notary --apple-id <tu Apple ID> --team-id <tu equipo>
#      (pide una contraseña específica de app, que se crea en account.apple.com).
#
# Uso:
#   scripts/release.sh            # todo: compilar, firmar, dmg, notarizar y grapar
#   scripts/release.sh --no-notarize   # sin enviar a Apple (para probar la firma en este Mac)
#   scripts/release.sh --no-wait       # envía a Apple y termina sin esperar la respuesta
#   scripts/release.sh --staple        # grapa el resultado al .dmg ya creado, cuando Apple lo acepte
#   SAYSO_SIGN_ID="Developer ID Application: …"  fuerza una identidad concreta
#   SAYSO_NOTARY_PROFILE=otro-nombre             usa otro perfil de credenciales
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=1
WAIT=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0
[ "${1:-}" = "--no-wait" ] && WAIT=0
PROFILE="${SAYSO_NOTARY_PROFILE:-sayso-notary}"

# notarytool guarda el perfil en el Llavero con protección de datos, que solo se puede leer con la
# sesión desbloqueada. Si la pantalla se bloquea mientras Apple revisa la app, la siguiente llamada
# dice «No Keychain password item found» aunque el perfil siga ahí. Por eso el script no deja que la
# pantalla se apague mientras corre y, si aun así está bloqueada, espera a que se desbloquee.
if [ -z "${SAYSO_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
    SAYSO_CAFFEINATED=1 exec caffeinate -dims "$0" "$@"
fi

screen_locked() {
    ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -o - - 2>/dev/null | grep -qx true
}

notary() {
    if screen_locked; then
        echo "→ La pantalla está bloqueada y el Llavero no deja leer el perfil «$PROFILE»; esperando a que la desbloquees…"
        while screen_locked; do sleep 5; done
    fi
    xcrun notarytool "$@" --keychain-profile "$PROFILE"
}

if [ "${1:-}" = "--staple" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
    DMG="build/SaySo-$VERSION.dmg"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Listo: $DMG (firmado y notarizado). Ya se puede compartir."
    exit 0
fi

SIGN_ID="${SAYSO_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
    if [ "$NOTARIZE" = 1 ]; then
        echo "No hay ningún certificado «Developer ID Application» en el Llavero." >&2
        echo "Créalo en Xcode → Settings → Accounts → Manage Certificates y vuelve a lanzar el script." >&2
        exit 1
    fi
    SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && /"/ {print $2}')"
    echo "Aviso: sin Developer ID; se firma con la identidad de desarrollo solo para probar en este Mac."
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
APP="build/release/SaySo.app"
DMG="build/SaySo-$VERSION.dmg"

echo "→ Compilando (release)…"
swift build -c release --product SaySo
# Las licencias tienen que corresponder a las dependencias de esta compilación.
python3 scripts/generate-third-party-notices.py --check
BIN="$(swift build -c release --show-bin-path)/SaySo"

rm -rf build/release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SaySo"
cp scripts/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources" >/dev/null
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/brand/*.svg "$APP/Contents/Resources/"
# Licencias del software de terceros (se regenera con scripts/generate-third-party-notices.py).
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"
find "$(dirname "$BIN")" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

echo "→ Firmando con runtime endurecido…"
# Primero lo de dentro y al final la app, con sus permisos.
find "$APP/Contents/Resources" -name '*.bundle' -exec codesign --force --options runtime --timestamp --sign "$SIGN_ID" {} \;
codesign --force --options runtime --timestamp --entitlements scripts/SaySo.release.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --strict --deep "$APP"

if [ "$NOTARIZE" = 1 ] && [ "$WAIT" = 1 ]; then
    # La app se notariza y se grapa antes de meterla en el .dmg: así quien la copie a Aplicaciones
    # y la abra por primera vez sin conexión también pasa Gatekeeper. Grapar solo el .dmg no basta,
    # porque el ticket se queda en la imagen y no viaja con la app.
    echo "→ Notarizando la app (suele tardar unos minutos)…"
    ZIP="$(mktemp -d)/SaySo.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notary submit "$ZIP" --wait
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

echo "→ Creando la imagen de disco…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "SaySo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# La copia intermedia se borra: dos apps con el mismo identificador en el disco hacen que macOS no
# enseñe SaySo en las listas de Privacidad (Supervisión de entrada, Accesibilidad) aunque la
# apunte, y entonces no hay interruptor que encender. Lo que se reparte es el .dmg.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
rm -rf build/release

if [ "$NOTARIZE" = 1 ] && [ "$WAIT" = 0 ]; then
    echo "→ Enviando a Apple para notarizar, sin esperar la respuesta…"
    notary submit "$DMG" --no-wait
    echo "Enviado: $DMG. Consulta el estado con: xcrun notarytool history --keychain-profile $PROFILE"
    echo "Cuando salga «Accepted», grapa el resultado con: scripts/release.sh --staple"
elif [ "$NOTARIZE" = 1 ]; then
    echo "→ Notarizando la imagen de disco…"
    notary submit "$DMG" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Listo: $DMG (firmado y notarizado). Ya se puede compartir."
else
    echo "Listo: $DMG (firmado, SIN notarizar). En otros Mac macOS lo bloqueará."
fi
