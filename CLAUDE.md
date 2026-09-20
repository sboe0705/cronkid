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
- `tests/`: the test suite (`tests/run-tests.sh`), see "Testing".
- `.github/workflows/tests.yml`: runs `bash -n`, `shellcheck -x` and the suite on every push and
  pull request.

Both scripts download from GitHub (`CRONKID_REPO`, `CRONKID_BRANCH`). Branch URLs on
`raw.githubusercontent.com` are cached by the CDN for up to 5 minutes (`max-age=300`). The GitHub REST API is also cached, for 60 seconds, and is limited to 60 requests per hour
without authentication. So the scripts read the latest commit ID from the uncached git smart-HTTP
endpoint `https://github.com/<repo>.git/info/refs?service=git-upload-pack` with plain `curl` (`git` is
not required) and download from the immutable `raw.githubusercontent.com/<repo>/<sha>/` URL. If that
fails, they fall back to the branch URL. In `cronkid` this lives in `origin_url`. Setting
`CRONKID_URL` in the environment overrides the origin, for example `file://` for tests. The installed script
only changes after a push to `main` followed by `cronkid update`.

## Current state of `cronkid`

Both scripts run their `main` only when they are executed, not when they are sourced
(`if [[ ${BASH_SOURCE[0]} == "$0" ]]`), which is how the tests get at the single functions. In
`install.sh` the whole flow lives in `main`, and the root check is the function `require_root`,
which a test replaces.

Commands (dispatched in `main`, one `cmd_*` function each):

`--user <name>` (setup, remove, status, reset): `for_other_user` returns 1 when no user was given, or when
the given user is the non-root caller. In that case the command runs for the current user as non-root
(`require_non_root`). Otherwise it checks that the user exists, re-runs itself through sudo (`require_root`),
refuses uid 0 and requires the home directory. It then sets `TARGET_USER`, `TARGET_UID` and `TARGET_HOME`.
remove, status and reset parse their options with `parse_user_option`, which sets `USER_OPTION`; setup
parses its own. As root, the user's files are never accessed directly. They are touched only via
`runuser -u <user>`, so the files end up owned by that user and root never follows symlinks the user
controls. The service is controlled via `systemctl --user --machine=<user>@`, and only if
`user@<uid>.service` is active. For other users the scripts always use `~/.config`, ignoring
`XDG_CONFIG_HOME`.

- `setup --limit <minutes> [--warn <minutes>] [--user <name>]`: the unit text comes from `service_unit`
  (`ExecStart=/usr/local/bin/cronkid run --limit <minutes> --warn <minutes>`, `WantedBy=default.target`).
  Limit and warning time are stored only in the unit file. `--warn` says how many minutes before the end
  the first warning is shown; `effective_warn` applies `DEFAULT_WARN_MINUTES` (5) when it is missing and
  clamps a value that is not smaller than the limit to `FINAL_WARN_MINUTES` (1). `setup_current_user` runs
  `systemctl --user daemon-reload`, `enable` and `restart`. `setup_other_user` creates the unit and the `default.target.wants` symlink via `runuser`, and
  runs `daemon-reload` and `restart` if the user is logged in. Otherwise the service starts at the next login.
- `remove [--user <name>]`: for the current user it runs `disable --now`, deletes the unit and runs
  `daemon-reload`. `remove_other_user` stops the service if the user is logged in, deletes the unit and
  symlink via `runuser`, then runs `daemon-reload`. Both keep `~/.cronkid`, so running `setup` again
  continues from the previous used time.
- `status [--user <name>]`: prints the remaining minutes as limit minus today's used time, floored at 0.
  The limit comes from `read_limit`, which parses `--limit N` from the unit's `ExecStart=` (the
  `--warn N` behind it is ignored). Without a
  unit file it reports that no service is configured. For another user it re-runs itself as that user
  through `run_as_target`, which calls `runuser` with `HOME`, `USER` and `LOGNAME` set and `XDG_CONFIG_HOME`
  unset.
