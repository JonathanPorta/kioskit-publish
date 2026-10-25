# kioskit-publish — the command surface (blessed makefile.core@1). CI and
# operators call these targets, never the underlying scripts. A target is
# public iff it carries a `## ` description, so `make help` is the contract.
#
# Everything here is offline except `sync-scripts` (fetches the pinned blessed
# public script export). Needs bash, git, jq, mikefarah yq v4, OpenSSL >= 3
# (macOS: set OPENSSL_BIN to Homebrew's openssl), shellcheck and actionlint.
# blessed's validate-surfaces.sh needs yq EXACTLY 4.53.2: set YQ_BIN to it.
.DEFAULT_GOAL := help
SHELL := bash

OWN_SCRIPTS := $(wildcard scripts/*.sh test/*.sh test/lib/*.sh)
TOOLS := bash git jq yq openssl shellcheck actionlint

.PHONY: help deps install dev format check test build docs clean \
	lint contract surfaces manifest verify-scripts sync-scripts

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

deps: ## Check the toolchain (bash git jq yq openssl>=3 shellcheck actionlint); installs nothing
	@missing=0; for t in $(TOOLS); do command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; done; \
	"$${OPENSSL_BIN:-openssl}" version | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])' || { echo "need OpenSSL >= 3 (set OPENSSL_BIN)"; missing=1; }; \
	yq --version | grep -q mikefarah || { echo "need mikefarah yq v4"; missing=1; }; \
	"$${YQ_BIN:-yq}" --version | grep -q 'version v4.53.2$$' || { echo "need YQ_BIN = mikefarah yq 4.53.2 (blessed validate-surfaces.sh)"; missing=1; }; \
	[ $$missing -eq 0 ] && echo "deps OK"

install: deps ## Developer setup: verify the toolchain (no hooks or local tools are installed)
	@echo "install: nothing further to install; see README (Development)."

dev: ## No interactive loop: there is no server; use `make check test`
	@echo "dev: nothing to run locally; 'make check test' exercises the workflows offline."

format: ## No automatic formatter is configured; shellcheck runs in check
	@echo "format: nothing to rewrite; style is enforced by 'make check' (shellcheck, actionlint)."

check: verify-scripts lint contract surfaces manifest ## Static checks: signed scripts, lint, workflow contract, surface, blessed.yml
	@echo "make check: OK"

test: ## Behavioural tests: verify-before-run, contract and export mutations, mirror and resume
	bash test/verify-publisher.test.sh
	bash test/contract-mutations.test.sh
	bash test/export-verify.test.sh
	bash test/mirror.test.sh
	bash test/mirror-resume.test.sh
	@echo "make test: OK"

build: ## Nothing to build: the publisher is mirrored from kioskd's signed releases by mirror.yml
	@echo "build: no build output; binaries come from kioskd releases via .github/workflows/mirror.yml."

docs: ## Validate the docs: every relative link in the top-level Markdown resolves
	@rc=0; for f in *.md; do \
	  for l in $$(grep -oE '\]\([^)]+\)' "$$f" | sed -E 's/^\]\(//; s/\)$$//; s/#.*//' | grep -v -e '://' -e '^mailto:' -e '^$$' | sort -u); do \
	    [ -e "$$l" ] || { echo "$$f: broken link $$l"; rc=1; }; \
	  done; \
	done; if [ $$rc -eq 0 ]; then echo "docs: all relative links resolve"; fi; exit $$rc

clean: ## Nothing is generated in the tree; tests use mktemp
	@echo "clean: nothing to remove"

# Internal (called by check).
lint:
	shellcheck -x $(OWN_SCRIPTS)
	actionlint

contract:
	bash test/workflow-contract.test.sh

surfaces:
	bash test/surfaces.test.sh

manifest:
	bash test/blessed-manifest.test.sh

verify-scripts: ## Verify the vendored blessed files against the signed export manifest (offline)
	bash scripts/verify-export.sh

sync-scripts: ## Re-install the vendored blessed files from the pinned public script export (network, gh)
	bash scripts/sync-blessed-export.sh
