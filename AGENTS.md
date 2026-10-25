# HWYD

Public repository. Discussion and UI remain in French. New documentation, issues and PRs use English. Existing French design documents are retained. Code and commits use English. No em dash.

- Lire `docs/architecture.md` et `docs/ui/design-direction.md` avant de changer l’architecture ou le langage visuel.
- SwiftPM, Swift 6 strict concurrency. Pas de `.xcodeproj` requis.
- Build : `scripts/build-app.sh debug`. Utilise Xcode installé comme chaîne d’outils, sans changer les réglages globaux.
- Tests : `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore`.
- UI : `build/How Was Your Day.app/Contents/MacOS/HWYD --snapshot build/screenshots`, puis inspecter les PNG.
- Ne pas reconstruire par-dessus un binaire en cours de capture.
- Démonstration et tests synthétiques séparés des vraies données. Aucun micro utilisé par `--demo`, `--snapshot`, `--self-test`, `--ui-test` ou `--asr-test`.
- Ne pas présenter une fonction future comme active. Le README décrit les limites de la version actuelle.
- Aucun vecteur vocal dans les exports ou SQLite. Une correction de speaker ne constitue pas un consentement à l’enrôlement.
- Le callback audio C ne doit ni allouer, ni écrire sur disque, ni prendre un verrou bloquant.
