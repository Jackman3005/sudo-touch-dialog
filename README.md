# sudo-touch-dialog

> A GTK4 confirmation dialog for `sudo`. Tap a YubiKey or type a
> password — but always see the exact command you're authorizing first,
> with an explicit Cancel button when you don't want to run it.

Built for the situations where stock askpass falls down: LLM coding
agents that try to `sudo`, scripts that auth in the background,
multi-step automation. The dialog is a small floating window that
shows up the moment something needs `sudo`, displays the literal
command (syntax-highlighted), and gives you three buttons.

## Screenshots

<table>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/yubikey.png" alt="YubiKey mode — tap to authorize">
  <br><sub><b>YubiKey mode</b> — tap your key to authorize, or fall back to password.</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/password.png" alt="Password mode — type to authenticate">
  <br><sub><b>Password mode</b> — when no FIDO key is plugged in.</sub>
</td>
</tr>
</table>

## The problem this solves

If you've ever run an LLM coding agent (Claude Code, Cursor, etc.) and
hit one of these, you know:

- The agent runs `sudo apt install foo`, your askpass pops up *with no
  command shown*. You either trust the agent blindly or copy-paste the
  command into your own terminal — defeating the agent's autonomy.
- pam_u2f is configured but the cue ("Please touch the FIDO
  authenticator") only goes to stdout/stderr — invisible in a GUI
  session. So you wait 30 seconds for pam_u2f to time out, then a
  password dialog finally appears.
- Multiple sudo calls queue up and you have no idea which command your
  YubiKey tap is going to authorize.
- The askpass dialog doesn't have a "no, don't run this" button. You
  cancel by typing the wrong password and hoping sudo gives up.
- The dialog persists on screen during the entire command — so a
  `sudo pacman -Syu` leaves a modal in your face for minutes.

This dialog fixes all of those. The command itself is rendered in the
window with shell-syntax highlighting; YubiKey tap and password
fallback share one coordinated UI; concurrent sudos are flock-queued
so each tap is unambiguous; **Cancel** is a real first-class button
(exits 77, logged as REJECTED); the dialog auto-hides once sudo hands
off to the wrapped command.

## What you get

- **Per-command visibility.** Every elevated command renders in the
  dialog with `sudo` and the command name in blue, flags in orange,
  quoted strings in green. Long commands wrap.
- **Three auth states**, auto-detected:
  - **cached** — sudo timestamp is fresh, just *Approve* / *Cancel*.
  - **touch** — YubiKey present, tap to authorize, *Use password* link
    if you'd rather type.
  - **password** — no key plugged in, type and submit.
- **Optional reason line.** Set
  `AGENT_SUDO_REASON="installing the zig toolchain"` in the env and
  it shows as a subtitle. Designed for agents that should explain
  their intent; any caller can use it.
- **Wrong password retries** in-place with a red error label, no
  closing-and-restarting.
- **Auto-hide on hand-off.** Once sudo runs the wrapped command, the
  dialog gets out of the way — your desktop unblocks for long-running
  commands.
- **Cancel is real.** Click Cancel → wrapper exits 77 → caller can
  treat that as an explicit deny rather than an auth failure.
- **Concurrent-safe.** Wrapper holds an flock so queued sudos are
  shown one at a time. You always know which command you're tapping
  for.
- **Logged.** Every invocation lands in
  `~/.local/state/sudo-askpass/asksudo.log` as APPROVED / REJECTED /
  FAILED.

## Demo

```bash
$ AGENT_SUDO_REASON="installing zig toolchain" sudo pacman -S --needed zig
# → dialog pops up, shows the full command with syntax highlighting
#   and "installing zig toolchain" as subtitle.
# → tap your YubiKey
# → dialog vanishes, pacman runs in your terminal as normal.

$ sudo true                # quick "I want to verify the dialog still works"
# → dialog appears
# → click Cancel
sudo: command rejected by user
$ echo $?
77
```

## Compatibility

- **Distro**: built and tested on Arch Linux (specifically
  [Omarchy](https://omarchy.org/)).
- **Compositor**: Hyprland (Wayland). The dialog itself is portable —
  GTK4 + Adwaita + Python — and should run on any Wayland or X11
  desktop. The window-management bits (float, center, pin, dim_around)
  live in `config/hyprland-windowrules.conf`. **GNOME / KDE / Sway**
  users will need to substitute equivalent rules for centering and
  always-on-top behavior; the dialog itself is unchanged.
- **Sudo**: 1.9.x with `pam_u2f` configured as a `sufficient` first
  auth method.
- **YubiKey**: tested on 5-series (FIDO2). Other FIDO2 authenticators
  should work — the dialog talks to whatever `fido2-token -L` finds.

## Install

### Prereqs

```sh
# Arch (adjust for your distro)
sudo pacman -S --needed pam-u2f python-gobject gtk4 libadwaita inotify-tools
```

You'll also need:
- A FIDO2 credential registered for your user, e.g.
  `pamu2fcfg -o pam://$(hostname) -i pam://$(hostname) > /etc/fido2/fido2`.
- `pam_u2f` listed as `sufficient` first in `/etc/pam.d/sudo`:
  ```
  auth sufficient pam_u2f.so cue authfile=/etc/fido2/fido2
  ```

### Clone and link

```sh
git clone https://github.com/Jackman3005/sudo-touch-dialog.git
cd sudo-touch-dialog
./install.sh
```

`install.sh` symlinks `bin/*` into `~/.local/bin/`, so subsequent
`git pull`s pick up new versions automatically.

### Wire it into sudo

Two manual one-time steps:

1. **Hyprland window rules** — source the config from your
   `hyprland.conf`:
   ```
   source = /absolute/path/to/sudo-touch-dialog/config/hyprland-windowrules.conf
   ```
   then `hyprctl reload`.

2. **Non-interactive sudo shim** — in `~/.bashrc`, *before* any
   `[[ $- != *i* ]] && return` line:
   ```bash
   if [[ $- != *i* ]]; then
       sudo() { "$HOME/.local/bin/sudo-askpass" "$@"; }
       return
   fi
   ```
   Interactive shells stay untouched — you still get the normal
   terminal prompt when you type `sudo` yourself.

   See [`docs/agent-integration.md`](docs/agent-integration.md) for
   the snapshot caveat if you're integrating with Claude Code or a
   similar shell-snapshot-based harness.

### Verify

```sh
sudo true
```

Dialog should pop up. Tap or type, click Approve, and `echo $?` after
should print `0`. Click Cancel instead and you'll get `77` plus
`sudo: command rejected by user` on stderr.

## Configuration

### `AGENT_SUDO_REASON`

Set per-invocation:

```bash
AGENT_SUDO_REASON="kernel rebuild for the GPIO fix" sudo limine-mkinitcpio
```

Renders as a subtitle below the "Authorize this command" header. If
unset or empty, the subtitle is hidden and the layout looks the same
as without the feature.

#### Suggested rule for your agent context

If you use Claude Code, drop this in `~/.claude/CLAUDE.md` (or a
per-project `CLAUDE.md`). Cursor / Aider / etc. have equivalent
context files — adapt to taste.

```markdown
## sudo via sudo-touch-dialog

The user's `sudo` in non-interactive shells (every Bash tool invocation here) is gated by a custom GTK confirmation dialog.

- **Repo**: `~/Work/sudo-touch-dialog/` (public: https://github.com/Jackman3005/sudo-touch-dialog).
- **Always** set `AGENT_SUDO_REASON="<short why>"` inline before any sudo invocation. The value renders as a subtitle so the user knows *why* you're elevating. Keep it short — one lowercase phrase, no trailing period, describes the *intent* not the command.
  - `AGENT_SUDO_REASON="installing zig toolchain" sudo pacman -S zig`
  - `AGENT_SUDO_REASON="kernel rebuild for the GPIO fix" sudo limine-mkinitcpio`
- **Exit codes:**
  - `0` — sudo ran; forward the wrapped command's exit code.
  - `77` — user clicked Cancel. **Stop. Do not retry.** "sudo: command rejected by user" appears on stderr; treat it as an explicit deny and abort the flow.
  - other non-zero — sudo failure or the wrapped command failed. Read stderr; don't blindly retry.
- **Bash tool timeout**: the dialog needs a human in the loop. For commands likely to need fresh auth, pass a generous timeout (e.g. `300000` ms) so the tool doesn't SIGTERM the dialog mid-tap.
```

### Exit codes

| Code | Meaning                                                     |
|------|-------------------------------------------------------------|
| 0    | sudo ran. Forwards the wrapped command's exit code.         |
| 77   | User clicked **Cancel**. Logged as REJECTED on stderr.      |
| 1+   | sudo failed (auth or otherwise) — read stderr to diagnose.  |

## FAQ

### Why not just use `lxqt-openssh-askpass` (or `ssh-askpass`)?

They're generic single-line password dialogs — no command shown, no
"Tap YubiKey" indicator, no reject button. They also don't see
pam_u2f's touch cue (it goes through `SUDO_CONV_INFO_MSG`, not the
askpass channel) so the YubiKey path silently times out before askpass
even appears.

### Why not `pkexec` / a polkit agent?

pkexec requires policy files for arbitrary commands; pointing it at
`/usr/bin/sudo` defeats the purpose. polkit agents are tied to the
desktop's auth flow and don't replace `sudo` for shell-driven use.

### What happens if the agent calls sudo without my consent?

It can't bypass the dialog — `sudo` itself is shimmed via the bashrc
function. Cancel exits 77 and the agent sees an explicit reject in
stderr. Worst case: the agent retries; you cancel again; it gives up.

## Project status

Personal tool, working well, used daily. Issues and PRs welcome but no
guaranteed response time. The threat model is "I trust my agents
*almost* — let me confirm each elevation"; if you need a stronger
guarantee, this isn't enough on its own.

## Docs

- [`docs/architecture.md`](docs/architecture.md) — how the wrapper,
  dialog, FIFO, and lock fit together.
- [`docs/gotchas.md`](docs/gotchas.md) — non-obvious things the code
  works around (no-tty timestamps, SIGTERM-vs-SIGKILL, snapshot-cached
  bash functions, …).
- [`docs/agent-integration.md`](docs/agent-integration.md) — bashrc
  shim, `AGENT_SUDO_REASON`, suggested CLAUDE.md rule, Claude Code
  Bash tool timeout note.

## License

MIT — see [LICENSE](LICENSE).
