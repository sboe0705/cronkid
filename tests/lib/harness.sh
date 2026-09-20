#!/usr/bin/env bash
#
# Test harness of the cronkid test suite. A test file sources this file, defines functions named
# 'test_*' and calls 'harness_main "$@"' at the end. Every test runs in its own subshell with
#
#   - a fresh HOME (the used-time file and the service unit live there),
#   - a fresh stub state directory (STUB_STATE), and
#   - tests/lib/stubs first in PATH, so that loginctl, notify-send and systemctl are stubs.
#
# The scripts under test are used as they are: a test either runs 'cronkid' as a command
# (run_cronkid) or sources it (load_cronkid) to call single functions. Sourcing works because both
# scripts only run their 'main' when they are executed, not when they are sourced.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(dirname -- "$TESTS_DIR")"
CRONKID="${REPO_DIR}/cronkid"
INSTALL_SH="${REPO_DIR}/install.sh"
STUBS_DIR="${TESTS_DIR}/lib/stubs"
# The loop driver starts cronkid in a process of its own.
export CRONKID INSTALL_SH
# Seconds a wait_for helper waits for something the counting loop does.
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"

# --- assertions ---------------------------------------------------------------------------------

# Ends the running test with a message. Tests run in a subshell, so this only fails that one test.
fail() {
    echo "      $*" >&2
    exit 1
}

