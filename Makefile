# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Health8
# SPDX-License-Identifier: Apache-2.0

# Makefile — health8 (docs-only vertical root, docs-group CI lane)
#
# The vertical is design-stage: this repo carries the design corpus +
# brand assets only. No services, no compose, no build — the CI lane
# validates this Makefile and the repo hygiene.

SHELL := /bin/bash

.PHONY: help lint clean

help: ## Show this help
	@echo "health8 (docs-only vertical root)"
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

lint: ## static checks — the design corpus is present
	@test -d design || { echo "ERROR: design/ missing" >&2; exit 1; }

clean: ## remove .run .run/logs .tmp (docs-only vertical — no build artifacts)
	@rm -rf .run .run/logs .tmp
