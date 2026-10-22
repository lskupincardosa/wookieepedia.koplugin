#!/usr/bin/env python3
"""Build samples/lookup-test.epub: a tiny self-written EPUB whose text
contains names that exercise each lookup case (normal, redirect,
disambiguation, lowercase, not found). Run: python3 tools/make_test_epub.py"""
import pathlib, zipfile

OUT = pathlib.Path(__file__).resolve().parent.parent / "samples" / "lookup-test.epub"

PARAGRAPHS = [
    ("Normal articles", "Avar Kriss looked out from Starlight Beacon while Bell Zettifar "
     "and Elzar Mann argued about the Nihil. Far below, Coruscant glittered."),
    ("Redirects", "Everyone simply called her Rey. Some said the old Kriss had once "
     "been kept as a pet."),
    ("Disambiguation", "The name Mace was common. So was Ben."),
    ("Lowercase selection", "Select these words: avar kriss, starlight beacon, lightsaber."),
    ("Not found", "Nobody had heard of Xyzzyqq Florbnik, which is not a real name."),
]

CHAPTER = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Lookup test</title></head>
<body><h1>Wookieepedia lookup test</h1>
{body}
</body></html>"""

OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">wookieepedia-koplugin-lookup-test</dc:identifier>
<dc:title>Wookieepedia lookup test</dc:title><dc:language>en</dc:language>
<meta property="dcterms:modified">2026-10-22T00:00:00Z</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine><itemref idref="ch1"/></spine>
</package>"""

NAV = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
<body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">Lookup test</a></li></ol></nav></body></html>"""

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

body = "\n".join(f"<h2>{h}</h2>\n<p>{p}</p>" for h, p in PARAGRAPHS)
OUT.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(OUT, "w") as z:
    z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/content.opf", OPF, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/nav.xhtml", NAV, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/ch1.xhtml", CHAPTER.format(body=body), compress_type=zipfile.ZIP_DEFLATED)
print(OUT)
