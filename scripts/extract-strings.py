#!/usr/bin/env python3
"""Lista los textos visibles de SaySo (las claves de traducción) como JSON.

Uso: scripts/extract-strings.py > claves.json
El español del código es la clave. Se recogen: el primer argumento de cada tr("…") en todo
Sources/, y los literales con pinta de frase de los archivos de interfaz y de los catálogos.
Los textos que solo lee el modelo (descripciones de herramientas, instrucciones) no se traducen.
"""
import glob, json, re, sys

LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
TR = re.compile(r'\btr\(\s*(?:[a-zA-Z_.]+ \? )?"((?:[^"\\]|\\.)*)"(?:\s*:\s*"((?:[^"\\]|\\.)*)")?')

# Archivos cuyos literales se muestran tal cual a través de los componentes.
WHOLE = (glob.glob("Sources/SaySoUI/*.swift") + glob.glob("Sources/SaySoApp/*.swift") + [
    "Sources/SaySoCore/Permissions.swift", "Sources/SaySoCore/Computer.swift", "Sources/SaySoCore/Tasks.swift",
    "Sources/SaySoCore/Plugins.swift", "Sources/SaySoVM/ComputerManager.swift", "Sources/SaySoVM/VMImage.swift",
    "Sources/SaySoTDLib/TDLibSession.swift", "Sources/SaySoDictation/WhisperTranscriber.swift",
    "Sources/SaySoDictation/DictationController.swift", "Sources/SaySoPermissions/MacScriptRunner.swift",
])
SKIP = ("Previews.swift",)
TECH = re.compile(r'^[a-zA-Z0-9_.:\-/@#$%+*=<>()\[\]{}|&!?,; \'\\]*$')  # sin letras propias del español ni frase


def looks_like_text(s):
    if "\\(" in s or len(s) < 2:
        return False
    if not re.search(r"[a-záéíóúñ]", s):
        return False
    if re.fullmatch(r"[a-z0-9_.:\-/]+", s):          # identificadores, símbolos SF, claves
        return False
    if re.fullmatch(r"[A-Za-z]+\.[A-Za-z.]+", s):
        return False
    if s.startswith(("SAYSO_", "x-apple", "http", "sudo ", "set -e", "export ", "systemctl", "/")):
        return False
    return bool(re.search(r"[A-ZÁÉÍÓÚ¿¡«a-záéíóúñ]", s[0])) and (" " in s or s[0].isupper() or re.search(r"[áéíóúñ]", s))


# Claves que el código pasa a tr() desde una variable.
EXTRA = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom", "ahora mismo", "en pausa", "el plugin"]

keys = set(EXTRA)
for path in glob.glob("Sources/*/*.swift"):
    if path.endswith(SKIP):
        continue
    text = open(path, encoding="utf-8").read()
    for m in TR.finditer(text):
        keys.add(m.group(1))
        if m.group(2):
            keys.add(m.group(2))
    if path in WHOLE:
        for line in text.split("\n"):
            code = line.split("//")[0] if line.strip().startswith("//") else line
            if code.strip().startswith(("///", "//")) or "environment[" in code or "print(" in code:
                continue
            for m in LIT.finditer(code):
                if looks_like_text(m.group(1)):
                    keys.add(m.group(1))

json.dump(sorted(keys), sys.stdout, ensure_ascii=False, indent=0)
