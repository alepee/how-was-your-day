# Modèle de données HWYD

Version interne SQLite : migrations nommées, indépendante de `hwyd_schema: 1`. Référence : [design technique](technical-design.md). J4 crée le schéma complet mais laisse les tables biométriques vides.

## 1. Conventions

| Convention | Valeur |
|---|---|
| Identifiants | UUID minuscules en TEXT ; IDs publics inconnus `speaker-<uuid>` ; libellé court distinct |
| Temps civil | INTEGER, microsecondes Unix UTC ; export RFC 3339 UTC |
| Temps audio | INTEGER, microsecondes depuis origine session ; `0 <= start_us < end_us` |
| Booléens | INTEGER `CHECK IN (0,1)` |
| JSON | TEXT avec `CHECK(json_valid(column))` ; objets typés et validés avant insertion |
| Révisions | Entiers croissants par session ; versions transcript/notes/summary indépendantes |
| Chemins | Relatifs à la racine interne, validés contre traversée et liens symboliques |
| Vecteurs | Jamais en SQLite, même temporaires ; références opaques vers le trousseau |
| Suppression | Foreign keys ON ; cascades explicites uniquement pour données appartenant à une session |

Dossier interne privé, permissions 0700 ; fichiers 0600. SQLite en WAL, `synchronous=FULL`, busy timeout 5 s. Un `DatabasePool` GRDB par processus, transactions courtes. `ValueObservation` local ne constitue pas un bus interprocessus : surveiller `change_log.seq` et rafraîchir périodiquement l'UI. Voir [GRDB](https://github.com/groue/GRDB.swift) pour les primitives de pool et migration.

## 2. Schéma relationnel normatif

Notation : `PK`, `FK`, `UQ`, `?` nullable. Toute FK porte un index si elle ne commence pas déjà une PK ou un index unique. Les champs non marqués `?` sont NOT NULL. Les enums sont des TEXT avec CHECK, jamais des ordinals Swift.

