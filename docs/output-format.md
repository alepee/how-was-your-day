# Contrat de sortie HWYD, schéma 1

`hwyd_schema: 1` versionne le contrat public, indépendamment du schéma SQLite et des versions de transcript. UTF-8 sans BOM, fins de ligne LF, dates RFC 3339 UTC, durées en microsecondes entières. Un lecteur refuse un major inconnu et ignore les champs additionnels d'un major connu. Aucun changement de sens ou suppression de champ sous le même major.

## 1. Artefacts et chemins

Un enregistrement possède quatre artefacts logiques : audio, transcript, summary facultatif, notes. L'export expose une vue Markdown combinée et un JSON complet. L'audio reste dans le store privé. MCP expose aussi chaque artefact textuel séparément.

| Fichier | Fonction |
|---|---|
| `session-2026-10-23-<slug>-<uuid>.md` | Vue courante lisible, sections Notes / Summary / Transcript |
| Même nom `.json` | Vue courante structurée |
| `.hwyd/generations/<uuid>/<revision>/session.md` | Markdown immuable d'une génération publiée |
| Même dossier `session.json` | JSON cohérent avec ce Markdown |
| Même dossier `manifest.json` | ID, révision, hashes SHA-256 et tailles des deux fichiers |
| `index.jsonl` | Journal public de publication, chemin vers les générations immuables |

Le préfixe neutre `session-` remplace le préfixe d'exemple `meeting-` pour les nouveaux exports. Le slug est fixé lors de la première publication, ASCII lowercase, 60 caractères maximum, sans traversée de chemin. Un renommage de titre ne déplace pas les fichiers. L'UUID complet prévient les collisions. Organisation plate par défaut ; option `YYYY/` selon la date locale de début. L'index reste à la racine et les chemins sont relatifs à cette racine.

## 2. Frontmatter complet

Tous les champs suivants sont présents, avec `null` ou tableau vide si non applicable. Les strings sont encodées par un sérialiseur YAML, jamais concaténées. Un alias wikilink est une string, pas du YAML injecté.

```yaml
---
hwyd_schema: 1
type: Session
id: "123e4567-e89b-42d3-a456-426614174000"
source: "hwyd://session/123e4567-e89b-42d3-a456-426614174000"
revision: 3
transcript_version: 1
notes_version: 2
summary_version: null
date: "2026-10-23"
started_at: "2026-10-23T08:00:00Z"
ended_at: "2026-10-23T08:30:00Z"
timezone: "Europe/Paris"
duration_us: 1800000000
title: "Point produit"
session_kind: meeting
app: meet
status: complete
locale: "fr-FR"
consent_announced: true
participants:
  - id: "123e4567-e89b-42d3-a456-426614174001"
    name: "Camille"
    alias: "[[person-camille]]"
calendar:
  provider: eventkit
  event_id: "opaque-event-id"
  calendar_id: "opaque-calendar-id"
  title: "Point produit"
  description: "Suivi des décisions"
  location: null
  url: "https://meet.google.com/abc-defg-hij"
  starts_at: "2026-10-23T08:00:00Z"
  ends_at: "2026-10-23T08:30:00Z"
  participants:
    - name: "Camille"
      email: null
      response: accepted
  links: ["https://meet.google.com/abc-defg-hij"]
  attachments: []
  attachments_status: unavailable
audio:
  state: available
  retention_hours: 72
  expires_at: "2026-10-26T08:30:00Z"
  encryption: volume_only
summary:
  status: disabled
  provider: null
  model: null
  model_revision: null
  prompt_version: null
  generated_at: null
  transcript_version: null
  notes_version: null
exported_at: "2026-10-23T08:31:00Z"
---
```

| Champ | Sémantique |
|---|---|
| `revision` | Révision globale strictement croissante de la session ; peut augmenter sans changement du transcript |
| `status` | `capturing`, `processing`, `complete`, `partial`, `failed` ; `partial` si lacunes ou traitement incomplet |
| `participants` | Identités humainement confirmées et non opposées seulement ; aucune identité proposée |
| `calendar.participants` | Invités du calendrier, pas preuve de présence ; séparés des personnes identifiées |
| `calendar` | Objet ci-dessus ou null ; `response` accepted/declined/tentative/pending/unknown |
| `app` | meet/gather/slack-huddle/in-person/unknown ; signal de contexte, pas attribution de chaque son |
| `consent_announced` | Déclaration utilisateur d'annonce ; ne signifie pas consentement à l'empreinte |
| `locale` | Locale effective du moteur, ou `multilingual` pour un moteur le déclarant |
| `summary.status` | disabled/pending/ready/failed/stale ; autres champs null si absent |
| `audio.state` | available/purging/purged/missing ; aucun chemin audio public |
| `audio.encryption` | volume_only/application/none ; reflète le mode réel, pas une intention |

