#!/usr/bin/env bash
#
# The commands for the current user: setup, remove, status, reset, and the dispatching in main.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_setup_writes_the_unit_and_starts_the_service() {
    run_cronkid setup --limit 30
    assert_ok "setup"
    assert_file_exists "$(unit_path)" "service unit"
    assert_contains "$(cat "$(unit_path)")" \
        "ExecStart=/usr/local/bin/cronkid run --limit 30 --warn 5" "unit"
    assert_file_exists "${HOME}/.config/systemd/user/cronkid.service" "service unit"
    local calls
    calls="$(systemctl_calls)"
    assert_contains "$calls" "systemctl --user daemon-reload" "systemctl calls"
    assert_contains "$calls" "systemctl --user enable cronkid.service" "systemctl calls"
    assert_contains "$calls" "systemctl --user restart cronkid.service" "systemctl calls"
    assert_contains "$out" "limit of 30 minutes" "output"
    assert_contains "$out" "first warning at 5 minutes left" "output"
}

test_setup_takes_the_warning_time() {
    run_cronkid setup --limit 60 --warn 10
    assert_ok "setup"
    assert_contains "$(cat "$(unit_path)")" "--limit 60 --warn 10" "unit"
    assert_contains "$out" "first warning at 10 minutes left" "output"
}

test_setup_moves_a_warning_that_does_not_fit_into_the_limit_to_the_last_minute() {
    run_cronkid setup --limit 3
    assert_ok "setup"
    assert_contains "$(cat "$(unit_path)")" "--limit 3 --warn 1" "unit"
    assert_contains "$out" "first warning at 1 minute left" "output"
}

test_setup_replaces_an_existing_configuration() {
    run_cronkid setup --limit 30
    run_cronkid setup --limit 45 --warn 15
    assert_ok "second setup"
    assert_contains "$(cat "$(unit_path)")" "--limit 45 --warn 15" "unit"
    assert_not_contains "$(cat "$(unit_path)")" "--limit 30" "unit"
}

test_setup_rejects_invalid_options() {
    run_cronkid setup
    assert_failed "setup requires --limit <minutes>" "setup without a limit"
    run_cronkid setup --limit 0
    assert_failed "--limit must be a positive number of minutes" "setup with limit 0"
    run_cronkid setup --limit abc
    assert_failed "--limit must be a positive number of minutes" "setup with a text limit"
    run_cronkid setup --limit 30 --warn 0
    assert_failed "--warn must be a positive number of minutes" "setup with warn 0"
    run_cronkid setup --limit
    assert_failed "--limit requires a value" "setup without a value"
    run_cronkid setup --limit 30 --bogus x
    assert_failed "unknown option for setup: --bogus" "setup with an unknown option"
    assert_no_file "$(unit_path)" "service unit"
}

test_setup_keeps_the_used_time() {
    seed_used "$(today)" 20
    run_cronkid setup --limit 30
    assert_ok "setup"
    assert_eq "20" "$(used_minutes)" "used time after setup"
}

test_remove_deletes_the_unit_and_stops_the_service() {
    write_unit 30 5
    run_cronkid remove
    assert_ok "remove"
    assert_no_file "$(unit_path)" "service unit"
    assert_contains "$(systemctl_calls)" "systemctl --user disable --now cronkid.service" "systemctl calls"
    assert_contains "$out" "control service of user '${USER}' removed" "output"
}

test_remove_keeps_the_used_time() {
    write_unit 30 5
    seed_used "$(today)" 20
    run_cronkid remove
    assert_ok "remove"
    assert_eq "20" "$(used_minutes)" "used time after remove"
}

test_remove_without_a_service_fails() {
    run_cronkid remove
    assert_failed "no control service configured for user '${USER}'" "remove"
}

test_status_without_a_service_reports_the_used_time() {
    seed_used "$(today)" 7
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "no control service configured for user '${USER}' (used today: 7 minutes)" "output"
}

test_status_shows_the_remaining_time() {
    write_unit 60 5
    seed_used "$(today)" 10
    run_cronkid status
    assert_ok "status"
    assert_eq "Remaining time of user '${USER}': 50 minutes (used 10 of 60 minutes today)" "$out" "output"
}

test_status_never_reports_a_negative_remaining_time() {
    write_unit 60 5
    seed_used "$(today)" 90
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "0 minutes (used 90 of 60 minutes today)" "output"
}

test_status_counts_yesterdays_minutes_as_used_up_today() {
    write_unit 60 5
    seed_used "$(yesterday)" 60
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "60 minutes (used 0 of 60 minutes today)" "output"
}

test_reset_sets_the_used_time_of_today_to_zero() {
    seed_used "$(today)" 42
    run_cronkid reset
    assert_ok "reset"
    assert_eq "$(today) 0" "$(used_line)" "used file"
    assert_contains "$out" "used time of user '${USER}' reset" "output"
}

test_own_user_given_with_user_is_handled_without_root() {
    write_unit 60 5
    seed_used "$(today)" 10
    run_cronkid status --user "$USER"
    assert_ok "status --user of oneself"
    assert_contains "$out" "Remaining time of user '${USER}': 50 minutes" "output"
}

test_commands_reject_an_unknown_user() {
    run_cronkid status --user no-such-user-for-cronkid
    assert_failed "unknown user: no-such-user-for-cronkid" "status of an unknown user"
    run_cronkid reset --user no-such-user-for-cronkid
    assert_failed "unknown user: no-such-user-for-cronkid" "reset of an unknown user"
}

test_usage_is_shown_for_help_and_without_a_command() {
    run_cronkid --help
    assert_ok "--help"
    assert_contains "$out" "Usage: cronkid <command> [options]" "usage"
    run_cronkid
    assert_failed "Usage: cronkid <command> [options]" "cronkid without a command"
}

test_unknown_command_fails_with_the_usage() {
    run_cronkid bogus
    assert_failed "unknown command: bogus" "unknown command"
    assert_contains "$err" "Usage: cronkid <command> [options]" "usage"
}

test_version_of_an_uninstalled_script() {
    run_cronkid version
    assert_ok "version"
    assert_contains "$out" "no version, this script was not installed" "output"
    run_cronkid --version
    assert_ok "--version"
    assert_contains "$out" "no version, this script was not installed" "output"
}

harness_main "$@"
