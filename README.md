# bats-mock

Mocks, spies and call assertions for [bats-core](https://github.com/bats-core/bats-core). A
mock replaces a command or function with rules that match its arguments. Every call is
logged with its arguments and its stdin, and the assertions read that log.

```bash
setup()    { mock_setup; }
teardown() { mock_teardown; }

@test "deploy syncs the release and restarts the service once" {
    mock rsync "*"          "echo synced"
    mock ssh   "~restart"   "return 0"
    mock curl  "*"          "printf '%s' '{\"ok\":true}'"

    run deploy v1.2.0

    assert_called_once_with ssh "web01 systemctl restart app"
    refute_called_with ssh "*reboot*"
    assert_call_sequence "rsync" "ssh" "curl"
}
```

## Install

Add the repository as a submodule next to your tests and load it:

```sh
git submodule add https://github.com/stealth-scale/bats-mock tests/helpers/bats-mock
```

```bash
load 'helpers/bats-mock/load'
```

`load.bash` is the entry point, so `bats_load_library bats-mock` works as well when the
repository is on `BATS_LIB_PATH`. `make install` copies the library to
`/usr/local/lib/bats-mock` for a system-wide `load`.

Requirements: Bash 4 or later and bats-core 1.4.0 or later. Call `mock_setup` in `setup()` and
`mock_teardown` in `teardown()`. The test suite runs on Bash 5 with bats-core 1.7.0 and
1.14.0.

## Mocking a command

```bash
mock COMMAND [PATTERN] [ACTION]
```

`mock` defines a shell function named `COMMAND`. The function logs the call, finds the
first rule whose pattern matches the arguments, and evaluates that rule's action.

- `PATTERN` is matched against the arguments joined by single spaces. It is a glob by
  default. A leading `~` makes it an extended regex. The default is `*`.
- `ACTION` is shell code. It runs inside the mock, so `$1`, `$@` and `$#` are the call's
  arguments and its return code is the mock's. The default is `true`.
- Rules are matched newest first. A later `mock` for the same command overrides an earlier
  one where both match.
- A call that matches no rule prints `MOCK ERROR: 'COMMAND' called with unexpected args`
  and returns 127. `mock_strict_mode 0` makes it return 0 silently instead.
- A command name may contain letters, digits, `.`, `_`, `:` and `-`. The framework's own
  names (`mock`, `unmock`, `mock_*` and `mock::internal::*`) are refused.
- When `COMMAND` was a function, `mock` saves it and `unmock` restores it.

```bash
mock_spy COMMAND
```

Logs every call and then runs the original: the saved function when there was one, the
binary through `command` otherwise.

```bash
mock_sequence COMMAND PATTERN ACTION...
```

The first call that matches runs the first action, the second call the second, and so on.
The last action repeats. The counter is guarded by a lock, so calls from parallel subshells
take distinct actions.

```bash
unmock COMMAND
mock_strict_mode 0|1
mock_debug [FD]
```

`unmock` removes the function, its rules and its logs. `mock_debug` prints every mock with
its rules and its calls, to fd 3 when bats provides it and to stderr otherwise.

## Stdin

A mock copies its stdin to a per-call log while the action runs, so an action can read
stdin and the test can assert what was piped in. The copy is ended after the action returns,
which keeps `yes | mocked_cmd` from hanging.

## Assertions

Every assertion returns 0 on success. On failure it prints a framed report with the
command, the expectation and the actual value or the call history, and returns 1.

| Assertion                                    | Passes when                                                   |
| -------------------------------------------- | ------------------------------------------------------------- |
| `assert_called CMD`                          | `CMD` was called at least once                                |
| `refute_called CMD`                          | `CMD` was never called                                        |
| `assert_called_times CMD N`                  | `CMD` was called exactly `N` times                            |
| `assert_called_with CMD PATTERN...`          | one call's arguments match `PATTERN`                          |
| `assert_called_once_with CMD PATTERN...`     | there was exactly one call and it matches `PATTERN`           |
| `refute_called_with CMD PATTERN...`          | no call's arguments match `PATTERN`                           |
| `assert_called_exact CMD ARGS...`            | one call's arguments equal `ARGS` character for character     |
| `refute_called_exact CMD ARGS...`            | no call's arguments equal `ARGS`                              |
| `assert_called_at_index CMD I PATTERN...`    | the arguments of call `I` (from 0) match `PATTERN`            |
| `assert_args_contain CMD TEXT`               | one call's arguments contain `TEXT`                           |
| `assert_stdin_equals CMD TEXT`               | one call received `TEXT` on stdin                             |
| `assert_stdin_at_index CMD I TEXT`           | call `I` received `TEXT` on stdin                             |
| `assert_call_sequence "CMD ARGS"...`         | the calls appear in this order across all mocks, with other calls allowed between them |

A `PATTERN` is joined from the words after the command name and matched against the logged
arguments. It is a glob by default, a regex with a leading `~`, and a literal string with a
leading `=`. `assert_called_at_index` takes the glob and regex forms only. Newlines in
arguments are logged as `<newline>`, and a pattern with a newline is converted the same way
before it is compared.

```
================================================================================
  MOCK ASSERTION FAILED: Argument Mismatch
================================================================================
  Command    : ssh
  Expected   : Call matching: '*reboot*'
  History    :
    1. web01 uptime
    2. web01 systemctl restart app
================================================================================
```

## Configuration

| Variable               | Default                         | What it is                                               |
| ---------------------- | ------------------------------- | -------------------------------------------------------- |
| `BATS_MOCK_TMPDIR`     | `$BATS_TEST_TMPDIR`, else `/tmp` | Where the state directory is created                     |
| `BATS_MOCK_STATE_DIR`  | `$BATS_MOCK_TMPDIR/mocks`       | Rules and logs, one set of files per mocked command      |
| `BATS_MOCK_GLOBAL_LOG` | `$BATS_MOCK_STATE_DIR/global.log` | Every call across all mocks, in order, with a timestamp |
| `BATS_MOCK_STRICT`     | `1`                             | `1` fails an unmatched call with 127; `0` lets it return 0 |

Set a variable before the library is loaded to change it. `mock_teardown` deletes the state
directory and unsets the rule variables the framework exported.

## Working here

```sh
make check      # shellcheck, then the test suite
make test       # the suite alone; BATS_FLAGS and BATS override the defaults
make lint       # shellcheck over the loader, the sources, the tests and the scripts
make coverage   # line coverage of src/ under the suite
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## License

[MIT](LICENSE). Copyright Stealth Scale B.V.
