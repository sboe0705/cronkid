#!/usr/bin/env bash
#
# Option parsing, the configuration file and the small pure functions around the countdown and the
# service unit.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_user_option_is_parsed() {
    load_cronkid
    parse_user_option status --user kid
    assert_eq "kid" "$USER_OPTION" "--user"
    parse_user_option status
    assert_eq "" "$USER_OPTION" "no --user"
}

test_user_option_rejects_unknown_and_incomplete_options() {
    load_cronkid
    run parse_user_option status --bogus
    assert_failed "unknown option for status: --bogus" "parse_user_option"
    run parse_user_option status --user
    assert_failed "--user requires a value" "parse_user_option"
}

test_check_user_sets_the_target_user() {
    load_cronkid
    check_user "$USER"
    assert_eq "$USER" "$TARGET_USER" "TARGET_USER"
    assert_eq "$(id -u)" "$TARGET_UID" "TARGET_UID"
    assert_eq "$HOME" "$TARGET_HOME" "TARGET_HOME"
}

test_check_user_rejects_paths_unknown_users_and_root() {
    load_cronkid
    run check_user "../etc/passwd"
    assert_failed "invalid user name: ../etc/passwd" "check_user with a path"
    run check_user "no-such-user-for-cronkid"
    assert_failed "unknown user: no-such-user-for-cronkid" "check_user with an unknown user"
    # The getent stub knows only the current user, so root is checked with the real one.
    PATH="${PATH#"${STUBS_DIR}":}" run check_user root
    assert_failed "the root user cannot be controlled" "check_user root"
}

test_valid_time_and_time_minutes() {
    load_cronkid
    valid_time "00:00" || fail "00:00 is not valid"
    valid_time "23:59" || fail "23:59 is not valid"
    valid_time "24:00" && fail "24:00 is valid"
    valid_time "8:00" && fail "8:00 is valid"
    valid_time "08:60" && fail "08:60 is valid"
    assert_eq "0" "$(time_minutes 00:00)" "minutes of 00:00"
    assert_eq "490" "$(time_minutes 08:10)" "minutes of 08:10"
    assert_eq "1439" "$(time_minutes 23:59)" "minutes of 23:59"
}

test_read_config_parses_the_file_and_ignores_invalid_values() {
    load_cronkid
    run read_config "$USER"
    assert_failed "" "read_config without a file"
    write_config 120 08:00 20:00 10
    read_config "$USER"
    assert_eq "120 08:00 20:00 10" "$CFG_LIMIT $CFG_FROM $CFG_UNTIL $CFG_WARN" "configuration"
    # shellcheck disable=SC2016  # the command substitution must not run
    printf 'LIMIT=0\nFROM=8:00\nUNTIL=20:00\nWARN=abc\nLIMIT=$(touch x)\n' >"$(config_path)"
    read_config "$USER"
    assert_eq "|||" "${CFG_LIMIT}|${CFG_FROM}|${CFG_UNTIL}|${CFG_WARN}" \
        "invalid values, and a period with only one valid end"
}

test_effective_warn_applies_the_default_and_the_limit() {
    load_cronkid
    assert_eq "5" "$(effective_warn 60 "")" "default warning time"
    assert_eq "10" "$(effective_warn 60 10)" "given warning time"
    assert_eq "59" "$(effective_warn 60 59)" "warning time just inside the limit"
    assert_eq "1" "$(effective_warn 60 60)" "warning time as long as the limit"
    assert_eq "1" "$(effective_warn 3 10)" "warning time beyond the limit"
    assert_eq "1" "$(effective_warn 3 "")" "default warning time beyond the limit"
    assert_eq "30" "$(effective_warn "" 30)" "warning time without a limit"
}

test_remaining_minutes_takes_the_limit() {
    load_cronkid
    CFG_LIMIT=60 CFG_FROM="" CFG_UNTIL="" USED=10
    remaining_minutes
    assert_eq "50 limit" "$REMAINING $REASON" "remaining time"
    USED=90
    remaining_minutes
    assert_eq "0 limit" "$REMAINING $REASON" "remaining time beyond the limit"
}

test_remaining_minutes_takes_the_end_of_the_period() {
    skip_near_midnight
    load_cronkid
    CFG_LIMIT="" CFG_FROM="$(clock_in -10)" CFG_UNTIL="$(clock_in 20)" USED=0
    remaining_minutes
    assert_eq "period" "$REASON" "reason"
    (( REMAINING >= 19 && REMAINING <= 20 )) || fail "remaining time in the period: ${REMAINING}"
    CFG_LIMIT=5
    remaining_minutes
    assert_eq "5 limit" "$REMAINING $REASON" "a limit that ends before the period"
    CFG_LIMIT=60
    remaining_minutes
    assert_eq "period" "$REASON" "a period that ends before the limit"
    CFG_FROM="$(clock_in 10)"
    remaining_minutes
    assert_eq "0 period" "$REMAINING $REASON" "remaining time before the period"
    CFG_FROM="$(clock_in -20)" CFG_UNTIL="$(clock_in -10)"
    remaining_minutes
    assert_eq "0 period" "$REMAINING $REASON" "remaining time after the period"
}

test_countdown_stage_maps_the_remaining_minutes() {
    load_cronkid
    assert_eq "ok" "$(countdown_stage 6 5)" "6 minutes left"
    assert_eq "warn" "$(countdown_stage 5 5)" "5 minutes left"
    assert_eq "warn" "$(countdown_stage 2 5)" "2 minutes left"
    assert_eq "final" "$(countdown_stage 1 5)" "1 minute left"
    assert_eq "up" "$(countdown_stage 0 5)" "no minutes left"
    assert_eq "ok" "$(countdown_stage 2 1)" "2 minutes left with a 1 minute warning"
    assert_eq "final" "$(countdown_stage 1 1)" "1 minute left with a 1 minute warning"
}

test_final_warning_announces_the_lock_or_the_shutdown() {
    load_cronkid
    LOCKS=0
    assert_eq "Your screen will be locked in 1 minute (automatic lock 1 of 5; the last one shuts the computer down)." \
        "$(final_warning)" "first lock"
    LOCKS=3
    assert_contains "$(final_warning)" "automatic lock 4 of 5" "fourth lock"
    LOCKS=4
    assert_eq "The computer will shut down in 1 minute." "$(final_warning)" "fifth lock"
}

test_minutes_phrase_uses_the_singular_for_one_minute() {
    load_cronkid
    assert_eq "1 minute" "$(minutes_phrase 1)" "1 minute"
    assert_eq "2 minutes" "$(minutes_phrase 2)" "2 minutes"
    assert_eq "0 minutes" "$(minutes_phrase 0)" "0 minutes"
}

test_config_phrase_describes_limit_and_period() {
    load_cronkid
    CFG_LIMIT=120 CFG_FROM="" CFG_UNTIL=""
    assert_eq "limit of 120 minutes" "$(config_phrase)" "limit"
    CFG_LIMIT="" CFG_FROM=08:00 CFG_UNTIL=20:00
    assert_eq "allowed 08:00-20:00" "$(config_phrase)" "period"
    CFG_LIMIT=1
    assert_eq "limit of 1 minute, allowed 08:00-20:00" "$(config_phrase)" "both"
}

test_service_unit_is_a_template_for_the_run_command() {
    load_cronkid
    local unit
    unit="$(service_unit)"
    assert_contains "$unit" "ExecStart=${INSTALL_PATH} run --user %i" "unit"
    assert_contains "$unit" "Restart=always" "unit"
    assert_contains "$unit" "WantedBy=multi-user.target" "unit"
}

harness_main "$@"
