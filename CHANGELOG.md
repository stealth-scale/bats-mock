# Changelog

Every change a user would notice is recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `mock`, `unmock`, `mock_spy`, `mock_sequence`, `mock_strict_mode` and `mock_debug`.
- Glob and `~` regex argument patterns, matched newest rule first.
- Strict mode: a call that matches no rule returns 127.
- Stdin capture per call, with `assert_stdin_equals` and `assert_stdin_at_index`.
- Assertions on presence, count, arguments, exact arguments, index, substring and call
  order across mocks.
- `load.bash` as the entry point for `load` and `bats_load_library`.
- A test suite of 146 cases.

[Unreleased]: https://github.com/stealth-scale/bats-mock/commits/main
