# External summary approaches: source audit and diagnostic plan

Research date: 2026-10-26. HWYD baseline: 0.4.0, `summary-v7-grounded-writing`.

The immediate priority is **topic-to-source retrieval followed by source-based chapter writing**. None of the inspected projects establishes a ready-made solution for detailed French/English reports on a low-memory Mac. This is a source audit, not a reproduction of their published quality results.

## Pinned sources

| Project | Revision | Material inspected | Repository license declaration |
|---|---|---|---|
| [QMSum](https://github.com/Yale-LILY/QMSum/tree/83d7768c1f2b4dfeb091385d3dc7e239b8e5bb7e) | `83d7768` | README, license, complete validation JSONL | MIT |
| [Summ-N](https://github.com/psunlpgroup/Summ-N/tree/05ea309fce2d18d940a7022a6acde050aa71463f) | `05ea309` | README, license, QMSum configurations and loaders, source segmentation, target matching | MIT |
| [Millet](https://github.com/pretyflaco/millet/tree/5c0bfd0057334c105d1fd20376eb966a12cd6dba) | `5c0bfd0` | Local summary implementation, prompts, evaluation documents, mocked tests and metadata parsing | GPL-3.0-or-later |

No third-party implementation or prompt text was incorporated into HWYD. Downloaded research materials and derived input packets remain under ignored `build/summary-research/`. Repository license declarations do not replace checking the terms of underlying corpora before redistributing them.

## Findings that change the next experiment

### QMSum: separate locating evidence from summarizing it

QMSum is principally a dataset and benchmark. Each targeted question has a reference answer and relevant transcript ranges. A topic can reference multiple separated ranges. Its README points to a separate locator implementation; the dataset is not a complete application pipeline.

Inspection of the pinned validation file found:

| Measurement | Value |
|---|---:|
| Meetings | 35 |
| Annotated topics | 149 |
| Topics with multiple ranges | 8 |
| Specific questions | 237 |
| Specific questions with multiple ranges | 11 |
| Median selected text / complete transcript text, per specific question | 5.93% |

The last row uses human-selected ranges, unique turns, and text characters only. It excludes speaker labels, prompts, neighboring turns and general questions. It is **not** a token, memory or total-meeting cost reduction. Answering every topic can reread overlapping material. A predicted locator may miss evidence that the human annotation supplies.

The useful diagnostic is an **oracle evidence arm**: give the generator the annotated source ranges, then compare it with a predicted-evidence arm. If generation fails even with oracle sources, improving the locator cannot fix that failure. If it works with oracle sources but fails with predicted sources, investigate retrieval recall and missing corrections first.

QMSum supplies English cases. It does not validate French or mixed-language behavior. Its reference answers help assess coverage but are not exhaustive lists of all permissible claims; check the original turns when judging an additional detail. An annotated range is not necessarily a complete evidence set: in validation meeting 0, specific question 2, the reference mentions twelve to thirteen recorded hours, stated in turns 618-619, outside the annotated range supplied to the writer. Do not score that missing number as a generator failure on this restricted input.

### Summ-N: useful bounded baseline, not our chapter index

The inspected configuration uses two stages and 1,024-token input settings. Source segmentation groups complete turns by a length counter. Later stages consume generated intermediate summaries, rather than returning to the original passages for every chapter. Target matching uses ROUGE during preparation for training.

This differs from the proposed HWYD outline: summarizing summaries can discard details needed to interpret a later reversal. The published framework remains useful as a bounded hierarchical baseline, but its quality results cannot be assigned to a new prompt-only implementation with Qwen.

The pinned code is also not ready to run as a QMSum adapter: both `dataset_loader/QMSum.py` and `QMSum_gold.py` begin `load()` with `raise NotImplementedError()`. Its README specifies Python 3.7, PyTorch 1.8.1 and Fairseq 0.10.0. We did not install that stack or run its training code.

References: [source segmentation](https://github.com/psunlpgroup/Summ-N/blob/05ea309fce2d18d940a7022a6acde050aa71463f/models/data_segment/source_segment.py), [QMSum loader](https://github.com/psunlpgroup/Summ-N/blob/05ea309fce2d18d940a7022a6acde050aa71463f/dataset_loader/QMSum.py), [paper](https://aclanthology.org/2022.acl-long.112/).

### Millet: extraction and formatting are separate, but the source is unbounded

At the pinned revision, the local Ollama path sends the entire transcript for extraction, then sends only those extracted lists for formatting. The hosted TEE default uses a different path. These results must not be conflated.

| Observation in the local path | Implication for HWYD |
|---|---|
| Context estimate is characters divided by four, clamped to a ceiling | A heuristic is not a tokenizer or proof that all input fits |
| First pass reserves 16,384 output tokens; second pass fixes context at 8,192 | A sufficiently long extraction can exceed the formatter's envelope |
| No source-window splitting in the inspected two-pass function | Does not implement the proposed bounded chapter retrieval |
| Formatting reads extraction alone | Missing or misclassified facts cannot be recovered from original speech |
| Free Markdown and best-effort structured parsing, no source citations | Compare claim fidelity separately from formatting and citation availability |
| Local evaluations are small and use NVIDIA hardware | No demonstrated French/English low-memory Mac equivalence |

These are implementation observations, not a claim that an overflow necessarily occurred in the published runs. Server behavior beyond the context ceiling was not tested here. A valid source reference also does not guarantee factual accuracy; conversely, an uncited claim can still be faithful when checked against the transcript.

Useful ideas are separating discovery from presentation, explicitly representing unresolved proposals, recording stage costs, and judging individual claims blind to the candidate model. Avoid transferring item quotas, silent normalization, or reported cloud-model quality to a small local implementation.

References: [implementation](https://github.com/pretyflaco/millet/blob/5c0bfd0057334c105d1fd20376eb966a12cd6dba/millet/summarize.py), [local evaluation](https://github.com/pretyflaco/millet/blob/5c0bfd0057334c105d1fd20376eb966a12cd6dba/docs/local-model-evaluation.md), [TEE evaluation](https://github.com/pretyflaco/millet/blob/5c0bfd0057334c105d1fd20376eb966a12cd6dba/docs/tee-summarization-evaluation.md).

## How this relates to the HWYD review

An independent Claude review identified concrete v7 issues: lexical retrieval includes participant names and can select most of a meeting; paginated verification repeatedly rewrites a candidate; output fields are serialized alphabetically with commitments before thematic prose; tentative or unassigned follow-ups have no dedicated structured category. Field order as a cause of missing commitments remains a hypothesis.

The suggested deterministic owner rule also needs qualification: a speaker can quote someone else, assign an accepted task to a third party, or accept a collective responsibility. Selecting an anchor does not prove that its speaker owns the task. Preserve an explicit unconfirmed state instead of treating every first-person sentence or matching speaker ID as proof. A requester and an acceptor being the same person is not universally invalid.

Routing every turn to a writing request guarantees input delivery, not semantic coverage in the final answer. Claims that v7 is categorically higher quality than an external project would require a controlled comparison, which has not been done.

## Next experiments, one question at a time

| Arm | Isolated question | Keep fixed | Acceptance or stop condition |
|---|---|---|---|
| Field-order ablation | Does thematic prose before commitments improve recall? | Model, source, instructions, schema fields, call count | Verify actual response order; reject added owners/tasks/dates and measure variance before changing defaults |
| Oracle topic writing | Can the small model faithfully answer a topic with relevant passages already supplied? | Model, original words, bounded envelope, French output | Check coverage, contradictions, source support and output language; no claim of locator quality |
| Predicted topic writing | Does a compact outline recover the oracle passages, including distant corrections? | Same writer as oracle arm | Measure missed evidence separately from generation errors; original turn IDs remain stable |
| Typed statement classification | Do tentative tasks and open questions stop leaking into commitments? | Same source and retrieval | No false owner or unsupported promotion; retain unknown/ambiguous states |
| Final composition | Can presentation be consolidated without changing factual commitments? | Frozen chapter facts and source references | Changes to owners, dates or decision status require returning to sources; do not rewrite the facts freely |

For long recordings, cap source packets and process chapters sequentially. Retrieve multiple disjoint passages with neighbors and preserve their chronological order. Split oversized packets explicitly. A short outline indexes sources; it is not the only evidence available to the writer. Search for later corrections without treating participant names as discriminating keywords.

Freeze separate French, English and mixed-language scenarios before prompt tuning. Include quoted first-person speech, requests without acceptance, reassignment, delayed cancellation, unresolved proposals, uncertain dates and unidentified voices. Compare at the claim level; more bullet points do not establish better recall. Preserve test recordings and production summaries unchanged.

## Reproduce the data inspection

Download the validation JSONL from the pinned QMSum revision into `build/summary-research/QMSum/data/ALL/jsonl/val.jsonl`, then run:

```sh
python3 scripts/prepare-qmsum-probes.py \
  build/summary-research/QMSum/data/ALL/jsonl/val.jsonl \
  --output build/summary-research/qmsum-probes
```

The output directory must be new. The script validates ranges, records the input checksum and selects three multi-range and three single-range questions in dataset order. This is a diagnostic selection, not a representative random sample. Each case has full and oracle input packets, with one neighboring turn on either side of selected evidence. Reference answers are stored separately in `evaluation-only.json` and must never enter generation prompts. No model, network request, microphone or production store is used by this preparation script.

## Initial annotated-span diagnostic

Six prepared questions were sent individually to Qwen3.5 4B, MLX 4-bit, through the same LM Studio server, with reasoning disabled. Inputs remained below 24,000 compact JSON characters. The independent prompt requested a French answer and source IDs, not a complete meeting report. Reference answers were excluded from inference. The source text was English; this is not a bilingual corpus evaluation.

All six responses were structurally valid and stopped normally. Calls took 3.2 to 13.7 seconds, but four answers were in English despite the French instruction. Spot checks found incomplete coverage and interpretations requiring source review. The annotated-range issue above also prevents treating reference-answer recall as a clean generator score.

A second sequential run with the saved probe script again produced six structurally valid responses and the same four English answers. Response wording was not identical. Its 1.3 to 5.5 second timings used the already warm server, so they are recorded separately rather than presented as an algorithmic speedup.

These timings are for a simpler question-answer task and cannot be compared directly with the two-call v7 report timings. No physical-footprint measurement was taken for this diagnostic. The experiment does not establish detailed report quality, successful retrieval, or the final document's coherence. It does justify isolating retrieval, language compliance and writing quality before another long end-to-end run.

The independently written probe is reproducible with an already loaded local model:

```sh
python3 scripts/probe-qmsum-local.py build/summary-research/qmsum-probes \
  --model YOUR_LOADED_LOCAL_MODEL --output build/summary-research/oracle-probe-new
```

The probe accepts only loopback servers, rejects oversized inputs without truncation, uses a fresh output directory and saves raw responses for review. Its fixed `reasoning_effort: none` requires server support. A structural pass is not a quality verdict.
