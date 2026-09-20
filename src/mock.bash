#############################################
#
# Stealth Mock Framework
# ==============================================================================
# Mocks, call-through spies and interaction assertions for bats-core.
#
# Features:
#    - Compilation: Generated wrappers with cached argument-matching rules.
#    - Validation: Registered assertion targets and owned session directories.
#    - Concurrency: Atomic locking for sequence mocks.
#    - Regex Support: Prefix patterns with '~' for regular expressions.
#    - Restoration: Automatically backs up and restores original functions.
#    - I/O Capture: Non-blocking capture of stdin supporting streams.
#
# Usage:
#    load "mock.bash"
#
#    setup() {
#        mock_setup
#    }
#
#    teardown() {
#        mock_teardown
#    }
# ==============================================================================

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================

: "${BATS_MOCK_TMPDIR:=${BATS_TEST_TMPDIR:-/tmp}}"
: "${BATS_MOCK_STATE_DIR:=${BATS_MOCK_TMPDIR}/mocks}"
: "${BATS_MOCK_GLOBAL_LOG:=${BATS_MOCK_STATE_DIR}/global.log}"
: "${BATS_MOCK_STRICT:=1}"

export BATS_MOCK_TMPDIR
export BATS_MOCK_STATE_DIR
export BATS_MOCK_STRICT
export BATS_MOCK_GLOBAL_LOG

# Internal prefix to avoid namespace collisions
if [[ "${BATS_MOCK_PREFIX:-}" != "_BATS_MOCK" ]]; then
    readonly BATS_MOCK_PREFIX="_BATS_MOCK"
fi

# ==============================================================================
# INTERNAL UTILITIES
# ==============================================================================

#######################################
# Acquires an atomic lock for a specific directory.
# Uses mkdir atomicity to prevent race conditions. The five-second deadline
# includes command execution and scheduling time, not just time spent sleeping.
#
# Arguments:
#    $1 (String) - _lock_dir_path: The directory path to lock (suffix .lock will be appended).
# Returns:
#    0 - If lock acquired successfully.
#    1 - If lock acquisition times out.
#######################################
mock::sync::lock() {
    local _lock_dir_path="$1.lock"
    local _lock_deadline=$((SECONDS + 5))
    local -i _lock_tries=0

    while ! command mkdir -- "$_lock_dir_path" 2>/dev/null; do
        if (( SECONDS >= _lock_deadline )); then
            echo "MOCK TIMEOUT: Could not acquire lock for $1" >&2
            return 1
        fi
        ((_lock_tries+=1))
        if (( _lock_tries > 16 )); then command sleep 0.05; fi
    done
    return 0
}

#######################################
# Releases the atomic lock.
#
# Arguments:
#    $1 (String) - _unlock_dir: The directory path to unlock.
#######################################
mock::internal::unlock() {
    local _unlock_dir="$1.lock"
    rmdir "$_unlock_dir" 2>/dev/null || true
}

#######################################
# Formats a message block with a prominent border.
#
# Arguments:
#    $1 (String) - _frame_title: The title of the message frame.
#    $2 (String) - _frame_body: The content of the message.
#    $3 (Integer) - _frame_fd: Optional file descriptor (defaults to 2 for stderr).
#######################################
mock::report::frame() {
    local _frame_title="$1"
    local _frame_body="$2"
    local _frame_fd="${3:-2}"
    {
        echo "================================================================================"
        echo "  $_frame_title"
        echo "================================================================================"
        echo "$_frame_body"
        echo "================================================================================"
    } >&"$_frame_fd"
}

