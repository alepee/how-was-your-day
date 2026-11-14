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
| Synchronisation | Tap et micro dans **un seul aggregate device** avec compensation de dérive, un seul IOProc. Exception (0.10.0) : si le micro et le tap n'ont pas la même fréquence, typiquement un casque Bluetooth en mode appel (HFP, 16 kHz), deux horloges séparées, alignées par le writer sur l'horloge hôte | Deux horloges séparées dérivent d'environ 450 ms sur 2h30. Un aggregate n'offre que les fréquences de son sous-device et ne rééchantillonne pas (spike du 2026-11-10, MOMENTUM 3), d'où la compensation logicielle dans ce cas. |
| Écho des distants sur le micro | Traité **après coup** : fenêtres où la piste système est active et le micro corrélé = écho, rejetées ; un cluster micro qui suit l'activité système est écarté | Remplace l'AEC. **[spike]** : qualité de ce rejet en hybride avec haut-parleurs du Mac. |
| Stockage | Fichiers CAF par tranches de 5 min, 16 kHz mono par piste | Un WAV unique laisse un en-tête invalide en cas de crash. |
| Changement de device | Recréer le graphe, garder une horloge hôte commune | AirPods connectés en cours de réunion. |
| Permissions | Micro, audio système, calendrier (accès complet), notifications, Automation (navigateur) | Pas d'enregistrement d'écran. |

## 4. Pipeline

