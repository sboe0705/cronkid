#!/usr/bin/env bash
#
# The counting loop of the control service: counting, the warnings, the lock and what a login, an
# unlock and a reset do to it. The loop runs with one second per check and per counted minute
# (tests/lib/run_loop.sh), so a test reaches the lock in a few seconds.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Seconds a test waits when it has to show that something does *not* happen any more.
QUIET_SECONDS=3

test_run_rejects_invalid_options() {
    run_cronkid run
    assert_failed "run requires --limit <minutes>" "run without a limit"
    run_cronkid run --limit 0
    assert_failed "run requires --limit <minutes>" "run with limit 0"
    run_cronkid run --limit 5 --warn abc
    assert_failed "--warn must be a positive number of minutes" "run with a text warning time"
    run_cronkid run --limit 5 --bogus
    assert_failed "unknown option for run: --bogus" "run with an unknown option"
}

test_counts_the_used_minutes() {
    set_sessions c1
    start_loop --limit 10 --warn 2
    wait_for used_reached 3 || fail "the loop did not count 3 minutes: $(loop_log)"
    stop_loop
    assert_matches "$(used_line)" "^$(today) [0-9]+$" "used file"
}

test_counts_from_zero_after_midnight() {
    seed_used "$(yesterday)" 999
    set_sessions c1
    start_loop --limit 5 --warn 2
    wait_for notified "5 minutes of screen time left today" \
        || fail "the minutes of yesterday were not forgotten: $(notifications)"
    wait_for used_reached 1 || fail "the loop did not count a minute: $(loop_log)"
    stop_loop
    assert_matches "$(used_line)" "^$(today) [0-9]+$" "used file"
}

test_warns_and_locks_on_the_way_to_the_limit() {
    set_sessions c1
    enable_locker
    start_loop --limit 4 --warn 2
    wait_for notified "Your screen time for today is up" || fail "the end was not announced: $(notifications)"
    wait_for locked_at_least 1 || fail "the screen was not locked: $(loop_log)"
    stop_loop
    assert_eq "normal|4 minutes of screen time left today.
normal|Only 2 minutes of screen time left.
critical|The screen will be locked in 1 minute.
critical|Your screen time for today is up." "$(notifications)" "notifications"
    assert_contains "$(loop_log)" "limit of 4 minutes reached, locking the screen of user '${USER}'" "log"
    session_is_locked c1 || fail "session c1 is not locked"
}

test_logging_in_with_the_limit_used_up_grants_the_announced_minute() {
    seed_used "$(today)" 30
    set_sessions c1
    enable_locker
    local started=$SECONDS
    TEST_GRACE_SECONDS=4 TEST_TICK_SECONDS=10 start_loop --limit 30 --warn 5
    wait_for notified "The screen will be locked in 1 minute" \
        || fail "the lock was not announced: $(notifications)"
    wait_for locked_at_least 1 || fail "the screen was never locked: $(loop_log)"
    local waited=$((SECONDS - started))
    stop_loop
    (( waited >= 4 )) || fail "the screen was locked after ${waited}s, before the granted minute was over"
}

test_repeats_the_lock_until_a_session_reports_it() {
    seed_used "$(today)" 30
    set_sessions c1
    # No screen locker: loginctl reports success, but nobody locks the screen.
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=10 start_loop --limit 30 --warn 5
    wait_for locked_at_least 3 || fail "the lock was not repeated: $(locks)"
    enable_locker
    wait_for session_is_locked c1 || fail "the screen was never locked: $(locks)"
    local before
    before="$(lock_count)"
    sleep "$QUIET_SECONDS"
    stop_loop
    (( $(lock_count) <= before + 1 )) \
        || fail "the lock was repeated although the session reports it: $(lock_count) locks after ${before}"
    # Only the first lock of a series is logged.
    assert_eq "1" "$(loop_log | grep -c "locking the screen")" "log lines about the lock"
}

test_unlocking_the_screen_warns_again_and_locks_again() {
    seed_used "$(today)" 30
    set_sessions c1
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=10 start_loop --limit 30 --warn 5
    wait_for session_is_locked c1 || fail "the screen was never locked: $(loop_log)"
    # The unlock is only noticed once the loop has seen the lock itself.
    sleep "$QUIET_SECONDS"
    local locks_before warnings_before
    locks_before="$(lock_count)"
    warnings_before="$(notifications | grep -c "will be locked")"
    unlock_sessions
    wait_for notified_more_than "$warnings_before" || fail "the unlock was not answered with a warning"
    wait_for locked_more_than "$locks_before" || fail "the screen was not locked again after the unlock"
    stop_loop
}

notified_more_than() {
    (( $(notifications | grep -c "will be locked") > $1 ))
}

locked_more_than() {
    (( $(lock_count) > $1 ))
}

test_a_further_login_is_announced_with_the_remaining_time() {
    set_sessions c1
    TEST_TICK_SECONDS=30 start_loop --limit 60 --warn 5
    wait_for notified "of screen time left today" || fail "the first login was not announced"
    local before
    before="$(notifications | grep -c .)"
    set_sessions c1 c2
    wait_for more_notifications_than "$before" || fail "the second login was not announced: $(notifications)"
    stop_loop
    assert_contains "$(notifications | tail -n 1)" "of screen time left today." "notification of the login"
}

more_notifications_than() {
    (( $(notifications | grep -c .) > $1 ))
}

test_a_reset_while_the_service_runs_ends_the_lock() {
    seed_used "$(today)" 30
    set_sessions c1
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=30 start_loop --limit 30 --warn 5
    wait_for locked_at_least 1 || fail "the screen was never locked: $(loop_log)"
    local before
    before="$(lock_count)"
    seed_used "$(today)" 0
    unlock_sessions
    wait_for notified "30 minutes of screen time left today" \
        || fail "the reset was not noticed: $(notifications)"
    sleep "$QUIET_SECONDS"
    stop_loop
    assert_eq "$before" "$(lock_count)" "locks after the reset"
}

test_an_undelivered_notification_is_retried() {
    set_sessions c1
    break_notify_send
    TEST_TICK_SECONDS=30 start_loop --limit 60 --warn 5
    wait_for notify_send_tried 3 || fail "the notification was not retried: $(notify_send_calls)"
    assert_eq "" "$(notifications)" "notifications while notify-send fails"
    fix_notify_send
    wait_for notified "60 minutes of screen time left today" \
        || fail "the notification was not delivered after notify-send worked again"
    stop_loop
    assert_eq "1" "$(notifications | grep -c .)" "delivered notifications"
}

notify_send_tried() {
    (( $(notify_send_calls | grep -c .) >= $1 ))
}

test_the_loop_runs_without_a_usable_loginctl() {
    seed_used "$(today)" 5
    break_loginctl
    TEST_GRACE_SECONDS=1 start_loop --limit 5 --warn 2
    wait_for notified "The screen will be locked in 1 minute" \
        || fail "the lock was not announced: $(notifications)"
    wait_for loop_logged_the_lock || fail "the lock was not attempted: $(loop_log)"
    stop_loop
    assert_eq "" "$(locks)" "locked sessions"
}

loop_logged_the_lock() {
    loop_log | grep -q "locking the screen"
}

harness_main "$@"
