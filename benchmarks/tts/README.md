# Voix synthétiques pour le banc HWYD

Qwen3-TTS 0.6B CustomVoice, quantifié en 4 bits, via MLX Audio. Deux voix prédéfinies, Ryan et Serena, avec langue forcée à `French`. Aucun micro, clonage ou audio personnel. Ce générateur est un outil de test Python séparé de l’app Swift.

## Générer une fixture

```sh
uv venv --python 3.12 build/tts-venv
uv pip sync --python build/tts-venv/bin/python benchmarks/tts/requirements.lock
build/tts-venv/bin/python scripts/generate-tts-fixture.py build/qwen-tts-fixture
HWYD_TTS_FIXTURE="$PWD/build/qwen-tts-fixture" scripts/test-diarization.sh
```

Utiliser un dossier neuf pour la génération. Le premier lancement télécharge environ 1,7 Go de poids dans le cache Hugging Face. Après téléchargement, `--offline` bloque les accès au Hub. Aucun audio n’est envoyé à un service externe. Les modèles community-1 doivent déjà être installés par l’app.

| Élément figé | Valeur |
|---|---|
| Modèle | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit` |
| Révision | `08c72cad5e2fd0f41730c8bd1f28149585e46361` |
| Moteur testé | `mlx-audio==0.6.1` |
| Voix | Ryan, Serena |
| Graines | 42, 43 |
| Température | 0,7 |
| Limite | 1 024 tokens par énoncé |
| Fichiers | WAV mono PCM16 à 16 kHz |

`tts-manifest.json` conserve les textes, durées, paramètres, version du moteur et SHA-256 de chaque WAV. Le test vérifie ces empreintes. Les résultats MLX ne sont pas garantis identiques bit à bit entre versions de macOS ou matériels ; les WAV conservés sont la référence exacte.

## Ce que mesure le test

Deux énoncés sont assemblés dans l’ordre A/B/A/B, séparés par une seconde de silence. Ce sont des répétitions des mêmes WAV, pas quatre générations indépendantes. Le test exige deux clusters par piste, une attribution des segments lexicaux et une identité stable lors de la répétition. Les runs contenant seulement de la ponctuation peuvent rester non attribués s’ils tombent hors parole.

Le test `say` reste disponible sans `HWYD_TTS_FIXTURE` pour les contrôles rapides sans poids TTS. Le test Qwen enrichit le banc ; il ne remplace pas les conversations consenties, les chevauchements, les hésitations, les micros éloignés ou la compression visio. Les voix prédéfinies ont des langues natives autres que le français ; leur accent français doit aussi être apprécié à l’écoute.

Sources : [modèle Qwen officiel](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice), [API MLX Audio](https://github.com/Blaizzy/mlx-audio/blob/main/docs/models/tts/qwen3-tts.md), [poids quantifiés](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit). Kokoro reste une option plus légère, mais son [catalogue officiel](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) ne propose qu’une voix française.
