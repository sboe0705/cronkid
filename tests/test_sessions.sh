#!/usr/bin/env bash
#
# The functions that talk to the desktop: notifications, the user's sessions and the screen lock.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_notify_user_sends_the_message_as_the_user_with_its_urgency() {
    load_cronkid
    create_bus
    notify_user "$USER" critical "time is up"
    assert_eq "0" "$?" "notify_user"
    assert_eq "critical|time is up" "$(notifications)" "notification"
    assert_contains "$(notify_send_calls)" "--app-name=cronkid" "notify-send call"
    assert_contains "$(notify_send_calls)" "Screen time" "notify-send call"
    assert_contains "$(runuser_calls)" "runuser -u ${USER} -- env DBUS_SESSION_BUS_ADDRESS=unix:path=${TEST_TMP}/run/user/$(id -u)/bus" \
        "runuser call"
}

test_notify_user_reports_an_undelivered_message() {
    load_cronkid
    create_bus
    break_notify_send
    notify_user "$USER" normal "hello"
    assert_ne "0" "$?" "notify_user with a failing notify-send"
    assert_eq "" "$(notifications)" "notifications"
}

test_notify_user_gives_up_without_a_session_bus() {
    load_cronkid
    notify_user "$USER" normal "hello"
    assert_ne "0" "$?" "notify_user without a bus"
    assert_eq "" "$(notify_send_calls)" "notify-send calls"
}

test_notify_user_succeeds_without_notify_send() {
    load_cronkid
    # Nothing can be retried without notify-send, so the message counts as handled.
    ( without_notify_send; notify_user "$USER" normal "hello" )
    assert_eq "0" "$?" "notify_user without notify-send"
    assert_eq "" "$(notifications)" "notifications"
}

test_notify_others_tells_every_other_logged_in_user() {
    load_cronkid
    create_bus
    create_bus 0
    add_logged_in_user 0 root
    notify_others "$USER" "shutting down"
    assert_eq "critical|shutting down" "$(notifications)" "notifications"
    assert_contains "$(runuser_calls)" "runuser -u root" "runuser calls"
    assert_not_contains "$(runuser_calls)" "runuser -u ${USER} " "runuser calls"
}

test_user_sessions_lists_only_login_sessions_that_are_not_closing() {
    load_cronkid
    set_sessions c1 c2 c3 c4 5
    set_session_class c2 manager
    set_session_class c3 greeter
    set_session_state c4 closing
    set_session_class 5 user-early
    assert_eq "c1
5" "$(user_sessions "$USER")" "sessions"
}

test_user_sessions_is_empty_without_a_usable_loginctl() {
    load_cronkid
    set_sessions c1
    break_loginctl
    assert_eq "" "$(user_sessions "$USER")" "sessions"
}

test_lock_sessions_locks_every_session_of_the_user() {
    load_cronkid
    set_sessions c1 c2
    enable_locker
    lock_sessions "$USER"
    assert_eq "c1
c2" "$(locks)" "locked sessions"
    session_is_locked c1 || fail "session c1 is not locked"
    session_is_locked c2 || fail "session c2 is not locked"
}

test_lock_sessions_survives_a_session_that_cannot_be_locked() {
    load_cronkid
    set_sessions c1
    # Without a screen locker loginctl reports success and nothing happens.
    lock_sessions "$USER"
    assert_eq "0" "$?" "lock_sessions"
    assert_eq "c1" "$(locks)" "locked sessions"
    sessions_locked "$USER" && fail "a session reports itself as locked although no locker ran"
    return 0
}

test_sessions_locked_follows_the_locked_hint() {
    load_cronkid
    set_sessions c1 c2
    sessions_locked "$USER" && fail "a session reports itself as locked"
    enable_locker
    lock_sessions "$USER"
    sessions_locked "$USER" || fail "no session reports itself as locked"
    unlock_sessions
    sessions_locked "$USER" && fail "a session still reports itself as locked after the unlock"
    return 0
}

test_sessions_locked_is_false_without_a_usable_loginctl() {
    load_cronkid
    set_sessions c1
    break_loginctl
    sessions_locked "$USER" && fail "a session reports itself as locked without loginctl"
    return 0
}

harness_main "$@"
