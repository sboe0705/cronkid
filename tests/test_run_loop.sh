#!/usr/bin/env bash
#
# The counting loop of the control service (cronkid run): counting, the warnings, the lock, what a
# login, an unlock and a reset do to it, the fallback for a screen locker that never reports the
# lock, and the shutdown after the last automatic lock. The loop runs with one second per check and
# per counted minute (tests/lib/run_loop.sh), so a test reaches the lock in a few seconds.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Seconds a test waits when it has to show that something does *not* happen (any more).
QUIET_SECONDS=3

# A logged-in user with a session bus, so that notifications arrive.
logged_in() {
    create_bus
    set_sessions "${@:-c1}"
}

lock_warning_count() {
    notifications | grep -c "will be locked" || true
}

lock_warnings_more_than() {
    (( $(lock_warning_count) > $1 ))
}

powered_off() {
    systemctl_called "systemctl poweroff -i"
}

test_counts_the_used_minutes_while_a_session_exists() {
    write_config 10 "" "" 2
    logged_in
    start_loop
    wait_for used_reached 3 || fail "the loop did not count 3 minutes: $(loop_log)"
    set_sessions ""
    sleep 1.5
    local before
    before="$(used_minutes)"
    sleep "$QUIET_SECONDS"
    stop_loop
    assert_eq "$before" "$(used_minutes)" "used time after the logout"
    assert_matches "$(state_line)" "^$(today) [0-9]+ $(today) 0$" "state file"
}

test_counts_from_zero_after_midnight() {
    write_config 5 "" "" 2
    seed_state 999 3 "$(yesterday)" "$(yesterday)"
    logged_in
    start_loop
    wait_for notified "^normal\|5 minutes of screen time left today\.$" \
        || fail "the minutes of yesterday were not forgotten: $(notifications)"
    stop_loop
}

test_warns_and_locks_on_the_way_to_the_limit() {
    write_config 4 "" "" 2
    logged_in
    enable_locker
    start_loop
    wait_for session_is_locked c1 || fail "the screen was not locked: $(loop_log)"
    wait_for locks_in_state_reached 1 || fail "the lock was not counted: $(state_line)"
    stop_loop
    assert_eq "normal|4 minutes of screen time left today.
normal|Your screen will be locked in 2 minutes.
critical|Your screen will be locked in 1 minute (automatic lock 1 of 5; the last one shuts the computer down)." \
        "$(notifications)" "notifications"
    assert_contains "$(loop_log)" \
        "limit of 4 minutes reached, locking the screen of user '${USER}' (automatic lock 1 of 5)" "log"
    assert_eq "1" "$(lock_count_in_state)" "automatic locks"
}

test_logging_in_with_the_limit_used_up_grants_the_announced_minute() {
    write_config 30
    seed_state 30
    logged_in
    enable_locker
    local started=$SECONDS
    TEST_GRACE_SECONDS=4 TEST_TICK_SECONDS=10 start_loop
    wait_for notified "^critical\|Your screen will be locked in 1 minute \(automatic lock 1 of 5" \
        || fail "the lock was not announced: $(notifications)"
    wait_for locked_at_least 1 || fail "the screen was never locked: $(loop_log)"
    local waited=$((SECONDS - started))
    stop_loop
    (( waited >= 4 )) || fail "the screen was locked after ${waited}s, before the granted minute was over"
}

test_repeats_the_lock_until_a_session_reports_it() {
    write_config 30
    seed_state 30
    logged_in
    # No screen locker: loginctl reports success, but nobody locks the screen.
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=10 start_loop
    wait_for locked_at_least 3 || fail "the lock was not repeated: $(locks)"
    enable_locker
    wait_for session_is_locked c1 || fail "the screen was never locked: $(locks)"
    local before
    before="$(lock_count)"
    sleep "$QUIET_SECONDS"
    stop_loop
    (( $(lock_count) <= before + 1 )) \
        || fail "the lock was repeated although the session reports it: $(lock_count) locks after ${before}"
    # A series of locks is logged and counted once.
    assert_eq "1" "$(loop_log | grep -c "locking the screen")" "log lines about the lock"
    assert_eq "1" "$(lock_count_in_state)" "automatic locks"
}

test_a_locker_without_the_hint_is_locked_once_per_minute_without_counting() {
    write_config 30
    seed_state 30
    logged_in
    # With 3 seconds per counted minute the loop gives up on the confirmation after 3 seconds and
    # then locks once every 3 seconds instead of every second.
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=3 start_loop
    wait_for locked_at_least 1 || fail "the screen was never locked: $(loop_log)"
    sleep 5
    local before
    before="$(lock_count)"
    sleep 6
    stop_loop
    local repeated=$(($(lock_count) - before))
    (( repeated >= 1 && repeated <= 3 )) || fail "${repeated} locks in 6 seconds of the fallback"
    assert_eq "1" "$(lock_count_in_state)" "automatic locks"
}

test_unlocking_the_screen_warns_again_and_locks_again() {
    write_config 30
    seed_state 30
    logged_in
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=10 start_loop
    wait_for session_is_locked c1 || fail "the screen was never locked: $(loop_log)"
    # The unlock is only noticed once the loop has seen the lock itself.
    sleep "$QUIET_SECONDS"
    local warnings_before
    warnings_before="$(lock_warning_count)"
    unlock_sessions
    wait_for lock_warnings_more_than "$warnings_before" || fail "the unlock was not answered with a warning"
    wait_for session_is_locked c1 || fail "the screen was not locked again after the unlock"
    wait_for locks_in_state_reached 2 || fail "the second lock was not counted: $(state_line)"
    stop_loop
    assert_contains "$(notifications | tail -n 1)" "automatic lock 2 of 5" "warning after the unlock"
}

