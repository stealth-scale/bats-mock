# Contributing

## Getting set up

You need GNU make, [ShellCheck](https://www.shellcheck.net) and Podman or Docker.
`make test` pulls `ghcr.io/stealth-scale/bats-test`, the image of the
[bats-test](https://github.com/stealth-scale/bats-test) repository, at the bash and bats-core
versions it is given. For `make test-host`, install Bash 4.4 or later and
[bats-core](https://github.com/bats-core/bats-core) 1.7.0 or later.

```sh
git clone git@github.com:stealth-scale/bats-mock.git
cd bats-mock
make check
```

## Before you open a pull request

```sh
make lint       # shellcheck over the loader, the sources and the tests
make test       # the suite in the bats-test image; BASH_VERSION and BATS_VERSION pick the cell
make test-host  # the suite with the bash and bats of this machine
make coverage   # the suite under kcov: a table per file, report in coverage/
make check      # what CI runs: lint, then test
```

`RUNTIME=docker` selects Docker. The default is Podman. `TARGET` selects one test file.

CI runs `make lint`, `make test` for bash 4.4, 5.1, 5.2 and 5.3 against bats-core 1.7.0 and
1.14.0, and `make test-host` on Ubuntu and macOS with both bats-core versions.

## A change to the framework

- Put the test in the group of `tests/mock.bats` it belongs to, and name it in the form the
  group uses: `area: case -> expectation`.
- A behaviour a user can observe has a test.
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for a change a user
  would notice.

## Releasing

A release is a tag on `main`.

1. Move the `Unreleased` entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD`
   heading and add the compare link at the foot of the file.
2. Commit as `chore: release vX.Y.Z`.
3. `git tag -s vX.Y.Z -m vX.Y.Z && git push --follow-tags`.

The release workflow runs the full CI matrix on the tag and publishes a GitHub release with the
changelog entry as its notes. A tag without a matching changelog entry fails the workflow.

## Conventions

Commit messages take the form `type(scope): summary`, as the standards for every stealth
repository set out at https://docs.stealthscale.io. This repository has one package, so the
scope is left out: `fix: restore a function with a body on one line`.

## Review

A pull request is reviewed by a maintainer of the stealth-scale organisation.
