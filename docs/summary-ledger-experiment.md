# Experiment: typed commitment ledger, then writing

Status: benchmark-only prototype. The application and the shipped `summary-v7-grounded-writing` workflow are unchanged. Nothing here is exposed in HWYD 0.4.0.

## Question

v7 asks one model response to write themes and, in the same object, free lists of decisions and tasks with an owner chosen by the model. Short-fixture runs lost explicit decisions from the decision list, added unpromised tasks with larger models, and promoted open questions. On a 90-minute recording, a generative verification step moved a task from its real owner to the person who had asked for it. This experiment tests whether a typed ledger of anchored statements, grounded by deterministic rules, and a writer that cannot emit commitment lists, reduce these failures without adding model calls.

## Pipeline

`scripts/ledger-summary.py` is a standalone, standard-library Python prototype. It reads a `Recording` JSON copy, calls an already loaded model on a loopback OpenAI-compatible endpoint, and writes every artifact under `build/`.

1. **Windows.** Complete turns are grouped into windows of at most 12,000 source characters, the shipped budget. A turn larger than its window fails the run; nothing is truncated. Turns keep global identifiers (`S1` to `Sn`) across windows.
2. **Ledger extraction, one call per window.** The model returns only `statements`. Each statement has a `kind` (`decision`, `task`, `tentative_task`, `unassigned_followup`, `proposal`, `open_question`, `withdrawn`), the anchor `turn`, a short French `text`, an `owner` chosen from identified participants or null, the `owner_turn` where that owner speaks to commit or accept, up to three `support_turns`, an optional `replaces` reference, and the deadline as spoken in `due_text`. Identifier fields are enums of the current window, and `replaces` may also name an item of the carried ledger.
3. **Deterministic derivation.** Code, not the model, decides where an item is rendered:
   - A `task` is listed as a next step only when `owner_turn` (or the anchor turn) is spoken by that owner. A task assigned by someone else without heard acceptance, a cited turn spoken by a different person (for example quoted first-person speech), an unidentified voice, or an echo-only turn is rendered as *to confirm*, with the reason. Assigning a task to a third party is valid when the assignee accepts in their own turn. The same person may ask for and accept a task.
   - `tentative_task` and `unassigned_followup` are always *to confirm*. `proposal` and `open_question` are rendered as open items. Non-commitment kinds never keep an owner.
   - A withdrawal or change applies only when grounded: a withdrawal must come from someone who took part in the item (requester, accepting owner or participant in the decision) or be confirmed by the owner; a handover needs the new owner's own acceptance. Otherwise the original item stays active, its listing says the claim is unconfirmed, and the claim itself is listed as *to confirm*. A replacement without a matching target changes nothing.
   - Within a window, `replaces` may name a turn instead of a carried item. It then targets only items stated or accepted in that turn, never an item that merely shares a supporting turn; when several match, the one with the same owner, then the same kind, is preferred. Kinds must be compatible: a commitment is replaced by a commitment or withdrawn, a decision by a decision, a reopening or a withdrawal. A withdrawal is an event and can never be replaced itself. A replacement must share at least one content word (four-letter prefix) with what it replaces, otherwise it is ignored; this catches a model linking two unrelated items, not a wrong paraphrase.
   - A restatement (same kind, owner and text, no new deadline) confirms the existing item instead of replacing it, and identical items within one window are folded together.
   - If the turn that grounds an owner also contains an explicit refusal or reservation cue in French or English ("je ne te le promets pas", "pas cette semaine", "I won't promise", "not this week"), the item is listed as *to confirm*. This lexical cue only degrades; it never deletes an item, and a turn that both commits and declines something else is degraded too.
   - A spoken deadline is kept only if its numbers, months and weekdays appear in the cited turns (French and English names are equivalent). `due_date` is filled only from a literal `YYYY-MM-DD` string.
4. **Bounded carried ledger.** Each later window receives active items from earlier windows, tasks and tentative tasks first, then the most recent, up to 12 items and 3,000 characters, with the first 100 characters of the anchor turn. Omitted items are logged per window. An omitted item cannot be targeted by a later correction, so the correction becomes an independent item. This is the main thing the bounded ledger can forget.
5. **Writing.** The writer receives original turns and a read-only ledger slice (at most 4,000 characters, omissions logged). Its schema contains only `details`, `key_points` and `overview`, so it cannot recreate commitment lists. A single-window conversation uses two calls in total, like v7. A longer session writes one chronological chapter per window, then one or more bounded executive calls for the overview and key points. There is no thematic routing and no generative verification in this arm.
6. **Assembly.** Decisions, next steps, items to confirm, open items and changes come from the ledger. Prose comes from the writer. A withdrawn item that had been listed as a commitment is shown as withdrawn; a dropped request or proposal is shown as not retained, so a refusal never reads as a withdrawn promise.