| Table | Colonnes | Contraintes et rôle |
|---|---|---|
| `recordings` | `id TEXT PK`, `kind TEXT`, `title TEXT`, `started_at_us INTEGER`, `ended_at_us INTEGER?`, `timezone TEXT`, `duration_us INTEGER?`, `capture_state TEXT`, `stop_reason TEXT?`, `revision INTEGER DEFAULT 0`, `current_transcript_id TEXT?`, `current_notes_id TEXT?`, `current_summary_id TEXT?`, `calendar_id TEXT?`, `app TEXT`, `consent_announced INTEGER`, `retention_hours INTEGER DEFAULT 72`, `audio_state TEXT`, `audio_expires_at_us INTEGER?`, `deleted_at_us INTEGER?` | Kind = meeting/call/conversation/voice-memo/ad-hoc ; états du design ; retention >= 0 ; pointeurs FK vers versions et snapshot, même session vérifiée par trigger |
| `recording_revisions` | `recording_id TEXT FK`, `revision INTEGER`, `snapshot_json TEXT`, `created_at_us INTEGER` | PK(recording_id,revision) ; projection publique sans vecteurs, métadonnées et IDs des versions ; permet lecture historique et export exact après crash |
| `calendar_snapshots` | `id TEXT PK`, `recording_id TEXT FK`, `provider TEXT`, `event_identifier TEXT?`, `calendar_identifier TEXT?`, `title TEXT?`, `description TEXT?`, `location TEXT?`, `url TEXT?`, `starts_at_us INTEGER?`, `ends_at_us INTEGER?`, `participants_json TEXT`, `links_json TEXT`, `attachments_json TEXT`, `attachments_status TEXT`, `captured_at_us INTEGER` | Snapshot immuable ; provider `eventkit` en v1 ; pas de FK vers EventKit ; modification calendrier ne réécrit pas l'historique |
| `tracks` | `id TEXT PK`, `recording_id TEXT FK`, `source TEXT`, `default_channel TEXT`, `sample_rate INTEGER DEFAULT 16000`, `channels INTEGER DEFAULT 1` | UQ(recording_id, source), source mic/system ; canal near/room/remote |
| `capture_epochs` | `id TEXT PK`, `recording_id TEXT FK`, `start_us INTEGER`, `end_us INTEGER?`, `host_anchor TEXT`, `sample_anchor INTEGER`, `device_config_json TEXT`, `latency_us INTEGER` | Configuration des UID, streams, rates et compensation ; host anchor UInt64 encodé en décimal |
| `audio_chunks` | `id TEXT PK`, `track_id TEXT FK`, `epoch_id TEXT FK`, `sequence INTEGER`, `start_us INTEGER`, `end_us INTEGER`, `frame_count INTEGER`, `relative_path TEXT`, `sha256 TEXT`, `state TEXT`, `sealed_at_us INTEGER`, `crypto_key_ref TEXT?`, `crypto_version INTEGER?` | UQ(track_id,sequence) ; state sealed/purging/purged/quarantined ; pas de ligne durable pour un fichier encore ouvert |
| `audio_gaps` | `id TEXT PK`, `track_id TEXT FK`, `start_us INTEGER`, `end_us INTEGER`, `reason TEXT` | device_change/overflow/crash/sleep/source_unavailable ; ne pas assimiler lacune et silence |
| `pipeline_runs` | `id TEXT PK`, `recording_id TEXT FK`, `base_transcript_id TEXT?`, `state TEXT`, `config_json TEXT`, `config_hash TEXT`, `started_at_us INTEGER`, `finished_at_us INTEGER?`, `error_json TEXT?` | Config inclut versions poids, SDK, paramètres, locale et règles d'alignement ; aucune donnée vectorielle |
| `stage_jobs` | `id TEXT PK`, `run_id TEXT FK`, `stage TEXT`, `scope TEXT`, `input_hash TEXT`, `status TEXT`, `owner_token TEXT?`, `generation INTEGER`, `lease_until_us INTEGER?`, `heartbeat_at_us INTEGER?`, `attempt INTEGER`, `result_path TEXT?`, `result_hash TEXT?`, `error_json TEXT?` | UQ(run_id,stage,scope,input_hash) ; scope chunk/piste/session ; commit conditionné par owner+generation |
| `transcript_versions` | `id TEXT PK`, `recording_id TEXT FK`, `version INTEGER`, `parent_id TEXT? FK`, `run_id TEXT? FK`, `reason TEXT`, `created_at_us INTEGER`, `locale TEXT`, `provenance_json TEXT`, `redacted_at_us INTEGER?` | UQ(recording_id,version), reason initial/correction/reprocess/redaction ; immuable sauf procédure d'effacement |
| `speaker_clusters` | `id TEXT PK`, `transcript_id TEXT FK`, `track_id TEXT FK`, `local_label TEXT`, `channel TEXT`, `clean_speech_us INTEGER`, `status TEXT` | UQ(transcript_id,track_id,local_label) ; status anonymous/proposed/confirmed/opposed ; cluster scoped à une version |
| `speaker_turns` | `id TEXT PK`, `transcript_id TEXT FK`, `cluster_id TEXT FK`, `start_us INTEGER`, `end_us INTEGER`, `overlap INTEGER`, `confidence REAL?` | Tours bruts conservés ; aucune confiance fabriquée si le moteur n'en fournit pas |
| `words` | `id TEXT PK`, `transcript_id TEXT FK`, `track_id TEXT FK`, `ordinal INTEGER`, `start_us INTEGER`, `end_us INTEGER`, `text TEXT`, `confidence REAL?`, `timing_quality TEXT`, `raw_cluster_id TEXT? FK`, `cluster_id TEXT? FK`, `flags_json TEXT` | UQ(transcript_id,track_id,ordinal) ; timing word/coarse ; deux attributions avant/après absorption |
| `segments` | `id TEXT PK`, `transcript_id TEXT FK`, `track_id TEXT FK`, `cluster_id TEXT? FK`, `ordinal INTEGER`, `start_us INTEGER`, `end_us INTEGER`, `text TEXT`, `confidence REAL?`, `flags_json TEXT` | UQ(transcript_id,ordinal), ordre start, source, ID ; chevauchements inter-pistes autorisés |
| `segment_words` | `segment_id TEXT FK`, `word_id TEXT FK`, `position INTEGER` | PK(segment_id,position), UQ(word_id), même version/piste imposée |
| `echo_regions` | `id TEXT PK`, `run_id TEXT FK`, `start_us INTEGER`, `end_us INTEGER`, `classification TEXT`, `correlation REAL?`, `delay_us INTEGER?`, `policy_version TEXT` | echo_only/double_talk/uncertain ; pas une identité de speaker |
| `persons` | `id TEXT PK`, `display_name TEXT?`, `alias TEXT?`, `is_self INTEGER`, `identity_state TEXT`, `created_at_us INTEGER`, `last_seen_at_us INTEGER?`, `erased_at_us INTEGER?` | named/unnamed/opposed/erased ; UUID stable ; alias opaque ; display_name non requis pour sujet consenti non nommé |
| `consents` | `id TEXT PK`, `person_id TEXT FK`, `purpose TEXT`, `status TEXT`, `recorded_at_us INTEGER`, `expires_at_us INTEGER?`, `evidence TEXT?`, `revoked_at_us INTEGER?` | purpose voice_identification ; status granted/revoked/expired ; événement d'annonce distinct de ce consentement |
| `oppositions` | `person_id TEXT PK FK`, `created_at_us INTEGER`, `reason TEXT?` | Interdit enrôlement et matching ; ne contient aucun vecteur de reconnaissance d'opposant |
| `cluster_assignments` | `cluster_id TEXT PK FK`, `person_id TEXT? FK`, `state TEXT`, `acoustic_score REAL?`, `adjusted_score REAL?`, `margin REAL?`, `threshold REAL?`, `method TEXT`, `policy_version TEXT`, `confirmed_at_us INTEGER?` | anonymous/proposed/confirmed/opposed ; confirmed exige un acte humain, pas uniquement un seuil |
| `identity_candidates` | `cluster_id TEXT FK`, `person_id TEXT FK`, `rank INTEGER`, `acoustic_score REAL`, `calendar_bonus REAL`, `cross_channel INTEGER` | PK(cluster_id,person_id) ; diagnostic interne ; export limité selon output-format |
| `voice_exemplars` | `id TEXT PK`, `person_id TEXT FK`, `consent_id TEXT FK`, `channel TEXT`, `embedding_space_id TEXT`, `keychain_ref TEXT UQ`, `source_recording_id TEXT? FK`, `source_cluster_id TEXT? FK`, `clean_speech_us INTEGER`, `quality REAL?`, `created_at_us INTEGER`, `last_matched_at_us INTEGER?`, `expires_at_us INTEGER?`, `state TEXT` | channel near/room/remote ; state pending/active/deleting ; pas de BLOB ; <= 20 actifs par personne/canal/espace, contrôlé dans transaction |
| `keychain_operations` | `id TEXT PK`, `exemplar_id TEXT? FK`, `keychain_ref TEXT`, `operation TEXT`, `state TEXT`, `created_at_us INTEGER`, `error_code TEXT?` | Journal récupérable create/delete, sans secret |
| `note_versions` | `id TEXT PK`, `recording_id TEXT FK`, `version INTEGER`, `markdown TEXT`, `entries_json TEXT`, `created_at_us INTEGER`, `origin TEXT` | UQ(recording_id,version) ; entries contient id, offset nullable, texte ; copie complète à chaque sauvegarde |
| `summary_versions` | `id TEXT PK`, `recording_id TEXT FK`, `version INTEGER`, `transcript_id TEXT FK`, `notes_id TEXT? FK`, `status TEXT`, `markdown TEXT?`, `structured_json TEXT?`, `provenance_json TEXT`, `created_at_us INTEGER` | UQ(recording_id,version), status ready/failed/stale ; provenance contient fournisseur/modèle/révision prompt/hash/schema/options |
| `mutation_requests` | `request_id TEXT PK`, `recording_id TEXT FK`, `payload_hash TEXT`, `receipt_json TEXT`, `created_at_us INTEGER` | Idempotence durable ; même ID avec payload différent = conflit |
| `export_outbox` | `recording_id TEXT FK`, `revision INTEGER`, `operation TEXT`, `state TEXT`, `generation_path TEXT?`, `event_id TEXT UQ`, `index_seq INTEGER?`, `error_json TEXT?` | PK(recording_id,revision), upsert/delete ; état pending/published |
| `change_log` | `seq INTEGER PK AUTOINCREMENT`, `recording_id TEXT? FK`, `revision INTEGER?`, `kind TEXT`, `created_at_us INTEGER` | Notification interprocessus, sans contenu privé |
| `settings` | `key TEXT PK`, `value_json TEXT`, `revision INTEGER` | Politique MCP, rétention, export ; aucune clé API |

