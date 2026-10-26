# Topic planning and grounded writing

HWYD uses two phases for local summaries:

1. Map the subjects, arguments, unresolved questions and explicit commitments.
2. Write the report using both this map and the original transcript.

The final structure remains overview, key points, decisions, next steps and thematic details. Source references are validated. Suspected echo is a review hint, not automatic deletion or proof of the speaker's intent.

## Context and request count

The context setting must match the context actually loaded in the local server. It does not reconfigure LM Studio. HWYD uses a conservative character budget, reserving space for instructions and output; it is an estimate, not tokenizer-based accounting.

Short transcripts use two model requests. Long transcripts are mapped in smaller portions even with a large context, then those maps are consolidated into one global plan. This avoids allowing the beginning of a long conversation to monopolize the plan. Writing receives the entire raw transcript when it fits; otherwise it uses batches followed by bounded pairwise consolidation. This fallback still loses some detail compared with a full-context second pass. HWYD does not claim that two requests always suffice or that local quality equals Google Meet.

References are shortened before budgeting and restored to original segment IDs after generation. The topic map is guidance; the writing pass receives raw words rather than only intermediate summaries.

## Recovery

Validated steps are saved atomically in the local `cache/summaries/<recording-id>/` directory. An interrupted or failed run reuses matching steps. Keys include input content, speaker labels and identities, endpoint, model, prompt version, instructions and stage prompt. Changing the transcript, names, endpoint, model or prompt invalidates the corresponding entries. Cache files contain private derived text and are not exports.

The UI shows the current stage and completed steps. Cancellation preserves completed checkpoints. The final report is saved only after validation and a stale-input check. Regenerating an existing final summary forces fresh inference. Resuming a missing or failed summary reuses matching checkpoints. Cache write failures do not discard a valid model response.

## Validation

Tests cover plan-before-writing, raw source presence in the writing pass, resumption after failure, model isolation and speaker-correction invalidation. A private opt-in test accepts `HWYD_SUMMARY_RECORDING` and `HWYD_SUMMARY_OUTPUT` and runs against the configured loopback LLM server. Private recordings and benchmark results stay in ignored `build/` folders.

A Claude reference obtained through read-only MCP is a comparative artifact, not ground truth. Assess topic coverage, factual fidelity, attribution, useful detail, structure and runtime separately. A shorter model output must not be described as equivalent solely because its JSON validates.
