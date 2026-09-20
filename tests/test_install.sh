#!/usr/bin/env bash
#
# install.sh: it installs the script from the origin and stamps the version into it. The origin is
# a directory served through a file:// URL (CRONKID_URL).
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# Prepares an origin and makes install.sh's main work without root.
prepare_install() {
    load_install_sh
    # shellcheck disable=SC2317  # the override is called by the function under test
    require_root() { :; }
    mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/origin"
    INSTALL_PATH="${TEST_TMP}/bin/cronkid"
    cp "$CRONKID" "${TEST_TMP}/origin/cronkid"
    export CRONKID_URL="file://${TEST_TMP}/origin"
}

test_install_as_a_regular_user_is_refused() {
    run bash "$INSTALL_SH"
    assert_failed "must be run as root" "install.sh as a regular user"
}

test_install_piped_into_bash_runs() {
    # The installer is meant to be piped into bash, where BASH_SOURCE is unset. That it gets as far
    # as the root check shows that it runs at all.
    run bash -c "cat '${INSTALL_SH}' | bash"
    assert_failed "must be run as root" "install.sh piped into bash"
}

test_install_puts_the_script_in_place() {
    prepare_install
    run main
    assert_ok "install.sh"
    assert_file_exists "$INSTALL_PATH" "installed script"
    assert_eq "755" "$(stat -c %a "$INSTALL_PATH")" "mode of the installed script"
    cmp -s "$CRONKID" "$INSTALL_PATH" || fail "the installed script differs from the origin"
    assert_contains "$out" "cronkid installed to ${INSTALL_PATH}" "output"
    assert_contains "$out" "cronkid setup --limit <minutes>" "output"
}

test_install_without_a_commit_installs_without_a_version() {
    prepare_install
    run main
    assert_ok "install.sh"
    assert_not_contains "$out" "version" "output"
    run "$INSTALL_PATH" version
    assert_contains "$out" "no version" "version of the installed script"
}

test_install_refuses_a_download_that_is_not_valid_bash() {
    prepare_install
    printf '#!/usr/bin/env bash\nif then fi\n' >"${TEST_TMP}/origin/cronkid"
    run main
    assert_failed "" "install.sh with an invalid script"
    assert_no_file "$INSTALL_PATH" "installed script"
}

test_install_stamps_the_version_of_the_commit_it_downloads() {
    prepare_install
    # The installer only stamps a version when it resolved a commit; the payload of the API call
    # and the ref advertisement come from the curl stub.
    local sha="b12c9b6a1234567890123456789012345678abcd"
    stub_curl_output '{"commit": {"author": {"date": "2026-09-20T03:03:17Z"}}}'
    version="$(commit_version "$sha")"
    assert_eq "2026-09-20 03:03 UTC b12c9b6" "$version" "version"
    local copy="${TEST_TMP}/stamped"
    cp "$CRONKID" "$copy"
    stamp_version "$copy" "$version" || fail "stamp_version failed"
    assert_contains "$(grep '^CRONKID_VERSION=' "$copy")" "$version" "version line"
    run env TZ=UTC bash "$copy" version
    assert_eq "cronkid ${version}" "$out" "version of the stamped script"
}

harness_main "$@"
