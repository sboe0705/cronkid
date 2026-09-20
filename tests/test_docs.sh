#!/usr/bin/env bash
#
# Checks that keep the scripts and their documentation together: valid syntax, no drift between the
# copies of the version functions in cronkid and install.sh, and a documented entry for every command.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Prints the commands that main dispatches, without the aliases and the internal 'run'.
documented_commands() {
    sed -n '/^main() {/,/^}/p' "$CRONKID" \
        | grep -oE '^ +[a-z|" -]+\)' | tr -d ' )' | tr '|' '\n' | grep -E '^[a-z]+$' \
        | grep -vE '^(run|help)$'
}

# Prints the body of the function <2> of the script <1>.
function_body() {
    sed -n "/^${2}() {/,/^}/p" "$1"
}

test_the_scripts_are_valid_bash() {
    run bash -n "$CRONKID"
    assert_ok "bash -n cronkid"
    run bash -n "$INSTALL_SH"
    assert_ok "bash -n install.sh"
}

test_shellcheck_is_happy() {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not installed"
    run shellcheck -x "$CRONKID" "$INSTALL_SH" "${TESTS_DIR}"/*.sh "${TESTS_DIR}"/lib/*.sh \
        "${TESTS_DIR}"/lib/stubs/*
    assert_ok "shellcheck: ${out}"
}

test_every_command_is_in_the_usage_text() {
    local usage command
    usage="$("$CRONKID" --help)"
    for command in $(documented_commands); do
        assert_contains "$usage" "$command" "usage text"
    done
    assert_not_contains "$usage" "cronkid run" "usage text"
}

test_every_command_is_in_the_readme() {
    local readme command
    readme="$(cat "${REPO_DIR}/README.md")"
    for command in $(documented_commands); do
        assert_contains "$readme" "cronkid ${command}" "README.md"
    done
}

test_every_command_is_in_the_development_guide() {
    local guide command
    guide="$(cat "${REPO_DIR}/CLAUDE.md")"
    for command in $(documented_commands); do
        assert_contains "$guide" "$command" "CLAUDE.md"
    done
}

test_the_version_functions_are_the_same_in_both_scripts() {
    local name
    for name in commit_version local_version stamp_version; do
        assert_eq "$(function_body "$CRONKID" "$name")" "$(function_body "$INSTALL_SH" "$name")" \
            "${name} in cronkid and install.sh"
    done
}

test_the_defaults_of_the_script_are_the_ones_the_readme_names() {
    load_cronkid
    local readme
    readme="$(cat "${REPO_DIR}/README.md")"
    assert_eq "5" "$DEFAULT_WARN_MINUTES" "DEFAULT_WARN_MINUTES"
    assert_contains "$readme" "default 5" "README.md"
    assert_eq "1" "$FINAL_WARN_MINUTES" "FINAL_WARN_MINUTES"
    assert_contains "$readme" "again 1 minute before the screen is" "README.md"
    assert_eq "${HOME}/.cronkid" "$(used_file)" "used-time file"
    # shellcheck disable=SC2016  # the backticks are markdown, not a command
    assert_contains "$readme" '`~/.cronkid`' "README.md"
}

harness_main "$@"
