#############################################
#
# Stealth Mock Framework v3.2.1 (Stream Safe)
# ==============================================================================
# A production-ready, secure, and concurrency-safe mocking library for BATS.
#
# Features:
#    - JIT Compilation: Dynamic function generation for maximum performance.
#    - Safety: Input sanitization and strict mode compliance (set -u, -e).
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
readonly BATS_MOCK_PREFIX="_BATS_MOCK"

# ==============================================================================
# INTERNAL UTILITIES
# ==============================================================================

#######################################
# Acquires an atomic lock for a specific directory.
# Uses mkdir atomicity to prevent race conditions.
#
# Arguments:
#    $1 (String) - _lock_dir_path: The directory path to lock (suffix .lock will be appended).
# Returns:
#    0 - If lock acquired successfully.
#    1 - If lock acquisition times out.
#######################################
mock::sync::lock() {
    local _lock_dir_path="$1.lock"
    local _lock_timeout=50 # 5 seconds (50 * 0.1)
    local _lock_i=0

    while ! mkdir "$_lock_dir_path" 2>/dev/null; do
        if (( _lock_i++ >= _lock_timeout )); then
            echo "MOCK TIMEOUT: Could not acquire lock for $1" >&2
            return 1
        fi
        sleep 0.1
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

    if [[ "$_glc_type" == "stdin" ]]; then
        _glc_suffix=".stdin.log"
    fi

    local _glc_log_file="${BATS_MOCK_STATE_DIR}/${_glc_cmd}${_glc_suffix}"
    [[ -s "$_glc_log_file" ]] && cat "$_glc_log_file" || echo "<EMPTY LOG>"
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
    if [[ "$_rep_content" == "__HISTORY__" ]]; then
        local _rep_log_content
        _rep_log_content=$(mock::internal::get_log_content "$_rep_cmd" "args")
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

#######################################
# Sanitizes a string for use as a variable name.
#
# Arguments:
#    $1 (String) - _san_str: The string to sanitize.
# Returns:
#    String - Sanitized string (alphanumeric and underscores only).
#######################################
mock::internal::sanitize() {
    echo "${1//[^a-zA-Z0-9_]/_}"
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
    local _jit_safe_cmd="${_jit_cmd//[^a-zA-Z0-9_]/_}"

    local _jit_dirty_var="${BATS_MOCK_PREFIX}_DIRTY_${_jit_safe_cmd}"
    if [[ "${!_jit_dirty_var:-0}" -eq 0 ]] && declare -f "$_jit_cmd" >/dev/null; then
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

    local _jit_func_body=""

    # 1. Logging Logic (Global & Local)
    _jit_func_body+="${_jit_cmd}() {
        local args=\"\$*\"
        local cmd_name=\"${_jit_cmd}\"
        local timestamp
        printf -v timestamp \"%(%s)T\" -1 2>/dev/null || timestamp=\$(date +%s)

        # Generate a unique temp file for stdin capture for this specific call
        local stdin_tmp=\"${BATS_MOCK_STATE_DIR}/${_jit_cmd}.stdin.tmp.\$$.\$RANDOM\"

        local serialized_args
        printf -v serialized_args \"%q \" \"\$@\"
        serialized_args=\"\${serialized_args% }\"

        local log_safe_args=\"\${args//\$'\n'/<newline>}\"

        { printf \"[%s] %s %s\n\" \"\$timestamp\" \"\$cmd_name\" \"\$serialized_args\"; } >> \"${BATS_MOCK_GLOBAL_LOG}\"
        { printf \"%s\n\" \"\$log_safe_args\"; } >> \"${BATS_MOCK_STATE_DIR}/${_jit_cmd}.log\"
    "

    # 2. Matching Logic (LIFO)
    # Uses process substitution < <(tee) to stream stdin to the action
    # while capturing it, ensuring strict side-effect preservation.
    _jit_func_body+="
        local i
        local count=\${${BATS_MOCK_PREFIX}_RULE_COUNT_${_jit_safe_cmd}:-0}
        local return_code=0
        local executed=0

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
                    # Non-blocking capture via tee with FD management to allow waiting
                    # Use exec to assign a file descriptor and capture the PID
                    # trap '' PIPE ensures tee keeps writing to file even if action closes stdin early
                    local stdin_fd
                    exec {stdin_fd}< <(trap '' PIPE; tee \"\$stdin_tmp\")
                    local stdin_pid=\$!

                    eval \"\${!act_var}\" <&\$stdin_fd
                    return_code=\$?

                    # Cleanup FD
                    exec {stdin_fd}<&-

                    # Explicitly terminate tee to avoid hangs on infinite streams (e.g. yes | mock_spy)
                    # where the pipe might remain open by leaked FDs or buffering issues.
                    kill \"\$stdin_pid\" 2>/dev/null || true

                    # Wait for process termination to avoid race conditions on log file access
                    wait \"\$stdin_pid\" 2>/dev/null || true
                else
                    eval \"\${!act_var}\"
                    return_code=\$?
                fi
                executed=1
                break
            fi
        done

        # 3. Strict Mode & Post-Execution Logging
        if [[ \"\$executed\" -eq 0 ]]; then
             if [[ \"\${BATS_MOCK_STRICT:-0}\" -eq 1 ]]; then
                echo \"MOCK ERROR: '${_jit_cmd}' called with unexpected args: '\$args'\" >&2
                return 127
             fi
        fi

        # Process the captured stdin log after action completion
        if [[ -f \"\$stdin_tmp\" ]]; then
             local cap_in=\$(cat \"\$stdin_tmp\"; echo \"x\")
             cap_in=\"\${cap_in%x}\"
             local safe_in=\"\${cap_in//\$'\n'/<newline>}\"
             printf \"%s\n\" \"\$safe_in\" >> \"${BATS_MOCK_STATE_DIR}/${_jit_cmd}.stdin.log\"
             rm -f \"\$stdin_tmp\"
        else
             # Log empty line to maintain index alignment with args log
             echo \"\" >> \"${BATS_MOCK_STATE_DIR}/${_jit_cmd}.stdin.log\"
        fi

        return \$return_code
    }"

    eval "$_jit_func_body"
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

    printf "%s\0%s\0" "$_ar_pattern" "$_ar_action" >> "$_ar_rules_file"

    local _ar_safe_cmd="${_ar_cmd_name//[^a-zA-Z0-9_]/_}"
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
    mkdir -p "$BATS_MOCK_STATE_DIR"
    : > "$BATS_MOCK_GLOBAL_LOG"
}

#######################################
# Cleans up the mocking environment.
# Must be called in `teardown()`.
#
# Globals:
#    BATS_MOCK_STATE_DIR
#######################################
mock_teardown() {
    # Safety check to prevent deleting root or unexpected directories
    if [[ -n "${BATS_MOCK_STATE_DIR}" && "${BATS_MOCK_STATE_DIR}" == *"bats-mock"* && "${BATS_MOCK_STATE_DIR}" != "/" ]]; then
        rm -rf "${BATS_MOCK_STATE_DIR}"
    elif [[ -n "${BATS_MOCK_STATE_DIR}" && "${BATS_MOCK_STATE_DIR}" != "/" ]]; then
        # Fallback for custom temp dirs not named 'bats-mock', but still paranoid
        rm -rf "${BATS_MOCK_STATE_DIR}"
    fi
    eval "unset \"\${!${BATS_MOCK_PREFIX}_@}\""
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
    local _m_pat="${2:-*}"
    local _m_act="${3:-true}"

    # Validate Function Name (Security)
    if [[ ! "$_m_cmd" =~ ^[a-zA-Z0-9._:-]{1,}$ ]]; then
        echo "MOCK ERROR: Invalid function name '$_m_cmd'. Mocks must not contain shell meta-characters." >&2
        return 1
    fi

    # Protect Framework Internals (Stability)
    local _m_reserved_pattern="^(mock|unmock|mock_setup|mock_teardown|mock_spy|mock_sequence|mock_strict_mode|mock_debug|mock::internal::.*)$"

    if [[ "$_m_cmd" =~ $_m_reserved_pattern ]]; then
        echo "MOCK ERROR: '$_m_cmd' is a reserved framework function and cannot be mocked." >&2
        return 1
    fi

    # Initialize log and BACKUP ORIGINAL if this is the first interaction
    if [[ ! -f "${BATS_MOCK_STATE_DIR}/${_m_cmd}.log" ]]; then
        : > "${BATS_MOCK_STATE_DIR}/${_m_cmd}.log"
        : > "${BATS_MOCK_STATE_DIR}/${_m_cmd}.stdin.log"

        # Check for existing function to backup (save-and-restore)
        local _m_orig_file="${BATS_MOCK_STATE_DIR}/${_m_cmd}.orig"
        if declare -f "$_m_cmd" > "$_m_orig_file" 2>/dev/null; then
             :
        else
             rm -f "$_m_orig_file"
        fi
    fi

    mock::jit::add_rule "$_m_cmd" "$_m_pat" "$_m_act"
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
    local _um_cmd="$1"
    unset -f "$_um_cmd"
    unset -v "BASH_FUNC_${_um_cmd}%%" 2>/dev/null || true

    local _um_safe_cmd="${_um_cmd//[^a-zA-Z0-9_]/_}"

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

    # Restore original function if backup exists
    local _um_orig_file="${BATS_MOCK_STATE_DIR}/${_um_cmd}.orig"
    if [[ -f "$_um_orig_file" ]]; then
        # shellcheck source=/dev/null
        source "$_um_orig_file" || true
        rm -f "$_um_orig_file"
    fi

    # Clean up state files
    rm -f "${BATS_MOCK_STATE_DIR}/${_um_cmd}.rules"
    rm -f "${BATS_MOCK_STATE_DIR}/${_um_cmd}.log"
    rm -f "${BATS_MOCK_STATE_DIR}/${_um_cmd}.stdin.log"
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
    local _ms_cmd="$1"

    if declare -f "$_ms_cmd" >/dev/null; then
        local _ms_safe_cmd="${_ms_cmd//[^a-zA-Z0-9_]/_}"
        local _ms_hidden_name="${BATS_MOCK_PREFIX}_SPY_ORIGINAL_${_ms_safe_cmd}"

        local _ms_orig_def
        _ms_orig_def=$(declare -f "$_ms_cmd")

        # Bash 'declare -f' standardizes output to "name ()".
        # We replace the FIRST occurrence of the name with the hidden name.
        local _ms_new_def="${_ms_orig_def/$_ms_cmd ()/$_ms_hidden_name ()}"

        if [[ "$_ms_new_def" == "$_ms_orig_def" ]]; then
             _ms_new_def="${_ms_orig_def/function $_ms_cmd/$_ms_hidden_name}"
        fi

        eval "$_ms_new_def"
        mock "$_ms_cmd" "*" "$_ms_hidden_name \"\$@\""
    else
        mock "$_ms_cmd" "*" "command ${_ms_cmd} \"\$@\""
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
    local _seq_cmd="$1"
    local _seq_pat="$2"
    shift 2
    local _seq_actions=("$@")

    local _seq_counter_file
    _seq_counter_file="${BATS_MOCK_STATE_DIR}/seq_${_seq_cmd}_$(date +%s%N)"
    echo "0" > "$_seq_counter_file"

    local _seq_script=""

    # Inline locking logic for subshell portability
    _seq_script+="
    local lock_dir='${_seq_counter_file}.lock'
    local idx=0

    # 1. Acquire Lock
    local i=0
    while ! mkdir \"\$lock_dir\" 2>/dev/null; do
        if (( i++ > 50 )); then echo 'Lock timeout' >&2; return 1; fi
        sleep 0.1
    done

    # 2. Critical Section
    if [[ -f '${_seq_counter_file}' ]]; then
        read -r idx < '${_seq_counter_file}'
    fi
    echo \$((idx + 1)) > '${_seq_counter_file}'

    # 3. Release Lock
    rmdir \"\$lock_dir\" 2>/dev/null || true

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

    local _search_suffix=".log"
    if [[ "$_search_type" == "stdin" ]]; then _search_suffix=".stdin.log"; fi

    local _search_log="${BATS_MOCK_STATE_DIR}/${_search_cmd}${_search_suffix}"

    [[ -f "$_search_log" ]] || return 1

    local _search_safe_pat="${_search_pat//$'\n'/<newline>}"

    while IFS= read -r _search_line; do
        # 1. Literal Match (Prefix '=')
        # shellcheck disable=SC2053  # the unquoted pattern is the glob contract of the default mode
        if [[ "${_search_pat:0:1}" == "=" ]]; then
            local _search_literal="${_search_safe_pat:1}"
            # Exact string comparison
            if [[ "$_search_line" == "$_search_literal" ]]; then return 0; fi

        # 2. Regex Match (Prefix '~')
        elif [[ "${_search_pat:0:1}" == "~" ]]; then
            local _search_regex="${_search_safe_pat:1}"
            if [[ "$_search_line" =~ $_search_regex ]]; then return 0; fi

        # 3. Glob Match (Default)
        elif [[ "$_search_line" == $_search_safe_pat ]]; then
            return 0
        fi
    done < "$_search_log"

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
    local _acw_cmd="$1"
    shift
    local _acw_pattern="$*"

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
    local _acow_cmd="$1"
    shift
    local _acow_pattern="$*"
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
    local _rcw_cmd="$1"
    shift
    local _rcw_pattern="$*"
    if mock::history::search "$_rcw_cmd" "$_rcw_pattern" "args"; then
         mock::report::fail "$_rcw_cmd" "Unexpected Call" "Not to match: '$_rcw_pattern'" "Matched" "Pattern found in history"
         return 1
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
    local _rce_cmd="$1"
    shift
    local _rce_pattern="=$*"

    if mock::history::search "$_rce_cmd" "$_rce_pattern" "args"; then
         mock::report::fail "$_rce_cmd" "Unexpected Call" "Not to match: '$*'" "Matched" "Exact match found"
         return 1
    fi
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
    local _act_cmd="$1"
    local _act_expected="$2"
    local _act_count=0
    local _act_log="${BATS_MOCK_STATE_DIR}/${_act_cmd}.log"

    if [[ -f "$_act_log" ]]; then
        _act_count=$(wc -l < "$_act_log")
    fi

    if [[ "${_act_count// /}" -ne "$_act_expected" ]]; then
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
    local _aci_cmd="$1"
    local _aci_index="$2"
    shift 2
    local _aci_pattern="$*"
    local _aci_log="${BATS_MOCK_STATE_DIR}/${_aci_cmd}.log"

    if [[ ! -f "$_aci_log" ]]; then
        mock::report::fail "$_aci_cmd" "Index Failure" "Call at index $_aci_index" "Status" "No history"
        return 1
    fi

    local _aci_lines=()
    mapfile -t _aci_lines < "$_aci_log"

    local _aci_actual_line="${_aci_lines[$_aci_index]}"
    if [[ -z "$_aci_actual_line" && "${#_aci_lines[@]}" -le "$_aci_index" ]]; then
         mock::report::fail "$_aci_cmd" "Index Failure" "Call at index $_aci_index" "Status" "Index out of bounds (Size: ${#_aci_lines[@]})"
         return 1
    fi

    # Support Regex match here too
    # Sanitize pattern for multiline comparison
    local _aci_safe_pattern="${_aci_pattern//$'\n'/<newline>}"

    # shellcheck disable=SC2053  # the unquoted pattern is the glob contract of the default mode
    if [[ "${_aci_pattern:0:1}" == "~" ]]; then
        local _aci_regex="${_aci_safe_pattern:1}"
        if [[ "$_aci_actual_line" =~ $_aci_regex ]]; then return 0; fi
    elif [[ "$_aci_actual_line" == $_aci_safe_pattern ]]; then
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
    local _asi_cmd="$1"
    local _asi_index="$2"
    shift 2
    local _asi_pattern="$*"
    local _asi_log="${BATS_MOCK_STATE_DIR}/${_asi_cmd}.stdin.log"

    if [[ ! -f "$_asi_log" ]]; then
        mock::report::fail "$_asi_cmd" "Index Failure" "Stdin at index $_asi_index" "Status" "No history"
        return 1
    fi

    local _asi_lines=()
    mapfile -t _asi_lines < "$_asi_log"

    local _asi_actual_line="${_asi_lines[$_asi_index]}"
    if [[ -z "$_asi_actual_line" && "${#_asi_lines[@]}" -le "$_asi_index" ]]; then
         mock::report::fail "$_asi_cmd" "Index Failure" "Stdin at index $_asi_index" "Status" "Index out of bounds (Size: ${#_asi_lines[@]})"
         return 1
    fi

    local _asi_safe_pattern="${_asi_pattern//$'\n'/<newline>}"

    if [[ "$_asi_actual_line" == "$_asi_safe_pattern" ]]; then
        return 0
    fi

    mock::report::fail "$_asi_cmd" "Stdin Mismatch" "Index $_asi_index matching: '$_asi_pattern'" "Actual" "$_asi_actual_line"
    return 1
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
    local _asc_cmd="$1"
    local _asc_substring="$2"
    local _asc_log="${BATS_MOCK_STATE_DIR}/${_asc_cmd}.log"

    [[ ! -f "$_asc_log" ]] && mock::report::fail "$_asc_cmd" "Search Failure" "Args containing: '$_asc_substring'" "Status" "No history" && return 1

    while IFS= read -r _asc_line; do
        if [[ "$_asc_line" == *"$_asc_substring"* ]]; then return 0; fi
    done < "$_asc_log"

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

        if [[ "$_acs_trimmed_line" == "$_acs_expected_item"* ]]; then
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
