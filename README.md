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

| Command                          | Runs as        | Description                                                                 |
|----------------------------------|----------------|-----------------------------------------------------------------------------|
| `cronkid setup --limit <minutes>`| controlled user| Configures, enables and starts the control service for the current user.    |
| `cronkid unsetup`                | controlled user| Stops, disables and removes the control service of the current user (keeps the used time). |
| `cronkid reset`                  | controlled user| Resets the used time of the current user to 0.                              |
| `cronkid update`                 | root (via sudo)| Replaces the installed script with the latest version from GitHub.          |
| `cronkid uninstall`              | root (via sudo)| Removes the script, the control services and the used-time files of all users. |

`update` and `uninstall` call `sudo` automatically when run by a regular user.

### Example

Log in as the child's user (or `su - <child>`) and run:

```bash
cronkid setup --limit 120
```

Running `setup` again with another limit replaces the previous configuration.

## How it works

- `setup` writes a systemd **user** service to `~/.config/systemd/user/cronkid.service` and enables it
  for `default.target`. The service starts automatically when the user logs in and stops when their last
  session ends.
- Once a minute the service adds one minute to the used time, stored in the hidden file `~/.cronkid`
  (the file holds a plain number of minutes).
- When the used time reaches the limit, the service ends all sessions of the user
  (`loginctl terminate-user`). If the limit is already reached at login, the user is logged out
  right after logging in.
- The used time is **not** reset automatically. Use `cronkid reset` to reset it.

## Known limitations

- The used time is only reset manually via `cronkid reset`. There is no daily reset yet.
- There is no warning before the user is logged out.
- The controlled user owns the service and the `~/.cronkid` file. A user who knows how can stop the
  service, run `cronkid reset` or edit the file.
