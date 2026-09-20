# cronkid

A shell-based parental control for Linux that limits the usage time of configured users.
The used time is stored on disk, so the limit survives logouts and reboots.

## Requirements

- Linux with systemd (user services and `loginctl`)
- `bash`, `curl`, `sudo`
- `notify-send` (package `libnotify`) for the warnings; without it the screen is locked without warning

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/sboe0705/cronkid/main/install.sh | sudo bash
```

This installs the `cronkid` script to `/usr/local/bin/cronkid`, which is accessible by all users.

## Usage

| Command                                              | Description                                                                  |
|------------------------------------------------------|------------------------------------------------------------------------------|
| `cronkid setup --limit <minutes> [--warn <minutes>] [--user <username>]`| Configures and enables the control service. It starts immediately if the user is logged in, otherwise at their next login. Running it again replaces the configuration. `--warn` sets how many minutes before the end the first warning is shown (default 5). |
| `cronkid remove [--user <username>]`                 | Stops and removes the control service. The used time is kept.                |
| `cronkid status [--user <username>]`                 | Shows the remaining, used and allowed minutes for today.                     |
| `cronkid reset [--user <username>]`                  | Resets today's used time to 0.                                               |
| `cronkid update`                                     | Replaces the installed script with the latest version from GitHub (root).    |
| `cronkid version`                                    | Shows the version of the installed script: date and time (local time zone, without seconds) of the commit it was installed from, and its short commit ID. |
| `cronkid uninstall`                                  | Removes the script, the control services and the used-time files of all users (root). |

Without `--user`, a command applies to the user who runs it. With `--user`, it applies to the given user and
needs root. `--user`, `update` and `uninstall` call `sudo` automatically when run by a regular user.

### Example

As a parent with sudo rights, set up a limit of 2 hours for the user `kid`:

```bash
cronkid setup --limit 120 --user kid
```

Or log in as the child's user and run `cronkid setup --limit 120`. Check or reset the child's time with
`cronkid status --user kid` and `cronkid reset --user kid`.

Running `setup` again with another limit replaces the previous configuration.

## How it works

- `setup` writes a systemd **user** service to `~/.config/systemd/user/cronkid.service` and enables it
  for `default.target`. The service starts automatically when the user logs in and stops when their last
  session ends.
- The service checks every few seconds and adds one minute to the used time for every full minute of
  checks. The used time is stored in the hidden file `~/.cronkid` as `<date> <minutes>`
  (e.g. `2026-09-19 42`).
- The user is warned by a desktop notification `--warn` minutes before the end (5 by default, or
  1 minute if the limit itself is not longer than that) and again in the last minute. After logging
  in the user is notified of the remaining time, or gets the warning right away if the time is
  almost up. This also happens at a further login, because the service can keep running across
  logouts, as long as the user's service manager stays up. A notification that cannot be delivered
  yet, because the desktop is still starting, is retried on the following checks and therefore
  arrives within seconds of the desktop being ready.
- When the used time reaches the limit, the service locks the screen of all sessions of the user
  (`loginctl lock-session`). If the limit is already reached at login, the screen is locked right
  after logging in. After that it is locked again with every counted minute, so unlocking it buys at
  most the rest of the current minute.
- The version is written into the script while it is installed or updated, because a running script
  cannot tell which commit it came from. A script run straight from a clone of the repository
  therefore has no version. It is stored as UTC, because the machine that installs the script is not
  necessarily the one that runs it, and converted to the local time zone when it is shown.
- The used time is reset automatically every day at midnight: minutes recorded on an earlier date
  count as 0, also after a reboot or while the user is logged in. `cronkid reset` resets it manually.

## Known limitations

- The user stays logged in, so the used time keeps counting while the screen is locked.
- A user who knows their password can unlock the screen. It is locked again within a minute.
- The controlled user owns the service and the `~/.cronkid` file. A user who knows how can stop the
  service, run `cronkid reset` or edit the file.
