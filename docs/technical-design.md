# Design technique HWYD

Statut : proposition d'implémentation du 23 octobre 2026. Référence : [architecture v0.1](architecture.md), laissée intacte. Les amendements sont regroupés en fin de document. Les seuils expérimentaux ne sont pas des résultats mesurés.

## 1. Périmètre et invariants

Jalon 1 : une app signée capture deux pistes synchronisées, ferme des CAF récupérables et survit aux changements de périphérique. Jalon 4 : le CLI produit un transcript anonyme, ses métadonnées calendrier et les exports, sans identité ni LLM requis. Les contrats préparent les jalons suivants sans les rendre bloquants.

| Invariant | Conséquence |
|---|---|
| macOS 26 minimum, Apple Silicon pour la distribution v1 | Swift 6, mode de langage 6, vérification stricte de concurrence |
| Une capture active par utilisateur | Verrou de capture global ; le pipeline ne possède jamais le micro |
| Deux pistes brutes | Aucun VPIO ; écho traité en aval ; source toujours traçable |
| Unité temporelle commune | Entiers `Int64` en microsecondes depuis le démarrage ; intervalles semi-ouverts `[start_us,end_us)` |
| SQLite est l'autorité transactionnelle interne | Fichiers audio et résultats immuables référencés par hash ; export public reconstructible |
| Consentement absent | Aucun embedding persistant ni rapprochement biométrique entre sessions |
| Capture prioritaire | Une file bornée protège le callback ; saturation visible et enregistrée comme lacune |

## 2. Workspace et dépendances

```text
HWYD.xcworkspace/
App/HWYD.xcodeproj/                 # bundle, signature, Info.plist, ressources
App/HWYD/                          # SwiftUI, composition des dépendances
Package.swift                      # exécutables HWYDPipeline et HWYDMCP
Packages/HWYDCore/Package.swift
Packages/HWYDCore/Sources/
  HWYDDomain/ HWYDStore/ HWYDAudio/ HWYDPipeline/
  HWYDSpeech/ HWYDFluidAudio/ HWYDIdentity/ HWYDProviders/ HWYDExport/
  HWYDRealtime/                     # petit module C, ring buffer SPSC
Sources/HWYDPipeline/
Sources/HWYDMCP/
Tests/                             # contrats, intégration, corpus exclu du dépôt
Resources/Prompts/summary-v1.txt
Resources/Models/manifest.json      # références, licences, hashes ; pas les poids
```

`HWYDCore` est un package à plusieurs cibles, pas un module monolithique. L'app Xcode consomme ses produits SwiftPM. SwiftPM construit les deux CLI ; le packaging les copie dans `HWYD.app/Contents/Helpers/`. Un simple executable SwiftPM ne remplace pas un bundle macOS avec permissions et signature.

| Dépendance | Base retenue, figée à l'intégration | Consommateur |
|---|---|---|
| Xcode / Swift / SDK | Xcode 26, Swift 6.2, SDK macOS 26 au minimum | Toutes les cibles ; CI sur le minimum et sur le SDK courant |
| [GRDB](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) | `7.11.1`, Swift tools 6.1 | `HWYDStore` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7) | `0.17.7`, Swift tools 6.0 | `HWYDFluidAudio` |
| [MCP Swift](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) | `0.12.1`, Swift tools 6.1 | `HWYDMCP` seulement |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) | `3.32.3`, Swift tools 6.2 | `HWYDProviders`, hors chemin critique J4 |
| [Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) | `2.10.0` | App, packaging ultérieur |
| Frameworks système | CoreAudio, AudioToolbox, AVFAudio, Speech, EventKit, Security, CryptoKit, CoreML, UserNotifications, ServiceManagement | Adaptateurs dédiés |

Ces tags existent et leurs manifests ont été consultés. Leur compatibilité combinée n'a pas été compilée ici. Utiliser des versions exactes et committer `Package.resolved`, y compris les dépendances transitives. Ne pas dépendre de `main`. Le SDK local inspecté est **27.0**, donc il ne suffit pas à prouver une compilation avec SDK 26. Les APIs ajoutées après 26 restent interdites au chemin de base.

Les modèles ont leur propre manifeste : `model_id`, révision amont immuable, SHA-256 des fichiers, licence, runtime, dimensions, sample rate et version de conversion. Aucun numéro de poids inventé ici : le banc fige les artefacts réellement téléchargés avant toute comparaison. Téléchargements explicites, vérification des hashes, puis exécution hors ligne. Une mise à jour de poids invalide les caches concernés.

