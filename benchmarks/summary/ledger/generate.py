#!/usr/bin/env python3
"""Generate the HWYD commitment ledger benchmark fixtures.

Standard library only and deterministic: the same sources always produce the
same bytes. Existing files are never overwritten unless --force is given.

  python3 benchmarks/summary/ledger/generate.py          # refuses to overwrite
  python3 benchmarks/summary/ledger/generate.py --force  # rewrites every output

Sources: scenarios_dev.py and scenarios_holdout.py. Outputs: dev/, holdout/
and manifest.json. Run check.py afterwards.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import datetime  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402
import uuid  # noqa: E402
from pathlib import Path  # noqa: E402

import scenarios_dev  # noqa: E402
import scenarios_holdout  # noqa: E402

ROOT = Path(__file__).resolve().parent
NAMESPACE_NAME = "hwyd:benchmarks/summary/ledger"
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, NAMESPACE_NAME)
CREATED_AT = "2026-10-26T23:10:00Z"
LANGUAGES = ("fr", "en", "mixed")
EXPECTED_SCHEMA = "hwyd-ledger-expected/1"
MANIFEST_SCHEMA = "hwyd-ledger-manifest/1"
# Swift encodes Date as seconds since 2001-01-01T00:00:00Z.
REFERENCE_DATE = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
CHARACTERS_PER_SECOND = 14.5
TURN_REFERENCE = re.compile(r"\[\[([a-z0-9_]+)\]\]")


def scenarios():
    return scenarios_dev.SCENARIOS + scenarios_holdout.SCENARIOS


def uid(*parts):
    return str(uuid.uuid5(NAMESPACE, "/".join(str(part) for part in parts))).upper()


def text_of(turn, language):
    value = turn[language]
    return turn[value[1:]] if value in ("=fr", "=en") else value


def timeline(turns):
    """Shared timestamps for all languages, in seconds, one decimal."""
    rows, cursor = [], 0
    for index, turn in enumerate(turns):
        longest = max(len(text_of(turn, language)) for language in LANGUAGES)
        length = max(16, round(longest * 10 / CHARACTERS_PER_SECOND))
        if index:
            cursor += round(turn["gap"] * 10) if turn["gap"] is not None else 6 + (index * 7) % 9
        rows.append((cursor / 10, (cursor + length) / 10))
        cursor += length
    return rows


def turn_index(scenario):
    index = {}
    for position, turn in enumerate(scenario["turns"]):
        if turn["tag"] in index:
            raise ValueError(f"{scenario['slug']}: duplicate turn tag {turn['tag']}")
        index[turn["tag"]] = position
    return index


def recording(scenario, language):
    split, slug = scenario["split"], scenario["slug"]
    speakers, speaker_ids, sources = [], {}, {}
    for position, (key, label, source) in enumerate(scenario["speakers"]):
        speaker_ids[key] = uid(split, slug, language, "speaker", position)
        sources[key] = source
        speakers.append({
            "id": speaker_ids[key],
            "personID": uid(split, slug, "person", position),
            "label": label,
            "confirmed": True,
            "source": source,
        })
    segments = []
    for position, (turn, (start, end)) in enumerate(zip(scenario["turns"], timeline(scenario["turns"]))):
        key = turn["speaker"]
        segments.append({
            "id": uid(split, slug, language, "segment", position),
            "start": start,
            "end": end,
            "speakerID": speaker_ids[key] if key else None,
            "source": sources[key] if key else scenario["unidentified_source"],
            "text": text_of(turn, language),
        })
    started = datetime.datetime.fromisoformat(scenario["started_at"].replace("Z", "+00:00"))
    return {
        "id": uid(split, slug, language, "recording"),
        "title": f"{scenario['title']} ({language})",
        "kind": "meeting",
        "startedAt": int((started - REFERENCE_DATE).total_seconds()),
        "duration": math.ceil(segments[-1]["end"] + 2),
        "state": "sealed",
        "revision": 0,
        "transcriptVersion": 1,
        "notes": "",
        "noteEntries": [],
        "speakers": speakers,
        "segments": segments,
        "transcriptState": "ready",
        "audioChunks": [],
        "consentAnnounced": False,
        "isDemo": True,
    }


def expected(scenario, language, record):
    index = turn_index(scenario)
    segment_ids = [segment["id"] for segment in record["segments"]]

    def references(tags):
        return [segment_ids[position] for position in sorted(index[tag] for tag in tags)]

    def notes(entry):
        text = TURN_REFERENCE.sub(lambda match: f"turn {index[match.group(1)] + 1}", entry.get("notes", ""))
        if "late" in entry:
            origin, change = (index[tag] for tag in entry["late"])
            late = f"Original statement at turn {origin + 1}; change at turn {change + 1}, {change - origin} turns later."
            text = f"{text} {late}" if text else late
        return text

    items = [{
        "id": item["id"],
        "phenomena": item["phenomena"],
        "description": item["description"],
        "match_segment_ids": references(item["turns"]),
        "expected_section": item["section"],
        "acceptable_sections": item.get("acceptable", [item["section"]]),
        "owner": item["owner"],
        "final_status": item["status"],
        "due_text_contains": item["due"],
        "due_date": item.get("due_date"),
        "notes": notes(item),
    } for item in scenario["items"]]
    forbidden = [{
        "id": entry["id"],
        "phenomena": entry["phenomena"],
        "description": entry["description"],
        "section": entry["section"],
        "owner": entry["owner"],
        "match_segment_ids": references(entry["turns"]),
    } for entry in scenario["forbidden"]]
    return {
        "schema": EXPECTED_SCHEMA,
        "synthetic": True,
        "split": scenario["split"],
        "scenario": scenario["slug"],
        "input_language": language,
        "output_language": "fr",
        "participants": [label for _, label, _ in scenario["speakers"]],
        "items": items,
        "forbidden": forbidden,
        "forbidden_claims": scenario["forbidden_claims"],
        "detail_checks": scenario["detail_checks"],
    }


def dump(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def build():
    """Return {path relative to ROOT: bytes} for every generated file."""
    outputs, entries = {}, []
    for scenario in scenarios():
        split, slug = scenario["split"], scenario["slug"]
        for language in LANGUAGES:
            stem = f"{split}/{slug}-{language}"
            record = recording(scenario, language)
            truth = expected(scenario, language, record)
            outputs[f"{stem}.json"] = dump(record)
            outputs[f"{stem}.expected.json"] = dump(truth)
            entries.append({
                "path": f"{stem}.json", "kind": "recording", "split": split, "scenario": slug, "language": language,
                "sha256": hashlib.sha256(outputs[f"{stem}.json"]).hexdigest(),
                "segments": len(record["segments"]),
                "text_characters": sum(len(segment["text"]) for segment in record["segments"]),
                "speakers": len(record["speakers"]),
                "unidentified_segments": sum(segment["speakerID"] is None for segment in record["segments"]),
                "duration_seconds": record["duration"],
            })
            entries.append({
                "path": f"{stem}.expected.json", "kind": "expected", "split": split, "scenario": slug, "language": language,
                "sha256": hashlib.sha256(outputs[f"{stem}.expected.json"]).hexdigest(),
                "recording": f"{stem}.json",
                "items": len(truth["items"]),
                "forbidden": len(truth["forbidden"]),
            })
    outputs["manifest.json"] = dump({
        "schema": MANIFEST_SCHEMA,
        "created_at": CREATED_AT,
        "root": "benchmarks/summary/ledger",
        "uuid_namespace": str(NAMESPACE).upper(),
        "uuid_namespace_derivation": f"uuid5(NAMESPACE_URL, \"{NAMESPACE_NAME}\")",
        "uuid_names": {
            "recording": "{split}/{scenario}/{language}/recording",
            "speaker": "{split}/{scenario}/{language}/speaker/{index}",
            "person": "{split}/{scenario}/person/{index}",
            "segment": "{split}/{scenario}/{language}/segment/{index}",
        },
        "files": entries,
    })
    return outputs


def main():
    parser = argparse.ArgumentParser(description="Generate the ledger benchmark fixtures.")
    parser.add_argument("--force", action="store_true", help="overwrite existing generated files")
    args = parser.parse_args()
    outputs = build()
    existing = sorted(path for path in outputs if (ROOT / path).exists())
    if existing and not args.force:
        parser.error(f"{len(existing)} generated file(s) already exist (first: {existing[0]}); pass --force to overwrite")
    for path, data in outputs.items():
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(f"Wrote {len(outputs)} files under {ROOT}")


if __name__ == "__main__":
    main()
