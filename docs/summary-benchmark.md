# Local summary benchmark

The benchmark runs the production Swift summary workflow against an already loaded local model. It never writes to the app store, records audio, or loads/unloads models. Results, transcripts and caches stay under ignored `build/` directories.

## Acceptance criteria

French and English are required. A mixed-language conversation must preserve meaning and speaker attribution. A syntactically valid summary is not a quality pass.

| Dimension | Check |
|---|---|
| Decisions | Recover agreed decisions, distinguish rejected proposals and unresolved questions |
| Actions | Preserve the latest commitment, correct owner and deadline; never invent missing ones |
| Detail | Cover substantive topics, figures, disagreement and changes of mind |
| Evidence | Each cited source supports the associated claim |
| Resources | Report sampled peak physical footprint and RSS, elapsed time, model, quantization and loaded context |
| Scaling | Compare a short fixture with a long recording at the same bounded input budget |

The synthetic suite has three equivalent six-minute conversations: French, English and alternating French/English. Each has 18 turns, three decisions and two commitments. Expected files contain source IDs, unresolved questions and forbidden claims. These are small diagnostic cases, not representative proof of quality on real meetings. Evaluate the real long transcript separately. The expected summary language is French, matching the app's current output instructions.

## Run

First build the test binary, with no live benchmark environment variables set:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore --filter SummaryWorkflowTests
python3 scripts/test-benchmark-summary.py
python3 scripts/benchmark-summary.py --suite --prepare-only
```

Load exactly one candidate in LM Studio. Set its context explicitly, record the quantization and stop competing inference. Changing `--context-tokens` only records a label; it does not reconfigure the server. Check the loaded model metadata rather than trusting a requested load setting: some MLX runtimes can report a different context from the requested value ([LM Studio issue 2318](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2318)). Record the actual advertised value as the label and retain the requested value in the experiment notes. Neither value proves how much cache memory is allocated; use the measured footprint. The selected server must support the model and the structured output schema. `--reasoning-effort none` optionally sends the provider-specific `reasoning_effort` setting and records it in metadata. Omit it for backends without this option. In particular, verify that a reasoning model returns final JSON in `content`, rather than exhausting its output budget in `reasoning_content`.

```sh
python3 scripts/benchmark-summary.py \
  --suite \
  --model MODEL_IDENTIFIER \
  --endpoint http://127.0.0.1:1234/v1 \
  --input-characters 24000 \
  --context-tokens 16384 \
  --quantization 4bit \
  --skip-build \
  --output build/summary-benchmark/candidate-synthetic-01
```

Then use a copy of a real `Recording` JSON, never the store itself:

```sh
python3 scripts/benchmark-summary.py \
  --recording build/summary-benchmark/local/recording.json \
  --model MODEL_IDENTIFIER \
  --input-characters 24000 \
  --skip-build \
  --output build/summary-benchmark/candidate-long-01
```

Each output directory must be new. By default the run is marked `fresh` and no previous cached generations are copied, so a fresh comparison cannot silently skip model calls. The Swift runner receives `HWYD_SUMMARY_INPUT_CHARACTER_LIMIT`. This is a character budget, not an exact tokenizer limit. Reserve enough server context for system instructions, schema and output. The runtime's actual token/context behavior must still be checked.

`--server-pid PID` can be repeated to select model worker process trees. Without it, discovery includes processes whose executable path contains `.lmstudio/`, `LM Studio` or `llmster`, and their descendants. This broad default includes the GUI and all detected backends. `--app-pid PID` optionally measures the running HWYD app separately. The Swift test process tree has its own group.

## Resume an interrupted private case

Use `--cache-seed DIRECTORY` only for one explicit `--recording`. The harness rejects `--suite`, zero recordings and multiple recordings with this option. The output directory must still be new.

```sh
python3 scripts/benchmark-summary.py \
  --recording build/summary-benchmark/local/recording.json \
  --model MODEL_IDENTIFIER \
  --cache-seed build/summary-benchmark/previous-long-run/01-recording/cache \
  --skip-build \
  --output build/summary-benchmark/resumed-long-run
