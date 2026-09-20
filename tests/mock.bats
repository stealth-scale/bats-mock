#!/usr/bin/env bats

# shellcheck disable=SC2030,SC2031  # every @test is its own process, not a subshell of the file

# ==============================================================================
# Stealth Mock Framework - Comprehensive Test Suite
# ==============================================================================
# Organized into the following groups:
#   01. Core Lifecycle (Registration, LIFO, Cleanup)
#   02. Argument Matching - Basic (Literal, Glob)
#   03. Argument Matching - Advanced (Regex, Whitespace, Unicode, Special Chars)
#   04. I/O & Side Effects (Stdio, Exit Codes, Files)
#   05. Interactions (Pipes, Recursion, Subshells, Arrays)
#   06. Spies & Unmocking
#   07. Sequences & Concurrency
#   08. Strict Mode & Compliance
#   09. Assertions - Presence & Frequency
#   10. Assertions - Arguments (With, Once With, Refute)
#   11. Assertions - History & Sequence
#   12. Assertions - Feedback & Debugging
#   13. Security & Safety (Injection, Reserved Names)
#   14. System & Configuration (Naming, config vars, Whitebox)
#   15. Error Handling & Edge Cases (Invalid inputs, Timeouts, Ambiguities)
#   16. Namespace Support
#   17. Assertions - Exact Matching
#   18. Edge Cases - Control Characters
#   19. Stdin Capturing & Assertions
#   20. Spy Regressions (Side Effects & Streaming)
# ==============================================================================

setup() {
    # Enforce Strict Mode for Tests
    set -Euoe pipefail

    # We check return codes on the run function
    bats_require_minimum_version 1.5.0

    # Robust Library Loading
    local lib_dir="$BATS_TEST_DIRNAME/../src"

    if [ -f "$lib_dir/mock.bash" ]; then
        load "$lib_dir/mock.bash"
    # Fallback to current dir if testing in-place
    elif [ -f "$BATS_TEST_DIRNAME/mock.bash" ]; then
        load "$BATS_TEST_DIRNAME/mock.bash"
    else
        echo "Error: Could not find mock.bash in '$BATS_TEST_DIRNAME' or '$lib_dir'" >&2
        return 1
    fi

    mock_setup
}

teardown() {
    mock_teardown
}

# Keep streaming regressions bounded on both Linux and macOS, including Bats 1.7.
# Separate process groups let the watchdog stop children that keep output FDs open.
run_with_timeout() {
    local seconds="$1"
    shift
    run bash -c '
        seconds=$1
        shift
        set -m
        "$@" &
        task_pid=$!
        (
            sleep "$seconds"
            printf "Test command exceeded %s seconds\n" "$seconds" >&2
            kill -KILL -- "-$task_pid" 2>/dev/null
        ) &
        timer_pid=$!
        # Disowned, so bash does not report "Killed" for it when it is stopped below.
        disown "$timer_pid"
        set +m
        result=0
        wait "$task_pid" 2>/dev/null || result=$?
        kill -KILL -- "-$task_pid" 2>/dev/null || :
        kill -KILL -- "-$timer_pid" 2>/dev/null || :
        wait "$timer_pid" 2>/dev/null || :
        exit "$result"
    ' _ "$seconds" "$@"
}

# Reproduce slow process/filesystem operations without changing the watchdog's
# sleep. Fifty retries now take at least 20 seconds; a five-second deadline must
# still expire within the 15-second safety watchdog.
slow_lock_attempts() {
    local lock_path="$1"
    local shim_dir="$BATS_TEST_TMPDIR/slow-lock-bin"
    local mkdir_bin
    mkdir_bin=$(type -P mkdir)
    mkdir -p "$shim_dir"
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # expanded when the shim runs
        printf 'if [[ ${@: -1} == %q ]]; then command sleep 0.3; fi\n' "$lock_path"
        printf 'exec %q "$@"\n' "$mkdir_bin"
    } > "$shim_dir/mkdir"
    chmod +x "$shim_dir/mkdir"
    export PATH="$shim_dir:$PATH"
}

# ==============================================================================
# GROUP 01: CORE MOCK LIFECYCLE
# ==============================================================================

@test "core: registration -> returns static output" {
    mock curl "http://example.com" "echo 'hello world'"
    run curl "http://example.com"
    [ "$output" = "hello world" ]
    [ "$status" -eq 0 ]
}

