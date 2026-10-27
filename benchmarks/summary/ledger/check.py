#!/usr/bin/env python3
"""Self-check for the HWYD commitment ledger benchmark (standard library only).

  python3 benchmarks/summary/ledger/check.py

Verifies that the files on disk equal generate.py output, the Recording and
expected schemas, cross-language alignment, the annotation policy, late-change
distances in multi-window scenarios, split hygiene, phenomenon coverage and the
README coverage table. Exits non-zero on any failure.
"""
import sys

sys.dont_write_bytecode = True

import hashlib  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import uuid  # noqa: E402
from pathlib import Path  # noqa: E402

import generate  # noqa: E402

ROOT = generate.ROOT
REPO = ROOT.parents[2]
LANGUAGES = generate.LANGUAGES
ATLAS = [REPO / "benchmarks" / "summary" / "synthetic" / f"{language}.json" for language in LANGUAGES]
FORBIDDEN_CHARACTER = chr(0x2014)
RECORDING_KEYS = ["id", "title", "kind", "startedAt", "duration", "state", "revision", "transcriptVersion", "notes",
                  "noteEntries", "speakers", "segments", "transcriptState", "audioChunks", "consentAnnounced", "isDemo"]
SPEAKER_KEYS = ["id", "personID", "label", "confirmed", "source"]
SEGMENT_KEYS = ["id", "start", "end", "speakerID", "source", "text"]
EXPECTED_KEYS = ["schema", "synthetic", "split", "scenario", "input_language", "output_language", "participants",
                 "items", "forbidden", "forbidden_claims", "detail_checks"]
ITEM_KEYS = ["id", "phenomena", "description", "match_segment_ids", "expected_section", "acceptable_sections",
             "owner", "final_status", "due_text_contains", "due_date", "notes"]
FORBIDDEN_KEYS = ["id", "phenomena", "description", "section", "owner", "match_segment_ids"]
SECTIONS = {"decision", "task", "to_confirm", "open"}
STATUSES = {"active", "withdrawn", "superseded"}
LIMITS = {
    "short": {"turns": (18, 26), "characters": (1800, 3500), "participants": (3, 3), "unidentified": 1},
    "long": {"turns": (40, 60), "characters": (5000, 8000), "participants": (3, 4), "unidentified": 0},
}
SIZE_BY_PREFIX = {"d1": "short", "d2": "long", "h1": "short", "h2": "short", "h3": "long"}
LATE_MINIMUM = 15
ISO_DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
BANNED_NAMES = ["Camille", "Jordan", "Antoine", "Clément", "Nadia", "Marc"]
BANNED_TOPICS = ["claude", "plugin", "personal os", "memory system", "système de mémoire", "agent ia", "agents ia",
                 "ai agent"]
NGRAM = 6
COVERAGE = [
    ("1", "Reported speech, quoted person never commits", "quoted_never_commits"),
    ("1", "Reported speech, quoted person commits later in own words", "quoted_later_commits"),
    ("2", "Request without acceptance", "request_without_acceptance"),
    ("3", "Hesitant or conditional commitment", "hesitant_commitment"),
    ("4", "Obligation with no owner", "no_owner"),
    ("5", "Late correction by the owner", "late_correction"),
    ("6", "Late withdrawal by the owner", "late_withdrawal"),
    ("6", "Cancellation by the requester", "requester_cancellation"),
    ("7", "False withdrawal by a third party", "false_withdrawal_third_party"),
    ("8", "Relative deadline", "relative_deadline"),
    ("8", "Explicit date in words", "explicit_date"),
    ("8", "Literal YYYY-MM-DD date", "iso_date"),
    ("9", "Assignment by a third party, accepted", "third_party_assignment"),
    ("10", "Same person asks and accepts", "self_assignment"),
    ("11", "Assignment to an absent person", "absent_assignee"),
    ("12", "Promise by an unidentified voice", "unidentified_voice"),
    ("13", "Collective decision", "collective_decision"),
    ("13", "Personal choice, not a decision", "personal_choice"),
    ("13", "Proposal rejected", "proposal_rejected"),
    ("13", "Alternative adopted", "alternative_adopted"),
    ("13", "Idea deferred", "deferred_idea"),
    ("14", "Handover accepted by the new owner", "handover_accepted"),
    ("14", "Handover suggested, not accepted", "handover_suggested"),
    ("14", "Decision reversed late", "decision_reversal"),
]
KNOWN_TAGS = {tag for _, _, tag in COVERAGE} | {"reported_speech"}
LONG_ONLY = {"handover_accepted", "handover_suggested", "decision_reversal"}
NEEDS_LATE = {"late_correction", "late_withdrawal", "requester_cancellation", "false_withdrawal_third_party",
              "handover_suggested"}

