#!/usr/bin/env bash
#
# 'cronkid update': it replaces the installed script only with a script that is complete and valid.
# The origin is a directory served through a file:// URL (CRONKID_URL).
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Prepares an installed script and an origin. load_cronkid makes cmd_update work without root.
prepare_update() {
    load_cronkid
    mkdir -p "${TEST_TMP}/origin"
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
    assert_contains "$(systemctl_calls)" "systemctl try-restart cronkid@*.service" "systemctl calls"
}

test_update_of_an_unchanged_script_does_nothing() {
    prepare_update
    run cmd_update
    assert_ok "update"
    assert_contains "$out" "is already up to date" "output"
    assert_eq "" "$(systemctl_calls)" "systemctl calls"
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

test_update_stamps_the_version_of_the_commit_it_downloads() {
    prepare_update
    # The commit comes from the last segment of the origin URL, the date from the GitHub API.
    local sha="b12c9b6a1234567890123456789012345678abcd"
    mkdir -p "${TEST_TMP}/${sha}"
    cp "$CRONKID" "${TEST_TMP}/${sha}/cronkid"
    export CRONKID_URL="file://${TEST_TMP}/${sha}"
    # file:// URLs are fetched by the real curl; only the API call goes to the stub.
    mkdir -p "${TEST_TMP}/curl-stub"
    cat >"${TEST_TMP}/curl-stub/curl" <<STUB
#!/usr/bin/env bash
if [[ \$* == *api.github.com* ]]; then
    echo '{"commit": {"author": {"date": "2026-09-20T03:03:17Z"}}}'
else
    exec $(command -v curl) "\$@"
fi
STUB
    chmod +x "${TEST_TMP}/curl-stub/curl"
    PATH="${TEST_TMP}/curl-stub:${PATH}" run cmd_update
    assert_ok "update"
    assert_contains "$out" "(version 2026-09-20 03:03 UTC b12c9b6)" "output"
    assert_contains "$(grep '^CRONKID_VERSION=' "$INSTALL_PATH")" '"2026-09-20 03:03 UTC b12c9b6"' "version line"
}

test_update_leaves_no_temporary_file_behind() {
    prepare_update
    echo "# a newer version" >>"${TEST_TMP}/origin/cronkid"
    run cmd_update
    assert_ok "update"
    assert_eq "cronkid" "$(ls "${TEST_TMP}/bin")" "files next to the installed script"
}

harness_main "$@"
