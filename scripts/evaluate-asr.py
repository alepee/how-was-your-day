#!/usr/bin/env python3
"""Evaluate a transcribed session against track-specific, consented annotations."""
import argparse
import hashlib
import json
import math
import re
import unicodedata
from pathlib import Path


def tokens(text):
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", text).casefold(), flags=re.UNICODE)


def wer(reference, hypothesis):
    # Each cell stores (total edits, substitutions, deletions, insertions).
    previous = [(i, 0, 0, i) for i in range(len(hypothesis) + 1)]
    for i, expected in enumerate(reference, 1):
        row = [(i, 0, i, 0)]
        for j, actual in enumerate(hypothesis, 1):
            if expected == actual:
                row.append(previous[j - 1])
            else:
                candidates = []
                for base, delta in ((previous[j-1], (1,1,0,0)), (previous[j], (1,0,1,0)), (row[j-1], (1,0,0,1))):
                    candidates.append(tuple(a+b for a,b in zip(base, delta)))
                row.append(min(candidates))
        previous = row
    edits, substitutions, deletions, insertions = previous[-1]
    return dict(reference_words=len(reference), hypothesis_words=len(hypothesis), substitutions=substitutions,
                deletions=deletions, insertions=insertions, wer=edits/len(reference) if reference else None)


def evaluate(reference, hypothesis):
    if reference.get("benchmark_schema") != 1 or reference.get("consent_confirmed") is not True:
        raise ValueError("Référence versionnée et consentement confirmé requis.")
    words = reference["words"]
    for word in words:
        if (word.get("source") not in ("mic", "system") or not isinstance(word.get("text"), str)
                or not isinstance(word.get("speaker"), str) or not word["speaker"]
                or not all(isinstance(word.get(k), (int, float)) and math.isfinite(word[k]) for k in ("start", "end"))
                or not 0 <= word["start"] < word["end"]):
            raise ValueError("Annotation de mot invalide.")
    if not words:
        raise ValueError("La référence doit contenir des mots annotés.")
    segments = hypothesis["segments"]
    for segment in segments:
        if segment.get("source") not in ("mic", "system") or not isinstance(segment.get("text"), str):
            raise ValueError("Segment hypothèse invalide.")
    scores = {}
    for source in ("mic", "system"):
        expected = sorted((w for w in words if w["source"] == source), key=lambda w:w["start"])
        actual = sorted((s for s in segments if s["source"] == source), key=lambda s:s["start"])
        scores[source] = wer(tokens(" ".join(w["text"] for w in expected)), tokens(" ".join(s["text"] for s in actual)))
    return dict(metric_schema=1, normalization="nfkc-casefold-alphanumeric-v1", tracks=scores)


def main():
    parser = argparse.ArgumentParser(description="Mesurer le WER par piste sans publier le contenu des voix.")
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypothesis", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        reference_bytes, hypothesis_bytes = args.reference.read_bytes(), args.hypothesis.read_bytes()
        result = evaluate(json.loads(reference_bytes), json.loads(hypothesis_bytes))
        result["reference_sha256"] = hashlib.sha256(reference_bytes).hexdigest()
        result["hypothesis_sha256"] = hashlib.sha256(hypothesis_bytes).hexdigest()
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"Évaluation impossible : {error}\n")

if __name__ == "__main__":
    main()