failures = []


def fail(message):
    failures.append(message)


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def is_v5(value):
    try:
        parsed = uuid.UUID(value)
    except (TypeError, ValueError):
        return False
    return parsed.version == 5 and value == str(parsed).upper()


def words(text):
    return re.findall(r"[\w']+", text.lower().replace("’", "'"))


def has_word(text, word):
    return re.search(rf"(?<!\w){re.escape(word)}(?!\w)", text) is not None


def check_files(outputs):
    for path, content in outputs.items():
        target = ROOT / path
        if not target.exists():
            fail(f"missing generated file {path}")
        elif target.read_bytes() != content:
            fail(f"{path} differs from generate.py output; regenerate with --force")
    manifest = load(ROOT / "manifest.json")
    listed = {entry["path"] for entry in manifest["files"]}
    for entry in manifest["files"]:
        target = ROOT / entry["path"]
        if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != entry["sha256"]:
            fail(f"manifest hash mismatch for {entry['path']}")
    on_disk = {str(path.relative_to(ROOT)) for folder in ("dev", "holdout") for path in (ROOT / folder).glob("*")}
    for stray in sorted(on_disk - listed):
        fail(f"unlisted file {stray}")
    if len(listed) != 30:
        fail(f"manifest lists {len(listed)} files, expected 30")
    if manifest["uuid_namespace"] != str(generate.NAMESPACE).upper():
        fail("manifest namespace does not match generate.NAMESPACE")


def check_recording(scenario, language, record):
    split, slug = scenario["split"], scenario["slug"]
    where = f"{split}/{slug}-{language}"
    if list(record) != RECORDING_KEYS:
        fail(f"{where}: recording keys {list(record)}")
    fixed = {"kind": "meeting", "state": "sealed", "revision": 0, "transcriptVersion": 1, "notes": "",
             "noteEntries": [], "transcriptState": "ready", "audioChunks": [], "consentAnnounced": False,
             "isDemo": True}
    for key, value in fixed.items():
        if record.get(key) != value:
            fail(f"{where}: {key} is {record.get(key)!r}")
    if not isinstance(record["startedAt"], (int, float)) or isinstance(record["startedAt"], bool):
        fail(f"{where}: startedAt must be a number")
    if record["id"] != generate.uid(split, slug, language, "recording"):
        fail(f"{where}: recording id is not the deterministic UUIDv5")
    speakers = record["speakers"]
    labels = {}
    for position, speaker in enumerate(speakers):
        if list(speaker) != SPEAKER_KEYS or speaker["confirmed"] is not True:
            fail(f"{where}: bad speaker {speaker}")
        if speaker["id"] != generate.uid(split, slug, language, "speaker", position):
            fail(f"{where}: speaker id {position} is not deterministic")
        if speaker["personID"] != generate.uid(split, slug, "person", position):
            fail(f"{where}: personID {position} is not deterministic")
        if not (is_v5(speaker["id"]) and is_v5(speaker["personID"])):
            fail(f"{where}: speaker UUIDs must be uppercase v5")
        labels[speaker["id"]] = speaker
    if [speaker["source"] for speaker in speakers].count("mic") != 1:
        fail(f"{where}: exactly one speaker must use mic")
    if any(speaker["source"] not in ("mic", "system") for speaker in speakers):
        fail(f"{where}: invalid speaker source")
    previous_end = -1.0
    spoken = set()
    for position, segment in enumerate(record["segments"]):
        if [key for key in segment if key != "echoSuspect"] != SEGMENT_KEYS:
            fail(f"{where}: segment {position} keys {list(segment)}")
        if segment["id"] != generate.uid(split, slug, language, "segment", position) or not is_v5(segment["id"]):
            fail(f"{where}: segment {position} id is not the deterministic uppercase UUIDv5")
        if not (segment["end"] >= segment["start"] >= previous_end):
            fail(f"{where}: segment {position} times are not increasing")
        previous_end = segment["end"]
        if segment["source"] not in ("mic", "system"):
            fail(f"{where}: segment {position} source")
        speaker = labels.get(segment["speakerID"])
        if segment["speakerID"] is not None and speaker is None:
            fail(f"{where}: segment {position} has an unknown speakerID")
        if speaker and speaker["source"] != segment["source"]:
            fail(f"{where}: segment {position} source differs from its speaker")
        if speaker:
            spoken.add(speaker["label"])
        if not isinstance(segment["text"], str) or not segment["text"].strip():
            fail(f"{where}: segment {position} has no text")
    if record["duration"] < previous_end:
        fail(f"{where}: duration shorter than the last segment")
    if spoken != {speaker["label"] for speaker in speakers}:
        fail(f"{where}: every participant must speak")
    limits = LIMITS[scenario["size"]]
    if SIZE_BY_PREFIX[slug[:2]] != scenario["size"]:
        fail(f"{where}: size {scenario['size']} does not match prefix {slug[:2]}")
    turns = len(record["segments"])
    characters = sum(len(segment["text"]) for segment in record["segments"])
    unidentified = sum(segment["speakerID"] is None for segment in record["segments"])
    if not limits["turns"][0] <= turns <= limits["turns"][1]:
        fail(f"{where}: {turns} turns outside {limits['turns']}")
    if not limits["characters"][0] <= characters <= limits["characters"][1]:
        fail(f"{where}: {characters} characters outside {limits['characters']}")
    if not limits["participants"][0] <= len(speakers) <= limits["participants"][1]:
        fail(f"{where}: {len(speakers)} participants outside {limits['participants']}")
    if unidentified < limits["unidentified"]:
        fail(f"{where}: needs at least {limits['unidentified']} unidentified turn(s)")
    return turns, characters, unidentified


