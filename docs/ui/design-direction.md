# Direction visuelle : Studio

Statut : retenue par Antoine le 23 octobre 2026.

Référence interactive : [maquettes](visual-directions.html), ouvertes sur Studio par défaut. Clair et Carnet restent consultables comme alternatives explorées.

| Élément | Direction retenue |
|---|---|
| Surfaces | Graphite, fond principal `#1b2025`, surfaces secondaires `#232a30` |
| Texte | Principal `#e7ecee`, secondaire `#9aa8af` |
| Accent | Menthe `#a5dcc8`, sélection et lecture |
| Capture / arrêt | Cuivre `#e9a48c`, toujours accompagné d’un libellé |
| Typographie | Système macOS ; chiffres monospaces pour les durées |
| Composition | Contrôles compacts, audio visible, transcript prioritaire en relecture |
| Parcours | Bibliothèque, capture avec notepad, relecture, barre de menus |
| Identité | Correction de voix accessible depuis le transcript, distincte de l’enrôlement |

La maquette est une référence visuelle, pas une implémentation SwiftUI. Ses données, la capture et la lecture sont simulées. Le choix de Studio ne modifie pas les contrats techniques ni les règles de consentement. Les deux apparences conservent la même composition Studio. Le thème clair utilise des surfaces blanches et gris sauge, une menthe profonde `#256951` et un cuivre `#99492f` pour garder les textes et contrôles lisibles.

## Première implémentation native

L’interface Studio est implémentée dans `Sources/HWYDApp` avec SwiftUI. Le projet se construit avec SwiftPM et `scripts/build-app.sh`, sans `.xcodeproj`, comme No Bleeding Eyes. Voir le [README](../../README.md) pour les parcours disponibles, les vérifications et les limites actuelles.

## Apparence de l’application

Réglages propose **Système** (défaut), **Clair** et **Sombre**. Système suit les changements de macOS sans relancer l’application. Le choix s’applique à la fenêtre principale, au menu, au notepad et aux fenêtres de dialogue. Les modes découverte, snapshots et tests ne modifient pas la préférence enregistrée.

`--snapshot` génère les mêmes parcours dans les sous-dossiers `light/` et `dark/`, sans changer l’apparence globale de macOS.

## Relecture multipiste

Le lecteur présente deux lignes alignées sur la même durée : Micro et Système. Les formes d’onde proviennent des échantillons audio, avec un curseur commun. Un clic ou glissement sur une piste déplace les deux. Le lecteur tient sur deux lignes fines, sans titre ni slider : quand il a le focus, les flèches gauche et droite déplacent la lecture de 5 s, et la position affichée est ajustable par les technologies d’assistance. La lecture enchaîne les tranches CAF et respecte les silences entre fichiers.

Les deux pistes sont audibles par défaut. **S** active Solo, **M** active Muet. Plusieurs solos sont possibles ; Muet reste prioritaire. Les commandes changent le mixage sans déplacer le curseur. Les réglages de mixage sont remis à zéro à l’ouverture d’une autre session. Aucune forme d’onde fictive n’est affichée quand l’audio est absent.

## Réglages intégrés

Les réglages occupent le panneau principal de la fenêtre. La barre latérale présente cinq catégories : Général, Calendrier, Audio et voix, Synthèse, Données et agents. Chaque catégorie possède son en-tête et des cartes dans une zone défilante, avec un réglage par ligne : libellé à gauche, contrôle à droite. Les réglages s’appliquent au changement, sans bouton d’enregistrement. Les explications longues s’ouvrent depuis un bouton d’aide `(?)`. Les modèles affichent leur état (installé ou à installer). Les personnes mémorisées se gèrent dans Audio et voix. La rétention audio n’est pas proposée tant que la purge n’existe pas. La largeur du contenu est bornée pour garder une lecture confortable sur grand écran.

Retour retrouve la session ou la bibliothèque précédente. La capture reste accessible. Le raccourci ⌘, ouvre ce même espace. Les liens depuis la synthèse sélectionnent directement la catégorie Synthèse. Aucun panneau modal supplémentaire.

