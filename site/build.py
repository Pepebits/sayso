#!/usr/bin/env python3
"""Genera las páginas públicas de SaySo (privacidad y soporte) en site/_out.

Uso: python3 site/build.py
El contenido está en site/pages/*.html (solo el cuerpo); aquí se pone la cabecera, el pie y los
enlaces de idioma. Lo publica .github/workflows/pages.yml.
"""
import html
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "_out"
WORDMARK = (ROOT / "assets" / "wordmark-inner.svg").read_text().strip()

# Ruta, idioma, título, ruta de la misma página en el otro idioma.
PAGES = [
    ("privacidad", "es", "Política de privacidad", "privacy"),
    ("privacy", "en", "Privacy policy", "privacidad"),
    ("soporte", "es", "Soporte", "support"),
    ("support", "en", "Support", "soporte"),
]

TEXT = {
    "es": {"product": "un producto de", "opens": "Ir a pepebits.com", "other": "English", "this": "Español"},
    "en": {"product": "a product of", "opens": "Go to pepebits.com", "other": "Español", "this": "English"},
}


def page(slug, lang, title, twin):
    body = (ROOT / "pages" / f"{slug}.html").read_text()
    t = TEXT[lang]
    first, second = (("es", slug), ("en", twin)) if lang == "es" else (("es", twin), ("en", slug))
    def lang_link(code, target):
        current = ' aria-current="true"' if code == lang else ""
        label = TEXT[code]["this"]
        return f'<a href="../{target}/" hreflang="{code}" lang="{code}"{current}>{label}</a>'
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · SaySo</title>
<link rel="icon" href="../assets/sayso.svg" type="image/svg+xml">
<link rel="alternate" hreflang="{'en' if lang == 'es' else 'es'}" href="../{twin}/">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Hanken+Grotesk:wght@700;800&family=Inter:wght@400;600&display=swap">
<link rel="stylesheet" href="../assets/site.css">
</head>
<body>
<div class="wrap">
<header class="top">
<a class="brand" href="../{'privacidad' if lang == 'es' else 'privacy'}/"><img src="../assets/sayso.svg" alt=""><span>SaySo</span></a>
<nav class="lang" aria-label="{'Idioma' if lang == 'es' else 'Language'}">{lang_link(*first)}{lang_link(*second)}</nav>
</header>
<main>
{body.strip()}
</main>
<footer class="site">
<span>© <span data-year>2026</span> SaySo</span>
<a href="https://pepebits.com" rel="external"><span>{t["product"]}</span><svg viewBox="0 0 302 75" width="100" height="25" aria-hidden="true" focusable="false">{WORDMARK}</svg><span class="sr-only">PEPEBITS ({t["opens"]})</span></a>
</footer>
</div>
<script>document.querySelectorAll("[data-year]").forEach(e => e.textContent = new Date().getFullYear())</script>
</body>
</html>
"""


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "assets").mkdir(parents=True)
    for name in ["site.css", "sayso.svg"]:
        shutil.copy(ROOT / "assets" / name, OUT / "assets" / name)
    for slug, lang, title, twin in PAGES:
        (OUT / slug).mkdir()
        (OUT / slug / "index.html").write_text(page(slug, lang, title, twin))
    # La raíz lleva a la política en el idioma del navegador.
    (OUT / "index.html").write_text("""<!doctype html>
<html lang="es"><head><meta charset="utf-8"><title>SaySo</title>
<script>location.replace(/^es|^gl/.test(navigator.language) ? "privacidad/" : "privacy/")</script>
</head><body><a href="privacidad/">Privacidad</a> · <a href="privacy/">Privacy</a></body></html>
""")
    (OUT / ".nojekyll").write_text("")
    print(f"Listo: {OUT}")


if __name__ == "__main__":
    main()