## 3. Modules et interfaces

| Module | Responsabilité et dépendances | Interface principale |
|---|---|---|
| `HWYDDomain` | DTO `Sendable`, identifiants, états, erreurs ; Foundation seulement | `Recording`, `TimedWord`, `SpeakerTurn`, `SessionSnapshot` |
| `HWYDStore` | GRDB, migrations, révisions, commandes, accès trousseau | `SessionStore`, `VectorVault` |
| `HWYDAudio` | Graphe HAL, horloge, changements de device, writer CAF | `AudioCapture` ; Domain + Realtime + Store |
| `HWYDSpeech` | Conversion PCM et adaptation SpeechAnalyzer | `ASRProvider` |
| `HWYDFluidAudio` | ASR de repli, diarisation, embeddings ; aucun type SDK exporté | `ASRProvider`, `Diarizer`, `SpeakerEmbedder` |
| `HWYDIdentity` | Catégories, scoring, consentement, affectation | `IdentityResolver` ; Domain + accès `VectorVault` |
| `HWYDPipeline` | Ordonnancement, étapes, reprise, alignement, écho | `SessionPipeline` ; dépend seulement des protocoles |
| `HWYDProviders` | MLX, endpoint local, OpenAI-compatible, Anthropic | `LLMProvider` |
| `HWYDExport` | Sérialisation déterministe, publication, journal d'index | `SessionExporter` ; Domain + Store |
| App | UI, EventKit, permissions, supervision, corrections | `@MainActor AppModel` |
| CLI pipeline | Assemblage des adaptateurs, exécution isolée | `hwyd-pipeline run --id UUID --follow` |
| CLI MCP | Validation MCP, lecture et commandes autorisées | Contrat [MCP](mcp.md) ; pas de lien vers FluidAudio ou MLX |

Les signatures ci-dessous sont **des protocoles HWYD proposés**, pas des signatures Apple ou FluidAudio. Les DTO sont définis par le tableau qui suit et le [modèle de données](data-model.md). Tous les appels sont annulables ; l'annulation ne publie aucun résultat incomplet.

```swift
public protocol AudioCapture: Sendable {
    func start(_ request: CaptureRequest) async throws -> CaptureHandle
    func events(for id: UUID) async -> AsyncStream<CaptureEvent>
    func stop(_ id: UUID) async throws -> CaptureManifest
}
public protocol SessionPipeline: Sendable {
    func run(_ request: PipelineRequest) async throws -> PipelineOutcome
    func cancel(_ id: UUID) async
}
public protocol ASRProvider: Sendable {
    func capabilities() async throws -> ASRCapabilities
    func transcribe(_ input: AudioSlice, locale: String) async throws -> WordBatch
}
public protocol Diarizer: Sendable {
    func diarize(_ input: TrackAudio, hints: DiarizationHints) async throws -> Diarization
}
public protocol SpeakerEmbedder: Sendable {
    func embed(_ input: ClusterAudio) async throws -> EphemeralEmbedding
}
public protocol IdentityResolver: Sendable {
    func resolve(_ request: IdentityRequest) async throws -> IdentityResolution
}
public protocol LLMProvider: Sendable {
    func capabilities() async throws -> LLMCapabilities
    func generate(_ request: StructuredRequest) async throws -> StructuredResponse
}
public protocol SessionStore: Sendable {
    func snapshot(_ id: UUID, revision: Int64?) async throws -> SessionSnapshot
    func apply(_ command: StoreCommand, expectedRevision: Int64,
               requestID: UUID) async throws -> CommitReceipt
    func claim(_ job: JobKey, owner: UUID) async throws -> JobLease
    func complete(_ lease: JobLease, result: StageResult) async throws
}
public protocol SessionExporter: Sendable {
    func publish(_ snapshot: SessionSnapshot) async throws -> ExportReceipt
}
public protocol VectorVault: Sendable {
    func read(_ reference: UUID) async throws -> EphemeralEmbedding
    func stage(_ embedding: EphemeralEmbedding, operation: UUID) async throws -> UUID
    func delete(_ reference: UUID) async throws
}
```

