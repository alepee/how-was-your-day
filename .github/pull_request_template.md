<!-- Release PR? Follow docs/development/release-template.md for the title and body. -->

## Description

<!-- What does this PR do? Why is this change needed? -->

## Checklist

- [ ] Tests pass (`make test`, and `make test-app` when the app changes)
- [ ] Static checks pass (`make check`)
- [ ] `CHANGELOG.md` updated under `[Unreleased]` (or `skip-changelog` label added)
- [ ] Documentation updated for any behavior, architecture, storage, export, MCP or workflow change (see the code-area to doc map in [AGENTS.md](AGENTS.md#keeping-documentation-in-sync))
- [ ] UI change: snapshots inspected (`make snapshot`), French and English strings in the catalog
- [ ] Privacy rules respected: no microphone in synthetic modes, no voice vector in exports or SQLite