def check_expected(scenario, language, record, truth):
    where = f"{scenario['split']}/{scenario['slug']}-{language}.expected"
    if list(truth) != EXPECTED_KEYS:
        fail(f"{where}: keys {list(truth)}")
    header = {"schema": generate.EXPECTED_SCHEMA, "synthetic": True, "split": scenario["split"],
              "scenario": scenario["slug"], "input_language": language, "output_language": "fr"}
    for key, value in header.items():
        if truth.get(key) != value:
            fail(f"{where}: {key} is {truth.get(key)!r}")
    participants = [speaker["label"] for speaker in record["speakers"]]
    if truth["participants"] != participants:
        fail(f"{where}: participants {truth['participants']} != speakers {participants}")
    segments = {segment["id"]: (position, segment) for position, segment in enumerate(record["segments"])}
    names = {speaker["id"]: speaker["label"] for speaker in record["speakers"]}
    all_text = " ".join(segment["text"] for segment in record["segments"])

    def resolve(ids, label):
        if not ids:
            fail(f"{where}: {label} has no match_segment_ids")
        missing = [value for value in ids if value not in segments]
        if missing:
            fail(f"{where}: {label} references unknown segments {missing}")
            return []
        positions = [segments[value][0] for value in ids]
        if positions != sorted(set(positions)):
            fail(f"{where}: {label} match_segment_ids are not unique and in transcript order")
        return [segments[value][1] for value in ids]

    items = truth["items"]
    if len({item["id"] for item in items}) != len(items):
        fail(f"{where}: duplicate item ids")
    for item in items:
        label = f"item {item.get('id')}"
        if list(item) != ITEM_KEYS:
            fail(f"{where}: {label} keys {list(item)}")
            continue
        unknown = set(item["phenomena"]) - KNOWN_TAGS
        if not item["phenomena"] or unknown:
            fail(f"{where}: {label} phenomena {item['phenomena']}")
        matched = resolve(item["match_segment_ids"], label)
        section, owner, status = item["expected_section"], item["owner"], item["final_status"]
        if section not in SECTIONS or not set(item["acceptable_sections"]) <= SECTIONS:
            fail(f"{where}: {label} invalid section")
        if section not in item["acceptable_sections"] or len(set(item["acceptable_sections"])) != len(item["acceptable_sections"]):
            fail(f"{where}: {label} acceptable_sections must contain expected_section once")
        if owner is not None and owner not in participants:
            fail(f"{where}: {label} owner {owner} is not a participant")
        if status not in STATUSES:
            fail(f"{where}: {label} final_status {status}")
        if not all(isinstance(value, str) and value for value in item["due_text_contains"]):
            fail(f"{where}: {label} due_text_contains must hold non-empty strings")
        speakers = {names.get(segment["speakerID"]) for segment in matched}
        if section == "task" and (owner is None or owner not in speakers):
            fail(f"{where}: {label} task owner must speak in a matched turn")
        if section in ("decision", "open") and owner is not None:
            fail(f"{where}: {label} {section} items have no owner")
        if section == "to_confirm" and owner is not None:
            if "hesitant_commitment" not in item["phenomena"] or owner not in speakers:
                fail(f"{where}: {label} to_confirm owner is only set for the hesitant speaker")
        if "unidentified_voice" in item["phenomena"]:
            if section == "task" or owner is not None or not any(segment["speakerID"] is None for segment in matched):
                fail(f"{where}: {label} unidentified promise must stay owner-less and cite the voice")
        if "absent_assignee" in item["phenomena"] and (section == "task" or owner is not None):
            fail(f"{where}: {label} absent assignee must stay owner-less")
        if status == "withdrawn" and section != "task":
            fail(f"{where}: {label} only tasks are withdrawn here")
        if status == "superseded":
            replacements = [other for other in items if other is not item and other["final_status"] == "active"
                            and other["expected_section"] == section
                            and set(other["match_segment_ids"]) & set(item["match_segment_ids"])]
            if not replacements:
                fail(f"{where}: {label} superseded without an overlapping active replacement")
        due_date = item["due_date"]
        if ("iso_date" in item["phenomena"]) != (due_date is not None):
            fail(f"{where}: {label} iso_date tag and due_date must go together")
        if due_date is not None and (not ISO_DATE.fullmatch(due_date) or not any(due_date in segment["text"] for segment in matched)):
            fail(f"{where}: {label} due_date must literally appear in a matched turn")
        if not isinstance(item["notes"], str):
            fail(f"{where}: {label} notes must be a string")
    due_dates = {item["due_date"] for item in items if item["due_date"]}
    for literal in ISO_DATE.findall(all_text):
        if literal not in due_dates:
            fail(f"{where}: literal date {literal} is not annotated")

    forbidden = truth["forbidden"]
    if len({entry["id"] for entry in forbidden}) != len(forbidden):
        fail(f"{where}: duplicate forbidden ids")
    for entry in forbidden:
        label = f"forbidden {entry.get('id')}"
        if list(entry) != FORBIDDEN_KEYS:
            fail(f"{where}: {label} keys {list(entry)}")
            continue
        if not entry["phenomena"] or set(entry["phenomena"]) - KNOWN_TAGS:
            fail(f"{where}: {label} phenomena {entry['phenomena']}")
        if entry["section"] not in ("task", "decision"):
            fail(f"{where}: {label} section {entry['section']}")
        if entry["owner"] is not None and entry["owner"] not in participants:
            fail(f"{where}: {label} owner {entry['owner']} is not a participant")
        resolve(entry["match_segment_ids"], label)
        for item in items:
            same_owner = entry["owner"] is None or entry["owner"] == item["owner"]
            shared = set(entry["match_segment_ids"]) & set(item["match_segment_ids"])
            if entry["section"] in item["acceptable_sections"] and same_owner and shared:
                fail(f"{where}: {label} would flag the correct reading of item {item['id']}")
    for key in ("forbidden_claims", "detail_checks"):
        if not truth[key] or not all(isinstance(value, str) and value for value in truth[key]):
            fail(f"{where}: {key} must be a non-empty list of strings")