| DTO | Champs et règles |
|---|---|
| `CaptureRequest` | `recordingID`, pistes demandées, device UID micro, consentement annoncé, instant UTC ; pas d'objet EventKit |
| `PipelineRequest` | `recordingID`, mode follow/sealed, identité disabled/enabled, config versionnée, référence transcript de départ ; aucune dépendance UI |
| `PipelineOutcome` | run ID, transcript publié, état export, avertissements ; ne confond pas summary failed et pipeline failed |
| `TrackAudio` | piste, durée session, CAF complet éphémère, gaps, hash ; lecture hors mémoire intégrale |
| `DiarizationHints` | nombre de speakers facultatif et souple, profil de modèle ; jamais identité calendrier imposée |
| `ASRCapabilities` | locales effectives, disponibilité locale, granularité temporelle annoncée, modèle/révision |
| `WordBatch` | mots finaux, intervalle central, provenance, avertissements, hash d’entrée |
| `IdentityRequest` | clusters, canaux, embeddings éphémères, candidats consentis, invités contexte, version de calibration |
| `LLMCapabilities` | contexte effectif, budget de sortie, tokenizer, support schema, mode local/remote |
| `CaptureHandle` | ID et origine d'horloge ; succès uniquement après démarrage effectif du graphe |
| `CaptureEvent` | `started`, `chunkSealed`, `gap`, `deviceChanged`, `stopped`, `failed` ; la DB permet de relire les événements perdus par l'UI |
| `AudioSlice` | ID piste, fichiers fermés, intervalle central et contexte ; mapping vers temps session ; hash |
| `TimedWord` | texte, intervalle, piste, confiance nullable, `timing_quality` ; ponctuation jointe au mot voisin |
| `Diarization` | tours exclusifs, régions de chevauchement séparées, clusters locaux et provenance |
| `ClusterAudio` | spans propres de même piste/canal, durée cumulée ; minimum 10 s, cible 20 s |
| `EphemeralEmbedding` | 256 Float32 normalisés, `embedding_space_id` ; non `Codable`, jamais dans logs/exports |
| `IdentityResolution` | candidats, scores bruts et ajustés, marge, seuils, abstention, affectation proposée |
| `StructuredRequest` | prompt versionné, schema JSON, fenêtres de transcript, budget de tokens ; contenu traité comme données |
| `StructuredResponse` | JSON validé, provenance, références aux segments ; aucune publication de JSON invalide |
| `CommitReceipt` | `recordingID`, nouvelle `revision`, `exportState` ; pas de promesse de synchronisation immédiate du dossier |

## 4. Capture, horloges et CAF

### Construction du graphe

1. Acquérir `capture.lock` par `flock(LOCK_EX|LOCK_NB)`. Créer la session `preparing` et son dossier privé. Vérifier micro et destination avant de démarrer.
2. Résoudre le PID de l'app en **AudioObjectID de process**. La liste d'exclusion de `CATapDescription` attend ces objets, pas des PID. Exclure aussi les helpers HWYD producteurs d'audio éventuels.
3. Créer le tap global stéréo privé, sans mute de la sortie. Lire son format. Créer un aggregate privé contenant le device micro et le tap. Choisir le micro comme horloge principale et activer la compensation de dérive du tap. Vérifier les propriétés réellement appliquées.
4. Énumérer les streams et canaux du nouvel aggregate. Construire une table `stream/channel -> mic/system`. Ne jamais supposer que les deux premiers canaux sont ceux du micro. Installer **un seul IOProc**.
5. Le callback copie PCM, `mHostTime`, sample time, format et numéro d'époque dans un ring SPSC préalloué de 2 s. Aucun `await`, allocation, lock bloquant, accès DB, log ou écriture disque dans ce callback.
6. Un worker hors temps réel lit le ring. Il convertit chaque piste en mono Float32 PCM little-endian, 16 kHz, CAF. Pour le tap stéréo : moyenne L/R avec limitation du niveau ; tester l'annulation de phase. Pour un micro multicanal : canal choisi dans la configuration, pas de somme implicite.

Les clés `kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey` et `kAudioSubTapDriftCompensationKey`, ainsi que `AudioHardwareCreateProcessTap`, sont présentes dans les headers locaux. Le [sample Apple](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) confirme le montage tap dans un aggregate. Le câblage exact du micro et du tap doit être validé matériellement au jalon 1.

### Horloge et rotation

L'origine monotone est fixée au démarrage effectif. Le temps UTC est une métadonnée séparée. Les timestamps HAL sont convertis avec la timebase hôte ; aucune différence de `Date()` ne sert à aligner des mots. Chaque époque de device stocke son ancrage hôte, sample rate, latence et position session. Rééchantillonnage continu avec état de filtre conservé entre tranches.

