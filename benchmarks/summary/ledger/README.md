# Commitment ledger benchmark

Synthetic meeting transcripts that probe how a summarizer classifies commitments: what was decided, who owns which task, what still needs confirmation and what stays open. Each scenario sets traps that a plain extractor tends to fall into: reported speech, requests nobody accepted, hesitations, obligations without an owner, absent assignees, unidentified voices, late corrections, withdrawals, false withdrawals, handovers and reversed decisions.

Every meeting, company, person and figure is invented. Nothing comes from a real recording. Each scenario exists in three versions with the same speakers, turn order and timestamps: French (`fr`), English (`en`) and mixed (`mixed`, a bilingual team where speakers alternate languages and some turns code-switch). The expected report language is always French; expectations are written in English.

## Dev and holdout

- `dev/` may be read, inspected and used to iterate on prompts or code.
- `holdout/` is for final measurement only. **Holdout is never used for prompt or code tuning; it is run once with a frozen system.** Do not open `holdout/` or `scenarios_holdout.py` while tuning, and do not copy holdout content into prompts, issues or commit messages.

Holdout scenarios use other business domains, other names and other wording than dev and than the Atlas fixtures in `../synthetic/`. `check.py` enforces disjoint names and the absence of any shared six-word sequence.

## Layout

| Path | Content |
|---|---|
| `dev/<scenario>-<lang>.json` | Input Recording JSON, same shape as `../synthetic/fr.json` |
| `dev/<scenario>-<lang>.expected.json` | Expected reading of that input |
| `holdout/...` | Same layout for holdout |
| `manifest.json` | Path, split, scenario, language, SHA-256, segment and character counts of every file, `created_at` and the UUID namespace |
| `scenarios_dev.py`, `scenarios_holdout.py` | Source of truth: turns in three languages and annotations |
| `generate.py` | Deterministic generator, standard library only |
| `check.py` | Self-check, standard library only |

Dev scenarios:

- `d1-trade-fair-booth`, short (21 turns): a chair maker prepares its trade fair booth. Hélène (mic), Bastien and Mehdi, plus one unidentified voice.
- `d2-second-restaurant-opening`, multi-window (54 turns): a restaurant group prepares its second site. Lucie (mic), Karim, Sophie and Thomas. Every late change happens at least 15 turns after the statement it changes, so a windowed evaluation sees them in different windows.

Holdout scenarios: `h1` and `h2` are short like `d1`, `h3` is multi-window like `d2`. They are described only by the coverage table below; turn and character counts are in `manifest.json`.

## Regenerate and validate

```sh
python3 benchmarks/summary/ledger/generate.py --force   # rewrite every output from the sources
python3 benchmarks/summary/ledger/check.py              # self-check, non-zero exit on failure
for f in benchmarks/summary/ledger/{dev,holdout}/*-{fr,en,mixed}.json; do
  python3 scripts/benchmark-summary.py --recording "$f" --prepare-only
done
```

`generate.py` refuses to overwrite existing files without `--force`. Its output is byte-identical from one run to the next (`created_at` is a constant in the script). `check.py` compares the files on disk with a fresh in-memory generation, then checks the Recording shape, deterministic UUIDs, cross-language alignment, the annotation policy below, late-change distances, split hygiene, phenomenon coverage, the absence of U+2014 in every file, and that this README contains the current coverage table. `--prepare-only` only parses a recording; it uses neither the network nor a model.

## Recording conventions

- One participant uses `mic`, the others `system`. An unidentified voice is a segment with `speakerID: null` and `source: "system"`.
- Timestamps are in seconds and shared by the three languages. A five-second silence precedes each "nobody answered, so I will do it" turn.
- `startedAt` counts seconds since 2001-01-01T00:00:00Z (Swift `Date` encoding) and points to a fixed day in October 2026, so a model can be tempted to turn "Friday" into a calendar date. It must not.
- French text uses typographic apostrophes and « » quotes. In mixed versions a quoted sentence is often in the quoted person's language.

