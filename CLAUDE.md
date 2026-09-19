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

Both scripts download from `CRONKID_URL`, which defaults to
`https://raw.githubusercontent.com/sboe0705/cronkid/main` and can be overridden through the environment.
The installed script therefore only changes after a push to `main` followed by `cronkid update`.

## Current state of `cronkid`

Commands (dispatched in `main`, one `cmd_*` function each):

- `setup --limit <minutes>` (non-root): writes `~/.config/systemd/user/cronkid.service` with
  `ExecStart=/usr/local/bin/cronkid run --limit <minutes>` and `WantedBy=default.target`, then runs
  `daemon-reload`, `enable` and `restart`. The limit is stored only in the unit file.
- `remove` (non-root): runs `disable --now` on the user unit, deletes the unit file and runs `daemon-reload`.
  It keeps `~/.cronkid`, so running `setup` again continues from the previous used time.
- `reset` (non-root): writes today's date with `0` to `~/.cronkid`.
- `run --limit <minutes>`: an internal command that the service executes and that is not listed in the usage text. It loops:
  if used >= limit it calls `loginctl terminate-user "$USER"`, then sleeps `TICK_SECONDS` (60) and adds 1.
  It re-reads `~/.cronkid` on every tick, so `reset` takes effect while the service runs.
- `update` (root, auto-sudo): downloads `cronkid` (with retries) into a temp file next to
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