`date` est la date civile locale au début, indépendante de tout système de daily notes. Les IDs EventKit sont opaques, non portables. Les URLs ne sont ni ouvertes ni téléchargées automatiquement. Le schéma accepte `calendar: null` et `participants: []` pour un mémo sans contexte.

## 3. Corps Markdown

```markdown
# Point produit

## Notes
- [00:03:10] Vérifier le budget.

Texte libre saisi après la session.

## Summary
Synthèse non activée.

## Transcript
**[00:00:12.000 - 00:00:13.400] Camille (micro)** : Bonjour.
**[00:00:14.000 - 00:00:15.200] Speaker 2 (système)** : Bonjour.
```

Ordre des sections fixe. Horodatages `HH:MM:SS.mmm`, heures non limitées à 23. Notes : entrées horodatées ordonnées par offset puis ID, suivies du Markdown libre. Sans notes, section vide. Summary : texte validé si ready ; sinon courte indication de statut. Un summary stale porte un avertissement et sa version source. Transcript : segments ordonnés par `start_us`, piste puis ID ; libellé confirmé ou Speaker N. Une proposition n'est pas affichée comme nom acquis. Aucun texte arbitraire n'est interprété comme HTML par l'app. Échapper noms/titres dans les marqueurs Markdown ; préserver le Markdown manuel comme contenu utilisateur.

Les fichiers exportés sont des vues gérées par HWYD. Éditer les notes dans l'app ou via MCP. Avant remplacement d'un fichier plat modifié hors HWYD, comparer au dernier hash publié et conserver une copie `.conflict-<timestamp>.md`. Signaler le conflit ; ne pas importer silencieusement le transcript édité ni perdre les notes externes. Les générations référencées par index sont immuables.

## 4. Contrat JSON

Les champs racine du frontmatter sont repris avec les mêmes types. `type` vaut `Session`. Le JSON ajoute les objets suivants. Tous les champs du tableau sont obligatoires sauf mention nullable. Aucune valeur NaN/Inf. Les confiances absentes sont `null`, jamais `0` par défaut.

| Objet / champ | Type | Contraintes |
|---|---|---|
| `tracks` | array | Objets `{id: UUID, source: mic/system, channel: near/room/remote, sample_rate: 16000, channels: 1}` |
| `speakers` | array | Objets ci-dessous ; peut être vide sans parole |
| `speakers[].id` | string | ID du cluster qualifié par version, stable dans cette version |
| `speakers[].label` | string | Speaker N ou nom confirmé ; nom affiché séparé de l'ID |
| `speakers[].track_id` | UUID | Référence une piste |
| `speakers[].channel` | enum | near/room/remote |
| `speakers[].identity` | object | `{status, person_id, persistent_speaker_id, name, alias, proposed_person_id, scores}` |
| `identity.status` | enum | anonymous/proposed/confirmed/opposed |
| `identity.person_id`, `name`, `alias` | string ou null | Non null seulement pour identité confirmée ; alias peut rester null |
| `identity.persistent_speaker_id` | string ou null | `speaker-<uuid>` uniquement pour sujet consenti persistant ; pas pour opposant |
| `identity.proposed_person_id` | UUID ou null | Candidat non confirmé ; son nom peut être obtenu via get_participants si la politique l'autorise |
| `identity.scores` | object ou null | `{acoustic, adjusted, margin, threshold, calendar_bonus, cross_channel, policy_version}` |
| `scores.acoustic` | number | Cosinus moyen dans [-1,1], pas une probabilité |
| `scores.adjusted` | number | score acoustique + bonus, dans [-1,1.03] |
| `scores.margin` | number ou null | Différence avec deuxième candidat acoustique ; null s'il n'existe pas |
| `scores.threshold` | number | Seuil acoustique utilisé |
| `scores.calendar_bonus` | number | [0,0.03] |
| `scores.cross_channel` | boolean | Repli inter-catégories utilisé |
| `scores.policy_version` | string | Politique de calibration |
| `segments` | array | Objets `{id, start_us, end_us, track_id, speaker_id, text, confidence, flags, words}` |
| `segments[].speaker_id` | string ou null | Référence speakers ; null si non aligné |
| `segments[].confidence` | number ou null | [0,1], confiance ASR documentée par provider |
| `segments[].flags` | array de strings | echo_uncertain/overlap/timing_coarse/absorbed_turn/boundary_conflict |
| `segments[].words` | array | `{id, text, start_us, end_us, confidence, timing_quality}` ; timing_quality word/coarse |
| `gaps` | array | `{track_id,start_us,end_us,reason}` |
| `notes` | object | `{version, markdown, entries:[{id,offset_us,text}]}` ; offset null pour note hors capture |
| `summary` | object | Champs frontmatter + `markdown`, `structured`, `schema_version`, `prompt_hash`, `options`, `error_code` ; valeurs null si absent |
| `provenance` | object | `{pipeline_version, run_id, asr, diarizer, echo_policy, alignment_policy, identity_policy}` |
| `asr`, `diarizer` | array | `{track_id, provider, model, model_revision, runtime_version, parameters}` ; pas de chemin interne |