- `reset [--user <name>]`: writes today's date with `0` to `~/.cronkid`. For another user it uses `run_as_target`.
- `run --limit <minutes> [--warn <minutes>]`: an internal command that the service executes and that is
  not listed in the usage text. It loops with `CHECK_SECONDS` (5) between the checks and adds a minute to
  the used time once the checks add up to `TICK_SECONDS` (60). The checks are that much shorter than a
  minute so that an undelivered notification and a new login are handled within seconds instead of at
  the next minute. A unit written before `--warn` existed still works, because the option is optional
  here. `~/.cronkid` is re-read on every check, so `reset` takes effect while the service runs. The loop
  is a small state machine:
  - `countdown_stage` maps the remaining minutes to `ok`, `warn` (from `--warn` minutes left on),
    `final` (the last `FINAL_WARN_MINUTES`, 1, which is not configurable) and `up` (limit used up).
    Entering a stage queues one notification, and so does every login and every unlock: each check
    compares the IDs from `graphical_sessions` (the user's sessions whose `Type` is `x11`, `wayland` or
    `mir`) with those of the previous check, and an ID that was not there before is a login, as is the
    first check, which the user's first login starts. Sessions that disappear change nothing, and
    without a usable `loginctl` only that first check counts as a login. A login therefore always gets a
    notification: the remaining time in `ok`, the first warning in `warn`, and `lock_warning` in `final`
    and `up`.
  - The queued message is sent by `notify` on every check until it was delivered, because at login the
    service usually runs before the desktop's notification daemon; a newer message replaces one that is
    still queued. `notify` uses `notify-send` (setting `DBUS_SESSION_BUS_ADDRESS` to `/run/user/<uid>/bus`
    if it is unset) and returns non-zero when the message was not delivered. Without `notify-send` it
    returns 0, so nothing is retried.
  - In stage `up` the screen is locked, driven by `lock_state`: `idle` (nothing locked, or a grace
    period runs) sends the lock and logs the one line of the series, `locking` repeats it on every check
    until `sessions_locked` sees `LockedHint=yes` on one of the user's sessions, because
    `loginctl lock-session` succeeds even when no locker listens and at login the locker is often not up
    yet. `locked` then only watches: a session that does not report the lock any more was unlocked by
    the user. A lock that no session confirms within a counted minute ends up in `unconfirmed`, where an
    unlock cannot be told apart from a lost lock, so the screen is locked again once per counted minute
    (`minute_done`) as a fallback, and the hint is still checked in case the locker starts reporting it.
  - A login in stage `final` or `up`, and an unlock, set `lock_state` back to `idle` and `grace_left` to
    `LOCK_GRACE_SECONDS` (`FINAL_WARN_MINUTES` * 60), which runs down with the checks and holds the lock
    back that long, so the announced minute is really given; the grace period is never cut short. In a
    session that was already running, the lock follows the limit right away, because the warning went
    out a minute earlier. `lock_sessions` reads the session IDs from
    `loginctl show-user "$USER" --property=Sessions --value` and runs `loginctl lock-session <id>` for
    each, ignoring sessions that do not support a screen lock (the manager session). The user stays
    logged in, so the used time keeps counting.
- `version`: prints `CRONKID_VERSION` through `local_version`, or a note that the script was not
  installed. The variable holds `<YYYY-MM-DD> <HH:MM> UTC <short sha>` and is empty in the repository: `stamp_version` writes it into
  the `CRONKID_VERSION=""` line of the downloaded script during install and `update`, because a running
  script cannot tell which commit it came from. The value comes from `commit_version`, which reads the
  commit date from the GitHub API (once per install, so the rate limit is not a concern) and falls back
  to the short sha alone. `stamp_version` returns non-zero when the version is not plain text or the
  script has no such line, as an older version of it has; the caller then reports no version.
  `local_version` converts the stored UTC time to the time zone of the machine with
  `date -d "<utc> UTC"` and prints `<YYYY-MM-DD> <HH:MM> <TZ> <short sha>`. The stamp stays UTC
  because the machine that installs the script is not necessarily the one that runs it. A version
  without a time, and one that `date` cannot read, is printed unchanged.
  All three are duplicated in `install.sh`, which resolves the sha anyway and shows the installed
  version the same way; `cmd_update` takes the sha from the last path segment of `origin_url`. With a
  branch-URL fallback or `CRONKID_URL` there is no sha and no version.
- `update` (root, auto-sudo): downloads `cronkid` from `origin_url`, with retries, into a temp file next to
  `/usr/local/bin/cronkid`. It checks that the file starts with `#!`, stamps the version, and passes
  `bash -n`, skips the update if the file is identical, then does `chmod 0755` and an atomic `mv`. Any failure keeps the
  current version. The temp file stays in the same directory so that the rename is atomic, the
  running script keeps its old inode, and the SELinux label is `bin_t`.
