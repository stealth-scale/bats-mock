# `make help` lists the targets. The tests run in ghcr.io/stealth-scale/bats-test, the
# image of the bats-test repository: bash at BASH_VERSION, bats-core at BATS_VERSION,
# kcov, with the checkout mounted read-only.
#
#   make test
#   make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
#   make test TARGET=tests/NAME.bats
#   make coverage
SHELL := bash
.DEFAULT_GOAL := help

RUNTIME      ?= podman
BASH_VERSION ?= 5.2
BATS_VERSION ?= 1.14.0
IMAGE        ?= ghcr.io/stealth-scale/bats-test:bash$(BASH_VERSION)-bats$(BATS_VERSION)
TARGET       ?= tests/
BATS_FLAGS   ?= --print-output-on-failure
COVERAGE_MIN ?= 0
PREFIX       ?= /usr/local
LIBDIR        = $(PREFIX)/lib/bats-mock

SOURCES = load.bash $(wildcard src/*.bash)
TESTS   = $(wildcard tests/*.bats)

# As the calling user, no network, no capabilities, checkout read-only. coverage/ is
# the one writable mount, for kcov's report. The image is its own init: Ctrl+C and
# `podman stop` end a run, kcov included.
RUN = $(RUNTIME) run --rm --network=none --cap-drop=ALL --security-opt=label=disable \
      --user $(shell id -u):$(shell id -g) $(if $(filter podman,$(RUNTIME)),--userns=keep-id) \
      --volume "$(CURDIR):/code:ro" --workdir /code

.PHONY: help test coverage test-host lint check shell install uninstall clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

test: ## Run TARGET in the image
	$(RUN) $(IMAGE) test $(BATS_FLAGS) --recursive $(TARGET)

coverage: ## Run TARGET under kcov; table per file, report in coverage/, floor COVERAGE_MIN
	rm -rf coverage && mkdir coverage
	$(RUN) --volume "$(CURDIR)/coverage:/code/coverage" $(IMAGE) coverage --min $(COVERAGE_MIN) $(COVERAGE_FLAGS) -- $(BATS_FLAGS) --recursive $(TARGET)

test-host: ## Run TARGET with the bats of this machine
	bats $(BATS_FLAGS) --recursive $(TARGET)

lint: ## Run shellcheck over the loader, the sources and the tests
	shellcheck $(SOURCES) $(TESTS)

check: lint test ## What CI runs

shell: ## A shell in the image
	$(RUN) --interactive --tty $(IMAGE) shell

install: ## Copy the library to $(LIBDIR), for `load` by absolute path
	install -d $(DESTDIR)$(LIBDIR)/src
	install -m 0644 load.bash $(DESTDIR)$(LIBDIR)/
	install -m 0644 src/*.bash $(DESTDIR)$(LIBDIR)/src/

uninstall: ## Remove the library from $(LIBDIR)
	rm -rf $(DESTDIR)$(LIBDIR)

clean: ## Remove the coverage report
	rm -rf coverage
