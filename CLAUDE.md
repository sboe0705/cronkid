# CLAUDE.md

Guidance for working on this repository.

## Project

cronkid is a shell-based (bash) parental control that limits the usage time of Linux users.
The used time is stored on disk, so it survives reboots. See `README.md` for user-facing documentation.

## Files

- `cronkid`: the main script. It is installed to `/usr/local/bin/cronkid`.
- `install.sh`: the installer, meant for `curl -fsSL .../install.sh | sudo bash`. It downloads
  `cronkid` from `CRONKID_URL` and installs it.
- `README.md`: user documentation. `LICENSE`: MIT.

Both scripts download from GitHub (`CRONKID_REPO`, `CRONKID_BRANCH`). Branch URLs on
`raw.githubusercontent.com` are cached by the CDN for up to 5 minutes (`max-age=300`). The GitHub REST API is also cached, for 60 seconds, and is limited to 60 requests per hour
without authentication. So the scripts read the latest commit ID from the uncached git smart-HTTP
endpoint `https://github.com/<repo>.git/info/refs?service=git-upload-pack` with plain `curl` (`git` is
not required) and download from the immutable `raw.githubusercontent.com/<repo>/<sha>/` URL. If that
fails, they fall back to the branch URL. In `cronkid` this lives in `origin_url`. Setting
`CRONKID_URL` in the environment overrides the origin, for example `file://` for tests. The installed script
only changes after a push to `main` followed by `cronkid update`.

## Current state of `cronkid`

Commands (dispatched in `main`, one `cmd_*` function each):

- `setup --limit <minutes> [--user <name>]`: the unit text comes from `service_unit`
  (`ExecStart=/usr/local/bin/cronkid run --limit <minutes>`, `WantedBy=default.target`). The limit is
  stored only in the unit file.
  - Without `--user`, or with `--user` set to yourself: `setup_current_user` (non-root) writes the unit and
    runs `systemctl --user daemon-reload`, `enable` and `restart`.
  - With `--user` set to another user: the command re-runs itself through sudo and calls
    `setup_other_user`. It refuses uid 0 and needs an existing home directory. It creates the unit and the
    `default.target.wants` symlink as the target user via `runuser`, so the files are owned by that user and
    root never follows paths the user controls. If `user@<uid>.service` is active, it runs `daemon-reload`
    and `restart` through `systemctl --user --machine=<user>@`. Otherwise the service starts at the next
    login. It always writes to `~/.config`; `XDG_CONFIG_HOME` is not considered.
- `remove` (non-root): runs `disable --now` on the user unit, deletes the unit file and runs `daemon-reload`.
  It keeps `~/.cronkid`, so running `setup` again continues from the previous used time.
- `status` (non-root): prints the remaining minutes as limit minus today's used time, floored at 0.
  The limit comes from `read_limit`, which parses `--limit N` from the unit's `ExecStart=`. Without a
  unit file it reports that no service is configured.
- `reset` (non-root): writes today's date with `0` to `~/.cronkid`.
- `run --limit <minutes>`: an internal command that the service executes and that is not listed in the usage text. It loops:
  if used >= limit it calls `loginctl terminate-user "$USER"`, then sleeps `TICK_SECONDS` (60) and adds 1.
  It re-reads `~/.cronkid` on every tick, so `reset` takes effect while the service runs.
- `update` (root, auto-sudo): downloads `cronkid` from `origin_url`, with retries, into a temp file next to
  `/usr/local/bin/cronkid`. It checks that the file starts with `#!` and passes `bash -n`, skips the
  update if the file is identical, then does `chmod 0755` and an atomic `mv`. Any failure keeps the
  current version. The temp file stays in the same directory so that the rename is atomic, the
  running script keeps its old inode, and the SELinux label is `bin_t`.
- `uninstall` (root, auto-sudo): for every passwd entry with a home directory, stops and removes the
  user unit, including its `default.target.wants` symlink, and removes `~/.cronkid`. Then deletes
  `/usr/local/bin/cronkid`.

State: `~/.cronkid` holds `<YYYY-MM-DD> <minutes>` and is written atomically (tmp file + `mv`).
`read_used` returns 0 when the stored date is not today, which gives the daily reset. There is no
separate job for it, and it works across reboots and while the service runs past midnight. A file in the
old plain-integer format is read as 0. There is no warning before logout.

## Workflow

- After every change, commit and push directly to `main` (`git push origin main`), unless the user
  asks otherwise. There are no feature branches or PRs.
- Keep `README.md` and this file in sync with the current state of the scripts in the same commit.

## Conventions

- Bash with `set -euo pipefail`. Keep the script self-contained, with no extra runtime files.
- Error messages go through `die`, prefixed with `cronkid:`.
- `EXIT` traps run after a function has returned, so a trap must not refer to a function's `local`
  variables under `set -u`. Expand the value when setting the trap, e.g. `trap "rm -f -- $(printf '%q' "$tmp")" EXIT`.
- `/usr/local/bin` was chosen because it is on `PATH` for all users. Fedora's sudo `secure_path` does
  not include it, so root commands re-exec themselves with `sudo "$(readlink -f "$0")"`.

## Testing

There is no test suite yet. Check syntax with `bash -n cronkid install.sh`. To test the counting loop
without being logged out, copy the script with `TICK_SECONDS=1`, put a `loginctl` stub first in
`PATH`, and point `HOME` at a temporary directory.
