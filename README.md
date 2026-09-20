# cronkid

A shell-based parental control for Linux that limits the usage time of configured users.
The used time is stored on disk, so the limit survives logouts and reboots.

## Requirements

- Linux with systemd (user services and `loginctl`)
- `bash`, `curl`, `sudo`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/sboe0705/cronkid/main/install.sh | sudo bash
```

This installs the `cronkid` script to `/usr/local/bin/cronkid`, which is accessible by all users.

## Usage

| Command                                              | Description                                                                  |
|------------------------------------------------------|------------------------------------------------------------------------------|
| `cronkid setup --limit <minutes> [--user <username>]`| Configures and enables the control service. It starts immediately if the user is logged in, otherwise at their next login. Running it again replaces the limit. |
| `cronkid remove [--user <username>]`                 | Stops and removes the control service. The used time is kept.                |
| `cronkid status [--user <username>]`                 | Shows the remaining, used and allowed minutes for today.                     |
| `cronkid reset [--user <username>]`                  | Resets today's used time to 0.                                               |
| `cronkid update`                                     | Replaces the installed script with the latest version from GitHub (root).    |
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
- Once a minute the service adds one minute to the used time, stored in the hidden file `~/.cronkid`
  as `<date> <minutes>` (e.g. `2026-09-19 42`).
- When the used time reaches the limit, the service locks the screen of all sessions of the user
  (`loginctl lock-session`). If the limit is already reached at login, the screen is locked right
  after logging in. The screen is locked again on every check, so unlocking it does not buy extra time.
- The used time is reset automatically every day at midnight: minutes recorded on an earlier date
  count as 0, also after a reboot or while the user is logged in. `cronkid reset` resets it manually.

## Known limitations

- There is no warning before the screen is locked.
- The user stays logged in, so the used time keeps counting while the screen is locked.
- A user who knows their password can unlock the screen. It is locked again within a minute.
- The controlled user owns the service and the `~/.cronkid` file. A user who knows how can stop the
  service, run `cronkid reset` or edit the file.
