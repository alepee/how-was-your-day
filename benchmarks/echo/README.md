# Diagnostic d’écho expérimental

Le helper fournit un diagnostic séparé. Aucun mot, segment ou speaker n’est supprimé ou modifié. L’app ne l’exécute pas automatiquement. Il ne constitue pas un rejet d’écho opérationnel.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product hwyd-pipeline
python3 scripts/test-echo.py build/qwen-tts-fixture
.build/debug/hwyd-pipeline echo-diagnostic <store> <request.json> <report.json>
```

La fixture provient du [générateur Qwen local](../tts/README.md). Le test n’utilise aucun micro et ne télécharge rien. Il vérifie les empreintes des deux WAV synthétiques. Les fichiers de travail restent dans un dossier neuf sous `build/echo-test.*`.

## Mesure

Les chunks des deux pistes sont reconstruits sur la même horloge. Les trous deviennent du silence. Le lecteur travaille par fenêtres, avec une mémoire audio bornée. Les CAF temporaires sont supprimés en sortie normale. Après crash, leur dossier `echo-<UUID>` peut rester à côté du rapport. Les deux pistes doivent avoir la même durée, à deux échantillons près.

| Paramètre | Valeur expérimentale |
|---|---|
| Entrée | Mono 16 kHz, comme la capture actuelle |
| Décimation | Moyenne de 16 échantillons, résultat à 1 kHz |
| Fenêtre | 1 seconde, sans recouvrement |
| Retard recherché | Micro après système, 0 à 500 ms, pas de 1 ms |
| Score | Corrélation normalisée centrée, valeur absolue |
| Seuil candidat | Corrélation ≥ 0,95 |
| Signal minimal | Énergie centrée moyenne ≥ 10⁻⁶ sur chaque piste |
| Résidu | `1 - correlation²`, ajustement scalaire sur le signal décimé |
| Fenêtre finale | Moins de 500 ms : signal insuffisant |

Le résidu est dérivé du même score. Il n’apporte pas une preuve indépendante de double parole. Le retard est fourni aussi pour les fenêtres incertaines ; il ne faut pas l’interpréter comme une estimation fiable dans ce cas.

Le rapport JSON porte `diagnosticSchema: 1`, `algorithm: normalized-correlation-1khz-v1`, `diagnosticOnly: true`, `recordingID` et `windows`. Chaque fenêtre contient `start`, `end`, `status` et, si mesurables, `delay`, `correlation`, `residualRatio`. Les temps sont en secondes sur l’horloge de session. Les statuts sont `correlatedCandidate`, `uncertain`, `insufficientSignal`. L’écriture du rapport est atomique. Le format est interne au banc, distinct de `hwyd_schema`.

## Résultat du 23 octobre 2026

Deux extraits Qwen fournissent 16,24 secondes. Ryan est la piste distante. Serena simule une voix locale indépendante. Le retard injecté est de 120 ms. Le rapport conserve les résultats et les durées d’exécution sur ce Mac, build debug.

| Cas | Fenêtres candidates | Fenêtres incertaines | Signal insuffisant |
|---|---:|---:|---:|
| Écho seul, gain 0,4 | 16 | 0 | 1 |
| Écho + voix locale, gain local 1 | 0 | 16 | 1 |
| Voix locale seule | 0 | 16 | 1 |
| Micro silencieux | 0 | 0 | 17 |
| Écho + voix locale faible, gain local 0,01 | 16 | 0 | 1 |

Chaque fenêtre candidate retrouve 120 ms. Le dernier cas est un contre-exemple obligatoire : supprimer les fenêtres corrélées supprimerait aussi une vraie voix locale.

## Limites et suite du spike

Ce modèle scalaire ignore la réponse acoustique de la salle, la réverbération, les traitements des haut-parleurs, les retards variables et la dérive. La décimation par moyenne n’est pas un filtre anti-repliement suffisant pour une mesure acoustique définitive. Les trous sont indiscernables d’un silence. Les retards négatifs ou supérieurs à 500 ms ne sont pas couverts. Aucune précision sur des réunions réelles n’est revendiquée.

La prochaine validation nécessite un corpus hybride consenti, avec écho seul, voix locales faibles et fortes, interruptions et double parole annotée. Un filtre adaptatif ou une décision combinant indices audio et texte pourra être comparé à cette base. Le critère prioritaire reste la conservation de toute parole locale. Aucun seuil de suppression automatique n’est adopté à ce stade.
