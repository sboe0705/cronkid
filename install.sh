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

# Prints the version of the commit <1>: its date and time in UTC, without seconds, and the short
# commit ID. The date comes from the GitHub API; if that fails, only the ID is used.
commit_version() {
    local sha="$1" date
    date="$(curl -fsSL --retry 2 --connect-timeout 10 \
        "https://api.github.com/repos/${CRONKID_REPO}/commits/${sha}" 2>/dev/null \
        | grep -o '"date": *"[0-9-]\{10\}T[0-9:]\{8\}Z"' | head -n 1 \
        | grep -o '[0-9-]\{10\}T[0-9:]\{5\}' | tr 'T' ' ' || true)"
    if [[ -n $date ]]; then
        echo "${date} UTC ${sha:0:7}"
    else
        echo "${sha:0:7}"
    fi
}

# Writes the version <2> into the CRONKID_VERSION line of the script <1>, which is where
# 'cronkid version' reads it from. Returns non-zero without touching the file if the version is not
# plain text or if the script has no such line, as an older version of it has.
stamp_version() {
    local file="$1" version="$2"
    [[ $version =~ ^[0-9A-Za-z\ :-]+$ ]] || return 1
    grep -q '^CRONKID_VERSION=""$' "$file" || return 1
    sed -i "s|^CRONKID_VERSION=\"\"\$|CRONKID_VERSION=\"${version}\"|" "$file"
}

# Branch URLs on raw.githubusercontent.com are cached for up to 5 minutes, so download from the
# latest commit instead, read from the uncached git smart-HTTP ref advertisement (falls back to
# the branch URL if that fails).
# CRONKID_URL overrides the origin, e.g. for testing.
sha=""
if [[ -z ${CRONKID_URL:-} ]]; then
    sha="$(curl -fsSL --retry 3 --connect-timeout 10 \
        "https://github.com/${CRONKID_REPO}.git/info/refs?service=git-upload-pack" 2>/dev/null \
        | grep -ao "[0-9a-f]\{40\} refs/heads/${CRONKID_BRANCH}\$" | head -n 1 | cut -c 1-40 || true)"
    if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
        CRONKID_URL="https://raw.githubusercontent.com/${CRONKID_REPO}/${sha}"
    else
        CRONKID_URL="https://raw.githubusercontent.com/${CRONKID_REPO}/${CRONKID_BRANCH}"
    fi
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 10 "${CRONKID_URL}/cronkid" -o "$tmp"
# The version is written into the script while it is installed, because a running script cannot know
# which commit it came from.
version=""
suffix=""
if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
    version="$(commit_version "$sha")"
    stamp_version "$tmp" "$version" || version=""
fi
if [[ -n $version ]]; then
    suffix=" (version ${version})"
fi
bash -n "$tmp"
install -m 0755 "$tmp" "$INSTALL_PATH"

echo "cronkid installed to ${INSTALL_PATH} from ${CRONKID_URL}${suffix}"
echo "Next step: log in as the user to be controlled and run 'cronkid setup --limit <minutes>'"
