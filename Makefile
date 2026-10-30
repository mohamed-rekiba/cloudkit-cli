# CloudKit CLI — development targets
# Requires: shellcheck (brew install shellcheck), bash

SHELL := /bin/bash
SCRIPTS := main.sh session.sh services/ec2.sh services/ecs.sh services/gce.sh services/gce_ig.sh

.PHONY: shellcheck test ci help

help:
	@echo "Targets: shellcheck, test, ci"

shellcheck: ## Run Shellcheck on Bash scripts (excludes Expect)
	shellcheck -x $(SCRIPTS)

test: ## Run all tests (smoke + auth + ec2; no AWS credentials required)
	@bash "$(CURDIR)/test/run.sh"
	@bash "$(CURDIR)/test/test_auth.sh"
	@bash "$(CURDIR)/test/test_ec2.sh"

ci: shellcheck test ## Run all CI checks
