#!/usr/bin/env python3
"""Checks the appcast written by scripts/make-appcast.py."""
import importlib.util
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location("make_appcast", Path(__file__).with_name("make-appcast.py"))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

with tempfile.TemporaryDirectory() as scratch:
    archive = Path(scratch, "HowWasYourDay.zip"); archive.write_bytes(b"x" * 42)
    output = Path(scratch, "appcast.xml")
    notes = Path(scratch, "notes.md")
    notes.write_text("# How Was Your Day v1.2.3: Title\n\n[![Downloads](https://img.shields.io/x.svg)](https://x)\n\nIntro & <b>more</b>.\n\n## Fixed\n\n- `a]]>b`\n")
    module.main(["1.2.3", "456", str(archive), 'sparkle:edSignature="c2lnbmF0dXJl==" length="42"', str(output), "--notes", str(notes)])
    item = ET.parse(output).getroot().find("channel/item")
    assert item.find(SPARKLE + "version").text == "456"
    assert item.find(SPARKLE + "shortVersionString").text == "1.2.3"
    assert item.find(SPARKLE + "minimumSystemVersion").text == "26.0"
    # Notes are embedded, never linked: Sparkle would show the whole GitHub page.
    assert item.find(SPARKLE + "releaseNotesLink") is None
    assert item.find("link").text.endswith("/releases/tag/v1.2.3")
    description = item.find("description")
    assert description.get(SPARKLE + "format") == "markdown"
    assert description.text.startswith("Intro & <b>more</b>.")
    assert "img.shields.io" not in description.text and "# How Was Your Day" not in description.text
    assert "- `a]]>b`" in description.text
    assert description.text.rstrip().endswith("(https://github.com/alepee/how-was-your-day/releases/tag/v1.2.3)")
    enclosure = item.find("enclosure")
    assert enclosure.get("url") == "https://github.com/alepee/how-was-your-day/releases/download/v1.2.3/HowWasYourDay.zip"
    assert enclosure.get(SPARKLE + "edSignature") == "c2lnbmF0dXJl==" and enclosure.get("length") == "42"
    # A signature for another file must not end up in the appcast.
    try:
        module.main(["1.2.3", "456", str(archive), 'sparkle:edSignature="c2ln" length="41"', str(output), "--notes", str(notes)])
        raise AssertionError("length mismatch accepted")
    except SystemExit as error:
        assert "differs" in str(error)
    for bad in ["no signature here", 'length="42"']:
        try:
            module.parse_signature(bad); raise AssertionError("bad signature accepted")
        except ValueError:
            pass
print("Appcast: PASS")
