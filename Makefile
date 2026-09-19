# `make help` lists the targets. The tests run in tests/Containerfile: the official
# bash image at BASH_VERSION with bats-core BATS_VERSION, checkout mounted read-only.
#
#   make test
#   make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
#   make test TARGET=tests/mock.bats
SHELL := bash
.DEFAULT_GOAL := help

RUNTIME      ?= podman
BASH_VERSION ?= 5.2
BATS_VERSION ?= 1.14.0
IMAGE        ?= bats-mock-test:$(BASH_VERSION)-bats$(BATS_VERSION)
TARGET       ?= tests/
BATS_FLAGS   ?= --print-output-on-failure
PREFIX       ?= /usr/local
LIBDIR        = $(PREFIX)/lib/bats-mock

SOURCES = load.bash $(wildcard src/*.bash)
TESTS   = $(wildcard tests/*.bats)

# As the calling user, no network, no capabilities. --init lets Ctrl+C stop the run.
RUN = $(RUNTIME) run --rm --init --network=none --cap-drop=ALL --security-opt=label=disable \
      --user $(shell id -u):$(shell id -g) $(if $(filter podman,$(RUNTIME)),--userns=keep-id) \
      --volume "$(CURDIR):/code:ro" --workdir /code

.PHONY: help build test test-host lint check shell install uninstall

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

build: ## Build the test image for BASH_VERSION and BATS_VERSION
	$(RUNTIME) build -q -f tests/Containerfile --build-arg BASH_VERSION=$(BASH_VERSION) --build-arg BATS_VERSION=$(BATS_VERSION) -t $(IMAGE) tests/

test: build ## Run TARGET in the container
	$(RUN) $(IMAGE) bats $(BATS_FLAGS) --recursive $(TARGET)

test-host: ## Run TARGET with the bats of this machine
	bats $(BATS_FLAGS) --recursive $(TARGET)

lint: ## Run shellcheck over the loader, the sources and the tests
	shellcheck $(SOURCES) $(TESTS)

check: lint test ## What CI runs

shell: build ## A shell in the test image
	$(RUN) --interactive --tty --entrypoint bash $(IMAGE)

install: ## Copy the library to $(LIBDIR), for `load` by absolute path
	install -d $(DESTDIR)$(LIBDIR)/src
	install -m 0644 load.bash $(DESTDIR)$(LIBDIR)/
	install -m 0644 src/*.bash $(DESTDIR)$(LIBDIR)/src/

uninstall: ## Remove the library from $(LIBDIR)
	rm -rf $(DESTDIR)$(LIBDIR)
