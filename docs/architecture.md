# How Was Your Day : plan d'architecture (brouillon v0.1)

> App macOS native, barre de menus, qui enregistre, transcrit, diarise et nomme les speakers d'une réunion, entièrement on-device, et expose le résultat en Markdown (frontmatter YAML) dans un dossier au choix. L'app est **autonome** : aucun memory system, skill ou agent n'est requis pour qu'elle soit utile ; ils ne sont que des consommateurs possibles de ses notes.
> Statut : brouillon révisé le 2026-10-23 après deux passes de revue (vérifications factuelles, revue d'architecture). Les points **[spike]** sont à trancher par expérimentation.

## 1. Positionnement, objectifs et non-objectifs

**Positionnement (décision du 2026-10-23)** : création originale en Swift, inspirée d'Anarlog (MIT, Rust/Tauri) sans le forker. Vocation **general usage** : la réunion est un cas parmi d'autres. L'unité de base est une **session de capture** (réunion visio, réunion en salle, appel, conversation informelle, mémo vocal, session ad hoc déclenchée à la main), avec ou sans événement calendrier. L'app produit une note par session, auto-suffisante et lisible telle quelle (Obsidian, Tolaria, éditeur). Tout consommateur aval (un skill, un agent, un script) reste libre d'en dériver ce qu'il veut depuis le frontmatter.

**Objectifs**
- Fonctionner quelle que soit la source : Google Meet (navigateur), Gather, Slack Huddle, appel, ou aucune application (conversation en salle autour du laptop, mémo vocal).
- Attribuer chaque segment à une personne nommée, avec une mémoire des voix qui s'améliore de réunion en réunion.
- Traitement audio et texte entièrement local. Limite à documenter : si l'utilisateur branche des agents sur le dossier de sortie, les transcripts peuvent partir vers des LLM cloud ; c'est son choix, hors du périmètre de l'app.
- **Découplage** : l'app ne connaît ni `dusk`, ni `dawn`, ni le vault. Le contrat d'intégration est le format des fichiers de sortie (§ 7), stable et documenté.
- Sortie exploitable par un agent sans API : fichiers Markdown + JSON.

**Non-objectifs (v1)**
- Micro virtuel exposé aux autres apps (v2, voir § 8 : la capture et le pipeline restent intacts, le micro virtuel est une branche de sortie séparée).
- Écoute permanente (« always on ») : écarté.
- Transcription affichée en temps réel pendant la réunion.
- Résumé obligatoire : la synthèse et les action items sont **opt-in**, via un fournisseur LLM configuré dans les réglages (§ 12). Sans fournisseur, un enregistrement reste complet (audio, transcript, notes).
- Voice Isolation ou tout traitement « un seul locuteur proche » sur la piste **capturée** : il détruit la salle et l'hybride. L'isolation n'a sa place que sur la branche micro virtuel (§ 8), en aval de tout.

## 2. Vue d'ensemble

```
┌──────────────────────────────────────────────────────────────────┐
│ App barre de menus (SwiftUI)                                     │
│  - état enregistrement, toggle, raccourci global                 │
│  - notifications calendrier « rejoindre et enregistrer »         │
│  - enregistrement en 1 clic + notepad de session                 │
│  - capture audio (dans le process app)                           │
│  - fenêtre de relecture / correction des speakers                │
└───────────────┬──────────────────────────────────────────────────┘
                │ dossier de réunion sur disque
┌───────────────▼──────────────────────────────────────────────────┐
│ Pipeline : exécutable CLI embarqué (CoreML), un run par réunion  │
│  1. ASR par piste    SpeechAnalyzer (macOS 26) [repli Parakeet]  │
│  2. Écho             rejet des zones micro corrélées au système  │
│  3. Diarisation      Pyannote community-1 (FluidAudio offline)   │
│                      [challenger : WHO]                          │
│  4. Alignement       par mot, découpe aux changements de speaker │
│  5. Embeddings       WeSpeaker 256-d (FluidAudio) par cluster    │
│  6. Identité         catégories de canal, seuil + marge,         │
│                      affectation hongroise, calendrier en a priori│
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│ Store local (SQLite + fichiers)                                  │
│  - réunions, segments, vecteurs, empreintes par personne/canal   │
│  - audio brut avec rétention 7-30 jours, chiffré au repos        │
└───────────────┬──────────────────────────────────────────────────┘
                │ export (sans vecteurs)
┌───────────────▼──────────────────────────────────────────────────┐
│ Dossier de sortie (Markdown + JSON, contrat public)              │
│  meeting-YYYY-MM-DD-<slug>.md  +  .json (segments, scores)       │
└──────────────────────────────────────────────────────────────────┘
```

Deux process seulement : l'app (UI + capture) et le CLI de pipeline. Un crash ou un pic mémoire CoreML ne tue jamais la capture ; le CLI est testable seul, relançable par un agent, et permet de retraiter d'anciennes réunions quand un modèle change.

## 3. Capture

| Besoin | Mécanisme | Notes |
|---|---|---|
| Audio des distants, quelle que soit l'app | Core Audio process tap **global** : `CATapDescription(stereoGlobalTapButExcludeProcesses: [self])`, macOS 14.2+ | Meet est dans Chrome/Safari, Gather et Slack sont des apps Electron : un tap global évite toute liste de process. Permission TCC dédiée `kTCCServiceAudioCapture` (`NSAudioCaptureUsageDescription`), distincte de l'enregistrement d'écran, sans API de pré-vérification. |
| Ma voix et la salle | Micro **brut**, sans voice processing | VPIO (AEC, débruitage, AGC) est réglé pour un locuteur proche : atténue les voix lointaines, coupe en parole simultanée, duck les autres apps, et échoue (-10875) quand entrée et sortie sont sur des devices différents (AirPods + haut-parleurs Mac). |
| Synchronisation | Tap et micro dans **un seul aggregate device** avec compensation de dérive, un seul IOProc | Deux horloges séparées dérivent d'environ 450 ms sur 2h30. |
| Écho des distants sur le micro | Traité **après coup** : fenêtres où la piste système est active et le micro corrélé = écho, rejetées ; un cluster micro qui suit l'activité système est écarté | Remplace l'AEC. **[spike]** : qualité de ce rejet en hybride avec haut-parleurs du Mac. |
| Stockage | Fichiers CAF par tranches de 5 min, 16 kHz mono par piste | Un WAV unique laisse un en-tête invalide en cas de crash. |
| Changement de device | Recréer le graphe, garder une horloge hôte commune | AirPods connectés en cours de réunion. |
| Permissions | Micro, audio système, calendrier (accès complet), notifications, Automation (navigateur) | Pas d'enregistrement d'écran. |

## 4. Pipeline

| Étape | Modèle / mécanisme | Alternative | Remarques |
|---|---|---|---|
| ASR | SpeechAnalyzer `SpeechTranscriber`, locale fr, attribut `audioTimeRange` par token, **au fil de l'eau par tranche de 5 min et par piste** | Parakeet TDT 0.6B v3 (FluidAudio, 25 langues dont français), WhisperKit | **[spike]** : présence de `fr-FR` dans `supportedLocales`, timestamps par mot, code-switching fr/en (une locale par session, à tester). |
| VAD | Aucun dédié | Silero v6 (FluidAudio) seulement si besoin de filtrer musique/notifs sur la piste système | Pyannote et SpeechAnalyzer ont le leur. |
| Diarisation | **Pyannote community-1 offline** (FluidAudio `OfflineDiarizerManager` : segmentation powerset, WeSpeaker, VBx), sortie exclusive, par piste, **en fin de réunion** sur le fichier complet | NVIDIA Nemotron 3 diarization (challenger : 8 speakers, ~100 Mo, CoreML/MLX, pas d'embeddings, NVIDIA Open Model License) ; Pyannote 3.1 allégé en repli si trop lourd ; WHO en 3e option seulement si sa licence source-available et son ping mensuel conviennent | Le défaut doit tenir sur le cas difficile (micro en salle). Sortformer écarté : 4 slots fixes. `max_speakers` = invités calendrier + 2, jamais un nombre exact. |
| Alignement | Chaque mot va au speaker qui recouvre le plus son intervalle ; phrases ASR découpées aux changements de speaker ; tours < 0,5 s ou 2 mots absorbés sauf aux frontières de piste | ASR par tour de parole, seulement en rattrapage des zones de faible confiance | Le vote par phrase attribue faussement toute phrase qui chevauche un changement. |
| Embeddings | WeSpeaker v2, 256-d, FluidAudio `embedSpans` / `extractEmbedding` | | Embedder un **cluster entier** (≥ 10-20 s de parole propre, hors chevauchement), jamais un segment isolé. |
| Identité | Voir § 5 | | |

Un modèle chargé à la fois. Le CLI se termine après chaque réunion, donc la mémoire est rendue.

## 5. Identité des speakers (le cœur)

**Principe** : une base locale d'empreintes vocales (fingerprints) est ce qui transforme « speaker 1 / speaker 2 » en noms. Sans elle, la diarisation seule ne donne que des étiquettes anonymes par session. La base est la propriété de l'utilisateur, sur sa machine, jamais exportée.

- **Empreinte par personne et par catégorie de canal** : `near` (moi), `room` (salle, champ lointain), `remote` (Opus/AGC de la visio). Jusqu'à ~20 exemplaires par catégorie (k-médoïdes). Score = moyenne des k meilleurs dans la même catégorie ; croisement de catégories seulement en repli, avec seuil plus strict. Raison : le décalage de canal fait tomber la similarité intra-personne dans la zone inter-personnes.
- **Décision** : seuil absolu **et** marge entre premier et deuxième candidat (~0,1). Démarrer prudent, calibrer par catégorie après 15-20 réunions corrigées.
- **Contrainte par réunion** : deux clusters ne sont pas la même personne → affectation hongroise clusters × candidats ; collision = proposer la fusion.
- **Calendrier en a priori**, jamais en filtre : bonus de score pour les participants de l'événement, moi toujours candidat. Sans événement : toute la base, seuil et marge plus stricts. Décision validée le 2026-10-23.
- **Inconnu persistant** : un cluster non résolu devient `speaker-xxxx`, réidentifié de réunion en réunion, nommable plus tard.
- **Enrôlement** : actif pour moi (30 s à l'installation) ; passif pour les autres par confirmation post-réunion, **uniquement pour les personnes ayant consenti** (§ 9).
- **Correction** : clic sur un segment → renommer le cluster → propagation + ajout des vecteurs dans la bonne catégorie.
- **Alias par personne** : chaque personne porte un nom d'affichage et un `alias` optionnel libre (par exemple un wikilink `[[person-<prenom>-<nom>]]`), que l'export recopie tel quel. L'app ne connaît pas la sémantique de l'alias.

## 6. Détection et déclenchement

- **Calendrier** : Google, Outlook/Microsoft 365 et Apple Calendar. Voie principale : **EventKit**, qui expose déjà tous les comptes ajoutés dans Réglages Système (Google, Exchange, iCloud, CalDAV) sans OAuth propre à l'app. Voie de secours si un compte n'est pas dans macOS : OAuth direct Google Calendar API et Microsoft Graph, en v2. Deux rôles. (1) **Mise en contexte** : titre, description, participants, pièces jointes et liens de l'événement alimentent le frontmatter et le JSON, pour qu'un consommateur aval puisse relier la session à ses propres entités (personnes, projets). (2) **A priori d'identité** (§ 5), jamais filtre. Lu dès le jalon 4. Emails à parser depuis `EKParticipant.url` (mailto) ou via Contacts ; lien visio à extraire de `url`, `location`, `notes` (pas de propriété dédiée). Notification N minutes avant, action « rejoindre et enregistrer ».
- **Enregistrement en 1 clic** : depuis la barre de menus ou le raccourci, la session démarre immédiatement (sans événement : `session_kind: ad-hoc`, titre horodaté, renommable). Une notification propose d'ouvrir le **notepad de session** : une fenêtre flottante légère où l'utilisateur tape des notes pendant la capture. Chaque note est horodatée sur l'horloge de la session, ce qui permet de la replacer dans le transcript. Le notepad est le même pour toutes les sortes de sessions.
- **Sans calendrier** : objets process Core Audio (macOS 14+) : `kAudioProcessPropertyIsRunningInput/Output` + bundle ID (Chrome helper, Slack, Gather). Slack qui prend le micro = Huddle. Meet ou Gather dans un onglet : URL de l'onglet actif via Automation sur Chrome/Safari (`meet.google.com`, `app.gather.town`). Le critère « app au premier plan » est écarté, Meet est souvent en arrière-plan ; `DeviceIsRunningSomewhere` est global et peu fiable en Bluetooth.
- **Fin de réunion** : entrée et sortie du process de visio inactives depuis > 60 s. **[spike]** : le mute Meet libère-t-il le micro ?
- **Salle** : aucun signal fiable. Événement sans lien visio + raccourci clavier.
- Jamais de démarrage silencieux : indicateur visible.

## 7. Sortie

`meeting-YYYY-MM-DD-<slug>.md` :

```markdown
---
type: Session            # type neutre ; un consommateur peut le re-projeter
date: 2026-10-23
source: hwyd://session/<uuid>
session_kind: meeting | call | conversation | voice-memo | ad-hoc
participants:         # uniquement les identités confirmées
  - name: Jérôme Noel
    alias: "[[person-jerome-noel]]"   # alias libre défini dans l'app, recopié tel quel
  - name: Antoine Lépée
    alias: "[[person-antoine-lepee]]"
app: meet | gather | slack-huddle | in-person | unknown
consent_announced: true
---

# <Titre calendrier> — 23 octobre 2026

## Notes
- [00:03:10] à relancer sur le budget Q1
- [00:12:45] décision : on garde Pyannote

## Transcript
**[00:00:12] Antoine** : ...
**[00:00:41] Jérôme Noel** : ...
**[00:01:03] speaker-a3f2 (inconnu)** : ...
```

`<même nom>.json` : segments, piste d'origine, speaker ids, identités devinées avec score. **Jamais de vecteurs d'embedding dans l'export.**

**Contrat d'exposition** :
- Un dossier de sortie configurable, structure plate `YYYY/` ou plate, au choix. Écriture atomique (fichier temporaire puis rename) pour qu'un watcher ne lise jamais un fichier partiel.
- Un fichier `index.jsonl` append-only (une ligne par session : id, date, kind, titre, chemin) pour l'énumération sans parcours du dossier.
- Le schéma du frontmatter et du JSON est versionné (`hwyd_schema: 1`) et documenté dans `docs/output-format.md`.
- Plus tard, si besoin : CLI `hwyd export --since` et serveur MCP minimal (list, get, search). Les fichiers restent la source de vérité.

## 8. Micro virtuel (v2)

Idée retenue : le micro virtuel n'est **pas** en tête de pipeline. La capture, la transcription et la diarisation travaillent sur l'audio brut. En parallèle, une branche de sortie prend le micro, lui applique l'isolation de voix (ou un autre traitement), et le pousse vers un device de sortie virtuel que Meet, Gather ou Slack peuvent sélectionner comme micro. Implémentation : AudioServerPlugIn (driver utilisateur, pas d'extension noyau) ou DriverKit ; signature et notarisation obligatoires. Hors v1.

## 9. Consentement et données (France, cadre professionnel)

Le risque principal est le RGPD, pas l'article 226-1 : des empreintes vocales qui identifient une personne sont des **données biométriques (art. 9)**, consentement explicite requis, et une app perso utilisée au travail n'a pas l'exemption domestique. L'article L.1222-4 du Code du travail impose l'information préalable des salariés. Le rapport hiérarchique fragilise le consentement des personnes qui me reportent.

- Empreinte persistante uniquement avec consentement ; liste d'opposition (jamais d'enrôlement, sortie « Participant N »).
- Effacement par personne : purge des vecteurs, anonymisation de l'historique.
- Annonce en début de réunion, consignée (`consent_announced`).
- Exclusion par défaut des 1:1 RH, entretiens annuels, sujets médicaux (mots-clés calendrier).
- Audio brut supprimé après 7-30 jours, chiffré au repos.
- Dire aux participants que les transcripts sont lus par des agents LLM cloud ; vérifier la politique IT Evaneos.
- À faire valider par le DPO avant usage avec des collègues. Sources juridiques secondaires (cabinets), pas la CNIL : à compléter.

## 10. Jalons

1. **Spike capture** : tap global + micro brut dans un aggregate device, tranches CAF, test Meet, Gather, Huddle, salle, AirPods en cours de route.
2. **Corpus et harnais d'évaluation** : 5-8 réunions réelles avec consentement, ~10 min annotées chacune (salle, hybride, visio pure, AirPods, changement de device). Scripts DER, WER, précision d'identification. Sans ça, le choix de modèles est une impression.
3. **Benchmark des modèles** sur le corpus (décision validée le 2026-10-23) : Pyannote community-1 vs Nemotron 3 vs Pyannote 3.1 allégé (WHO si licence acceptée), SpeechAnalyzer vs Parakeet v3, rejet d'écho post-hoc. Décision de stack.
4. **Pipeline bout en bout** (CLI) sans identité : transcript Speaker N + métadonnées calendrier dans le dossier de sortie.
5. **Identité** : enrôlement, catégories de canal, matching, UI de correction, consentement et effacement.
6. **Notifications calendrier, détection sans calendrier.**
7. **Rétention, chiffrement, packaging** (signature, notarisation, Login Item).

## 11. Stack applicative

**Choix : Swift natif de bout en bout.** Toutes les briques critiques sont des API Apple ou des SDK Swift (Core Audio taps, AVAudioEngine, SpeechAnalyzer, CoreML, FluidAudio, EventKit, UserNotifications, Foundation Models). Rust/Tauri (voie Anarlog) obligerait à écrire des bindings pour chacune ; Electron ajouterait un runtime pour rien. Le développeur a déjà livré une app barre de menus SwiftUI.

| Couche | Choix | Pourquoi |
|---|---|---|
| UI | SwiftUI, `MenuBarExtra`, fenêtres auxiliaires (notepad flottant, relecture) | Natif, léger, déjà maîtrisé |
| Concurrence | Swift 6 strict concurrency, actors pour capture et store | Sécurité des accès audio/DB |
| Store | SQLite via **GRDB** (migrations, FTS5 pour la recherche plein texte des transcripts) | Même choix qu'Anarlog, robuste, requêtable par le serveur MCP |
| Fichiers | Dossier de données app (`~/Library/Application Support/HWYD`) + dossier d'export Markdown configurable | Séparation état interne / contrat public |
| Audio | Core Audio taps, AVAudioEngine, fichiers CAF par tranches | § 3 |
| Modèles audio | SpeechAnalyzer, FluidAudio (Pyannote, WeSpeaker), Nemotron 3 en challenger | § 4 |
| Pipeline | Exécutable CLI embarqué `hwyd-pipeline` (SwiftPM, cible séparée) | Isolation mémoire, retraitement, tests |
| Empreintes | SQLite pour les métadonnées, vecteurs chiffrés dans le trousseau (comme Anarlog) | Données biométriques |
| LLM | Protocole `LLMProvider` à 3 backends (§ 12) | Opt-in, interchangeable |
| MCP | Exécutable `hwyd-mcp` (SwiftPM, SDK officiel `modelcontextprotocol/swift-sdk`, transport stdio) | § 13 |
| Packaging | Xcode, signature Developer ID, notarisation, Sparkle pour les mises à jour, Login Item | Comme No Bleeding Eyes |
| Tests | XCTest sur le pipeline avec le corpus annoté (DER/WER/identité), snapshots SwiftUI | Jalon 2 |

Structure : un workspace SwiftPM avec un package `HWYDCore` (modèle de données, store, pipeline, providers) partagé par trois cibles : l'app, `hwyd-pipeline`, `hwyd-mcp`.

### Modèle de données : l'enregistrement

Un enregistrement (`Recording`) porte quatre artefacts, chacun avec son cycle de vie :

| Artefact | Contenu | Rétention | Produit par |
|---|---|---|---|
| **Audio** | pistes micro et système, CAF | **X heures** configurable (défaut 72 h), purge automatique, suppression immédiate possible ; purge différée tant que le pipeline n'a pas fini | capture |
| **Transcript** | segments (début, fin, piste, speaker, texte, confiance), speakers résolus ou `speaker-xxxx` | permanent, versionné à chaque correction ou retraitement | pipeline |
| **Summary** | synthèse, action items, décisions ; avec provenance (fournisseur, modèle, version du prompt, date) | permanent, régénérable | LLM provider (opt-in) |
| **Notes** | notes manuelles, horodatées sur l'horloge de session, éditables après coup (fenêtre à la manière de Notion : titre, notes libres, transcript dépliable) | permanent | utilisateur |

Plus les métadonnées : `kind`, titre, date, durée, événement calendrier lié, participants (confirmés / devinés avec score), `consent_announced`.

## 12. Traitements LLM (synthèse, action items)

Opt-in dans les réglages. Un protocole unique `LLMProvider` (`generate(prompt, schema) -> structured output`) et trois backends :

| Backend | Implémentation | Cas d'usage |
|---|---|---|
| **Embarqué** | MLX Swift (`mlx-swift-lm`) avec un petit modèle téléchargé à la demande ; candidat par défaut **LFM2.5-1.2B-Thinking** (Liquid AI, < 1 Go, 32k de contexte, support MLX et llama.cpp annoncé) ; liste courte de modèles téléchargeables à benchmarker sur les transcripts (Qwen3 1.7B/4B, Gemma 3 4B, SmolLM3 3B) ; Foundation Models d'Apple en alternative sans téléchargement (contexte ~4k, insuffisant pour un transcript entier sans découpage) | Zéro configuration, tout local |
| **Endpoint local** | API OpenAI-compatible : LM Studio, Ollama (`http://localhost:…`), modèle au choix | Utilisateur qui a déjà un serveur local et veut un modèle plus gros |
| **API distante** | OpenAI-compatible ou Anthropic, clé dans le trousseau, avertissement explicite que le transcript quitte la machine | Qualité maximale, opt-in séparé |

Règles : sortie structurée (JSON schema) pour summary et action items ; découpage par fenêtres avec réduction finale pour les longs transcripts ; prompts versionnés dans le dépôt ; aucun appel sans fournisseur configuré ; la provenance est stockée avec le summary. **[spike]** : banc des petits modèles sur des transcripts réels (fidélité des action items, attribution des décisions, respect du schéma JSON, temps pour une heure d'audio sur M-series). LFM2.5-1.2B-Thinking en défaut provisoire ; son contexte de 32k couvre une heure de transcript.

## 13. Serveur MCP

Exécutable `hwyd-mcp` en transport **stdio**, déclaré dans Claude Code ou Codex comme n'importe quel serveur local. Il lit le store SQLite et les fichiers en lecture seule ; l'app n'a pas besoin de tourner. Transport HTTP streamable en option plus tard (le support serveur dans le SDK Swift officiel est à vérifier).

Outils (v1) :
- `list_recordings(since, kind, participant, limit)`
- `get_recording(id, include: transcript | summary | notes | all)`
- `search(query)` : FTS5 sur transcripts, summaries et notes
- `get_participants()` : personnes connues avec leurs alias
- `set_notes(id, markdown)` et `rename_speaker(id, speaker, person)` : écriture, désactivables dans les réglages

Ressources : `hwyd://recording/<id>/transcript.md`, `/summary.md`, `/notes.md`. L'export Markdown (§ 7) reste disponible en parallèle pour les consommateurs qui préfèrent les fichiers.

## 14. Risques

- Diarisation en salle insuffisante même après correction : repli = micro de conférence externe, ou précision moindre assumée en présentiel.
- Dérive d'horloge entre pistes si l'aggregate device n'est pas correctement configuré.
- Rejet d'écho post-hoc insuffisant en hybride avec haut-parleurs du Mac.
- Rupture du graphe audio au changement de device.
- Tap global qui capture musique et notifications : VAD optionnel sur la piste système.
- WHO : licence source-available, ping mensuel d'un serveur de licence, pas d'embeddings ni d'indice de nombre de speakers exposés.
- Fuite de données biométriques ou de contenu vers les agents : aucun vecteur exporté, transcripts documentés comme sortant vers un LLM.
- Dépendance à macOS 26 (SpeechAnalyzer) : acceptable pour un outil perso.
- Anarlog (ex-Hyprnote, open source MIT ; Char est désormais un autre produit de la même équipe) fait déjà des empreintes persistantes WeSpeaker ; le différenciant est la vocation general usage, les catégories de canal, la boucle de correction et un contrat de sortie Markdown ouvert à n'importe quel consommateur.
