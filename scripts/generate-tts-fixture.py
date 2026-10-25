#!/usr/bin/env python3
"""Generate an isolated French diarization fixture using predefined Qwen voices."""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import time

MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"
REVISION = "08c72cad5e2fd0f41730c8bd1f28149585e46361"
UTTERANCES = [
    ("first", "Ryan", "Bonjour tout le monde. Nous allons parler du prototype. Je propose de commencer par la capture audio et de vérifier que les deux pistes sont bien enregistrées. Ensuite nous pourrons tester la séparation des voix et préparer la prochaine démonstration."),
    ("second", "Serena", "Merci pour cette présentation. Je vais préparer les exemples pour vendredi. Il faut également vérifier la qualité des notes et garder les décisions importantes. Nous pourrons ensuite organiser une nouvelle réunion avec toute notre équipe."),
]


def main():
    parser = argparse.ArgumentParser(description="Créer deux voix de test, sans micro ni clonage vocal.")
    parser.add_argument("output", type=Path)
    parser.add_argument("--offline", action="store_true", help="Utiliser uniquement le modèle déjà en cache")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    from huggingface_hub import snapshot_download
    from mlx_audio.tts.utils import load_model

    path = snapshot_download(MODEL, revision=REVISION, local_files_only=args.offline)
    model = load_model(path)
    manifest = dict(fixture_schema=1, synthetic=True, model=MODEL, revision=REVISION,
                    engine="mlx-audio", engine_version=importlib.metadata.version("mlx-audio"),
                    language="French", sample_rate=16000, utterances=[],
                    requirements_sha256=hashlib.sha256((Path(__file__).resolve().parents[1] / "benchmarks/tts/requirements.lock").read_bytes()).hexdigest())
    for index, (name, speaker, text) in enumerate(UTTERANCES):
        seed = 42 + index
        mx.random.seed(seed)
        started = time.monotonic()
        results = list(model.generate_custom_voice(text=text, speaker=speaker, language="French",
                                                   temperature=0.7, max_tokens=1024))
        if not results or len({r.sample_rate for r in results}) != 1:
            raise RuntimeError("Le moteur n’a pas fourni un audio exploitable.")
        rate = results[0].sample_rate
        samples = np.concatenate([np.asarray(r.audio).reshape(-1) for r in results])
        if samples.size == 0 or not np.isfinite(samples).all():
            raise RuntimeError("Signal vide ou invalide.")
        divisor = math.gcd(int(rate), 16000)
        samples = resample_poly(samples, 16000 // divisor, int(rate) // divisor)
        output = args.output / (name + ".wav")
        sf.write(output, samples, 16000, subtype="PCM_16")
        manifest["utterances"].append(dict(file=output.name, speaker=speaker, text=text, seed=seed,
            temperature=0.7, max_tokens=1024, duration=len(samples)/16000,
            generation_seconds=time.monotonic()-started, sha256=hashlib.sha256(output.read_bytes()).hexdigest()))
        print(f"{name}: {len(samples)/16000:.1f}s, {speaker}", flush=True)
    (args.output / "tts-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")

if __name__ == "__main__":
    main()
