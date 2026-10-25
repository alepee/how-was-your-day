# Spikes HWYD

Ces protocoles testent les six hypothèses ouvertes. Aucun résultat qualité n'est présumé. Les seuils ci-dessous sont des **critères d'acceptation proposés**, fixés avant mesure pour éviter de choisir après coup. Les résultats vont dans `benchmarks/<spike>/<run-id>/report.md`, avec configuration et métriques JSON. Le corpus audio reste hors dépôt.

## 0. Règles communes

| Élément | Protocole |
|---|---|
| Corpus | 5 à 8 sessions consenties, au moins 10 min annotées par session ; visio pure, salle, hybride, AirPods, changement de device |
| Annotations | Mots et bornes, speaker réel, chevauchement, source acoustique, écho seul, double parole ; deux annotateurs sur 20 % et arbitrage des écarts |
| Séparation | Calibration par sessions, validation sur sessions distinctes ; jamais deux tranches d'une même session dans les deux ensembles |
| Reproductibilité | SHA-256 du corpus, modèle/poids/SDK, OS build, matériel, RAM, paramètres, alimentation, thermique, graines si disponibles |
| Mesures | WER normalisé français/anglais avec règles versionnées ; DER avec collar 250 ms et aussi sans collar, chevauchement inclus et exclu ; précision des identités acceptées et couverture séparées |
| Performance | Temps froid téléchargement/compilation séparé du temps chaud ; 3 répétitions chaudes ; pic RSS, temps CPU et durée murale |
| Publication | Rapport agrégé sans voix, noms, tokens ou vecteurs ; modèle retenu seulement après résultat sur validation |

Le choix final des diarizers reste le banc du jalon 3. Comparer community-1, Nemotron 3 et Pyannote 3.1 sur les mêmes annotations. WHO entre dans ce banc uniquement après acceptation documentée de sa licence et de sa dépendance au ping. Les noms de modèles ne suffisent pas : figer les poids et la conversion réellement employés.

## 1. SpeechTranscriber : français, timestamps, code-switching

**Question.** Le moteur Apple installé sur macOS 26 donne-t-il des mots horodatés exploitables en français et en alternance français/anglais ?

| Étape | Expérience |
|---|---|
| Capacité | Dans un binaire signé, consigner `isAvailable`, `supportedLocales`, locale équivalente fr-FR et locales installées ; ne pas déduire la locale de la langue du système |
| Assets et permissions | Installation explicite des assets puis exécution réseau coupé ; tester app, helper embarqué et CLI lancé par terminal ; compte neuf et permissions refusées |
| Échantillons | Au moins 30 min français, 15 min anglais, 15 min code-switching intra/inter-phrase ; nombres, noms propres, acronymes ; chaque piste séparément |
| Temps | Demander `audioTimeRange`, conserver les runs attribués bruts ; mesurer proportion de mots avec intervalle propre, bornes non monotones et erreur contre annotation |
| Frontières | Une phrase chevauche chaque frontière de 5 min ; mesurer doublons/pertes avec contexte de 1 s et normalisation |
| Comparaison | Même PCM pour Apple fr-FR, Apple en-US si disponible et Parakeet v3 multilingue ; ne pas supposer une API de locale multiple Apple |

**Critères.** `fr-FR` ou équivalent effectivement utilisable hors ligne. Au moins 99 % des mots lexicaux ont un intervalle exploitable et monotone. Erreur temporelle p95 <= 200 ms. Sur français : WER <= 20 % et pas plus de 3 points absolus au-dessus de Parakeet. Sur code-switching : pas plus de 5 points au-dessus du meilleur candidat local. Aux frontières, moins de 1 % de mots perdus ou dupliqués.

| Résultat | Changement dans le design |
|---|---|
| Critères satisfaits | Apple par défaut, locale effective enregistrée par session |
| Français indisponible ou helper inutilisable | Parakeet pour J4, même `ASRProvider` ; macOS minimum inchangé |
| Horodatages grossiers | Garder les mots Apple comme texte diagnostique ; ré-ASR des zones avec Parakeet, ou session entière si défaut généralisé ; ne pas interpoler en prétendant à une précision mesurée |
| Code-switching mauvais | Mode multilingue Parakeet au niveau session ; Apple conservé pour français seul |
| Échec de tous les candidats | J4 peut produire `timing_quality: coarse` et une attribution incertaine, mais le critère d'alignement par mot n'est pas validé ; ne pas annoncer le jalon réussi |

