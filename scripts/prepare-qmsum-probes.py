#!/usr/bin/env python3
"""Prepare isolated oracle-span diagnostic inputs, never production recordings."""
import argparse
import hashlib
import json
import pathlib
import statistics

ROOT = pathlib.Path(__file__).resolve().parents[1]


def indices(spans, count):
    selected = set()
    for start, end in spans:
        start, end = int(start), int(end)
        if not 0 <= start <= end < count:
            raise ValueError(f"Invalid span {start}:{end} for {count} turns")
        selected.update(range(start, end + 1))
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=pathlib.Path, help='Downloaded QMSum validation JSONL')
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--count', type=int, default=6)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / 'build') or output == ROOT / 'build':
        parser.error('Output must be a new directory under build/')
    if args.count <= 0:
        parser.error('--count must be positive')
    raw = args.input.read_bytes()
    meetings = [json.loads(line) for line in raw.splitlines() if line.strip()]
    cases, fractions = [], []
    topic_count = multi_topics = 0
    for meeting_index, meeting in enumerate(meetings):
        turns = meeting['meeting_transcripts']
        total = sum(len(turn['content']) for turn in turns)
        for topic in meeting['topic_list']:
            indices(topic['relevant_text_span'], len(turns))
            topic_count += 1
            multi_topics += len(topic['relevant_text_span']) > 1
        for query_index, query in enumerate(meeting['specific_query_list']):
            selected = indices(query['relevant_text_span'], len(turns))
            fractions.append(sum(len(turns[i]['content']) for i in selected) / max(total, 1))
            cases.append((meeting_index, query_index, len(query['relevant_text_span']) > 1, selected))
    # Fixed diagnostic selection: first multi-span cases, then first single-span cases.
    # This deliberately overrepresents distant evidence, not natural dataset prevalence.
    multi = [case for case in cases if case[2]]
    single = [case for case in cases if not case[2]]
    chosen = multi[:args.count // 2] + single[:args.count - min(len(multi), args.count // 2)]
    output.mkdir(parents=True, exist_ok=False)
    manifest = {'source_sha256': hashlib.sha256(raw).hexdigest(), 'meetings': len(meetings),
                'topics': topic_count, 'multi_span_topics': multi_topics,
                'specific_queries': len(cases), 'multi_span_queries': len(multi),
                'median_oracle_text_fraction': statistics.median(fractions) if fractions else None,
                'oracle_only': True, 'selection': 'first half multi-span, remainder single-span',
                'cases': []}
    for ordinal, (meeting_index, query_index, _, selected) in enumerate(chosen, 1):
        meeting = meetings[meeting_index]
        query = meeting['specific_query_list'][query_index]
        turns = meeting['meeting_transcripts']
        context = {j for i in selected for j in range(max(0, i - 1), min(len(turns), i + 2))}
        rows = [{'id': f'T{i:05d}', 'speaker': turn['speaker'], 'text': turn['content']}
                for i, turn in enumerate(turns)]
        directory = output / f'{ordinal:02d}'
        directory.mkdir()
        # Answers never enter either inference input. Oracle references are evaluation labels.
        for name, source in [('full-input', rows), ('oracle-input', [rows[i] for i in sorted(context)])]:
            (directory / f'{name}.json').write_text(json.dumps({'query': query['query'], 'turns': source}, ensure_ascii=False, indent=2))
        (directory / 'evaluation-only.json').write_text(json.dumps({'reference_answer': query['answer'],
            'gold_turn_ids': [rows[i]['id'] for i in sorted(selected)]}, ensure_ascii=False, indent=2))
        manifest['cases'].append({'directory': directory.name, 'meeting_index': meeting_index,
            'query_index': query_index, 'full_turns': len(rows), 'gold_turns': len(selected),
            'oracle_turns_with_neighbors': len(context)})
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
