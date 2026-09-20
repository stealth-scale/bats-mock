# Changelog

Every change a user would notice is recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-09-20

### Changed

- Stdin capture is off unless a mock is registered with `-stdin`. `mock`, `mock_spy` and
  `mock_sequence` accept the flag, and `--` ends option parsing. Capture cost a temporary
  file, a `tee` child and a drain on every call. Under bats, stdin is a socket that never
  reports EOF, so the drain waited its full 0.1 second timeout on any mock that inherited
  it: a call cost 113 ms and now costs 5 ms. Set `BATS_MOCK_CAPTURE_STDIN=1` to restore
  the old behaviour for every mock. `assert_stdin_equals`, `assert_stdin_at_index` and
  `assert_stdin_complete` report that capture was not enabled instead of comparing against
  an empty record.
- A lock retries immediately sixteen times before it sleeps. A lock is held for
  microseconds, so sleeping 0.1 seconds on the first miss turned a brief overlap into a
  0.1 second stall. The test suite has 228 such waits and runs 4 seconds faster.
- A new rule no longer rebuilds the generated wrapper. The wrapper reads its rules at call
  time, so registering a second rule for a command publishes it and leaves the body alone.
- `mock::internal::sanitize_ref` writes through a nameref and memoises its result. The
  previous command substitution ran a subshell for every registration, compile and unmock.
- `mock::internal::require_session` reads the ownership marker without a subshell and
  resolves the session path once per session rather than on every call.

### Removed

- `mock::internal::sanitize`. Every caller now uses `mock::internal::sanitize_ref`.
- The rule reload inside `mock::jit::compile`. Rules are published as they are registered,
  and `unmock` and `mock_teardown` drop the rules file and the variables together, so
  rebuilding the rules from the file could not be reached.

## [1.0.1] - 2026-09-19

### Fixed

- `mock_spy` keeps the `function` keyword when it hides a definition written as
  `function name`. Such a function could not be spied on: the hidden copy did not
  compile and `mock_spy` returned 1.

## [1.0.0] - 2026-09-19

First tagged release.

### Added

- `mock`, `unmock`, `mock_spy`, `mock_sequence`, `mock_strict_mode` and `mock_debug`.
- Glob and `~` regex argument patterns, matched newest rule first.
- Strict mode: a call that matches no rule returns 127.
- Stdin capture per call, with `assert_stdin_equals`, `assert_stdin_at_index` and
  `assert_stdin_complete` to distinguish complete captures from partial ones.
- Assertions on presence, count, arguments, exact arguments, index, substring and call
  order across mocks.
- Argument-boundary assertions: `assert_called_with_args`, `refute_called_with_args` and
  `assert_called_at_index_with_args`, including empty arguments and embedded newlines.
- `load.bash` as the entry point for `load` and `bats_load_library`.
- A test suite of 217 cases, including streaming, concurrency and slow-lock regressions.
- Container tests on Bash 4.4, 5.1, 5.2 and 5.3 with bats-core 1.7.0 and 1.14.0, plus
  host tests on Ubuntu and macOS.

### Changed

Compatibility changes for users of earlier untagged revisions:

- Bash 4.4 or newer is required.
- Command-specific assertions require a registered mock or spy, including negative and
  zero-call assertions. Misspelled command names no longer pass silently.
- `mock_setup` requires a new, dedicated state directory. Repeated setup in the same
  session preserves its history; teardown removes only the directory owned by that session.
- Call-sequence assertions require an exact entry or a space-delimited prefix, so partial
  command names no longer match.

### Fixed

- Spies retain direct-call shell side effects and preserve the original command's status.
- Stream capture handles partial reads and open or infinite input without waiting forever
  after the action returns, and reaps only its own capture process.
- Per-call stdin records stay aligned with invocation indexes when calls finish out of order.
- Invalid regexes are rejected at registration and in assertions.
- Literal `<newline>` text is distinct from an actual newline in exact argument assertions.
- Lock timeouts account for command execution and scheduling overhead, including on macOS;
  stdin-log timeouts remove the temporary capture file.

[Unreleased]: https://github.com/stealth-scale/bats-mock/compare/v1.1.0...main
[1.1.0]: https://github.com/stealth-scale/bats-mock/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/stealth-scale/bats-mock/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/stealth-scale/bats-mock/releases/tag/v1.0.0