Une tranche centrale dure 300 s, soit 4 800 000 frames à 16 kHz, sauf arrêt, lacune ou changement de format. Les pistes partagent les mêmes bornes temporelles. Un buffer qui traverse une borne est scindé. L'écart résiduel entre pistes est mesuré, pas supposé nul parce que l'aggregate existe.

Écrire un journal de tranche atomique avec ID, piste, époque et ancrage temporel avant les premières frames. Écrire `000001.caf.partial`, fermer, synchroniser, renommer `000001.caf`, synchroniser le dossier, puis enregistrer hash, frames et bornes dans SQLite. Le CLI ignore les `.partial`. Un manifeste JSON atomique par session rend les fichiers fermés récupérables sans la DB. Il porte les pistes, époques, chunks et lacunes, sans vecteurs.

Débranchement : stopper l'ancien IOProc, vider le ring, fermer les tranches, détruire aggregate puis tap. Recréer le graphe avec la nouvelle route. Garder l'origine de session. Inscrire un `gap` pour le temps absent. La piste système ne devient jamais une piste micro par changement d'ordre des canaux. Pas de pause/reprise utilisateur en v1 ; arrêt puis nouvelle session. Veille système : fermer la session avec motif `sleep`, ne pas redémarrer silencieusement au réveil.

## 5. Flux de bout en bout

| Étape | Entrée | Sortie durable / règle de reprise |
|---|---|---|
| Création | Action explicite, calendrier facultatif | `recordings`, snapshot calendrier, notes vides ; exclusion sensible vérifiée avant capture |
| Capture | IOProc | CAF fermés + manifest ; le crash du worker ML n'affecte pas l'app |
| ASR progressive | Chunks fermés par piste | Cache de mots finalisés, clé par hash audio + locale + modèle + paramètres |
| Fermeture | Stop ou récupération crash | Manifest scellé avec durée et lacunes ; ASR de la dernière tranche |
| Écho | Deux pistes complètes sur la même timeline | Masques `echo_only`, `double_talk`, `uncertain` ; aucune suppression des CAF |
| Diarisation | Chaque piste complète | Clusters et tours anonymes ; pas de diarisation indépendante par chunk |
| Alignement | Mots + tours + masques | Segments, provenance, zones incertaines ; stage déterministe |
| Identité | Clusters + embeddings + consentements | J4 : `disabled`, Speaker N ; J5 : propositions et confirmations séparées |
| Commit | Résultat candidat complet | Nouvelle version de transcript et pointeur courant dans une transaction |
| Summary facultatif | Version précise du transcript | Version de summary ou erreur isolée ; jamais bloquant pour transcript/export |
| Export | Snapshot cohérent | Génération publiée puis événement d'index ; retry indépendant |
| Rétention | Deadline + absence de lecteur/pipeline actif | Suppression des sources et fichiers temporaires audio |

`hwyd-pipeline run --id UUID` traite une session scellée ; ajouter `--follow` pendant la capture. `hwyd-pipeline migrate` et `hwyd-pipeline maintain` sont des modes séparés sous les mêmes verrous. Codes de sortie : 0 succès, 2 arguments, 3 store/schéma, 4 conflit de verrou, 5 dépendance manquante, 6 échec de traitement, 130 annulation. `SIGTERM` demande arrêt coopératif et laisse les caches scellés récupérables.

`--follow` consomme les chunks fermés tant que la capture existe, puis finalise après son scellement. Un `--run` sans suivi traite un manifest déjà fermé. Un processus logique par session peut être relancé après crash. Un verrou global d'inférence évite deux sessions lourdes en parallèle. Le worker d'une ancienne session cède ce verrou entre étapes si une capture active attend son ASR. Aucun modèle lourd ne reste chargé pendant cette attente.

ASR : tranche centrale de 5 min avec 1 s de contexte gauche/droite. La tranche attend le chunk suivant pour son contexte droit ; la dernière est traitée à l'arrêt. Garder les mots dont le milieu appartient à la tranche centrale. Dédupliquer les frontières par texte normalisé et recouvrement temporel ; conflit conservé avec un drapeau. Le contexte et la version de cette règle entrent dans la clé du cache.

