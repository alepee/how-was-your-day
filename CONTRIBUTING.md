# Contributing to How Was Your Day

Thank you for your interest in contributing!

## Quick start

1. Install Xcode 27 (Swift 6.4 or later) on an Apple Silicon Mac.
2. Clone the repository.
3. Build: `make build` (needs a persistent signing identity, see the [README](README.md#build)), or `make build-adhoc` for isolated checks.
4. Verify: `make check && make test`.

Read [AGENTS.md](AGENTS.md) first: it holds the project rules (privacy, realtime audio, synthetic data) that every change must respect.

## Branch strategy

| Branch | Purpose |
|--------|---------|
| `main` | Single branch for development and releases. Protected by a ruleset. |
| Feature branches | Created from `main`, named `feat/...`, `fix/...`, `docs/...` or `chore/...`. |

## Making changes

1. Create a branch from `main` (`git switch main && git pull && git switch -c feat/my-feature`).
2. Follow the [architecture](docs/architecture.md) and, for UI work, the [design direction](docs/ui/design-direction.md).
3. Run `make check && make test`, and `make test-app` when the app changes. For UI changes, run `make snapshot` and look at the images.
4. Update `CHANGELOG.md` under `[Unreleased]` (see [Changelog](#changelog)).
5. Update the affected documentation (see [Documentation](#documentation)).
6. Commit using the [conventional commit](https://www.conventionalcommits.org/) format.

## Pull requests

- **Base branch**: always `main`.
- **Squash merged**: each PR becomes a single commit on `main`.
- Explain what changes and why.
- The `ci` check must pass before merge. It builds the app, runs the core, pipeline, realtime and contract tests, checks the localization catalog and runs the synthetic app checks. A PR touching only documentation skips the build.

## Changelog

Every PR that changes behavior adds an entry under `[Unreleased]` in `CHANGELOG.md`, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):

```markdown
## [Unreleased]

### Added
- New feature description

### Fixed
- Bug fix description
```

Use the right section: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. Write what the user observes, not the implementation.

PRs with no user-facing effect (CI, tooling, internal refactoring, docs) can use the `skip-changelog` label.

## Documentation

Documentation lives in [`docs/`](docs/). A PR that changes behavior, architecture, storage, exports, MCP tools or a public workflow updates the affected docs in the same PR: see the code-area to doc map in [AGENTS.md](AGENTS.md#keeping-documentation-in-sync). Verify statements against the code before relying on them.

## Releases

A `release: X.Y.Z` PR moves the changelog entries and adds `docs/releases/X.Y.Z.md`; once merged, `make release VERSION=X.Y.Z` signs, notarizes and publishes. Use the [release template](docs/development/release-template.md) so titles and notes stay consistent, and see [distribution](docs/distribution.md) for signing.

## Localization

The interface is localized in French and English through `Resources/Localizable.xcstrings`. `make l10n-sync` adds new literals, `make check` fails when an entry lacks a language. See [localization](docs/localization.md).