def check_alignment(scenario, files):
    slug = scenario["slug"]
    records = {language: files[language][0] for language in LANGUAGES}
    truths = {language: files[language][1] for language in LANGUAGES}

    def shape(record):
        speaker_index = {speaker["id"]: position for position, speaker in enumerate(record["speakers"])}
        return {
            "speakers": [(s["label"], s["source"], s["personID"]) for s in record["speakers"]],
            "segments": [(s["start"], s["end"], speaker_index.get(s["speakerID"]), s["source"]) for s in record["segments"]],
            "startedAt": record["startedAt"],
            "duration": record["duration"],
        }

    reference = shape(records["fr"])
    for language in LANGUAGES[1:]:
        if shape(records[language]) != reference:
            fail(f"{slug}: {language} speakers, timestamps or turn order differ from fr")
    ids = [set(segment["id"] for segment in records[language]["segments"]) for language in LANGUAGES]
    if ids[0] & ids[1] or ids[0] & ids[2] or ids[1] & ids[2]:
        fail(f"{slug}: segment ids must differ between languages")
    if len({records[language]["id"] for language in LANGUAGES}) != 3:
        fail(f"{slug}: recording ids must differ between languages")

    def normalized(language):
        position = {segment["id"]: index for index, segment in enumerate(records[language]["segments"])}
        truth = json.loads(json.dumps(truths[language]))
        truth.pop("input_language")
        for entry in truth["items"] + truth["forbidden"]:
            entry["match_segment_ids"] = [position[value] for value in entry["match_segment_ids"]]
        return truth

    base = normalized("fr")
    for language in LANGUAGES[1:]:
        if normalized(language) != base:
            fail(f"{slug}: {language} expectations differ from fr beyond segment ids")
    texts = [tuple(segment["text"] for segment in records[language]["segments"]) for language in LANGUAGES]
    same_fr = sum(m == f for m, f in zip(texts[2], texts[0]))
    same_en = sum(m == e for m, e in zip(texts[2], texts[1]))
    switched = len(texts[2]) - sum(m in (f, e) for m, f, e in zip(texts[2], texts[0], texts[1]))
    if min(same_fr, same_en, switched) < 3:
        fail(f"{slug}: mixed needs French, English and code-switched turns ({same_fr}/{same_en}/{switched})")
    if sum(f == e for f, e in zip(texts[0], texts[1])) > 0:
        fail(f"{slug}: some fr and en turns are identical")
    return same_fr, same_en, switched