Validation sémantique en plus des types : références existantes, IDs uniques, bornes dans la durée, mots inclus dans leur segment, mots ordonnés, gap strictement positif. Les segments de pistes différentes peuvent se recouvrir. Les scores sont null au jalon 4. Une confirmation manuelle peut conserver le score antérieur à titre d'audit mais reste `method: manual` en provenance interne.

Exemple d'un élément de `speakers` et de son segment, à insérer dans la racine décrite ci-dessus :

```json
{
  "speakers": [{
    "id": "cluster-mic-1",
    "label": "Speaker 1",
    "track_id": "123e4567-e89b-42d3-a456-426614174010",
    "channel": "room",
    "identity": {
      "status": "anonymous", "person_id": null,
      "persistent_speaker_id": null, "name": null, "alias": null,
      "proposed_person_id": null, "scores": null
    }
  }],
  "segments": [{
    "id": "segment-1", "start_us": 12000000, "end_us": 13400000,
    "track_id": "123e4567-e89b-42d3-a456-426614174010",
    "speaker_id": "cluster-mic-1", "text": "Bonjour.",
    "confidence": null, "flags": [],
    "words": [{"id":"word-1", "text":"Bonjour.", "start_us":12000000,
      "end_us":13400000, "confidence":null, "timing_quality":"word"}]
  }]
}
```

Summary structuré, version 1 : `{overview: string, decisions: [{text, evidence_segment_ids}], action_items: [{text, assignee_person_id: UUID|null, due_date: YYYY-MM-DD|null, evidence_segment_ids}]}`. Tous les tableaux sont présents. Les références doivent exister dans la version source. Une attribution ou échéance non explicite reste null. Les sorties LLM invalides ne sont jamais exportées comme ready.

Sont interdits dans tout export : vecteurs, références trousseau, clés API, échantillons vocaux d'enrôlement, chemins privés, preuves textuelles de consentement. Les scores scalaires autorisés ne rendent pas une identité certaine.

## 5. `index.jsonl`

Journal append-only, **un événement par révision publiée**, pas une seule ligne permanente par session. Une ligne = un objet JSON compact + LF. Le consommateur réduit par `id`, conserve la plus grande `revision`, et applique `delete`. Les doublons identiques d'`event_id` sont tolérés après crash.

```json
{"hwyd_schema":1,"event_id":"123e4567-e89b-42d3-a456-426614174099","seq":42,"op":"upsert","id":"123e4567-e89b-42d3-a456-426614174000","revision":3,"date":"2026-10-23","kind":"meeting","title":"Point produit","path":".hwyd/generations/123e4567-e89b-42d3-a456-426614174000/3/session.md","json_path":".hwyd/generations/123e4567-e89b-42d3-a456-426614174000/3/session.json","manifest_path":".hwyd/generations/123e4567-e89b-42d3-a456-426614174000/3/manifest.json","published_at":"2026-10-23T08:31:00Z"}
```

| Champ | Contrat |
|---|---|
| `seq` | Entier strictement croissant par racine, alloué sous `export.lock` |
| `op` | upsert/delete/redact ; redact publie une génération nettoyée et impose d'abandonner les précédentes |
| `event_id` | UUID persisté dans l'outbox avant écriture ; retry garde le même ID |
| `path`, `json_path`, `manifest_path` | Strings relatives sur upsert/redact, null sur delete |
| `date`, `kind`, `title` | Métadonnées courantes ; null sur delete pour minimiser les traces |

