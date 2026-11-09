# CLAUDE.md

Guidance for working on this repository.

## Project

cronkid is a shell-based (bash) parental control that limits the usage time of Linux users with a
daily limit and/or an allowed period of the day, locks the screen at the end and shuts the computer
down instead of the 5th automatic lock of a day. The used time is stored on disk, so it survives reboots. See `README.md` for user-facing documentation.

## Files

- `cronkid`: the main script. It is installed to `/usr/local/bin/cronkid`.
- `install.sh`: the installer, meant for `curl -fsSL .../install.sh | sudo bash`. It downloads
  `cronkid` from `CRONKID_URL` and installs it.
- `README.md`: user documentation. `LICENSE`: MIT. `.github/FUNDING.yml`: the sponsor button (Buy Me a Coffee).

Both scripts download from GitHub (`CRONKID_REPO`, `CRONKID_BRANCH`). Branch URLs on
`raw.githubusercontent.com` are cached by the CDN for up to 5 minutes (`max-age=300`). The GitHub REST API is also cached, for 60 seconds, and is limited to 60 requests per hour
without authentication. So the scripts read the latest commit ID from the uncached git smart-HTTP
endpoint `https://github.com/<repo>.git/info/refs?service=git-upload-pack` with plain `curl` (`git` is
not required) and download from the immutable `raw.githubusercontent.com/<repo>/<sha>/` URL. If that
fails, they fall back to the branch URL. In `cronkid` this lives in `origin_url`. Setting
`CRONKID_URL` in the environment overrides the origin, for example `file://` for tests. The installed script
only changes after a push to `main` followed by `cronkid update`.

## Current state of `cronkid`

cronkid runs as a root system service, one instance `cronkid@<user>.service` of the template
`/etc/systemd/system/cronkid@.service` (`service_unit`: `ExecStart=/usr/local/bin/cronkid run --user %i`,
`Restart=always`, `WantedBy=multi-user.target`) per controlled user, so the child cannot stop it or change
its files. The configuration is `/etc/cronkid/<user>.conf` (`CONFIG_DIR`) with the lines `LIMIT=`, `FROM=`,
`UNTIL=` and `WARN=`; `read_config` parses it into `CFG_*` (never sourced, invalid values ignored, a
period only as a whole). Config and state are root-owned and 0644, so `status` works without root.
`check_user` validates a user name (no paths, must exist, not uid 0) and sets `TARGET_USER`, `TARGET_UID`
and `TARGET_HOME`. Commands that need root re-run themselves through sudo (`require_root`) after the
options were validated, so errors appear without a password prompt.

Commands (dispatched in `main`, one `cmd_*` function each):

- `setup --user <name> [--limit <minutes>] [--from HH:MM --until HH:MM] [--warn <minutes>]` (root): at
  least one of limit or period; `--from` and `--until` together and `FROM < UNTIL` (no period across
  midnight). Writes the config atomically and the template unit, removes a legacy user service with
  `remove_legacy_service`, then `daemon-reload`, `enable` and `restart`. `effective_warn` applies
  `DEFAULT_WARN_MINUTES` (5) when `WARN` is empty and clamps a value that is not smaller than the limit
  to `FINAL_WARN_MINUTES` (1).
- `remove --user <name>` (root): `disable --now`, deletes the config and a legacy user service, keeps the state.
- `status [--user <name>]`: remaining minutes (`remaining_minutes`), used/limit, period, and the
  automatic locks or the lockout. Without `--user` the current user.
- `reset --user <name>` (root): writes used time 0 and locks 0.
- `run --user <name>`: the internal loop the service executes, not listed in the usage text. Called as
  `run --limit ...` by a legacy user unit, it prints a hint and exits 0, so systemd does not restart it.

Legacy: versions before the system service ran a user service `~/.config/systemd/user/cronkid.service`
and kept the used time in `~/.cronkid`. `remove_legacy_service` stops the unit through
`systemctl --user --machine=<user>@` (only if `user@<uid>.service` is active) and deletes the unit and
its `default.target.wants` symlink via `runuser -u <user>`, so root never writes through paths the user
controls.

The loop (`cmd_run`) checks every `CHECK_SECONDS` (5) and is a small state machine:

- `user_sessions` lists the user's sessions whose `Class` starts with `user` and whose `State` is not
  `closing` (so neither the manager session nor sessions lingering after a logout). An ID not seen in
  the previous check is a login; the sessions existing at the first check count as logins too. Used
  time is added only while a session exists, one minute per `TICK_SECONDS` (60) of checks.