Les FK des pointeurs courants sont différables. Insérer d'abord recording, puis notes v1, puis actualiser le pointeur dans la même transaction. Les triggers de cohérence refusent un mot, segment, cluster, pointeur ou attribution provenant d'une autre session/version. Toute transaction qui change le contenu visible incrémente `recordings.revision`, écrit `recording_revisions`, `change_log` et l'outbox. La projection historique n'inclut pas les états secrets ni les chemins privés. L'effacement expurge aussi ces snapshots.

### Index requis

| Index | Usage |
|---|---|
| `recordings(started_at_us DESC,id DESC) WHERE deleted_at_us IS NULL` | Pagination stable par date |
| `recordings(kind,started_at_us DESC,id DESC)` | Filtre type |
| `recordings(audio_expires_at_us) WHERE audio_state='available'` | Maintenance rétention |
| `audio_chunks(track_id,start_us)` | Lecture séquentielle et récupération |
| `stage_jobs(status,lease_until_us)` | Reprise |
| `segments(transcript_id,start_us,ordinal)` | Lecture des versions |
| `cluster_assignments(person_id,state,cluster_id)` | Sessions par personne confirmée |
| `voice_exemplars(person_id,channel,embedding_space_id,state)` | Matching dans l'espace adéquat |
| `voice_exemplars(expires_at_us) WHERE state='active'` | Purge des sujets non nommés |
| `export_outbox(state,recording_id,revision)` | Publication et retry |

