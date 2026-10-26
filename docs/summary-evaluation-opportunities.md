# Further summary evaluation opportunities

Research checked on 2026-10-26 using Linkup and primary paper or repository pages. These are candidates for experiments, not validated improvements to HWYD. No external model was downloaded or trained, and no private transcript was sent to search tools.

## Highest-priority opportunities

| Opportunity | Evidence inspected | Proposed HWYD experiment | Limits |
| --- | --- | --- | --- |
| French source-grounded writing | [FREDSum repository](https://github.com/linagora-labs/FREDSum) supplies extractive and abstractive summaries. Its `community` annotations associate summary sentences with supporting source sentences. | Compare source-only writing against plan plus original passages on a small fixed French subset. Review names, predicates, modality and unsupported causal links. Keep references out of model input. | Political debates, not workplace commitments. Does not establish performance on noisy ASR or code-switching. |
| Independent factuality and coverage evaluation | [TofuEval repository](https://github.com/amazon-science/tofueval) supplies expert sentence-level labels, error explanations, topic key points and dev/test document IDs. | Calibrate an offline evaluator against human labels before trusting its scores on HWYD output. Score factuality and missing key points separately. | Sources come from MediaSum and MeetingBank. This is not a French evaluation or a task-ownership benchmark. |
| Separate candidate detection from task resolution | [Context-Drop paper](https://arxiv.org/html/2303.16763v1) treats action detection as sentence classification and distinguishes nearby from relevant distant context. | First locate candidate speech and relevant context, then resolve commitment status with bounded source passages. Compare against ledger extraction; measure missed tasks before measuring writing quality. | Detection labels are not complete task records. Classification cannot itself establish owner, acceptance or final status. No French result or Apple memory measurement in the evidence inspected. |
| Contrastive fidelity tests | [CONFIT](https://aclanthology.org/2022.naacl-main.415/) reports dialogue-specific contrastive fine-tuning and evaluates on SAMSum and AMI. | Create independent synthetic minimal pairs: unapproved/rejected, asked/accepted, speaker/quoted speaker, tentative/firm, postponed/cancelled. Test the evaluator as well as the generator. | The paper's intervention requires training. Prompt changes are not equivalent to its method. No fine-tuning is authorized by this research note or performed here. |

## Why these complement the ledger experiment

The current Atlas fixtures repeat one invented meeting in three language forms. They are useful regression tests but weak evidence of generalization. FREDSum can probe French writing and evidence use independently of action classification. TofuEval can probe whether a proposed automated judge recognizes known errors instead of rewarding fluent prose.

The ledger prototype should continue independently. Do not add datasets, language changes and new retrieval methods to the same experimental arm. A measured failure should remain attributable to a specific stage.

## Concrete evaluation design

1. Freeze a manifest with source revision, selected document IDs and selection criteria before generating outputs. Keep development and holdout documents disjoint.
2. For French source-grounded writing, select examples with named speakers and multiple supporting passages. Compare reference passages with retrieved passages separately: an oracle writing result does not validate retrieval.
3. For factuality checking, retain the human explanation and error label outside the generator input. Measure false positives and false negatives. A judge that misses attribution or modality errors cannot approve a release.
4. Record each generated claim's evidence, support status and error type. Distinguish supported, contradicted, insufficient evidence and ambiguous. Report missing expected facts separately, so abstention cannot inflate the quality score.
5. Preserve chronological changes and qualifiers in the rubric. A source citation that mentions the right person or topic is not necessarily evidence for the claim.
6. Keep any evaluator outside the production path until its value and latency are demonstrated. Do not add a full second model in memory merely to produce a confidence score.

## Additional sources and caveats

[AIMU](https://aclanthology.org/L16-1117/) annotates actionable intents and arguments in 22 ICSI meetings. Its scope includes assistant operations such as finding documents, not only commitments by meeting participants. The paper page was inspected; current dataset download availability and licensing were not verified. It is a schema reference, not a ready-to-use HWYD benchmark.

The Context-Drop paper uses a binary action-information label. It reports moderate annotator agreement on its Chinese corpus and derives AMI labels from links to action-related summaries. This reinforces the need for an explicit HWYD annotation policy and an ambiguity category. It does not establish that a single sentence contains everything needed to resolve a task.

FREDSum's repository identifies a version used for its paper and later corrections. Pin the chosen release or commit before evaluation. The repository displays CC-BY-SA-4.0. TofuEval displays MIT-0 and explicitly describes the benchmark as evaluation-only, not training data; underlying source corpora have separate provenance and terms. No dataset is vendored by this change. Inspect the actual license files and source-corpus conditions before importing or redistributing data.

## Prioritization

1. Finish the isolated ledger experiment and its adversarial tests.
2. Add a small French source-grounded writing evaluation if prose still invents relations despite correct structured commitments.
3. Calibrate a factuality judge on TofuEval before using one for automated acceptance.
4. Consider a small specialized detector only if candidate recall is the demonstrated bottleneck. Account for model residency, loading time and multilingual coverage.

No inspected source provides a drop-in recipe that demonstrates detailed, faithful French and English meeting reports from a small local model on Apple Silicon.
