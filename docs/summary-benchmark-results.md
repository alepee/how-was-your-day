# Local summary benchmark results

Date: 2026-10-26. Workflow: `summary-v7-grounded-writing`.

**No model is recommended yet.** Every tested configuration failed at least one fidelity requirement. Lower memory usage or successful JSON generation does not compensate for missing decisions, invented tasks or unsupported explanations.

The comparison table uses the public [synthetic fixtures](../benchmarks/summary/synthetic/). A separate long-session failure is reported below without publishing any real meeting content. End-to-end long-session quality and scaling are not established by these runs.

## Method

| Setting | Value |
|---|---|
| Machine | Apple M4 Pro, 48 GB unified memory |
| Input | Three equivalent conversations: French, English and mixed French/English |
| Fixture size | 18 turns, six minutes of synthetic timestamps, roughly 1,700 to 1,900 text characters |
| Expected output | French; three decisions and two explicit tasks, with correct owners and final commitments |
| Workflow | Same v7 pipeline; these short inputs used two model calls each |
| Serving | Local LM Studio, MLX, 4-bit weights, one request at a time |
| Qwen setting | `reasoning_effort: none` |
| Ministral setting | Server default reasoning behavior |
| Timing | Workflow inference time, excluding model loading and Swift compilation |
| Memory | Sampled Darwin physical footprint, not RSS; interval 0.5 seconds |
| Review | Manual comparison with fixture ground truth and cited source turns |

Model identifiers were `qwen/qwen3.5-4b`, `qwen/qwen3.5-9b` and `ministral-3-14b-instruct-2512` (MLX conversion published by `mlx-community`). The server advertised 262,144 tokens for the Qwen instances and 93,696 for Ministral. Those values are not measurements of allocated context memory. Requested loading limits and advertised limits can differ with the runtime; see the [benchmark procedure](summary-benchmark.md).

Decision recall below is measured in the structured `decisions` field. Two decisions combined in one correct entry count as two. A decision corrupted by an invented date does not count as correctly recovered. Task recall requires the expected task and correct owner in `action_items`; deadlines and source support are also reviewed separately. The source expresses dates in prose, so the current schema can leave `due_date` empty even when the date is correctly repeated in the text.

## Results

“Added tasks” are future tasks presented as agreed without support in the conversation. “Server footprint” includes LM Studio, its GUI and model workers. It is not the size of the model weights or the memory footprint of an embedded implementation.

| Model | Input | Decisions | Tasks | Added tasks | Inference | Peak server footprint |
|---|---|---:|---:|---:|---:|---:|
| Ministral 3 14B Instruct | French | 2/3 | 0/2 | 0 | 129.6 s | 12.23 GiB |
| Ministral 3 14B Instruct | English | 2/3 | 2/2 | 1 | 180.8 s | 13.39 GiB |
| Ministral 3 14B Instruct | Mixed | 2/3 | 2/2 | 0 | 144.5 s | 13.03 GiB |
| Qwen3.5 9B | French | 3/3 | 2/2 | 1 | 63.6 s | 9.87 GiB |
| Qwen3.5 9B | English | 1/3 | 2/2 | 3 | 68.6 s | 10.63 GiB |
| Qwen3.5 9B | Mixed | 2/3 | 2/2 | 3 | 58.6 s | 10.89 GiB |
| Qwen3.5 4B | French | 1/3 | 2/2 | 0 | 45.7 s | 7.21 GiB |
| Qwen3.5 4B | English | 2/3 | 2/2 | 0 | 42.0 s | 7.31 GiB |
| Qwen3.5 4B | Mixed | 3/3 | 2/2 | 0 | 40.6 s | 7.45 GiB |

All outputs were structurally valid. None passed the complete semantic review.

## Observed failures

| Configuration | Material findings |
|---|---|
| Ministral, French | Both tasks appear in prose but disappear from `action_items`. The announcement decision loses its test-validation condition. |
| Ministral, English | Adds a task to assign a finance owner, although nobody agreed to do so. Presents the explicitly rejected 20% reading as an uncertain metric. |
| Ministral, mixed | Recovers the two tasks, but says only the technical task has a deadline while also reporting the guide deadline. Calls the announcement undecided despite recording its agreed postponement. |
| Qwen 9B, French | Recovers the expected decisions and tasks, but invents a finance follow-up. Adds an adoption-percentage objective and links metric uncertainty to the launch delay without support. |
| Qwen 9B, English | Invents a November 5 public launch date despite an explicit absence of a date. Adds finance, legal and announcement tasks that were not promised. |
| Qwen 9B, mixed | Adds the same three unsupported tasks. Produces only one detailed paragraph, losing most thematic detail. |
| Qwen 4B, French | Keeps both tasks without additions, but leaves two decisions outside the structured decision list. Adds budget approval as a cause of the launch delay. |
| Qwen 4B, English | Keeps both tasks without additions, but omits the language decision from `decisions` and confuses the rejected 20% interpretation with the unknown calculation base. |
| Qwen 4B, mixed | Recovers all expected decisions and tasks without additions, but adds a budget-related cause for the delay and changes “final delivery date remains open” into “the final guide is not guaranteed.” |

