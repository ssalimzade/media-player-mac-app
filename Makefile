# RezkaPlayer — developer convenience targets.
#
#   make            list every target
#   make doctor     check the toolchain before you start
#   make run        build the app (Debug) and launch it
#
# Architecture and conventions live in CLAUDE.md; the proxy / geo-blocking notes
# are in README.md. Nothing here is required to build — every target is a thin
# wrapper over xcodegen / xcodebuild / scripts/*.sh.

SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_NAME   := RezkaPlayer
ROOT       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
APP_DIR    := $(ROOT)/app
SIDECAR    := $(ROOT)/sidecar
PROJ       := $(APP_DIR)/$(APP_NAME).xcodeproj
VENV       := $(SIDECAR)/.venv
VENV_STAMP := $(VENV)/.deps.stamp
PY         := $(VENV)/bin/python3

# Build into the repo (app/.build is gitignored) so `make run` finds the app at a
# fixed path instead of globbing ~/Library/Developer/Xcode/DerivedData/RezkaPlayer-*.
# Xcode's own ⌘R still uses the default DerivedData location; the two don't collide.
CONFIG ?= Debug
DD     := $(APP_DIR)/.build
APP    := $(DD)/Build/Products/$(CONFIG)/$(APP_NAME).app

# Standalone-sidecar port for `make sidecar` / `make health`. The app itself always
# launches its own sidecar on an OS-assigned port — this is only for poking endpoints.
PORT ?= 8777

# xcodebuild is very chatty; VERBOSE=1 turns the full log back on.
QUIET := -quiet
ifdef VERBOSE
QUIET :=
endif

.PHONY: help doctor check-xcode check-xcodegen venv project build run xcode \
        sidecar health freeze dmg clean distclean

## ---------------------------------------------------------------- everyday

help: ## List available targets
	@echo "RezkaPlayer — make targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Variables: CONFIG=Debug|Release  PORT=$(PORT)  VERBOSE=1"

doctor: ## Check the toolchain (Xcode, xcodegen, python3)
	@echo "Toolchain check"
	@printf '  %-10s ' 'xcode'; \
	if xcodebuild -version >/dev/null 2>&1; then \
	  xcodebuild -version | head -1; \
	else \
	  echo "MISSING — active dir is $$(xcode-select -p)"; \
	  echo '             install Xcode from the App Store, then:'; \
	  echo '             sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'; \
	fi
	@printf '  %-10s ' 'xcodegen'; \
	if command -v xcodegen >/dev/null 2>&1; then xcodegen --version; \
	else echo "MISSING — brew install xcodegen"; fi
	@printf '  %-10s ' 'python3'; \
	if command -v python3 >/dev/null 2>&1; then python3 --version; \
	else echo "MISSING"; fi
	@printf '  %-10s ' 'venv'; \
	if [ -x "$(PY)" ]; then echo "ok ($(VENV))"; else echo "not created — make venv"; fi
	@printf '  %-10s ' 'xcodeproj'; \
	if [ -d "$(PROJ)" ]; then echo "ok"; else echo "not generated — make project"; fi

run: venv build ## Build the app and launch it
	@if pgrep -x $(APP_NAME) >/dev/null 2>&1; then \
	  echo "==> quitting running $(APP_NAME)"; \
	  osascript -e 'quit app "$(APP_NAME)"' >/dev/null 2>&1 || true; \
	  sleep 1; \
	fi
	@echo "==> launching $(APP)"
	@open "$(APP)"

build: check-xcode $(PROJ) ## Build the app (CONFIG=Debug|Release)
	@echo "==> building $(APP_NAME) ($(CONFIG))"
	@cd $(APP_DIR) && xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
	  -configuration $(CONFIG) -derivedDataPath "$(DD)" \
	  -destination 'platform=macOS' $(QUIET) build
	@echo "==> built $(APP)"

xcode: $(PROJ) ## Open the project in Xcode (⌘R to run)
	@open "$(PROJ)"

## ---------------------------------------------------------------- setup

venv: $(VENV_STAMP) ## Create the sidecar venv and install its deps

$(VENV_STAMP): $(SIDECAR)/requirements.txt
	@if [ ! -x "$(PY)" ]; then echo "==> creating venv"; python3 -m venv "$(VENV)"; fi
	@echo "==> installing sidecar deps"
	@"$(VENV)/bin/pip" install -q --upgrade pip
	@"$(VENV)/bin/pip" install -q -r $(SIDECAR)/requirements.txt
	@touch "$@"

project: $(PROJ) ## Regenerate RezkaPlayer.xcodeproj from app/project.yml

# project.yml is the source of truth; the .xcodeproj is gitignored and regenerated.
$(PROJ): $(APP_DIR)/project.yml | check-xcodegen
	@echo "==> xcodegen generate"
	@cd $(APP_DIR) && xcodegen generate

## ---------------------------------------------------------------- sidecar

sidecar: venv ## Run the sidecar standalone on PORT (manual API testing)
	@echo "==> sidecar on http://127.0.0.1:$(PORT)  (Ctrl-C to stop)"
	@cd $(SIDECAR) && "$(PY)" server.py --port $(PORT)

health: ## GET /health from a standalone sidecar (needs `make sidecar` running)
	@out=$$(curl -fsS "http://127.0.0.1:$(PORT)/health" 2>/dev/null) || { \
	  echo "no sidecar on 127.0.0.1:$(PORT) — start one with: make sidecar"; exit 1; }; \
	echo "$$out" | python3 -m json.tool

## ---------------------------------------------------------------- packaging

freeze: ## Freeze the sidecar with PyInstaller (sidecar/dist/)
	@$(ROOT)/scripts/build-sidecar.sh

dmg: check-xcode check-xcodegen ## Build the distributable DMG -> build/RezkaPlayer.dmg
	@$(ROOT)/scripts/package.sh

## ---------------------------------------------------------------- cleanup

clean: ## Remove build artifacts
	@rm -rf "$(DD)" "$(ROOT)/build" "$(SIDECAR)/build" "$(SIDECAR)/dist"
	@rm -f $(SIDECAR)/*.spec
	@echo "==> cleaned"

distclean: clean ## Also remove the venv and the generated xcodeproj
	@rm -rf "$(VENV)" "$(PROJ)"
	@echo "==> removed venv + xcodeproj"

## ---------------------------------------------------------------- guards

check-xcode:
	@xcodebuild -version >/dev/null 2>&1 || { \
	  echo "ERROR: full Xcode is required to build (active dir: $$(xcode-select -p))."; \
	  echo "  Install Xcode from the App Store, then:"; \
	  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
	  echo "  Or skip building: download the DMG from the GitHub releases page."; \
	  exit 1; }

check-xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || { \
	  echo "ERROR: xcodegen not found. Install it with:"; \
	  echo "    brew install xcodegen"; \
	  exit 1; }
