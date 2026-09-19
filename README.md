# bats-mock

A mocking framework for [bats-core](https://github.com/bats-core/bats-core), combining
argument-driven mocks, call-through spies, response sequences, stdin capture and
interaction assertions in one helper. Define how dependencies behave, run your code,
and verify its interactions with failure reports that show what actually happened.

Use it to unit-test Bash libraries and command orchestration: deployment steps, retries,
pipelines and functions with shell-side effects. No changes to the code under test are
needed when it calls dependencies by name through Bash's normal command lookup.

## Why bats-mock

Choose it when your Bats tests need argument-matching rules, spies that run the original
function, stdin verification and call ordering across commands. Mocks, spies and response
sequences share the same recording and assertion API; your test runner remains Bats.

- **Describe behavior with rules.** Match arguments using globs or extended regexes,
  override defaults with more specific rules, and return output, failures or shell-side
  effects. Unmatched calls fail by default. Rules define behavior; assertions separately
  define the expected interactions.
- **Choose what to replace and what to observe.** `mock` replaces behavior, while
  `mock_spy` records calls and runs the original. Both use the same assertions. Direct
  function calls retain variable and directory changes in the calling shell.
- **Model changes across calls.** `mock_sequence` expresses retries, transient failures
  and changing responses. Its disk-backed counter survives subshells and uses locking to
  allocate successive responses to concurrent callers.
- **Verify more than output.** Assert call counts, argument patterns or exact argument
  boundaries, stdin payloads, individual history entries and order across commands.
  Records survive Bats `run`, so verification happens naturally after execution.
- **Catch mistakes in the test itself.** Command-specific assertions reject unregistered
  names, including negative assertions. Invalid regexes fail immediately. A typo must
  not silently turn a "never called" assertion green.
- **Get context when a test fails.** Assertions report the command, expectation and
  recorded values or history. `mock_debug` exposes rules and calls when diagnosing a test;
  tests do not need to parse the library's log files themselves.

These features work together: a retry test can sequence a failure and a success, inspect
both calls, verify the uploaded payload and check that a later restart happened afterward.
The comparison below shows which parts other helpers provide directly and which need
custom test code.

## Comparison with other Bats mocking libraries

These projects share a name, but expose different testing APIs. The table
compares built-in behavior; "custom action" means the test must supply that behavior.

| Capability | This library (`stealth-scale/bats-mock`) | [jasonkarns/bats-mock](https://github.com/jasonkarns/bats-mock) | [grayhemp/bats-mock](https://github.com/grayhemp/bats-mock) |
| --- | --- | --- | --- |
| Testing model | Behavior rules plus post-call interaction assertions | Expected call plans checked by `stub` / `unstub` | Configure a mock program and query its recorded calls |
| Argument-based behavior | Glob or extended regex over joined arguments; newest rule wins | Per-argument glob patterns in a call plan | Custom side-effect code |
| Successive responses | `mock_sequence`; final action repeats | Ordered `stub` plan; `stub_repeated` for reusable rules | Output, status and side effects configurable by call number |
| Call-through spies | `mock_spy` for functions and external commands | Custom forwarding action | Custom forwarding side effect |
| Verification | Assertions for counts, arguments, stdin and cross-command order | Plan matching, with final verification in `unstub` | Getters for counts and recorded call properties |
| Stdin recording | Built-in capture and text assertions | Custom action | Custom side effect |
| Existing Bash functions | Replace, spy on, and restore with `unmock` | Must unset a shadowing function to reach the executable | Requires routing calls to the generated executable |
| Caller-shell variable and directory changes | Preserved on direct calls | Actions run in a separate process | Side effects run in a separate process |
| Recorded environment and user | No built-in snapshot API | No built-in snapshot API | Per-call environment and user getters |
| Interception | Named Bash function | Stub executable on `PATH` | Generated executable path supplied to the code under test |

Comparison checked against the upstream READMEs and implementations:
[jasonkarns's stub API](https://github.com/jasonkarns/bats-mock/blob/main/stub.bash),
[its argument matcher](https://github.com/jasonkarns/bats-mock/blob/main/binstub), and
[grayhemp's implementation](https://github.com/grayhemp/bats-mock/blob/master/src/bats-mock.bash).
This is a comparison of testing models, not a performance ranking or a drop-in
compatibility claim.

### Compared with bashunit

[bashunit](https://github.com/TypedDevs/bashunit) is a complete test framework, not another
Bats helper. It already includes mocks, sequences, call assertions and failure histories;
those features alone are not unique to this library.

| Area | This library | bashunit |
| --- | --- | --- |
| Argument-based behavior | Glob/regex rules with newest-first precedence | Branch inside a replacement implementation |
| Default spy behavior | Record and call the saved original function or real command | Record without calling the original; an implementation can be supplied |
| Response sequences | Final action repeats; counter updates are locked | Final response repeats |
| Argument boundaries | Dedicated assertions for any call or a zero-based index | Dedicated assertion for the last call |
| Unregistered assertion targets | Rejected, including negative checks | Rejected for spy assertions |
| Stdin | Capture, payload assertions and an explicit completeness assertion | No corresponding built-in API documented |
| Cross-command order | Shared invocation history and sequence assertion | No corresponding built-in assertion documented |

See bashunit's [test-double documentation](https://github.com/TypedDevs/bashunit/blob/main/docs/test-doubles.md)
and [spy implementation](https://github.com/TypedDevs/bashunit/blob/main/src/doubles/spy.sh).
Choose between full frameworks on their wider requirements; this helper is for projects
that want these mocking features within Bats.

### How interception works

Mocks are Bash functions that shadow a command or replace an existing function, including
names such as `package::install`. Rules, call history and sequence state are stored under
a per-test directory. `unmock` restores a saved original function.

Actions run in the calling shell; Bats `run`, command substitution and pipelines still
have their normal subshell behavior. This is not a process sandbox. An executable-based
helper may fit better when the code under test needs fake programs on `PATH` rather than
Bash function interception. See [Boundaries to keep in mind](#boundaries-to-keep-in-mind).

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

The [CI matrix](.github/workflows/ci.yml) tests Bash 4.4, 5.1, 5.2 and 5.3 with bats-core
1.7.0 and 1.14.0, plus host runs on Linux and macOS. This is a Bash library, not a POSIX
`sh` library; Bash 4.4 or newer is required, so macOS's bundled Bash 3.2 is not supported.
Runtime helpers such as `tee`, `awk`, `cmp` and `mktemp` must also be available.

## Quick start

Save this as `tests/deploy.bats` after installing the helper at the path above. The
function under test is included so the example runs as written; in a project, source
your own implementation instead.

```bash
load 'helpers/bats-mock/load'

setup()    { mock_setup; }
teardown() { mock_teardown; }

deploy() {
    rsync -a "releases/$1/" web01:/srv/app/ || return
    ssh web01 systemctl restart app || return
    curl --fail https://web01/health
}

@test "deploy: release -> syncs, restarts and checks health" {
    mock rsync '-a releases/v1.2.0/ web01:/srv/app/' 'return 0'
    mock ssh 'web01 systemctl restart app' 'return 0'
    mock curl '--fail https://web01/health' 'printf "%s" "healthy"'

    run deploy v1.2.0

    [ "$status" -eq 0 ]
    [ "$output" = healthy ]
    assert_called_once_with rsync '-a releases/v1.2.0/ web01:/srv/app/'
    assert_called_once_with ssh 'web01 systemctl restart app'
    assert_called_once_with curl '--fail https://web01/health'
    assert_call_sequence 'rsync' 'ssh' 'curl'
}
```

Run it with `bats tests/deploy.bats`. No SSH connection, file transfer or HTTP request is
made: all three dependencies are mocked. The assertions here are provided by this library;
`bats-assert` is not required.

## Mocking a command

```bash
mock COMMAND [PATTERN] [ACTION]
```

`mock` defines a shell function named `COMMAND`. The function logs the call, finds the
first rule whose pattern matches the arguments, and evaluates that rule's action.

- `PATTERN` is matched against the arguments joined by single spaces. It is a glob by
  default. A leading `~` makes it an extended regex. The default is `*`. An invalid regex
  is rejected at registration, without replacing existing rules.
- `ACTION` is shell code. It runs inside the mock, so `$1`, `$@` and `$#` are the call's
  arguments and its return code is the mock's. The default is `true`.
- Rules are matched newest first. A later `mock` for the same command overrides an earlier
  one where both match.
- A call that matches no rule prints `MOCK ERROR: 'COMMAND' called with unexpected args`
  and returns 127. `mock_strict_mode 0` makes it return 0 silently instead.
- A command name may contain letters, digits, `.`, `_`, `:` and `-`. The framework's own
  API and internal names are reserved.
- When `COMMAND` was a function, `mock` saves it and `unmock` restores it.

Quote actions with single quotes when their variables should expand at call time:

```bash
mock lookup '*' 'printf "unknown: %s\n" "$1"'
mock lookup 'admin' 'printf "administrator\n"'
```

The second rule handles `lookup admin`; the first handles everything else. A catch-all
rule also accepts unexpected arguments, so omit it when only specific calls are allowed.
Strict mode returns a failure status; it does not force a test to fail if the code under
test ignores that status. Check `run`'s `$status` and assert the expected interactions.

### Spying on real behavior

```bash
mock_spy COMMAND
```

Logs every call and then runs the original: the saved function when there was one, the
command through `command` otherwise. A spy keeps real behavior, including side effects
and failures; it does not make network or filesystem operations safe.

With the same `setup` and `teardown` as above:

```bash
@test "spy: direct call -> retains the function's side effects" {
    selected_release=old
    select_release() { selected_release=$1; }
    mock_spy select_release

    select_release v1.2.0

    [ "$selected_release" = v1.2.0 ]
    assert_called_once_with select_release v1.2.0
    unmock select_release
}
```

Call the function directly when checking shell-state changes. `run select_release v1.2.0`
would execute in a subshell: the call history would survive, but the variable change would
not reach the test's shell.

### Sequencing responses

```bash
mock_sequence COMMAND PATTERN ACTION...
```

The first call that matches runs the first action, the second call the second, and so on.
The last action repeats. The counter is guarded by a lock, so calls from parallel subshells
advance the sequence without losing increments. Action completion order is not guaranteed.

```bash
@test "retry: temporary failure -> succeeds on the second attempt" {
    mock_sequence fetch_release '*' 'return 1' 'printf "%s" "ready"'
    retry_fetch() { fetch_release || fetch_release; }

    run retry_fetch

    [ "$status" -eq 0 ]
    [ "$output" = ready ]
    assert_called_times fetch_release 2
}
```

### Cleanup and debugging

```bash
unmock COMMAND
mock_strict_mode 0|1
mock_debug [FD]
```

`unmock` restores a saved function, or removes the wrapper to expose the original command
lookup again. It clears that mock's rules and per-command logs; the global history remains.
Use it after assertions if the original is needed again within a test.

`mock_teardown` restores registered original functions and removes wrappers, generated
helpers, rule variables and the owned state directory. Repeated teardown is harmless.
Repeated `mock_setup` in the same session retains rules and history instead of resetting
them. To start a fresh session, tear down first and then set up again.

Setup refuses to adopt an existing state directory. Teardown checks the session's recorded
path and ownership marker before removing anything; do not change `BATS_MOCK_STATE_DIR`
during an active session.
`mock_debug [FD]` prints rules and call history, using fd 3 when detected and stderr otherwise.

## Stdin

A mock forwards non-terminal stdin to its action while copying it to a per-call log.
Use an action that consumes the input when the test needs to verify the complete payload:

```bash
@test "upload: pipeline -> forwards and records the payload" {
    mock upload '*' 'command cat >/dev/null'
    send_payload() { printf 'release=v1.2.0\n' | upload; }

    run send_payload

    [ "$status" -eq 0 ]
    assert_called_once_with upload ''
    assert_stdin_equals upload $'release=v1.2.0\n'
    assert_stdin_complete upload 0
}
```

After the action returns, capture cleanup drains at most 65,536 additional characters for
up to 0.1 seconds, then terminates and reaps its capture process. An action that ignores
input or reads only a prefix may therefore leave a partial capture. This prevents the
capture process from waiting indefinitely for EOF; it is **not a timeout for the action**.
A spy on a command that itself blocks will still block.

`assert_stdin_complete CMD INDEX` requires capture to have reached EOF for that zero-based
call index. It fails for a partial capture, a call that was not captured, or a missing call.
Payload assertions compare what was captured; use the completeness assertion as well when
the whole stream matters. Argument and stdin indexes identify the same invocation even
when concurrent calls finish in a different order. Wait for those calls before asserting.

Stdin assertions compare text, including trailing newlines, not arbitrary binary data.
Terminal input is not captured. In pipelines with early-exiting consumers, normal shell
rules still apply: a producer can exit on SIGPIPE, and `pipefail` can make the pipeline fail.

## Assertions

Every assertion returns 0 on success. On failure it prints a framed report with the
command, the expectation and the actual value or the call history, and returns 1.
Command-specific assertions require a registered mock or spy, even for zero calls or
negative expectations. Perform them before `unmock` or `mock_teardown`.

| Assertion                                    | Passes when                                                   |
| -------------------------------------------- | ------------------------------------------------------------- |
| `assert_called CMD`                          | `CMD` was called at least once                                |
| `refute_called CMD`                          | `CMD` was never called                                        |
| `assert_called_times CMD N`                  | `CMD` was called exactly `N` times                            |
| `assert_called_with CMD PATTERN...`          | one call's arguments match `PATTERN`                          |
| `assert_called_once_with CMD PATTERN...`     | there was exactly one call and it matches `PATTERN`           |
| `refute_called_with CMD PATTERN...`          | no call's arguments match `PATTERN`                           |
| `assert_called_exact CMD ARGS...`            | one call's joined argument text equals joined `ARGS` literally |
| `refute_called_exact CMD ARGS...`            | no call's joined argument text equals joined `ARGS`           |
| `assert_called_with_args CMD [ARG...]`       | one call has exactly these argument boundaries and values   |
| `refute_called_with_args CMD [ARG...]`       | no call has exactly these argument boundaries and values    |
| `assert_called_at_index_with_args CMD I [ARG...]` | call `I` (from 0) has exactly these arguments             |
| `assert_called_at_index CMD I PATTERN...`    | the arguments of call `I` (from 0) match `PATTERN`            |
| `assert_args_contain CMD TEXT`               | one call's arguments contain `TEXT`                           |
| `assert_stdin_equals CMD TEXT`               | one call received `TEXT` on stdin                             |
| `assert_stdin_at_index CMD I TEXT`           | call `I` received `TEXT` on stdin                             |
| `assert_stdin_complete CMD I`               | capture reached EOF for call `I` (from 0)                    |
| `assert_call_sequence "CMD ARGS"...`         | the calls appear in this order across all mocks, with other calls allowed between them |

A `PATTERN` is joined from the words after the command name and matched against the logged
arguments. It is a glob by default, a regex with a leading `~`, and a literal string with a
leading `=`. `assert_called_at_index` takes the glob and regex forms only. Matching uses
the original text: physical newlines and the literal text `<newline>` are distinct.

The `*_with_args` assertions compare individual arguments without joining or evaluating
them. Omitting `ARG...` means zero arguments; passing `''` means one empty argument:

```bash
@test "arguments: spaces -> remain part of one argument" {
    mock notify '*' true
    notify 'release ready' '' 42

    assert_called_with_args notify 'release ready' '' 42
    assert_called_at_index_with_args notify 0 'release ready' '' 42
    refute_called_with_args notify release ready '' 42
}
```

`assert_call_sequence` checks an ordered subsequence, not the entire history. Its entries
are matched against complete records or prefixes ending at a space boundary, so `api`
does not match `api_v2`, and `git fetch` does not match `git fetcher`. Global log arguments
are shell-escaped. Pair sequence checks with argument and count assertions to reject extra
or different calls. Global history remains available after `unmock`.

Per-command assertion histories display at most ten entries, showing up to 240 characters
of each entry plus an ellipsis, and report the number of omitted calls. This display limit
does not truncate stored arguments or captured stdin. `mock_debug` can show the full
diagnostic logs.

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

## Boundaries to keep in mind

- **Function lookup is the interception boundary.** `command ssh`, `/usr/bin/ssh` and
  programs that launch their own executables bypass a function mock. Simple alphanumeric
  and underscore names are exported to child Bash processes that import functions;
  names containing `:`, `.` or `-` are not exported. They still work in the current shell
  and Bats `run` subshells. Defining a function after mocking it replaces the mock.
- **Pattern rules and joined-text assertions do not distinguish argument boundaries.**
  `tool "a b"` and `tool a b` both match the same joined text. This also applies to the
  existing `assert_called_exact` API. Use `assert_called_with_args` when boundaries matter.
- **Invocation order is not completion order.** History and call indexes are allocated
  under a lock before actions run. Sequence allocation has its own lock, so neither
  action completion nor sequence-response order is guaranteed to equal history order.
  Each invocation retains its own argument and stdin records.
- **Actions are trusted shell code.** They are evaluated in the test environment. Use
  `return`, not `exit`, to set an action's status without terminating the calling shell.

## Configuration

| Variable               | Default                         | What it is                                               |
| ---------------------- | ------------------------------- | -------------------------------------------------------- |
| `BATS_MOCK_TMPDIR`     | `$BATS_TEST_TMPDIR`, else `/tmp` | Where the state directory is created                     |
| `BATS_MOCK_STATE_DIR`  | `$BATS_MOCK_TMPDIR/mocks`       | Rules and logs, one set of files per mocked command      |
| `BATS_MOCK_GLOBAL_LOG` | `$BATS_MOCK_STATE_DIR/global.log` | Every call across all mocks, in order, with a timestamp |
| `BATS_MOCK_STRICT`     | `1`                             | `1` fails an unmatched call with 127; `0` lets it return 0 |

Set a variable before the library is loaded to change it. If overriding
`BATS_MOCK_STATE_DIR`, provide a unique path that does not yet exist; `mock_setup` creates
and owns it. `mock_teardown` deletes that directory after checking ownership. Do not put
unrelated files inside it or alter its `.owner` marker. A custom global log outside the
state directory is not deleted by teardown.

### Compatibility notes

Existing glob/regex rules and joined-text assertions keep their argument semantics. Tests
must now register a mock before making negative assertions, supply valid regexes, and let
`mock_setup` create the state directory. Sequence expectations no longer match partial
command or argument names. Use the new `*_with_args` assertions for argument boundaries.

## Working here

```sh
make test                                   # the suite in the bats-test image: bash 5.2, bats 1.14.0
make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
make test-host                              # the suite with the bash and bats of this machine
make coverage                               # the suite under kcov: a table per file, report in coverage/
make lint                                   # shellcheck over the loader, the sources and the tests
make check                                  # what CI runs: lint, then test
```

`RUNTIME=docker` selects Docker. The default is Podman. `TARGET` selects one test file.

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## License

[MIT](LICENSE). Copyright Stealth Scale B.V.
