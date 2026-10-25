# Serveur MCP HWYD

Transport v1 : stdio, exécutable signé `hwyd-mcp`. Lecture directe du store, sans app ouverte. SDK officiel [Swift MCP 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1). Les schémas suivants sont des contrats HWYD, pas des signatures du SDK.

## 1. Démarrage et capacités

```json
{"mcpServers":{"hwyd":{"command":"/Applications/HWYD.app/Contents/Helpers/hwyd-mcp","args":["--read-only"]}}}
```

Par défaut : lecture seule. `--allow-write` est nécessaire mais insuffisant. Il faut aussi `mcp_writes_enabled=true` dans les réglages locaux modifiables par l'app. `--read-only` l'emporte toujours. Aucun outil MCP ne peut activer cette politique. La vérifier dans la transaction de chaque mutation. Ne pas présenter ces règles comme une isolation contre un autre programme du même utilisateur ayant accès direct aux fichiers.

| Capacité | Comportement |
|---|---|
| `tools` | Quatre outils de lecture ; deux outils d'écriture seulement si autorisés ; `listChanged: false` en v1, redémarrage pour mise à jour de la liste |
| `resources` | Trois templates de ressources, lecture textuelle ; pas de subscription ni notification serveur en v1 |
| Versions MCP | Négociation initialize par le SDK ; protocole différent de `hwyd_schema` |
| stdout | JSON-RPC seulement ; stderr pour logs expurgés |
| Store absent | `STORE_NOT_INITIALIZED`, sans création de DB vide |
| Schéma incompatible | `SCHEMA_MISMATCH`, jamais de migration depuis MCP |
| Trousseau | Pas d'accès biométrique ; aucune ressource vecteur ou audio |

`list_recordings`, `search`, `get_recording` utilisent des snapshots de lecture courts. Une opération d'écriture committe dans SQLite et inscrit l'outbox. Après commit, le serveur tente l'export via HWYDExport ; un échec retourne `export_state: pending`, sans annuler la modification. Un lancement ultérieur app/pipeline/MCP en mode écriture reprend cette outbox. MCP en lecture seule ne fait pas de maintenance mutante.

## 2. Schémas JSON

JSON Schema draft 2020-12. Le catalogue ci-dessous contient des `$defs` communs puis, pour chaque outil, `inputSchema` et `outputSchema`. Les `$ref` sont relatifs à ce document JSON. Lors de `tools/list`, le serveur copie les `$defs` dans chaque schéma envoyé afin que chaque schéma soit autonome. Toute propriété non déclarée est refusée dans les entrées.

