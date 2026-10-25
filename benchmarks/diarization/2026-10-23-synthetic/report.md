# Premier test de séparation des voix

Le 23 octobre 2026. FluidAudio 0.17.7, OfflineDiarizerManager, community-1, sortie exclusive.

| Mesure | Résultat |
|---|---|
| Entrée | Deux voix macOS synthétiques, Thomas et Amélie, alternées deux fois |
| Durée par piste | 56.366 s |
| Sources | Même audio sur micro et système pour vérifier leur indépendance |
| Speakers obtenus | 2 par piste, 4 identifiants distincts |
| Passages attribués | 8 |
| Vecteurs exportés | Aucun |
| Réseau du moteur pendant l’inférence | ModelHub.offlineMode activé |

Le téléchargement des modèles est séparé du traitement. Le test a été reproduit par `scripts/test-diarization.sh`. Les fichiers de synthèse restent dans `build/`, hors dépôt. Aucun micro ni enregistrement personnel n’a été utilisé.

Cette expérience valide l’intégration, pas le DER sur des réunions réelles. Elle ne démontre ni la robustesse aux voix éloignées, ni le code-switching, ni le rejet d’écho. Les identités ne sont pas fusionnées entre les pistes.
