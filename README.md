# cronkid

A shell-based parental control for Linux that limits the usage time of configured users: a daily
limit, an allowed period of the day, or both. At the end the user is logged off. A user who keeps
logging in again is logged off again after a minute, and after the 5th automatic logoff of the day
the computer shuts down, also at every further login, until the next day.
The used time is stored on disk, so the limit survives logouts and reboots.

## Requirements

- Linux with systemd (system services and `loginctl`)
- `bash`, `curl`, `sudo`
- `notify-send` (package `libnotify`) for the warnings; without it the user is logged off without warning

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/sboe0705/cronkid/main/install.sh | sudo bash
```

This installs the `cronkid` script to `/usr/local/bin/cronkid`, which is accessible by all users.

## Usage

| Command                                              | Description                                                                  |
|------------------------------------------------------|------------------------------------------------------------------------------|
| `cronkid setup --user <username> [--limit <minutes>] [--from <HH:MM> --until <HH:MM>] [--warn <minutes>]` | Configures, enables and starts the control service of the user (root). `--limit` sets the minutes per day, `--from`/`--until` the allowed period of the day; at least one of them is required. `--warn` sets how many minutes before the end the first warning is shown (default 5). Running it again replaces the configuration. |
| `cronkid remove --user <username>`                   | Stops and removes the control service of the user (root). The used time is kept. |
| `cronkid status [--user <username>]`                 | Shows the remaining time, the used and allowed minutes, the allowed period and today's automatic logoffs. Works without root; without `--user` it shows the current user. |
| `cronkid reset --user <username>`                    | Resets today's used time and automatic logoffs to 0, which also lifts a lockout (root). |
| `cronkid update`                                     | Replaces the installed script with the latest version from GitHub and restarts the control services (root). |
| `cronkid version`                                    | Shows the version of the installed script: date and time (local time zone, without seconds) of the commit it was installed from, and its short commit ID. |
| `cronkid uninstall`                                  | Removes the script, the control services, their configuration and state (root). |

Commands that need root call `sudo` automatically when run by a regular user.

### Example

As a parent with sudo rights, allow the user `kid` 2 hours a day between 8 a.m. and 8 p.m.:

```bash
cronkid setup --user kid --limit 120 --from 08:00 --until 20:00
```

Check or reset the child's time with `cronkid status --user kid` and `cronkid reset --user kid`.

### Upgrading from a version with the screen lock

Older versions locked the screen and ran as a user service of the child. After `sudo cronkid update`
that service stops doing anything, so run `cronkid setup --user <name> ...` once again: it removes
the old service and starts the new one. The used time of the old version is not taken over.

## How it works

- `setup` writes the configuration to `/etc/cronkid/<user>.conf` and enables the system service
  `cronkid@<user>.service` (template `/etc/systemd/system/cronkid@.service`). It runs as root from
  boot on, so the child can neither stop it nor change its configuration or state.
- The service checks every few seconds and adds one minute to the used time for every full minute in
  which the user is logged in. The used time is stored in `/var/lib/cronkid/<user>` as
  `<date> <minutes> <period day> <logoffs>` (e.g. `2026-10-01 42 2026-10-01 0`).
- The time ends when the limit is used up or the allowed period is over, whichever comes first.
  Outside the allowed period there is no time at all.
- The user is warned by a desktop notification `--warn` minutes before the end (5 by default, or
  1 minute if the limit itself is not longer than that) and again 1 minute before the logoff. That last
  minute is not configurable.
- Every login is announced as well: with the remaining time, or with the warning about the logoff when
  the time is almost up or already over. A notification that cannot be delivered yet, because the
  desktop is still starting, is retried on the following checks.
- At the end, all sessions of the user are ended (`loginctl terminate-user`). The user can log in
  again, is told that they will be logged off in 1 minute, and is logged off after that minute. Each of
  these logoffs is counted.
- The 5th automatic logoff of the day shuts the computer down instead, and so does every further
  login of the user until the next day, also after a reboot. A shutdown is announced 10 seconds in
  advance, to the child and to every other logged-in user, and is carried out even when other users
  are logged in. Nothing happens as long as the child does not log in, so others can use the computer.
- The used time is reset automatically every day at midnight. The automatic logoffs belong to the day
  of the allowed period, which starts at `--from` (at midnight without a period): a child who is locked
  out at 9 p.m. is still locked out at 1 a.m. `cronkid reset` resets both.
- The version is written into the script while it is installed or updated, because a running script
  cannot tell which commit it came from. A script run straight from a clone of the repository
  therefore has no version. It is stored as UTC, because the machine that installs the script is not
  necessarily the one that runs it, and converted to the local time zone when it is shown.

## Known limitations

- The allowed period is the same every day and cannot cross midnight.
- The shutdown ends the sessions of other users too; unsaved work in them is lost.
- Root (and anyone with sudo rights) can change the system clock, the configuration and the state.
