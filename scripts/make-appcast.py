#!/usr/bin/env python3
"""Write the Sparkle appcast for one release.

  scripts/make-appcast.py VERSION BUILD ARCHIVE SIGNATURE OUTPUT --notes NOTES.md [--url URL]

SIGNATURE is the `sparkle:edSignature="…" length="…"` fragment printed by Sparkle's
`sign_update`. The appcast holds the latest release only: Sparkle compares it with the
installed build number, so older items are not needed. It is uploaded as a release asset and
read through releases/latest/download/appcast.xml.

The release notes are embedded as Markdown (Sparkle 2.9+, macOS 12+) rather than linked: a
`releaseNotesLink` to the GitHub release page shows the whole site, with its header and menus,
in the small notes pane of the update prompt.
"""
import argparse
import plistlib
import re
import sys
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

REPO = "alepee/how-was-your-day"
ROOT = Path(__file__).resolve().parent.parent


def parse_signature(fragment):
    signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', fragment)
    length = re.search(r'length="(\d+)"', fragment)
    if not signature or not length:
        raise ValueError("Unexpected sign_update output: " + fragment.strip())
    return signature.group(1), int(length.group(1))


def update_notes(markdown, page):
    """Release notes as shown in the update prompt: without the title, which repeats the prompt's
    own heading, or the badges, which are remote images; with a link to the full release page."""
    lines = markdown.strip().splitlines()
    while lines and (lines[0].startswith("# ") or lines[0].startswith("[![") or not lines[0].strip()):
        lines.pop(0)
    if not lines:
        raise ValueError("Release notes are empty")
    body = "\n".join(lines).rstrip() + f"\n\n[Full release notes on GitHub]({page})\n"
    # The notes sit in a CDATA section, which cannot contain its own terminator.
    return body.replace("]]>", "]]]]><![CDATA[>")


def appcast(version, build, url, signature, length, minimum_system, notes, date=None):
    page = f"https://github.com/{REPO}/releases/tag/v{version}"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>How Was Your Day</title>
    <link>https://github.com/{REPO}</link>
    <item>
      <title>{escape(version)}</title>
      <pubDate>{date or formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system)}</sparkle:minimumSystemVersion>
      <link>{escape(page)}</link>
      <description sparkle:format="markdown"><![CDATA[{update_notes(notes, page)}]]></description>
      <enclosure url={quoteattr(url)} type="application/octet-stream" sparkle:edSignature={quoteattr(signature)} length="{length}"/>
    </item>
  </channel>
</rss>
"""


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("version"); parser.add_argument("build"); parser.add_argument("archive")
    parser.add_argument("signature"); parser.add_argument("output")
    parser.add_argument("--notes", required=True, help="Release notes in Markdown")
    parser.add_argument("--url", help="Archive URL (defaults to the GitHub release asset)")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or not args.build.isdigit():
        raise SystemExit("Expected VERSION x.y.z and a numeric BUILD")
    signature, length = parse_signature(args.signature)
    archive = Path(args.archive)
    if archive.stat().st_size != length:
        raise SystemExit(f"Signed length {length} differs from {archive} ({archive.stat().st_size} bytes)")
    with open(ROOT / "Resources/Info.plist", "rb") as plist:
        minimum_system = plistlib.load(plist)["LSMinimumSystemVersion"]
    url = args.url or f"https://github.com/{REPO}/releases/download/v{args.version}/{archive.name}"
    Path(args.output).write_text(appcast(args.version, args.build, url, signature, length, minimum_system,
                                              Path(args.notes).read_text()))
    print("Appcast: " + args.output)


if __name__ == "__main__":
    main(sys.argv[1:])