- `uninstall` (root, auto-sudo): for every passwd entry with a home directory, stops and removes the
  user unit, including its `default.target.wants` symlink, and removes `~/.cronkid`. Then deletes
  `/usr/local/bin/cronkid`.

State: `~/.cronkid` holds `<YYYY-MM-DD> <minutes>` and is written atomically (tmp file + `mv`).
`read_used` returns 0 when the stored date is not today, which gives the daily reset. There is no
separate job for it, and it works across reboots and while the service runs past midnight. A file in the
old plain-integer format is read as 0.

## Workflow

- After every change, commit and push directly to `main` (`git push origin main`), unless the user
  asks otherwise. There are no feature branches or PRs.
- Keep `README.md` and this file in sync with the current state of the scripts in the same commit.
  `tests/test_docs.sh` checks the easy half of that: every command of `main` appears in the usage
  text, in `README.md` and here.
- Every change comes with its tests. `tests/run-tests.sh` and `shellcheck -x cronkid install.sh
  tests/*.sh tests/lib/*.sh tests/lib/stubs/*` have to pass before pushing; the GitHub Action runs
  both again.

## Conventions

- Bash with `set -euo pipefail`. Keep the script self-contained, with no extra runtime files.
- Error messages go through `die`, prefixed with `cronkid:`.
- `EXIT` traps run after a function has returned, so a trap must not refer to a function's `local`
  variables under `set -u`. Expand the value when setting the trap, e.g. `trap "rm -f -- $(printf '%q' "$tmp")" EXIT`.
- `/usr/local/bin` was chosen because it is on `PATH` for all users. Fedora's sudo `secure_path` does
  not include it, so root commands re-exec themselves with `sudo "$(readlink -f "$0")"`.

## Testing

`tests/run-tests.sh` runs the whole suite (about a minute), `tests/run-tests.sh tests/test_run_loop.sh`
a single file and a second argument only the tests whose name contains it. It has to run as a
regular user, because cronkid refuses to control root. Every test runs in a subshell of its own with
a temporary `HOME`, a temporary `STUB_STATE` and `tests/lib/stubs` first in `PATH`, so a test never
touches the machine and never needs a network: `loginctl`, `notify-send` and `systemctl` are stubs
that record their calls and take the sessions, the session types, the locked hints and the failures
they are to simulate from files. `tests/lib/harness.sh` has a helper for each of them
(`set_sessions`, `set_session_type`, `enable_locker`, `unlock_sessions`, `break_loginctl`,
`break_notify_send`, `stub_curl_output`, ...) besides the assertions.

A test file sources the harness, defines `test_*` functions and ends with `harness_main "$@"`.
`run_cronkid` runs the script as a command; `load_cronkid` and `load_install_sh` source it to call
single functions, and `run` calls a command or a function in a subshell with `set -e`, as the
scripts themselves run, and keeps `status`, `out` and `err`.

- The counting loop is driven by `tests/lib/run_loop.sh`, which sources the script and replaces only
  `TICK_SECONDS`, `CHECK_SECONDS` and `LOCK_GRACE_SECONDS` (`TEST_TICK_SECONDS`, `TEST_CHECK_SECONDS`
  and `TEST_GRACE_SECONDS`, one second by default), so that a test reaches the warnings and the lock
  in seconds. `start_loop` starts it in the background, `wait_for` waits for a notification, a lock
  or a counted minute, and the test's subshell stops it again. A test that shows that something does
  *not* happen any more waits `QUIET_SECONDS` and compares the counters.
- `update` and `install.sh` run against an origin directory served as a `file://` URL
  (`CRONKID_URL`), with `INSTALL_PATH` pointing into the test's temporary directory and
  `require_root` redefined to do nothing.

Test files: `test_state.sh` (used-time file, daily reset), `test_options.sh` (option parsing and the
pure functions around the countdown and the unit), `test_commands.sh` (setup, remove, status, reset,
dispatching), `test_sessions.sh` (notifications, graphical sessions, lock and locked hint),
`test_run_loop.sh` (counting, warnings, lock, login, unlock, reset, retried notifications),
`test_version.sh`, `test_update.sh`, `test_install.sh` and `test_docs.sh` (syntax, shellcheck, and
the documentation of every command).

Not covered, because it needs root, a real systemd or the network: everything behind
`--user <name>` (`runuser`, `systemctl --user --machine=`), `uninstall`, and the download from
GitHub. Test those by hand on a real machine, e.g. with a second user account.
