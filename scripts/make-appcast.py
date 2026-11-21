#!/usr/bin/env python3
"""Escribe el appcast de Sparkle para una versión publicada.

Uso: scripts/make-appcast.py <versión> <build> <enclosure-attrs> <salida.xml>

<enclosure-attrs> es lo que imprime `sign_update <dmg>`: sparkle:edSignature="…" length="…".
Las notas salen de la sección de esa versión en CHANGELOG.md, convertidas a HTML sencillo.
El appcast se sube como archivo de la release; la app lo lee en
https://github.com/Pepebits/sayso/releases/latest/download/appcast.xml.
"""
import html
import plistlib
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

REPO = "https://github.com/Pepebits/sayso"
ROOT = Path(__file__).resolve().parent.parent


def changelog_section(version: str) -> str:
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    match = re.search(rf"^## \[{re.escape(version)}\].*?$(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not match:
        sys.exit(f"CHANGELOG.md no tiene sección para {version}")
    return match.group(1).strip()


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)


def to_html(markdown: str) -> str:
    out, in_list = [], False
    for line in markdown.splitlines():
        line = line.rstrip()
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list and line:
            out.append("</ul>")
            in_list = False
        if line.startswith("### "):
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line:
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    version, build, attrs, output = sys.argv[1:]
    if not re.fullmatch(r'\s*sparkle:edSignature="[^"]+"\s+length="\d+"\s*', attrs):
        sys.exit(f"Firma inesperada de sign_update: {attrs!r}")
    info = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
    minimum = info["LSMinimumSystemVersion"]
    url = f"{REPO}/releases/download/v{version}/SaySo-{version}.dmg"
    notes = to_html(changelog_section(version))
    date = format_datetime(datetime.now(timezone.utc))
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SaySo</title>
    <link>{REPO}</link>
    <item>
      <title>SaySo {version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{REPO}/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {attrs.strip()}/>
    </item>
  </channel>
</rss>
"""
    Path(output).write_text(feed, encoding="utf-8")
    print(f"Appcast: {output}")


if __name__ == "__main__":
    main()
