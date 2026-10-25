# Corpus de validation

Le corpus réel reste dans un dossier privé hors dépôt. Aucun enregistrement n’est déclenché par ce banc. Le consentement à ce corpus ne vaut pas consentement à l’enrôlement biométrique.

## Collecte et annotation

| Cas | Échantillon à collecter | Vérification |
|---|---|---|
| Micro seul | 10 min, sans app diffusant du son | Démarrage immédiat, piste système silencieuse |
| Visio | Meet, Gather, Huddle, 10 min chacun | Deux pistes audibles, attribution de la source |
| Salle | 2 à 4 voix, distances variées | Voix éloignées présentes |
| Hybride | Salle et distants sur haut-parleurs | Annoter écho seul et double parole |
| Périphériques | USB, AirPods, branchement et débranchement | Arrêt explicite actuel, pistes précédentes lisibles |
| Longue durée | 2 h réelles, repères audibles au début et à la fin | Dérive et interruptions mesurées |

Séparer les sessions de calibration et de validation. Conserver les deux pistes brutes. Annoter les mots avec les temps sur l’horloge de session, la piste et un identifiant de speaker pseudonyme. Garder les décisions de consentement hors du rapport public.

Format de référence :

```json
{
  "benchmark_schema": 1,
  "consent_confirmed": true,
  "words": [
    {"text": "Bonjour", "start": 0.12, "end": 0.42, "source": "mic", "speaker": "speaker-1"}
  ]
}
```

Ce fragment est un exemple fictif, pas une donnée collectée. Ne pas mettre `consent_confirmed` à vrai sans validation effective.

## Évaluation ASR disponible

```sh
python3 scripts/evaluate-asr.py /chemin/prive/reference.json /chemin/prive/result.json --output /chemin/prive/metrics.json
python3 -m unittest discover -s Tests/BenchmarkTests -v
```

L’hypothèse est le JSON de `TranscriptionResult` ou l’export de prévisualisation, avec `segments`. Le rapport contient seulement les compteurs d’erreurs, le WER par piste et les empreintes SHA-256 des fichiers évalués. Un WER nul n’est pas produit pour une référence vide : la valeur est `null`, les insertions restent comptées.

Normalisation v1 : Unicode NFKC, casse ignorée, tokens alphanumériques, ponctuation et apostrophes séparatrices, accents conservés. « neuf heures » et « 9h » restent différents. Le score est donc lexical, pas une équivalence sémantique des nombres. La diarisation, le DER et l’erreur temporelle restent à ajouter avant le choix des modèles.

## Tests synthétiques disponibles

```sh
scripts/test-realtime.sh
"build/How Was Your Day.app/Contents/MacOS/HWYD" --self-test build/audio-two-hours 7200
```

Le second test pousse deux heures de PCM synthétique aussi vite que possible, sans micro. Il vérifie les CAF, la rotation et la séparation des pistes. Il ne teste pas deux heures d’horloge matérielle ni les routes Bluetooth. Prévoir environ 1 Go pour les deux pistes.