| Étape | Modèle / mécanisme | Alternative | Remarques |
|---|---|---|---|
| ASR | SpeechAnalyzer `SpeechTranscriber`, locale choisie par session ou détectée par piste (0.11.0, voir [design technique](technical-design.md)), attribut `audioTimeRange` par token, **au fil de l'eau par tranche de 5 min et par piste** | Parakeet TDT 0.6B v3 (FluidAudio, 25 langues dont français), WhisperKit | **[spike]** : présence de `fr-FR` dans `supportedLocales`, timestamps par mot, code-switching fr/en (une locale par session, à tester). |
| VAD | Aucun dédié | Silero v6 (FluidAudio) seulement si besoin de filtrer musique/notifs sur la piste système | Pyannote et SpeechAnalyzer ont le leur. |
| Diarisation | **Pyannote community-1 offline** (FluidAudio `OfflineDiarizerManager` : segmentation powerset, WeSpeaker, VBx), sortie exclusive, par piste, **en fin de réunion** sur le fichier complet | NVIDIA Nemotron 3 diarization (challenger : 8 speakers, ~100 Mo, CoreML/MLX, pas d'embeddings, NVIDIA Open Model License) ; Pyannote 3.1 allégé en repli si trop lourd ; WHO en 3e option seulement si sa licence source-available et son ping mensuel conviennent | Le défaut doit tenir sur le cas difficile (micro en salle). Sortformer écarté : 4 slots fixes. `max_speakers` = invités calendrier + 2, jamais un nombre exact. |
| Alignement | Chaque mot va au speaker qui recouvre le plus son intervalle ; phrases ASR découpées aux changements de speaker ; tours < 0,5 s ou 2 mots absorbés sauf aux frontières de piste | ASR par tour de parole, seulement en rattrapage des zones de faible confiance | Le vote par phrase attribue faussement toute phrase qui chevauche un changement. |
| Embeddings | WeSpeaker v2, 256-d, FluidAudio `embedSpans` / `extractEmbedding` | | Embedder un **cluster entier** (≥ 10-20 s de parole propre, hors chevauchement), jamais un segment isolé. |
| Identité | Voir § 5 | | |

Un modèle chargé à la fois. Le CLI se termine après chaque réunion, donc la mémoire est rendue.

## 5. Identité des speakers (le cœur)

**Principe** : une base locale d'empreintes vocales (fingerprints) est ce qui transforme « speaker 1 / speaker 2 » en noms. Sans elle, la diarisation seule ne donne que des étiquettes anonymes par session. La base est la propriété de l'utilisateur, sur sa machine, jamais exportée.

- **Empreinte par personne et par canal** : `mic` (micro, proche ou salle) et `remote` (Opus/AGC de la visio), déduit de la piste, jamais choisi par l'utilisateur. Jusqu'à 20 exemplaires par canal, chacun avec la session et la voix d'origine pour pouvoir retirer l'apport d'une session. Score = moyenne des 3 meilleurs exemplaires du même canal. Si la personne n'a aucun exemplaire sur ce canal, l'autre canal sert de repli avec un seuil de 0,85 au lieu de 0,75. Raison : le décalage de canal fait tomber la similarité intra-personne dans la zone inter-personnes. La distinction `near`/`room` (avant 0.9) a été retirée : elle n'était pas utilisée à la comparaison et ses exemplaires sont fusionnés dans `mic` à la première lecture.
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
| Fichiers | Dossier de données app (`~/Library/Application Support/HWYD`) + dossier d'export Markdown configurable. `SessionFiles` (HWYDCore) recense les fichiers d'une session hors SQLite : `audio/<id>/`, `cache/summaries/<ID>/`, `cache/waveforms/<chunk>-<bins>.json`, `jobs/<uuid>/` et `jobs/voice-<uuid>/` dont la requête nomme la session. `RecordingRepository.remove` refuse une session en cours d'enregistrement, supprime la ligne puis ces fichiers et rend leur bilan dans `RecordingRemoval.files` ; un échec est signalé, et `SessionLibrary.load` le reprend au lancement par `removeOrphanFiles`, en tâche de fond une fois la bibliothèque prête, hors de l'acteur du store : seulement si `pipeline.lock` est libre et la bibliothèque non vide. Il ne prend jamais `capture.lock`, une capture peut donc démarrer pendant le balayage ; il garde toute entrée écrite depuis moins d'une heure, car le dossier d'une capture qui démarre précède sa ligne SQLite. Jamais hors du dossier de données, jamais à travers un lien symbolique | Séparation état interne / contrat public ; aucune session sans son audio, aucun audio sans session |
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

### Settings and helper paths

Two stores hold settings, each behind typed accessors; no caller spells a key.

- **Preferences** go through the `SettingsStore` port (`Packages/HWYDCore/Sources/HWYDCore/Settings.swift`). Every key is declared once as a `SettingKey<Value>` with its type and default, under the UserDefaults name earlier versions wrote, so an update keeps the user's choices. Adapters: `UserDefaultsSettings` for the installed app, `InMemorySettings` for previews, tests and synthetic checks. `AppModel` and `CalendarIntegration` read and write only the store they are given; a model built for a preview or another data directory gets an in-memory store and never reads the user's preferences.
- **Integration settings**, read by `hwyd-mcp` without the app, stay in SQLite (`integration_settings`). `SessionStore.mcpWritesEnabled()`, `exportDirectory()` and their setters are the only access; their keys are named in `IntegrationSetting`. The app, the store's mutation gate and export publisher, and `hwyd-mcp` all use them.

`SummarySettings` (HWYDCore) holds the summary preferences shown in the app, loads and saves them through the `SettingsStore`, manages the hosted provider's key and model list, and produces the `SummaryConfiguration` given to `SummarizerFactory` (§ 12). It finds installed ACP agents through the `AgentDiscovery` port: `LoginShellAgentDiscovery` (app, `zsh -lc`) for the installed app, `FixedAgentDiscovery` for previews and tests.

`HelperLocator` (HWYDCore) is the only place that knows where `hwyd-pipeline` and `hwyd-mcp` live. The app builds it once from its bundle (`HelperLocator.app`) and hands it to the pipeline adapters (below) and the summarizer environment.

Known gap, for later steps: the keychain is reached through static enums.

### Pipeline ports

The app reaches `hwyd-pipeline` through three ports declared in HWYDCore, each with an in-memory double used by unit tests and by the `--ui-test` check:

| Port | Operations | App adapter | Double |
|---|---|---|---|
| `TranscriptionService` (`TranscriptionService.swift`) | `transcribe(TranscriptionRequest) -> TranscriptionResult` | `HelperTranscriptionService` | `InMemoryTranscriptionService` |
| `VoiceMemory` (`VoiceMemory.swift`) | `enroll`, `identify`, `forget(person)`, `forget(person, source)`, `sources(person)` | `HelperVoiceMemory` | `InMemoryVoiceMemory` |
| `SpeechModelCatalog` (`SpeechModelCatalog.swift`) | `locales()`, `install(locale)`, `diarizerReady()`, `installDiarizer()` | `HelperSpeechModelCatalog` | `InMemorySpeechModelCatalog` |

The adapters (`Sources/HWYDApp/HelperPipeline.swift`) are the only code that knows the helper's commands, the job folders under `<store>/jobs`, `request.json` and `result.json`; `PipelineRunner` starts the process for them and nothing else calls it. Cancelling the calling task stops the helper. The transcription job folder is removed once its result is read and kept after a failure, with its log. No voice vector crosses `VoiceMemory`: the helper alone reads the keychain, and its results carry matches and contributions only.

- **Requests.** `TranscriptionRequest(session:language:diarize:locales:)` builds a session's request: the language chosen for this run, else the session's, else French for sessions recorded before the choice existed; with automatic detection, the candidates, fallback and installable languages come from the catalog's `locales()`, as the helper resolves them.
- **Readiness.** `diarizerReady()` reads the models on disk (`hwyd-pipeline diarizer-status <store>` checks every file the offline diarizer loads). The app no longer infers it from a preference or the transcript history.
- **Voice identity.** `Recording.linkSpeaker(_:to:)` is the one mutation that confirms a voice as a person (name validation, opposed person refused); the voice tiles, the end of an enrollment and the MCP rename (`SessionStore.mutate`) all use it. It reads and writes no voice print. `EnrollVoice` (`EnrollVoice.swift`) is the only path to a print: `EnrollVoice.person(named:for:among:)` validates the name, finds the person and refuses an opposed one; running it records the user's request on the person through the `VoicePeople` port (`SessionStore`, or `InMemoryVoicePeople`), then calls `VoiceMemory.enroll`. `Recording.applyEnrollment` and `proposeIdentities` apply its outcome. A speaker correction never leads to `EnrollVoice`.

Known gap, for later steps: `PipelineRunner` polls the helper process every 200 ms.

### Heavy work

`WorkCoordinator` (`Packages/HWYDCore/Sources/HWYDCore/WorkCoordinator.swift`), an actor, owns heavy-work exclusivity: transcription, voice jobs, model installs and summaries (`WorkJob`) run one at a time, since they share the CPU, the Neural Engine, the helper's lock and the transcript they read.

- **Requests.** A trigger calls `request(job, run:)` and gets a `WorkDecision`: `accepted` (the job starts), `queued(behind:)` or `refused(WorkRefusal)` with the reason (the job that runs, the same job already requested, or a condition of the session or the mode). Transcriptions wait their turn (`WorkJob.waitsWhenBusy`), so the end of a capture never loses one; jobs the user starts by hand are refused with the reason. `AppModel` says every refusal in a notice: no trigger hits a silent guard.
- **Availability.** `Availability<Reason>` is `ready`, `busy(WorkBusy)` or `unavailable(Reason)`. A service states its own conditions (`SummaryAvailability` is `Availability<SummaryUnavailability>`); `combined(with:)` adds the coordinator's `busy`, and the service's own reason comes first. Views read `AppModel.workAvailability` and `summaryAvailability` instead of busy flags.
- **State.** `snapshots()` streams `WorkSnapshot` (running job, waiting jobs, growing `revision`); `AppModel.work` mirrors it, so views show what runs and what waits. `busyChanges()` streams only the flips of `isBusy`; `AppModel.isBusy` adds a running capture to it, and the updater and the library refresh read it instead of the whole model's changes. `idle()` returns once nothing runs or waits, and returns early when its task is cancelled. `cancel(where:)` stops a running job (it still runs its cleanup) and drops waiting ones.
- **Order.** `AppModel` runs trigger requests one after another (`enqueue`), so a cancel never overtakes the request it cancels; `AppModel.idle()` waits for those requests, then for the coordinator. App termination and the synthetic checks await it instead of polling.
- **Deletion.** A session with work running or waiting on it (transcription, summary, voice job) cannot be deleted; the user is told why.
- **Second line of defense.** `hwyd-pipeline` keeps its `flock` on `<store>/pipeline.lock` for transcription and voice commands (model installs take none). It only guards against a process the coordinator cannot see (a second app instance, a script); inside the app, the coordinator decides first.

- **Queue and restarts.** The waiting order lives in memory on purpose. Quitting cancels running and waiting work (the termination handler asks for it): a running transcription stops and is marked failed, with its retry (after a crash, the next launch marks it failed). A waiting one simply never started: its session keeps its audio and its « Transcrire » button. Persisting the queue would mean resuming heavy work unasked at launch, a new behavior, so it is not done.

Known gap, for later steps: demo mode is still a flag checked by each request.

### Sessions and persistence

Sessions go through one port and one application service, both in HWYDCore.

| Part | Role | Adapters / doubles |
|---|---|---|
| `RecordingRepository` (`RecordingRepository.swift`) | `all`, `recording(id)`, `revisions`, `save` (optimistic: `StoreError.conflict` when another writer committed first, `StoreError.notFound` when the session was deleted since it was read, so a deleted session is never created again), `remove`, `recoverInterrupted`, `sequence` (grows with every commit, by any process), the export outbox (`pendingExports`, `acknowledgeExport`), and `removeOrphanFiles` (files of sessions deleted earlier; nil for an adapter without files) | `SessionStore` (GRDB, shared with `hwyd-mcp` and `hwyd-pipeline`), `InMemoryRecordingRepository` |
| `SessionLibrary` (`SessionLibrary.swift`, `@MainActor`, `@Observable`) | Working copies shown by the app and the rules for changing them | volatile library (previews, demo mode) |
| `ExportPublisher` (`ExportPublisher.swift`) | `publish(recording)`, `withdraw(id, revision)` | `FolderExportPublisher` (`SessionExporter` generations), `InMemoryExportPublisher` |

`Recording.committed(over:)` holds the commit rules both repositories apply: next revision, notes and summary versions, no summary provenance without a summary.

- **Edits.** `edit(id, mutation)` changes the working copy at once and saves it after 300 ms; `flush()` saves now. An edit made while a save is in flight stays in the working copy and is saved by the next turn. A save that meets another writer's commit reads it, rebases the pending edit on it (`Recording.merge(base:local:remote:)`, per `RecordingPart`) and tries again. A part both sides changed keeps the app's side; the other writer's revision stays in `ui_recording_versions`, and the user is told. A summary follows the transcript it was made from.
- **Other writers.** `hwyd-mcp` writes from another process. The library reads `sequence()` every 2 seconds (one row); when it moved, it compares `revisions()` with its own and decodes only the sessions that changed. Clean copies are replaced, copies with pending edits are rebased, sessions deleted elsewhere leave; pending edits leave with them and the user is told (`removedElsewhere`). The watch starts with the first load: when that load fails, its next tick reads every session again. SQLite offers no cross-process notification GRDB can observe, and `PRAGMA data_version` would still need the same poll, so the cheap check stays. It replaces the former 3-second poll that swapped the whole list and skipped while anything was unsaved or busy.
- **Results of work.** Transcription, voice recognition and enrollment, and summaries run on a copy. They apply their result with `apply(id, ifStillAt: transcriptVersion, where:)`: pending edits are saved, the stored session is merged, then the transcript version and the caller's own condition (the summary's input hash) decide. An outdated result, or one for a deleted session, throws `StaleResult` and changes nothing; each flow keeps its own message. Any other failure to read the stored session is thrown as is. A result that cannot be saved throws `UnsavedResult`: it stays a pending edit, and the save failure is the notice. When both sides changed the transcript, the merged one takes a transcript version neither side used, so work that read the other side is stale.
- **Publication.** Every commit of a sealed session and every deletion leaves an outbox entry in the same transaction. The library drains the outbox (`ExportOutbox.drain`) into the publisher of the moment after its own commits, after each commit it sees from another process, at load, and when a publication folder is chosen; `hwyd-mcp` drains it after its own write when a folder is set. A failing entry holds back only the later entries of its own session; the others are published, the failure is reported once and retried at the next drain. A one-off export to a folder the user picks uses the same `FolderExportPublisher`.
- **Readiness and changes.** `await library.ready` returns once the first load is done (launch actions from the calendar and `hwyd://` links wait on it). `changes` streams `LibraryChange` (saved, save failed, external, rebased, export deferred, removed elsewhere, files left by the launch sweep, sweep failed); `AppModel` turns failures and conflicts into notices.
- **Deletion.** `remove(id)` returns a `RecordingRemoval`: the removed session, and `files`, the `SessionFiles.Report` of what the repository removed or could not remove (nil for `InMemoryRecordingRepository`, which keeps no files). Both repositories refuse a session that is recording (`StoreError.capturing`); the library publishes the withdrawal itself. A failure to remove a file is reported, and the files stay until the next launch sweep.
- **Launch sweep.** After a successful load of a non-empty library, `fileSweep` runs `removeOrphanFiles` in the background: it holds no library operation and does not delay `ready`. It reports only what it could not remove (`filesLeft`, `fileSweepFailed`).