## UUIDs

All identifiers are uppercase UUIDv5 values in the namespace `A5D4223F-74A4-550C-9DF3-51E08CCE7D90`, itself `uuid5(NAMESPACE_URL, "hwyd:benchmarks/summary/ledger")`. Names:

| Identifier | Name |
|---|---|
| Recording `id` | `{split}/{scenario}/{language}/recording` |
| Speaker `id` | `{split}/{scenario}/{language}/speaker/{index}` |
| Speaker `personID` | `{split}/{scenario}/person/{index}`, shared by the three languages |
| Segment `id` | `{split}/{scenario}/{language}/segment/{index}` |

Segment and speaker identifiers therefore differ between language versions, as in the Atlas fixtures.

## Expected files

Schema `hwyd-ledger-expected/1`: `schema`, `synthetic`, `split`, `scenario`, `input_language`, `output_language` (always `fr`), `participants`, `items`, `forbidden`, `forbidden_claims`, `detail_checks`. Each item has `id`, `phenomena`, `description`, `match_segment_ids`, `expected_section`, `acceptable_sections`, `owner`, `final_status`, `due_text_contains`, `due_date` and `notes`. Forbidden entries have `id`, `description`, `section`, `owner` and `match_segment_ids`, plus one extension: `phenomena`, so trap rates can be broken down by phenomenon.

Conventions:

- `match_segment_ids` lists, in transcript order, every turn that states, accepts, corrects or supports the item, including the turn that corrects, withdraws or supersedes it.
- In `notes`, "turn N" is the 1-based position in `segments`. Items changed late say which turns hold the original statement and the change.
- `due_text_contains` holds lowercase French substrings, because the report is French; compare case-insensitively. Weekdays and relative deadlines use the French words (`vendredi`, `demain`, `ce soir`, `fin du mois`). For a literal ISO date only the day number is kept (`10`), so both "10 novembre 2026" and "2026-11-10" match, and `due_date` carries the exact value. Timing relative to an event ("before opening", "before registration closes") leaves the list empty and is explained in `notes`.
- `due_date` stays null unless the source literally contains a YYYY-MM-DD string.
- An owner who corrects the date or the deliverable of their own commitment keeps one active item carrying the corrected version; the obsolete version is listed in `forbidden_claims`.
- An accepted handover gives two items: the old one `superseded`, the new one `active`, both citing the handover turns. A reversed decision works the same way.
- A task withdrawn by its owner, or cancelled by the person who requested it, stays in the file with `final_status: withdrawn`: it must not be reported as a live task.
- A rejected proposal is an `open` item with `final_status: active`, because the report should still show it as not adopted. When the rejection is part of the adopted alternative, `decision` is also acceptable.
- A forbidden entry describes an output entry that must not exist: one in `section`, owned by `owner` (null means any owner, including none), citing any of `match_segment_ids`. `check.py` verifies that no expected reading would trigger a forbidden entry.
- `forbidden_claims` lists statements a correct French report must not make, `detail_checks` facts its prose should preserve.

## Section policy

- `decision`: a collective choice explicitly adopted. Not a personal preference, not a proposal under discussion.
- `task`: a firm future action whose owner commits or accepts in a turn spoken by that owner. A third party may assign it if the owner accepts. The same person may both ask and accept.
- `to_confirm`: something that may need doing but lacks a firm owner commitment: hesitant or conditional commitments, requests without acceptance, owner-less obligations, assignments to absent people, promises from an unidentified voice, assignments not acknowledged by the assignee. For hesitant cases `owner` is the hesitant person; otherwise `owner` is null.
- `open`: proposals not adopted, rejected proposals, explicitly open questions, ideas deferred to later.
- `final_status`: `withdrawn` when the item was cancelled by its owner or its requester, `superseded` when a later statement replaced it (the replacement is a separate active item), otherwise `active`.

