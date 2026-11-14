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

The public `SummaryPipeline.run` interface retains its character-budget argument, but user prompts are capped by the provider independently of meeting length: **24,000 characters** for a local server, with extraction windows of at most 12,000 source characters. Hosted providers (Mistral, OpenAI, Anthropic, Google Gemini) have contexts of 128k tokens or more, so their ceiling is **200,000 characters** per request with extraction windows of up to 120,000 source characters: a typical one-hour session fits one window and takes the two-request path. A configured budget below that ceiling reduces it, with a minimum of 12,000 characters. Actual envelopes are checked, including topic maps, candidates and source JSON. An oversized single turn or indivisible source bundle fails explicitly instead of being silently truncated.

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

An experimental benchmark option asks the extraction, routing and verification stages for English instead of French, while the writing stages keep producing French and the source passages are never translated. It is off by default, not exposed in the application, adds no request, and does not change the shipped prompts or their checkpoint identity. It does not make lexical retrieval work across languages. See `docs/summary-benchmark.md`.

Cancellation preserves completed checkpoints. Cache writes are best effort. Regenerating a saved final summary forces fresh inference; resuming a failed or missing result reuses matching checkpoints. The application saves a final report only after validation and a stale-input check. Cache files contain private derived text and are not exports.

## Validation and benchmark

Unit tests cover bounded long-session requests, coverage of every original turn in writing, mixed French/English source handling, failure rather than truncation for oversized turns, correction evidence reaching the writer before drafting, explained same-count changes, the two-request short path, cache reuse and invalidation. Deterministic fixtures test orchestration, not model quality.

The opt-in test accepts `HWYD_SUMMARY_RECORDING`, `HWYD_SUMMARY_OUTPUT`, `HWYD_SUMMARY_INPUT_CHARACTER_LIMIT`, `HWYD_LIVE_LLM_URL`, `HWYD_LIVE_LLM_MODEL`, optional `HWYD_LIVE_LLM_REASONING_EFFORT` and optional `HWYD_LIVE_LLM_SCHEMA_ORDER` (`alphabetical` by default, or the experimental `narrative-first`) and optional `HWYD_LIVE_LLM_INTERMEDIATE_LANGUAGE` (`french` by default, or the experimental `english`), both described in `docs/summary-benchmark.md`. It writes the report, provenance, timing and `metrics.json` with inference call count, largest user prompt and inference time. Private inputs and results belong under ignored `build/` paths. The external benchmark harness measures process memory separately, including the inference server.

A Claude reference obtained through read-only MCP is a comparison artifact, not ground truth. Score coverage, factual fidelity, attribution, useful detail, structure, runtime and measured peak memory separately.

## Entry point

The app reaches every provider through the `Summarizer` contract described in [architecture §12](architecture.md#12-traitements-llm-synthèse-action-items). Each implementation reports whether it can run and why not; the summary tab shows that reason under the Generate button. It also states where its draft is written and what leaves the Mac (local server, named hosted provider, ACP agent); the tab shows that line instead of a fixed one. Summary settings live in `SummarySettings`, saved through the `SettingsStore` port.

## Hosted providers

Mistral, OpenAI and Google Gemini are called through their OpenAI-compatible chat completions endpoints; Anthropic through the Messages API with `output_config.format`. Every stage keeps the same prompts, output contract and schema. Array size limits (`minItems`, `maxItems`) are removed from the wire schema, because hosted engines do not all accept them, and upper bounds are applied to the response before validation, as constrained decoding would. Segment references stay enumerated in the schema up to 200 references; above that, the enumeration is dropped and unknown references are still rejected at decoding. Each request allows 16,000 output tokens, including provider-side reasoning. OpenAI and Gemini requests ask for low reasoning effort; Anthropic uses the model's default effort.

Nothing is sent until a hosted provider is selected and its API key is saved. Saving a key first lists the provider's models (Anthropic and OpenAI-compatible `/models`, Gemini's native `models` endpoint with the key in a header); a rejected key is not stored. The settings offer the text-generation models from that list, as a menu and as completions, and still accept a typed identifier. The request carries the session title, transcript passages and voice labels, never notes, audio or voice vectors. Keys live in the macOS keychain (this device only, not synchronized) and are never stored in preferences, exports, the database or summary provenance.

## Agent mode (ACP)

HWYD acts as an Agent Client Protocol client. It starts the configured command in a login shell (stdio, newline-delimited JSON-RPC), advertises no file system or terminal capability, and opens one session in the chosen working directory with a single MCP server: `hwyd-mcp --summary-handoff <private dir> --recording <id> --input-hash <hash>`. In that mode `hwyd-mcp` offers only `submit_summary`.

The prompt carries the session title, the heard passages with `S<n>` references and voice labels, the summary rules, and asks the agent to consult its own context read-only before writing. `submit_summary` maps references to segment IDs, applies the summary validation (up to five references per item, 32 topics, eight context notes) and writes the accepted summary to the private directory; a rejection returns its reason to the agent. If the agent ends its turn with the summary as text instead, HWYD extracts the JSON object and applies the same validation. HWYD re-validates the result, checks the session did not change, and stores it with the agent name as provenance.

Permission requests are answered by `ACPPermissionPolicy`: `read`, `search`, `think` and `fetch` tool kinds and `submit_summary` are allowed; `edit`, `delete`, `move`, `execute`, `switch_mode` and other tools are refused. Runs time out after 20 minutes and can be cancelled from the session (`session/cancel`, then termination).