- `remaining_minutes` takes the smaller of the rest of the limit and the minutes until `UNTIL` (0
  outside the period) and sets `REASON` (`limit`/`period`). `countdown_stage` maps it to `ok`, `warn`
  (from `WARN` minutes left), `final` (the last `FINAL_WARN_MINUTES`, not configurable) and `up`.
  Entering a stage queues one notification, and so does every login and every unlock. A login or
  unlock in `final` or `up` gets `final_warning`, `lock_state=idle` and
  `grace_left = LOCK_GRACE_SECONDS` (60), which holds the lock back; a session that was already
  running is locked right at the end, because it was warned a minute earlier. An unlock is a session
  that no longer reports `LockedHint=yes` while `lock_state` is `locked` (`sessions_locked`).
- In stage `up` with a session, once the grace time is over: if `LOCKS >= MAX_LOCKS` (5), or
  `lock_state` is `idle` and the next lock would be the 5th, the shutdown starts: locks are written as 5
  first (so a reboot does not end the lockout), the 10 s warning is queued, and
  `SHUTDOWN_WARN_SECONDS` (10) after it was delivered (at most `SHUTDOWN_DELIVERY_SECONDS`, 30, waiting
  for that) the loop runs `systemctl poweroff -i`, retried after a minute. `notify_others` tells every
  other logged-in user. During the shutdown the loop checks every second. Time coming back (`reset`)
  cancels it.
- Otherwise the lock is driven by `lock_state`: `idle` counts the lock (`write_state` with `LOCKS + 1`),
  logs the one line of the series, calls `lock_sessions` (`loginctl lock-session` for every ID of
  `user_sessions`) and goes to `locking`. `locking` repeats the lock on every check until
  `sessions_locked` confirms it, because `loginctl lock-session` succeeds even when no locker listens;
  a lock that no session confirms within a counted minute (`minute_done`) ends up in `unconfirmed`,
  which locks again once per counted minute as a fallback, without counting, so a user who walked away
  from the locked screen is not shut down. `locked` only watches for the unlock. Leaving stage `up`
  sets `lock_state` back to `idle`. The user is never logged off.
- Notifications go through `notify_user`: `runuser -u <user> -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus notify-send`.
  It returns non-zero when the message was not delivered, and the queued message is retried on every
  check until it is; a newer message replaces it. Without sessions the queue is cleared. Without
  `notify-send` it returns 0.

State: `/var/lib/cronkid/<user>` (`STATE_DIR`) holds `<YYYY-MM-DD> <minutes> <period day> <locks>` and
is written atomically (tmp file + `mv`) by `write_state`. `read_state` sets `USED` (0 when the date is
not today, the daily reset) and `LOCKS` (0 when the period day differs). `period_day` is yesterday
before `FROM` and today otherwise (always today without a period), so a lockout in the evening lasts
until `FROM` the next morning. The state is re-read on every check, so `reset` takes effect while the
service runs.

Other commands:

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
  `bash -n`, skips the update if the file is identical, then does `chmod 0755` and an atomic `mv`, and `try-restart`s `cronkid@*.service` so the services
  run the new code. Any failure keeps the current version. The temp file stays in the same directory so that the rename is atomic, the
  running script keeps its old inode, and the SELinux label is `bin_t`.
- `uninstall` (root, auto-sudo): disables every `cronkid@<user>` that has a config or is enabled or
  active, removes the legacy user units and `~/.cronkid` of every user, then the template unit,
  `/etc/cronkid`, `/var/lib/cronkid` and `/usr/local/bin/cronkid`.

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

There is no test suite yet. Check syntax with `bash -n cronkid install.sh`. To test the loop without
root, copy the script with a small `TICK_SECONDS`, `CHECK_SECONDS=1`, short `LOCK_GRACE_SECONDS`,
`SHUTDOWN_WARN_SECONDS` and `SHUTDOWN_DELIVERY_SECONDS`, and `CONFIG_DIR`/`STATE_DIR` in a temporary
directory, and run `run --user <your own user>` (so `/run/user/<uid>/bus` exists). Put stubs first in
`PATH`: `loginctl` (`show-user` prints session IDs from a file, `show-session` answers `Class` with `user`,
`State` with `active` and `LockedHint` with `yes` while a `locked` file exists, `lock-session` logs and
creates that file, `list-users` prints `<uid> <name> ...` lines), `systemctl` (logs), `runuser` (drops everything up to `--` and execs the rest)
and `notify-send` (logs). Seeding the state file near the limit or with locks reaches the warnings,
locks and the shutdown quickly; writing a new ID into the sessions file is a login, deleting the
`locked` file an unlock, and a stub that never reports the hint tests the `unconfirmed` fallback. For the period,
set `FROM`/`UNTIL` relative to the current time (it uses the real clock).
