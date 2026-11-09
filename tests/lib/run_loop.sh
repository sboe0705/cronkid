#!/usr/bin/env bash
#
# Runs cronkid's counting loop with the paths of the running test and the short timings of the test
# suite. The script is sourced, so the loop is the real one; only the constants that would make a
# test wait for minutes are replaced. The arguments are those of 'cronkid run', i.e. --user <name>.
#
set -euo pipefail

# shellcheck source=/dev/null
source "${CRONKID:?CRONKID is not set}"
# shellcheck source-path=SCRIPTDIR source=harness.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"
set -euo pipefail
cronkid_paths

# shellcheck disable=SC2034  # the constants are read by the sourced loop
TICK_SECONDS="${TEST_TICK_SECONDS:-1}"
# shellcheck disable=SC2034
CHECK_SECONDS="${TEST_CHECK_SECONDS:-1}"
# shellcheck disable=SC2034
LOCK_GRACE_SECONDS="${TEST_GRACE_SECONDS:-3}"
# shellcheck disable=SC2034
SHUTDOWN_WARN_SECONDS="${TEST_SHUTDOWN_WARN_SECONDS:-2}"
# shellcheck disable=SC2034
SHUTDOWN_DELIVERY_SECONDS="${TEST_SHUTDOWN_DELIVERY_SECONDS:-3}"

cmd_run "$@"
