#!/usr/bin/env bash
#
# Test harness of the cronkid test suite. A test file sources this file, defines functions named
# 'test_*' and calls 'harness_main "$@"' at the end. Every test runs in its own subshell with
#
#   - a fresh temporary directory (TEST_TMP) that holds the configuration, the state, the service
#     unit, the installed script and the runtime directories of the users,
#   - a fresh HOME, which getent reports as the home of the current user, so that the legacy files
#     cronkid looks for in a home directory are the test's own,
#   - a fresh stub state directory (STUB_STATE), and
#   - tests/lib/stubs first in PATH, so that loginctl, systemctl, runuser, getent and notify-send are
#     stubs.
#
# The controlled user is the user who runs the tests: cronkid needs a user that exists, and refuses
# to control root. The scripts under test are used as they are; tests/lib/cronkid_cmd and
# tests/lib/run_loop.sh source cronkid and only point its paths into TEST_TMP (cronkid_paths) and
# replace require_root, which would call sudo. Sourcing works because both scripts only run their
# 'main' when they are executed, not when they are sourced.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(dirname -- "$TESTS_DIR")"
CRONKID="${REPO_DIR}/cronkid"
INSTALL_SH="${REPO_DIR}/install.sh"
STUBS_DIR="${TESTS_DIR}/lib/stubs"
# The command wrapper and the loop driver start cronkid in a process of their own.
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
    [[ ! -e $1 && ! -L $1 ]] || fail "${2:-file} unexpectedly exists: $1"
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

# Runs a cronkid command, e.g. 'run_cronkid setup --user "$USER" --limit 30', with the paths of the
# test and without sudo.
run_cronkid() {
    run "${TESTS_DIR}/lib/cronkid_cmd" "$@"
}

# Points the paths of a sourced cronkid into the test's temporary directory.
cronkid_paths() {
    CONFIG_DIR="${TEST_TMP}/etc/cronkid"
    STATE_DIR="${TEST_TMP}/var/lib/cronkid"
    UNIT_PATH="${TEST_TMP}/etc/systemd/system/cronkid@.service"
    INSTALL_PATH="${TEST_TMP}/bin/cronkid"
    RUNTIME_DIR="${TEST_TMP}/run/user"
}

# Sources the script under test into the current test, which makes its functions callable, with the
# paths of the test and a require_root that does nothing. Both scripts turn on 'set -eu'; the
# harness checks statuses itself, so they are turned off again.
load_cronkid() {
    # shellcheck source=/dev/null
    source "$CRONKID"
    set +eu
    cronkid_paths
    # shellcheck disable=SC2317  # the override is called by the functions under test
    require_root() { :; }
}

load_install_sh() {
    # shellcheck source=/dev/null
    source "$INSTALL_SH"
    set +eu
}

# --- the counting loop --------------------------------------------------------------------------

