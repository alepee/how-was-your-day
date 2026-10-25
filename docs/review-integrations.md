# Review des intégrations

Version de travail du 25 octobre 2026. Trois premières tranches fonctionnelles. Le document d’architecture cible n’est pas modifié.

## Signature

Le build utilise le certificat local existant `No Bleeding Eyes Code Signing`. Empreinte publique SHA-1 : `E9EA65E6060488008B4345D4EA527BAA7F88771F`.

Les identifiants sont fixes : `dev.lepee.hwyd`, `dev.lepee.hwyd.pipeline`, `dev.lepee.hwyd.mcp`. Deux exécutables différents signés avec ce certificat ont la même designated requirement. La vérification stricte passe. Aucun réglage de confiance système n’a été modifié. La continuité TCC reste à confirmer sur les prochains rebuilds. Le passage initial depuis ad hoc peut demander une nouvelle autorisation. Ce n’est pas une signature de distribution Developer ID.

## Parcours à essayer

| Chantier | Parcours | Résultat |
|---|---|---|
| Synthèse | Réglages → Synthèse locale. Activer, saisir endpoint `/v1` et identifiant exact du modèle. Ouvrir une session → Synthèse → Générer | Brouillon, modèle et version du prompt. Une correction pendant le calcul invalide le résultat |
| Voix | Session → Identité des voix. Choisir canal et cluster, confirmer consentement et propreté des passages | Empreinte 256 dimensions dans le trousseau. Minimum 20 secondes. Aucun vecteur en SQLite ou dans les exports |
| Reconnaissance | Autre session → Identité des voix → Chercher les voix consenties | Propositions à confirmer. Aucun renommage automatique |
| Opposition | Identité des voix → Effacer et opposer | Suppression des empreintes des trois canaux et blocage des nouveaux enrôlements du même nom. Les noms historiques restent dans les transcripts |
| Exports | Réglages → Agents et exports → Choisir le dossier de publication | Les révisions en attente sont publiées. Les sauvegardes suivantes republient automatiquement |
| Export ponctuel | Bouton Exporter d’une session | Copie indépendante dans le dossier choisi |
| MCP | Configurer le client ci-dessous | L’app peut être fermée. Lecture directe du store |

Une correction de nom seule ne crée aucune empreinte. Une case de consentement enregistrée dans SQLite ne suffit pas à prouver que l’extraction a réussi. Le message de succès confirme la création dans le trousseau.

## Configuration MCP

```json
{
  "mcpServers": {
    "hwyd": {
      "command": "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-mcp",
      "args": ["--read-only"]
    }
  }
}
```

`--store /chemin/absolu` permet un store distinct. Le serveur n’initialise ni ne migre les données. Lancer d’abord l’app après mise à jour.

Pour écrire, activer l’option dans les réglages et remplacer `--read-only` par `--allow-write`. Les deux autorisations sont nécessaires. La révocation est contrôlée dans chaque transaction. Relancer le serveur pour faire apparaître les outils d’écriture après activation.

Outils : `list_recordings`, `get_recording`, `search`, `get_participants`, `set_notes`, `rename_speaker`. Les schémas livrés sont dans `Sources/HWYDMCP/tools.json`. Les mutations exigent `expected_revision` et un `request_id` UUID unique. Une répétition identique rend le même reçu. Aucun enrôlement biométrique via MCP.

Les ressources suivent `hwyd://recording/<UUID>/transcript.md`, `summary.md` et `notes.md`. Taille maximale 1 Mio. Au-delà, utiliser `get_recording` paginé. Les curseurs sont authentifiés, expirent après 15 minutes et deviennent invalides si les données changent. Ils ne survivent pas au redémarrage du serveur.

## Implémentation et limites

| Élément | État de cette tranche |
|---|---|
| LLM | Endpoint de boucle locale uniquement. Redirections refusées. Sortie JSON et références validées. Pas de backend MLX embarqué ou distant |
| Résumé long | Fenêtres de 12 000 caractères. Résultats concaténés, sans consolidation supplémentaire. Pas de responsable déduit. Dates conservées seulement si explicites dans les segments cités |
| Validation sémantique | Les références existent, mais cela ne prouve pas la fidélité de chaque affirmation. Aucun benchmark qualitatif déclaré réussi |
| Embedding | FluidAudio 0.17.7, traitement des passages sélectionnés concaténés, une seule voix exigée dans le résultat. Jusqu’à 60 secondes par extraction |
| Identité | Seuil expérimental 0,75, marge 0,10, moyenne des trois meilleurs exemplaires, affectation hongroise avec abstention. Même canal uniquement. Pas encore de bonus calendrier |
| Exemplaires | Maximum 20 par personne et canal. Élimination de l’exemplaire le plus redondant. Ce n’est pas encore un k-médoïdes complet |
| Inconnus persistants | Non implémentés. Les voix non enrôlées restent locales à la session |
| Opposition | Efface les vecteurs et bloque les correspondances. Ne supprime pas les noms, textes ou fichiers audio historiques |
| Store | Migrations `ui_v002_people` et `ui_v003_integrations`. FTS5, séquence, reçus idempotents et outbox. Les tables `ui_*` ne sont pas encore le schéma normalisé cible |
| Concurrence | Révision attendue contrôlée en transaction. L’app recharge les changements externes quand elle est inactive et sans édition locale. Un conflit conserve les éditions locales et affiche une erreur, sans fusion automatique |
| Exports | Générations immuables et hashes. `index.jsonl` remplacé atomiquement en conservant l’ordre logique append-only. Fin de ligne incomplète réparée. Fichiers plats modifiés extérieurement préservés en `.conflict-*` |
| Suppression | Tombstone dans le dossier de publication configuré, retrait des générations et fichiers plats. Copies ponctuelles externes non suivies. L’historique du journal conserve les anciennes métadonnées |
| Audio | Pas de purge automatique. `retention_hours` et `expires_at` restent null dans l’export |
| Provenance | Synthèse complète. Provenance ASR/diarizer exportée à compléter. Aucun chemin de fichier audio privé exporté |
| MCP | Stdio seulement, lectures chargées en mémoire. `current_revision` reste null dans les erreurs et les reçus d’export sont conservativement `pending` |

## Vérifications reproductibles

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore
python3 scripts/test-summary.py
"build/How Was Your Day.app/Contents/MacOS/HWYD" --ui-test build/review-ui-test-new
python3 scripts/test-mcp.py "build/How Was Your Day.app/Contents/Helpers/hwyd-mcp" build/review-ui-test-new
"build/How Was Your Day.app/Contents/MacOS/HWYD" --snapshot build/review-screenshots-new
codesign --verify --deep --strict "build/How Was Your Day.app"
```

Les tests UI, HTTP et MCP utilisent uniquement des données fictives. Le test HTTP simule un modèle compatible JSON Schema. Aucun consentement de personne réelle n’est supposé. La qualité intersessions et le comportement TCC après migration nécessitent encore une validation réelle.

Résultats du banc du 25 octobre : tests Core sans échec, tests UI et mixage hors ligne sans échec, échange MCP stdio réel réussi, provider HTTP exercé contre un serveur synthétique. Une voix Qwen synthétique de 35 secondes a également traversé l’extraction FluidAudio, avec un seul cluster et un vecteur valide de 256 dimensions. Le mode `probe-voice` n’écrit aucune empreinte dans le trousseau. Cela ne mesure pas la précision d’identification réelle.
