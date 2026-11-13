# Release template

Follow this template when cutting a release so titles and notes stay consistent with past releases (derived from `docs/releases/0.9.0.md` to `0.12.1`). It covers three artifacts: the **release PR**, the **GitHub Release title** and the **release notes**.

## Release flow (recap)

1. Pick the version from the `[Unreleased]` entries (Semantic Versioning: `Added` or a notable `Changed` means minor, `Fixed` alone means patch). `make version` shows the last one.
2. On a `release/X.Y.Z` branch, move the `[Unreleased]` entries of `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD` section, leave `## [Unreleased]` in place and empty, and update the compare links at the bottom.
3. Write `docs/releases/X.Y.Z.md` (template below), from the changelog entries.
4. Open the PR, merge it once `ci` passes.
5. On an up-to-date `main`: `make release VERSION=X.Y.Z`. It checks the changelog section and notes, then runs `scripts/publish-release.sh`, which builds, signs, notarizes, tags `vX.Y.Z`, publishes the GitHub release and updates the Homebrew cask. See [distribution](../distribution.md) for prerequisites and recovery.

## Release PR title

Use a `release:` prefix with the bare version:

```
release: X.Y.Z
```

## GitHub Release title

The tag and the release name are `vX.Y.Z` (set by `scripts/publish-release.sh`). Sparkle's appcast links to the GitHub release page, so the notes are also what the in-app updater shows. The notes file opens with a themed H1 summarizing the release in a few words:

```
# How Was Your Day vX.Y.Z: <short theme>
```

## Release notes (`docs/releases/X.Y.Z.md`)

Scale the sections to the release: a patch may only need the intro, Installation and the changelog link; a minor uses Highlights and one subsection per feature. Keep the emoji section headers so releases read consistently.

```markdown
# How Was Your Day vX.Y.Z: <short theme>

[![Downloads for this release](https://img.shields.io/github/downloads/alepee/how-was-your-day/vX.Y.Z/total.svg)](https://github.com/alepee/how-was-your-day/releases/vX.Y.Z)

<One or two sentences: what this release lets the user do and why it matters. Link the PRs or issues, e.g. ([#16](https://github.com/alepee/how-was-your-day/pull/16)).>

## 🎯 Highlights   <!-- minor/major only -->

- **<Feature>**: one-line value statement
- **<Feature>**: one-line value statement

## ✨ What's New

### <Feature title>

<What changed, from the user's point of view: what they see, where to find it.>

## 🐛 Bug Fixes   <!-- if any -->

### <Fix title> ([#NNN](https://github.com/alepee/how-was-your-day/issues/NNN))

<What was wrong and what the user now observes.>

## ⚠️ Upgrade note   <!-- only when the update needs a user action -->

<Exact steps: permissions to grant again, languages to reinstall, sessions to reprocess. State what is kept.>

## 🚧 Known limits   <!-- what this release does not do yet, or has not been measured -->

- <Limit.>

## 🔧 Under the Hood   <!-- optional: build, signing, CI, internal changes worth noting -->

- <Internal change, with PR link.>

## 📦 Installation

Use **Check for Updates…** in the app menu, or:

```sh
brew update && brew upgrade --cask alepee/tap/how-was-your-day
```

Or download `HowWasYourDay.dmg` below (Apple Silicon, macOS 26 or later; signed and notarized).

<State migration needs explicitly: "No migration needed." or what happens to existing sessions.>

## 🐛 Bug Reports

If you encounter issues, please [open an issue](https://github.com/alepee/how-was-your-day/issues/new/choose) with:
- HWYD and macOS versions
- Your audio setup (built-in microphone, USB interface, Bluetooth headset) when recording is involved
- The exact error message

Do not attach recordings, transcripts or summaries of real conversations.

---

**Full Changelog:** [vPREV...vX.Y.Z](https://github.com/alepee/how-was-your-day/compare/vPREV...vX.Y.Z)
```

See [0.12.0](../releases/0.12.0.md) for a complete example.

## Notes

- Write from the **user's** perspective (observable behavior), not the diff. The `CHANGELOG.md` entries are the raw material; the notes reframe them.
- Name menus and buttons as the English interface shows them, in bold (**Expand all**).
- Never present a future feature as active. State limits plainly, including what has not been tested on real devices.
- Include `⚠️ Upgrade note` only when the user must act (a signing change makes macOS ask for permissions again); restate the action in Installation.
- Always end with the `Full Changelog` compare link against the previous tag.
- No em dash: the H1 uses a colon.