@test "core: defaults -> no action implies 'true' (exit 0)" {
    mock mycmd "*"
    run mycmd
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "core: independence -> multiple mocks operate without interference" {
    mock git "status" "echo 'clean'"
    mock npm "test" "echo 'passing'"

    run git status
    [ "$output" = "clean" ]
    run npm test
    [ "$output" = "passing" ]
}

@test "core: priority -> LIFO (newer rules override older)" {
    mock log "*" "echo 'generic'"
    mock log "error" "echo 'specific'"

    run log "info"
    [ "$output" = "generic" ]
    run log "error"
    [ "$output" = "specific" ]
}

@test "core: idempotency -> can define same rule twice without error" {
    mock git "status" "echo 'one'"
    mock git "status" "echo 'two'"

    run git status
    [ "$output" = "two" ]
}

@test "core: unmatched (permissive) -> returns 0 and empty output by default" {
    mock_strict_mode 0
    mock git "status" "echo 'clean'"
    run git checkout main
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "core: cleanup -> mock_teardown removes state directory" {
    mock git "*" "true"
    [ -d "$BATS_MOCK_STATE_DIR" ]

    mock_teardown
    [ ! -d "$BATS_MOCK_STATE_DIR" ]
}

@test "core: setup -> repeated setup retains rules and call history" {
    mock probe '*' true
    probe
    mock_setup
    assert_called_times probe 1
    assert_call_sequence probe
}

@test "core: lifecycle arguments -> rejects inputs without changing the owned session" {
    mock probe '*' true
    probe before
    local owner function_name
    owner=$(< "$BATS_MOCK_STATE_DIR/.owner")
    for function_name in mock_setup mock_teardown; do
        run "$function_name" unexpected
        [ "$status" -eq 1 ]
        [ "$output" = "MOCK ERROR: Usage: $function_name" ]
        [ "$(< "$BATS_MOCK_STATE_DIR/.owner")" = "$owner" ]
        assert_called_times probe 1
        assert_called_at_index_with_args probe 0 before
    done
    probe after
    assert_called_times probe 2
}

@test "core: teardown -> restores functions and removes generated helpers" {
    # shellcheck disable=SC2329  # restored, then invoked through run
    original() { echo original; }
    mock_spy original
    mock temporary '*' true
    mock_teardown
    run original
    [ "$status" -eq 0 ]
    [ "$output" = original ]
    run -1 declare -F temporary
    run -1 declare -F _BATS_MOCK_ACTION_original
    run -1 declare -F _BATS_MOCK_SPY_ORIGINAL_original
    mock_teardown
}

@test "core: ownership -> refuses an existing directory and preserves its files" {
    mock_teardown
    export BATS_MOCK_STATE_DIR="$BATS_TEST_TMPDIR/user-data"
    mkdir "$BATS_MOCK_STATE_DIR"
    printf keep > "$BATS_MOCK_STATE_DIR/important"
    run mock_setup
    [ "$status" -eq 1 ]
    [[ "$output" == *'new, dedicated directory'* ]]
    mock_teardown
    [ "$(< "$BATS_MOCK_STATE_DIR/important")" = keep ]
}

@test "core: ownership -> changing the configured path cannot redirect cleanup" {
    local owned_dir="$BATS_MOCK_STATE_DIR"
    export BATS_MOCK_STATE_DIR="$BATS_TEST_TMPDIR"
    printf keep > "$BATS_TEST_TMPDIR/important"
    run mock_teardown
    [ "$status" -eq 1 ]
    [ "$(< "$BATS_TEST_TMPDIR/important")" = keep ]
    [ -d "$owned_dir" ]
    export BATS_MOCK_STATE_DIR="$owned_dir"
}

@test "core: ownership -> refuses a replaced directory symlink" {
    local owned_dir="$BATS_MOCK_STATE_DIR"
    mv "$owned_dir" "$owned_dir.saved"
    ln -s "$BATS_TEST_TMPDIR" "$owned_dir"
    run mock_teardown
    [ "$status" -eq 1 ]
    [ -d "$BATS_TEST_TMPDIR" ]
    rm "$owned_dir"
    mv "$owned_dir.saved" "$owned_dir"
}

@test "core: ownership -> refuses a changed session marker" {
    local marker
    marker=$(< "$BATS_MOCK_STATE_DIR/.owner")
    printf other > "$BATS_MOCK_STATE_DIR/.owner"
    run mock_teardown
    [ "$status" -eq 1 ]
    [ -d "$BATS_MOCK_STATE_DIR" ]
    printf '%s\n' "$marker" > "$BATS_MOCK_STATE_DIR/.owner"
}

@test "core: session -> registration requires setup and teardown permits a fresh session" {
    mock_teardown
    run mock probe '*' true
    [ "$status" -eq 1 ]
    [[ "$output" == *'call mock_setup first'* ]]
    mock_setup
    mock probe '*' true
    assert_called_times probe 0
    probe
    assert_called_times probe 1
}

# ==============================================================================
# GROUP 02: ARGUMENT MATCHING - BASIC
# ==============================================================================

@test "match: literal -> matches exact string" {
    mock echo_cmd "hello" "echo 'matched'"
    run echo_cmd "hello"
    [ "$output" = "matched" ]
}

@test "match: literal -> fails on partial string" {
    mock echo_cmd "hello" "echo 'matched'"
    run -127 echo_cmd "hello world"
    [ "$output" != "matched" ]
}

@test "match: glob (*) -> matches suffix" {
    mock git "push *" "echo 'pushing'"
    run git push origin
    [ "$output" = "pushing" ]
}

@test "match: glob (*) -> matches prefix" {
    mock ls "*.txt" "echo 'text files'"
    run ls "data.txt"
    [ "$output" = "text files" ]
}

@test "match: glob (*) -> matches middle" {
    mock grep "*error*" "echo 'found error'"
    run grep "foo error bar"
    [ "$output" = "found error" ]
}

@test "match: glob (?) -> matches single character" {
    mock cat "file?.txt" "echo 'reading'"
    run cat "file1.txt"
    [ "$output" = "reading" ]
    run cat "fileA.txt"
    [ "$output" = "reading" ]
}

@test "match: glob (?) -> does not match multiple characters" {
    mock cat "file?.txt" "echo 'reading'"
    run -127 cat "file10.txt"
    [ "$output" != "reading" ]
}

# ==============================================================================
# GROUP 03: ARGUMENT MATCHING - ADVANCED
# ==============================================================================

@test "match: regex (~) -> matches basic pattern" {
    mock grep "~^err.*" "echo 'error found'"
    run grep "error_log"
    [ "$output" = "error found" ]
    run -127 grep "info_log"
    [ "$output" != "error found" ]
}

@test "match: regex (~) -> matches numeric ranges" {
    mock cat "~file[0-9]\.txt" "echo 'digit file'"
    run cat "file1.txt"
    [ "$output" = "digit file" ]
    run -127 cat "fileA.txt"
    [ "$output" != "digit file" ]
}

@test "match: regex (~) -> matches whitespace" {
    # POSIX ERE works with both the GNU and macOS regex engines.
    mock grep "~[[:space:]]+" "echo 'whitespace'"
    run grep "   "
    [ "$output" = "whitespace" ]
    run grep $'\t'
    [ "$output" = "whitespace" ]
    run -127 grep "non-whitespace"
}

@test "match: regex (~) -> matches end of line anchors" {
    mock cmd "~end$" "echo 'matched'"
    run cmd "the end"
    [ "$output" = "matched" ]
    run -127 cmd "ending"
    [ "$output" != "matched" ]
}

@test "match: whitespace -> handles arguments with spaces" {
    mock git "commit -m msg" "echo 'committed'"
    run git commit -m 'msg'
    [ "$output" = "committed" ]
}

@test "match: whitespace -> handles arguments with tabs" {
    mock tool "a"$'\t'"b" "echo 'tabbed'"
    run tool "a"$'\t'"b"
    [ "$status" -eq 0 ]
    [ "$output" = "tabbed" ]
}

@test "match: whitespace -> handles newlines in arguments" {
    # Arguments with newlines are tricky in bash, but mock.bash serializes them
    mock multi "line1"$'\n'"line2" "echo 'multiline'"
    run multi "line1"$'\n'"line2"
    [ "$output" = "multiline" ]
}

@test "match: empty -> handles empty string argument" {
    mock mycmd "" "echo 'empty'"
    run mycmd ""
    [ "$output" = "empty" ]
    run -127 mycmd "non-empty"
}

@test "match: mixed -> empty arg followed by non-empty" {
    mock mycmd " arg2" "echo 'mixed'"
    run mycmd "" "arg2"
    [ "$output" = "mixed" ]
}

@test "match: multiple args -> matches specific sequence" {
    mock cp "src dest" "echo 'copied'"
    run cp src dest
    [ "$output" = "copied" ]
}

@test "match: quoting -> handles single quotes in args" {
    mock python "-c 'print(1)'" "echo 'one'"
    run python "-c 'print(1)'"
    [ "$output" = "one" ]
}

@test "match: quoting -> handles double quotes in args" {
    mock echo_cmd "\"quoted\"" "echo 'got quotes'"
    run echo_cmd '"quoted"'
    [ "$output" = "got quotes" ]
}

@test "match: special chars -> handles hyphens (flags)" {
    mock ls "-la" "echo 'listing'"
    run ls -la
    [ "$output" = "listing" ]
}

@test "match: special chars -> handles paths with slashes" {
    mock ls "/usr/bin/local" "echo 'path'"
    run ls "/usr/bin/local"
    [ "$output" = "path" ]
}

@test "match: unicode -> handles utf-8 characters" {
    mock echo_cmd "café" "echo 'matched'"
    run echo_cmd "café"
    [ "$output" = "matched" ]
}

@test "match: unicode -> handles emoji" {
    mock echo_cmd "🚀" "echo 'lift off'"
    run echo_cmd "🚀"
    [ "$output" = "lift off" ]
}

@test "match: control chars -> handles tab and newline in args" {
    mock format "line1"$'\n'"line2" "echo 'formatted'"
    run format "line1"$'\n'"line2"
    [ "$output" = "formatted" ]
}

# ==============================================================================
# GROUP 04: I/O & SIDE EFFECTS
# ==============================================================================

@test "io: stdout -> mock writes to stdout" {
    mock echo_cmd "*" "echo 'standard out'"
    run echo_cmd
    [ "$output" = "standard out" ]
}

@test "io: stderr -> mock writes to stderr" {
    mock error_cmd "*" "echo 'standard err' >&2"
    run error_cmd
    [ "$output" = "standard err" ]
}

@test "io: mixed -> mock writes to both stdout and stderr" {
    mock mixed_cmd "*" "echo 'out'; echo 'err' >&2"
    run mixed_cmd
    [[ "$output" == *"out"* ]]
    [[ "$output" == *"err"* ]]
}

@test "io: stdin -> mock can read from stdin (legacy cat)" {
    mock cat_mock "*" "cat"
    run bash -c "echo 'input' | cat_mock"
    [ "$output" = "input" ]
}

@test "io: exit code -> returns specific non-zero code" {
    mock grep "*" "return 1"
    run grep "foo"
    [ "$status" -eq 1 ]
}

@test "side_effect: file -> creates file on system" {
    local touch_file="${BATS_TMPDIR}/touch.txt"
    rm -f "$touch_file"
    mock touch "*" "command touch '$touch_file'"

    run touch "foo"
    [ -f "$touch_file" ]
    rm -f "$touch_file"
}

@test "side_effect: variable -> modifies exported variable" {
    export GLOBAL_VAR="original"
    mock setter "*" "export GLOBAL_VAR='modified'"

    setter
    [ "$GLOBAL_VAR" = "modified" ]
}

@test "side_effect: return -> preserves arguments and variable changes" {
    local RESULT=""
    # shellcheck disable=SC2016  # evaluated by the mock
    mock -stdin probe "*" 'RESULT="$#|$1|$2|$3"; return 23'
    local result_code=0
    probe "" "two words" "*" || result_code=$?
    [ "$result_code" -eq 23 ]
    [ "$RESULT" = '3||two words|*' ]
    assert_stdin_at_index probe 0 ""
}

# ==============================================================================
# GROUP 05: INTERACTIONS (Pipes, Recursion, Subshells)
# ==============================================================================

@test "interaction: recursion -> mock calls another mock" {
    mock inner "*" "echo 'inside'"
    mock outer "*" "inner"

    run outer
    [ "$output" = "inside" ]
    assert_called "inner"
}

@test "interaction: nested -> mock A calls mock B" {
    mock inner "data" "echo 'inner-data'"
    mock outer "*" "inner 'data'"

    run outer
    [ "$output" = "inner-data" ]
    assert_called_with "inner" "data"
}

@test "interaction: pipe -> mock A pipes to mock B" {
    mock producer "*" "echo 'raw'"
    mock consumer "*" "cat"

    run bash -c "producer | consumer"
    [ "$output" = "raw" ]
    assert_called "producer"
    assert_called "consumer"
}

@test "interaction: subshell variable -> capture output of mock" {
    mock source_cmd "*" "echo '123'"

    run bash -c "VAL=\$(source_cmd); echo \"Got \$VAL\""
    [ "$output" = "Got 123" ]
}

@test "interaction: subshell nesting -> works inside nested subshells" {
    mock deep "*" "echo 'deep'"
    # shellcheck disable=SC2005  # the echo inside a nested subshell is the case under test
    result=$( ( echo "$(deep)" ) )
    [ "$result" = "deep" ]
}

@test "interaction: array args -> handles bash arrays correctly" {
    mock arr "*" "echo 'arrayed'"
    local my_arr=("element 1" "element 2")
    run arr "${my_arr[@]}"
    [ "$output" = "arrayed" ]
    assert_called_with "arr" "element 1 element 2"
}

@test "interaction: nested returns -> preserves outer status and arguments" {
    local RESULT=""
    mock -stdin inner "*" "return 3"
    # shellcheck disable=SC2016  # evaluated by the mock
    mock -stdin outer "*" 'inner "$@"; RESULT="$1"; return 9'
    local result_code=0
    outer value || result_code=$?
    [ "$result_code" -eq 9 ]
    [ "$RESULT" = value ]
    assert_called_times inner 1
    assert_called_times outer 1
    assert_stdin_at_index inner 0 ""
    assert_stdin_at_index outer 0 ""
}

# ==============================================================================
# GROUP 06: SPIES & UNMOCKING
# ==============================================================================

@test "spy: basic -> executes real command" {
    mock_spy ls
    run ls "$BATS_TEST_DIRNAME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mock.bats"* ]]
}

@test "spy: logging -> records arguments of spy" {
    mock_spy ls
    ls "$BATS_TEST_DIRNAME"
    assert_called_with ls "$BATS_TEST_DIRNAME"
}

@test "spy: pipeline -> works correctly in pipes" {
    mock_spy cat
    run bash -c "echo 'hello' | cat"
    [ "$output" = "hello" ]
    assert_called "cat"
}

@test "spy: exit code -> preserves original exit code" {
    mock_spy false
    run false
    [ "$status" -eq 1 ]
    assert_called "false"
}

@test "spy: recursion -> prevents infinite loops if designed carefully" {
    # If using spy, it shouldn't loop unless using 'mock' calling itself
    mock_spy ls
    run ls
    [ "$status" -eq 0 ]
}

@test "whitebox: spy definition -> accepts saved function keyword syntax" {
    local declaration
    for declaration in 'function original' 'function original()'; do
        mock original '*' true
        # Exercise alternate saved definitions, not declare -f's usual form.
        # shellcheck disable=SC2016  # evaluated only when the restored function is called
        printf '%s %s\n' "$declaration" '{ printf "<%s>" "$@"; return 7; }' > "$BATS_MOCK_STATE_DIR/original.orig"
        mock_spy original
        run original 'a b' '' tail
        [ "$status" -eq 7 ]
        [ "$output" = '<a b><><tail>' ]
        assert_called_at_index_with_args original 0 'a b' '' tail
        unmock original
        run original restored
        [ "$status" -eq 7 ]
        [ "$output" = '<restored>' ]
    done
}

@test "unmock: basic -> restores original command" {
    hello() { echo "original"; }
    export -f hello
    mock hello "*" "echo 'mocked'"

    unmock hello
    run hello
    [ "$output" = "original" ]
}

@test "unmock: idempotent -> handles double unmock gracefully" {
    mock hello "*" "true"
    unmock hello
    unmock hello
    run true
    [ "$status" -eq 0 ]
}

@test "unmock: non-existent -> does not error on unmocking unknown cmd" {
    run unmock "ghost_command"
    [ "$status" -eq 0 ]
}

@test "unmock: unregistered -> leaves an existing function intact" {
    # shellcheck disable=SC2329  # invoked indirectly by run
    original() { echo original; }
    unmock original
    run original
    [ "$status" -eq 0 ]
    [ "$output" = original ]
}