Citation IDs can be valid while their meaning is wrong. Examples include citing an explicit lack of an owner to support a newly invented task, or citing the original guide promise instead of the later correction to a draft. Schema validation alone cannot detect these failures.

## Interpretation and limits

Qwen 4B had the lowest time and memory measurements here and preserved both tasks without adding others across all three variants. That makes it a useful candidate for further experiments, **not a validated default**. The larger Qwen variant did not consistently improve quality. These observations support testing the complete workflow and model combination rather than choosing by parameter count alone.

- Each model/language combination ran once. There are no confidence intervals or repeated-seed measurements.
- The three inputs describe the same invented meeting. This checks language consistency, not broad meeting coverage.
- Models remained loaded across the language cases. Backend caches and memory baselines changed between runs.
- Physical-footprint samples can miss brief peaks. Process sums are not an exact measure of unique memory across the whole system.
- The app and Swift benchmark process were measured separately. Their combined contribution was small in these short runs, but this does not measure concurrent audio processing or long-session UI memory.
- Advertised context sizes and reasoning settings differ. This is a practical comparison of usable configurations, not an architecture-controlled model benchmark.
- Model responses change later prompt sizes and output lengths. The same pipeline does not imply identical generated workloads.
- No result here establishes fit or responsiveness on a 16 GB Mac, or quality over a 90-minute transcript.

The next acceptance step is repeated evaluation on a broader bilingual corpus, including long conversations and corrections across window boundaries. Required gates remain: recover explicit decisions and commitments, preserve their final status and owners, add no unsupported task or deadline, and keep memory bounded in measured long-session runs.

## Long-session follow-up

A separate Qwen 4B run used an isolated copy of a 90-minute French transcript, with 854 segments and the same input ceiling. It stopped before thematic writing after 567.6 seconds. The sampled server physical-footprint peak was 8.77 GiB. A verification response changed a proposed task's owner without the required cited explanation, so the workflow rejected it.

This exposed a recovery defect: a structurally valid response had been cached before stage-specific validation. The fix validates verification responses before caching or reuse, removes rejected entries, and permits exactly one targeted retry with the same candidates and source passages. A resumed run reused valid checkpoints but rejected the retry too. No final report was produced, and the original recording was unchanged.

The measured peak covers only the stages reached. It is **not** a successful full-session memory bound or completion-time measurement. Qwen 4B remains an experimental candidate, not an accepted solution for long meetings.

## Schema-order ablation (A1)

An isolated follow-up used Qwen 3.5 4B MLX 4-bit, reasoning disabled, and the same three Atlas fixtures. A0 retained alphabetical schema order. A1 requested overview and details before decisions and actions. The production default remains A0.

| Input | A0 wall time | A1 wall time | Explicit decisions recovered in the decision list, A0 / A1 |
| --- | ---: | ---: | ---: |
| French | 42.1 s | 37.3 s | 1/3 / 2/3 |
| English | 40.0 s | 41.4 s | 2/3 / 2/3 |
| Mixed | 40.5 s | 41.2 s | 3/3 / 2/3 |

Both arms retained both assigned tasks in all three cases. A1 removed the French entry that classified unresolved budget and retention questions as a decision. It still omitted the language choice from every decision list, and the English decision list mixed task deadlines into a decision. Some A1 action lists omitted deadlines that remained in the detailed prose. This is not an overall quality improvement or an acceptance pass.

Sampled server physical-footprint peaks ranged from 7.50 to 8.58 GiB for A0 and 7.64 to 8.51 GiB for A1. There was one run per language and arm, with A0 before A1 on the same loaded model. Backend caching and execution order prevent attributing small time or memory differences to schema order. Source recordings were unchanged. A successful harness status only means the workflow completed; the quality assessment above is separate.

## English intermediate stages

An opt-in variant requested English extraction, routing and verification, while preserving the French final-writing prompts. It used alphabetical schema order and Qwen 3.5 4B MLX 4-bit with reasoning disabled. Original source text was unchanged. These short fixtures exercised extraction and writing only, not routing or verification.

| Input | Wall time | Decisions recovered in the decision list | Tasks recovered | Final prose language |
| --- | ---: | ---: | ---: | --- |
| French | 40.1 s | 2/3 | 2/2 | French |
| English | 36.8 s | 3/3 | 2/2 | English, fails requirement |
| Mixed | 33.7 s | 2/3 | 2/2 | English, fails requirement |

All intermediate extractions were in English. Two final reports ignored the French-writing instruction. The French report promoted unresolved retention into a decision to defer it pending Legal. The mixed report claimed Finance rejected the budget in a key point, although its own details correctly said Finance had not answered. These are substantive failures, despite valid JSON and preserved task owners.

The variant remains benchmark-only. No production default changed. There was one run per input, a model reload between this arm and A0, and a brief overlapping loopback fixture test with no competing model inference. Times are descriptive, not evidence of a speed improvement. The short-case failures do not justify treating this variant as a solution for the 90-minute recording. Next work should address statement classification and grounded commitment extraction; language choice alone has not solved either.

## Reproduce

Use [the benchmark harness and procedure](summary-benchmark.md). Run each candidate with a fresh output directory and the same fixtures. Preserve model metadata, workflow version, memory samples and the manual review. Do not publish private recordings or their generated summaries with the results.
