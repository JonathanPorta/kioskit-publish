# kioskit-publish — the command surface. CI and operators call these targets,
# never the underlying scripts. A target is public iff it carries a `## `
# description, so `make help` is the contract.
#
# Everything here is offline except `sync-scripts` (fetches the pinned blessed
# public script export). Needs bash, jq, mikefarah yq v4, OpenSSL >= 3
# (macOS: set OPENSSL_BIN to Homebrew's openssl), shellcheck and actionlint.
.DEFAULT_GOAL := help
SHELL := bash

OWN_SCRIPTS := $(wildcard scripts/*.sh test/*.sh test/lib/*.sh)

.PHONY: help check test lint contract surfaces verify-scripts sync-scripts clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check: verify-scripts lint contract surfaces test ## Everything CI runs: scripts, lint, workflow contract, surface, tests
	@echo "make check: OK"

lint: ## shellcheck this repo's scripts and actionlint the workflows
	shellcheck -x $(OWN_SCRIPTS)
	actionlint

contract: ## Workflow, pin and provenance contract (AC-6, AC-15, AC-16)
	bash test/workflow-contract.test.sh

surfaces: ## release-surfaces.yaml declares the AC-14 surface (BLESSED_CICD_DIR=… also runs blessed's validator)
	bash test/surfaces.test.sh

test: ## Behavioural tests: verify-before-run (AC-5), contract mutations (AC-6), mirror (AC-15..17)
	bash test/verify-publisher.test.sh
	bash test/contract-mutations.test.sh
	bash test/mirror.test.sh

verify-scripts: ## Check the vendored blessed signing scripts against their MANIFEST.sha256
	@cd scripts/signing && shasum -a 256 -c MANIFEST.sha256 >/dev/null && echo "scripts/signing v$$(cat VERSION): OK"

sync-scripts: ## Re-install scripts/signing from the pinned blessed public script export (network, gh)
	bash scripts/sync-blessed-export.sh

clean: ## Nothing is generated in the tree; tests use mktemp
	@echo "clean: nothing to remove"