# ==============================================================================
# GROUP 07: SEQUENCES & CONCURRENCY
# ==============================================================================

@test "sequence: basic -> cycles through defined values" {
    mock_sequence seq "*" "echo 1" "echo 2"
    run seq; [ "$output" = "1" ]
    run seq; [ "$output" = "2" ]
}

@test "sequence: exhaustion -> repeats last value" {
    mock_sequence seq "*" "echo A" "echo B"
    run seq; [ "$output" = "A" ]
    run seq; [ "$output" = "B" ]
    run seq; [ "$output" = "B" ]
}

@test "sequence: persistence -> state persists across subshells" {
    mock_sequence seq "*" "echo 1" "echo 2"
    run seq; [ "$output" = "1" ]
    run seq; [ "$output" = "2" ]
}

@test "sequence: mixed -> cycles different exit codes" {
    mock_sequence flakey "*" "return 1" "return 0"
    run flakey; [ "$status" -eq 1 ]
    run flakey; [ "$status" -eq 0 ]
}

@test "sequence: concurrency -> atomic locking prevents races" {
    mock_sequence counter "" "echo A" "echo B" "echo C" "echo D" "echo E"

    counter &
    counter &
    counter &
    counter &
    counter &
    wait

    assert_called_times counter 5
}

@test "sequence: reset -> defining new sequence on same mock resets counter" {
    mock_sequence seq "*" "echo A" "echo B"
    seq
    mock_sequence seq "*" "echo C" "echo D"
    run seq
    [ "$output" = "C" ]
}

@test "sequence: uniqueness -> rapid registration uses distinct counters" {
    local i
    for ((i=0; i<25; i++)); do mock_sequence probe "*" true; done
    local counters=( "$BATS_MOCK_STATE_DIR"/seq_probe_* )
    [ "${#counters[@]}" -eq 25 ]
}

@test "sequence: invalid counter -> fails and releases the lock" {
    mock_sequence probe "*" true
    local counters=( "$BATS_MOCK_STATE_DIR"/seq_probe_* )
    printf 'invalid\n' > "${counters[0]}"
    run probe
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid sequence counter"* ]]
    [ ! -d "${counters[0]}.lock" ]
}

@test "sequence: missing actions -> rejects an empty sequence" {
    run mock_sequence probe "*"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MOCK ERROR"* ]]
}

# ==============================================================================
# GROUP 08: STRICT MODE & COMPLIANCE
# ==============================================================================

@test "strict: enabled -> unmatched call fails with 127" {
    mock_strict_mode 1
    mock git "status" "true"
    run -127 git diff
    [ "$status" -eq 127 ]
}

@test "strict: disabled -> unmatched call returns 0" {
    mock_strict_mode 0
    mock git "status" "true"
    run git diff
    [ "$status" -eq 0 ]
}

@test "strict: toggle -> can switch strict mode on and off" {
    mock_strict_mode 1
    mock cmd "*" "true"
    run cmd "arg"
    [ "$status" -eq 0 ]

    mock_strict_mode 0
    # Strict mode only affects UNMATCHED calls.
    mock_strict_mode 1
    # "unmatched" matches "*" so this passes.
    run cmd "unmatched"

    mock strict_test "match" "true"
    mock_strict_mode 1
    run -127 strict_test "fail"
    [ "$status" -eq 127 ]

    mock_strict_mode 0
    run strict_test "fail"
    [ "$status" -eq 0 ]
}

@test "strict: set -u -> works with nounset" {
    set -u
    mock nounset "args" "echo 'safe'"
    run nounset "args"
    [ "$output" = "safe" ]
}

@test "strict: set -e -> works with errexit" {
    set -e
    mock errexit "args" "true"
    errexit "args"
    assert_called "errexit"
}

@test "strict: pipefail -> works with pipefail" {
    set -o pipefail
    mock pipe "*" "echo 'pipe'"
    run bash -c "pipe | grep pipe"
    [ "$status" -eq 0 ]
}

# ==============================================================================
# GROUP 09: ASSERTIONS - PRESENCE & FREQUENCY
# ==============================================================================

@test "assert_called: success -> when called" {
    mock cmd "*" "true"
    cmd
    assert_called "cmd"
}

@test "assert_called: fail -> when not called" {
    mock cmd "*" "true"
    run assert_called "cmd"
    [ "$status" -eq 1 ]
}

@test "assert_called: fail -> when called different mock" {
    mock cmd1 "*" "true"
    mock cmd2 "*" "true"
    cmd1
    run assert_called "cmd2"
    [ "$status" -eq 1 ]
}

@test "refute_called: success -> when not called" {
    mock cmd "*" "true"
    refute_called "cmd"
}

@test "refute_called: fail -> when called" {
    mock cmd "*" "true"
    cmd
    run refute_called "cmd"
    [ "$status" -eq 1 ]
}

@test "assert_called_times: success -> exact match" {
    mock cmd "*" "true"
    cmd; cmd
    assert_called_times "cmd" 2
}

@test "assert_called_times: fail -> under count (1 expected 2)" {
    mock cmd "*" "true"
    cmd
    run assert_called_times "cmd" 2
    [ "$status" -eq 1 ]
}

@test "assert_called_times: fail -> under count (0 expected 1)" {
    mock cmd "*" "true"
    run assert_called_times "cmd" 1
    [ "$status" -eq 1 ]
}

@test "assert_called_times: fail -> over count (2 expected 1)" {
    mock cmd "*" "true"
    cmd; cmd
    run assert_called_times "cmd" 1
    [ "$status" -eq 1 ]
}

@test "assert_called_times: fail -> over count (1 expected 0)" {
    mock cmd "*" "true"
    cmd
    run assert_called_times "cmd" 0
    [ "$status" -eq 1 ]
}

@test "assert_called_times: success -> 0 times" {
    mock cmd "*" "true"
    assert_called_times "cmd" 0
}

@test "assertions: registration -> negative and zero-count checks reject unknown names" {
    local assertion
    for assertion in refute_called refute_called_with refute_called_exact refute_called_with_args; do
        run "$assertion" unregistered_typo
        [ "$status" -eq 1 ]
        [[ "$output" == *'Unregistered Mock'* ]]
    done
    run assert_called_times unregistered_typo 0
    [ "$status" -eq 1 ]
    [[ "$output" == *'Unregistered Mock'* ]]
}

@test "assertions: registration -> all call assertions reject an unmocked command" {
    mock probe '*' true
    probe
    unmock probe
    local assertion
    for assertion in assert_called assert_called_with assert_called_once_with assert_called_exact assert_called_with_args assert_stdin_equals; do
        run "$assertion" probe
        [ "$status" -eq 1 ]
        [[ "$output" == *'Unregistered Mock'* ]]
    done
    for assertion in assert_called_at_index assert_called_at_index_with_args assert_stdin_at_index assert_stdin_complete; do
        run "$assertion" probe 0
        [ "$status" -eq 1 ]
        [[ "$output" == *'Unregistered Mock'* ]]
    done
}

@test "assertions: corrupt history -> negative checks fail instead of treating it as no match" {
    mock probe '*' true
    probe recorded
    printf unterminated > "$BATS_MOCK_STATE_DIR/probe.calls/0/args"
    local assertion
    for assertion in refute_called_with refute_called_exact; do
        run "$assertion" probe missing
        [ "$status" -eq 1 ]
        [[ "$output" == *'History Read Failure'* ]]
    done
}

@test "assert_called_times: decimal -> normalizes zeroes and rejects expressions" {
    mock probe "*" true
    local i
    for ((i=0; i<9; i++)); do probe; done
    assert_called_times probe 009
    run assert_called_times probe '3*3'
    [ "$status" -eq 1 ]
}

# ==============================================================================
# GROUP 10: ASSERTIONS - ARGUMENTS
# ==============================================================================

@test "assert_called_with: success -> literal match" {
    mock git "fetch" "true"
    git fetch
    assert_called_with "git" "fetch"
}

@test "assert_called_with: success -> glob match" {
    mock git "fetch" "true"
    git fetch
    assert_called_with "git" "fet*"
}

@test "assert_called_with: success -> regex match" {
    mock git "fetch" "true"
    git fetch
    assert_called_with "git" "~^fet.*"
}

@test "assert_called_with: fail -> no matching call (literal)" {
    mock git "fetch" "true"
    git fetch
    run assert_called_with "git" "pull"
    [ "$status" -eq 1 ]
}

@test "assert_called_with: fail -> no matching call (regex)" {
    mock git "fetch" "true"
    git fetch
    run assert_called_with "git" "~^pull.*"
    [ "$status" -eq 1 ]
}

@test "assert_called_with: fail -> no history" {
    mock git "*" "true"
    run assert_called_with "git" "fetch"
    [ "$status" -eq 1 ]
}

@test "assert_called_with: multiline -> handles arguments with newlines" {
    mock email "Subject Line 1"$'\n'"Line 2" "true"
    email "Subject" "Line 1"$'\n'"Line 2"
    assert_called_with "email" "Subject" "Line 1"$'\n'"Line 2"
}

@test "refute_called_with: success -> no matching call" {
    mock git "fetch" "true"
    git fetch
    refute_called_with "git" "pull"
}

@test "refute_called_with: fail -> match found" {
    mock git "fetch" "true"
    git fetch
    run refute_called_with "git" "fetch"
    [ "$status" -eq 1 ]
}

@test "assert_called_once_with: success -> exactly one match and one call" {
    mock git "*" "true"
    git commit
    assert_called_once_with "git" "commit"
}

@test "assert_called_once_with: fail -> called twice total" {
    mock git "*" "true"
    git commit; git commit
    run assert_called_once_with "git" "commit"
    [ "$status" -eq 1 ]
}

@test "assert_called_once_with: fail -> no match found" {
    mock git "*" "true"
    git push
    run assert_called_once_with "git" "pull"
    [ "$status" -eq 1 ]
}

# ==============================================================================
# GROUP 11: ASSERTIONS - HISTORY & SEQUENCE
# ==============================================================================

@test "assert_called_at_index: success -> correct arg at index 0" {
    mock log "*" "true"
    log "one"; log "two"
    assert_called_at_index "log" 0 "one"
}

@test "assert_called_at_index: success -> correct arg at index 1" {
    mock log "*" "true"
    log "one"; log "two"
    assert_called_at_index "log" 1 "two"
}

