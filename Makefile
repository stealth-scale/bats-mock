# Development targets. `make help` lists them.
SHELL := bash
.DEFAULT_GOAL := help

BATS         ?= bats
BATS_FLAGS   ?= --print-output-on-failure
SHELLCHECK   ?= shellcheck
COVERAGE_MIN ?= 0
PREFIX       ?= /usr/local
LIBDIR        = $(PREFIX)/lib/bats-mock

SOURCES = load.bash $(wildcard src/*.bash)
TESTS   = $(wildcard tests/*.bats)

.PHONY: help test lint check coverage install uninstall

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

test: ## Run the test suite
	$(BATS) $(BATS_FLAGS) $(TESTS)

lint: ## Run shellcheck over the loader, the sources, the tests and the scripts
	$(SHELLCHECK) $(SOURCES) $(TESTS) scripts/coverage

check: lint test ## What CI runs

coverage: ## Measure line coverage of src/ and fail under COVERAGE_MIN percent
	BATS=$(BATS) scripts/coverage $(COVERAGE_MIN)

install: ## Copy the library to $(LIBDIR), for `load` by absolute path
	install -d $(DESTDIR)$(LIBDIR)/src
	install -m 0644 load.bash $(DESTDIR)$(LIBDIR)/
	install -m 0644 src/*.bash $(DESTDIR)$(LIBDIR)/src/

uninstall: ## Remove the library from $(LIBDIR)
	rm -rf $(DESTDIR)$(LIBDIR)