#######################################
# Reads the content of a mock's log file.
#
# Arguments:
#    $1 (String) - _glc_cmd: The name of the mocked command.
#    $2 (String) - _glc_type: "args" (default) or "stdin".
# Returns:
#    String - Log content or "<EMPTY LOG>" if empty.
#######################################
mock::internal::get_log_content() {
    local _glc_cmd="$1"
    local _glc_type="${2:-args}"
    local _glc_suffix=".log"

    if [[ "$_glc_type" == argv ]]; then
        local _glc_count=0 _glc_index _glc_text _glc_args=()
        IFS= read -r _glc_count < "$BATS_MOCK_STATE_DIR/$_glc_cmd.next" || return 1
        [[ "$_glc_count" =~ ^[0-9]+$ && ${#_glc_count} -le 15 ]] || return 1
        for ((_glc_index=0; _glc_index<_glc_count && _glc_index<10; _glc_index++)); do
            mapfile -d '' -t _glc_args < "$BATS_MOCK_STATE_DIR/$_glc_cmd.calls/$_glc_index/argv" || return 1
            builtin printf -v _glc_text '%q ' "${_glc_args[@]}"
            _glc_text="${#_glc_args[@]} arguments: $_glc_text"
            if (( ${#_glc_text} > 240 )); then _glc_text="${_glc_text:0:240}..."; fi
            builtin printf '%s\n' "$_glc_text"
        done
        if (( _glc_count == 0 )); then builtin printf '%s\n' '<EMPTY LOG>'; fi
        if (( _glc_count > 10 )); then builtin printf '... and %s more calls\n' "$((_glc_count - 10))"; fi
        return 0
    fi

    if [[ "$_glc_type" == "stdin" ]]; then
        _glc_suffix=".stdin.log"
    fi

    local _glc_log_file="${BATS_MOCK_STATE_DIR}/${_glc_cmd}${_glc_suffix}"
    if [[ -s "$_glc_log_file" ]]; then
        command awk '
            NR <= 10 { print (length($0) > 240 ? substr($0, 1, 240) "..." : $0) }
            END { if (NR > 10) printf "... and %d more calls\n", NR - 10 }
        ' "$_glc_log_file"
    else
        builtin printf '%s\n' '<EMPTY LOG>'
    fi
}

#######################################
# Reports a test failure with detailed context.
#
# Arguments:
#    $1 (String) - _rep_cmd: The command name.
#    $2 (String) - _rep_type: The type of failure (e.g., "Argument Mismatch").
#    $3 (String) - _rep_expected: Description of what was expected.
#    $4 (String) - _rep_label: Label for the actual value (e.g., "Actual").
#    $5 (String) - _rep_content: The actual value found (or "__HISTORY__" to dump log).
# Returns:
#    1 - Always returns 1 to signal failure.
#######################################
mock::report::fail() {
    local _rep_cmd="$1"
    local _rep_type="$2"
    local _rep_expected="$3"
    local _rep_label="$4"
    local _rep_content="$5"

    # Expand history if requested
    if [[ "$_rep_content" == "__HISTORY__" || "$_rep_content" == "__ARGV_HISTORY__" ]]; then
        local _rep_log_content _rep_history_type=args
        if [[ "$_rep_content" == '__ARGV_HISTORY__' ]]; then _rep_history_type=argv; fi
        _rep_log_content=$(mock::internal::get_log_content "$_rep_cmd" "$_rep_history_type")
        if [[ "$_rep_log_content" == "<EMPTY LOG>" ]]; then
            _rep_content="(No calls recorded)"
        else
            # Number the lines for clearer history visibility using awk
            _rep_content=$(echo "$_rep_log_content" | awk '{printf "%3d. %s\n", NR, $0}')
            _rep_content="${_rep_content%$'\n'}"
        fi
    fi

    # Expand STDIN history if requested
    if [[ "$_rep_content" == "__STDIN_HISTORY__" ]]; then
        local _rep_log_content
        _rep_log_content=$(mock::internal::get_log_content "$_rep_cmd" "stdin")
        if [[ "$_rep_log_content" == "<EMPTY LOG>" ]]; then
            _rep_content="(No stdin recorded)"
        else
            _rep_content=$(echo "$_rep_log_content" | awk '{printf "%3d. %s\n", NR, $0}')
            _rep_content="${_rep_content%$'\n'}"
        fi
    fi

    local _rep_width=10
    local _rep_body=""

    printf -v _rep_body "  %-*s : %s" "$_rep_width" "Command" "$_rep_cmd"

    local _rep_expected_str
    printf -v _rep_expected_str "\n  %-*s : %s" "$_rep_width" "Expected" "$_rep_expected"
    _rep_body+="$_rep_expected_str"

    if [[ "$_rep_content" == *$'\n'* ]] || [[ "$_rep_label" == "History" ]]; then
        local _rep_label_str
        printf -v _rep_label_str "\n  %-*s :" "$_rep_width" "$_rep_label"
        _rep_body+="$_rep_label_str"

        local _rep_indented_content
        _rep_indented_content=$(printf "%s" "$_rep_content" | sed 's/^/  /')
        _rep_body+=$'\n'"$_rep_indented_content"
    else
        local _rep_actual_str
        printf -v _rep_actual_str "\n  %-*s : %s" "$_rep_width" "$_rep_label" "$_rep_content"
        _rep_body+="$_rep_actual_str"
    fi

    mock::report::frame "MOCK ASSERTION FAILED: $_rep_type" "$_rep_body"
    return 1
}

# ==============================================================================
# CORE ENGINE (JIT & RULE MANAGEMENT)
# ==============================================================================

# Memo table for sanitize_ref. Cleared with the session by mock_teardown.
declare -gA _BATS_MOCK_SAFE=()

#######################################
# Writes the sanitized name into the nameref named by $1.
# A command substitution costs a subshell on a path that runs for every
# registration, every compile and every unmock, so this form avoids one.
#
# Arguments:
#    $1 (Nameref) - Output variable.
#    $2 (String)  - The string to sanitize.
#######################################
mock::internal::sanitize_ref() {
    local -n _sr_out="$1"
    local _sr_in="$2"
    if [[ -n "${_BATS_MOCK_SAFE[$_sr_in]:-}" ]]; then
        _sr_out="${_BATS_MOCK_SAFE[$_sr_in]}"
        return 0
    fi
    local _sr_v="$_sr_in"
    if [[ "$_sr_v" == *[!a-zA-Z0-9_]* ]]; then
        # The reserved prefix separates encoded names from ordinary identifiers.
        _sr_v="${_sr_v//_/_u}"
        _sr_v="${_sr_v//./_d}"
        _sr_v="${_sr_v//:/_c}"
        _sr_v="${_sr_v//-/_h}"
        _sr_v="${BATS_MOCK_PREFIX}_ENCODED_${_sr_v}"
    fi
    _BATS_MOCK_SAFE["$_sr_in"]="$_sr_v"
    _sr_out="$_sr_v"
}

#######################################
# Validates a command name before generating code or writing state files.
#######################################
mock::internal::validate_name() {
    local _vn_cmd="${1:-}"
    if [[ ! "$_vn_cmd" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
        printf "MOCK ERROR: Invalid function name '%s'. Mocks must not contain shell meta-characters.\n" "$_vn_cmd" >&2
        return 1
    fi

    case "$_vn_cmd" in
        mock|unmock|mock_*|mock::*|_BATS_MOCK*|assert_called*|refute_called*|assert_stdin*|assert_args_contain|assert_call_sequence)
            printf "MOCK ERROR: '%s' is a reserved framework function and cannot be mocked.\n" "$_vn_cmd" >&2
            return 1
            ;;
    esac
}

#######################################
# Normalizes an unsigned decimal without evaluating arithmetic expressions.
#######################################
mock::internal::decimal() {
    local _dec_value="${1:-}"
    if [[ ! "$_dec_value" =~ ^[0-9]+$ ]]; then
        printf "MOCK ERROR: Expected a non-negative decimal integer, got '%s'.\n" "$_dec_value" >&2
        return 1
    fi
    _dec_value="${_dec_value#"${_dec_value%%[!0]*}"}"
    printf '%s\n' "${_dec_value:-0}"
}

#######################################
# Rejects malformed regexes before a rule or assertion can silently ignore them.
#######################################
mock::internal::validate_pattern() {
    [[ "${1:0:1}" == '~' ]] || return 0
    local _vp_regex="${1:1}" _vp_status=0
    # shellcheck disable=SC2319  # distinguish invalid ERE (2) from no match (1)
    [[ '' =~ $_vp_regex ]] || _vp_status=$?
    if (( _vp_status == 2 )); then
        printf "MOCK ERROR: Invalid regular expression '%s'.\n" "$_vp_regex" >&2
        return 1
    fi
}

#######################################
# Assertions must target a live registration, including negative assertions.
#######################################
mock::internal::require_registered() {
    mock::internal::validate_name "${1:-}" || return 1
    if [[ ! -f "$BATS_MOCK_STATE_DIR/$1.rules" ]]; then
        mock::report::fail "$1" "Unregistered Mock" "A registered mock or spy" \
            "Status" "No history: register '$1' with mock or mock_spy first"
        return 1
    fi
}

mock::internal::assert_command() {
    local _ac_min=$1 _ac_max=$2
    shift 2
    if (( $# < _ac_min || (_ac_max >= 0 && $# > _ac_max) )); then
        printf 'MOCK ERROR: Invalid arguments for %s.\n' "${FUNCNAME[1]}" >&2
        return 1
    fi
    mock::internal::require_registered "$1"
}

#######################################
# JIT Compiles a mock function based on registered rules.
# Optimizes performance by checking a dirty flag before recompiling.
# Supports Glob (default) and Regex (prefix '~') matching.
# Uses Process Substitution for non-blocking stdin capture.
#
# Arguments:
#    $1 (String) - _jit_cmd: The name of the command to compile.
# Globals:
#    Reads/Writes BATS_MOCK_STATE_DIR
#######################################
mock::jit::compile() {
    local _jit_cmd="$1"
    local _jit_safe_cmd
    mock::internal::sanitize_ref _jit_safe_cmd "$_jit_cmd"

    local _jit_dirty_var="${BATS_MOCK_PREFIX}_DIRTY_${_jit_safe_cmd}"
    if [[ "${!_jit_dirty_var:-0}" -eq 0 ]] && declare -f -- "$_jit_cmd" >/dev/null; then
        return 0
    fi

    local _jit_rules_file="${BATS_MOCK_STATE_DIR}/${_jit_cmd}.rules"
    local _jit_patterns=()
    local _jit_actions=()

    if [[ -f "$_jit_rules_file" ]]; then
        while IFS= read -r -d '' _jit_pat && IFS= read -r -d '' _jit_act; do
            _jit_patterns+=("$_jit_pat")
            _jit_actions+=("$_jit_act")
        done < "$_jit_rules_file"
    fi

    local _jit_count=${#_jit_patterns[@]}
    local _jit_i
    for ((_jit_i=0; _jit_i<_jit_count; _jit_i++)); do
        local _jit_pat_var="${BATS_MOCK_PREFIX}_RULE_${_jit_safe_cmd}_${_jit_i}_PAT"
        local _jit_act_var="${BATS_MOCK_PREFIX}_RULE_${_jit_safe_cmd}_${_jit_i}_ACT"

        printf -v "$_jit_pat_var" "%s" "${_jit_patterns[$_jit_i]}"
        printf -v "$_jit_act_var" "%s" "${_jit_actions[$_jit_i]}"
        export "${_jit_pat_var?}" "${_jit_act_var?}"
    done
    export "${BATS_MOCK_PREFIX}_RULE_COUNT_${_jit_safe_cmd}=$_jit_count"

    local _jit_state_dir _jit_global_log
    printf -v _jit_state_dir '%q' "$BATS_MOCK_STATE_DIR"
    printf -v _jit_global_log '%q' "$BATS_MOCK_GLOBAL_LOG"

    # A separate function contains action-level `return` without losing side effects.
    local _jit_action_func="${BATS_MOCK_PREFIX}_ACTION_${_jit_safe_cmd}"
    local _jit_func_body="${_jit_action_func}() {
        eval \"\${!act_var}\"
    }
    "

    # 1. Logging Logic (Global & Local)
    _jit_func_body+="${_jit_cmd}() {
        local args
        local _mock_state_dir=$_jit_state_dir
        local _mock_global_log=$_jit_global_log
        builtin printf -v args '%s ' \"\$@\"
        args=\"\${args% }\"
        local cmd_name=\"${_jit_cmd}\"
        local timestamp
        builtin printf -v timestamp \"%(%s)T\" -1 2>/dev/null || timestamp=\$(command date +%s)

        # Generate a unique temp file for stdin capture for this specific call
        local stdin_tmp

        local serialized_args
        builtin printf -v serialized_args \"%q \" \"\$@\"
        serialized_args=\"\${serialized_args% }\"

        local log_safe_args=\"\${args//\$'\n'/<newline>}\"

        # Reserve a per-command index and publish invocation order under one lock.
        # Release it before running user code, including nested mocks.
        local _mock_history_lock=\"\$_mock_state_dir/history.lock\"
        local _mock_history_deadline=\$((SECONDS + 5))
        local -i _mock_history_tries=0
        while ! command mkdir -- \"\$_mock_history_lock\" 2>/dev/null; do
            if (( SECONDS >= _mock_history_deadline )); then
                builtin printf 'MOCK TIMEOUT: Could not acquire call history lock\\n' >&2
                return 1
            fi
            ((_mock_history_tries+=1))
            if (( _mock_history_tries > 16 )); then command sleep 0.05; fi
        done
        local _mock_call_index
        if ! IFS= read -r _mock_call_index < \"\$_mock_state_dir/${_jit_cmd}.next\" ||
           [[ ! \$_mock_call_index =~ ^[0-9]+$ || \${#_mock_call_index} -gt 15 ]]; then
            command rmdir -- \"\$_mock_history_lock\"
            builtin printf 'MOCK ERROR: Invalid call counter\\n' >&2
            return 1
        fi
        local _mock_call_dir=\"\$_mock_state_dir/${_jit_cmd}.calls/\$_mock_call_index\"
        if command mkdir -- \"\$_mock_call_dir\" &&
           builtin printf '%s\\0' \"\$args\" > \"\$_mock_call_dir/args\" &&
           { if (( \$# > 0 )); then builtin printf '%s\\0' \"\$@\"; fi; } > \"\$_mock_call_dir/argv\" &&
           builtin printf '%s\\n' \"\$((10#\$_mock_call_index + 1))\" > \"\$_mock_state_dir/${_jit_cmd}.next\" &&
           builtin printf \"[%s] %s %s\n\" \"\$timestamp\" \"\$cmd_name\" \"\$serialized_args\" >> \"\$_mock_global_log\" &&
           builtin printf \"%s\n\" \"\$log_safe_args\" >> \"\$_mock_state_dir/${_jit_cmd}.log\"; then
            command rmdir -- \"\$_mock_history_lock\" || return 1
        else
            command rmdir -- \"\$_mock_history_lock\" 2>/dev/null || :
            return 1
        fi
    "

    # 2. Matching Logic (LIFO)
    # Uses process substitution < <(tee) to stream stdin to the action
    # while capturing it, ensuring strict side-effect preservation.
    _jit_func_body+="
        local i
        local count=\${${BATS_MOCK_PREFIX}_RULE_COUNT_${_jit_safe_cmd}:-0}
        local return_code=0
        local executed=0
        local _mock_stdin_state=unavailable

        for ((i=count-1; i>=0; i--)); do
            local pat_var=\"${BATS_MOCK_PREFIX}_RULE_${_jit_safe_cmd}_\${i}_PAT\"
            local act_var=\"${BATS_MOCK_PREFIX}_RULE_${_jit_safe_cmd}_\${i}_ACT\"
            local pattern=\"\${!pat_var}\"
            local matched=0

            if [[ \"\${pattern:0:1}\" == \"~\" ]]; then
                local regex=\"\${pattern:1}\"
                if [[ \"\$args\" =~ \$regex ]]; then matched=1; fi
            elif [[ \"\$args\" == \$pattern ]]; then
                matched=1
            fi

            if [[ \"\$matched\" -eq 1 ]]; then
                if [[ ! -t 0 ]]; then
                    stdin_tmp=\$(command mktemp \"\$_mock_state_dir/${_jit_cmd}.stdin.tmp.XXXXXXXX\") || return 1
                    # Exec makes the saved PID the capture process, not a shell that
                    # could leave a tee child holding the pipeline open.
                    local stdin_fd
                    exec {stdin_fd}< <(trap '' PIPE; exec tee \"\$stdin_tmp\")
                    local stdin_pid=\$!

                    if ${_jit_action_func} \"\$@\" <&\$stdin_fd; then
                        return_code=0
                    else
                        return_code=\$?
                    fi

                    # Give finite input a chance to finish even when the action
                    # reads nothing. Both a byte limit and a deadline are needed:
                    # neither an infinite producer nor an idle pipe may block us.
                    local unread_stdin _mock_drain_status=0
                    LC_ALL=C builtin read -r -t 0.1 -N 65536 unread_stdin <&\$stdin_fd || _mock_drain_status=\$?
                    _mock_stdin_state=partial
                    if (( _mock_drain_status == 1 )); then _mock_stdin_state=complete; fi

                    # The action is finished; stop only our capture child. TERM
                    # can be inherited as ignored, leaving wait blocked forever.
                    builtin kill -KILL \"\$stdin_pid\" 2>/dev/null || :

                    # Wait for process termination to avoid race conditions on log file access
                    builtin wait \"\$stdin_pid\" 2>/dev/null || :
                    # Keep the reader open until tee exits, avoiding a BSD tee
                    # broken-pipe diagnostic between closing and terminating it.
                    exec {stdin_fd}<&-
                else
                    if ${_jit_action_func} \"\$@\"; then
                        return_code=0
                    else
                        return_code=\$?
                    fi
                fi
                executed=1
                break
            fi
        done

        # 3. Strict Mode & Post-Execution Logging
        if [[ \"\$executed\" -eq 0 ]]; then
             if [[ \"\${BATS_MOCK_STRICT:-0}\" -eq 1 ]]; then
                echo \"MOCK ERROR: '${_jit_cmd}' called with unexpected args: '\$args'\" >&2
                return_code=127
             fi
        fi

        # Serialize complete records, including large records that require more
        # than one write. A stale lock must fail instead of hanging the caller.
        local stdin_lock=\"\$_mock_state_dir/${_jit_cmd}.stdin.log.lock\"
        local _mock_stdin_deadline=\$((SECONDS + 5))
        local -i _mock_stdin_tries=0
        while ! command mkdir -- \"\$stdin_lock\" 2>/dev/null; do
             if (( SECONDS >= _mock_stdin_deadline )); then
                 builtin printf 'MOCK TIMEOUT: Could not acquire stdin log lock for %s\\n' \"\$cmd_name\" >&2
                 [[ -z \"\${stdin_tmp:-}\" ]] || command rm -f -- \"\$stdin_tmp\"
                 return 1
             fi
             ((_mock_stdin_tries+=1))
             if (( _mock_stdin_tries > 16 )); then command sleep 0.05; fi
        done

        local log_status=0
        # Process the captured stdin log after action completion
        if [[ -f \"\${stdin_tmp:-}\" ]]; then
             # Stream the encoding: Bash replacement is quadratic on dense
             # newlines. The sentinel preserves an unterminated final line.
             { command cat -- \"\$stdin_tmp\"; builtin printf x; } |
                 LC_ALL=C command awk '
                     NR > 1 { printf \"%s<newline>\", previous }
                     { previous = \$0 }
                     END { printf \"%s\\n\", substr(previous, 1, length(previous) - 1) }
                 ' >> \"\$_mock_state_dir/${_jit_cmd}.stdin.log\" || log_status=\$?
             command mv -- \"\$stdin_tmp\" \"\$_mock_call_dir/stdin\" || log_status=\$?
        else
             # Log empty line to maintain index alignment with args log
             builtin printf '\n' >> \"\$_mock_state_dir/${_jit_cmd}.stdin.log\" || log_status=\$?
             : > \"\$_mock_call_dir/stdin\" || log_status=\$?
        fi
        builtin printf '%s\\n' \"\$_mock_stdin_state\" > \"\$_mock_call_dir/capture\" || log_status=\$?
        builtin printf '%s\\n' \"\$return_code\" > \"\$_mock_call_dir/status\" || log_status=\$?
        command rmdir -- \"\$stdin_lock\" || log_status=\$?
        (( log_status == 0 )) || return \$log_status

        return \$return_code
    }"

    eval "$_jit_func_body" || return 1
    export -f "${_jit_action_func?}"
    if [[ "$_jit_cmd" =~ ^[a-zA-Z0-9_]+$ ]]; then
        export -f "${_jit_cmd?}"
    fi

    printf -v "$_jit_dirty_var" "0"
    export "${_jit_dirty_var?}"
}

#######################################
# Adds a new rule to a mock.
#
# Arguments:
#    $1 (String) - _ar_cmd_name: The command to mock.
#    $2 (String) - _ar_pattern: The argument pattern (glob or regex with '~').
#    $3 (String) - _ar_action: The shell code to execute on match.
# Globals:
#    Writes to BATS_MOCK_STATE_DIR
#######################################
mock::jit::add_rule() {
    local _ar_cmd_name="$1"
    local _ar_pattern="$2"
    local _ar_action="$3"
    local _ar_rules_file="${BATS_MOCK_STATE_DIR}/${_ar_cmd_name}.rules"

    printf "%s\0%s\0" "$_ar_pattern" "$_ar_action" >> "$_ar_rules_file" || return 1

    local _ar_safe_cmd
    mock::internal::sanitize_ref _ar_safe_cmd "$_ar_cmd_name"
    local _ar_dirty_var="${BATS_MOCK_PREFIX}_DIRTY_${_ar_safe_cmd}"
    printf -v "$_ar_dirty_var" "1"
    export "${_ar_dirty_var?}"
}

# ==============================================================================
# PUBLIC API
# ==============================================================================

#######################################
# Initializes the mocking environment.
# Must be called in `setup()`.
#
# Globals:
#    BATS_MOCK_STATE_DIR
#    BATS_MOCK_GLOBAL_LOG
#######################################
mock_setup() {
    if (( $# != 0 )); then
        printf '%s\n' 'MOCK ERROR: Usage: mock_setup' >&2
        return 1
    fi
    if [[ -n "${_BATS_MOCK_SESSION_DIR:-}" ]]; then
        mock::internal::require_session
        return $?
    fi
    # Never adopt an existing directory: it may contain unrelated user files.
    if [[ -z "$BATS_MOCK_STATE_DIR" || -e "$BATS_MOCK_STATE_DIR" || -L "$BATS_MOCK_STATE_DIR" ]]; then
        printf '%s\n' 'MOCK ERROR: State directory must be a new, dedicated directory.' >&2
        return 1
    fi
    local _setup_parent _setup_name _setup_dir
    _setup_parent=$(command dirname -- "$BATS_MOCK_STATE_DIR")
    _setup_name=$(command basename -- "$BATS_MOCK_STATE_DIR")
    [[ "$_setup_name" != . && "$_setup_name" != .. ]] || return 1
    command mkdir -p -- "$_setup_parent" || return 1
    _setup_parent=$(builtin cd -P -- "$_setup_parent" && builtin pwd -P) || return 1
    _setup_dir="${_setup_parent%/}/$_setup_name"
    (umask 077; command mkdir -- "$_setup_dir") || return 1
    export BATS_MOCK_STATE_DIR="$_setup_dir"
    if [[ "$BATS_MOCK_GLOBAL_LOG" != /* ]]; then
        export BATS_MOCK_GLOBAL_LOG="$PWD/$BATS_MOCK_GLOBAL_LOG"
    fi
    declare -gA _BATS_MOCK_SAFE=()
    export _BATS_MOCK_SESSION_DIR="$_setup_dir"
    export _BATS_MOCK_SESSION_CONFIG="$BATS_MOCK_STATE_DIR"
    export _BATS_MOCK_SESSION_TOKEN="${BASHPID:-$$}:$RANDOM:$RANDOM"
    builtin printf '%s\n' "$_BATS_MOCK_SESSION_TOKEN" > "$_setup_dir/.owner" || return 1
    : > "$BATS_MOCK_GLOBAL_LOG"
}

#######################################
# Check both the configured path and the marker before touching session state.
#######################################
mock::internal::require_session() {
    local _session_dir="${_BATS_MOCK_SESSION_DIR:-}"
    if [[ -z "$_session_dir" || "$BATS_MOCK_STATE_DIR" != "${_BATS_MOCK_SESSION_CONFIG:-}" ||
          ! -d "$_session_dir" || -L "$_session_dir" || -L "$BATS_MOCK_STATE_DIR" ||
          ! -f "$_session_dir/.owner" || -L "$_session_dir/.owner" ]]; then
        printf '%s\n' 'MOCK ERROR: No owned session at the configured path; call mock_setup first.' >&2
        return 1
    fi
    local _rs_owner=
    IFS= read -r _rs_owner < "$_session_dir/.owner" || :
    if [[ "$_rs_owner" != "${_BATS_MOCK_SESSION_TOKEN:-}" ]]; then
        printf '%s\n' 'MOCK ERROR: State directory ownership changed; refusing to use or remove it.' >&2
        return 1
    fi
    # Resolving the path costs a subshell. The owner marker above is checked
    # on every call, so resolve the path once per session.
    if [[ "${_BATS_MOCK_SESSION_RESOLVED:-}" != "$_session_dir" ]]; then
        if [[ "$(builtin cd -P -- "$BATS_MOCK_STATE_DIR" && builtin pwd -P)" != "$_session_dir" ]]; then
            printf '%s\n' 'MOCK ERROR: State directory ownership changed; refusing to use or remove it.' >&2
            return 1
        fi
        _BATS_MOCK_SESSION_RESOLVED="$_session_dir"
    fi
}

#######################################
# Cleans up the mocking environment.
# Must be called in `teardown()`.
#
# Globals:
#    BATS_MOCK_STATE_DIR
#######################################
mock_teardown() {
    if (( $# != 0 )); then
        printf '%s\n' 'MOCK ERROR: Usage: mock_teardown' >&2
        return 1
    fi
    [[ -n "${_BATS_MOCK_SESSION_DIR:-}" ]] || return 0
    mock::internal::require_session || return 1
    local _teardown_rule _teardown_cmd _teardown_var
    for _teardown_rule in "$BATS_MOCK_STATE_DIR"/*.rules; do
        [[ -f "$_teardown_rule" ]] || continue
        _teardown_cmd=${_teardown_rule##*/}
        unmock "${_teardown_cmd%.rules}" || return 1
    done
    command rm -rf -- "$_BATS_MOCK_SESSION_DIR" || return 1
    for _teardown_var in ${!_BATS_MOCK_@}; do
        unset "$_teardown_var"
    done
}

#######################################
# Mocks a command.
#
# Arguments:
#    $1 (String) - _m_cmd: The command to mock.
#    $2 (String) - _m_pat: Argument pattern (default "*"). Use '~' prefix for regex.
#    $3 (String) - _m_act: Code to execute (default "true").
# Usage:
#    mock git "fetch" "echo 'fetching'"
#    mock grep "~^error.*" "return 1"
#######################################
mock() {
    local _m_cmd="${1:-}"
    local _m_pat="${2-*}"
    local _m_act="${3-true}"
    if (( $# < 1 || $# > 3 )); then
        printf '%s\n' 'MOCK ERROR: Usage: mock COMMAND [PATTERN] [ACTION]' >&2
        return 1
    fi
    mock::internal::validate_name "$_m_cmd" || return 1
    mock::internal::validate_pattern "$_m_pat" || return 1
    mock::internal::require_session || return 1

    # Initialize log and BACKUP ORIGINAL if this is the first interaction
    if [[ ! -f "${BATS_MOCK_STATE_DIR}/${_m_cmd}.log" ]]; then
        : > "${BATS_MOCK_STATE_DIR}/${_m_cmd}.log" || return 1
        : > "${BATS_MOCK_STATE_DIR}/${_m_cmd}.stdin.log" || return 1
        command mkdir -- "${BATS_MOCK_STATE_DIR}/${_m_cmd}.calls" || return 1
        builtin printf '0\n' > "${BATS_MOCK_STATE_DIR}/${_m_cmd}.next" || return 1

        # Check for existing function to backup (save-and-restore)
        local _m_orig_file="${BATS_MOCK_STATE_DIR}/${_m_cmd}.orig"
        if declare -f -- "$_m_cmd" > "$_m_orig_file" 2>/dev/null; then
             :
        else
             command rm -f -- "$_m_orig_file"
        fi
    fi

    mock::jit::add_rule "$_m_cmd" "$_m_pat" "$_m_act" || return 1
    mock::jit::compile "$_m_cmd"
}

#######################################
# Removes a mock and restores the original command.
#
# Arguments:
#    $1 (String) - _um_cmd: The command to restore.
# Usage:
#    unmock git
#######################################
unmock() {
    local _um_cmd="${1:-}"
    if (( $# != 1 )); then
        printf '%s\n' 'MOCK ERROR: Usage: unmock COMMAND' >&2
        return 1
    fi
    mock::internal::validate_name "$_um_cmd" || return 1
    [[ -f "${BATS_MOCK_STATE_DIR}/${_um_cmd}.rules" ]] || return 0
    mock::internal::require_session || return 1
    unset -f -- "$_um_cmd"
    unset -v "BASH_FUNC_${_um_cmd}%%" 2>/dev/null || true

    local _um_safe_cmd
    mock::internal::sanitize_ref _um_safe_cmd "$_um_cmd"

    # Safely unset all rule variables
    local _um_count_var="${BATS_MOCK_PREFIX}_RULE_COUNT_${_um_safe_cmd}"
    local _um_count="${!_um_count_var:-0}"
    local _um_i
    for ((_um_i=0; _um_i<_um_count; _um_i++)); do
        unset "${BATS_MOCK_PREFIX}_RULE_${_um_safe_cmd}_${_um_i}_PAT"
        unset "${BATS_MOCK_PREFIX}_RULE_${_um_safe_cmd}_${_um_i}_ACT"
    done
    unset "$_um_count_var"
    unset "${BATS_MOCK_PREFIX}_DIRTY_${_um_safe_cmd}"
    unset -f "${BATS_MOCK_PREFIX}_SPY_ORIGINAL_${_um_safe_cmd}"
    unset -f "${BATS_MOCK_PREFIX}_ACTION_${_um_safe_cmd}"

    # Restore original function if backup exists
    local _um_orig_file="${BATS_MOCK_STATE_DIR}/${_um_cmd}.orig"
    if [[ -f "$_um_orig_file" ]]; then
        # shellcheck source=/dev/null
        source "$_um_orig_file" || return 1
        command rm -f -- "$_um_orig_file"
    fi

    # Clean up state files
    command rm -f -- "${BATS_MOCK_STATE_DIR}/${_um_cmd}.rules" \
        "${BATS_MOCK_STATE_DIR}/${_um_cmd}.log" \
        "${BATS_MOCK_STATE_DIR}/${_um_cmd}.stdin.log" \
        "${BATS_MOCK_STATE_DIR}/${_um_cmd}.next" || return 1
    command rm -rf -- "${BATS_MOCK_STATE_DIR}/${_um_cmd}.calls"
}

#######################################
# Creates a spy on a command.
# Executes the original command but logs the call.
#
# Arguments:
#    $1 (String) - _ms_cmd: The command or function to spy on.
# Usage:
#    mock_spy curl
#######################################
mock_spy() {
    local _ms_cmd="${1:-}"
    if (( $# != 1 )); then
        printf '%s\n' 'MOCK ERROR: Usage: mock_spy COMMAND' >&2
        return 1
    fi
    mock::internal::validate_name "$_ms_cmd" || return 1
    mock::internal::require_session || return 1

    local _ms_orig_def=""
    # Keep existing history, but never save a generated wrapper as the original.
    if [[ -f "${BATS_MOCK_STATE_DIR}/${_ms_cmd}.rules" ]]; then
        if [[ -f "${BATS_MOCK_STATE_DIR}/${_ms_cmd}.orig" ]]; then
            _ms_orig_def=$(< "${BATS_MOCK_STATE_DIR}/${_ms_cmd}.orig")
        fi
    elif declare -f -- "$_ms_cmd" >/dev/null; then
        _ms_orig_def=$(declare -f -- "$_ms_cmd")
    fi

    if [[ -n "$_ms_orig_def" ]]; then
        local _ms_safe_cmd
        mock::internal::sanitize_ref _ms_safe_cmd "$_ms_cmd"
        local _ms_hidden_name="${BATS_MOCK_PREFIX}_SPY_ORIGINAL_${_ms_safe_cmd}"

        # Bash 'declare -f' standardizes output to "name ()".
        # We replace the FIRST occurrence of the name with the hidden name.
        local _ms_new_def="${_ms_orig_def/$_ms_cmd ()/$_ms_hidden_name ()}"

        if [[ "$_ms_new_def" == "$_ms_orig_def" ]]; then
             _ms_new_def="${_ms_orig_def/function $_ms_cmd/function $_ms_hidden_name}"
        fi

        eval "$_ms_new_def" || return 1
        export -f "${_ms_hidden_name?}"
        mock "$_ms_cmd" "*" "$_ms_hidden_name \"\$@\""
    else
        mock "$_ms_cmd" "*" "command -- ${_ms_cmd} \"\$@\""
    fi
}

#######################################
# Mocks a command with a sequence of actions.
# Thread-safe using atomic locking.
#
# Arguments:
#    $1 (String) - _seq_cmd: The command to mock.
#    $2 (String) - _seq_pat: The argument pattern.
#    $@ (Strings) - A list of actions to execute in order.
# Usage:
#    mock_sequence seq_cmd "*" "echo 1" "echo 2" "echo 3"
#######################################
mock_sequence() {
    if (( $# < 3 )); then
        printf '%s\n' 'MOCK ERROR: Usage: mock_sequence COMMAND PATTERN ACTION...' >&2
        return 1
    fi
    local _seq_cmd="$1"
    local _seq_pat="$2"
    mock::internal::validate_name "$_seq_cmd" || return 1
    mock::internal::validate_pattern "$_seq_pat" || return 1
    mock::internal::require_session || return 1
    shift 2
    local _seq_actions=("$@")

    local _seq_counter_file
    _seq_counter_file=$(command mktemp "${BATS_MOCK_STATE_DIR}/seq_${_seq_cmd}_XXXXXXXX") || return 1
    printf '0\n' > "$_seq_counter_file" || return 1
    local _seq_counter_quoted
    printf -v _seq_counter_quoted '%q' "$_seq_counter_file"

    local _seq_script=""

    # Inline locking logic for subshell portability
    _seq_script+="
    local counter_file=$_seq_counter_quoted
    local lock_dir=\"\${counter_file}.lock\"
    local idx=0

    # 1. Acquire Lock
    local _mock_sequence_deadline=\$((SECONDS + 5))
    local _mock_sequence_tries=0
    while ! command mkdir -- \"\$lock_dir\" 2>/dev/null; do
        if (( SECONDS >= _mock_sequence_deadline )); then echo 'Lock timeout' >&2; return 1; fi
        ((_mock_sequence_tries+=1))
        if (( _mock_sequence_tries > 16 )); then command sleep 0.05; fi
    done

    # 2. Critical Section
    if ! IFS= read -r idx < \"\$counter_file\" || [[ ! \$idx =~ ^[0-9]+$ ]]; then
        command rmdir -- \"\$lock_dir\" 2>/dev/null || true
        echo 'MOCK ERROR: Invalid sequence counter' >&2
        return 1
    fi
    if ! builtin printf '%s\n' \$((idx + 1)) > \"\$counter_file\"; then
        command rmdir -- \"\$lock_dir\" 2>/dev/null || true
        return 1
    fi

    # 3. Release Lock
    command rmdir -- \"\$lock_dir\" 2>/dev/null || true

    case \$idx in
    "

    local _seq_i=0
    local _seq_action
    for _seq_action in "${_seq_actions[@]}"; do
        _seq_script+="$_seq_i) $_seq_action ;; "
        ((_seq_i+=1))
    done

    local _seq_last_action="${_seq_actions[$((${#_seq_actions[@]} - 1))]}"
    _seq_script+="*) $_seq_last_action ;; "
    _seq_script+=$'esac'

    mock "$_seq_cmd" "$_seq_pat" "$_seq_script"
}

#######################################
# Enables or disables strict mode.
#
# Arguments:
#    $1 (Integer) - _st_val: 1 for strict (fail on unmatched), 0 for permissive.
# Usage:
#    mock_strict_mode 1
#######################################
mock_strict_mode() {
    if (( $# != 1 )) || [[ "$1" != 0 && "$1" != 1 ]]; then
        printf '%s\n' 'MOCK ERROR: Usage: mock_strict_mode 0|1' >&2
        return 1
    fi
    export BATS_MOCK_STRICT="$1"
}

# ==============================================================================
# ASSERTIONS
# ==============================================================================

#######################################
# Internal helper to check if a pattern exists in a history log.
# Supports Glob (default) and Regex (prefix '~').
#
# Arguments:
#   $1 (String) - _search_cmd: Command name.
#   $2 (String) - _search_pat: Pattern to match.
#   $3 (String) - _search_type: "args" (default) or "stdin".
# Returns:
#   0 - If found.
#   1 - If not found.
#######################################
mock::history::search() {
    local _search_cmd="$1"
    local _search_pat="$2"
    local _search_type="${3:-args}"

    local _search_file _search_line
    for _search_file in "$BATS_MOCK_STATE_DIR/$_search_cmd.calls/"*/"$_search_type"; do
        [[ -f "$_search_file" ]] || continue
        if [[ "$_search_type" == stdin ]]; then
            if builtin printf '%s' "${_search_pat:1}" | command cmp -s - "$_search_file"; then
                return 0
            fi
            continue
        fi
        IFS= read -r -d '' _search_line < "$_search_file" || return 2
        # 1. Literal Match (Prefix '=')
        # shellcheck disable=SC2053  # the unquoted pattern is the glob contract of the default mode
        if [[ "${_search_pat:0:1}" == "=" ]]; then
            local _search_literal="${_search_pat:1}"
            # Exact string comparison
            if [[ "$_search_line" == "$_search_literal" ]]; then return 0; fi

        # 2. Regex Match (Prefix '~')
        elif [[ "${_search_pat:0:1}" == "~" ]]; then
            local _search_regex="${_search_pat:1}"
            if [[ "$_search_line" =~ $_search_regex ]]; then return 0; fi

        # 3. Glob Match (Default)
        elif [[ "$_search_line" == $_search_pat ]]; then
            return 0
        fi
    done

    return 1
}

#######################################
# Asserts that a mock was called at least once.
#
# Arguments:
#    $1 (String) - _ac_cmd: Command Name.
# Returns:
#    0 - If called at least once.
#    1 - If never called (prints failure).
# Usage:
#    assert_called git
#######################################
assert_called() {
    mock::internal::assert_command 1 1 "$@" || return 1
    local _ac_cmd="$1"
    local _ac_log="${BATS_MOCK_STATE_DIR}/${_ac_cmd}.log"
    if [[ ! -s "$_ac_log" ]]; then
        mock::report::fail "$_ac_cmd" "Not Called" "At least 1 call" "Actual" "0 calls"
        return 1
    fi
}

#######################################
# Asserts that a mock was NEVER called.
#
# Arguments:
#    $1 (String) - _rc_cmd: Command Name.
# Returns:
#    0 - If never called.
#    1 - If called (prints failure).
# Usage:
#    refute_called rm
#######################################
refute_called() {
    mock::internal::assert_command 1 1 "$@" || return 1
    local _rc_cmd="$1"
    local _rc_log="${BATS_MOCK_STATE_DIR}/${_rc_cmd}.log"
    if [[ -s "$_rc_log" ]]; then
        local _rc_count
        _rc_count=$(wc -l < "$_rc_log")
        mock::report::fail "$_rc_cmd" "Unexpected Call" "0 calls" "Actual" "${_rc_count// /} calls"
        return 1
    fi
}

#######################################
# Asserts that a mock was called with arguments matching a pattern.
#
# Arguments:
#    $1 (String) - _acw_cmd: Command Name
#    $@ (Strings) - Pattern to match against call history (joined by spaces).
# Returns:
#    0 - If pattern is found.
#    1 - If pattern is not found (prints failure block).
# Usage:
#    assert_called_with git "push origin main"   # Literal match
#    assert_called_with git "push" "origin"      # Varargs match
#    assert_called_with log "*[ERROR]*"          # Glob match
#    assert_called_with grep "~^error.*"         # Regex match
#######################################
assert_called_with() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _acw_cmd="$1"
    shift
    local _acw_pattern="$*"
    mock::internal::validate_pattern "$_acw_pattern" || return 1

    if mock::history::search "$_acw_cmd" "$_acw_pattern" "args"; then
        return 0
    fi
    mock::report::fail "$_acw_cmd" "Argument Mismatch" "Call matching: '$_acw_pattern'" "History" "__HISTORY__"
    return 1
}

#######################################
# Asserts that a mock was called EXACTLY once, and with matching arguments.
#
# Arguments:
#    $1 (String) - _acow_cmd: Command Name.
#    $@ (Strings) - Pattern to match.
# Returns:
#    0 - If called exactly once and matches pattern.
#    1 - If count != 1 or pattern not match.
# Usage:
#    assert_called_once_with git "init"
#######################################
assert_called_once_with() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _acow_cmd="$1"
    shift
    local _acow_pattern="$*"
    mock::internal::validate_pattern "$_acow_pattern" || return 1
    local _acow_log="${BATS_MOCK_STATE_DIR}/${_acow_cmd}.log"

    local _acow_count=0
    if [[ -f "$_acow_log" ]]; then
        _acow_count=$(wc -l < "$_acow_log")
    fi

    if [[ "$_acow_count" -ne 1 ]]; then
         mock::report::fail "$_acow_cmd" "Count Mismatch" "Exactly 1 call" "Actual" "${_acow_count// /} calls"
         return 1
    fi

    if mock::history::search "$_acow_cmd" "$_acow_pattern" "args"; then
        return 0
    fi
    mock::report::fail "$_acow_cmd" "Argument Mismatch" "Single call matching: '$_acow_pattern'" "History" "__HISTORY__"
    return 1
}

#######################################
# Asserts that a mock was NOT called with matching arguments.
#
# Arguments:
#    $1 (String) - _rcw_cmd: Command Name.
#    $@ (Strings) - Pattern to match.
# Returns:
#    0 - If pattern is NOT found.
#    1 - If pattern IS found.
# Usage:
#    refute_called_with rm "-rf /"
#######################################
refute_called_with() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _rcw_cmd="$1"
    shift
    local _rcw_pattern="$*"
    mock::internal::validate_pattern "$_rcw_pattern" || return 1
    if mock::history::search "$_rcw_cmd" "$_rcw_pattern" "args"; then
         mock::report::fail "$_rcw_cmd" "Unexpected Call" "Not to match: '$_rcw_pattern'" "Matched" "Pattern found in history"
         return 1
    else
        local _rcw_status=$?
        if (( _rcw_status != 1 )); then
            mock::report::fail "$_rcw_cmd" "History Read Failure" "Readable call records" "Status" "Corrupt argument record"
            return 1
        fi
    fi
}

#######################################
# Asserts that a mock was called with arguments matching a pattern EXACTLY.
# Treats all characters (including [, ], *, ?) as literals, disabling globbing.
#
# Arguments:
#    $1 (String) - _ace_cmd: Command Name.
#    $@ (Strings) - The exact argument string to match (joined by spaces).
# Returns:
#    0 - If an exact match is found in the history.
#    1 - If no exact match is found (prints failure).
# Usage:
#    assert_called_exact git "array[0]"
#    assert_called_exact logger "Line 1"$'\n'"Line 2"
#######################################
assert_called_exact() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _ace_cmd="$1"
    shift
    # We explicitly prepend '=' to force the internal search
    # to treat this as a literal string.
    local _ace_pattern="=$*"

    if mock::history::search "$_ace_cmd" "$_ace_pattern" "args"; then
        return 0
    fi
    mock::report::fail "$_ace_cmd" "Exact Match Failure" "Args: '$*'" "History" "__HISTORY__"
    return 1
}

#######################################
# Asserts that a mock was NEVER called with specific arguments.
# Uses exact string matching, ignoring glob patterns.
#
# Arguments:
#    $1 (String) - _rce_cmd: Command Name.
#    $@ (Strings) - The exact argument string to check for.
# Returns:
#    0 - If the exact pattern is NOT found.
#    1 - If the exact pattern IS found (prints failure).
# Usage:
#    refute_called_exact git "password123"
#######################################
refute_called_exact() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _rce_cmd="$1"
    shift
    local _rce_pattern="=$*"

    if mock::history::search "$_rce_cmd" "$_rce_pattern" "args"; then
         mock::report::fail "$_rce_cmd" "Unexpected Call" "Not to match: '$*'" "Matched" "Exact match found"
         return 1
    else
        local _rce_status=$?
        if (( _rce_status != 1 )); then
            mock::report::fail "$_rce_cmd" "History Read Failure" "Readable call records" "Status" "Corrupt argument record"
            return 1
        fi
    fi
}

#######################################
# Compares argv records without flattening or evaluating their contents.
#######################################
mock::history::argv_equal() {
    local _ae_file="$1"
    shift
    local _ae_actual=() _ae_index=0 _ae_arg
    mapfile -d '' -t _ae_actual < "$_ae_file" || return 1
    (( ${#_ae_actual[@]} == $# )) || return 1
    for _ae_arg in "$@"; do
        [[ "${_ae_actual[$_ae_index]}" == "$_ae_arg" ]] || return 1
        ((_ae_index+=1))
    done
}

mock::history::has_argv() {
    local _ha_cmd="$1" _ha_file
    shift
    for _ha_file in "$BATS_MOCK_STATE_DIR/$_ha_cmd.calls/"*/argv; do
        [[ -f "$_ha_file" ]] || continue
        if mock::history::argv_equal "$_ha_file" "$@"; then return 0; fi
    done
    return 1
}

#######################################
# Asserts exact argument boundaries and values in any call (including zero args).
#######################################
assert_called_with_args() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _cwa_cmd="$1" _cwa_expected
    shift
    if mock::history::has_argv "$_cwa_cmd" "$@"; then return 0; fi
    builtin printf -v _cwa_expected '%q ' "$@"
    mock::report::fail "$_cwa_cmd" "Argument Mismatch" \
        "Exactly $# arguments: $_cwa_expected" "History" "__ARGV_HISTORY__"
}

refute_called_with_args() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _rca_cmd="$1" _rca_expected
    shift
    if mock::history::has_argv "$_rca_cmd" "$@"; then
        builtin printf -v _rca_expected '%q ' "$@"
        mock::report::fail "$_rca_cmd" "Unexpected Call" \
            "Not exactly $# arguments: $_rca_expected" "History" "__ARGV_HISTORY__"
        return 1
    fi
}

assert_called_at_index_with_args() {
    mock::internal::assert_command 2 -1 "$@" || return 1
    local _cia_cmd="$1" _cia_index _cia_expected _cia_file
    _cia_index=$(mock::internal::decimal "$2") || return 1
    shift 2
    _cia_file="$BATS_MOCK_STATE_DIR/$_cia_cmd.calls/$_cia_index/argv"
    if [[ ! -f "$_cia_file" ]]; then
        mock::report::fail "$_cia_cmd" "Index Failure" "Call at index $_cia_index" "Status" "Index out of bounds"
        return 1
    fi
    if mock::history::argv_equal "$_cia_file" "$@"; then return 0; fi
    builtin printf -v _cia_expected '%q ' "$@"
    mock::report::fail "$_cia_cmd" "Argument Mismatch" \
        "Index $_cia_index with exactly $# arguments: $_cia_expected" "History" "__ARGV_HISTORY__"
}

#######################################
# Asserts that a mock was called a specific number of times.
#
# Arguments:
#    $1 (String) - _act_cmd: Command Name.
#    $2 (Integer) - _act_expected: Expected count.
# Returns:
#    0 - If counts match.
#    1 - If counts do not match.
# Usage:
#    assert_called_times git 3
#######################################
assert_called_times() {
    if (( $# != 2 )); then
        printf '%s\n' 'MOCK ERROR: Usage: assert_called_times COMMAND COUNT' >&2
        return 1
    fi
    local _act_cmd="$1"
    mock::internal::require_registered "$_act_cmd" || return 1
    local _act_expected
    _act_expected=$(mock::internal::decimal "$2") || return 1
    local _act_count=0
    local _act_log="${BATS_MOCK_STATE_DIR}/${_act_cmd}.log"

    if [[ -f "$_act_log" ]]; then
        _act_count=$(wc -l < "$_act_log")
    fi

    if [[ "${_act_count//[[:space:]]/}" != "$_act_expected" ]]; then
        mock::report::fail "$_act_cmd" "Count Mismatch" "$_act_expected times" "Actual" "${_act_count// /}"
        return 1
    fi
}

#######################################
# Asserts that a mock call at a specific index matches a pattern.
#
# Arguments:
#    $1 (String) - _aci_cmd: Command Name.
#    $2 (Integer) - _aci_index: Index (0-based).
#    $@ (String) - Pattern to match.
# Returns:
#    0 - If match found at index.
#    1 - If index out of bounds or mismatch.
# Usage:
#    assert_called_at_index git 0 "fetch"
#######################################
assert_called_at_index() {
    if (( $# < 2 )); then
        printf '%s\n' 'MOCK ERROR: Usage: assert_called_at_index COMMAND INDEX [PATTERN...]' >&2
        return 1
    fi
    local _aci_cmd="$1"
    mock::internal::require_registered "$_aci_cmd" || return 1
    local _aci_index
    _aci_index=$(mock::internal::decimal "$2") || return 1
    shift 2
    local _aci_pattern="$*"
    mock::internal::validate_pattern "$_aci_pattern" || return 1
    local _aci_log="${BATS_MOCK_STATE_DIR}/${_aci_cmd}.log"

    if [[ ! -f "$_aci_log" ]]; then
        mock::report::fail "$_aci_cmd" "Index Failure" "Call at index $_aci_index" "Status" "No history"
        return 1
    fi

    local _aci_lines=()
    mapfile -t _aci_lines < "$_aci_log"

    local _aci_size=${#_aci_lines[@]}
    if [[ ${#_aci_index} -gt ${#_aci_size} ]] || (( _aci_index >= _aci_size )); then
         mock::report::fail "$_aci_cmd" "Index Failure" "Call at index $_aci_index" "Status" "Index out of bounds (Size: ${#_aci_lines[@]})"
         return 1
    fi
    local _aci_actual_line
    IFS= read -r -d '' _aci_actual_line < "$BATS_MOCK_STATE_DIR/$_aci_cmd.calls/$_aci_index/args" || return 1

    # shellcheck disable=SC2053  # the unquoted pattern is the glob contract of the default mode
    if [[ "${_aci_pattern:0:1}" == "~" ]]; then
        local _aci_regex="${_aci_pattern:1}"
        if [[ "$_aci_actual_line" =~ $_aci_regex ]]; then return 0; fi
    elif [[ "$_aci_actual_line" == $_aci_pattern ]]; then
        return 0
    fi

    mock::report::fail "$_aci_cmd" "Argument Mismatch" "Index $_aci_index matching: '$_aci_pattern'" "Actual" "$_aci_actual_line"
    return 1
}

#######################################
# Asserts that a mock received specific STDIN content in ANY call.
#
# Arguments:
#    $1 (String) - _ase_cmd: Command Name.
#    $@ (String) - Exact stdin content expected.
# Returns:
#    0 - If match found.
#    1 - If not found.
# Usage:
#    assert_stdin_equals cat "input data"
#######################################
assert_stdin_equals() {
    mock::internal::assert_command 1 -1 "$@" || return 1
    local _ase_cmd="$1"
    shift
    local _ase_pattern="$*"

    # Treat as literal string match by prefixing '='
    if mock::history::search "$_ase_cmd" "=$_ase_pattern" "stdin"; then
        return 0
    fi
    mock::report::fail "$_ase_cmd" "Stdin Mismatch" "Input: '$_ase_pattern'" "History" "__STDIN_HISTORY__"
    return 1
}

#######################################
# Asserts that a mock received specific STDIN content at a specific index.
#
# Arguments:
#    $1 (String) - _asi_cmd: Command Name.
#    $2 (Integer) - _asi_index: Index (0-based).
#    $@ (String) - Exact stdin content expected.
# Returns:
#    0 - If match found at index.
#    1 - If mismatch or OOB.
# Usage:
#    assert_stdin_at_index cat 0 "input data"
#######################################
assert_stdin_at_index() {
    if (( $# < 2 )); then
        printf '%s\n' 'MOCK ERROR: Usage: assert_stdin_at_index COMMAND INDEX [TEXT...]' >&2
        return 1
    fi
    local _asi_cmd="$1"
    mock::internal::require_registered "$_asi_cmd" || return 1
    local _asi_index
    _asi_index=$(mock::internal::decimal "$2") || return 1
    shift 2
    local _asi_pattern="$*"
    local _asi_log="${BATS_MOCK_STATE_DIR}/${_asi_cmd}.log"

    if [[ ! -f "$_asi_log" ]]; then
        mock::report::fail "$_asi_cmd" "Index Failure" "Stdin at index $_asi_index" "Status" "No history"
        return 1
    fi

    local _asi_lines=()
    mapfile -t _asi_lines < "$_asi_log"

    local _asi_size=${#_asi_lines[@]}
    if [[ ${#_asi_index} -gt ${#_asi_size} ]] || (( _asi_index >= _asi_size )); then
         mock::report::fail "$_asi_cmd" "Index Failure" "Stdin at index $_asi_index" "Status" "Index out of bounds (Size: ${#_asi_lines[@]})"
         return 1
    fi
    local _asi_file="$BATS_MOCK_STATE_DIR/$_asi_cmd.calls/$_asi_index/stdin"
    if [[ -f "$_asi_file" ]]; then
        if builtin printf '%s' "$_asi_pattern" | command cmp -s - "$_asi_file"; then return 0; fi
    fi
    mock::report::fail "$_asi_cmd" "Stdin Mismatch" "Index $_asi_index matching: '$_asi_pattern'" "History" "__STDIN_HISTORY__"
    return 1
}

#######################################
# Distinguishes a complete capture from a bounded partial capture or no capture.
#######################################
assert_stdin_complete() {
    mock::internal::assert_command 2 2 "$@" || return 1
    local _sc_cmd="$1" _sc_index _sc_file _sc_state=unavailable
    _sc_index=$(mock::internal::decimal "$2") || return 1
    _sc_file="$BATS_MOCK_STATE_DIR/$_sc_cmd.calls/$_sc_index/capture"
    if [[ -f "$_sc_file" ]]; then
        IFS= read -r _sc_state < "$_sc_file" || return 1
    fi
    [[ "$_sc_state" == complete ]] && return 0
    mock::report::fail "$_sc_cmd" "Incomplete Stdin" \
        "Complete capture at index $_sc_index" "Actual" "$_sc_state"
}

#######################################
# Asserts that any of the mock calls contain a specific substring.
#
# Arguments:
#    $1 (String) - _asc_cmd: Command Name.
#    $2 (String) - _asc_substring: Substring to search for.
# Returns:
#    0 - If substring found in any call.
#    1 - If substring not found.
# Usage:
#    assert_args_contain git "--force"
#######################################
assert_args_contain() {
    mock::internal::assert_command 2 2 "$@" || return 1
    local _asc_cmd="$1"
    local _asc_substring="$2"
    local _asc_log="${BATS_MOCK_STATE_DIR}/${_asc_cmd}.log"

    if [[ ! -f "$_asc_log" ]]; then
        mock::report::fail "$_asc_cmd" "Search Failure" "Args containing: '$_asc_substring'" "Status" "No history"
        return 1
    fi

    local _asc_line _asc_file
    for _asc_file in "$BATS_MOCK_STATE_DIR/$_asc_cmd.calls/"*/args; do
        [[ -f "$_asc_file" ]] || continue
        IFS= read -r -d '' _asc_line < "$_asc_file" || return 1
        if [[ "$_asc_line" == *"$_asc_substring"* ]]; then return 0; fi
    done

    mock::report::fail "$_asc_cmd" "Search Failure" "Args containing: '$_asc_substring'" "History" "__HISTORY__"
    return 1
}

#######################################
# Asserts a sequence of calls across different mocks.
#
# Arguments:
#    $@ (Strings) - List of expected calls in order (e.g., "git fetch" "make build").
# Returns:
#    0 - If sequence matches.
#    1 - If sequence fails.
# Usage:
#    assert_call_sequence "git fetch" "git merge"
#######################################
assert_call_sequence() {
    (( $# > 0 )) || return 0
    local _acs_expected_sequence=("$@")
    local _acs_global_log="$BATS_MOCK_GLOBAL_LOG"

    if [[ ! -f "$_acs_global_log" ]]; then
        echo "Global mock log not found at: $_acs_global_log" >&2
        return 1
    fi

    local _acs_actual_lines=()
    mapfile -t _acs_actual_lines < <(sed -E 's/^\[[^]]+\] //' "$_acs_global_log")

    local _acs_match_idx=0
    local _acs_total_expected=${#_acs_expected_sequence[@]}
    local _acs_line _acs_trimmed_line

    for _acs_line in "${_acs_actual_lines[@]}"; do
        local _acs_expected_item="${_acs_expected_sequence[$_acs_match_idx]}"
        _acs_trimmed_line="${_acs_line%"${_acs_line##*[![:space:]]}"}"

        if [[ "$_acs_trimmed_line" == "$_acs_expected_item" ||
              "$_acs_trimmed_line" == "$_acs_expected_item "* ]]; then
            ((_acs_match_idx+=1))
            if [[ $_acs_match_idx -ge $_acs_total_expected ]]; then return 0; fi
        fi
    done

    local _acs_next_expected="${_acs_expected_sequence[$_acs_match_idx]}"
    local _acs_body="  Progress:
    Matched $_acs_match_idx of $_acs_total_expected items.
    Waiting for: '$_acs_next_expected'

  Global Log Content (Normalized):"

    local _acs_formatted_log=""
    if [[ ${#_acs_actual_lines[@]} -gt 0 ]]; then
        printf -v _acs_formatted_log "    %s\n" "${_acs_actual_lines[@]}"
    else
        _acs_formatted_log="    (Empty)"
    fi

    _acs_body="$_acs_body
$_acs_formatted_log"
    mock::report::frame "✖ SEQUENCE ASSERTION FAILED" "$_acs_body"
    return 1
}

#######################################
# Prints a debug report of all mocks to FD 3 (or stderr).
#
# Arguments:
#   $1 (Integer) - _deb_fd: Optional FD to write to (default: auto-detect 3 or 2).
# Usage:
#    mock_debug
#    mock_debug 1  # Write to stdout
#######################################
mock_debug() {
    local _deb_fd="${1:-}"

    # Auto-detect if not provided
    if [[ -z "$_deb_fd" ]]; then
        _deb_fd=2
        if [[ -e /proc/self/fd/3 ]]; then _deb_fd=3; fi
    fi

    local _deb_active_mocks=() _deb_idle_mocks=() _deb_empty_mocks=()
    local _deb_mock_cmds=""

    if [[ -d "$BATS_MOCK_STATE_DIR" ]]; then
        _deb_mock_cmds=$(find "$BATS_MOCK_STATE_DIR" -maxdepth 1 -name "*.rules" -o -name "*.log" | sed 's|.*/||; s|\.rules||; s|\.log||' | sort -u)
    fi

    for _deb_cmd in $_deb_mock_cmds; do
        local _deb_log="${BATS_MOCK_STATE_DIR}/${_deb_cmd}.log"
        local _deb_stdin_log="${BATS_MOCK_STATE_DIR}/${_deb_cmd}.stdin.log"
        local _deb_rules="${BATS_MOCK_STATE_DIR}/${_deb_cmd}.rules"
        local _deb_has_calls=0; [[ -s "$_deb_log" ]] && _deb_has_calls=1
        local _deb_has_rules=0; [[ -s "$_deb_rules" ]] && _deb_has_rules=1

        if [[ $_deb_has_calls -eq 1 ]]; then _deb_active_mocks+=("$_deb_cmd");
        elif [[ $_deb_has_rules -eq 1 ]]; then _deb_idle_mocks+=("$_deb_cmd");
        else _deb_empty_mocks+=("$_deb_cmd"); fi
    done

    _mock_print_details() {
        local _mpd_cmd="$1"
        local _mpd_show_history="$2"
        local _mpd_log="${BATS_MOCK_STATE_DIR}/${_mpd_cmd}.log"
        local _mpd_stdin_log="${BATS_MOCK_STATE_DIR}/${_mpd_cmd}.stdin.log"
        local _mpd_rules="${BATS_MOCK_STATE_DIR}/${_mpd_cmd}.rules"

        echo "  $_mpd_cmd"
        if [[ -f "$_mpd_rules" ]]; then
             local _mpd_idx=1
             while IFS= read -r -d '' _mpd_pattern && IFS= read -r -d '' _mpd_action; do
                echo "     Rule $_mpd_idx: pattern '$_mpd_pattern'"
                if [[ "$_mpd_action" == *$'\n'* ]]; then
                    printf '%s\n' "             | ${_mpd_action//$'\n'/$'\n'             | }"
                else
                    echo "             Action: $_mpd_action"
                fi
                ((_mpd_idx+=1))
            done < "$_mpd_rules"
        else
             echo "     Rule : (Default)"
        fi

        if [[ "$_mpd_show_history" == "1" && -s "$_mpd_log" ]]; then
            echo "     Calls:"
            sed 's/^/       -> /' "$_mpd_log"

            if [[ -s "$_mpd_stdin_log" ]]; then
                 echo "     Stdin:"
                 sed 's/^/       -> /' "$_mpd_stdin_log"
            fi
        fi
        echo ""
    }

    local _deb_body=""
    printf -v _deb_body "  State: %s\n\n" "$BATS_MOCK_STATE_DIR"

    if [[ ${#_deb_active_mocks[@]} -gt 0 ]]; then
        _deb_body+=$'  [ ACTIVE MOCKS ]\n  ------------------------------------------------------------------------------\n'
        for _deb_cmd in "${_deb_active_mocks[@]}"; do _deb_body+="$(_mock_print_details "$_deb_cmd" "1")"$'\n'; done
    fi
    if [[ ${#_deb_idle_mocks[@]} -gt 0 ]]; then
        _deb_body+=$'  [ IDLE MOCKS ]\n  ------------------------------------------------------------------------------\n'
        for _deb_cmd in "${_deb_idle_mocks[@]}"; do _deb_body+="$(_mock_print_details "$_deb_cmd" "0")"$'\n'; done
    fi
    if [[ ${#_deb_empty_mocks[@]} -gt 0 ]]; then
         _deb_body+=$'  [ UNUSED MOCKS ]\n  ------------------------------------------------------------------------------\n'
         _deb_body+="    $(IFS=', '; echo "${_deb_empty_mocks[*]}")"$'\n\n'
    fi

    mock::report::frame "🐞 MOCK DEBUG REPORT" "$_deb_body" "$_deb_fd"
}
