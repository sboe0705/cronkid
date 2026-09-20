#!/usr/bin/env bash
#
# Runs the cronkid test suite. Without arguments it runs every tests/test_*.sh; with arguments it
# runs the given test files, and a single file may be followed by a filter for the test names:
#
#   tests/run-tests.sh
#   tests/run-tests.sh tests/test_run_loop.sh
#   tests/run-tests.sh tests/test_run_loop.sh unlocking
#
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

if [[ $EUID -eq 0 ]]; then
    echo "run-tests.sh: run the tests as a regular user; cronkid refuses to control the root user" >&2
    exit 1
fi

files=()
filter=""
if [[ $# -gt 0 ]]; then
    files=("$1")
    shift
    filter="${1:-}"
else
    mapfile -t files < <(find "$TESTS_DIR" -maxdepth 1 -name 'test_*.sh' | sort)
fi

failed=0
for file in "${files[@]}"; do
    echo "${file##*/}"
    bash "$file" "$filter" || failed=$((failed + 1))
done

if ((failed > 0)); then
    echo "${failed} test file(s) failed" >&2
    exit 1
fi
echo "all tests passed"
