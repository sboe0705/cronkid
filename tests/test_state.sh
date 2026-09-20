#!/usr/bin/env bash
#
# The used-time file ~/.cronkid: its format, the daily reset and the atomic write.
#
# shellcheck source-path=SCRIPTDIR source=lib/harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/harness.sh"

test_used_file_is_written_with_todays_date() {
    load_cronkid
    write_used 42
    assert_eq "${HOME}/.cronkid" "$(used_file)" "used file path"
    assert_eq "$(today) 42" "$(used_line)" "used file"
    assert_eq "42" "$(read_used)" "read_used"
}

test_write_used_leaves_no_temporary_file() {
    load_cronkid
    write_used 1
    assert_no_file "${HOME}/.cronkid.tmp" "temporary used file"
}

test_minutes_of_another_day_count_as_zero() {
    load_cronkid
    seed_used "$(yesterday)" 500
    assert_eq "0" "$(read_used)" "used time of yesterday"
}

test_missing_file_counts_as_zero() {
    load_cronkid
    assert_eq "0" "$(read_used)" "used time without a file"
}

test_file_in_the_old_plain_integer_format_counts_as_zero() {
    load_cronkid
    echo "17" >"$(used_file_path)"
    assert_eq "0" "$(read_used)" "used time in the old format"
}

test_unreadable_content_counts_as_zero() {
    load_cronkid
    printf '%s abc\n' "$(today)" >"$(used_file_path)"
    assert_eq "0" "$(read_used)" "used time that is not a number"
    : >"$(used_file_path)"
    assert_eq "0" "$(read_used)" "used time in an empty file"
}

harness_main "$@"
