#!/bin/bash
# Compila SaySo y lo empaqueta como build/SaySo.app.
# Uso: scripts/make-app.sh [debug|release]
#
# Firma: por defecto usa la identidad «Developer ID» del llavero (o la de desarrollo, o la primera), para que macOS
# conserve entre compilaciones los permisos concedidos (Accesibilidad, Micrófono…). Con una firma
# ad hoc esos permisos se pierden en cada compilación. Para forzar otra: SAYSO_SIGN_ID="…" o "-".
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product SaySo
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SaySo"

APP="build/SaySo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SaySo"
cp scripts/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources" >/dev/null

# Idiomas: el español del código es la clave; Resources/en.lproj lleva el inglés.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Logotipo de Pepebits para la firma del pie.
cp Resources/brand/*.svg "$APP/Contents/Resources/"
# Licencias del software de terceros (se regenera con scripts/generate-third-party-notices.py).
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"

# Recursos de paquetes SPM (p. ej. los de las dependencias), si los hay.
find "$(dirname "$BIN")" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Con varias identidades se prefiere «Developer ID»: macOS reconoce la app por el equipo, no por el
# certificado concreto, así que los permisos concedidos (Accesibilidad, Micrófono…) sobreviven a
# renovar o recrear certificados. Con «Apple Development» se pierden cada vez que cambia el certificado.
IDENTITIES="$(security find-identity -v -p codesigning)"
SIGN_ID="${SAYSO_SIGN_ID:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")}"
SIGN_ID="${SIGN_ID:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")}"
SIGN_ID="${SIGN_ID:-$(awk -F'"' 'NR==1 && /"/ {print $2}' <<<"$IDENTITIES")}"
SIGN_ID="${SIGN_ID:--}"
codesign --force --deep --entitlements scripts/SaySo.entitlements --sign "$SIGN_ID" "$APP"
echo "Listo: $APP (firma: $([ "$SIGN_ID" = "-" ] && echo 'ad hoc' || echo 'identidad del llavero'))"
