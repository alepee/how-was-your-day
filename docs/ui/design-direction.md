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

Le lecteur présente deux lignes alignées sur la même durée : Micro et Système. Les formes d’onde proviennent des échantillons audio, avec un curseur commun. Un clic ou glissement sur une piste déplace les deux. Le slider reste disponible au clavier. La lecture enchaîne les tranches CAF et respecte les silences entre fichiers.

Les deux pistes sont audibles par défaut. **S** active Solo, **M** active Muet. Plusieurs solos sont possibles ; Muet reste prioritaire. Les commandes changent le mixage sans déplacer le curseur. Les réglages de mixage sont remis à zéro à l’ouverture d’une autre session. Aucune forme d’onde fictive n’est affichée quand l’audio est absent.

## Réglages intégrés

Les réglages occupent le panneau principal de la fenêtre. La barre latérale présente six catégories : Général, Calendrier, Audio et voix, Synthèse, Données locales, Agents et exports. Chaque catégorie possède son en-tête et des cartes dans une zone défilante. La largeur du contenu est bornée pour garder une lecture confortable sur grand écran.

Retour retrouve la session ou la bibliothèque précédente. La capture reste accessible. Le raccourci ⌘, ouvre ce même espace. Les liens depuis la synthèse sélectionnent directement la catégorie Synthèse. Aucun panneau modal supplémentaire.

## Compte rendu de session

Toutes les sessions utilisent une structure commune inspirée des notes Google Meet : Résumé et points clés, Décisions, Étapes suivantes, Détails par thème. Les sections sans contenu sont masquées. Chaque thème porte un titre et un paragraphe lisible. Les références horodatées positionnent le lecteur et révèlent le passage source au survol. Les anciennes synthèses restent affichées jusqu'à leur régénération.