En cas de ligne finale sans LF, le lecteur l'ignore et retente plus tard. Une ligne malformée au milieu déclenche une erreur de corruption. Le writer répare uniquement une queue incomplète sous verrou. Les suppressions de données privées peuvent imposer une reconstruction expurgée du journal, exception documentée à append-only. Après reconstruction, nouveau `index_epoch` dans `.hwyd/index-state.json` atomique ; le consommateur redémarre l'énumération, sans réutiliser son offset précédent.

## 6. Publication atomique et reprise

1. Lire un snapshot SQLite transactionnel à révision R. Sérialiser sans maintenir la transaction pendant les écritures disque.
2. Sous `export.lock`, écrire une génération temporaire **sur le volume cible**. Vérifier tailles, syntaxe JSON/YAML et IDs ; écrire le manifest avec hashes.
3. Synchroniser chaque fichier, puis le dossier temporaire. Renommer le dossier vers `<id>/<R>/`, synchroniser son parent. Une génération déjà présente avec mêmes hashes rend le retry idempotent ; des hashes différents sont une erreur.
4. Ajouter l'événement d'index en gérant les écritures partielles, puis synchroniser l'index. C'est le **point de publication** du couple MD/JSON. Le lecteur ouvre les chemins de cette ligne et vérifie le manifest.
5. Mettre à jour chaque fichier plat par temp + rename. Ils peuvent transitoirement porter des révisions différentes : un consommateur qui lit les deux vérifie `revision`, ou utilise l'index.
6. Marquer l'outbox publiée. Un crash avant ce commit peut répéter la même ligne, jamais produire un nouvel `event_id`.

Une génération sans ligne d'index est un orphelin non publié, récupérable par l'outbox. Ne pas effacer une génération publiée tant qu'elle peut servir au versioning, sauf suppression/redaction explicite. Si une nouvelle révision existe pendant l'export, publier R puis la suivante ; ne jamais remplacer les vues plates par une révision inférieure à celle déjà publiée.

Garanties ciblées : volume local APFS. Pour partage réseau ou dossier cloud synchronisé, l'atomicité locale ne prouve pas l'atomicité distante. Le lecteur doit vérifier hashes et retenter ; cette destination n'est pas qualifiée pour J4. Une panne disque ne peut être rendue atomique par un simple rename.

## Synthèse structurée, prompt `summary-v4`

Le même format s'applique actuellement à tous les `session_kind`. Des modèles par type de session restent une possibilité future. Les anciennes synthèses ne sont pas modifiées automatiquement.

| Champ de `structured` | Contenu |
|---|---|
| `overview` | Introduction courte du résumé |
| `key_points` | Points clés : `title`, `text`, `evidence_segment_ids` |
| `decisions` | Choix explicitement actés, avec références |
| `action_items` | Engagements explicites, `assignee_name` facultatif quand identifiable, date explicite seulement |
| `details` | Paragraphes thématiques : `title`, `text`, `evidence_segment_ids` |

`key_points`, `details` et `assignee_name` sont des ajouts facultatifs pour la lecture des anciennes données. Les nouvelles générations demandent les deux tableaux. Le schéma d'export reste `hwyd_schema: 1`. Aucun identifiant de personne n'est inféré par le modèle. `assignee_person_id` reste nul.

Le Markdown contient **Résumé**, ses points clés, **Décisions**, **Étapes suivantes**, puis **Détails** avec un sous-titre par thème. Les sections vides sont omises. La longueur dépend de la matière disponible. Les timestamps de l'interface sont calculés depuis les références aux segments, jamais inventés par le modèle. Cliquer positionne le lecteur ; survoler affiche le passage source. Le JSON conserve ces références.

Les longues sessions sont traitées par fenêtres puis fusionnées deux à deux. Chaque fusion réutilise seulement les références déjà présentes. Les détails sont limités à 16 thèmes ; cette réduction peut perdre des nuances sur une très longue session. Les validations de structure et de références ne prouvent pas la fidélité sémantique. Une relecture reste nécessaire.

Chaque fenêtre comporte une passe narrative et une passe dédiée aux décisions et engagements. Cette séparation évite de laisser les décisions uniquement dans les détails avec les petits modèles. Elle augmente le nombre d'appels au serveur local. `assignee_name` est contraint aux libellés connus et vérifié contre les passages cités ; cette vérification ne prouve pas à elle seule que la personne s'est engagée.
