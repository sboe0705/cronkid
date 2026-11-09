#!/usr/bin/env bash
#
# The commands: setup, remove, status, reset, uninstall, the legacy user service, and the
# dispatching in main. The controlled user is the user who runs the tests.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_setup_writes_the_configuration_and_starts_the_service() {
    run_cronkid setup --user "$USER" --limit 30
    assert_ok "setup"
    assert_eq "LIMIT=30
FROM=
UNTIL=
WARN=" "$(cat "$(config_path)")" "configuration"
    assert_eq "644" "$(stat -c %a "$(config_path)")" "mode of the configuration"
    assert_no_file "$(config_path).tmp" "temporary configuration"
    assert_file_exists "$(unit_path)" "service unit"
    assert_contains "$(cat "$(unit_path)")" "run --user %i" "unit"
    local calls
    calls="$(systemctl_calls)"
    assert_contains "$calls" "systemctl daemon-reload" "systemctl calls"
    assert_contains "$calls" "systemctl enable --quiet cronkid@${USER}.service" "systemctl calls"
    assert_contains "$calls" "systemctl restart cronkid@${USER}.service" "systemctl calls"
    assert_contains "$out" "limit of 30 minutes" "output"
    assert_contains "$out" "first warning at 5 minutes left" "output"
}

test_setup_takes_the_period_and_the_warning_time() {
    run_cronkid setup --user "$USER" --from 08:00 --until 20:00 --warn 10
    assert_ok "setup"
    assert_eq "LIMIT=
FROM=08:00
UNTIL=20:00
WARN=10" "$(cat "$(config_path)")" "configuration"
    assert_contains "$out" "allowed 08:00-20:00" "output"
    assert_contains "$out" "first warning at 10 minutes left" "output"
}

test_setup_moves_a_warning_that_does_not_fit_into_the_limit_to_the_last_minute() {
    run_cronkid setup --user "$USER" --limit 3
    assert_ok "setup"
    assert_contains "$out" "first warning at 1 minute left" "output"
}

test_setup_replaces_an_existing_configuration() {
    run_cronkid setup --user "$USER" --limit 30
    run_cronkid setup --user "$USER" --limit 45 --warn 15
    assert_ok "second setup"
    assert_contains "$(cat "$(config_path)")" "LIMIT=45" "configuration"
    assert_contains "$(cat "$(config_path)")" "WARN=15" "configuration"
}

test_setup_rejects_invalid_options() {
    run_cronkid setup --limit 30
    assert_failed "setup requires --user <username>" "setup without a user"
    run_cronkid setup --user "$USER"
    assert_failed "setup requires --limit <minutes> and/or --from <HH:MM> --until <HH:MM>" "setup without a limit"
    run_cronkid setup --user "$USER" --limit 0
    assert_failed "--limit must be a positive number of minutes" "setup with limit 0"
    run_cronkid setup --user "$USER" --limit abc
    assert_failed "--limit must be a positive number of minutes" "setup with a text limit"
    run_cronkid setup --user "$USER" --limit 30 --warn 0
    assert_failed "--warn must be a positive number of minutes" "setup with warn 0"
    run_cronkid setup --user "$USER" --from 08:00
    assert_failed "--from and --until must be given together" "setup with only --from"
    run_cronkid setup --user "$USER" --from 8:00 --until 20:00
    assert_failed "--from must be a time of day as HH:MM" "setup with an invalid --from"
    run_cronkid setup --user "$USER" --from 08:00 --until 24:00
    assert_failed "--until must be a time of day as HH:MM" "setup with an invalid --until"
    run_cronkid setup --user "$USER" --from 20:00 --until 08:00
    assert_failed "--from must be earlier than --until" "setup with a period across midnight"
    run_cronkid setup --user "$USER" --limit
    assert_failed "--limit requires a value" "setup without a value"
    run_cronkid setup --user "$USER" --limit 30 --bogus x
    assert_failed "unknown option for setup: --bogus" "setup with an unknown option"
    run_cronkid setup --user no-such-user-for-cronkid --limit 30
    assert_failed "unknown user: no-such-user-for-cronkid" "setup of an unknown user"
    assert_no_file "$(config_path)" "configuration"
    assert_eq "" "$(systemctl_calls)" "systemctl calls"
}

test_setup_keeps_the_used_time() {
    seed_state 20 2
    run_cronkid setup --user "$USER" --limit 30
    assert_ok "setup"
    assert_eq "$(today) 20 $(today) 2" "$(state_line)" "state after setup"
}

test_setup_removes_the_user_service_of_an_older_version() {
    write_legacy_service
    set_unit_active "user@$(id -u).service"
    run_cronkid setup --user "$USER" --limit 30
    assert_ok "setup"
    assert_no_file "$(legacy_unit_path)" "legacy unit"
    assert_no_file "${HOME}/.config/systemd/user/default.target.wants/cronkid.service" "legacy symlink"
    assert_contains "$(systemctl_calls)" "systemctl --user --machine=${USER}@ stop cronkid.service" "systemctl calls"
    assert_contains "$(runuser_calls)" "runuser -u ${USER} -- rm -f" "runuser calls"
    assert_contains "$out" "removed the user service of an older version" "output"
}

