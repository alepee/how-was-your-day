#!/usr/bin/env python3
"""String Catalog tooling for HWYD.

Resources/Localizable.xcstrings is the source of truth for UI text (source language: fr).
Keys are the French text as written in the code, as the Swift compiler sees them
(interpolations become %@, %lld, %lf...).

  scripts/l10n.py extract   Build with -emit-localized-strings and list the keys found in the code.
  scripts/l10n.py sync      extract, then add new keys to the catalog and drop keys no longer in code.
  scripts/l10n.py check     Guard: fails when a key lacks a fr or en translation, when the code
                            uses a key missing from the catalog, or when a French-looking literal
                            in the app, the helper or HWYDCore is not localizable. --fast skips the build and only
                            compares literals with catalog keys.

A French literal that must stay as is (demo data, diagnostics) ends its line with `// l10n:ignore`.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources/Localizable.xcstrings"
INFO_CATALOG = ROOT / "Resources/InfoPlist.xcstrings"
SCRATCH = ROOT / ".build/l10n"
STRINGSDATA = ROOT / ".build/l10n-strings"
# hwyd-mcp is left out: its texts go to agents (tool schema, protocol errors), not to the UI.
TARGETS = ["HWYDApp", "HWYDPipeline"]
SOURCE_ROOTS = [ROOT / "Sources", ROOT / "Packages/HWYDCore/Sources"]
LANGUAGES = ["fr", "en"]
SPEC = re.compile(r"%(?:(\d+)\$)?(#@\w+@|[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaA]|arg)")
FRENCH_CHARS = re.compile(r"[àâçéèêëîïôûùüÿœæÀÂÇÉÈÊËÎÏÔÛÙÜŸŒÆ’«»]")
FRENCH_WORDS = re.compile(r"\b(?:le|la|les|des|du|une|un|et|ou|pour|avec|sans|dans|est|sont|aucun|aucune|pas|vous|votre|vos|cette|ces|sur|au|aux|par|puis|nouvelle|nouveau|voix|réglages|lire|ouvrir|fermer|annuler|supprimer|enregistrer|retour)\b", re.I)
IGNORE = "l10n:ignore"


def developer_env():
    env = dict(os.environ)
    xcode = "/Applications/Xcode.app/Contents/Developer"
    if "DEVELOPER_DIR" not in env and Path(xcode, "usr/bin/xcodebuild").exists():
        env["DEVELOPER_DIR"] = xcode
    return env


def in_repo_sources(path):
    p = Path(path).resolve()
    return any(root in p.parents for root in SOURCE_ROOTS)


# Keys declared with String(localized: "key", defaultValue: "…", comment: "…"): French value and comment.
DEFAULTS = {}


def extract(verbose=True):
    """Returns {key: [(file, line), ...]} for every localizable string in HWYD sources."""
    env = developer_env()
    # swiftc names each .stringsdata after its source file: two files with the same name in
    # modules built together would overwrite each other and hide keys.
    seen = {}
    for root in SOURCE_ROOTS:
        for source in root.rglob("*.swift"):
            module = source.relative_to(root).parts[0]
            if module != "HWYDMCP" and source.name != "main.swift":
                if source.name in seen:
                    sys.exit(f"l10n: {source.relative_to(ROOT)} and {seen[source.name].relative_to(ROOT)} share a file name; rename one")
                seen[source.name] = source
    if not STRINGSDATA.exists():
        # Incremental builds only emit .stringsdata for recompiled files: start from scratch.
        subprocess.run(["rm", "-rf", str(SCRATCH)], check=True)
    for target in TARGETS:
        out = STRINGSDATA / target
        out.mkdir(parents=True, exist_ok=True)
        cmd = ["swift", "build", "--package-path", str(ROOT), "--scratch-path", str(SCRATCH), "--target", target,
               "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(out)]
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout[-4000:] + result.stderr[-4000:])
            sys.exit(f"l10n: build of {target} failed")
    keys = {}
    for data in STRINGSDATA.glob("*/*.stringsdata"):
        content = json.loads(data.read_text())
        source = content.get("source", "")
        if not in_repo_sources(source) or not Path(source).exists():
            continue
        for table, entries in content.get("tables", {}).items():
            if table != "Localizable":
                continue
            for entry in entries:
                line = entry.get("location", {}).get("startingLine", 0)
                keys.setdefault(entry["key"], []).append((str(Path(source).relative_to(ROOT)), line))
                if "value" in entry or entry.get("comment"):
                    DEFAULTS[entry["key"]] = (entry.get("value", entry["key"]), entry.get("comment", ""))
    if verbose:
        print(f"l10n: {len(keys)} keys extracted", file=sys.stderr)
    return keys


def load(path=CATALOG):
    if path.exists():
        return json.loads(path.read_text())
    return {"sourceLanguage": "fr", "strings": {}, "version": "1.0"}


def save(catalog, path=CATALOG):
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def specs(text):
    return sorted(m.group(2).replace("arg", "@") for m in SPEC.finditer(text))


def sync():
    keys = extract()
    catalog = load()
    strings = catalog["strings"]
    added = [k for k in keys if k not in strings]
    removed = [k for k, v in strings.items() if k not in keys and v.get("extractionState") != "manual"]
    for key in added:
        value, comment = DEFAULTS.get(key, (key, ""))
        strings[key] = {"localizations": {"fr": {"stringUnit": {"state": "translated", "value": value}}}}
        if comment:
            strings[key]["comment"] = comment
    for key in removed:
        del strings[key]
    save(catalog)
    print(f"l10n: {len(added)} added, {len(removed)} removed. Translate new keys into en.")
    for key in added:
        print("  + " + key)


def localization_problems(path):
    catalog = load(path)
    problems = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        for language in LANGUAGES:
            loc = localizations.get(language)
            if not loc:
                problems.append(f"{path.name}: missing {language}: {key!r}")
                continue
            values = []
            if "stringUnit" in loc:
                values.append(loc["stringUnit"])
            for kind, cases in loc.get("variations", {}).items():
                if kind == "plural" and not {"one", "other"} <= set(cases):
                    problems.append(f"{path.name}: {language} plural needs one and other: {key!r}")
                values += [case["stringUnit"] for case in cases.values()]
            for sub in loc.get("substitutions", {}).values():
                values += [case["stringUnit"] for case in sub.get("variations", {}).get("plural", {}).values()]
            if not values or any(v.get("state") != "translated" or not v.get("value", "").strip() for v in values):
                problems.append(f"{path.name}: untranslated {language}: {key!r}")
            elif path == CATALOG and "substitutions" not in loc:
                for value in values:
                    # A plural form may omit the number ("one session"), never add an argument.
                    if not set(specs(value["value"])) <= set(specs(key)) or ("variations" not in loc and specs(value["value"]) != specs(key)):
                        problems.append(f"{path.name}: {language} placeholders differ from key: {key!r} -> {value['value']!r}")
    return problems


LITERAL = re.compile(r'(?<![\\#])"((?:[^"\\]|\\.)*)"')


def strip_interpolations(text):
    out, depth, i = [], 0, 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            out.append("\x00")
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


# Model-facing text, demo data and export formats stay French on purpose (docs/localization.md).
UNTRANSLATED_FILES = {"Summary.swift", "SummaryWorkflow.swift", "RemoteLLMProvider.swift", "AgentSummary.swift",
                      "DemoContent.swift", "SessionExporter.swift", "RecordingText.swift"}
SCANNED = ("Sources/HWYDApp", "Sources/HWYDPipeline", "Packages/HWYDCore/Sources/HWYDCore")


def french_literals():
    paths = [path for folder in SCANNED for path in sorted((ROOT / folder).glob("*.swift")) if path.name not in UNTRANSLATED_FILES]
    for path in paths:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//", 1)[0] if IGNORE not in line else ""
            if not code or '"""' in code:
                continue
            for match in LITERAL.finditer(code):
                text = strip_interpolations(match.group(1))
                plain = text.replace("\x00", " ")
                if FRENCH_CHARS.search(plain) or len(FRENCH_WORDS.findall(plain)) >= 1 and re.search(r"[a-z]{3,} [a-z]{2,}", plain, re.I):
                    yield str(path.relative_to(ROOT)), number, text


