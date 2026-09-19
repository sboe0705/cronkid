#!/usr/bin/env bash
#
# Installs cronkid. Usage:
#   curl -fsSL https://raw.githubusercontent.com/sboe0705/cronkid/main/install.sh | sudo bash
#
set -euo pipefail

CRONKID_URL="${CRONKID_URL:-https://raw.githubusercontent.com/sboe0705/cronkid/main}"
INSTALL_PATH="/usr/local/bin/cronkid"

if [[ $EUID -ne 0 ]]; then
    echo "cronkid install: must be run as root, e.g. 'curl -fsSL ${CRONKID_URL}/install.sh | sudo bash'" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "${CRONKID_URL}/cronkid" -o "$tmp"
bash -n "$tmp"
install -m 0755 "$tmp" "$INSTALL_PATH"

echo "cronkid installed to ${INSTALL_PATH}"
echo "Next step: log in as the user to be controlled and run 'cronkid setup --limit <minutes>'"
