#!/usr/bin/env bash
#
# Runs cronkid's counting loop with the short timings of the test suite. The script is sourced, so
# the loop is the real one; only the constants that would make a test wait for minutes are replaced.
# The arguments are those of 'cronkid run', e.g. --limit 5 --warn 2.
#
set -euo pipefail

# shellcheck source=/dev/null
source "${CRONKID:?CRONKID is not set}"

# shellcheck disable=SC2034  # the constants are read by the sourced loop
TICK_SECONDS="${TEST_TICK_SECONDS:-1}"
# shellcheck disable=SC2034
CHECK_SECONDS="${TEST_CHECK_SECONDS:-1}"
# shellcheck disable=SC2034
LOCK_GRACE_SECONDS="${TEST_GRACE_SECONDS:-3}"

cmd_run "$@"
