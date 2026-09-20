#!/usr/bin/env bash
#
# The functions that talk to the desktop: notifications, the graphical sessions and the screen lock.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_notify_sends_the_message_with_its_urgency() {
    load_cronkid
    notify critical "time is up"
    assert_eq "0" "$?" "notify"
    assert_eq "critical|time is up" "$(notifications)" "notification"
    assert_contains "$(notify_send_calls)" "--app-name=cronkid" "notify-send call"
    assert_contains "$(notify_send_calls)" "Screen time" "notify-send call"
}

test_notify_reports_an_undelivered_message() {
    load_cronkid
    break_notify_send
    notify normal "hello"
    assert_ne "0" "$?" "notify with a failing notify-send"
    assert_eq "" "$(notifications)" "notifications"
}

test_notify_succeeds_without_notify_send() {
    load_cronkid
    # Nothing can be retried without notify-send, so the message counts as handled.
    ( without_notify_send; notify normal "hello" )
    assert_eq "0" "$?" "notify without notify-send"
    assert_eq "" "$(notifications)" "notifications"
}

test_notify_gives_up_without_a_session_bus() {
    load_cronkid
    [[ ! -S /run/user/${UID}/bus ]] || skip "this user has a session bus at /run/user/${UID}/bus"
    unset DBUS_SESSION_BUS_ADDRESS
    notify normal "hello"
    assert_ne "0" "$?" "notify without a bus"
    assert_eq "" "$(notifications)" "notifications"
}

test_graphical_sessions_lists_only_sessions_that_can_show_a_notification() {
    load_cronkid
    set_sessions c1 c2 c3 c4
    set_session_type c1 wayland
    set_session_type c2 tty
    set_session_type c3 x11
    set_session_type c4 mir
    assert_eq "c1
c3
c4" "$(graphical_sessions)" "graphical sessions"
}

test_graphical_sessions_is_empty_without_a_usable_loginctl() {
    load_cronkid
    set_sessions c1
    break_loginctl
    assert_eq "" "$(graphical_sessions)" "graphical sessions"
}

test_lock_sessions_locks_every_session_of_the_user() {
    load_cronkid
    set_sessions c1 c2
    enable_locker
    lock_sessions
    assert_eq "c1
c2" "$(locks)" "locked sessions"
    session_is_locked c1 || fail "session c1 is not locked"
    session_is_locked c2 || fail "session c2 is not locked"
}

test_lock_sessions_survives_a_session_that_cannot_be_locked() {
    load_cronkid
    set_sessions c1
    # Without a screen locker loginctl reports success and nothing happens.
    lock_sessions
    assert_eq "0" "$?" "lock_sessions"
    assert_eq "c1" "$(locks)" "locked sessions"
    sessions_locked && fail "a session reports itself as locked although no locker ran"
    return 0
}

test_sessions_locked_follows_the_locked_hint() {
    load_cronkid
    set_sessions c1 c2
    sessions_locked && fail "a session reports itself as locked"
    enable_locker
    lock_sessions
    sessions_locked || fail "no session reports itself as locked"
    unlock_sessions
    sessions_locked && fail "a session still reports itself as locked after the unlock"
    return 0
}

test_sessions_locked_is_false_without_a_usable_loginctl() {
    load_cronkid
    set_sessions c1
    break_loginctl
    sessions_locked && fail "a session reports itself as locked without loginctl"
    return 0
}

harness_main "$@"
