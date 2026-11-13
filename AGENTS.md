# HWYD

Canonical guide for any AI coding agent or human contributor working in this repository. Tool-specific entrypoints should defer to this file rather than duplicate it.

Public repository. Discussion and UI remain in French. New documentation, issues and PRs use English. Existing French design documents are retained. Code and commits use English. No em dash.

## Project rules

- Read `docs/architecture.md` and `docs/ui/design-direction.md` before changing the architecture or the visual language.
- SwiftPM, Swift 6 strict concurrency. No `.xcodeproj` required.
- Use the installed Xcode as toolchain without changing global settings (the Makefile exports `DEVELOPER_DIR`).
- After a UI change, run `make snapshot` and inspect the PNG files.
- Never rebuild over a binary that is recording.
- Demo and synthetic tests stay separate from real data. No microphone is used by `--demo`, `--snapshot`, `--self-test`, `--ui-test` or `--asr-test`.
- Never present a future feature as active. The README describes the limits of the current version.
- No voice vector in exports or SQLite. A speaker correction is not consent to enrollment.
- The C audio callback must not allocate, write to disk or take a blocking lock.

## Development commands

Every command is a `make` target. Run `make help` to list them.

```sh
make build          # Debug app (persistent signing identity, see README)
make build-adhoc    # Ad hoc signed debug app, isolated checks only
make check          # Static checks (localization catalog)
make test           # Core, pipeline, realtime and Python contract tests
make test-app       # Synthetic checks against the built app (no microphone)
make snapshot       # UI snapshots, French and English
make ci             # What CI runs, locally
make version        # Last released version
make release VERSION=x.y.z   # Sign, notarize and publish
```

## Operating modes

These workflows are stable; do not change them without explicit request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contributor workflow.

### Branch strategy
- `main` is the single branch for development and releases, protected by a ruleset: the `ci` status check must pass before merge.
- Feature branches start from `main`, named `feat/...`, `fix/...`, `docs/...` or `chore/...`.
- PRs to `main` are squash-merged (one commit per PR); merged branches are deleted.

### Git conventions
- No AI signature: no `Co-Authored-By` trailers.
- Conventional commits (`feat:`, `fix:`, `docs:`, `build:`, `chore:`, `test:`, `release:`), with a scope when it helps (`feat(summary): …`).
- **Changelog**: every behavior-affecting PR adds an entry under `[Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md) (Keep a Changelog). PRs with no user-facing effect use the `skip-changelog` label.

### Versioning
The last `vX.Y.Z` tag is the version source of truth; there is no version file. `scripts/build-app.sh` writes `VERSION` into the bundle at release time. Versions follow Semantic Versioning.

### Release process
A `release: X.Y.Z` PR moves the `[Unreleased]` entries under a dated `## [X.Y.Z] - YYYY-MM-DD` section and adds `docs/releases/X.Y.Z.md`. Once merged, run `make release VERSION=X.Y.Z` on an up-to-date `main`. Follow [docs/development/release-template.md](docs/development/release-template.md) for titles and notes, and [docs/distribution.md](docs/distribution.md) for signing and notarization.

## Keeping documentation in sync

Documentation is part of the definition of done, like tests. A PR that changes behavior, architecture, storage, exports, MCP tools or a public workflow updates the affected docs in the same PR. Verify statements against the code before relying on or copying them.

| You changed… | Update… |
|---|---|
| Layers, targets, data flow | [docs/architecture.md](docs/architecture.md), [docs/technical-design.md](docs/technical-design.md), this file |
| Capture, realtime audio, alignment | [docs/architecture.md](docs/architecture.md), [docs/capture-diagnostics.md](docs/capture-diagnostics.md) |
| Echo handling | [docs/echo-cancellation.md](docs/echo-cancellation.md) |
| SQLite schema, stored models | [docs/data-model.md](docs/data-model.md) |
| Markdown/JSON exports | [docs/output-format.md](docs/output-format.md) |
| MCP tools or resources | [docs/mcp.md](docs/mcp.md), README § MCP |
| Summary providers, prompts, schema | [docs/summary-workflow.md](docs/summary-workflow.md), [docs/review-integrations.md](docs/review-integrations.md) |
| Voice memory, identity, consent | [docs/voice-memory.md](docs/voice-memory.md) |
| UI strings, languages | [docs/localization.md](docs/localization.md) |
| Visual language | [docs/ui/design-direction.md](docs/ui/design-direction.md) |
| Build, signing, release | [docs/distribution.md](docs/distribution.md), [docs/development/release-template.md](docs/development/release-template.md) |
| A user-visible capability or limit | [README.md](README.md) § Features, § Current limitations |
| Commands, conventions, operating modes | this file, [CONTRIBUTING.md](CONTRIBUTING.md) |

The PR checklist ([.github/pull_request_template.md](.github/pull_request_template.md)) restates this so it is enforced at review time.