`RecordingMetadata` est la projection MCP stable de l'enregistrement. `get_recording` renvoie les artefacts comme Markdown, plus les numéros de version. Les détails par mot et les scores sont disponibles dans le JSON exporté ; ils ne sont pas implicites dans une string Markdown.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$defs": {
    "Person": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "format": "uuid"
        },
        "name": {
          "type": [
            "string",
            "null"
          ]
        },
        "alias": {
          "type": [
            "string",
            "null"
          ]
        },
        "status": {
          "type": "string",
          "enum": [
            "named",
            "unnamed"
          ]
        }
      },
      "required": [
        "id",
        "name",
        "alias",
        "status"
      ],
      "additionalProperties": false
    },
    "RecordingMetadata": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "format": "uuid"
        },
        "revision": {
          "type": "integer",
          "minimum": 0
        },
        "title": {
          "type": "string"
        },
        "kind": {
          "type": "string",
          "enum": [
            "meeting",
            "call",
            "conversation",
            "voice-memo",
            "ad-hoc"
          ]
        },
        "started_at": {
          "type": "string",
          "format": "date-time"
        },
        "duration_us": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 0
        },
        "status": {
          "type": "string",
          "enum": [
            "capturing",
            "processing",
            "complete",
            "partial",
            "failed"
          ]
        },
        "participants": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Person"
          }
        }
      },
      "required": [
        "id",
        "revision",
        "title",
        "kind",
        "started_at",
        "duration_us",
        "status",
        "participants"
      ],
      "additionalProperties": false
    },
    "Artifact": {
      "type": "object",
      "properties": {
        "status": {
          "type": "string",
          "enum": [
            "ready",
            "pending",
            "disabled",
            "failed",
            "stale",
            "unavailable"
          ]
        },
        "version": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1
        },
        "markdown": {
          "type": [
            "string",
            "null"
          ]
        }
      },
      "required": [
        "status",
        "version",
        "markdown"
      ],
      "additionalProperties": false
    },
    "MutationReceipt": {
      "type": "object",
      "properties": {
        "request_id": {
          "type": "string",
          "format": "uuid"
        },
        "id": {
          "type": "string",
          "format": "uuid"
        },
        "revision": {
          "type": "integer",
          "minimum": 0
        },
        "export_state": {
          "type": "string",
          "enum": [
            "published",
            "pending"
          ]
        },
        "identity_enrollment": {
          "const": "not_performed"
        }
      },
      "required": [
        "request_id",
        "id",
        "revision",
        "export_state",
        "identity_enrollment"
      ],
      "additionalProperties": false
    }
  },
  "tools": {
    "list_recordings": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "since": {
            "type": "string",
            "format": "date-time"
          },
          "kind": {
            "type": "string",
            "enum": [
              "meeting",
              "call",
              "conversation",
              "voice-memo",
              "ad-hoc"
            ]
          },
          "participant": {
            "type": "string",
            "format": "uuid"
          },
          "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 100,
            "default": 50
          },
          "cursor": {
            "type": "string"
          }
        },
        "required": [],
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "items": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/RecordingMetadata"
            }
          },
          "next_cursor": {
            "type": [
              "string",
              "null"
            ]
          },
          "snapshot_seq": {
            "type": "integer",
            "minimum": 0
          }
        },
        "required": [
          "items",
          "next_cursor",
          "snapshot_seq"
        ],
        "additionalProperties": false
      }
    },
    "get_recording": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "format": "uuid"
          },
          "include": {
            "type": "string",
            "enum": [
              "transcript",
              "summary",
              "notes",
              "all"
            ],
            "default": "all"
          },
          "revision": {
            "type": "integer",
            "minimum": 0
          },
          "cursor": {
            "type": "string"
          },
          "max_chars": {
            "type": "integer",
            "minimum": 1000,
            "maximum": 100000,
            "default": 50000
          }
        },
        "required": [
          "id"
        ],
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "recording": {
            "$ref": "#/$defs/RecordingMetadata"
          },
          "artifacts": {
            "type": "object",
            "properties": {
              "transcript": {
                "$ref": "#/$defs/Artifact"
              },
              "summary": {
                "$ref": "#/$defs/Artifact"
              },
              "notes": {
                "$ref": "#/$defs/Artifact"
              }
            },
            "required": [],
            "additionalProperties": false
          },
          "next_cursor": {
            "type": [
              "string",
              "null"
            ]
          },
          "truncated": {
            "type": "boolean"
          }
        },
        "required": [
          "recording",
          "artifacts",
          "next_cursor",
          "truncated"
        ],
        "additionalProperties": false
      }
    },
    "search": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "minLength": 1,
            "maxLength": 500
          },
          "kind": {
            "type": "string",
            "enum": [
              "meeting",
              "call",
              "conversation",
              "voice-memo",
              "ad-hoc"
            ]
          },
          "participant": {
            "type": "string",
            "format": "uuid"
          },
          "since": {
            "type": "string",
            "format": "date-time"
          },
          "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 100,
            "default": 50
          },
          "cursor": {
            "type": "string"
          }
        },
        "required": [
          "query"
        ],
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "items": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "recording_id": {
                  "type": "string",
                  "format": "uuid"
                },
                "revision": {
                  "type": "integer",
                  "minimum": 0
                },
                "artifact": {
                  "type": "string",
                  "enum": [
                    "title",
                    "transcript",
                    "summary",
                    "notes"
                  ]
                },
                "entity_id": {
                  "type": "string"
                },
                "snippet": {
                  "type": "string"
                },
                "rank": {
                  "type": "number"
                },
                "resource_uri": {
                  "type": "string",
                  "format": "uri"
                }
              },
              "required": [
                "recording_id",
                "revision",
                "artifact",
                "entity_id",
                "snippet",
                "rank",
                "resource_uri"
              ],
              "additionalProperties": false
            }
          },
          "next_cursor": {
            "type": [
              "string",
              "null"
            ]
          },
          "snapshot_seq": {
            "type": "integer",
            "minimum": 0
          }
        },
        "required": [
          "items",
          "next_cursor",
          "snapshot_seq"
        ],
        "additionalProperties": false
      }
    },
    "get_participants": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 100,
            "default": 50
          },
          "cursor": {
            "type": "string"
          }
        },
        "required": [],
        "additionalProperties": false
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "items": {
            "type": "array",
            "items": {
              "$ref": "#/$defs/Person"
            }
          },
          "next_cursor": {
            "type": [
              "string",
              "null"
            ]
          },
          "snapshot_seq": {
            "type": "integer",
            "minimum": 0
          }
        },
        "required": [
          "items",
          "next_cursor",
          "snapshot_seq"
        ],
        "additionalProperties": false
      }
    },
    "set_notes": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "format": "uuid"
          },
          "markdown": {
            "type": "string",
            "maxLength": 200000
          },
          "expected_revision": {
            "type": "integer",
            "minimum": 0
          },
          "request_id": {
            "type": "string",
            "format": "uuid"
          }
        },
        "required": [
          "id",
          "markdown",
          "expected_revision",
          "request_id"
        ],
        "additionalProperties": false
      },
      "outputSchema": {
        "$ref": "#/$defs/MutationReceipt"
      }
    },
    "rename_speaker": {
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "format": "uuid"
          },
          "speaker": {
            "type": "string",
            "minLength": 1
          },
          "person": {
            "type": "string",
            "format": "uuid"
          },
          "expected_revision": {
            "type": "integer",
            "minimum": 0
          },
          "request_id": {
            "type": "string",
            "format": "uuid"
          }
        },
        "required": [
          "id",
          "speaker",
          "person",
          "expected_revision",
          "request_id"
        ],
        "additionalProperties": false
      },
      "outputSchema": {
        "$ref": "#/$defs/MutationReceipt"
      }
    }
  }
}
```

## 3. Sémantique des outils

| Outil | Règles |
|---|---|
| `list_recordings` | `since` inclusif sur le début UTC ; `participant` = UUID d'identité confirmée dans la version courante, jamais nom libre ni simple invité calendrier ; exclut supprimés |
| `get_recording` | ID public = recording ID, identique au session ID ; par défaut révision courante ; `revision` permet lecture historique hors effacement ; `include` limite les artefacts |
| `search` | FTS5 sur versions courantes, accents normalisés, AND entre tokens littéraux ; rank BM25, plus petit = plus pertinent ; pas une probabilité |
| `get_participants` | Personnes nommées connues et sujets persistants consentis non nommés ; exclut opposants/effacés et clusters locaux ; aucun email, consentement ou score biométrique |
| `set_notes` | Remplace seulement le Markdown libre ; préserve les entrées notepad horodatées ; string vide autorisée ; nouvelle version de notes et révision session |
| `rename_speaker` | `speaker` = ID de cluster de la version courante ; `person` = UUID existant ; corrige tous les segments du cluster dans cette session, crée une version de transcript ; aucun renommage global de personne ni enrôlement |

Un appel `rename_speaker` ne crée pas une personne. Créer/nommer un sujet persistant reste une action de l'app. Une personne opposée est refusée. Une correction textuelle vers une personne sans consentement vocal reste possible mais ne crée pas d'empreinte. Un cluster obsolète retourne `VERSION_CONFLICT`. Les numéros Speaker N et noms affichés ne sont jamais acceptés comme IDs.

Mutations : comparer `expected_revision`, appliquer, incrémenter la révision, écrire outbox et receipt dans **une transaction**. Un retry avec le même `request_id` et même payload rend le receipt initial, même si la session a changé ensuite. Un autre payload sous le même ID retourne `IDEMPOTENCY_CONFLICT`. Le flag `identity_enrollment: not_performed` s'applique aussi à set_notes, pour expliciter l'absence d'effet biométrique.

## 4. Pagination et taille

| Liste | Ordre stable |
|---|---|
| Enregistrements | `started_at DESC, id DESC` |
| Personnes | `id ASC` |
| Recherche | `bm25 ASC, recording_id ASC, artifact ASC, entity_id ASC` |

Curseurs opaques base64url : version, hash des filtres, dernière clé, `snapshot_seq` global, expiration à 15 min. Signés HMAC avec clé éphémère du processus, donc invalidés au redémarrage. Aucun nom ou contenu textuel en clair dans le curseur. Contrôler taille et signature avant décodage métier. Toute modification de `change_log.seq` depuis la première page invalide la pagination de liste par `CURSOR_STALE` ; le client recommence. Ce choix privilégie la cohérence sans garder une transaction SQLite ouverte entre appels.

`get_recording` fige la révision au premier appel. Le curseur porte version, artefact et offset de caractère Unicode ; les blocs suivants peuvent découper un paragraphe. `max_chars` borne le total des champs Markdown de la réponse. `truncated=true` tant qu'il reste du texte ; la concaténation par artefact reconstitue exactement le texte. Les artefacts non demandés sont absents. Une redaction invalide les curseurs historiques. Refuser toute réponse encodée > 1 Mio et proposer une page plus petite.

## 5. Ressources

| URI template | MIME | Contenu |
|---|---|---|
| `hwyd://recording/{id}/transcript.md` | `text/markdown` | Frontmatter minimal ID/révision/version + transcript courant |
| `hwyd://recording/{id}/summary.md` | `text/markdown` | Frontmatter avec statut/provenance + synthèse ; indication de statut si absente |
| `hwyd://recording/{id}/notes.md` | `text/markdown` | Frontmatter ID/révision/version + entrées horodatées et Markdown libre |

