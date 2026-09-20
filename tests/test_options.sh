#!/usr/bin/env bash
#
# Option parsing and the small pure functions around the countdown and the service unit.
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

test_effective_warn_applies_the_default_and_the_limit() {
    load_cronkid
    assert_eq "5" "$(effective_warn 60 "")" "default warning time"
    assert_eq "10" "$(effective_warn 60 10)" "given warning time"
    assert_eq "59" "$(effective_warn 60 59)" "warning time just inside the limit"
    assert_eq "1" "$(effective_warn 60 60)" "warning time as long as the limit"
    assert_eq "1" "$(effective_warn 3 10)" "warning time beyond the limit"
    assert_eq "1" "$(effective_warn 3 "")" "default warning time beyond the limit"
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

test_minutes_phrase_uses_the_singular_for_one_minute() {
    load_cronkid
    assert_eq "1 minute" "$(minutes_phrase 1)" "1 minute"
    assert_eq "2 minutes" "$(minutes_phrase 2)" "2 minutes"
    assert_eq "0 minutes" "$(minutes_phrase 0)" "0 minutes"
}

test_service_unit_starts_the_run_command_and_is_wanted_by_default_target() {
    load_cronkid
    local unit
    unit="$(service_unit 30 5)"
    assert_contains "$unit" "ExecStart=/usr/local/bin/cronkid run --limit 30 --warn 5" "unit"
    assert_contains "$unit" "WantedBy=default.target" "unit"
    assert_contains "$unit" "Description=cronkid usage time control (limit: 30 minutes)" "unit"
}

test_service_dir_follows_xdg_config_home_of_the_current_user() {
    load_cronkid
    assert_eq "${HOME}/.config/systemd/user" "$(service_dir)" "service directory"
    local with_xdg
    with_xdg="$(XDG_CONFIG_HOME="${TEST_TMP}/xdg" service_dir)"
    assert_eq "${TEST_TMP}/xdg/systemd/user" "$with_xdg" "service directory with XDG_CONFIG_HOME"
}

test_read_limit_takes_the_limit_from_the_unit_and_ignores_the_warning_time() {
    load_cronkid
    assert_eq "" "$(read_limit)" "limit without a unit"
    write_unit 120 5
    assert_eq "120" "$(read_limit)" "limit"
    write_unit 7 90
    assert_eq "7" "$(read_limit)" "limit with a longer warning time"
}

test_read_limit_reads_a_unit_written_before_warn_existed() {
    load_cronkid
    mkdir -p "$(dirname "$(unit_path)")"
    printf '[Service]\nExecStart=/usr/local/bin/cronkid run --limit 45\n' >"$(unit_path)"
    assert_eq "45" "$(read_limit)" "limit of an old unit"
}

harness_main "$@"
