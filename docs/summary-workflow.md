# Bounded evidence and thematic writing

HWYD processes French, English and mixed-language transcripts. Reports currently use French. A model must pass the bilingual benchmark before it can be recommended; valid JSON alone does not demonstrate language support or factual quality.

## Workflow

1. Extract facts, arguments, disagreements, open questions and explicit commitments from windows of complete turns. Each window has at most 12,000 source characters, or less with a smaller configured budget.
2. Organize the extracted topic cards into a compact thematic map. Routing batches are bounded. Cards omitted by the model retain their original title instead of disappearing. Every original turn is assigned to a topic, using the closest cited turn within its extraction window as a fallback.
3. For long sessions, verify extracted commitments before drafting. Decisions and actions use separate batches, with at most four candidates per batch. Schemas prevent a task from moving into the decision array. Verification reads the topic's source, adjacent turns, and lexical matches elsewhere in the transcript and French extraction cards. Removing or changing a candidate's text, owner or date requires a cited correction note. Unchanged candidates must be copied without stylistic reformulation.
4. Write each topic from original turns, the topic inventory and the relevant verified commitments. Original passages supporting a later correction or cancellation are included even when initially routed to another theme. If the full source bundle exceeds the request ceiling, writing batches split further; an indivisible bundle fails explicitly. The writer explains the chronology once, with both the initial and final positions available.
5. Assemble the writer's detailed paragraphs, decisions and actions deterministically. A separate bounded editor writes only the overview and up to four key points from paragraphs that carry source references. It cannot remove detailed material or commitments.

There is **no automatic paragraph repair after writing**. Earlier experiments showed that repeated correction requests could introduce fictitious cancellations into otherwise faithful prose. Verification now supplies context before writing instead of editing a finished report.

For a transcript that fits one extraction window, HWYD skips routing and separate commitment verification. It sends the complete original source and extraction map to the writer, then uses that writer's report directly when the complete request fits. This is a two-request path, including conversations with commitments.

The final commitments come from the writer. A commitment missed during extraction but discovered during writing does not receive an additional verification call. This is a deliberate quality/runtime tradeoff, not a claim that every final sentence was independently checked.

Suspected echo remains a review hint, not automatic deletion or proof of a speaker's intent.

## Memory and context

The public `SummaryPipeline.run` interface retains its character-budget argument, but user prompts are capped at **24,000 characters** independently of meeting length. A configured budget below that ceiling reduces it, with a minimum of 12,000 characters. Actual envelopes are checked, including topic maps, candidates and source JSON. An oversized single turn or indivisible source bundle fails explicitly instead of being silently truncated.

These limits are **not tokenizer accounting or a total process-memory guarantee**. System instructions, JSON schema, output tokens, runtime buffers, model weights and the server's KV-cache allocation also consume memory. Planning allows 3,000 output tokens; writing, verification and editing allow 4,000. LM Studio's loaded context must be configured separately. HWYD does not unload other models or reconfigure the server.

All inference requests are sequential. The full transcript and intermediate cards still occupy ordinary application memory, which grows with recording length. The bounded guarantee concerns individual model input, not constant total host memory.

Short references are restored to original segment UUIDs after inference. Executive editing permits only references whose text appears in the current request or its previous key points. Stage-specific system instructions and schemas suppress irrelevant sections. Every request also presents a compact textual output contract to the model, including required fields, types and stage limits. The grammar alone is not assumed to tell the model which structure to produce. Optional `reasoningEffort` is forwarded only when explicitly configured; reasoning-channel text is never accepted as the final structured response.

## Limits

Routing is approximate. Lexical retrieval and model extraction do not guarantee detection of every cross-language paraphrase or distant reversal. The benchmark includes changed decisions and cancelled commitments for that reason. A later cancellation missed by extraction and retrieval can still be missed by verification.

Large thematic sections can remain split into several paragraphs. Exact duplicate paragraphs are removed; semantic deduplication is not guaranteed. If routing needs several batches, independently named equivalent subjects may remain separate. Deterministic assembly preserves detail at the cost of potentially repetitive prose. The final report permits up to 256 detailed paragraphs; individual model responses remain limited to 16. Excessive output fails validation rather than silently losing material.

Verification adds calls and can become expensive when a meeting contains many commitments. Neither speed nor Google Meet-level quality is claimed without measured evidence. A reported source ID proves that the source exists, not that the interpretation is faithful.

## Recovery and provenance

Validated steps are written atomically to the local `cache/summaries/<recording-id>/` directory. Cache keys include input content, speaker labels and identities, endpoint identity, model, prompt version, instructions and stage prompt. The caller includes generation options such as reasoning mode in the provider identity. Stable synthetic card IDs make routing resumable.

Verification constraints are checked before a response becomes a checkpoint, including when loading an existing checkpoint. An invalid legacy verification checkpoint is removed. An unexplained commitment change, category change or increase in candidate count gets one targeted retry with precise feedback and the same candidate and source passages. A second invalid answer fails the run. An accepted retry uses the original checkpoint key, so unrelated completed steps remain reusable.

Cancellation preserves completed checkpoints. Cache writes are best effort. Regenerating a saved final summary forces fresh inference; resuming a failed or missing result reuses matching checkpoints. The application saves a final report only after validation and a stale-input check. Cache files contain private derived text and are not exports.

## Validation and benchmark

Unit tests cover bounded long-session requests, coverage of every original turn in writing, mixed French/English source handling, failure rather than truncation for oversized turns, correction evidence reaching the writer before drafting, explained same-count changes, the two-request short path, cache reuse and invalidation. Deterministic fixtures test orchestration, not model quality.

The opt-in test accepts `HWYD_SUMMARY_RECORDING`, `HWYD_SUMMARY_OUTPUT`, `HWYD_SUMMARY_INPUT_CHARACTER_LIMIT`, `HWYD_LIVE_LLM_URL`, `HWYD_LIVE_LLM_MODEL` and optional `HWYD_LIVE_LLM_REASONING_EFFORT`. It writes the report, provenance, timing and `metrics.json` with inference call count, largest user prompt and inference time. Private inputs and results belong under ignored `build/` paths. The external benchmark harness measures process memory separately, including the inference server.

A Claude reference obtained through read-only MCP is a comparison artifact, not ground truth. Score coverage, factual fidelity, attribution, useful detail, structure, runtime and measured peak memory separately.