Every request is sequential and checked against the 24,000-character user-prompt ceiling before it is sent. Responses are validated before they become checkpoints. An invalid response gets one retry with a short reason prepended; a second invalid response fails the case. Checkpoint keys include the endpoint, model, reasoning setting, prompt version and hash, input checksum, budgets, stage, system prompt, schema and user prompt, so a change to an earlier window invalidates later windows that saw its ledger.

## Run

The prototype needs one model already loaded in a local server. It never loads or unloads models.

```sh
python3 scripts/test-ledger-summary.py
python3 scripts/ledger-summary.py prepare --fixtures atlas --fixtures dev
python3 scripts/ledger-summary.py run --fixtures atlas --fixtures dev \
  --model MODEL_IDENTIFIER --reasoning-effort none \
  --quantization 4bit --output build/summary-benchmark/ledger-dev-01
python3 scripts/ledger-summary.py score build/summary-benchmark/ledger-dev-01
```

`--prompt-version` selects the extraction instructions: `ledger-v1` was frozen before the first development run; `ledger-v2` and `ledger-v3` are the two revisions allowed after reading development failures (see Results). Only the extraction instructions differ between versions; a test pins the `ledger-v1` hash. The deterministic rules are not versioned: they are those of the current script. `rederive RUN --output DIR` applies the current rules to the cached responses of single-window cases without any model call, which separates the effect of rule changes from prompt changes. `--max-calls N` fails a case before it would send more than N model requests, retries included. `--window-characters` (1,000 to 12,000) shrinks windows to exercise several windows on a short fixture. Such runs test the carried-ledger mechanism, not the shipped bounds. Holdout fixtures require `--allow-holdout` and must be run once with a frozen prompt. `--cache-seed` resumes one recording from a previous run's checkpoints; the run is then marked `resumed` and its timing is not comparable with a fresh run.

Each case directory contains `benchmark.json` (provenance, parameters, status, model metadata, memory peaks), `metrics.json` (calls, retries, inference time, largest prompt in characters and tokens, ledger counts and omissions, and a crude stopword count of English-looking ledger texts and prose blocks, since the report must be French), `calls.jsonl`, `ledger.json`, `result.json`, `summary.md`, `prompts.json`, `memory.jsonl` and `cache/`. Memory sampling reuses the Darwin physical-footprint sampler of `scripts/benchmark-summary.py`.

`score` matches ledger items to expectations through cited turns. It also accepts directories produced by `scripts/benchmark-summary.py`: every v7 decision and action is scored as listed, owner-less actions included, and the action text stands in for the deadline because v7 keeps spoken deadlines there. Its flags (missed items, owner errors, promotions, stale states, forbidden hits, unmatched commitments, deadline issues) only assist manual review. Turns cited by several expected items, such as a recap, count for recall but not for owner or promotion flags. Each scored case also gets `review.md`, which lists every item next to its cited turns, then the expectations and flags. A cited turn proves that the item points somewhere plausible, not that the paraphrase is faithful.

## Fixtures

- `benchmarks/summary/synthetic/`: Atlas in French, English and mixed French/English. Development set. `*.ledger-expected.json` restates the original expectations as ledger items (decisions, tasks, items to confirm, open items, the replaced guide promise) and adds turn-based traps, such as a decision citing the budget or retention turns. They were written before any ledger run. Without them, `score` converts the original files to decision and task items only.
- `benchmarks/summary/ledger/`: additional development and holdout scenarios written by a separate agent that did not see the prompts. See that directory's README for the coverage table and the split rule.

## Results

Measured on 2026-10-27 with Qwen3.5 4B, MLX 4-bit, reasoning disabled, temperature 0, one request at a time on an Apple M4 Pro with 48 GB. The server advertised a 262,144-token context although 32,768 was requested. Recall and gates below come from manual review of each case against its cited turns; the automatic flags of `score` were only used to locate candidates. At temperature 0 a rerun of v7 on Atlas reproduced byte-identical outputs, so repetitions do not measure sampling variance here; robustness is read across languages and scenarios instead.

### Development set, shipped bounds (one window per case)

Nine cases: Atlas, `d1` and `d2`, each in French, English and mixed French/English. 18 expected decisions and 36 expected tasks. A case with no report counts as missed.

| Arm | Cases without report | Decisions | Tasks | Cases with a gate |
|---|---:|---:|---:|---:|
| v7 (shipped workflow) | 2 | 12/18 | 19/36 | 4 of 7 produced |
| ledger-v1 | 0 | 8/18 | 25/36 | 8 of 9 |
| ledger-v2 | 0 | 13/18 | 32/36 | 3 of 9 |
| ledger-v3 | 0 | 12/18 | 31/36 | 4 of 9 |
| ledger-v2 prompt with v3 rules (re-derived) | 0 | 13/18 | 34/36 | 1 of 9 |

The last row applies the final rules to the cached ledger-v2 responses with `rederive`, without new inference; the prose is the ledger-v2 prose. It was selected as the final system by a rule written before the last v3 cases were read: fewest cases with a gate, then recall. ledger-v3's extra prompt sentences fixed some cases and broke others (an adopted pilot became a person's task, a corrected date was no longer linked, a reversed decision stayed active): with this 4B model, small prompt edits move individual decisions and links from one case to another.

