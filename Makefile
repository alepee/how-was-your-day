.DEFAULT_GOAL := help

# Use the installed Xcode as toolchain without touching xcode-select.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

APP      := build/How Was Your Day.app
HWYD     := $(APP)/Contents/MacOS/HWYD
MCP      := $(APP)/Contents/Helpers/hwyd-mcp
# Synthetic test runs write here, never in the user's store.
TEST_DIR := build/make-tests

# The last published tag is the version source of truth (no version file).
VERSION_TAG := $(shell git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)

# --- Build ---------------------------------------------

.PHONY: build
build: ## Build the debug app (needs a persistent signing identity, see README)
	scripts/build-app.sh debug

.PHONY: build-release
build-release: ## Build the release app locally (not a published release)
	scripts/build-app.sh release

.PHONY: build-adhoc
build-adhoc: ## Build an ad hoc signed debug app, for isolated checks only
	SIGN_IDENTITY=- HWYD_ALLOW_ADHOC=1 scripts/build-app.sh debug

.PHONY: run
run: ## Open the built app
	open "$(APP)"

# --- Quality -------------------------------------------

.PHONY: l10n
l10n: ## Check the String Catalog (French and English complete)
	python3 scripts/l10n.py check

.PHONY: l10n-sync
l10n-sync: ## Add new localizable literals to the String Catalog
	python3 scripts/l10n.py sync

.PHONY: check
check: l10n ## Run static checks (localization catalog)

# --- Testing -------------------------------------------

.PHONY: test-core
test-core: ## Run HWYDCore tests (models, store, summaries, exports)
	swift test --package-path Packages/HWYDCore

.PHONY: test-pipeline
test-pipeline: ## Run the root package tests (pipeline)
	swift test

.PHONY: test-realtime
test-realtime: ## Run realtime buffer tests under sanitizers
	scripts/test-realtime.sh

.PHONY: test-scripts
test-scripts: ## Run the Python contract tests (summary HTTP, ACP, ledger, benchmark)
	mkdir -p build
	python3 scripts/test-summary.py
	python3 scripts/test-act-probe.py
	python3 scripts/test-ledger-summary.py
	python3 scripts/test-benchmark-summary.py
	python3 scripts/test-appcast.py

.PHONY: test
test: test-core test-pipeline test-realtime test-scripts ## Run all tests that need no built app

.PHONY: test-app
test-app: ## Run synthetic checks against the built app (no microphone)
	rm -rf "$(TEST_DIR)"
	"$(HWYD)" --self-test "$(TEST_DIR)/audio"
	"$(HWYD)" --ui-test "$(TEST_DIR)/ui"
	"$(HWYD)" --ui-test "$(TEST_DIR)/ui-en" -AppleLanguages '(en)'
	python3 scripts/test-mcp.py "$(MCP)" "$(TEST_DIR)/ui"

.PHONY: snapshot
snapshot: ## Render UI snapshots (French and English) into build/screenshots
	"$(HWYD)" --snapshot build/screenshots
	"$(HWYD)" --snapshot build/screenshots-en -AppleLanguages '(en)'

.PHONY: ci
ci: check test build-adhoc test-app ## Run what CI runs, locally

# --- Release -------------------------------------------

.PHONY: version
version: ## Show the last released version
	@echo $(VERSION_TAG:v%=%)

.PHONY: release-check
release-check: ## Check release inputs (usage: make release-check VERSION=x.y.z)
	@test -n "$(VERSION)" || { echo "Usage: make release-check VERSION=x.y.z"; exit 1; }
	@test -f "docs/releases/$(VERSION).md" || { echo "Missing docs/releases/$(VERSION).md"; exit 1; }
	@grep -q '^## \[$(VERSION)\] - [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$$' CHANGELOG.md || { \
		echo "CHANGELOG.md has no dated '## [$(VERSION)] - YYYY-MM-DD' section."; exit 1; }
	@echo "Release inputs for $(VERSION) are ready."

.PHONY: release
release: release-check ## Sign, notarize and publish (usage: make release VERSION=x.y.z)
	scripts/publish-release.sh $(VERSION) docs/releases/$(VERSION).md

# --- Help ----------------------------------------------

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