Speech accepte le format annoncé par `bestAvailableAudioFormat` ; convertir depuis 16 kHz si nécessaire. Demander les attributs temporels, consommer les résultats finaux, puis les traduire en mots HWYD. Une plage couvrant plusieurs mots n'est pas un timestamp par mot : conserver `timing_quality: coarse`, puis appliquer le repli du spike 1. Les ASR ne reçoivent jamais d'audio du micro en direct.

Pour la diarisation, matérialiser par piste un CAF de travail complet, en streaming depuis les chunks. Insérer du silence aux lacunes pour préserver les temps. Masquer uniquement l'écho certain avant segmentation micro ; conserver le masque et le hash de transformation. Le fichier complet est éphémère et soumis à la même purge que les sources. Traiter les pistes séquentiellement. Les clusters restent qualifiés par piste.

Alignement : pour chaque mot, choisir le tour de même piste maximisant l'intersection. Si intersection nulle, `speaker_id: null`. En cas d'égalité, choisir le tour dont le milieu est le plus proche, puis l'ID lexical ; signaler l'ambiguïté. Scinder aux changements de speaker, lacunes et pistes. Absorber un tour de durée < 0,5 s ou de moins de 2 mots vers le voisin de même piste ayant le meilleur recouvrement cumulé. Ne pas traverser une lacune ni absorber une réponse isolée sans voisin compatible. Conserver l'attribution brute et la règle appliquée pour audit. Les chevauchements entre pistes restent représentables ; ne pas forcer une conversation globale exclusive.

Le défaut de diarisation reste community-1. Nemotron 3, Pyannote 3.1 et WHO restent des adaptateurs candidats derrière le même protocole, selon le banc et leurs licences. Un graphe de diarisation peut contenir plusieurs sous-modèles : « un modèle à la fois » signifie ici **un moteur lourd à la fois**, sans ASR ou LLM concurrent.

### Identité préparée pour J5

Le système est `remote`. Le micro est `room` par défaut. `near` est réservé à une source ou un cluster explicitement validé comme voix proche de l'utilisateur. Ne pas transformer toute la salle en `near`.

Normaliser les vecteurs ; ne comparer que le même `embedding_space_id`. Score acoustique = moyenne des `min(3,n)` meilleurs cosinus de la catégorie. Croisement de catégories désactivé avant calibration, puis seuil distinct plus strict. Le calendrier apporte un bonus plafonné à 0,03 pour classer les candidats. Il ne permet jamais de franchir le seuil acoustique ni la marge acoustique minimale de 0,10. Les seuils absolus sont issus du spike 3 ; avant calibration, abstention automatique. Avec un seul candidat, marge null et seul le seuil absolu calibré est applicable ; ne pas fabriquer un score de deuxième candidat.

L'affectation hongroise comporte une colonne d'abstention par cluster. Éliminer les arêtes hors seuil/marge avant optimisation. Interdire d'imposer le deuxième candidat après collision. Par défaut, injectivité **par piste** ; une personne peut exister sur micro et système. Réunir des fragments d'une même voix seulement après contrôle de non-chevauchement et confirmation. Les corrections humaines priment sur tout retraitement ; les conflits de remapping sont présentés comme tels.

### Fournisseurs LLM et calendrier

J4 injecte `DisabledLLMProvider`. Plus tard, chaque backend expose contexte effectif, tokenizer, support du schema et limite de sortie. Fenêtres par tours avec recouvrement 10 %, budget de sortie réservé et marge 10 %. Une première passe extrait faits et IDs de segments ; la réduction déduplique les faits sans changer leurs sources. Valider schema, références et attributions ; une réparation maximum, puis erreur isolée. Provenance : backend, endpoint expurgé, modèle et révision, hash/version prompt, schema, paramètres, versions transcript/notes et date. Une réponse n'est pas fiable parce qu'elle est du JSON.

L'endpoint local est limité par défaut à loopback. Une URL non locale exige l'opt-in de sortie des données, y compris sur le LAN. Redirections vers un autre hôte refusées. Les secrets API sont dans le trousseau, jamais dans settings ou argv. Les adapters OpenAI-compatible et Anthropic restent distincts. Aucun fallback cloud automatique.

EventKit reste dans l'app, confiné à un adaptateur. Pour J4, choisir manuellement un événement parmi ceux chevauchant la session ; sans choix, calendrier null. Copier les valeurs dans un snapshot Sendable avant envoi au store. Extraire uniquement les `mailto:` valides des URL de participants ; noms et emails peuvent manquer. Liens candidats depuis URL, location et notes, dédupliqués ; pièces jointes non vérifiées laissées vides. Ne pas déduire qu'un invité est présent. Les mots-clés sensibles empêchent le démarrage automatique proposé et demandent une dérogation explicite avant capture contextualisée.

