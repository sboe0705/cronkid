#!/usr/bin/env bash
#
# The version that the installer and 'cronkid update' stamp into the script, and how it is shown.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

# A copy of the script that a test may stamp a version into.
script_copy() {
    cp "$CRONKID" "${TEST_TMP}/cronkid"
    chmod +x "${TEST_TMP}/cronkid"
    echo "${TEST_TMP}/cronkid"
}

test_commit_version_takes_the_commit_date_from_the_github_api() {
    load_cronkid
    stub_curl_output '{"commit": {"author": {"date": "2026-09-20T03:03:17Z"}}}'
    assert_eq "2026-09-20 03:03 UTC b12c9b6" "$(commit_version b12c9b6a1234567890123456789012345678abcd)" "version"
}

test_commit_version_falls_back_to_the_commit_id() {
    load_cronkid
    stub_curl_failure
    assert_eq "b12c9b6" "$(commit_version b12c9b6a1234567890123456789012345678abcd)" "version"
}

test_stamp_version_fills_the_version_line() {
    load_cronkid
    local copy
    copy="$(script_copy)"
    stamp_version "$copy" "2026-09-20 03:03 UTC b12c9b6" || fail "stamp_version failed"
    assert_contains "$(grep '^CRONKID_VERSION=' "$copy")" 'CRONKID_VERSION="2026-09-20 03:03 UTC b12c9b6"' "version line"
    bash -n "$copy" || fail "the stamped script is not valid bash"
}

test_stamp_version_refuses_a_script_that_was_stamped_before() {
    load_cronkid
    local copy
    copy="$(script_copy)"
    stamp_version "$copy" "2026-09-20 03:03 UTC b12c9b6" || fail "stamp_version failed"
    run stamp_version "$copy" "2026-09-21 03:03 UTC aaaaaaa"
    assert_failed "" "second stamp_version"
}

test_stamp_version_refuses_a_version_that_is_not_plain_text() {
    load_cronkid
    local copy
    copy="$(script_copy)"
    run stamp_version "$copy" 'x"; rm -rf /; #'
    assert_failed "" "stamp_version with a command in the version"
    assert_contains "$(grep '^CRONKID_VERSION=' "$copy")" 'CRONKID_VERSION=""' "version line"
}

test_version_is_shown_in_the_local_time_zone() {
    local copy
    copy="$(script_copy)"
    ( load_cronkid; stamp_version "$copy" "2026-09-20 03:03 UTC b12c9b6" ) || fail "stamp_version failed"
    run env TZ=UTC "$copy" version
    assert_ok "version"
    assert_eq "cronkid 2026-09-20 03:03 UTC b12c9b6" "$out" "version in UTC"
    # A fixed offset instead of a named zone, so that the test does not need a time zone database.
    run env TZ=XYZ-2 "$copy" version
    assert_ok "version"
    assert_eq "cronkid 2026-09-20 05:03 XYZ b12c9b6" "$out" "version two hours east of UTC"
}

test_a_version_without_a_time_is_shown_unchanged() {
    load_cronkid
    assert_eq "b12c9b6" "$(local_version "b12c9b6")" "version without a time"
    assert_eq "9999-99-99 99:99 UTC b12c9b6" "$(local_version "9999-99-99 99:99 UTC b12c9b6")" \
        "version with an impossible date"
}

harness_main "$@"
