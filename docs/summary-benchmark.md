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

Load exactly one candidate in LM Studio. Set its context explicitly, record the quantization and stop competing inference. Changing `--context-tokens` only records a label; it does not reconfigure the server. The selected server must support the model and the structured output schema. `--reasoning-effort none` optionally sends the provider-specific `reasoning_effort` setting and records it in metadata. Omit it for backends without this option. In particular, verify that a reasoning model returns final JSON in `content`, rather than exhausting its output budget in `reasoning_content`.

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

Each output directory must be new, so previous cached generations cannot make a fresh comparison appear faster. The Swift runner receives `HWYD_SUMMARY_INPUT_CHARACTER_LIMIT`. This is a character budget, not an exact tokenizer limit. Reserve enough server context for system instructions, schema and output. The runtime's actual token/context behavior must still be checked.

`--server-pid PID` can be repeated to select model worker process trees. Without it, discovery includes processes whose executable path contains `.lmstudio/`, `LM Studio` or `llmster`, and their descendants. This broad default includes the GUI and all detected backends. `--app-pid PID` optionally measures the running HWYD app separately. The Swift test process tree has its own group.

## Artifacts and interpretation

| File | Contents |
|---|---|
| `benchmark.json` | Input checksum, model metadata when available, parameters, status, timing, memory peaks and review status |
| `memory.jsonl` | Sampled process groups, per-process RSS and physical footprint |
| `swift-test.log` | Test output and progress; may contain private data |
| `result.json`, `summary.md` | Generated output from the Swift workflow |
| `timing.txt` | Workflow-only timing written by the Swift runner |
| `cache/` | Intermediate outputs for this isolated run |

Wall time includes test startup and, without `--skip-build`, compilation. Model loading should happen before the run and is not part of these timing numbers. The default sampling interval is 0.5 seconds. Physical footprint comes from Darwin `proc_pid_rusage` (`RUSAGE_INFO_V2`); inaccessible measurements are null. RSS can double-count shared pages and does not describe Metal allocation. Even physical-footprint process-group sums are not an exact system-wide unique-memory measurement. Short peaks can fall between samples. Keep baseline and per-process samples when comparing models.

The default timeout is one hour per case. A timeout or interruption terminates only the benchmark process group, never LM Studio. The server may take time to cancel an in-flight request; confirm it is idle before another run.

No automatic semantic score is claimed. Review `*.expected.json` against each synthetic output and record false commitments, contradictions, decision/action recall and evidence correctness. For real transcripts, independently verify claims against original passages, including the final third of the conversation. A reference generated by a stronger model is a comparison aid, not ground truth.