```

The seed is read without modification. Only direct regular files named with 64 hexadecimal characters and `.json`, containing valid JSON, are copied into the new case's `cache/`. Symlinks, nested directories, special files, other names and invalid JSON are skipped. Copies are independent files with private permissions. The source directory itself must not be a symlink.

`benchmark.json` records `run_type: resumed`, the explicit `cache_seed` path, copied filenames and hashes, and `timing_comparable_with_fresh: false`. The production workflow still checks the cache key against the recording, provider, model and prompts, and validates reused content. Copying a cache entry does not force the workflow to accept it.

A resumed duration measures only the remaining work and cache reads. **Do not compare it to a fresh run or use it as a full-session inference time.** Keep the earlier attempt's time and failure information alongside the resumed result. A resumed run remains labeled as such even if none of its entries are ultimately reusable.

## Experiment A1: narrative-first schema order

By default every request serializes JSON with sorted keys, so the root output schema lists `action_items`, `decisions`, `details`, `key_points`, `overview`. A constrained decoder typically emits fields in schema order, which makes the model state commitments before it has written the topic prose. A1 tests whether generating prose first improves commitment recall. It changes one thing: the order of the root `properties` object and `required` array in the request schema, to `overview`, `details`, `decisions`, `action_items`, `key_points`. Prompts, schema contents, temperature, output budgets, stage selection, output types and the number of inference calls are unchanged. It applies to every stage. A0 is the default `alphabetical` arm.

```sh
python3 scripts/benchmark-summary.py \
  --recording build/summary-benchmark/local/recording.json \
  --model MODEL_IDENTIFIER \
  --reasoning-effort none \
  --schema-order narrative-first \
  --skip-build \
  --output build/summary-benchmark/MODEL-a1
```

`--schema-order` (default `alphabetical`) sets `HWYD_LIVE_LLM_SCHEMA_ORDER` for the Swift test and is recorded as `schema_order` in `benchmark.json` and `metrics.json`. Foundation dictionaries do not keep insertion order, so the narrative-first body is written by a small deterministic serializer that orders only that one object and sorts every other key as before. The default path is untouched and byte-identical to the previous request.

Cache isolation: the benchmark `providerIdentity` is unchanged for `alphabetical`, so existing v7 checkpoints stay valid. For `narrative-first` it gains the suffix `|schema-order=narrative-first`, which is part of every cache key, so the two arms never share a checkpoint, including with `--cache-seed`. The wire format is an explicit provider identity rather than a prompt version, because the prompt text does not change and the production default does not change.

What this does not show: the request order is only an input. The API does not guarantee that a server emits fields in schema order, and some engines may reorder or ignore it. Before attributing any difference to A1, confirm the generated order in the raw server output. For LM Studio, the logs under `~/.lmstudio/server-logs/` hold raw responses, so `grep -o '{\\"overview\\"' LOG | wc -l` counts responses starting with `overview` (expected for A1), and the same with `'{\\"action_items\\"'` counts those starting with `action_items` (observed for A0). Compare against the total number of calls in `metrics.json`. A single run is also a small sample: judge decision and action recall against the rubric rather than from this order check.

## Experiment: English intermediate stages

By default the extraction, routing and verification stages ask the model for French, even for English or mixed turns. This opt-in variant tests whether English intermediate notes improve fidelity, commitment recall or the final French prose. It is a language ablation: `EXTRACT`, `ROUTE` and `VERIFY_*` ask for English in their directive line, system instructions and textual output contract. The stage prefixes used for dispatch are unchanged. `WRITE_TOPIC` and `EXECUTIVE` are byte-identical to the default prompts and still ask for French, so the final chapter prose and overview are written in French. There is no translation call.

```sh
python3 scripts/benchmark-summary.py \
  --recording build/summary-benchmark/local/recording.json \
  --model MODEL_IDENTIFIER \
  --reasoning-effort none \
  --intermediate-language english \
  --skip-build \
  --output build/summary-benchmark/MODEL-english-intermediate