L'existence des symboles est vérifiée dans le SDK local 27.0. La liste de locales et leur qualité sur macOS 26 restent à mesurer. Aucune signature d'API Apple de code-switching automatique n'est supposée.

### Résultat fonctionnel intermédiaire du 23 octobre 2026

Le [test synthétique](../benchmarks/speech/2026-10-23-synthetic/report.md) valide le français et les runs temporels dans le helper embarqué sur macOS 27.0.1. Deux pistes CAF, la sauvegarde, les notes concurrentes, l’annulation et la relance sont exercées. Le spike reste ouvert : conversations réelles, macOS 26, précision temporelle, réseau coupé et code-switching non évalués.

## 2. Rejet d’écho post-hoc en hybride

**Question.** Peut-on enlever la duplication des distants sans supprimer les voix locales quand les haut-parleurs du Mac diffusent la visio ?

| Étape | Expérience |
|---|---|
| Matrice | Deux pièces, trois distances micro (0,5 / 1,5 / 3 m), trois volumes haut-parleur (25 / 50 / 80 %), micro Mac et micro conférence si disponible |
| Script contrôlé | Pour chaque condition : distant seul, local seul, alternance, double parole, silence, musique/notif ; au moins 60 s par classe |
| Référence | Piste distante originale + capture deux pistes + annotation locale indépendante ; mesurer les latences et changements de route |
| Algorithme candidat | Fenêtres 1 s, pas 100 ms, corrélation normalisée avec recherche de délai 0 à 500 ms ; score spectral et stabilité du délai ; seuil calibré, pas supposé universel |
| Protection | Classer double_talk et uncertain ; ne masquer que echo_only ; conserver les sources et le diagnostic |
| Comparaison | Aucun rejet, rejet conservateur, variantes de fenêtres ; mesurer aussi DER/WER final, pas uniquement corrélation |

**Critères.** Supprimer >= 90 % de la durée d'écho seul détectable. Supprimer à tort < 1 % de la parole locale et < 2 % en double parole. Réduire les mots distants dupliqués à < 5 % sans augmenter le WER local de plus de 2 points. Aucun retrait d'un cluster micro complet sur la seule base d'une activité temporelle semblable.

| Résultat | Changement dans le design |
|---|---|
| Critères satisfaits | Activer le masque conservateur pour les conditions validées ; versionner ses paramètres |
| Rappel d'écho faible, protection locale bonne | Garder duplication signalée `echo_uncertain` ; proposer casque ou micro conférence |
| Parole locale supprimée | Désactiver le rejet automatique dans ce profil ; préserver les deux transcripts, correction manuelle |
| Nécessité d'AEC offline | Nouveau candidat derrière `EchoPolicy`, uniquement après preuve de non-destruction ; aucune modification de la capture brute ni ajout de VPIO |

La corrélation ne prouve pas que le signal micro ne contient **que** de l'écho. Une décision trop agressive détruit précisément la conversation hybride que HWYD doit garder.

## 3. WeSpeaker : stabilité entre canaux

**Question.** Les empreintes d'une personne restent-elles suffisamment séparables de celles des autres entre near, room et remote ?

| Étape | Expérience |
|---|---|
| Population | Minimum exploratoire 8 personnes consentantes ; au moins 3 sessions par personne, jours différents, 20 s propres par catégorie disponible |
| Conditions | Même voix proche, salle éloignée, Meet compressé ; variations micro et codec ; au moins un appareil non vu en validation |
| Extraction | Même espace d'embeddings, 256 dimensions vérifiées ; spans cumulés 5/10/20/40 s, avec et sans sélection hors chevauchement |
| Scoring | Cosinus, moyenne top-3 même catégorie ; exemplaires k-médoïdes jusqu'à 20 ; croisement de catégories mesuré séparément |
| Distracteurs | Invités absents, intervenant hors calendrier, homonymes ; bonus 0 puis 0,03 ; aucun filtre calendrier |
| Affectation | Clusters fragmentés, même personne sur les deux pistes, collisions ; comparer décision indépendante et Hongroise avec abstention |

