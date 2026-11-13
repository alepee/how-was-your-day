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
    module.main(["1.2.3", "456", str(archive), 'sparkle:edSignature="c2lnbmF0dXJl==" length="42"', str(output)])
    item = ET.parse(output).getroot().find("channel/item")
    assert item.find(SPARKLE + "version").text == "456"
    assert item.find(SPARKLE + "shortVersionString").text == "1.2.3"
    assert item.find(SPARKLE + "minimumSystemVersion").text == "26.0"
    assert item.find(SPARKLE + "releaseNotesLink").text.endswith("/releases/tag/v1.2.3")
    enclosure = item.find("enclosure")
    assert enclosure.get("url") == "https://github.com/alepee/how-was-your-day/releases/download/v1.2.3/HowWasYourDay.zip"
    assert enclosure.get(SPARKLE + "edSignature") == "c2lnbmF0dXJl==" and enclosure.get("length") == "42"
    # A signature for another file must not end up in the appcast.
    try:
        module.main(["1.2.3", "456", str(archive), 'sparkle:edSignature="c2ln" length="41"', str(output)])
        raise AssertionError("length mismatch accepted")
    except SystemExit as error:
        assert "differs" in str(error)
    for bad in ["no signature here", 'length="42"']:
        try:
            module.parse_signature(bad); raise AssertionError("bad signature accepted")
        except ValueError:
            pass
print("Appcast: PASS")
