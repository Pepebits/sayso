#!/bin/bash
# Compila la app de prueba y la firma con el App Sandbox activado.
# Uso: tools/sandbox-probe/make.sh [base|notas]   (notas añade la excepción de Apple Events para Notas)
set -euo pipefail
cd "$(dirname "$0")"
VARIANT="${1:-base}"
swift build -c release 2>&1 | tail -1
APP="../../build/SandboxProbe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/SandboxProbe" "$APP/Contents/MacOS/SandboxProbe"
cp Info.plist "$APP/Contents/Info.plist"
ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --options runtime --entitlements "sandbox-$VARIANT.entitlements" --sign "${ID:--}" "$APP"
echo "Listo: build/SandboxProbe.app (variante $VARIANT)"
