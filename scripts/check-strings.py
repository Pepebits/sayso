#!/usr/bin/env python3
"""Comprueba una traducción contra la inglesa, que es la de referencia.

Uso: scripts/check-strings.py <código>      (p. ej. gl, fr, pt)

Avisa de claves que faltan o sobran, de traducciones vacías y de textos cuyo número de huecos
(%@) no coincide con el de la clave. Sale con 1 si hay algún problema.
"""
import plistlib, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Resources"


def table(code):
    path = ROOT / f"{code}.lproj" / "Localizable.strings"
    if not path.exists():
        sys.exit(f"No existe {path}")
    lint = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    if lint.returncode != 0:
        sys.exit(f"El archivo no es válido: {lint.stdout.strip()} {lint.stderr.strip()}")
    xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)], capture_output=True, check=True).stdout
    return plistlib.loads(xml)


def holes(text):
    return len(re.findall(r"%(\d+\$)?@", text))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    reference, target = table("en"), table(sys.argv[1])
    problems = []
    for key in reference:
        if key not in target:
            problems.append(f"FALTA   {key!r}")
        elif not target[key].strip():
            problems.append(f"VACÍA   {key!r}")
        elif holes(key) != holes(target[key]):
            problems.append(f"HUECOS  {key!r} -> {target[key]!r}")
    for key in target:
        if key not in reference:
            problems.append(f"SOBRA   {key!r}")
    for line in problems[:60]:
        print(line)
    if len(problems) > 60:
        print(f"… y {len(problems) - 60} más")
    print(f"{sys.argv[1]}: {len(target)} de {len(reference)} claves, {len(problems)} problemas")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
