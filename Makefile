# AWS CLI Helpers — development targets
# Requires: shellcheck (brew install shellcheck), bash

SHELL := /bin/bash
SCRIPTS := main.sh session.sh services/ec2.sh services/ecs.sh

.PHONY: shellcheck test ci help

help:
	@echo "Targets: shellcheck, test, ci"

shellcheck: ## Run Shellcheck on Bash scripts (excludes Expect)
	shellcheck -x $(SCRIPTS)

test: ## Run smoke tests (no AWS credentials required)
	@bash "$(CURDIR)/test/run.sh"

ci: shellcheck test ## Run all CI checks
