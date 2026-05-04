# sudo-touch-dialog

A GTK4/Adwaita confirmation dialog for `sudo` that supports YubiKey tap,
password fallback, and explicit reject. Designed for non-interactive
shells (Claude Code, scripts) where you want every elevated command
explicitly authorized — but with the speed of just tapping a hardware
key.

## What you see

A small floating window that:

- Shows the literal command being run, with shell syntax highlighting
  (`sudo` and the command name in blue, flags in orange, quoted strings
  in green). Long commands wrap at word boundaries.
- Optionally shows a one-line **reason** — set
  `CLAUDE_SUDO_REASON="why this is happening"` in the env and it
  appears as a subtitle (e.g. for an LLM-driven shell).
- Adapts to three states automatically:
  - **cached**: timestamp fresh — just *Approve* / *Cancel*.
  - **touch**: YubiKey present — tap or click *Use password*.
  - **password**: no key plugged in — type and submit.

The wrapper logs every invocation to
`~/.local/state/sudo-askpass/asksudo.log` as APPROVED / REJECTED /
FAILED.

## Files

```
bin/sudo-askpass            bash wrapper, flock-serializes invocations
bin/sudo-touch-dialog       Python+GTK4 dialog, runs sudo internally
bin/sudo-askpass-bridge     `cat $FIFO` — sudo's askpass for password fallback
config/hyprland-windowrules.conf   float/center/pin/stay_focused/dim_around
docs/                       architecture, gotchas, integration notes
install.sh                  symlinks bin/ into ~/.local/bin/
```

## Install

```sh
./install.sh
```

Then, manually:

1. **Hyprland**: source the windowrules from your `hyprland.conf`:
   ```
   source = ~/Work/sudo-touch-dialog/config/hyprland-windowrules.conf
   ```
2. **Non-interactive sudo shim**: add to `~/.bashrc` (above any
   `[[ $- != *i* ]] && return`):
   ```bash
   if [[ $- != *i* ]]; then
       sudo() { "$HOME/.local/bin/sudo-askpass" "$@"; }
       return
   fi
   ```
   See `docs/claude-integration.md` for why and the snapshot caveat.

## Prereqs

- `pam-u2f` set as a sufficient auth method in `/etc/pam.d/sudo`:
  ```
  auth sufficient pam_u2f.so cue authfile=/etc/fido2/fido2
  ```
- A FIDO2 credential registered for your user (`pamu2fcfg`).
- `python-gobject`, `gtk4`, `libadwaita`, `inotify-tools` installed.
- `lxqt-openssh-askpass` is **not** required — we own the dialog.

## Exit codes

- `0` — sudo ran (forwards command's exit code).
- `77` — user clicked **Cancel** (logged REJECTED, stderr "sudo:
  command rejected by user").
- other non-zero — sudo failure or the command itself failed.

## Why not just `lxqt-openssh-askpass`?

It's a generic password askpass — single line, no hooks for YubiKey
state, can't render the command being authorized, no reject button
distinct from "wrong password". Under `sudo -A`, pam_u2f's "Please
touch the FIDO authenticator" cue goes to stderr (invisible to a GUI
user); after 30s of nobody noticing, askpass finally pops asking for a
password. This dialog replaces all of that with a single coordinated
UI.