## 6. Processus, acteurs et verrous

| Propriétaire | Travail | Accès |
|---|---|---|
| App | Capture, calendrier, notes, supervision, configuration | DB lecture/écriture ; permissions TCC ; trousseau |
| `hwyd-pipeline` | Traitement d'une session, export, maintenance explicite | DB lecture/écriture ; fichiers fermés ; trousseau si identité/chiffrement |
| `hwyd-mcp` | Lecture sans app, modifications autorisées | DB lecture seule par défaut ; aucune lecture du trousseau biométrique |

L'app lance `Process` avec URL du binaire embarqué et arguments séparés, jamais via shell. Aucun transcript ou secret dans argv. stdout du pipeline : événements JSONL de progression, stderr : diagnostics sans contenu sensible. SQLite reste l'autorité si les pipes cassent. MCP réserve stdout au protocole. Le parent draine les deux pipes pour éviter un deadlock.

| Synchronisation | Contrat |
|---|---|
| `CaptureActor` | Sérialise démarrage, arrêt et changements de route ; pas le callback temps réel |
| `PipelineActor` | Ordonne les étapes ; adaptateurs SDK confinés dans leur actor ; pas de partage forcé par `@unchecked Sendable` |
| `StoreActor` | Une façade par processus, `DatabasePool` GRDB ; les actors ne synchronisent pas les autres processus |
| SQLite | WAL, foreign keys ON sur chaque connexion, busy timeout 5 s, transactions courtes ; aucune inférence dans une transaction |
| `schema.lock` | Verrou partagé durant la vie des connexions ; exclusif pour migration, avant ouverture de la DB |
| `capture.lock` | Exclusif pendant la capture ; jamais hérité par un enfant (`CLOEXEC`) |
| `session-<id>.lock` | Un worker par session ; les mutations DB courtes restent possibles |
| `inference.lock` | Exclusif pendant une étape lourde ; libéré avant attente de chunk |
| `audio-<id>.lock` | Partagé par lecteurs audio/capture, exclusif par purge ; la purge ne peut supprimer un fichier ouvert par le pipeline |
| `export.lock` | Sérialise publication et index pour une racine d'export |

Ordre si plusieurs verrous : schema, session, audio, inference, export. Ne jamais attendre un verrou de fichier avec une transaction SQLite ouverte. La purge n'acquiert pas session après audio. Les fichiers de lock sont stables, jamais remplacés ou supprimés : c'est le verrou noyau qui fait foi, pas un PID dans un fichier.

Jobs : lease DB avec `owner_token`, `generation`, heartbeat toutes les 5 s, expiration à 30 s. Une reprise exige l'expiration **et** l'acquisition du verrou noyau correspondant. Chaque commit vérifie la génération pour rejeter un ancien worker. Une mise à jour concurrente des notes incrémente la révision session ; le résultat ML est rebasé sur les notes courantes, mais refuse d'écraser un transcript corrigé depuis son départ.

## 7. Permissions et distribution

| Fonction | Déclaration / démarche | Refus |
|---|---|---|
| Micro | `NSMicrophoneUsageDescription`, entitlement Hardened Runtime `com.apple.security.device.audio-input` | Pas de capture micro ; action explicite pour système seul |
| Tap système | `NSAudioCaptureUsageDescription` ; création du tap après action utilisateur | Pas de capture système ; proposer micro seul explicitement |
| Calendrier | `NSCalendarsFullAccessUsageDescription`, `requestFullAccessToEvents` | Session ad hoc possible ; pas de participants inventés |
| Notifications | `UNUserNotificationCenter` | Capture manuelle et notepad accessibles dans l'app |
| Automation | `NSAppleEventsUsageDescription`, `com.apple.security.automation.apple-events` si fonctionnalité activée | Détection par process seulement |
| Contacts | Hors J4 ; `NSContactsUsageDescription` si résolution enrichie activée | Garder `mailto` ou nom EventKit |
| Speech | Vérifier disponibilité et assets, pas de fallback réseau implicite | Parakeet local ou état `blocked` |
| Trousseau | Items locaux non synchronisés, accès par binaires signés autorisés | Identité suspendue ; transcript anonyme possible |

