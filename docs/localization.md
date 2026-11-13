# Localization

The app UI is available in French (development language) and English. It follows the macOS language order: English when English comes before French, French otherwise (including any other language). Changing the language per app in System Settings › General › Language & Region also works.

## Source of truth

- `Resources/Localizable.xcstrings`: every user-facing string of `Sources/HWYDApp`, `Packages/HWYDCore` and `Sources/HWYDPipeline`. Keys are the French text exactly as written in the code, as the Swift compiler sees it (interpolations become `%@`, `%lld`…). Each key has a `fr` and an `en` entry; counted strings use plural variations in both languages.
- `Resources/InfoPlist.xcstrings`: privacy usage descriptions of `Info.plist`.
- `Info.plist` declares `CFBundleDevelopmentRegion` = `fr` and `CFBundleLocalizations` = `fr`, `en`.

## Mechanism

There is no Xcode project, and SwiftPM does not compile String Catalogs for this app layout. `scripts/build-app.sh` runs `xcrun xcstringstool compile` on both catalogs into `Contents/Resources/fr.lproj` and `en.lproj` (`.strings` and `.stringsdict`).

- SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`…) resolve from `Bundle.main`.
- Strings stored as `String` (notices, errors, toasts, enum labels, panel prompts) use `String(localized: "…")` in the app.
- HWYDCore and the helpers use `String(localized: "…", bundle: .hwyd)`. `Bundle.hwyd` (`HWYDCore/Localization.swift`) is `Bundle.main` in the app. In `Contents/Helpers/hwyd-pipeline` and `hwyd-mcp`, `Bundle.main` is the helper directory, so `Bundle.hwyd` is the app's `.lproj` for the language in `HWYD_LOCALIZATION`. `PipelineRunner`, which starts the helper for the pipeline adapters, sets that variable from the app's resolved language, so an error raised in the helper and relayed through stderr reaches the user in the app's language. Without the variable, the helper uses the user's preferred languages. In tests and outside the app bundle no catalog is found and the French source text is returned.
- Dates, times and durations use `formatted(...)` with the current locale.

## Workflow

```sh
python3 scripts/l10n.py sync     # builds with -emit-localized-strings, adds new keys (fr only), drops removed ones
# translate the new keys into en in Resources/Localizable.xcstrings (Xcode's catalog editor works too)
python3 scripts/l10n.py check    # guard, also run in CI
```

`check` fails when a key lacks `fr` or `en`, when a translation changes the placeholders, when the code uses a key missing from the catalog, or when a French-looking literal in `Sources/HWYDApp` is not on a line the compiler extracted. A French literal that must stay as is ends its line with `// l10n:ignore`. `check --fast` skips the build and only compares literals with catalog keys. Source files of the extracted modules must have distinct names: the compiler writes one `.stringsdata` per file name.

Check both languages with `--snapshot <dir> -AppleLanguages '(en)'` and `'(fr)'`.

## Not translated

- Data: demo content, transcripts, notes, session titles, summaries and their Markdown, stored default speaker labels ("Voix 1", "Voix à nommer").
- Model-facing text: summary prompts, the summary schema, rows sent to models ("Voix non identifiée"), and the summary validation reasons, which are also returned to ACP agents.
- Exported files (`SessionExporter`, `RecordingText`), MCP tool schema and protocol text, diagnostic and log lines, `--self-test` output.
- Speech recognition locale: chosen per session or detected per track, independent of the UI language.
