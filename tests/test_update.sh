#!/usr/bin/env bash
#
# 'cronkid update': it replaces the installed script only with a script that is complete and valid.
# The origin is a directory served through a file:// URL (CRONKID_URL).
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Prepares an installed script and an origin, and makes cmd_update work without root.
prepare_update() {
    load_cronkid
    # shellcheck disable=SC2317  # the override is called by the function under test
    require_root() { :; }
    mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/origin"
    INSTALL_PATH="${TEST_TMP}/bin/cronkid"
    cp "$CRONKID" "$INSTALL_PATH"
    chmod 0755 "$INSTALL_PATH"
    cp "$CRONKID" "${TEST_TMP}/origin/cronkid"
    export CRONKID_URL="file://${TEST_TMP}/origin"
}

test_origin_url_can_be_overridden() {
    load_cronkid
    CRONKID_URL="file:///somewhere"
    assert_eq "file:///somewhere" "$(origin_url)" "origin"
}

test_update_replaces_the_installed_script() {
    prepare_update
    echo "# a newer version" >>"${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_ok "update"
    assert_contains "$out" "updated ${INSTALL_PATH} from file://${TEST_TMP}/origin" "output"
    cmp -s "${TEST_TMP}/origin/cronkid" "$INSTALL_PATH" || fail "the installed script was not replaced"
    assert_eq "755" "$(stat -c %a "$INSTALL_PATH")" "mode of the installed script"
}

test_update_of_an_unchanged_script_does_nothing() {
    prepare_update
    run cmd_update
    assert_ok "update"
    assert_contains "$out" "is already up to date" "output"
}

test_update_refuses_a_download_that_is_not_a_script() {
    prepare_update
    echo "<html>404</html>" >"${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_failed "downloaded file is not a script, keeping current version" "update"
    cmp -s "$CRONKID" "$INSTALL_PATH" || fail "the installed script was replaced"
}

test_update_refuses_a_download_that_is_not_valid_bash() {
    prepare_update
    printf '#!/usr/bin/env bash\nif then fi\n' >"${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_failed "downloaded script is not valid bash, keeping current version" "update"
    cmp -s "$CRONKID" "$INSTALL_PATH" || fail "the installed script was replaced"
}

test_update_keeps_the_current_version_when_the_download_fails() {
    prepare_update
    rm -f "${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_failed "failed, keeping current version" "update"
    cmp -s "$CRONKID" "$INSTALL_PATH" || fail "the installed script was replaced"
}

test_update_leaves_no_temporary_file_behind() {
    prepare_update
    echo "# a newer version" >>"${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_ok "update"
    assert_eq "cronkid" "$(ls "${TEST_TMP}/bin")" "files next to the installed script"
}

harness_main "$@"
