#!/usr/bin/env bash
#
# The state file /var/lib/cronkid/<user>: its format, the daily reset of the used time, the reset of
# the automatic locks at the start of the period day, and the atomic write.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_state_is_written_with_todays_date_and_the_period_day() {
    load_cronkid
    read_config "$USER"
    write_state "$USER" 42 2
    assert_eq "$(today) 42 $(today) 2" "$(state_line)" "state file"
    read_state "$USER"
    assert_eq "42" "$USED" "used minutes"
    assert_eq "2" "$LOCKS" "locks"
}

test_state_is_readable_by_everyone_and_leaves_no_temporary_file() {
    load_cronkid
    read_config "$USER"
    write_state "$USER" 1 0
    assert_eq "644" "$(stat -c %a "$(state_path)")" "mode of the state file"
    assert_no_file "$(state_path).tmp" "temporary state file"
}

test_minutes_and_locks_of_another_day_count_as_zero() {
    load_cronkid
    read_config "$USER"
    seed_state 500 3 "$(yesterday)" "$(yesterday)"
    read_state "$USER"
    assert_eq "0" "$USED" "used time of yesterday"
    assert_eq "0" "$LOCKS" "locks of yesterday"
}

test_missing_file_counts_as_zero() {
    load_cronkid
    read_config "$USER"
    read_state "$USER"
    assert_eq "0" "$USED" "used time without a file"
    assert_eq "0" "$LOCKS" "locks without a file"
}

test_unreadable_content_counts_as_zero() {
    load_cronkid
    read_config "$USER"
    mkdir -p "$(dirname "$(state_path)")"
    printf '%s abc %s x\n' "$(today)" "$(today)" >"$(state_path)"
    read_state "$USER"
    assert_eq "0" "$USED" "used time that is not a number"
    assert_eq "0" "$LOCKS" "locks that are not a number"
    : >"$(state_path)"
    read_state "$USER"
    assert_eq "0" "$USED" "used time in an empty file"
}

test_the_period_day_starts_at_from() {
    skip_near_midnight
    load_cronkid
    CFG_FROM="" CFG_UNTIL=""
    assert_eq "$(today)" "$(period_day)" "period day without a period"
    CFG_FROM="$(clock_in 10)" CFG_UNTIL="23:59"
    assert_eq "$(yesterday)" "$(period_day)" "period day before FROM"
    CFG_FROM="$(clock_in -10)"
    assert_eq "$(today)" "$(period_day)" "period day after FROM"
}

test_locks_of_the_evening_before_still_count_before_from() {
    skip_near_midnight
    load_cronkid
    write_config "" "$(clock_in 10)" "23:59"
    read_config "$USER"
    # Locked out yesterday evening: the used time is reset, the locks are not.
    seed_state 60 5 "$(yesterday)" "$(yesterday)"
    read_state "$USER"
    assert_eq "0" "$USED" "used time"
    assert_eq "5" "$LOCKS" "locks of the period day"
}

harness_main "$@"