Distribution Developer ID avec Hardened Runtime, **sans App Sandbox en v1**. Pas d'entitlement privé TCC, pas de permission écran, pas d'Accessibility pour le simple raccourci global. `kTCCServiceAudioCapture` décrit le service, ce n'est pas une API publique à appeler. Les entitlements sandbox calendrier ne sont pas ajoutés comme substituts au consentement TCC. Signature stable dès le spike pour tester les permissions réelles. Signer les helpers avant le bundle, puis notariser. Sparkle et Login Item viennent au packaging ; aucun helper de login ne démarre une capture.

Le besoin précis d'une autorisation Speech pour `SpeechAnalyzer` exécuté dans le helper doit être testé sur macOS 26 signé. Ne pas copier sans preuve le contrat `SFSpeechRecognizer`, ni inventer une API `requestAuthorization` sur `SpeechTranscriber`. Le spike 1 couvre aussi l'attribution TCC app/helper ; si elle bloque, J4 utilise Parakeet. [Accès EventKit documenté par Apple](https://developer.apple.com/documentation/eventkit/accessing-the-event-store).

## 8. Erreurs, crash et reprise

| État de capture | Transition permise |
|---|---|
| `preparing` | `recording`, `failed` |
| `recording` | `finalizing`, `interrupted` |
| `finalizing` | `sealed`, `interrupted` |
| `interrupted` | `sealed` après récupération, ou `failed` si aucun audio valide |
| `sealed`, `failed` | Terminal ; retraitement dans un nouveau run, sans relancer la capture |

Le pipeline a ses propres états `queued`, `running`, `blocked`, `failed`, `complete`, `cancelled`. Summary et export ont chacun leur statut. Une panne LLM ne remet pas le transcript en échec.

Au lancement, vérifier les locks avant toute récupération. Pour une capture orpheline : scanner les CAF fermés, vérifier taille/frames/hash, réconcilier ceux renommés avant le commit DB. Ouvrir chaque `.partial` via AudioToolbox. Si lisible, copier les frames récupérables dans un nouveau CAF, fermer et sceller ; sinon le mettre en quarantaine puis marquer la lacune. **CAF ne garantit pas zéro perte en cas de crash**. Borne de perte cible : la tranche active, 5 min maximum ; les tranches scellées restent valides.

| Erreur | Comportement |
|---|---|
| Disque plein / ring saturé | Fermer proprement si possible, signal visible, lacune persistée ; ne pas continuer en silence |
| Modèle absent, locale absente | `blocked`, proposer téléchargement ou repli local ; pas de téléchargement implicite en capture |
| Crash / OOM du CLI | Retry après backoff 5, 30, 120 s, maximum 3 ; reprendre les étapes cache-valides ; capture intacte |
| SQLite occupée | Retry borné ; préserver fichier fermé et journal pour réconciliation |
| Corruption DB | Stopper écritures ; copie de sauvegarde SQLite cohérente ; reconstruction des médias depuis manifests, sans prétendre récupérer des notes absentes de sauvegarde |
| Export indisponible | Outbox durable, état `pending`, transcript consultable dans l'app/MCP |
| Annulation / suppression audio | Invalider le run, empêcher commit tardif, libérer les lecteurs puis purger |

Les erreurs transportent `code`, `stage`, `retryable`, `recording_id`, diagnostic expurgé. Logs : durées, tailles et codes ; ni parole, ni noms, ni vecteurs. Les dumps de debug avec audio sont opt-in.

## 9. Critères de livraison

| Jalon | Preuve requise |
|---|---|
| J1 | Meet, Gather, Huddle, salle, AirPods, changement entrée/sortie ; 2 h continues ; dérive différentielle < 20 ms/h sur signaux de référence ; aucun chunk scellé corrompu après kill forcé |
| J1 | Refus TCC, disque plein, veille et route disparue ; lacunes explicites ; pas de blocage UI ni IOProc |
| J4 | Depuis CAF et snapshot calendrier : ASR par piste, diarisation complète, alignement par mot, Speaker N, notes et export schema 1 ; sans réseau après préparation des modèles |
| J4 | Kill après chaque frontière fichier/DB/export ; relance sans doublon de version ni corruption ; conflit avec correction humaine détecté |
| J4 | Aucun vecteur en SQLite, JSON, Markdown, stdout MCP ou logs ; repli ASR et absence de calendrier couverts |

## 10. Vérifiabilité des APIs

| Élément | Preuve consultée | Limite |
|---|---|---|
| Tap / aggregate / propriétés process | Headers CoreAudio SDK local 27.0 + sample Apple cité | J1 doit prouver le comportement sur 26 et les périphériques réels |
| Speech timestamps / locales | `Speech.swiftinterface` local : `audioTimeRange`, `supportedLocales`, `isAvailable`, `results` ; [documentation Speech](https://developer.apple.com/documentation/speech) | Aucun résultat d'exécution `fr-FR` ; granularité par mot non garantie ici |
| Diarisation FluidAudio | [source v0.17.7](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift) | La signature publique exacte d'`embedSpans` n'est pas validée ici ; ne pas la supposer sur le manager offline |
| Embedder | Contrat HWYD indépendant | Vérifier l'API publique `extractEmbedding`/extracteur dans le tag ; sinon adaptateur CoreML WeSpeaker dédié, sans accès à un symbole interne |
| MCP | Source 0.12.1, transports serveur présents | Le spike 5 teste l'intégration réseau ; stdio suffit en v1 |

## 11. Revue critique et amendements proposés

Ces propositions ne modifient pas `architecture.md`. Le design ci-dessus précise les comportements conservateurs nécessaires pour J1/J4.

| Passage | Désaccord / risque | Amendement proposé |
|---|---|---|
| §2 « deux process » | Le serveur MCP en ajoute un troisième | Distinguer trois exécutables et plusieurs instances MCP |
| §2/§9 rétention 7 à 30 jours | Contredit les 72 h de §11 | Rendre 72 h normatif partout, avec purge différée explicite |
| §7 fichiers « source de vérité » | Plusieurs writers MCP/UI et versions rendent une autorité double incohérente | SQLite autorité interne, exports contrat public ; notes éditées dans l'app/MCP en v1 |
| §7 rename atomique | Un rename par fichier ne publie pas un couple MD/JSON atomiquement | Générations immuables + index de commit ; fichiers plats comme vues de confort |
| §7 index append-only « une ligne par session » | Ne représente ni corrections ni suppressions | Journal d'événements par révision, réduction par ID, tombstones |
| §5 injectivité globale | Une même personne peut apparaître sur deux pistes ou être fragmentée | Affectation par piste, abstention, fusion contrôlée ; jamais deuxième choix forcé |
| §4 invités + 2 | Peut plafonner les intervenants hors calendrier | Traiter le nombre comme hint souple ; détecter saturation et relancer sans ce plafond |
| §5 inconnu persistant et §9 consentement | Un pseudonyme ne rend pas son empreinte non biométrique | Persistance et réidentification uniquement si consentement attaché au sujet, même non nommé ; sinon ID local |
| §5 correction = enrôlement | Nommer n'établit pas le consentement et peut contaminer la base | Correction textuelle séparée de l'ajout d'empreintes ; aucun auto-enrôlement par MCP |
| §3 CAF récupérable | Le format seul ne prouve pas la récupération après kill | Protocole de scellement, manifest et tests de troncature |
| §4 « un modèle chargé » | Un diarizer contient plusieurs sous-modèles | Un moteur lourd à la fois, budget mémoire mesuré |
| §12 32k couvre une heure | Dépend du débit, langue, tokenizer et budget de sortie | Toujours compter les tokens et fenêtrer selon le contexte effectif |
| §6 URL active | Un onglet actif ne permet pas d'identifier toutes les réunions en arrière-plan | Signal positif opportuniste ; absence d'URL jamais preuve de fin |
| §6 arrêt à 60 s | Mute et silence peuvent interrompre une session utile | Suggestion d'arrêt seulement jusqu'au résultat du spike 4 |
| §6 pièces jointes EventKit | API publique de lecture des pièces jointes non vérifiée | Exporter seulement les métadonnées effectivement accessibles ; champ attachments vide, capacité `unavailable` |
| §13 HTTP inconnu | Le tag MCP 0.12.1 possède deux transports serveur HTTP | Actualiser l'inventaire ; garder le test d'interopérabilité ouvert |
| §9 / jalon 7 chiffrement | Les corpus réels arrivent avant le jalon 7 | J1/J4 utilisent des données de test consenties sur volume chiffré ; chiffrement applicatif avant collecte sensible ; ne pas présenter un CAF brut comme chiffré |
| §9 consentement professionnel | L'implémentation ne démontre pas la validité juridique d'un consentement | Conserver le contrôle DPO prévu ; ce design décrit une barrière technique, pas une validation juridique |