# Ends the running test as skipped, e.g. because a tool it needs is not installed.
skip() {
    echo "      $*" >&2
    exit 77
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-value}"
    [[ $expected == "$actual" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_ne() {
    local unexpected="$1" actual="$2" label="${3:-value}"
    [[ $unexpected != "$actual" ]] || fail "${label}: expected something other than '${actual}'"
}

assert_matches() {
    local actual="$1" pattern="$2" label="${3:-value}"
    [[ $actual =~ $pattern ]] || fail "${label}: '${actual}' does not match '${pattern}'"
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    [[ $haystack == *"$needle"* ]] || fail "${label}: '${needle}' not found in: ${haystack}"
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    [[ $haystack != *"$needle"* ]] || fail "${label}: '${needle}' unexpectedly found in: ${haystack}"
}

assert_file_exists() {
    [[ -f $1 ]] || fail "${2:-file} does not exist: $1"
}

assert_no_file() {
    [[ ! -e $1 ]] || fail "${2:-file} unexpectedly exists: $1"
}

# Asserts that the last 'run' failed and, with a first argument, that stderr holds that message.
assert_failed() {
    (( status != 0 )) || fail "${2:-command} unexpectedly succeeded: ${out}"
    [[ -z ${1:-} ]] || assert_contains "$err" "$1" "stderr"
}

assert_ok() {
    (( status == 0 )) || fail "${1:-command} failed with status ${status}: ${err}${out}"
}

# --- running the scripts under test -------------------------------------------------------------

# The result of the last 'run': its exit status, its stdout and its stderr.
status=0
out=""
err=""

# Runs a command and stores its exit status in 'status', its stdout in 'out' and its stderr in
# 'err'. The command runs in a subshell with 'set -e', like the scripts themselves, so that a 'die'
# or a failing command in a sourced function ends it there and not the test.
run() {
    err=""
    out="$(set -e; "$@" 2>"${TEST_TMP}/stderr")"
    status=$?
    err="$(cat "${TEST_TMP}/stderr")"
}

run_cronkid() {
    run "$CRONKID" "$@"
}

# Sources the script under test into the current test, which makes its functions callable. Both
# scripts turn on 'set -eu'; the harness checks statuses itself, so they are turned off again.
load_cronkid() {
    # shellcheck source=/dev/null
    source "$CRONKID"
    set +eu
}

load_install_sh() {
    # shellcheck source=/dev/null
    source "$INSTALL_SH"
    set +eu
}

# --- the counting loop --------------------------------------------------------------------------

# Starts 'cronkid run' with the short timings of the test suite in the background. The arguments are
# those of the run command, e.g. --limit 5 --warn 2.
start_loop() {
    "${TESTS_DIR}/lib/run_loop.sh" "$@" >"${TEST_TMP}/loop.log" 2>&1 &
    LOOP_PID=$!
}

stop_loop() {
    [[ -n ${LOOP_PID:-} ]] || return 0
    kill "$LOOP_PID" 2>/dev/null
    wait "$LOOP_PID" 2>/dev/null
    LOOP_PID=""
}

loop_log() {
    cat "${TEST_TMP}/loop.log" 2>/dev/null || true
}

# Runs the given command until it succeeds, for at most TEST_TIMEOUT seconds.
wait_for() {
    local deadline=$((SECONDS + TEST_TIMEOUT))
    while ((SECONDS < deadline)); do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    return 1
}

# --- state of the user, the stubs and the service -------------------------------------------------

today() {
    date +%F
}

yesterday() {
    date -d yesterday +%F
}

used_file_path() {
    echo "${HOME}/.cronkid"
}

# Writes the used-time file, e.g. 'seed_used "$(today)" 42'.
seed_used() {
    printf '%s %s\n' "$1" "$2" >"$(used_file_path)"
}

used_line() {
    cat "$(used_file_path)" 2>/dev/null || true
}

# Prints the minutes in the used-time file, or 0 if there are none for today.
used_minutes() {
    local date used
    read -r date used 2>/dev/null <"$(used_file_path)" || true
    if [[ ${date:-} == "$(today)" && ${used:-} =~ ^[0-9]+$ ]]; then echo "$used"; else echo 0; fi
}

used_reached() {
    (( $(used_minutes) >= $1 ))
}

unit_path() {
    echo "${HOME}/.config/systemd/user/cronkid.service"
}

# Writes a service unit for the limit <1> and the warning time <2>, as 'cronkid setup' would.
write_unit() {
    mkdir -p "$(dirname "$(unit_path)")"
    cat >"$(unit_path)" <<EOF
[Unit]
Description=cronkid usage time control (limit: ${1} minutes)

[Service]
Type=simple
ExecStart=/usr/local/bin/cronkid run --limit ${1} --warn ${2:-5}
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

# The graphical sessions the loginctl stub reports, e.g. 'set_sessions c1 c2'.
set_sessions() {
    echo "$*" >"${STUB_STATE}/sessions"
}

# The session type the stub reports for a session; anything but x11, wayland and mir is ignored by
# cronkid. Sessions default to wayland.
set_session_type() {
    echo "$2" >"${STUB_STATE}/type.$1"
}

# Makes the stub behave like a desktop with a running screen locker: a locked session reports
# LockedHint=yes, which is how cronkid notices that its lock arrived.
enable_locker() {
    touch "${STUB_STATE}/locker_active"
}

disable_locker() {
    rm -f "${STUB_STATE}/locker_active"
}

# Unlocks every session, as the user would by typing their password.
unlock_sessions() {
    rm -f "${STUB_STATE}"/locked.*
}

session_is_locked() {
    [[ -e ${STUB_STATE}/locked.$1 ]]
}

# Makes every loginctl call fail, like a system without a usable loginctl.
break_loginctl() {
    touch "${STUB_STATE}/loginctl_broken"
}

# Makes notify-send fail, like a desktop whose notification daemon is not up yet.
break_notify_send() {
    touch "${STUB_STATE}/notify_fail"
}

fix_notify_send() {
    rm -f "${STUB_STATE}/notify_fail"
}

# Empties PATH for the current test, so that 'notify' finds no notify-send, like a system without
# libnotify. Only use it around a single call, since no other command is found either.
without_notify_send() {
    mkdir -p "${TEST_TMP}/empty-bin"
    # shellcheck disable=SC2123  # emptying PATH is the point: no command is found, notify-send least of all
    export PATH="${TEST_TMP}/empty-bin"
}

# The delivered notifications, one '<urgency>|<body>' per line.
notifications() {
    cat "${STUB_STATE}/notifications" 2>/dev/null || true
}

notified() {
    notifications | grep -qE -- "$1"
}

notify_send_calls() {
    cat "${STUB_STATE}/notify-send.log" 2>/dev/null || true
}

# The sessions that were asked to lock, one per line, in the order of the calls.
locks() {
    cat "${STUB_STATE}/locks.log" 2>/dev/null || true
}

lock_count() {
    locks | grep -c . || true
}

locked_at_least() {
    (( $(lock_count) >= $1 ))
}

systemctl_calls() {
    cat "${STUB_STATE}/systemctl.log" 2>/dev/null || true
}

# Makes 'systemctl is-active user@<uid>.service' succeed, i.e. the target user is logged in.
enable_user_manager() {
    touch "${STUB_STATE}/manager_active"
}

# Puts a curl stub first in PATH that prints <1> and succeeds, so that the functions asking the
# GitHub API can be tested without a network.
stub_curl_output() {
    mkdir -p "${TEST_TMP}/curl-stub"
    printf '%s\n' "$1" >"${TEST_TMP}/curl-stub/payload"
    printf '#!/usr/bin/env bash\ncat %s\n' "${TEST_TMP}/curl-stub/payload" \
        >"${TEST_TMP}/curl-stub/curl"
    chmod +x "${TEST_TMP}/curl-stub/curl"
    export PATH="${TEST_TMP}/curl-stub:${PATH}"
}

# Puts a curl stub first in PATH that always fails, like a machine without a network.
stub_curl_failure() {
    mkdir -p "${TEST_TMP}/curl-stub"
    printf '#!/usr/bin/env bash\nexit 7\n' >"${TEST_TMP}/curl-stub/curl"
    chmod +x "${TEST_TMP}/curl-stub/curl"
    export PATH="${TEST_TMP}/curl-stub:${PATH}"
}

# --- test runner --------------------------------------------------------------------------------

harness_setup_env() {
    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cronkid-test-XXXXXX")"
    export TEST_TMP
    export HOME="${TEST_TMP}/home"
    export STUB_STATE="${TEST_TMP}/state"
    mkdir -p "$HOME" "$STUB_STATE"
    # The scripts fall back to ~/.config only when XDG_CONFIG_HOME is unset.
    unset XDG_CONFIG_HOME
    export PATH="${STUBS_DIR}:${PATH}"
    export USER="${USER:-$(id -un)}"
    # Without a session bus address 'notify' gives up before it reaches the stub.
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${STUB_STATE}/bus"
    export TZ=UTC
    LOOP_PID=""
    status=0
    out=""
    err=""
}

harness_teardown() {
    stop_loop
    [[ -z ${TEST_TMP:-} ]] || rm -rf "$TEST_TMP"
}

# Runs every 'test_*' function of the test file, each in its own subshell and environment.
# Arguments filter the tests by substring.
harness_main() {
    local names name filter="${1:-}" failed=0 ran=0 skipped=0 result
    mapfile -t names < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
    for name in "${names[@]}"; do
        [[ -z $filter || $name == *"$filter"* ]] || continue
        ran=$((ran + 1))
        (
            harness_setup_env
            trap harness_teardown EXIT
            "$name"
        )
        result=$?
        case "$result" in
            0) echo "  ok   ${name#test_}" ;;
            77) echo "  skip ${name#test_}"; skipped=$((skipped + 1)) ;;
            *) echo "  FAIL ${name#test_}"; failed=$((failed + 1)) ;;
        esac
    done
    echo "  ${ran} tests, ${failed} failed, ${skipped} skipped"
    return $((failed > 0 ? 1 : 0))
}
