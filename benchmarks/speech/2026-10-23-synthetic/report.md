# Premier test SpeechAnalyzer français

Date : 23 octobre 2026. Test fonctionnel synthétique, pas un benchmark de qualité.

| Paramètre | Valeur |
|---|---|
| Machine | Mac16,8, arm64 |
| OS | macOS 27.0.1, build 26A434 |
| Compilateur | Apple Swift 6.4, swiftlang-6.4.0.34.1 |
| Source | Voix de synthèse macOS Thomas, aucune capture micro |
| Entrée initiale | AIFF mono 22 050 Hz, 6,174 s |
| Entrée intégration | CAF mono Float32 16 000 Hz |
| Pistes du test | Même échantillon, micro à 0 s et système à 300 s |
| Locale demandée | fr-FR, équivalent fr_FR effectivement disponible |
| Moteur | SpeechTranscriber avec audioTimeRange, résultats finaux |
| Attribution | Aucune, pas de diarisation |

Phrase source : « Bonjour Antoine. La réunion commence à neuf heures. Nous devons préparer le prototype pour vendredi. »

Texte obtenu : « Bonjour Antoine, la réunion commence à 9h. Nous devons préparer le prototype pour vendredi. »

Sur le test initial, 14 runs temporels pour 14 mots. Premier intervalle à 0,12 s et dernier à 6,174 s, avant ajout du décalage de session. Le test intégré vérifie les deux pistes, les intervalles présents, le décalage à 300 s, la provenance, la sauvegarde et la conservation d’une note modifiée pendant le traitement. Il vérifie aussi l’annulation et la relance, sans perdre le transcript précédent.

Observation : `installedLocales` contenait fr_FR, mais `AssetInventory.status(forModules:)` n’était pas `installed` avant préparation explicite. La commande `install-model fr-FR` a permis le traitement. Ce statut est contrôlé séparément dans l’adaptateur.

Reproduction : `scripts/build-app.sh debug`, préparation du modèle si nécessaire, puis `scripts/test-asr.sh`. Les fichiers de test sont isolés dans `build/asr-test.*`. Aucun audio personnel n’est lu.

Limites : pas de mesure WER/DER, pas d’annotation temporelle de référence, pas de test réseau physiquement coupé, pas de code-switching, pas de frontière parlée à 5 minutes, pas de macOS 26. Le spike 1 reste ouvert pour ces mesures. Ce test ne valide pas la capture Core Audio sur périphériques physiques.