**Critères.** Précision des identités automatiquement proposées >= 99 %, couverture >= 70 % pour clusters propres >= 20 s, par catégorie. Marge initiale 0,10, seuil absolu calibré par catégorie. Publier nombre d'acceptations et intervalle de confiance ; avec peu d'exemples, 99 % observés ne démontrent pas un taux d'erreur population de 1 %. Si l'échantillon ne permet pas de calibrer, garder confirmation obligatoire.

| Résultat | Changement dans le design |
|---|---|
| Même catégorie fiable | Activer matching dans cette catégorie avec seuil et version de calibration enregistrés |
| Inter-catégories dégradé | Désactiver ce repli ; demander un exemplaire consenti dans le canal manquant |
| Room instable | Allonger la durée propre, qualité minimale et abstention ; ne pas compenser par bonus calendrier |
| 10 s insuffisantes | Minimum 20 ou 40 s selon validation ; clusters courts restent anonymes |
| Changement d'embedder nécessaire | Nouvel `embedding_space_id`, ré-enrôlement ou recalcul si audio conservé et consentement valide ; jamais comparer les espaces |

Le test doit aussi confirmer l'API publique utilisable dans le tag FluidAudio retenu. `embedSpans` n'est pas supposé être une méthode publique d'`OfflineDiarizerManager`. Si nécessaire, l'adaptateur WeSpeaker expose le même protocole HWYD avec son propre chargement CoreML.

## 4. Mute Meet et signal de fin

**Question.** La libération des entrées/sorties process différencie-t-elle une fin d'appel d'un mute ou d'une pause ?

| Étape | Expérience |
|---|---|
| Clients | Chrome et Safari avec Meet ; contrôle sur Gather et Slack Huddle ; consigner versions exactes |
| États | Entrée en appel, mute 10/60/180 s, interlocuteur silencieux, caméra seule, onglet en arrière-plan, sortie d'appel, fermeture onglet, navigateur encore ouvert |
| Parasites | Autre onglet audio, musique, deuxième appel, changement AirPods ; associer objets process et helper IDs |
| Mesure | Échantillonner input/output à 250 ms et logguer notifications de propriété ; aucune donnée audio dans ce log |
| Répétitions | Au moins 10 séquences par client ; sessions naturelles annotées pour détecter faux arrêts |

**Critères.** Zéro faux signal d'arrêt pendant les mutes et silences testés. Détection de >= 95 % des vraies fins dans les 120 s. Documenter faux positifs/négatifs et attribution des process helpers. La combinaison « input et output inactifs 60 s » est testée comme hypothèse.

| Résultat | Changement dans le design |
|---|---|
| Signal fiable dans un client | Activer suggestion d'arrêt après 60 s ; auto-arrêt uniquement option utilisateur explicite et profil client qualifié |
| Mute libère les deux signaux | Ne jamais utiliser cette règle pour stopper ; notification facultative, bouton stop manuel |
| Autres onglets gardent le process actif | Accepter un faux négatif, ne pas tenter de déduire la fin depuis le seul premier plan |
| Changements de version | Profil de détection invalidé jusqu'au retest ; défaut conservateur |

Aucun résultat de ce spike n'autorise un démarrage silencieux ni l'always-on.

## 5. MCP Swift : serveur Streamable HTTP

**Question.** Le transport serveur HTTP du SDK retenu est-il interopérable et exploitable sans changer le contrat des outils ?

La source [0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1/Sources/MCP/Base/Transports/HTTPServer) contient `StatefulHTTPServerTransport` et `StatelessHTTPServerTransport`. Leur présence est vérifiée. La capacité opérationnelle reste un test, et ne rend pas HTTP nécessaire en v1.

| Étape | Expérience |
|---|---|
| Build | Petit serveur avec tag exact, macOS 26, adaptateur HTTP documenté ; aucun framework réseau supposé fourni implicitement par le transport |
| Clients | Deux clients indépendants compatibles avec la version négociée ; initialize, tools/list, tools/call, resources/read |
| Cycle de vie | POST, négociation de session, GET/SSE si stateful, annulation, fermeture, reconnexion, requête invalide, deux clients simultanés |
| Charge | 100 requêtes séquentielles et 10 concurrentes, réponse paginée de 100 ko, client lent et déconnecté |
| Exposition | Loopback uniquement pour le spike, contrôle Origin et Host ; test rejet origine tierce ; pas d'exposition LAN sans conception auth dédiée |