## Compte rendu de session

Toutes les sessions utilisent une structure commune inspirée des notes Google Meet : Résumé et points clés, Décisions, Étapes suivantes, Détails par thème, puis Contexte quand un agent en apporte. Les sections sans contenu sont masquées. Les anciennes synthèses restent affichées jusqu'à leur régénération.

The summary reads as a document, not a block of text:

- The reading column is limited to 640 pt. When the pane is wide enough, an outline sits beside it, lists sections and topics, highlights the one on screen and jumps to any entry.
- The overview opens in 15 pt, followed by counters (decisions, actions, topics, context notes) that scroll to their section, and key points as cards in two columns.
- Decisions are callouts with a mint edge. Actions are rows: the assignee's initials when the summary names one, the action, its due date in copper, its source.
- Each item carries one source reference: the first passage's time and how many others back it. Hover lists the passages; a click moves playback to the first one.
- Topics and context notes fold. Folded, they show their title, first sentence and the time span of their passages; open, the full text and one reference per passage. Summaries with more than three topics start folded; « Tout déplier » opens them all.

## Voice review

Every tab of a session shows one tile per detected voice under the player. A tile states the voice, its track and its speech time, plus its state: unidentified (dashed copper border), proposed (copper) or confirmed (mint). Clicking the tile plays only that voice's passages on its own track, back to back with a short silence. The tile action names or confirms the voice for the whole session; its menu also links it to a known person or regroups it with another voice. A voice that is not a participant (usually the speakers' echo on the microphone) can be ignored from the menu: the tile turns grey, moves last and offers "Rétablir"; its passages leave the transcript, the export, search and summaries, but stay stored. Dropping a tile onto another regroups them. On the same track, the passages move to the target voice; across tracks, both clusters keep their own audio and share the name. None of these actions enrolls a voice.

During playback the transcript highlights the passages being heard and keeps them in view. A manual scroll pauses the follow; a « Suivre la lecture » button resumes it, and any new playback resumes it too.

## Règles de sobriété (0.6.0)

- Une action, un nom : démarrer s’appelle « Nouvelle session » partout, avec `record.circle`. Un SF Symbol ne porte qu’un sens : `waveform` reste le logo, `waveform.circle` le mémo vocal, `smallcircle.filled.circle` la session libre.
- Quatre tailles de texte (`Studio.Size`) : 11, 13, 15 et 28 pt. Le chronomètre de capture et le logotype sont les seules exceptions.
- L’interface ne s’explique pas en phrases : pas de slogan, pas de note de bas de page. Une explication utile passe par une infobulle ou un bouton d’aide `(?)`.
- Dans la fenêtre principale, le mode découverte est annoncé par le bandeau ; la ligne d’état de la capture dit « Simulation » parce que le carnet détaché n’a pas de bandeau.
- Les actions d’un passage du transcript tiennent dans un bouton `ellipsis.circle` en bout de ligne.
- « Nouvelle session » n’enregistre jamais directement : elle ouvre un écran de préparation (type de session, nom facultatif), et seul « Démarrer l’enregistrement », en cuivre, lance la capture. Le dernier type choisi est retenu. La barre de menus propose les mêmes champs en version compacte. Les rappels de réunion démarrent directement, la réunion fournissant déjà type et titre.
- Les messages de l’application sont des toasts empilés en bas à droite de la fenêtre. Une information disparaît après 5 s, une erreur après 8 s ; le survol suspend la disparition. Un toast qui demande une décision porte ses boutons, reste affiché jusqu’à la réponse, et un clic sur le toast déclenche son action principale. Une offre facultative comme « Annuler » après une correction de voix disparaît seule après 8 s. Le bandeau reste réservé au mode découverte.
- L’identité des voix se gère depuis les tuiles de la session : nommer, regrouper, séparer, ignorer, mémoriser. Le canal (micro ou visio) n’est jamais demandé, il découle de la piste. Mémoriser reste une action distincte, confirmée. Les personnes mémorisées et ce que chaque session a apporté à leur empreinte se gèrent dans Réglages › Audio et voix.
