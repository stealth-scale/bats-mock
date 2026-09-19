# Contributing

## Getting set up

You need Bash 4 or later, [bats-core](https://github.com/bats-core/bats-core) 1.7.0 or
later, [ShellCheck](https://www.shellcheck.net) and GNU make.

```sh
sudo dnf install bats ShellCheck make      # Fedora
brew install bats-core shellcheck          # macOS, with Homebrew's bash on PATH
```

```sh
git clone git@github.com:stealth-scale/bats-mock.git
cd bats-mock
make check
```

## Before you open a pull request

```sh
make lint       # shellcheck over the loader, the sources, the tests and the scripts
make test       # the test suite
make coverage   # line coverage of src/, reported without a floor
make check      # what CI runs: lint, then test
```

CI runs `make check` on Ubuntu and macOS, against bats-core 1.7.0 and the latest release.

## A change to the framework

- Put the test in the group of `tests/mock.bats` it belongs to, and name it in the form the
  group uses: `area: case -> expectation`.
- A behaviour a user can observe has a test. `make coverage` reports the lines the suite
  never reached. Code the framework generates with `eval` is not measured.
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for a change a user
  would notice.

## Releasing

A release is a tag on `main`.

1. Move the `Unreleased` entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD`
   heading and add the compare link at the foot of the file.
2. Commit as `chore: release vX.Y.Z`.
3. `git tag -s vX.Y.Z -m vX.Y.Z && git push --follow-tags`.

The release workflow runs `make check` on the tag and publishes a GitHub release with the
changelog entry as its notes. A tag without a matching changelog entry fails the workflow.

## Conventions

Commit messages take the form `type(scope): summary`, as the standards for every stealth
repository set out at https://docs.stealthscale.io. This repository has one package, so the
scope is left out: `fix: restore a function with a body on one line`.

## Review

A pull request is reviewed by a maintainer of the stealth-scale organisation.
