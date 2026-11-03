#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (docs/appcast.xml, served by GitHub Pages).

    appcast.py --version 1.2.0 --build 4 --url https://.../Mirra.zip --length 123 \
               --signature BASE64 --notes notes.md [--appcast docs/appcast.xml]
"""
import argparse
import email.utils
import html
import os
import re

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mirra</title>
    <link>https://hanqing.github.io/Mirra/appcast.xml</link>
    <description>Mirra 舞镜的版本更新</description>
    <language>zh-CN</language>
"""
FOOTER = """  </channel>
</rss>
"""
KEEP = 10  # newest releases kept in the feed


def markdown_to_html(text):
    """Just enough Markdown for release notes: paragraphs, bullet lists, **bold**, `code`."""
    out, in_list = [], False
    for line in text.strip().splitlines():
        line = html.escape(line.rstrip())
        line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
        line = re.sub(r"`(.+?)`", r"<code>\1</code>", line)
        if re.match(r"^\s*[-*] ", line):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>" + re.sub(r"^\s*[-*] ", "", line) + "</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.strip():
            out.append("<p>" + line + "</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes", required=True)
    p.add_argument("--min-system", default="26.0")
    p.add_argument("--appcast", default=os.path.join(os.path.dirname(__file__), "..", "docs", "appcast.xml"))
    a = p.parse_args()

    with open(a.notes, encoding="utf-8") as f:
        notes = markdown_to_html(f.read())
    item = f"""    <item>
      <title>Mirra {a.version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{a.build}</sparkle:version>
      <sparkle:shortVersionString>{a.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{a.min_system}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{html.escape(a.url)}" length="{a.length}" type="application/octet-stream" sparkle:edSignature="{a.signature}"/>
    </item>
"""
    items = []
    if os.path.exists(a.appcast):
        with open(a.appcast, encoding="utf-8") as f:
            items = re.findall(r"    <item>.*?</item>\n", f.read(), re.S)
        items = [i for i in items if f"<sparkle:shortVersionString>{a.version}<" not in i]
    items = [item] + items[: KEEP - 1]
    with open(a.appcast, "w", encoding="utf-8") as f:
        f.write(HEADER + "".join(items) + FOOTER)
    print(f"appcast: {a.version} (build {a.build}) -> {os.path.normpath(a.appcast)}")


if __name__ == "__main__":
    main()