## 3. Recherche FTS5

Index des **versions courantes uniquement**. Un document par segment, note complète, summary complet et titre. Des snippets de 200 caractères maximum évitent de renvoyer un transcript entier dans `search`.

```sql
CREATE TABLE search_documents (
    id INTEGER PRIMARY KEY,
    recording_id TEXT NOT NULL REFERENCES recordings(id),
    artifact TEXT NOT NULL CHECK (artifact IN ('title','transcript','summary','notes')),
    entity_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    body TEXT NOT NULL,
    UNIQUE(recording_id, artifact, entity_id)
);
CREATE VIRTUAL TABLE search_fts USING fts5(
    body, content='search_documents', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER search_ai AFTER INSERT ON search_documents BEGIN
    INSERT INTO search_fts(rowid, body) VALUES (new.id, new.body);
END;
CREATE TRIGGER search_ad AFTER DELETE ON search_documents BEGIN
    INSERT INTO search_fts(search_fts, rowid, body)
    VALUES ('delete', old.id, old.body);
END;
CREATE TRIGGER search_au AFTER UPDATE ON search_documents BEGIN
    INSERT INTO search_fts(search_fts, rowid, body)
    VALUES ('delete', old.id, old.body);
    INSERT INTO search_fts(rowid, body) VALUES (new.id, new.body);
END;
CREATE INDEX search_recording ON search_documents(recording_id, artifact);
```

Remplacer les documents d'un artefact dans la transaction qui bascule sa version courante. Un échec annule les deux. Une reconstruction utilise `INSERT INTO search_fts(search_fts) VALUES ('rebuild')`. Test d'intégration : ancien texte absent après correction, nouveau texte trouvable, rollback sans résultat fantôme. L'entrée utilisateur devient des tokens littéraux reliés par AND ; aucune interpolation SQL et aucune syntaxe FTS arbitraire en v1.