@test "assert_called_at_index: regex -> matches only the selected call" {
    mock probe '*' true
    probe 'job-42 ready'
    probe 'job-7 failed'
    assert_called_at_index probe 0 '~^job-[0-9]+ ready$'
    assert_called_at_index probe 1 '~^job-[0-9]+ failed$'
    run assert_called_at_index probe 1 '~^job-[0-9]+ ready$'
    [ "$status" -eq 1 ]
    [[ "$output" == *'Argument Mismatch'* ]]
    [[ "$output" == *"Index 1 matching: '~^job-[0-9]+ ready$'"* ]]
    [[ "$output" == *'Actual     : job-7 failed'* ]]
}

@test "assertions: missing log -> registered mocks report one structured failure" {
    mock -stdin probe '*' true
    probe value
    mv "$BATS_MOCK_STATE_DIR/probe.log" "$BATS_MOCK_STATE_DIR/probe.log.saved"
    local function_name
    for function_name in assert_called_at_index assert_stdin_at_index assert_args_contain; do
        if [[ "$function_name" == assert_args_contain ]]; then
            run "$function_name" probe value
        else
            run "$function_name" probe 0 value
        fi
        [ "$status" -eq 1 ]
        [[ "$output" == *'No history'* ]]
        [[ "$output" != *'Unregistered Mock'* ]]
        [[ "$output" != *'No such file or directory'* ]]
        [[ "$output" != *'unbound variable'* ]]
    done
    mv "$BATS_MOCK_STATE_DIR/probe.log.saved" "$BATS_MOCK_STATE_DIR/probe.log"
    assert_called_at_index probe 0 value
    assert_args_contain probe value
}

@test "assert_called_at_index: fail -> wrong arg at index" {
    mock log "*" "true"
    log "one"
    run assert_called_at_index "log" 0 "two"
    [ "$status" -eq 1 ]
}

@test "assert_called_at_index: fail -> index out of bounds" {
    mock log "*" "true"
    log "one"
    run assert_called_at_index "log" 1 "one"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Index out of bounds"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "assert_called_at_index: decimal -> validates before array access" {
    mock probe "*" true
    local i
    for ((i=0; i<9; i++)); do probe "$i"; done
    assert_called_at_index probe 008 8
    local index
    for index in -1 '0+0' 18446744073709551616; do
        run assert_called_at_index probe "$index" 0
        [ "$status" -eq 1 ]
        [[ "$output" != *"unbound variable"* ]]
    done
}

@test "assert_args_contain: success -> substring found" {
    mock grep "*" "true"
    grep "-r" "."
    assert_args_contain "grep" "-r"
}

@test "assert_args_contain: fail -> substring not found" {
    mock grep "*" "true"
    grep "-r" "."
    run assert_args_contain "grep" "-v"
    [ "$status" -eq 1 ]
}

@test "assert_args_contain: missing history -> reports one structured failure" {
    run assert_args_contain absent value
    [ "$status" -eq 1 ]
    [[ "$output" == *"No history"* ]]
    [[ "$output" != *"No such file or directory"* ]]
    [[ "$output" != *"History"* ]]
}

@test "assert_call_sequence: success -> verifies global order" {
    mock git "*" "true"
    mock make "*" "true"

    git fetch
    git merge
    make build

    assert_call_sequence "git fetch" "git merge" "make build"
}

@test "assert_call_sequence: fail -> wrong order" {
    mock git "*" "true"
    git push; git fetch
    run assert_call_sequence "git fetch" "git push"
    [ "$status" -eq 1 ]
}

@test "assert_call_sequence: fail -> missing step" {
    mock git "*" "true"
    git fetch
    run assert_call_sequence "git fetch" "git push"
    [ "$status" -eq 1 ]
}

@test "assert_call_sequence: empty -> succeeds with and without history" {
    assert_call_sequence
    mock probe "*" true
    probe
    assert_call_sequence
}

@test "assert_call_sequence: missing log -> fails without creating replacement history" {
    mv "$BATS_MOCK_GLOBAL_LOG" "$BATS_MOCK_GLOBAL_LOG.saved"
    run assert_call_sequence 'probe value'
    [ "$status" -eq 1 ]
    [ "$output" = "Global mock log not found at: $BATS_MOCK_GLOBAL_LOG" ]
    [ ! -e "$BATS_MOCK_GLOBAL_LOG" ]
    assert_call_sequence
    mv "$BATS_MOCK_GLOBAL_LOG.saved" "$BATS_MOCK_GLOBAL_LOG"
}

@test "assert_call_sequence: no calls -> reports zero progress and an empty log" {
    mock probe '*' true
    run assert_call_sequence 'probe first' 'probe second'
    [ "$status" -eq 1 ]
    [[ "$output" == *'Matched 0 of 2 items.'* ]]
    [[ "$output" == *"Waiting for: 'probe first'"* ]]
    [[ "$output" == *'    (Empty)'* ]]
}

@test "assert_call_sequence: command boundary -> rejects a longer command name" {
    mock api_v2 '*' true
    api_v2
    run assert_call_sequence api
    [ "$status" -eq 1 ]
    assert_call_sequence api_v2
}

@test "assert_call_sequence: argument boundary -> rejects a partial argument" {
    mock git '*' true
    git fetcher
    run assert_call_sequence 'git fetch'
    [ "$status" -eq 1 ]
    git fetch origin
    assert_call_sequence 'git fetch'
}

# ==============================================================================
# GROUP 12: ASSERTIONS - FEEDBACK & DEBUGGING
# ==============================================================================

@test "feedback: assert_called -> message contains command name" {
    mock phantom "*" "true"

    run assert_called "phantom"
    [ "$status" -eq 1 ]
    [[ "$output" == *"phantom"* ]]
    [[ "$output" == *"Not Called"* ]]
}

@test "feedback: assert_called_with -> message shows mismatch" {
    mock git "fetch" "true"
    git fetch

    run assert_called_with "git" "push"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Argument Mismatch"* ]]
    [[ "$output" == *"fetch"* ]] # History should show the actual call
}

@test "feedback: history -> limits displayed calls and reports omitted entries" {
    mock probe '*' true
    local i
    for ((i=1; i<=12; i++)); do probe "entry-$i"; done
    run assert_called_with probe missing
    [ "$status" -eq 1 ]
    [[ "$output" == *entry-1* ]]
    [[ "$output" == *entry-10* ]]
    [[ "$output" != *entry-11* ]]
    [[ "$output" == *'and 2 more calls'* ]]
}