A third party who says a task is no longer needed changes nothing: only the owner or the requester can withdraw it. A promise quoted or imitated by someone else is not a commitment of either person until the quoted person commits in their own turn.

## Coverage

Each cell counts the expected items and forbidden entries carrying the tag (French files; the other languages are identical). Row numbers follow the phenomenon list of the benchmark brief.

| # | Phenomenon | Tag | d1 | d2 | dev | h1 | h2 | h3 | holdout |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | Reported speech, quoted person never commits | `quoted_never_commits` | 1 | - | 1 | 1 | - | - | 1 |
| 1 | Reported speech, quoted person commits later in own words | `quoted_later_commits` | - | 1 | 1 | - | 1 | - | 1 |
| 2 | Request without acceptance | `request_without_acceptance` | 2 | 2 | 4 | - | 2 | 2 | 4 |
| 3 | Hesitant or conditional commitment | `hesitant_commitment` | - | 2 | 2 | 2 | - | 2 | 4 |
| 4 | Obligation with no owner | `no_owner` | 2 | 2 | 4 | - | 2 | 2 | 4 |
| 5 | Late correction by the owner | `late_correction` | 1 | 1 | 2 | - | 1 | 1 | 2 |
| 6 | Late withdrawal by the owner | `late_withdrawal` | - | 1 | 1 | 1 | - | 1 | 2 |
| 6 | Cancellation by the requester | `requester_cancellation` | - | 1 | 1 | - | - | 1 | 1 |
| 7 | False withdrawal by a third party | `false_withdrawal_third_party` | - | 1 | 1 | - | 1 | 1 | 2 |
| 8 | Relative deadline | `relative_deadline` | 3 | 8 | 11 | 3 | 4 | 6 | 13 |
| 8 | Explicit date in words | `explicit_date` | 1 | - | 1 | 1 | - | 1 | 2 |
| 8 | Literal YYYY-MM-DD date | `iso_date` | - | 1 | 1 | - | 1 | - | 1 |
| 9 | Assignment by a third party, accepted | `third_party_assignment` | 2 | 3 | 5 | 2 | 2 | 4 | 8 |
| 10 | Same person asks and accepts | `self_assignment` | 1 | 1 | 2 | - | 1 | 1 | 2 |
| 11 | Assignment to an absent person | `absent_assignee` | - | 2 | 2 | 2 | - | 2 | 4 |
| 12 | Promise by an unidentified voice | `unidentified_voice` | 2 | - | 2 | 2 | - | - | 2 |
| 13 | Collective decision | `collective_decision` | 1 | 3 | 4 | 1 | 1 | 3 | 5 |
| 13 | Personal choice, not a decision | `personal_choice` | - | 1 | 1 | - | 1 | 1 | 2 |
| 13 | Proposal rejected | `proposal_rejected` | 1 | - | 1 | 1 | - | - | 1 |
| 13 | Alternative adopted | `alternative_adopted` | 1 | - | 1 | 1 | - | - | 1 |
| 13 | Idea deferred | `deferred_idea` | - | 2 | 2 | - | - | 2 | 2 |
| 14 | Handover accepted by the new owner | `handover_accepted` | - | 2 | 2 | - | - | 2 | 2 |
| 14 | Handover suggested, not accepted | `handover_suggested` | - | 2 | 2 | - | - | 2 | 2 |
| 14 | Decision reversed late | `decision_reversal` | - | 2 | 2 | - | - | 2 | 2 |

Items quoting someone also carry the umbrella tag `reported_speech`. Row 14 appears only in the multi-window scenarios.

## Limits

- The transcripts are clean: no disfluencies, misrecognitions or overlapping speech.
- Literal ISO dates are rare in speech; here they come from someone reading a portal or a document aloud.
- One annotator wrote every expectation. Where a reading is genuinely ambiguous, `acceptable_sections` lists the alternatives and `notes` explains why.
