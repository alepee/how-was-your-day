# Validation synthétique de capture et récupération

Le 23 octobre 2026, sur le Mac de développement.

| Contrôle | Résultat |
|---|---|
| Deux heures de PCM à 48 kHz, conversion 16 kHz | Réussi |
| Pistes micro et système | 24 chunks chacune |
| Durée écrite par piste | 7 199,999625 s |
| Continuité des offsets entre chunks | Vérifiée à un échantillon près |
| Rotation | Aucun chunk au-delà de 300 s |
| Valeurs de signal | Micro 0,2 et système 0,6 vérifiés dans chaque CAF |
| Ring C sous ASan et UBSan | Buffers séparés, tap silencieux, tailles incohérentes, saturation et 100 000 cycles de réutilisation réussis |
| Tests Swift | 14 tests réussis, dont 4 de récupération |
| Mesure WER | 3 tests Python réussis |
| Parcours UI | Sauvegarde, correction des speakers et isolation des exemples réussis |

Les fixtures de récupération utilisent des CAF lisibles sous nom `.partial.caf`, ainsi que des fichiers corrompus. Ce contrôle ne remplace pas un arrêt brutal réel du processus pendant une écriture sur disque.

Ce test accéléré ne valide ni la dérive matérielle sur deux heures, ni le Bluetooth, ni les appels réels. Le changement de route reste un arrêt explicite, pas une reconstruction automatique du graphe. Le convertisseur ne vide pas encore sa toute dernière fraction de buffer à l’arrêt ; l’écart observé est de six échantillons à 16 kHz.

Reproduction : commandes dans `benchmarks/corpus/README.md`. Les fichiers générés sont dans `build/long-capture-test`, hors dépôt.