def check_late(scenario, files):
    index = generate.turn_index(scenario)
    rows = []
    for item in scenario["items"]:
        needs = item["status"] in ("withdrawn", "superseded") or set(item["phenomena"]) & NEEDS_LATE
        if "late" not in item:
            if needs and scenario["size"] == "long":
                fail(f"{scenario['slug']}: item {item['id']} needs a late (origin, change) pair")
            continue
        origin, change = (index[tag] for tag in item["late"])
        rows.append((item["id"], origin + 1, change + 1, change - origin))
        if scenario["size"] == "long" and change - origin < LATE_MINIMUM:
            fail(f"{scenario['slug']}: item {item['id']} change only {change - origin} turns after origin")
        for language in LANGUAGES:
            record, truth = files[language]
            ids = next(entry["match_segment_ids"] for entry in truth["items"] if entry["id"] == item["id"])
            for position in (origin, change):
                if record["segments"][position]["id"] not in ids:
                    fail(f"{scenario['slug']}-{language}: item {item['id']} must cite turn {position + 1}")
    return rows


def check_hygiene(scenarios, data):
    texts = {}
    for scenario in scenarios:
        for language in LANGUAGES:
            record, truth = data[(scenario["slug"], language)]
            text = " ".join(segment["text"] for segment in record["segments"])
            texts[(scenario["split"], scenario["slug"], language)] = text
            blob = text + " " + json.dumps(truth, ensure_ascii=False)
            for name in BANNED_NAMES:
                if has_word(blob, name):
                    fail(f"{scenario['slug']}-{language}: banned name {name}")
            for topic in BANNED_TOPICS:
                if topic in text.lower():
                    fail(f"{scenario['slug']}-{language}: banned topic {topic!r}")
    names = {"dev": set(), "holdout": set()}
    for scenario in scenarios:
        names[scenario["split"]] |= {label for _, label, _ in scenario["speakers"]} | set(scenario["mentioned_names"])
    if names["dev"] & names["holdout"]:
        fail(f"names shared between splits: {sorted(names['dev'] & names['holdout'])}")
    for (split, slug, language), text in texts.items():
        other = names["holdout" if split == "dev" else "dev"]
        for name in other:
            if has_word(text, name):
                fail(f"{slug}-{language}: mentions {name} from the other split")

    def grams(text):
        tokens = words(text)
        return {tuple(tokens[i:i + NGRAM]) for i in range(len(tokens) - NGRAM + 1)}

    reference = set()
    for (split, _, _), text in texts.items():
        if split == "dev":
            reference |= grams(text)
    for path in ATLAS:
        reference |= grams(" ".join(segment["text"] for segment in load(path)["segments"]))
    for (split, slug, language), text in texts.items():
        if split == "holdout":
            for gram in sorted(grams(text) & reference):
                fail(f"{slug}-{language}: shares wording with dev or Atlas: {' '.join(gram)!r}")