## 4. Empreintes et trousseau

| Élément | Contrat |
|---|---|
| Espace | `embedding_space_id = SHA256(model revision + conversion + preprocessing + dimension)` |
| Format secret | Enveloppe versionnée : espace, 256 Float32 little-endian, norme, checksum ; environ 1 Ko par exemplaire |
| Item | Generic password, service `com.hwyd.voice-exemplar.v1`, account UUID d'exemplaire, synchronisation désactivée |
| Accès | App et pipeline signés explicitement autorisés ; MCP exclu ; tester avec session verrouillée et binaire mis à jour |
| Métadonnées | Personne/canal/consentement/source en SQLite ; pas de nom dans le libellé de l'item |
| Mémoire | Chargement borné par batch, pas de cache disque ; libération au terme du moteur ; Swift ne garantit pas l'effacement de toutes les copies mémoire |
| Sélection | Jusqu'à 20 médoïdes réels par personne/canal/espace ; conservation de la diversité, pas moyenne globale des canaux |

Écriture en saga, car SQLite et Security.framework ne partagent pas de transaction. Créer une opération `pending` et une référence unique. Écrire le secret dans le trousseau. Revalider le consentement dans une transaction, puis activer l'exemplaire. Un crash entre ces étapes laisse un item récupérable par sa référence. Si consentement révoqué entre-temps, supprimer l'item et ne pas activer. Le réconciliateur ne supprime que les items du service HWYD connus du journal.

Pour supprimer : marquer `deleting` et rendre immédiatement l'exemplaire inéligible ; supprimer l'item ; supprimer les métadonnées ou conserver une trace sans identité. Une erreur de trousseau reste visible et retentée. Une révocation ne dépend pas du succès physique immédiat pour arrêter le matching.

Un sujet non nommé peut avoir une empreinte seulement avec consentement documenté. Son expiration est `created_at + 45 jours`, sans prolongation implicite lors d'un match. Nommer ce sujet retire l'expiration de ses exemplaires encore valides après vérification du consentement. Sans consentement : clusters locaux, aucune continuité biométrique entre sessions. Un nom manuel n'autorise pas à enrôler.

La liste d'opposition est textuelle. Sans empreinte, elle ne peut pas reconnaître acoustiquement une personne opposée inconnue. Le contexte calendrier ou une correction déclenche l'exclusion ; l'app ne promet pas un filtrage biométrique sans biométrie.

## 5. Versioning et corrections

Une correction crée une copie logique complète du transcript, nouveaux IDs de clusters/segments/mots et parent explicite. Le run d'origine reste traçable. Une correction de cluster ne renomme pas automatiquement une personne dans toutes ses sessions. Le choix « nommer le sujet persistant » est une opération distincte de l'app, avec prévisualisation des sessions concernées.

La propagation dans une session affecte tous les segments du cluster sélectionné. Si l'utilisateur ne veut corriger qu'un segment, l'app doit d'abord scinder le cluster. Les mappings humains sont conservés lors des retraitements par comparaison des plages temporelles ; si l'audio/segmentation change trop, produire un conflit à résoudre, pas une correction silencieuse.

Les notes sont indépendantes du transcript. Les timestamps du notepad sont enregistrés avec la même horloge session. `set_notes` remplace le Markdown libre et conserve les entrées horodatées structurées déjà présentes ; l'édition de ces entrées est faite par l'app. Une suppression explicite d'entrée crée une nouvelle version. Le renderer présente entrées puis Markdown libre sans parser des timestamps depuis du texte arbitraire.

Un summary référence exactement le transcript et les notes utilisés. Changement de ces entrées : statut `stale`, pas de nouvelle requête LLM sans politique opt-in. Un résultat tardif ne devient pas courant si ses entrées ont changé.

## 6. Rétention audio et effacement