@test "feedback: history -> truncates large entries without changing assertions" {
    mock probe '*' true
    local payload
    printf -v payload '%1000s' ''
    payload=${payload// /x}
    probe "$payload"
    assert_called_with_args probe "$payload"
    run assert_called_with probe missing
    [ "$status" -eq 1 ]
    [[ "$output" == *'...'* ]]
    [[ "$output" != *"$payload"* ]]
}

@test "feedback: argv -> shows argument boundaries and zero-based index expectations" {
    mock probe '*' true
    probe 'a b' ''
    run assert_called_at_index_with_args probe 0 a b
    [ "$status" -eq 1 ]
    [[ "$output" == *'Index 0 with exactly 2 arguments'* ]]
    [[ "$output" == *"2 arguments: a\\ b ''"* ]]
}

@test "feedback: stdin -> distinguishes an uncalled mock from recorded empty input" {
    mock -stdin probe '*' 'cat >/dev/null'
    run assert_stdin_equals probe expected
    [ "$status" -eq 1 ]
    [[ "$output" == *'Stdin Mismatch'* ]]
    [[ "$output" == *'(No stdin recorded)'* ]]
    printf '' | probe
    assert_stdin_equals probe ''
    run assert_stdin_equals probe expected
    [ "$status" -eq 1 ]
    [[ "$output" != *'(No stdin recorded)'* ]]
    assert_called_times probe 1
}

@test "feedback: stdin -> bounds diagnostic history without truncating captured data" {
    mock -stdin probe '*' 'cat >/dev/null'
    local payload i
    printf -v payload '%1000s' ''
    payload=${payload// /x}
    printf '%s' "$payload" | probe
    for ((i=2; i<=12; i++)); do printf 'entry-%s' "$i" | probe; done
    assert_stdin_at_index probe 0 "$payload"
    assert_stdin_equals probe entry-12
    run assert_stdin_equals probe missing
    [ "$status" -eq 1 ]
    [[ "$output" == *"${payload:0:240}..."* ]]
    [[ "$output" != *"$payload"* ]]
    [[ "$output" == *entry-10* ]]
    [[ "$output" != *entry-11* ]]
    [[ "$output" != *entry-12* ]]
    [[ "$output" == *'and 2 more calls'* ]]
}

@test "debug: mock_debug -> runs without error" {
    mock git "*" "true"
    git status
    git log
    # Force output to stdout for verification
    run mock_debug 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK DEBUG REPORT"* ]]
}

@test "debug: idle mocks -> prints multiline rules without executing them" {
    mock idle_probe '*' $'printf first\nprintf second'
    run mock_debug 1
    [ "$status" -eq 0 ]
    [[ "$output" == *'[ IDLE MOCKS ]'* ]]
    [[ "$output" == *'  idle_probe'* ]]
    [[ "$output" == *"Rule 1: pattern '*'"* ]]
    [[ "$output" == *'             | printf first'* ]]
    [[ "$output" == *'             | printf second'* ]]
    assert_called_times idle_probe 0
}

@test "debug: default descriptor -> falls back to stderr when fd 3 is closed" {
    mock_debug >"$BATS_TEST_TMPDIR/debug.out" 2>"$BATS_TEST_TMPDIR/debug.err" 3>&-
    [ ! -s "$BATS_TEST_TMPDIR/debug.out" ]
    [[ "$(< "$BATS_TEST_TMPDIR/debug.err")" == *'MOCK DEBUG REPORT'* ]]
}

@test "debug: default descriptor -> uses fd 3 when proc exposes it" {
    [[ -d /proc/self/fd ]] || skip '/proc/self/fd is not available on this platform'
    mock_debug 3>"$BATS_TEST_TMPDIR/debug.fd3" >"$BATS_TEST_TMPDIR/debug.out" 2>"$BATS_TEST_TMPDIR/debug.err"
    [ ! -s "$BATS_TEST_TMPDIR/debug.out" ]
    [ ! -s "$BATS_TEST_TMPDIR/debug.err" ]
    [[ "$(< "$BATS_TEST_TMPDIR/debug.fd3")" == *'MOCK DEBUG REPORT'* ]]
}

# ==============================================================================
# GROUP 13: SECURITY & SAFETY
# ==============================================================================

@test "security: injection -> prevents eval injection in patterns" {
    mock_strict_mode 0

    local exploit_file="${BATS_TMPDIR}/hacked"
    rm -f "$exploit_file"

    mock injection "\$(touch $exploit_file)" "echo 'oops'"
    run injection "foo"

    [ ! -f "$exploit_file" ]
}

@test "security: injection -> prevents function definition injection in command name" {
    # Attempt to define a malicious function via the mock name
    # If vulnerable, this would create /tmp/pwned
    local exploit_file="/tmp/pwned"
    rm -f "$exploit_file"

    run mock "bad() { touch $exploit_file; }; true" "*" "true"

    [ "$status" -eq 1 ]
    [[ "$output" == *"MOCK ERROR"* ]]
    [ ! -f "$exploit_file" ]
}

@test "security: stability -> prevents mocking internal framework functions" {
    run mock "mock" "*" "true"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reserved framework function"* ]]

    run mock "mock_setup" "*" "true"
    [ "$status" -eq 1 ]
}

@test "security: reserved names -> protects all framework namespaces" {
    local name
    for name in mock::jit::compile mock::report::fail mock::sync::lock mock::history::search assert_called refute_called _BATS_MOCK_ACTION_probe; do
        run mock "$name" "*" true
        [ "$status" -eq 1 ]
        [[ "$output" == *"reserved framework function"* ]]
    done
}

# ==============================================================================
# GROUP 14: SYSTEM & CONFIGURATION
# ==============================================================================

@test "system: naming -> handles hyphens in command name" {
    mock git-upload-pack "*" "echo 'uploading'"
    run git-upload-pack
    [ "$output" = "uploading" ]
}

@test "system: naming -> handles underscores in command name" {
    mock my_custom_tool "*" "echo 'tooling'"
    run my_custom_tool
    [ "$output" = "tooling" ]
}

@test "system: naming -> handles dots in command name" {
    mock "node.js" "*" "echo 'runtime'"
    run node.js
    [ "$output" = "runtime" ]
}

@test "system: naming -> handles numbers in command name" {
    mock v2_tool "*" "echo 'v2'"
    run v2_tool
    [ "$output" = "v2" ]
}

@test "system: naming -> punctuation does not share rule state" {
    mock a-b "*" "echo hyphen"
    mock a_b "*" "echo underscore"
    mock a.b "*" "echo dot"
    mock a:b "*" "echo colon"
    run a-b; [ "$output" = hyphen ]
    run a_b; [ "$output" = underscore ]
    run a.b; [ "$output" = dot ]
    run a:b; [ "$output" = colon ]
    unmock a-b
    run a_b; [ "$output" = underscore ]
}

@test "system: loading -> sourcing the library twice is harmless" {
    load "$BATS_TEST_DIRNAME/../load.bash"
    mock probe "*" "echo loaded"
    run probe
    [ "$status" -eq 0 ]
    [ "$output" = loaded ]
}

@test "system: payload -> handles huge arguments" {
    local huge_arg
    huge_arg=$(printf 'a%.0s' {1..10000})
    mock heavy "*" "echo 'done'"
    run heavy "$huge_arg"
    [ "$status" -eq 0 ]
}

@test "config: state dir -> respects BATS_MOCK_STATE_DIR" {
    mock_teardown
    local custom_dir="${BATS_TEST_TMPDIR}/custom_mocks"
    export BATS_MOCK_STATE_DIR="$custom_dir"
    export BATS_MOCK_GLOBAL_LOG="$custom_dir/global.log"

    mock_setup
    mock git "*" "true"
    git status

    [ -d "$custom_dir" ]
    [ -f "${custom_dir}/git.log" ]

    mock_teardown
}

@test "config: global log -> respects BATS_MOCK_GLOBAL_LOG" {
    local custom_log="${BATS_TMPDIR}/custom_global.log"
    export BATS_MOCK_GLOBAL_LOG="$custom_log"

    mock_setup
    mock git "*" "true"
    git status

    [ -f "$custom_log" ]
    rm -f "$custom_log"
}

@test "config: relative global log -> resolves before commands change directory" {
    mock_teardown
    cd "$BATS_TEST_TMPDIR"
    export BATS_MOCK_STATE_DIR="$BATS_TEST_TMPDIR/relative-log-mocks"
    export BATS_MOCK_GLOBAL_LOG='calls with spaces.log'
    mock_setup
    [ "$BATS_MOCK_GLOBAL_LOG" = "$PWD/calls with spaces.log" ]
    mock probe '*' true
    cd "$BATS_MOCK_STATE_DIR"
    probe value
    assert_call_sequence 'probe value'
    [ ! -e "$BATS_MOCK_STATE_DIR/calls with spaces.log" ]
    cd "$BATS_TEST_TMPDIR"
}

@test "config: paths -> quotes and expansion characters remain literal" {
    mock_teardown
    export BATS_MOCK_STATE_DIR="$BATS_TEST_TMPDIR/space ' \" \$HOME"
    export BATS_MOCK_GLOBAL_LOG="$BATS_MOCK_STATE_DIR/global.log"
    mock_setup
    mock probe "*" "echo ok"
    run probe
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    assert_called_times probe 1
    mock_sequence step "*" "echo first" "echo second"
    run step; [ "$output" = first ]
    run step; [ "$output" = second ]
}

@test "whitebox: rules -> a new rule is published without rebuilding the wrapper" {
    mock dirty_check "*" "printf first"
    # shellcheck disable=SC2154  # set by mock::jit::compile
    [ "${_BATS_MOCK_DIRTY_dirty_check}" -eq 0 ]
    # shellcheck disable=SC2154  # set by mock::jit::compile
    [ "${_BATS_MOCK_BUILT_dirty_check}" -eq 1 ]
    # shellcheck disable=SC2154  # set by mock::jit::add_rule
    [ "${_BATS_MOCK_RULE_COUNT_dirty_check}" -eq 1 ]

    local before
    before=$(declare -f dirty_check)

    # The wrapper reads its rules at call time, so a second rule needs no
    # rebuild: the body is unchanged and the mock still honours the new rule.
    mock dirty_check "second" "printf second"
    [ "${_BATS_MOCK_DIRTY_dirty_check}" -eq 0 ]
    [ "${_BATS_MOCK_RULE_COUNT_dirty_check}" -eq 2 ]
    [ "$(declare -f dirty_check)" = "$before" ]

    run dirty_check second
    [ "$output" = second ]
    run dirty_check anything
    [ "$output" = first ]
}

@test "options: -- -> ends option parsing before the command name" {
    mock -- probe '*' 'printf parsed'
    run probe anything
    [ "$status" -eq 0 ]
    [ "$output" = parsed ]
    assert_called_once_with probe anything
}

@test "options: stdin -> mock_sequence records input for each action" {
    mock_sequence -stdin seq_in '*' 'command cat >/dev/null' 'command cat >/dev/null'
    printf 'first' | seq_in
    printf 'second' | seq_in
    assert_stdin_at_index seq_in 0 first
    assert_stdin_at_index seq_in 1 second
}

@test "options: stdin -> assertions name the flag when capture is off" {
    mock quiet '*' true
    printf 'payload' | quiet

    run assert_stdin_equals quiet payload
    [ "$status" -eq 1 ]
    [[ "$output" == *'Stdin Not Captured'* ]]
    [[ "$output" == *'mock -stdin quiet'* ]]

    run assert_stdin_at_index quiet 0 payload
    [ "$status" -eq 1 ]
    [[ "$output" == *'Stdin Not Captured'* ]]

    run assert_stdin_complete quiet 0
    [ "$status" -eq 1 ]
    [[ "$output" == *'Stdin Not Captured'* ]]
}

@test "whitebox: dirty flag -> enabling capture rebuilds the wrapper" {
    mock capture_check "*" "true"
    # shellcheck disable=SC2154  # set by mock::jit::compile
    [ "${_BATS_MOCK_DIRTY_capture_check}" -eq 0 ]
    local before
    before=$(declare -f capture_check)

    # The capture path is compiled in, so -stdin must produce a new body.
    mock -stdin capture_check "*" "true"
    [ "${_BATS_MOCK_DIRTY_capture_check}" -eq 0 ]
    [ "$(declare -f capture_check)" != "$before" ]

    printf 'payload' | capture_check
    assert_stdin_equals capture_check "payload"
}

@test "whitebox: compilation cache -> preserves the wrapper, rules and history" {
    mock probe '*' 'printf original'
    run probe before
    [ "$status" -eq 0 ]
    [ "$output" = original ]
    local definition
    definition=$(declare -f probe)
    mock::jit::compile probe
    [ "$(declare -f probe)" = "$definition" ]
    assert_called_at_index_with_args probe 0 before
    run probe after
    [ "$status" -eq 0 ]
    [ "$output" = original ]
    assert_called_at_index_with_args probe 1 after
    assert_called_times probe 2
}

@test "integrity: multiline arguments do not corrupt call count" {
    # Uses internal log inspection to verify data integrity
    mock email_sender "*" "true"

    # Send a multiline argument (Subject\nBody)
    email_sender "Subject"$'\n'"Body text"

    # Without the fix, this sees 2 lines in the log and fails
    assert_called_times "email_sender" 1

    # Verify the log content (internal implementation detail check)
    run cat "${BATS_MOCK_STATE_DIR}/email_sender.log"
    [[ "$output" == *"Subject<newline>Body text"* ]]
}

# ==============================================================================
# GROUP 15: ERROR HANDLING & EDGE CASES
# ==============================================================================

@test "error: watchdog -> stops a stuck command and its output-holding children" {
    run_with_timeout 1 bash -c 'trap "" TERM; sleep 30 & wait'
    [ "$status" -eq 137 ]
    [[ "$output" == *"Test command exceeded 1 seconds"* ]]
}

@test "error: watchdog -> closes output held by children after the command exits" {
    run_with_timeout 1 bash -c 'sleep 30 & exit 0'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "error: API arguments -> rejects missing and extra inputs" {
    local function_name
    for function_name in mock mock_spy mock_sequence unmock mock_strict_mode assert_called_times assert_called_at_index assert_stdin_at_index assert_called refute_called assert_called_with assert_called_once_with refute_called_with assert_called_exact refute_called_exact assert_called_with_args refute_called_with_args assert_called_at_index_with_args assert_stdin_equals assert_stdin_complete assert_args_contain; do
        run "$function_name"
        [ "$status" -eq 1 ]
        [[ "$output" == *"MOCK ERROR"* ]]
    done
    run mock_strict_mode 2
    [ "$status" -eq 1 ]
    [ "$BATS_MOCK_STRICT" = 1 ]
    run mock probe "*" true extra
    [ "$status" -eq 1 ]
}

@test "error: invalid regex -> registration fails without changing existing rules" {
    mock probe '*' 'echo original'
    run mock probe '~[' true
    [ "$status" -eq 1 ]
    [[ "$output" == *'Invalid regular expression'* ]]
    run probe
    [ "$output" = original ]
    run mock_sequence probe '~[' true
    [ "$status" -eq 1 ]
}

@test "error: invalid regex -> positive and negative assertions reject malformed patterns" {
    mock probe '*' true
    probe
    local assertion
    for assertion in assert_called_with assert_called_once_with refute_called_with; do
        run "$assertion" probe '~['
        [ "$status" -eq 1 ]
        [[ "$output" == *'Invalid regular expression'* ]]
    done
    run assert_called_at_index probe 0 '~['
    [ "$status" -eq 1 ]
}

@test "error: invalid action -> syntax error in action returns failure" {
    # Using an unclosed parenthesis '(' forces a genuine shell syntax error during eval
    mock bad_syntax "*" "("

    run bad_syntax
    [ "$status" -ne 0 ]
}

@test "error: timeouts -> fails gracefully on stale locks" {
    mock_sequence locked_cmd "*" "echo A"

    local counter_files=( "${BATS_MOCK_STATE_DIR}/seq_locked_cmd_"* )
    local counter_file="${counter_files[0]}"

    mkdir "${counter_file}.lock"
    slow_lock_attempts "${counter_file}.lock"

    run_with_timeout 15 locked_cmd

    [ "$status" -eq 1 ]
    [[ "$output" == *"Lock timeout"* ]]
    [ "$(< "$counter_file")" = 0 ]
    [ -d "${counter_file}.lock" ]

    rmdir "${counter_file}.lock"
    run locked_cmd
    [ "$status" -eq 0 ]
    [ "$output" = A ]
}

@test "error: history lock -> times out before executing an action" {
    mock probe '*' 'echo should-not-run'
    mkdir "$BATS_MOCK_STATE_DIR/history.lock"
    slow_lock_attempts "$BATS_MOCK_STATE_DIR/history.lock"
    run_with_timeout 15 probe
    [ "$status" -eq 1 ]
    [[ "$output" == *'call history lock'* ]]
    [[ "$output" != *should-not-run* ]]
    assert_called_times probe 0
    [ -d "$BATS_MOCK_STATE_DIR/history.lock" ]
    rmdir "$BATS_MOCK_STATE_DIR/history.lock"
    run probe
    [ "$status" -eq 0 ]
    [ "$output" = should-not-run ]
    assert_called_times probe 1
}

@test "error: sync lock -> timeout includes slow lock attempts" {
    local lock_path="$BATS_MOCK_STATE_DIR/manual"
    mkdir "$lock_path.lock"
    slow_lock_attempts "$lock_path.lock"
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 15 bash -c '
        source "$1"
        mock::sync::lock "$2"
    ' _ "$BATS_TEST_DIRNAME/../load.bash" "$lock_path"
    [ "$status" -eq 1 ]
    [[ "$output" == *'MOCK TIMEOUT: Could not acquire lock'* ]]
    [ -d "$lock_path.lock" ]
    rmdir "$lock_path.lock"
    mock::sync::lock "$lock_path"
    [ -d "$lock_path.lock" ]
    mock::internal::unlock "$lock_path"
    [ ! -d "$lock_path.lock" ]
}

@test "error: history lock -> retries until a competing caller releases it" {
    mock probe '*' 'echo acquired'
    mkdir "$BATS_MOCK_STATE_DIR/history.lock"
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 15 bash -c '
        (
            sleep 0.5
            rmdir "$BATS_MOCK_STATE_DIR/history.lock"
        ) &
        release_pid=$!
        result=0
        probe || result=$?
        wait "$release_pid" || exit
        exit "$result"
    '
    [ "$status" -eq 0 ]
    [ "$output" = acquired ]
    assert_called_times probe 1
    [ ! -d "$BATS_MOCK_STATE_DIR/history.lock" ]
}

@test "error: call counter -> rejects malformed state and releases the history lock" {
    mock probe '*' true
    printf '1+1\n' > "$BATS_MOCK_STATE_DIR/probe.next"
    run probe
    [ "$status" -eq 1 ]
    [[ "$output" == *'Invalid call counter'* ]]
    [ ! -d "$BATS_MOCK_STATE_DIR/history.lock" ]
    printf '0\n' > "$BATS_MOCK_STATE_DIR/probe.next"
    probe
    assert_called_times probe 1
}

@test "error: missing call counter -> releases the lock without executing the action" {
    # shellcheck disable=SC2016  # expanded when the action executes
    mock probe '*' 'printf executed > "$BATS_TEST_TMPDIR/action"'
    mv "$BATS_MOCK_STATE_DIR/probe.next" "$BATS_MOCK_STATE_DIR/probe.next.saved"
    run probe value
    [ "$status" -eq 1 ]
    [[ "$output" == *'Invalid call counter'* ]]
    [ ! -d "$BATS_MOCK_STATE_DIR/history.lock" ]
    [ ! -e "$BATS_TEST_TMPDIR/action" ]
    [ ! -s "$BATS_MOCK_STATE_DIR/probe.log" ]
    [ ! -s "$BATS_MOCK_GLOBAL_LOG" ]
    mv "$BATS_MOCK_STATE_DIR/probe.next.saved" "$BATS_MOCK_STATE_DIR/probe.next"
    probe recovered
    [ "$(< "$BATS_TEST_TMPDIR/action")" = executed ]
    assert_called_at_index_with_args probe 0 recovered
}

@test "error: call directory collision -> preserves state and releases the history lock" {
    # shellcheck disable=SC2016  # expanded when the action executes
    mock probe '*' 'printf executed > "$BATS_TEST_TMPDIR/action"'
    mkdir "$BATS_MOCK_STATE_DIR/probe.calls/0"
    printf keep > "$BATS_MOCK_STATE_DIR/probe.calls/0/marker"
    run probe value
    [ "$status" -eq 1 ]
    [ ! -d "$BATS_MOCK_STATE_DIR/history.lock" ]
    [ ! -e "$BATS_TEST_TMPDIR/action" ]
    [ ! -s "$BATS_MOCK_STATE_DIR/probe.log" ]
    [ ! -s "$BATS_MOCK_GLOBAL_LOG" ]
    [ "$(< "$BATS_MOCK_STATE_DIR/probe.next")" = 0 ]
    [ "$(< "$BATS_MOCK_STATE_DIR/probe.calls/0/marker")" = keep ]
    mv "$BATS_MOCK_STATE_DIR/probe.calls/0" "$BATS_TEST_TMPDIR/blocked-call"
    probe recovered
    [ "$(< "$BATS_TEST_TMPDIR/action")" = executed ]
    assert_called_at_index_with_args probe 0 recovered
}

@test "edge: collision -> handles literal '<newline>' string vs physical newline" {
    # NEW TEST: This documents the ambiguity/collision behavior of the log format.
    # If I pass the literal text "<newline>" it should be treated as text.
    # Due to the internal replacement, this might collide with actual newlines in logs.
    mock cmd "*" "true"
    cmd "foo <newline> bar"
    assert_called_with "cmd" "foo <newline> bar"
}

# ==============================================================================
# GROUP 16: NAMESPACE SUPPORT (::)
# ==============================================================================

@test "namespace: registration -> allows double colons in function name" {
    # Verifies the regex validation patch allows '::'
    mock stealth::pkg::install "*" "echo 'installed'"

    # Direct execution (Unit test style)
    stealth::pkg::install
    # shellcheck disable=SC2181  # the status is the assertion
    [ "$?" -eq 0 ]

    # output capture is manual in direct calls, but we verify exit code 0
    # and we verify the mock log recorded it
    assert_called "stealth::pkg::install"
}

@test "namespace: execution -> works in subshells (run) without export" {
    # shellcheck disable=SC2016  # the action is evaluated by the mock, not here
    mock stealth::ui::header "*" 'echo "HEADER: $1"'

    run stealth::ui::header "Welcome"

    [ "$status" -eq 0 ]
    [ "$output" = "HEADER: Welcome" ]
    assert_called_with "stealth::ui::header" "Welcome"
}

@test "namespace: matching -> arguments work for namespaced functions" {
    mock stealth::net::download "http://*" "echo 'downloading'"

    run stealth::net::download "http://example.com"
    [ "$output" = "downloading" ]

    run -127 stealth::net::download "ftp://bad.com"
    [ "$output" != "downloading" ]
}

@test "namespace: complex -> handles mixed delimiters and hyphens" {
    # Edge case: Valid characters mixed with namespace separators
    mock mod::v2-beta::init_module "*" "echo 'initialized'"

    run mod::v2-beta::init_module
    [ "$output" = "initialized" ]
}

@test "namespace: spy -> can spy on existing namespaced functions" {
    # Define a 'real' function in the namespace
    stealth::sys::fs::copy() { echo "real cp $1 $2"; }

    mock_spy stealth::sys::fs::copy

    run stealth::sys::fs::copy "src" "dest"

    [ "$output" = "real cp src dest" ]
    assert_called_with "stealth::sys::fs::copy" "src" "dest"

    # Unmock it
    unmock stealth::sys::fs::copy

    # Verify restoration
    run stealth::sys::fs::copy "test" "dir"
    [ "$output" = "real cp test dir" ]
    run refute_called_with "stealth::sys::fs::copy" "test" "dir"
    [ "$status" -eq 1 ]
    [[ "$output" == *'Unregistered Mock'* ]]
}

@test "namespace: unmock -> restores original namespaced function" {
    # Define original
    stealth::api::login() { echo "original login"; }

    # Mock it
    mock stealth::api::login "*" "echo 'mocked login'"
    run stealth::api::login
    [ "$output" = "mocked login" ]

    # Unmock it
    unmock stealth::api::login

    # Verify restoration
    run stealth::api::login
    [ "$output" = "original login" ]
}

@test "namespace: strict mode -> enforces strict calls on namespaces" {
    mock_strict_mode 1
    mock stealth::db::query "SELECT *" "true"

    run -127 stealth::db::query "DROP TABLE"

    [ "$status" -eq 127 ]
}

@test "namespace: assertion failure -> reports correct function name" {
    mock stealth::auth::check "*" "true"

    stealth::auth::check

    run assert_called_with "stealth::auth::check" "bad_arg"

    [ "$status" -eq 1 ]
    [[ "$output" == *"stealth::auth::check"* ]]
    [[ "$output" == *"Argument Mismatch"* ]]
}

# ==============================================================================
# GROUP 17: ASSERTIONS - EXACT MATCHING (Literal Mode)
# ==============================================================================

@test "assert_called_exact: brackets -> matches literals '[ ]' without treating them as glob ranges" {
    mock compiler "*" "true"
    compiler "array[0]"

    # Should pass: explicitly looking for the string "array[0]"
    assert_called_exact "compiler" "array[0]"
}

@test "assert_called_exact: brackets -> fails when brackets content differs" {
    mock compiler "*" "true"
    compiler "array[0]"

    # Should fail: [0] matches [0] exactly, so [1] must fail
    # (If this were globbing, [0-1] might have matched both)
    run assert_called_exact "compiler" "array[1]"
    [ "$status" -eq 1 ]
}

@test "assert_called_exact: wildcards -> matches literal '*' without treating it as wildcard" {
    mock math "*" "true"
    math "3 * 4"

    # Should pass: matches the literal asterisk
    assert_called_exact "math" "3 * 4"
}

@test "assert_called_exact: wildcards -> fails on partial match even if wildcard present" {
    mock math "*" "true"
    math "3 * 4"

    # Should fail: In glob mode, "3*" would match. In exact mode, it must fail.
    run assert_called_exact "math" "3 *"
    [ "$status" -eq 1 ]
}

@test "assert_called_exact: control chars -> matches newlines correctly when using ANSI quoting" {
    mock logger "*" "true"
    # Call with actual newline byte
    logger "Line 1"$'\n'"Line 2"

    # Assert using actual newline byte
    assert_called_exact "logger" "Line 1"$'\n'"Line 2"
}

@test "assert_called_exact: control chars -> matches tabs correctly when using ANSI quoting" {
    mock parser "*" "true"
    # Call with actual tab byte
    parser "Col1"$'\t'"Col2"

    assert_called_exact "parser" "Col1"$'\t'"Col2"
}

@test "refute_called_exact: refute -> success when exact string not found" {
    mock git "*" "true"
    git "push"

    # "pull" is not "push", so this passes
    refute_called_exact "git" "pull"
}

@test "refute_called_exact: refute -> fail when exact string IS found" {
    mock git "*" "true"
    git "arr[0]"

    # Should fail because "arr[0]" exists in history
    run refute_called_exact "git" "arr[0]"
    [ "$status" -eq 1 ]
}

@test "assert_called_with_args: boundaries -> distinguishes one argument from two" {
    mock probe '*' true
    probe 'a b'
    assert_called_with_args probe 'a b'
    refute_called_with_args probe a b
    run assert_called_with_args probe a b
    [ "$status" -eq 1 ]
    [[ "$output" == *'Exactly 2 arguments'* ]]
    # The existing joined-text API deliberately keeps its contract.
    assert_called_exact probe a b
}

@test "assert_called_with_args: empty -> distinguishes no arguments from an empty argument" {
    mock probe '*' true
    probe
    assert_called_with_args probe
    refute_called_with_args probe ''
    probe ''
    assert_called_at_index_with_args probe 0
    assert_called_at_index_with_args probe 1 ''
    run assert_called_at_index_with_args probe 0 ''
    [ "$status" -eq 1 ]
    run assert_called_at_index_with_args probe 1
    [ "$status" -eq 1 ]
}

@test "assert_called_with_args: data -> preserves empty fields, control characters and shell syntax" {
    mock probe '*' true
    # shellcheck disable=SC2016  # these strings are data, never executable code
    local args=( '' 'a b' '' $'line\n\tend\n' '<newline>' '$(printf unexpected)' '*[?]' 'héllo' 42 )
    probe "${args[@]}"
    assert_called_with_args probe "${args[@]}"
    assert_called_at_index_with_args probe 000 "${args[@]}"
    run refute_called_with_args probe "${args[@]}"
    [ "$status" -eq 1 ]
    refute_called_with_args probe "${args[@]}" ''
}

@test "assert_called_with_args: child shell -> retains lossless call records" {
    mock probe '*' true
    run bash -c 'probe "a b" "" 123'
    [ "$status" -eq 0 ]
    assert_called_with_args probe 'a b' '' 123
    refute_called_with_args probe a b '' 123
}

@test "assert_called_with_args: history -> searches all calls and handles an empty history" {
    mock probe '*' true
    run assert_called_with_args probe
    [ "$status" -eq 1 ]
    refute_called_with_args probe
    probe first
    probe second
    assert_called_with_args probe first
    assert_called_with_args probe second
}

@test "assert_called_at_index_with_args: index -> rejects invalid and out-of-range values" {
    mock probe '*' true
    probe first
    local index
    for index in -1 '0+0' 1 18446744073709551616; do
        run assert_called_at_index_with_args probe "$index" first
        [ "$status" -eq 1 ]
        [[ "$output" != *'unbound variable'* ]]
    done
}

# ==============================================================================
# GROUP 18: EDGE CASES - CONTROL CHARACTERS & LITERALS
# ==============================================================================

@test "edge: collision -> literal '\\n' string does NOT match actual newline byte" {
    mock logger "*" "true"

    # 1. Call with the ACTUAL newline byte
    logger "Line 1"$'\n'"Line 2"

    # 2. Assert using the LITERAL string "\n" (two chars: \ and n)
    # This should FAIL because the mock received a byte, not the text "\n"
    run assert_called_exact "logger" "Line 1\nLine 2"
    [ "$status" -eq 1 ]
}

@test "edge: marker -> literal newline marker never matches a physical newline" {
    mock probe '*' true
    probe '<newline>'
    assert_called_exact probe '<newline>'
    refute_called_exact probe $'\n'
    refute_called_with probe $'\n'
    run assert_called_at_index probe 0 $'\n'
    [ "$status" -eq 1 ]
    probe $'\n'
    assert_called_exact probe $'\n'
    assert_called_at_index probe 1 $'\n'
    assert_args_contain probe $'\n'
}

@test "edge: collision -> literal '\\t' string does NOT match actual tab byte" {
    mock parser "*" "true"

    # 1. Call with ACTUAL tab byte
    parser "Col1"$'\t'"Col2"

    # 2. Assert using LITERAL string "\t"
    run assert_called_exact "parser" "Col1\tCol2"
    [ "$status" -eq 1 ]
}

@test "edge: multiple -> handles consecutive newlines correctly" {
    mock buffer "*" "true"

    # Call with double newline (paragraph break)
    buffer "Para 1"$'\n\n'"Para 2"

    assert_called_exact "buffer" "Para 1"$'\n\n'"Para 2"
}

@test "edge: mixed -> handles mixed tabs and newlines in one string" {
    mock csv "*" "true"

    # Simulating a CSV row with a newline at the end
    csv "ID"$'\t'"Name"$'\n'

    assert_called_exact "csv" "ID"$'\t'"Name"$'\n'
}

@test "edge: boundary -> handles leading and trailing control characters" {
    mock wrapper "*" "true"

    # Argument starts and ends with newline
    wrapper $'\n'"CONTENT"$'\n'

    assert_called_exact "wrapper" $'\n'"CONTENT"$'\n'
}

# ==============================================================================
# GROUP 19: STDIN CAPTURING & ASSERTIONS
# ==============================================================================

@test "stdin: basic -> captures piped input" {
    mock -stdin uploader "*" "true"

    echo "data payload" | uploader "server"

    assert_called_with "uploader" "server"
    assert_stdin_equals "uploader" "data payload"$'\n'
}

@test "stdin: multiline -> captures multiple lines with newlines" {
    mock -stdin parser "*" "true"

    # Using ANSI-C quoting for newlines
    printf "Line 1\nLine 2\n" | parser "file.txt"

    # Note: printf "...\n" puts a newline at the very end
    assert_stdin_equals "parser" "Line 1"$'\n'"Line 2"$'\n'
}

@test "stdin: exact -> preserves trailing newlines (binary fidelity)" {
    mock -stdin binary_tool "*" "true"

    # echo puts a newline at the end. The framework MUST preserve this.
    echo "content" | binary_tool

    assert_stdin_equals "binary_tool" "content"$'\n'
}

@test "stdin: replay -> piped input is passed to the mock action" {
    # If the mock is just "cat", it should output what was piped in.
    mock -stdin passthrough "*" "cat"

    run bash -c "echo 'secret' | passthrough"
    [ "$output" = "secret" ]

    # And we should still have captured it for assertion
    assert_stdin_equals "passthrough" "secret"$'\n'
}

@test "stdin: index -> assert_stdin_at_index checks specific call" {
    mock -stdin logger "*" "true"

    echo "first" | logger
    echo "second" | logger

    assert_stdin_at_index "logger" 0 "first"$'\n'
    assert_stdin_at_index "logger" 1 "second"$'\n'
}

@test "stdin: index fail -> fails on mismatch" {
    mock -stdin logger "*" "true"

    echo "first" | logger

    run assert_stdin_at_index "logger" 0 "wrong"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Stdin Mismatch"* ]]
}

@test "stdin: empty -> empty pipe results in empty string" {
    mock -stdin cmd "*" "true"
    # Pipe empty string
    printf "" | cmd
    assert_stdin_equals "cmd" ""
}

@test "stdin: no pipe -> results in empty string (and doesn't hang)" {
    mock -stdin cmd "*" "true"
    # No pipe at all
    cmd
    # If no stdin was provided, we likely want to assert it was empty
    # Note: In some environments, stdin might be open but empty.
    # The framework checks `if [ ! -t 0 ]`. In a bats test, 0 IS usually a pipe/file.
    # If it's a TTY, captured is empty.
    assert_stdin_equals "cmd" ""
}

@test "stdin: return -> writes history and removes the capture file" {
    mock -stdin probe "*" "return 7"
    run probe
    [ "$status" -eq 7 ]
    assert_stdin_at_index probe 0 ""
    local leftovers=( "$BATS_MOCK_STATE_DIR"/*.stdin.tmp.* )
    [ ! -e "${leftovers[0]}" ]
}

@test "stdin: unmatched -> keeps stdin and argument history aligned" {
    mock -stdin probe yes true
    run -127 probe no
    assert_stdin_at_index probe 0 ""
    probe yes
    assert_stdin_at_index probe 1 ""
}

@test "stdin: index -> rejects negative, arithmetic and oversized indices" {
    mock -stdin probe "*" true
    probe
    assert_stdin_at_index probe 000 ""
    local index
    for index in -1 '0+0' 18446744073709551616; do
        run assert_stdin_at_index probe "$index" ""
        [ "$status" -eq 1 ]
        [[ "$output" != *"unbound variable"* ]]
    done
}

@test "stdin: internal reads -> bypasses mocked cat" {
    mock cat "*" "echo mocked"
    mock -stdin probe "*" "command cat; return 6"
    run_with_timeout 5 bash -c 'printf payload | probe'
    [ "$status" -eq 6 ]
    [ "$output" = payload ]
    assert_stdin_equals probe payload
    refute_called cat
}

@test "stdin: marker -> literal newline marker stays distinct from physical newlines" {
    mock -stdin probe '*' 'command cat >/dev/null'
    printf '%s' '<newline>' | probe
    assert_stdin_equals probe '<newline>'
    run assert_stdin_equals probe $'\n'
    [ "$status" -eq 1 ]
    run assert_stdin_at_index probe 0 $'\n'
    [ "$status" -eq 1 ]
    printf '\n' | probe
    assert_stdin_at_index probe 1 $'\n'
}

@test "stdin: concurrent completion -> argument and stdin indexes refer to the same call" {
    # shellcheck disable=SC2016  # expanded when the mock action runs
    mock -stdin probe '*' '
        command cat >/dev/null
        if [[ $1 == first ]]; then
            : > "$BATS_TEST_TMPDIR/first-started"
            while [[ ! -f "$BATS_TEST_TMPDIR/release-first" ]]; do command sleep 0.01; done
        fi
    '
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c '
        printf first-input | probe first &
        first_pid=$!
        while [[ ! -f "$BATS_TEST_TMPDIR/first-started" ]]; do sleep 0.01; done
        printf second-input | probe second
        : > "$BATS_TEST_TMPDIR/release-first"
        wait "$first_pid"
    '
    [ "$status" -eq 0 ]
    assert_called_at_index_with_args probe 0 first
    assert_called_at_index_with_args probe 1 second
    assert_stdin_at_index probe 0 first-input
    assert_stdin_at_index probe 1 second-input
    assert_stdin_complete probe 0
    assert_stdin_complete probe 1
}

@test "stdin: complete -> records EOF after the action consumes the stream" {
    mock -stdin probe '*' 'command cat >/dev/null'
    printf 'payload\n\n' | probe
    assert_stdin_equals probe $'payload\n\n'
    assert_stdin_complete probe 000
}

@test "stdin: partial -> bounded capture does not claim to have reached EOF" {
    mock -stdin probe '*' true
    run_with_timeout 5 bash -c 'yes payload | probe'
    [ "$status" -eq 0 ]
    run assert_stdin_complete probe 0
    [ "$status" -eq 1 ]
    [[ "$output" == *partial* ]]
}

@test "stdin: unavailable -> unmatched calls and missing indexes are not complete" {
    mock -stdin probe yes true
    run -127 probe no
    run assert_stdin_complete probe 0
    [ "$status" -eq 1 ]
    [[ "$output" == *unavailable* ]]
    run assert_stdin_complete probe 1
    [ "$status" -eq 1 ]
    run assert_stdin_complete probe '0+0'
    [ "$status" -eq 1 ]
}

# ==============================================================================
# GROUP 20: SPY REGRESSIONS (Side Effects & Streaming)
# ==============================================================================

@test "spy: side effects -> preserves global variable modifications" {
    global_var="original"
    modifier() { global_var="modified"; }
    mock_spy modifier

    modifier

    [ "$global_var" = "modified" ]
}

@test "spy: streaming -> does not hang on infinite input" {
    # If the mock buffers, this will hang
    mock_spy head

    # yes produces infinite 'y'
    # head -n 1 reads one line and exits
    # The mock must handle this gracefully, propagating the SIGPIPE
    run_with_timeout 5 bash -c "yes | head -n 1"

    [ "$status" -eq 0 ]
    [ "$output" = y ]
    assert_called_once_with head "-n 1"
}

@test "spy: child shell -> exports the saved function" {
    # shellcheck disable=SC2329  # invoked in the child shell
    original_child() { printf '%s\n' "$1"; }
    mock_spy original_child
    run_with_timeout 5 bash -c 'original_child hello'
    [ "$status" -eq 0 ]
    [ "$output" = hello ]
    assert_called_once_with original_child hello
}

@test "spy: repeated registration -> retains the original and call history" {
    original() { echo original; }
    mock_spy original
    original
    mock_spy original
    run_with_timeout 5 bash -c 'original'
    [ "$status" -eq 0 ]
    [ "$output" = original ]
    assert_called_times original 2
}

@test "spy: open stdin -> ignored TERM cannot strand the capture process" {
    original() { return 7; }
    mock_spy -stdin original
    local fifo="$BATS_TEST_TMPDIR/open-input"
    mkfifo "$fifo"
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c 'exec 9<> "$1"; trap "" TERM; original <&9' _ "$fifo"
    [ "$status" -eq 7 ]
    [ "$output" = "" ]
    assert_stdin_at_index original 0 ""
}

@test "spy: open stdin -> no-op returns without waiting for EOF" {
    local fifo="$BATS_TEST_TMPDIR/open-input"
    mkfifo "$fifo"
    # Isolate the spy because Bats itself calls true while collecting output.
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c '
        source "$1"
        mock_spy true
        exec 9<> "$2"
        true <&9
        assert_called_times true 1
    ' _ "$BATS_TEST_DIRNAME/../load.bash" "$fifo"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times true 1
}

@test "spy: no-op -> consistently captures a short finite input" {
    # shellcheck disable=SC2329  # invoked in the child shell
    ignore_input() { :; }
    mock_spy -stdin ignore_input
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 15 bash -c '
        for ((i=0; i<50; i++)); do
            printf "payload-%s\n" "$i" | ignore_input || exit
        done
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    local i
    for ((i=0; i<50; i++)); do
        assert_stdin_at_index ignore_input "$i" "payload-$i"$'\n'
    done
}

@test "spy: no-op -> does not drain an infinite producer forever" {
    ignore_input() { :; }
    mock_spy ignore_input
    run_with_timeout 5 bash -c 'yes | ignore_input'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times ignore_input 1
}

@test "spy: concurrency -> parallel finite streams retain every call" {
    mock_spy -stdin cat
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 10 bash -c '
        pids=()
        for ((i=0; i<20; i++)); do
            printf "payload-%s\n" "$i" | cat >/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" || exit; done
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times cat 20
    local i
    for ((i=0; i<20; i++)); do
        assert_stdin_equals cat "payload-$i"$'\n'
    done
}

@test "spy: log lock -> times out and removes the capture file" {
    mock_spy -stdin head
    mkdir "$BATS_MOCK_STATE_DIR/head.stdin.log.lock"
    slow_lock_attempts "$BATS_MOCK_STATE_DIR/head.stdin.log.lock"
    run_with_timeout 15 bash -c 'head -n 1 </dev/null'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MOCK TIMEOUT"* ]]
    local leftovers=( "$BATS_MOCK_STATE_DIR"/*.stdin.tmp.* )
    [ ! -e "${leftovers[0]}" ]
    [ -d "$BATS_MOCK_STATE_DIR/head.stdin.log.lock" ]
    rmdir "$BATS_MOCK_STATE_DIR/head.stdin.log.lock"
    run head -n 1 </dev/null
    [ "$status" -eq 0 ]
    assert_called_times head 2
}

@test "spy: cleanup -> does not terminate children started by the action" {
    # shellcheck disable=SC2034  # waited for in the child shell
    launch_child() { sleep 0.2 & action_pid=$!; }
    mock_spy launch_child
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c '
        launch_child </dev/null
        wait "$action_pid"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times launch_child 1
}

@test "spy: nested stream -> infinite producer terminates after the first line" {
    mock_spy cat
    mock_spy head
    run_with_timeout 5 bash -c 'yes | cat | head -n 1'
    [ "$status" -eq 0 ]
    [ "$output" = y ]
    assert_called_times cat 1
    assert_called_once_with head "-n 1"
}

@test "spy: finite stream -> forwards and captures more than a pipe buffer" {
    mock_spy -stdin cat
    run_with_timeout 5 bash -o pipefail -c 'dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr "\000" x | cat | wc -c'
    [ "$status" -eq 0 ]
    [ "${output//[[:space:]]/}" = 131072 ]
    local captured_bytes
    captured_bytes=$(wc -c < "$BATS_MOCK_STATE_DIR/cat.stdin.log")
    [ "${captured_bytes//[[:space:]]/}" = 131073 ]
    assert_called_times cat 1
}

@test "spy: newline-heavy stream -> encodes logs without quadratic slowdown" {
    mock_spy -stdin cat
    run_with_timeout 5 bash -o pipefail -c 'awk "BEGIN { for (i=0; i<65536; i++) print \"x\" }" | cat | wc -l'
    [ "$status" -eq 0 ]
    [ "${output//[[:space:]]/}" = 65536 ]
    local captured_bytes
    captured_bytes=$(wc -c < "$BATS_MOCK_STATE_DIR/cat.stdin.log")
    [ "${captured_bytes//[[:space:]]/}" = 655361 ]
    assert_called_times cat 1
}

@test "spy: pipefail -> preserves the producer SIGPIPE status" {
    mock_spy head
    run_with_timeout 5 bash -o pipefail -c 'yes | head -n 1'
    [ "$status" -eq 141 ]
    [ "$output" = y ]
    assert_called_once_with head "-n 1"
}

@test "spy: inherited traps -> preserves the callers signal handlers" {
    mock_spy head
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c '
        trap "echo unexpected-signal" PIPE TERM
        before=$(trap -p PIPE TERM)
        head -n 1 </dev/null
        [[ $(trap -p PIPE TERM) == "$before" ]]
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "spy: side effects -> preserves changes while reading stdin" {
    # shellcheck disable=SC2034  # inspected by the child shell after the spy returns
    consume_line() { IFS= read -r consumed_line; return 17; }
    mock_spy -stdin consume_line
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 5 bash -c '
        result=0
        consume_line <<< payload || result=$?
        [[ $result == 17 && $consumed_line == payload ]]
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_stdin_equals consume_line $'payload\n'
}

@test "spy: cleanup -> repeated direct calls reap their capture processes" {
    mock_spy head
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 10 bash -c '
        for ((i=0; i<25; i++)); do
            head -n 1 </dev/null || exit
            [[ -z $(jobs -pr) ]] || exit 1
        done
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times head 25
}

@test "spy: partial read -> preserves output and nonzero status" {
    first_line() { local line; IFS= read -r line; printf '%s\n' "$line"; return 23; }
    mock_spy first_line
    run_with_timeout 5 bash -c 'yes payload | first_line'
    [ "$status" -eq 23 ]
    [ "$output" = payload ]
    assert_called_times first_line 1
}

@test "spy: cleanup -> repeated calls leave no capture files or live children" {
    mock_spy head
    # shellcheck disable=SC2016  # expanded in the child shell
    run_with_timeout 15 bash -c '
        for ((i=0; i<50; i++)); do
            result=$(yes | head -n 1) || exit
            [[ $result == y ]] || exit 1
        done
        [[ -z $(jobs -pr) ]]
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    assert_called_times head 50
    local leftovers=( "$BATS_MOCK_STATE_DIR"/*.stdin.tmp.* )
    [ ! -e "${leftovers[0]}" ]
}