def coverage(scenarios, data):
    columns = [scenario for scenario in scenarios]
    counts = {}
    for scenario in columns:
        truth = data[(scenario["slug"], "fr")][1]
        for entry in truth["items"] + truth["forbidden"]:
            for tag in entry["phenomena"]:
                counts[(tag, scenario["slug"])] = counts.get((tag, scenario["slug"]), 0) + 1
    dev = [s for s in columns if s["split"] == "dev"]
    holdout = [s for s in columns if s["split"] == "holdout"]
    header = ["#", "Phenomenon", "Tag"] + [s["slug"][:2] for s in dev] + ["dev"] + [s["slug"][:2] for s in holdout] + ["holdout"]
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join(["---"] * 3 + ["---:"] * (len(header) - 3)) + "|"]
    for number, label, tag in COVERAGE:
        dev_counts = [counts.get((tag, s["slug"]), 0) for s in dev]
        holdout_counts = [counts.get((tag, s["slug"]), 0) for s in holdout]
        if not sum(dev_counts) or not sum(holdout_counts):
            fail(f"phenomenon {tag} must appear in dev and holdout")
        if tag in LONG_ONLY and any(counts.get((tag, s["slug"]), 0) for s in columns if s["size"] != "long"):
            fail(f"phenomenon {tag} belongs to multi-window scenarios only")
        cells = [str(value) if value else "-" for value in dev_counts] + [str(sum(dev_counts))]
        cells += [str(value) if value else "-" for value in holdout_counts] + [str(sum(holdout_counts))]
        lines.append("| " + " | ".join([number, label, f"`{tag}`"] + cells) + " |")
    return "\n".join(lines)


def check_text_files():
    for path in sorted(ROOT.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            if FORBIDDEN_CHARACTER in path.read_text(encoding="utf-8"):
                fail(f"{path.relative_to(ROOT)} contains U+2014")


def main():
    outputs = generate.build()
    check_files(outputs)
    scenarios = generate.scenarios()
    slugs = [scenario["slug"] for scenario in scenarios]
    if [slug[:2] for slug in slugs] != ["d1", "d2", "h1", "h2", "h3"]:
        fail(f"unexpected scenario set {slugs}")
    data, stats, late_rows, mixing = {}, [], {}, {}
    for scenario in scenarios:
        files = {}
        for language in LANGUAGES:
            stem = f"{scenario['split']}/{scenario['slug']}-{language}"
            record, truth = load(ROOT / f"{stem}.json"), load(ROOT / f"{stem}.expected.json")
            stats.append((stem,) + check_recording(scenario, language, record))
            check_expected(scenario, language, record, truth)
            files[language] = data[(scenario["slug"], language)] = (record, truth)
        mixing[scenario["slug"]] = check_alignment(scenario, files)
        late_rows[scenario["slug"]] = check_late(scenario, files)
    check_hygiene(scenarios, data)
    table = coverage(scenarios, data)
    readme = ROOT / "README.md"
    if not readme.exists() or table not in readme.read_text(encoding="utf-8"):
        fail("README.md does not contain the current coverage table (printed below)")
    check_text_files()

    print("file                                              turns  chars  unidentified")
    for stem, turns, characters, unidentified in stats:
        print(f"{stem:50s} {turns:5d} {characters:6d} {unidentified:6d}")
    print("\nmixed turns (same as fr / same as en / code-switched)")
    for slug, (same_fr, same_en, switched) in mixing.items():
        print(f"  {slug}: {same_fr} / {same_en} / {switched}")
    print("\nlate changes (item, origin turn, change turn, distance)")
    for slug, rows in late_rows.items():
        print(f"  {slug}: " + ", ".join(f"{i} {o}->{c} ({d})" for i, o, c, d in rows))
    print("\n" + table + "\n")
    if failures:
        print(f"FAILED: {len(failures)} problem(s)")
        for message in failures:
            print(f"  - {message}")
        raise SystemExit(1)
    print("OK: all checks passed")


if __name__ == "__main__":
    main()