def normalized_key(key):
    return SPEC.sub("\x00", key)


def check(fast):
    problems = localization_problems(CATALOG) + localization_problems(INFO_CATALOG)
    catalog_keys = set(load()["strings"])
    if fast:
        known = {normalized_key(k).replace("\\n", "\n") for k in catalog_keys}
        for file, line, text in french_literals():
            if text.replace("\\n", "\n").replace('\\"', '"') not in known:
                problems.append(f"{file}:{line}: French literal without catalog entry: {text!r}")
    else:
        keys = extract(verbose=False)
        for key, places in keys.items():
            if key not in catalog_keys:
                file, line = places[0]
                problems.append(f"{file}:{line}: key missing from the catalog (run scripts/l10n.py sync): {key!r}")
        lines = {place for places in keys.values() for place in places}
        for file, line, text in french_literals():
            if (file, line) not in lines:
                problems.append(f"{file}:{line}: French literal is not localizable (use String(localized:) or mark `// l10n:ignore`): {text!r}")
    for problem in problems:
        print(problem)
    if problems:
        sys.exit(f"l10n: {len(problems)} problem(s)")
    print("l10n: catalog complete for " + ", ".join(LANGUAGES))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "extract":
        for key, places in sorted(extract().items()):
            print(f"{places[0][0]}:{places[0][1]}\t{key!r}")
    elif command == "sync":
        sync()
    elif command == "check":
        check("--fast" in sys.argv)
    else:
        sys.exit(__doc__)
