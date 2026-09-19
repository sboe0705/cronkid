#!/usr/bin/env bash
#
# Installs cronkid. Usage:
#   curl -fsSL https://raw.githubusercontent.com/sboe0705/cronkid/main/install.sh | sudo bash
#
set -euo pipefail

CRONKID_REPO="sboe0705/cronkid"
CRONKID_BRANCH="main"
INSTALL_PATH="/usr/local/bin/cronkid"

if [[ $EUID -ne 0 ]]; then
    echo "cronkid install: must be run as root, e.g." \
        "'curl -fsSL https://raw.githubusercontent.com/${CRONKID_REPO}/${CRONKID_BRANCH}/install.sh | sudo bash'" >&2
    exit 1
fi

# Branch URLs on raw.githubusercontent.com are cached for up to 5 minutes, so download from the
# latest commit instead (falls back to the branch URL if the GitHub API is unreachable).
# CRONKID_URL overrides the origin, e.g. for testing.
if [[ -z ${CRONKID_URL:-} ]]; then
    sha="$(curl -fsSL --retry 3 --connect-timeout 10 -H "Accept: application/vnd.github.sha" \
        "https://api.github.com/repos/${CRONKID_REPO}/commits/${CRONKID_BRANCH}" 2>/dev/null || true)"
    if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
        CRONKID_URL="https://raw.githubusercontent.com/${CRONKID_REPO}/${sha}"
    else
        CRONKID_URL="https://raw.githubusercontent.com/${CRONKID_REPO}/${CRONKID_BRANCH}"
    fi
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 10 "${CRONKID_URL}/cronkid" -o "$tmp"
bash -n "$tmp"
install -m 0755 "$tmp" "$INSTALL_PATH"

echo "cronkid installed to ${INSTALL_PATH} from ${CRONKID_URL}"
echo "Next step: log in as the user to be controlled and run 'cronkid setup --limit <minutes>'"