**Critères.** Build reproductible, toutes les opérations passent sur deux clients ; aucune fuite de session, de données entre clients ou croissance mémoire non bornée après déconnexion. Les erreurs restent conformes à MCP et les logs restent hors réponses.

| Résultat | Changement dans le design |
|---|---|
| Test réussi | Documenter l'option v2 et le serveur HTTP hôte requis ; aucun changement des outils ni du store |
| API présente mais interop incomplète | Maintenir stdio, consigner précisément le cas défaillant et le tag |
| SDK différent sans transport serveur | Adapter dans un module transport séparé ou attendre le SDK ; ne pas bloquer J4 |

## 6. Petits LLM : fidélité et coût

**Question.** Quel backend local produit une synthèse structurée utile sans inventer d'actions ou d'attributions ?

| Étape | Expérience |
|---|---|
| Candidats | LFM2.5-1.2B-Thinking provisoire ; Qwen3 1.7B/4B, Gemma 3 4B, SmolLM3 3B ; Foundation Models en contrôle court si disponible |
| Artefacts | Vérifier disponibilité des poids, licence, conversion MLX et tokenizer ; modèle non chargeable = non évalué, pas score qualité nul |
| Corpus | Au moins 8 transcripts corrigés : réunion, appel, conversation, mémo, fr/en, aucun action item, désaccord, consigne adversariale dans le transcript |
| Référence | Actions, responsables, échéances, décisions et segments justificatifs annotés ; distinguer tâche proposée, acceptée et abandonnée |
| Prompt | Même version et même schema, température 0 si supportée ; trois runs ; budget de sortie explicite ; aucun accès outil |
| Contexte | Compter tokens avec le tokenizer effectif ; fenêtres par tours, 10 % de recouvrement ; budget total = contexte - prompt - sortie - marge 10 % |
| Réduction | Résumés de fenêtres avec IDs sources, fusion dédupliquée puis validation des références ; mesurer erreurs introduites par la réduction |
| Backend | MLX embarqué et endpoint local ; API distante uniquement sur corpus autorisé, avec opt-in distinct, comme comparaison facultative |

**Critères.** 100 % des sorties publiées passent le schema après au plus une tentative de réparation. Taux brut de succès >= 95 %. Précision des action items >= 95 %, rappel >= 80 %. Au moins 98 % d'attributions correctes parmi les actions attribuées. Zéro échéance ou responsable inventé sur le jeu de validation. >= 95 % des affirmations de synthèse ont une justification exacte dans les segments. Sur le Mac cible documenté : une heure de transcript résumée en <= 5 min à chaud, pic mémoire processus <= 4 Gio. Ces budgets doivent être rapportés avec le matériel, pas extrapolés à tous les Mac.

| Résultat | Changement dans le design |
|---|---|
| Petit modèle conforme | Retenir ce modèle et ses paramètres ; LFM reste provisoire jusqu'au résultat |
| JSON fragile | Validation et une réparation bornée ; après échec, statut failed ; ne pas publier du texte libre à la place du schema |
| Attributions peu fiables | Exiger références de segments, garder responsable null ; ne pas utiliser le calendrier pour inventer un assignee |
| Contexte insuffisant | Fenêtres plus petites et réduction hiérarchique ; conserver couverture et provenance par fenêtre |
| Aucun modèle local acceptable | Transcript et notes restent complets ; summary désactivé ou endpoint local configuré ; aucun passage automatique au cloud |
| Budget mémoire/temps dépassé | Modèle plus petit ou génération différée ; ne pas faire concurrence à la capture |

Une fenêtre de 32k ne garantit pas qu'une heure tient dans le contexte. Prompt, tokenizer et réponse consomment aussi ce budget. Le protocole `LLMProvider` renvoie la capacité effective ; un endpoint « compatible OpenAI » ne garantit pas le support du JSON schema.
