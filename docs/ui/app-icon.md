# Icône d'application

L'icône reprend la silhouette de l'icône de barre de menus (SF Symbol `waveform`, `Sources/HWYDApp/App.swift`) dans la direction [Studio](design-direction.md) : six barres menthe sur un corps graphite.

| Élément | Valeur |
|---|---|
| Corps | Carré arrondi graphite, dégradé vertical `#2b343b` → `#1b2025` → `#161a1e` |
| Onde | Six barres, hauteurs relatives 0,22 / 0,61 / 1 / 0,50 / 0,78 / 0,30, dégradé menthe `#c4ecdd` → `#a5dcc8` → `#86c4ad` |
| Détails (≥ 64 px) | Liseré clair en haut, sombre en bas, halo menthe discret derrière l'onde |
| Grille | Corps de 824/1024 avec ombre portée, conforme à la grille macOS |
| Petites tailles | 16 et 32 px : corps élargi, onde plus large, barres alignées sur la grille de pixels, extrémités carrées, sans ombre ni halo |

Le cuivre reste réservé à la capture : il n'apparaît pas dans l'icône.

## Génération

Le rendu est vectoriel et déterministe (AppKit / Core Graphics). Chaque PNG est dessiné directement à sa taille en pixels dans un `NSBitmapImageRep`, sans `lockFocus`, donc sans dépendre de l'échelle de l'écran.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift scripts/make-icon.swift build/icon-preview/AppIcon.iconset build/icon-preview
iconutil -c icns build/icon-preview/AppIcon.iconset -o Resources/AppIcon.icns
```

Le second argument est facultatif : il produit `sheet.png` (toutes les tailles à 1:1 sur fond graphite et clair), `zoom-16.png`, `zoom-32.png` et `icon-<taille>.png` pour l'inspection.

`scripts/build-app.sh` copie `Resources/AppIcon.icns` dans le bundle. `Resources/Info.plist` le référence via `CFBundleIconFile` = `AppIcon`.