`resources/templates/list` expose ces trois modèles ; `resources/list` retourne une liste vide pour ne pas énumérer tout l'historique. `resources/read` accepte uniquement ces URI exactes avec UUID valide. Pas de `file://`, pas de chemins libres ni de paramètres non prévus. Le champ `source: hwyd://session/<id>` des exports est un identifiant canonique, pas une quatrième ressource ; l'ID est le même.

Schéma du contenu textuel encodé dans une réponse `resources/read` :

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "contents": {
      "type": "array", "minItems": 1, "maxItems": 1,
      "items": {
        "type": "object",
        "properties": {
          "uri": {"type":"string","pattern":"^hwyd://recording/[0-9a-f-]{36}/(transcript|summary|notes)\\.md$"},
          "mimeType": {"const":"text/markdown"},
          "text": {"type":"string"}
        },
        "required": ["uri","mimeType","text"],
        "additionalProperties": false
      }
    }
  },
  "required": ["contents"], "additionalProperties": false
}
```

Lecture ressource atomique sur un snapshot, sans pagination du protocole de ressource. Si elle dépasse 1 Mio, retourner une erreur `RESOURCE_TOO_LARGE` indiquant d'utiliser `get_recording` paginé. Aucun résultat silencieusement tronqué.

## 6. Erreurs et exposition des données

Erreurs de protocole : méthode inconnue, JSON-RPC invalide ou arguments non conformes utilisent les codes JSON-RPC du SDK. Erreurs métier d'outil : `isError: true`, contenu textuel JSON stable décrit ci-dessous. Succès : `structuredContent` conforme à outputSchema et bloc texte JSON équivalent pour les clients ne lisant pas structuredContent. Les annotations `readOnlyHint`, `destructiveHint` et `idempotentHint` informent le client mais ne remplacent pas les contrôles serveur.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "code": {"type":"string"},
    "message": {"type":"string"},
    "retryable": {"type":"boolean"},
    "current_revision": {"type":["integer","null"],"minimum":0}
  },
  "required": ["code","message","retryable","current_revision"],
  "additionalProperties": false
}
```

Codes métier : `NOT_FOUND`, `WRITE_DISABLED`, `VERSION_CONFLICT`, `IDEMPOTENCY_CONFLICT`, `PERSON_OPPOSED`, `CURSOR_INVALID`, `CURSOR_STALE`, `RESOURCE_TOO_LARGE`, `STORE_BUSY`, `STORE_NOT_INITIALIZED`, `SCHEMA_MISMATCH`, `ARTIFACT_UNAVAILABLE`. Ne pas inclure de SQL, chemin privé ou texte source dans les messages d'erreur.

MCP local n'a pas d'authentification HTTP. Le client stdio reçoit les droits du processus lancé. L'opt-in MCP doit expliquer que le client agent peut transmettre les textes à son fournisseur. Le serveur ne traite jamais une instruction contenue dans un transcript comme une commande. Les outils d'écriture n'exécutent aucun shell, n'ouvrent aucun lien et ne changent aucune permission de consentement.

Tests de contrat requis à l'implémentation : validation des entrées/sorties, accès app éteinte, deux writers concurrents, retry après commit, politique désactivée après initialize, curseur après mutation, grande ressource, redaction et refus de traversée d'URI.