v7 also listed 13 decisions that were not adopted (open questions, an absent accountant's job, a personal choice, a deferred idea), kept tasks after a handover or a cancellation, and gave a wrong deadline in one case. Its two failed cases stopped at extraction on its own owner-evidence check; in the English `d1` case the rejected response, read from the server log, listed six tasks for a meeting with three.

ledger-v1 failures were systematic: a corrected deadline or deliverable was encoded as a withdrawal, so the corrected task disappeared; adopted proposals stayed proposals; a refusal was cited as the owner's acceptance. With ledger-v2 the corrected version became the active task in seven of the nine cases with a correction; in Atlas English it was demoted to a tentative task, and in mixed `d2` the linked correction kept a wrong deliverable text ("final menu" instead of the provisional one). Most decisions were recovered, but a refusal still grounded a task or a handover in three `d2` cases.

### Holdout, run once with the frozen system

Nine cases (`h1`, `h2`, `h3`, each in three language forms), shipped bounds, ledger-v2 prompt with the final rules: two calls per case, 37 to 79 seconds of inference, largest user prompt 14,056 characters, sampled server footprint peak 7.5 to 8.3 GiB, no retry. All 12 expected decisions and 37 of 39 expected tasks were listed with the right owner. **Eight of nine cases nevertheless contain at least one gate**; only English `h2` is clean.

Counterexamples: a job left to an absent person was attributed to the present speaker (`h1`, `h3`); a chair's agenda wish and a collective "we will meet to finish" became personal tasks (`h1`); a refusal phrased outside the cue list ("je ne vais pas m'avancer") grounded a task (`h2`); an unowned obligation was linked to the speaker of another promise (`h2`); a personal habit was listed as a decision or a task, and a fact as a task (`h3`); third-party doubts became a cancellation decision (`h3`); a cancelled request and a corrected deliverable stayed active (`h3` mixed). One gate comes from a rule flaw: a withdrawal raised by a third party was applied because the model cited the owner's original promise as the owner's confirmation (`h2` mixed). The fix, requiring a later owner turn distinct from the item, was found on holdout data and is not applied here.

The development result (one case with a gate out of nine) therefore did not generalize. Not run, for lack of time: `h3` in four windows, v7 on the holdout, a 9B confirmation and the 90-minute recording. The 9B development pass was run afterwards; see [the capacity follow-up](summary-capacity-followup.md).

### Several windows (development, mechanism only)

With four windows of 3,000 characters on `d2`, the carried ledger linked the late reversal of the closing day in one language of three with ledger-v1 and in all three with ledger-v2 and v3, kept handovers and grounded withdrawals, and blocked unfounded ones. Short windows also produced more false decisions and tasks than the single-window runs. The bounded carried ledger omitted 1 to 9 active items in windows 3 and 4, almost always proposals and open questions, once a decision, never a task; writer slices never omitted anything. Nine calls per case, about 110 seconds.

### Verdict

Not accepted, and not a production candidate. The typed ledger with deterministic grounding is more robust than v7 on commitments in these synthetic cases (no failed case, many more tasks with the right owner, far fewer stale states) and its rules block several trap classes. But a 4B model still misreads individual turns, and rules that only check who spoke cannot catch a right voice with a wrong meaning. The 90-minute run was not attempted because the precondition, no gate on short cases, was not met; the Clément/Antoine reattribution therefore remains unmeasured for this design.

Next hypothesis: replace free item generation by a closed per-turn classification (proposes, accepts, declines, defers, requests, decides, corrects, withdraws, quotes, none) with the turn it refers to, build items in code from these labels, and evaluate it on new scenarios, since the current holdout has now been read.

## Limits

- The ledger rules ground identity in who speaks, which is necessary but not sufficient. A model that anchors a task on a quoted first-person sentence spoken by the quoting person still produces a wrong owner that the rules accept.
- Classification, task text and decision status remain model judgments. Rules cannot detect a missing item or a wrong paraphrase, such as a provisional menu rewritten as the final one.
- The refusal cue is a short French and English phrase list. Other phrasings are missed, and a turn that commits to one thing while declining another is degraded to *to confirm*.
- The replacement link check compares four-letter word prefixes of model-written French texts. It rejects some unrelated links, not all, and can reject a legitimate correction worded without any shared word.
- Small prompt edits moved individual decisions and links between cases. Two iterations on six development scenarios are not enough to separate a real improvement from this instability.
- The writer is the v7-style writer without commitment fields. It still adds unsupported causal links and distorts some details.
- Long sessions are written chronologically per window, not by theme, so recurring topics can be split across chapters. Prose quality is not comparable with v7's thematic routing.
- The synthetic scenarios are clean transcripts written by one annotator, without recognition errors, overlaps or echo. They test classification traps, not ASR robustness.
- Character budgets are not tokenizer limits. Server memory depends on the loaded context and runtime, not only on prompt size.