```

`--intermediate-language` (`french` by default, or `english`) sets `HWYD_LIVE_LLM_INTERMEDIATE_LANGUAGE` for the Swift test, always explicitly so an ambient variable cannot change the arm. It is recorded as `intermediate_language` in `benchmark.json` and `metrics.json`, and it combines with `--schema-order`. An unknown value is rejected by the command line, and by the Swift test before any inference. The production application does not expose or enable it.

What changes: the directive and system wording of `EXTRACT`, `ROUTE`, `VERIFY_ACTIONS` and `VERIFY_DECISIONS`, the verification retry feedback, the English planning instructions, the textual output contract of these stages, and the harness-written `candidate.overview` label in the verification payload. The English wording is an independent translation of the French rules, with the same constraints, field names and limits.

What does not change: the call count and call order, the input character ceiling, windowing, output budgets, the JSON schema sent to the server, temperature, semantic guards, owner and date checks, stable IDs, speaker labels, timestamps, dates, and the original transcript passages, which stay in their original language (French, English or mixed). Progress and error strings stay French.

Cache isolation: the benchmark `providerIdentity` is unchanged for `french`. For `english` it gains the suffix `|intermediate-language=english`, appended after any `|schema-order=...` suffix, so the four schema order and language combinations have distinct identities. The workflow also derives its prompt version and hash from the provider language: the French values are unchanged, so existing checkpoints stay valid, and the English hash covers the rendered English prompt texts with length-prefixed parts. English and French checkpoints are never shared, even if a caller reuses the same provider identity or `--cache-seed`.

Limits to keep in mind when reading a result:

- Lexical retrieval across languages is not fixed. Verification context is still selected by comparing claim words with source words after accent folding. With English intermediates, claims match English passages and English extraction cards better, and French passages mostly through the cards. With French intermediates it is the reverse. A change in recall can come from retrieval, not only from the model.
- The semantic guard that rejects empty placeholder actions only knows French phrases (such as "aucune action"). It is unchanged, so an English placeholder is not caught by it.
- `WRITE_TOPIC` still receives English extraction notes, topic names and verified context. Its existing instruction to write natural French is the only guard against English wording leaking into the chapters or titles, which is part of what this experiment measures. Check the final text for untranslated phrases.
- In the rare case where several chapters are written but none has a detail paragraph, the executive step is skipped and the English routing overview would be returned as is.
- The speaker label for unattributed turns, `Voix non identifiée`, stays as it is in the source payload.
- Prompt lengths differ slightly between languages. The ceiling is unchanged, so batching can differ at the margin.
- A single run is a small sample, and a different arm is not evidence of a better model. Judge decisions and actions against the rubric.

## Artifacts and interpretation

| File | Contents |
|---|---|
| `benchmark.json` | Input checksum, model metadata when available, parameters (including `schema_order` and `intermediate_language`), status, timing, memory peaks and review status |
| `memory.jsonl` | Sampled process groups, per-process RSS and physical footprint |
| `swift-test.log` | Test output and progress; may contain private data |
| `result.json`, `summary.md` | Generated output from the Swift workflow |
| `timing.txt` | Workflow-only timing written by the Swift runner |
| `cache/` | Intermediate outputs for this isolated run |

Wall time includes test startup and, without `--skip-build`, compilation. Model loading should happen before the run and is not part of these timing numbers. The default sampling interval is 0.5 seconds. Physical footprint comes from Darwin `proc_pid_rusage` (`RUSAGE_INFO_V2`); inaccessible measurements are null. RSS can double-count shared pages and does not describe Metal allocation. Even physical-footprint process-group sums are not an exact system-wide unique-memory measurement. Short peaks can fall between samples. Keep baseline and per-process samples when comparing models.

The default timeout is one hour per case. A timeout or interruption terminates only the benchmark process group, never LM Studio. The server may take time to cancel an in-flight request; confirm it is idle before another run.

No automatic semantic score is claimed. Review `*.expected.json` against each synthetic output and record false commitments, contradictions, decision/action recall and evidence correctness. For real transcripts, independently verify claims against original passages, including the final third of the conversation. A reference generated by a stronger model is a comparison aid, not ground truth.