`audio_expires_at = ended_at + retention_hours`, défaut 72 h. Pour capture interrompue, fin = dernier instant récupérable. Les statuts audio sont `available`, `purging`, `purged`, `missing`. L'expiration n'est pas une garantie de suppression à l'heure exacte si l'app et ses helpers sont arrêtés.

À chaque lancement app et avant/après un run, maintenance idempotente. L'app ouverte lance aussi un passage horaire. Pas de daemon supplémentaire en v1. Une session non terminée, un pipeline non terminal ou un lecteur audio bloque la purge. Un pipeline `blocked` peut prolonger la conservation : l'UI montre l'échéance dépassée et permet abandon puis suppression. Pas de conservation infinie cachée.

Purge : acquérir le verrou audio exclusif, recontrôler les jobs, marquer `purging`, effacer chunks, concaténations, caches audio et fichiers `.partial`, puis passer `purged`. Un crash reprend les éléments restants. Les caches de mots sans audio peuvent rester ; aucun cache vectoriel disque. Une suppression immédiate explicite annule les jobs et attend leur sortie avant purge. Le transcript reste lisible ; retraiter depuis l'audio devient `AUDIO_UNAVAILABLE`.

Chiffrement applicatif cible : AES-GCM par chunk scellé, clé aléatoire par session dans le trousseau, nonce unique par fichier, enveloppe versionnée. Les CAF de capture et de travail restent provisoirement en clair sur volume chiffré, permissions privées et durée minimale. Ne pas prétendre à un chiffrement applicatif intégral du flux ouvert. Le jalon 7 implémente le wrapper crypto sans modifier `AudioSlice`. J1/J4 doivent signaler `encryption: volume_only`, jamais `application` si non implémenté.

Effacement par personne : blocage immédiat du matching, suppression des exemplaires, anonymisation des attributions de toutes les versions, suppression des candidats et données calendrier identifiantes, invalidation des summaries, reconstruction FTS et republication. Le texte libre peut nommer une personne indépendamment de son attribution : une prévisualisation d'occurrences à expurger est nécessaire ; ne pas promettre une anonymisation sémantique parfaite. Notes et summaries concernés restent bloqués à l'export jusqu'à résolution. Les anciennes générations d'export sont retirées et un événement de redaction est publié. Les copies faites par des agents ou des sauvegardes externes échappent à cette suppression.

Le versioning permanent cède devant un effacement explicite. `secure_delete`, checkpoint WAL et `VACUUM` de maintenance réduisent les restes dans la DB active ; ils ne garantissent pas l'effacement physique SSD/snapshots. Aucun vecteur ne se retrouve dans ces pages.

## 7. Migrations et sauvegardes

| Migration GRDB | Contenu |
|---|---|
| `v001_capture` | Recordings, calendrier, pistes, époques, chunks, gaps, settings |
| `v002_pipeline` | Runs, jobs, transcripts, clusters, turns, words, segments, echo |
| `v003_artifacts` | Notes, summaries, snapshots de révision, outbox, mutations, change log |
| `v004_identity` | Persons, consents, oppositions, assignments, candidates, exemplars, saga trousseau |
| `v005_search` | Documents FTS5, triggers et backfill des versions courantes |

Migrations exécutées par app ou `hwyd-pipeline migrate`, jamais implicitement par MCP. Verrou schema exclusif, sauvegarde SQLite cohérente via API de backup avant migration, puis `DatabaseMigrator` transactionnel. Ne pas copier seulement `.sqlite` pendant un WAL actif. Ne jamais activer l'effacement automatique sur changement de schéma en production.

MCP refuse une base trop ancienne ou trop récente avec `SCHEMA_MISMATCH`. Une app plus ancienne refuse un schéma inconnu. Pas de down migration destructive ; restauration de sauvegarde sous verrou explicite. Les sauvegardes contiennent du texte privé et suivent une politique de rétention documentée dans l'app ; les vecteurs restent dans le trousseau local, donc une restauration sur une autre machine rend les empreintes indisponibles jusqu'à ré-enrôlement.