# Starts 'cronkid run --user <current user>' with the short timings of the test suite in the
# background. The configuration has to be written before, with write_config.
start_loop() {
    "${TESTS_DIR}/lib/run_loop.sh" --user "$USER" >"${TEST_TMP}/loop.log" 2>&1 &
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

loop_logged() {
    loop_log | grep -qE -- "$1"
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

# --- configuration and state of the user ----------------------------------------------------------

today() {
    date +%F
}

yesterday() {
    date -d yesterday +%F
}

config_path() {
    echo "${TEST_TMP}/etc/cronkid/${USER}.conf"
}

state_path() {
    echo "${TEST_TMP}/var/lib/cronkid/${USER}"
}

unit_path() {
    echo "${TEST_TMP}/etc/systemd/system/cronkid@.service"
}

# Writes the configuration of the user as 'cronkid setup' would: write_config <limit> [<from>
# <until>] [<warn>], with empty values for what is not configured.
write_config() {
    mkdir -p "$(dirname "$(config_path)")"
    printf 'LIMIT=%s\nFROM=%s\nUNTIL=%s\nWARN=%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >"$(config_path)"
}

# Writes the state file: seed_state <minutes> [<locks>] [<date>] [<period day>]. The dates default to
# today, which is the period day of a configuration without a period.
seed_state() {
    mkdir -p "$(dirname "$(state_path)")"
    printf '%s %s %s %s\n' "${3:-$(today)}" "$1" "${4:-$(today)}" "${2:-0}" >"$(state_path)"
}

state_line() {
    cat "$(state_path)" 2>/dev/null || true
}

# Prints the minutes in the state file, or 0 if there are none for today.
used_minutes() {
    local date used
    read -r date used _ 2>/dev/null <"$(state_path)" || true
    if [[ ${date:-} == "$(today)" && ${used:-} =~ ^[0-9]+$ ]]; then echo "$used"; else echo 0; fi
}

# Prints the automatic locks in the state file.
lock_count_in_state() {
    local locks
    read -r _ _ _ locks 2>/dev/null <"$(state_path)" || true
    echo "${locks:-0}"
}

used_reached() {
    (( $(used_minutes) >= $1 ))
}

locks_in_state_reached() {
    (( $(lock_count_in_state) >= $1 ))
}

# A time of day <1> minutes from now as HH:MM. Tests of the allowed period use the real clock and
# skip themselves when the period would cross midnight.
clock_in() {
    date -d "${1} minutes" +%H:%M
}

skip_near_midnight() {
    local now
    now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
    (( now >= 30 && now < 23 * 60 + 30 )) || skip "too close to midnight for a test of the allowed period"
}

# --- the stubs ------------------------------------------------------------------------------------

# Creates the session bus socket of the user with the uid <1> (default: the current user), without
# which cronkid does not try to deliver a notification.
create_bus() {
    local uid="${1:-$(id -u)}" dir
    dir="${TEST_TMP}/run/user/${uid}"
    mkdir -p "$dir"
    command -v python3 >/dev/null 2>&1 || skip "python3 is needed to create a socket"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${dir}/bus"
}

# The sessions the loginctl stub reports for the user, e.g. 'set_sessions c1 c2'.
set_sessions() {
    echo "$*" >"${STUB_STATE}/sessions"
}

# The class (default: user) and state (default: active) the stub reports for a session.
set_session_class() {
    echo "$2" >"${STUB_STATE}/class.$1"
}

set_session_state() {
    echo "$2" >"${STUB_STATE}/state.$1"
}

# Further logged-in users for 'loginctl list-users', as '<uid> <name>' lines.
add_logged_in_user() {
    echo "$1 $2" >>"${STUB_STATE}/other_users"
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

# Empties PATH for the current test, so that notify_user finds no notify-send, like a system without
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

notification_count() {
    notifications | grep -c . || true
}

more_notifications_than() {
    (( $(notification_count) > $1 ))
}

notify_send_calls() {
    cat "${STUB_STATE}/notify-send.log" 2>/dev/null || true
}

runuser_calls() {
    cat "${STUB_STATE}/runuser.log" 2>/dev/null || true
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

locked_more_than() {
    (( $(lock_count) > $1 ))
}

systemctl_calls() {
    cat "${STUB_STATE}/systemctl.log" 2>/dev/null || true
}

systemctl_called() {
    systemctl_calls | grep -qF -- "$1"
}

# Makes 'systemctl is-active <unit>' (or is-enabled) succeed.
set_unit_active() {
    touch "${STUB_STATE}/active.$1"
}

set_unit_enabled() {
    touch "${STUB_STATE}/enabled.$1"
}

# Writes the user service of a version before the system service into the test's HOME, enabled.
write_legacy_service() {
    local dir="${HOME}/.config/systemd/user"
    mkdir -p "${dir}/default.target.wants"
    printf '[Service]\nExecStart=/usr/local/bin/cronkid run --limit 30\n' >"${dir}/cronkid.service"
    ln -sf ../cronkid.service "${dir}/default.target.wants/cronkid.service"
}

legacy_unit_path() {
    echo "${HOME}/.config/systemd/user/cronkid.service"
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
    export STUB_STATE="${TEST_TMP}/stub"
    # The directories a real system has: the one of the installed script and of the system units.
    mkdir -p "$HOME" "$STUB_STATE" "${TEST_TMP}/bin" "${TEST_TMP}/etc/systemd/system"
    export PATH="${STUBS_DIR}:${PATH}"
    export USER="${USER:-$(id -un)}"
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