test_a_further_login_is_announced_with_the_remaining_time() {
    write_config 60
    logged_in
    TEST_TICK_SECONDS=30 start_loop
    wait_for notified "of screen time left today" || fail "the first login was not announced"
    local before
    before="$(notification_count)"
    set_sessions c1 c2
    wait_for more_notifications_than "$before" || fail "the second login was not announced: $(notifications)"
    stop_loop
    assert_eq "normal|60 minutes of screen time left today." "$(notifications | tail -n 1)" \
        "notification of the login"
}

test_a_reset_while_the_service_runs_ends_the_lock() {
    write_config 30
    seed_state 30
    logged_in
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=30 start_loop
    wait_for locked_at_least 1 || fail "the screen was never locked: $(loop_log)"
    seed_state 0 0
    unlock_sessions
    wait_for notified "30 minutes of screen time left today" \
        || fail "the reset was not noticed: $(notifications)"
    local before
    before="$(lock_count)"
    sleep "$QUIET_SECONDS"
    stop_loop
    assert_eq "$before" "$(lock_count)" "locks after the reset"
}

test_an_undelivered_notification_is_retried() {
    write_config 60
    logged_in
    break_notify_send
    TEST_TICK_SECONDS=30 start_loop
    wait_for notify_send_tried 3 || fail "the notification was not retried: $(notify_send_calls)"
    assert_eq "" "$(notifications)" "notifications while notify-send fails"
    fix_notify_send
    wait_for notified "60 minutes of screen time left today" \
        || fail "the notification was not delivered after notify-send worked again"
    sleep 1.5
    stop_loop
    assert_eq "1" "$(notification_count)" "delivered notifications"
}

notify_send_tried() {
    (( $(notify_send_calls | grep -c .) >= $1 ))
}

test_nothing_happens_without_a_session() {
    write_config 30
    seed_state 30
    create_bus
    TEST_GRACE_SECONDS=1 start_loop
    sleep "$QUIET_SECONDS"
    stop_loop
    assert_eq "" "$(locks)" "locked sessions"
    assert_eq "" "$(notifications)" "notifications"
    assert_eq "$(today) 30 $(today) 0" "$(state_line)" "state"
}

test_outside_the_allowed_period_the_screen_is_locked() {
    skip_near_midnight
    write_config "" "$(clock_in 10)" "$(clock_in 60)"
    logged_in
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=30 start_loop
    wait_for session_is_locked c1 || fail "the screen was not locked: $(loop_log)"
    stop_loop
    assert_contains "$(notifications)" "critical|Your screen will be locked in 1 minute" "notifications"
    assert_contains "$(loop_log)" "outside of the allowed period" "log"
}

test_the_fifth_lock_shuts_the_computer_down_instead() {
    write_config 30
    seed_state 30 4
    logged_in
    enable_locker
    TEST_GRACE_SECONDS=1 TEST_TICK_SECONDS=30 start_loop
    wait_for powered_off || fail "the computer was not shut down: $(loop_log)"
    stop_loop
    assert_eq "critical|The computer will shut down in 1 minute.
critical|The computer will shut down in 2 seconds." "$(notifications)" "notifications"
    assert_contains "$(loop_log)" "reached 5 automatic locks, shutting down in 2 seconds" "log"
    assert_eq "5" "$(lock_count_in_state)" "automatic locks"
    assert_eq "" "$(locks)" "locked sessions"
}

test_a_login_after_the_lockout_shuts_down_and_tells_the_other_users() {
    write_config 30
    seed_state 30 5
    logged_in
    create_bus 0
    add_logged_in_user 0 root
    TEST_TICK_SECONDS=30 start_loop
    wait_for powered_off || fail "the computer was not shut down: $(loop_log)"
    stop_loop
    assert_eq "critical|The computer will shut down in 2 seconds.
critical|The computer will shut down in 2 seconds. (cronkid: user '${USER}' is locked out for today)" \
        "$(notifications)" "notifications of the user and of root"
}

test_the_shutdown_does_not_wait_forever_for_the_warning() {
    write_config 30
    seed_state 30 5
    logged_in
    break_notify_send
    local started=$SECONDS
    TEST_TICK_SECONDS=30 start_loop
    wait_for powered_off || fail "the computer was not shut down: $(loop_log)"
    local waited=$((SECONDS - started))
    stop_loop
    # 3 seconds for the delivery and 2 for the warning.
    (( waited >= 4 )) || fail "the computer was shut down after ${waited}s"
}

test_a_reset_cancels_the_shutdown() {
    write_config 30
    seed_state 30 5
    logged_in
    TEST_SHUTDOWN_WARN_SECONDS=4 TEST_TICK_SECONDS=30 start_loop
    wait_for loop_logged "shutting down in 4 seconds" || fail "the shutdown did not start: $(loop_log)"
    seed_state 0 0
    wait_for notified "30 minutes of screen time left today" || fail "the reset was not noticed: $(notifications)"
    sleep 5
    stop_loop
    powered_off && fail "the computer was shut down after the reset"
    return 0
}

harness_main "$@"
