# Follow-up: does a larger model fix the typed ledger?

Status: benchmark-only. The application and the shipped `summary-v7-grounded-writing` workflow are unchanged. This follows [the typed ledger experiment](summary-ledger-experiment.md), whose development and holdout results with Qwen3.5 4B were rejected.

## Question

The 4B failures left on the frozen system (ledger-v2 prompt, final deterministic rules) were local misreadings: an adopted proposal left as a proposal, a refusal read as acceptance, a corrected deliverable rewritten with the wrong content. The plan, written before the holdout, allowed one development pass with Qwen3.5 9B to test whether these errors are a matter of model capacity. No prompt, rule, fixture or budget was changed for this pass, and no new design was tried.

## Setup and provenance

- Same commit and script as the 4B final system: `scripts/ledger-summary.py` sha256 `2a094d46…a180`, prompt `ledger-v2` (hash `b48433b9…`), frozen fixtures and expectations checked before the run, deterministic tests passing.
- `qwen/qwen3.5-9b`, MLX 4-bit, reasoning disabled, temperature 0, one request at a time, parallel 1, the only model loaded. As with the 4B, 32,768 tokens were requested and the server advertised 262,144.
- Shipped bounds: 24,000-character user-prompt ceiling, 12,000-character windows (one window per case), carried ledger of 12 items or 3,000 characters, 4,000-character writer slice, at most 12 calls per case.
- The configured prompt version, budgets and reasoning settings in each case's `benchmark.json` match the 4B reference; the model identifier differs. The 4B reference applies the final rules to cached ledger-v2 responses (`rederive`); the 9B applies them live. Rules and prompt are identical.
- Nine development cases: Atlas, `d1` and `d2`, each in French, English and mixed French/English. 18 expected decisions, 36 expected tasks. The holdout was not run with the 9B, as planned.

Recall and gates come from manual review of every case against its cited turns. A task with a wrong deadline is not counted, as in the 4B review. A gate is any of: unsupported task in next steps, wrong owner, invented or wrong deadline, wrong status (unsupported change applied, or an old state left active), an unowned or hesitant item promoted to a task, a proposal promoted to a decision.

## Results

| | Qwen3.5 4B | Qwen3.5 9B |
|---|---:|---:|
| Calls per case | 2 | 2 |
| Retries, failed cases | 0, 0 | 0, 0 |
| Inference per case | 30.7 to 70.6 s | 40.8 to 91.7 s |
| Inference, nine cases | 411.9 s | 551.5 s (+34%) |
| Largest user prompt | 13,970 characters | 13,997 characters |
| Idle server footprint | 5.70 GiB | 7.30 GiB |
| Sampled server peak | 7.21 to 8.45 GiB | 9.65 to 11.08 GiB |
| Decisions recalled | 13/18 | 16/18 |
| Tasks recalled, right owner and deadline | 34/36 | 33/36 |
| Unsupported tasks listed | 0 | 2 |
| Cases with at least one gate | 1 of 9 | 5 of 9 |

Per case (decisions, tasks, gates):

| Case | 4B | 9B |
|---|---|---|
| Atlas FR | 3/3, 2/2, none | 2/3, 2/2, none |
| Atlas EN | 2/3, 1/2, none | 3/3, 2/2, none |
| Atlas mixed | 3/3, 2/2, none | 3/3, 2/2, none |
| `d1` EN | 1/1, 3/3, none | 1/1, 2/3, corrected date not applied |
| `d1` FR | 1/1, 3/3, none | 1/1, 3/3, unowned obligation listed as a task |
| `d1` mixed | 1/1, 3/3, none | 1/1, 2/3, corrected date not applied |
| `d2` EN | 1/2, 7/7, none | 2/2, 7/7, none |
| `d2` FR | 0/2, 7/7, none | 2/2, 7/7, reversed decision left active; personal habit listed as a task |
| `d2` mixed | 1/2, 6/7, wrong deliverable text | 1/2, 6/7, kept task demoted to "nobody owns it" |

The automatic `score` flags reported 16/18 decisions and 35/36 tasks for the 9B. They do not check the value of a deadline that a cited turn supports, so the two stale dates below counted as recalled.

### What the 9B fixed

- Adopted proposals are recognized as decisions on `d2`: the shared till software in all three languages, and the Monday to Tuesday closing reversal in English and French (the 4B left most of them as proposals).
- Atlas English: the postponed announcement is a decision and the corrected guide draft is a firm task.
- No refusal grounded a task or a handover; the press tasting and the declined hygiene handover never became someone's task.

### Counterexamples

- **Corrected deadline not applied** (`d1` English and mixed). Mehdi first promises the dock address "before November 6", then corrects it to November 9. The 9B cites both turns on one task but keeps "before November 6". The deadline rule accepts it because "6" occurs in the cited turns. Model error; the 4B linked this correction in all three languages.
- **Unowned obligation listed as a task** (`d1` French). "We must declare the badge names before registration closes", said by Mehdi, becomes Mehdi's task. The voice is right, so the rule accepts it.
- **Personal habit listed as a task** (`d2` French). Sophie keeping her own spreadsheet for bank reconciliations becomes her task.
- **Reversed decision left active** (`d2` French). The Tuesday decision points its `replaces` at the turn of the original Monday proposal, which the Monday decision had already replaced, instead of the decision itself. The rules do not follow a replacement chain, as documented, so both decisions are listed. Model linking error.
- **Kept task demoted** (`d2` mixed). Lucie's suggestion to hand the hygiene registrations to Sophie, declined by Sophie, is encoded as an owner-less follow-up that "replaces" Karim's task, which drops to *to confirm, nobody owns it*. The code accepts the change because Lucie is in the item's authority: the model had cited an unrelated Lucie turn as support for Karim's task. This is a model error made possible by a rule weakness, not a code defect against the documented rules: authority is computed from model-chosen support turns, and a demotion to no owner does not require the owner's own turn.

The prose has the same writer defects as before, sometimes in contradiction with correct lists: tote bags translated as "backpacks", the declined price grid described as Bastien's proposal or commitment, and an invented role for Thomas.

## Verdict

Switching to this 9B model with the frozen workflow: **not sufficient in this experiment**. The 9B recovers three decisions net and none of its gates comes from a code bug, but it lists two unsupported tasks, drops a correction the 4B handled, and goes from one to five development cases with a gate, for 34% more inference time and about 2.5 GiB more peak memory. Its failures belong to the classes already seen on the 4B holdout: the right voice with the wrong meaning, a replacement linked to the wrong item, an old value kept next to a cited correction. Rules that only check who speaks do not catch them. Following the plan, neither a 9B holdout nor the 90-minute run was attempted.

## Limits

- One pass at temperature 0 on nine synthetic development cases; earlier Atlas reruns were byte-identical, but deterministic decoding does not establish stability across hardware, runtime versions or all inputs.
- The development set was read while tuning the 4B system, so it favours the 4B prompt. The 9B was not tuned; a prompt adapted to the 9B was not tested.
- The 4B reference was re-derived from cached responses, the 9B run was live; prompt, rules and budgets are identical.
- Memory peaks are sampled every 0.5 s and include the LM Studio interface; brief peaks may be missed. The loaded context (262,144 tokens) is larger than any prompt here.
- Gate counting is a single reviewer's judgment against cited turns.