test_setup_does_not_stop_a_legacy_service_without_a_service_manager() {
    write_legacy_service
    run_cronkid setup --user "$USER" --limit 30
    assert_ok "setup"
    assert_no_file "$(legacy_unit_path)" "legacy unit"
    assert_not_contains "$(systemctl_calls)" "--user" "systemctl calls"
}

test_remove_deletes_the_configuration_and_stops_the_service() {
    write_config 30
    seed_state 20 1
    run_cronkid remove --user "$USER"
    assert_ok "remove"
    assert_no_file "$(config_path)" "configuration"
    assert_contains "$(systemctl_calls)" "systemctl disable --now --quiet cronkid@${USER}.service" "systemctl calls"
    assert_contains "$out" "control service of user '${USER}' removed" "output"
    assert_eq "$(today) 20 $(today) 1" "$(state_line)" "state after remove"
}

test_remove_without_a_service_fails() {
    run_cronkid remove --user "$USER"
    assert_failed "no control service configured for user '${USER}'" "remove"
    run_cronkid remove
    assert_failed "remove requires --user <username>" "remove without a user"
}

test_status_without_a_service() {
    run_cronkid status
    assert_ok "status"
    assert_eq "cronkid: no control service configured for user '${USER}'" "$out" "output"
}

test_status_shows_the_remaining_time_and_the_locks() {
    write_config 60
    seed_state 10 2
    run_cronkid status --user "$USER"
    assert_ok "status"
    assert_eq "Remaining time of user '${USER}': 50 minutes
  used 10 of 60 minutes today
  automatic locks: 2 of 5" "$out" "output"
}

test_status_shows_the_period() {
    write_config "" 08:00 20:00
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "allowed from 08:00 until 20:00" "output"
    assert_not_contains "$out" "used" "output"
}

test_status_never_reports_a_negative_remaining_time() {
    write_config 60
    seed_state 90
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "': 0 minutes" "output"
    assert_contains "$out" "used 90 of 60 minutes today" "output"
}

test_status_counts_yesterdays_minutes_as_unused() {
    write_config 60
    seed_state 60 5 "$(yesterday)" "$(yesterday)"
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "': 60 minutes" "output"
    assert_contains "$out" "automatic locks: 0 of 5" "output"
}

test_status_reports_the_lockout() {
    write_config 60
    seed_state 60 5
    run_cronkid status
    assert_ok "status"
    assert_contains "$out" "locked out until midnight: a login shuts the computer down" "output"
}

test_reset_sets_the_used_time_and_the_locks_to_zero() {
    write_config 60
    seed_state 42 5
    run_cronkid reset --user "$USER"
    assert_ok "reset"
    assert_eq "$(today) 0 $(today) 0" "$(state_line)" "state"
    assert_contains "$out" "used time and automatic locks of user '${USER}' reset" "output"
    run_cronkid reset
    assert_failed "reset requires --user <username>" "reset without a user"
}

test_commands_reject_an_unknown_user() {
    run_cronkid status --user no-such-user-for-cronkid
    assert_failed "unknown user: no-such-user-for-cronkid" "status of an unknown user"
    run_cronkid reset --user no-such-user-for-cronkid
    assert_failed "unknown user: no-such-user-for-cronkid" "reset of an unknown user"
    run_cronkid status --user ../x
    assert_failed "invalid user name: ../x" "status of a path"
}

test_uninstall_removes_everything() {
    write_config 60
    seed_state 10
    run_cronkid setup --user "$USER" --limit 60
    cp "$CRONKID" "${TEST_TMP}/bin/cronkid"
    write_legacy_service
    echo "$(today) 3" >"${HOME}/.cronkid"
    run_cronkid uninstall
    assert_ok "uninstall"
    assert_contains "$(systemctl_calls)" "systemctl disable --now --quiet cronkid@${USER}.service" "systemctl calls"
    assert_no_file "${TEST_TMP}/etc/cronkid" "configuration directory"
    assert_no_file "${TEST_TMP}/var/lib/cronkid" "state directory"
    assert_no_file "$(unit_path)" "service unit"
    assert_no_file "${TEST_TMP}/bin/cronkid" "installed script"
    assert_no_file "$(legacy_unit_path)" "legacy unit"
    assert_no_file "${HOME}/.cronkid" "legacy used-time file"
    assert_contains "$out" "cronkid: uninstalled" "output"
}

test_uninstall_disables_an_enabled_service_without_a_configuration() {
    set_unit_enabled "cronkid@${USER}.service"
    run_cronkid uninstall
    assert_ok "uninstall"
    assert_contains "$(systemctl_calls)" "systemctl disable --now --quiet cronkid@${USER}.service" "systemctl calls"
}

test_run_of_a_legacy_user_service_exits_successfully() {
    run_cronkid run --limit 30 --warn 5
    assert_ok "run --limit"
    assert_contains "$err" "this user service is no longer used" "stderr"
}

test_run_rejects_invalid_options() {
    run_cronkid run
    assert_failed "run requires --user <username>" "run without a user"
    run_cronkid run --user "$USER"
    assert_failed "no configuration for user '${USER}'" "run without a configuration"
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
