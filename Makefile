# Whisper Transcriber — every development and release command.
# Details: docs/BUILD_AND_RELEASE.md

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT        := $(shell pwd)
PROJECT     := app/WhisperTranscriber.xcodeproj
SCHEME      := WhisperTranscriber
DD          := build/dd
APP_DEBUG   := $(DD)/Build/Products/Debug/WhisperTranscriber.app
UV          := app/WhisperTranscriber/Resources/bin/uv
CATALOG     := app/WhisperTranscriber/Resources/Localizable.xcstrings
DEV_VENV    := build/venv-dev
RUNTIME     := $(HOME)/Library/Application Support/WhisperTranscriber/runtime

export UV_CACHE_DIR := $(HOME)/Library/Caches/WhisperTranscriber/uv
export UV_NO_CONFIG := 1

.PHONY: help
help: ## Show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# --- setup -----------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Download and verify the embedded uv binary + Sparkle's signing tools
	./scripts/fetch_uv.sh
	./scripts/fetch_sparkle.sh

.PHONY: provision
provision: bootstrap ## Install the isolated Python runtime (what first launch does)
	./scripts/provision_runtime.sh

.PHONY: reprovision
reprovision: bootstrap ## Reinstall the runtime from scratch
	./scripts/provision_runtime.sh --force

.PHONY: fixtures
fixtures: ## Generate the test audio files (macOS TTS)
	./scripts/make_test_audio.sh

# --- build -----------------------------------------------------------------

.PHONY: generate
generate: bootstrap ## Generate the Xcode project from project.yml
	cd app && xcodegen generate --spec project.yml

.PHONY: build
build: generate ## Debug build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DD) build

.PHONY: run
run: build ## Build and launch the app
	open "$(APP_DEBUG)"

# --- test and format -----------------------------------------------------------

$(DEV_VENV)/bin/python3: $(UV) python/requirements-dev.txt python/requirements.txt
	$(UV) venv --python 3.13 "$(DEV_VENV)"
	$(UV) pip install --python "$(DEV_VENV)/bin/python3" -r python/requirements-dev.txt
	@touch "$@"

.PHONY: dev-venv
dev-venv: $(DEV_VENV)/bin/python3 ## Set up a separate Python environment for testing

.PHONY: test
test: test-swift test-python ## Run every test

.PHONY: test-swift
test-swift: generate ## The Swift tests
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	  -derivedDataPath $(DD) \
	  -skip-testing:WhisperTranscriberTests/EngineIntegrationTests test

.PHONY: test-python
test-python: dev-venv ## The Python worker tests (pytest)
	cd python && "$(ROOT)/$(DEV_VENV)/bin/python3" -m pytest

.PHONY: test-python-slow
test-python-slow: dev-venv ## The real transcription tests (loads the model, slow)
	cd python && "$(ROOT)/$(DEV_VENV)/bin/python3" -m pytest -m slow -v

.PHONY: test-swift-slow
test-swift-slow: generate ## The Swift tests that run the real worker (needs the runtime)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	  -derivedDataPath $(DD) \
	  -only-testing:WhisperTranscriberTests/EngineIntegrationTests test

.PHONY: test-slow
test-slow: test-swift-slow test-python-slow ## Every slow test

.PHONY: icon
icon: ## Regenerate the app icon from scripts/make_icon.swift
	swift scripts/make_icon.swift --preview

.PHONY: strings
strings: build ## Update Localizable.xcstrings from the strings in the source
	@# Thanks to SWIFT_EMIT_LOC_STRINGS, the build produces one .stringsdata per Swift
	@# file. The Xcode UI merges those into the catalog itself; on the command line we do
	@# that step by hand with xcstringstool.
	@args=""; \
	for f in $$(find "$(DD)/Build/Intermediates.noindex/WhisperTranscriber.build/Debug/WhisperTranscriber.build" \
	            -name "*.stringsdata" | grep -v ExtractedAppShortcuts); do \
	  args="$$args --stringsdata $$f"; \
	done; \
	xcrun xcstringstool sync "$(CATALOG)" $$args
	@printf "keys in the catalog: "
	@python3 -c "import json,sys;print(len(json.load(open('$(CATALOG)'))['strings']))"

.PHONY: lint
lint: ## swift-format --lint + ruff
	xcrun swift-format lint --strict --recursive app/WhisperTranscriber scripts
	$(UV) tool run ruff check python
	$(UV) tool run ruff format --check python

.PHONY: format
format: ## Format the code (fixes in place)
	xcrun swift-format format --in-place --recursive app/WhisperTranscriber scripts
	$(UV) tool run ruff check --fix python
	$(UV) tool run ruff format python

# --- release -------------------------------------------------------------------

.PHONY: archive
archive: ## Release archive + export + Developer ID signature
	./scripts/archive.sh

.PHONY: sign
sign: ## Re-sign and verify the existing dist/export/.app
	./scripts/sign.sh

.PHONY: notarize
notarize: ## Notarize the .app + staple the ticket
	./scripts/notarize.sh

.PHONY: dmg
dmg: ## Build a signed + notarized + stapled .dmg (quarantine test included)
	./scripts/make_dmg.sh

.PHONY: notes
notes: ## Generate the release notes into dist/RELEASE_NOTES.md
	@mkdir -p dist
	./scripts/release_notes.sh > dist/RELEASE_NOTES.md
	@echo "wrote dist/RELEASE_NOTES.md"

.PHONY: appcast
appcast: ## Write the Sparkle appcast for the built dmg into dist/
	./scripts/make_appcast.sh

.PHONY: release
release: ## Full release: test -> archive -> notarize -> dmg -> appcast -> gh release (VERSION=x.y.z)
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 1; }
	./scripts/release.sh "$(VERSION)"

# --- cleanup ----------------------------------------------------------------

.PHONY: clean
clean: ## Delete the build output
	rm -rf build dist app/WhisperTranscriber.xcodeproj

.PHONY: clean-runtime
clean-runtime: ## Delete the isolated Python runtime (~900 MB comes back)
	rm -rf "$(RUNTIME)"
	@echo "deleted. ~/.cache/whisper was left alone."

.PHONY: doctor
doctor: ## Audit the environment
	@echo "xcodebuild : $$(xcodebuild -version | head -1)"
	@echo "swift      : $$(swift --version 2>&1 | head -1)"
	@echo "xcodegen   : $$(xcodegen --version)"
	@echo "uv         : $$(test -x $(UV) && $(UV) --version || echo 'missing — make bootstrap')"
	@echo "runtime    : $$(test -f "$(RUNTIME)/runtime.json" && echo ready || echo 'missing — make provision')"
	@echo "signature  : $$(security find-identity -v -p codesigning | grep 'Developer ID' | head -1 || echo missing)"
	@echo "gh         : $$(gh auth status >/dev/null 2>&1 && echo 'logged in' || echo 'not logged in — gh auth login')"
	@echo "notary     : $$(xcrun notarytool history --keychain-profile WHISPER_NOTARY >/dev/null 2>&1 && echo 'WHISPER_NOTARY ok' || echo 'missing — docs/BUILD_AND_RELEASE.md')"
	@echo "sparkle    : $$(test -x vendor/sparkle/bin/sign_update && echo "tools $$(cat vendor/sparkle/.version 2>/dev/null)" || echo 'missing — make bootstrap')"
	@echo "update key : $$(test -x vendor/sparkle/bin/generate_keys && vendor/sparkle/bin/generate_keys -p 2>/dev/null | tail -1 || echo 'unknown — make bootstrap')"