`AppModel` keeps the projection only: `recordings` and `hasUnsavedChanges` read the active library (the stored one, or a volatile one in demo mode and previews). Known gap, for later steps: snapshots replace a volatile library's sessions through `show(_:)`, a test seam the composition root (step 7) can remove.

### User notices

Flows tell the user what happened through the `UserNotifier` port (`Packages/HWYDCore/Sources/HWYDCore/UserNotifier.swift`), never by setting model state. A `UserNotice` carries a style (info, success, error), a message, its actions, and whether it waits for the user (`sticky`, or actions that are not `optional`). An action either names a `NavigationIntent` (a session tab, a session's language choice, the summary settings) or performs an effect its reporter owns, such as a retry or an undo.

- `ToastCenter` (app, `@Observable`) is the adapter: it shows notices as toasts, keeps at most four (transient ones leave first), replaces a repeated message, owns the dismissal timers and hover hold, and announces each message to VoiceOver. Navigation intents are handed to `AppModel.navigate(to:)`, which `hwyd://` links also use.
- `RecordingNotifier` (HWYDCore) keeps notices in memory for tests.

`AppModel`, `SummarySettings` and the view extensions report through the notifier they are given. Known gap, for later steps: use cases still build their message strings themselves; typed results mapped to notices by the presentation come with the services that own them.

## 12. Traitements LLM (synthèse, action items)

Opt-in dans les réglages. Un protocole unique `LLMProvider` (`generate(prompt, schema) -> structured output`) et trois backends :

| Backend | Implémentation | Cas d'usage |
|---|---|---|
| **Embarqué** | MLX Swift (`mlx-swift-lm`) avec un petit modèle téléchargé à la demande ; candidat par défaut **LFM2.5-1.2B-Thinking** (Liquid AI, < 1 Go, 32k de contexte, support MLX et llama.cpp annoncé) ; liste courte de modèles téléchargeables à benchmarker sur les transcripts (Qwen3 1.7B/4B, Gemma 3 4B, SmolLM3 3B) ; Foundation Models d'Apple en alternative sans téléchargement (contexte ~4k, insuffisant pour un transcript entier sans découpage) | Zéro configuration, tout local |
| **Endpoint local** | API OpenAI-compatible : LM Studio, Ollama (`http://localhost:…`), modèle au choix | Utilisateur qui a déjà un serveur local et veut un modèle plus gros |
| **API distante** | OpenAI-compatible ou Anthropic, clé dans le trousseau, avertissement explicite que le transcript quitte la machine | Qualité maximale, opt-in séparé |

Règles : sortie structurée (JSON schema) pour summary et action items ; découpage par fenêtres avec réduction finale pour les longs transcripts ; prompts versionnés dans le dépôt ; aucun appel sans fournisseur configuré ; la provenance est stockée avec le summary. **[spike]** : banc des petits modèles sur des transcripts réels (fidélité des action items, attribution des décisions, respect du schéma JSON, temps pour une heure d'audio sur M-series). LFM2.5-1.2B-Thinking en défaut provisoire ; son contexte de 32k couvre une heure de transcript.

### Summarizer contract

The app asks for a summary through one interface, `Summarizer` (`Packages/HWYDCore/Sources/HWYDCore/Summarizer.swift`): `availability` (`.ready` or `.unavailable(reason)`, with a localized reason) and `summarize(recording, progress:)`. Each implementation owns its own conditions and refuses to run, with `SummaryUnavailability`, when they are not met:

| Implementation | Ready when | Runs |
|---|---|---|
| `LocalSummarizer` | loopback HTTP address and a model | `LocalLLMProvider` through `SummaryPipeline`, input limit from the loaded context |
| `HostedSummarizer` | a key is stored, then a model is chosen | `RemoteLLMProvider` through `SummaryPipeline`; the key is read only when it runs, through the injected environment |
| `AgentSummarizer` | an agent command | `ACPSummaryAgent` with the bundled `hwyd-mcp` |
| `UnavailableSummarizer` | never (null object, summary turned off) | nothing |

Resumable checkpoints (`cache/summaries/<id>`) and cache reuse stay inside the pipeline implementations. `SummarizerFactory.make(configuration, environment:)` is the only place that maps the settings (`SummaryConfiguration`, one `Equatable` value) to an implementation; `SummarizerEnvironment` carries the data directory, the `hwyd-mcp` path and key access. Callers (the Generate button today) keep only app policy: demo mode, flush before the run, stale check, persistence and toasts; one job at a time is the `WorkCoordinator`'s (§ 11). They read `availability`, combined with the coordinator's `busy`, to disable the button and explain why, and never check the summarizer's conditions themselves.

Each implementation also states, through `disclosure` (`SummaryDisclosure`), where its draft is written and what leaves the Mac: the line under the summary controls and the explanation shown before a first summary. The local server says the draft is local; a hosted provider names itself, since the transcript is sent to it; an agent says the draft comes from the user's agent; a summary turned off claims no location and says how to turn it on. The summary tab only displays these texts.

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
