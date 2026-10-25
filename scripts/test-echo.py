#!/usr/bin/env python3
"""Exercise the read-only echo diagnostic with local, synthetic TTS WAV files."""
import argparse
import array
import collections
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import uuid
import wave

parser = argparse.ArgumentParser()
parser.add_argument("fixture", type=pathlib.Path)
parser.add_argument("--helper", type=pathlib.Path, default=pathlib.Path(".build/debug/hwyd-pipeline"))
args = parser.parse_args()
assert sys.byteorder == "little"
manifest = json.loads((args.fixture / "tts-manifest.json").read_text())
assert manifest["synthetic"] is True

def read(name):
    path = args.fixture / name
    entry = next(item for item in manifest["utterances"] if item["file"] == name)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]
    with wave.open(str(path), "rb") as audio:
        assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
        return array.array("h", audio.readframes(audio.getnframes()))

remote, local = read("first.wav"), read("second.wav")
length = min(len(remote), len(local))
remote, local = remote[:length], local[:length]
delay = 1920  # 120 ms
shifted = [0] * delay + list(remote[:-delay])
root = pathlib.Path(tempfile.mkdtemp(prefix="echo-test.", dir="build")).resolve()
reports = {}
for name, mic in {
    "echo": [0.4 * x for x in shifted],
    "double-talk": [0.4 * x + y for x, y in zip(shifted, local)],
    "local-only": local,
    "silence": [0] * length,
    "weak-double-talk": [0.4 * x + 0.01 * y for x, y in zip(shifted, local)],
}.items():
    folder = root / name
    folder.mkdir()
    for track, samples in [("mic", mic), ("system", remote)]:
        with wave.open(str(folder / (track + ".wav")), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(array.array("h", [max(-32768, min(32767, round(x))) for x in samples]).tobytes())
    request = dict(recordingID=str(uuid.uuid4()), locale="fr-FR", chunks=[dict(
        id=str(uuid.uuid4()), source=track, relativePath=track + ".wav", start=0,
        duration=length / 16000) for track in ("mic", "system")])
    (folder / "request.json").write_text(json.dumps(request))
    started = time.monotonic()
    subprocess.run([str(args.helper.resolve()), "echo-diagnostic", str(folder),
                    str(folder / "request.json"), str(folder / "report.json")], check=True)
    result = json.loads((folder / "report.json").read_text())
    assert result["diagnosticOnly"] is True
    windows = result["windows"]
    candidates = [w for w in windows if w["status"] == "correlatedCandidate"]
    reports[name] = dict(counts=dict(collections.Counter(w["status"] for w in windows)),
                         seconds=round(time.monotonic() - started, 3),
                         candidate_delays=[w["delay"] for w in candidates])
    if name == "echo":
        assert len(candidates) >= 10
        assert all(abs(w["delay"] - 0.12) <= 0.002 for w in candidates)
    elif name in ("local-only", "silence", "double-talk"):
        assert not candidates, (name, reports[name])
    elif name == "weak-double-talk":
        assert candidates, "This counterexample must prevent automatic suppression"
(root / "summary.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports, indent=2))
print("PASS:", root)
