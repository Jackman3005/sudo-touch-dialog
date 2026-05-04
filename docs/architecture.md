# Architecture

## Flow

```
your shell
   │  sudo <cmd...>
   ▼
sudo() shim in ~/.bashrc      ── only for non-interactive shells
   │
   ▼
~/.local/bin/sudo-askpass     ── flock /run/user/$UID/sudo-askpass.lock
   │                             logs to ~/.local/state/sudo-askpass/asksudo.log
   ▼
sudo-touch-dialog (GTK4)      ── reads AGENT_SUDO_REASON, fido2-token -L,
   │                             `sudo -n true` to determine state
   │
   ├──[cached]──► sudo -n -- <cmd...>             (no auth needed)
   │
   ├──[touch ]──► sudo -A -- <cmd...>             (pam_u2f waits for tap)
   │              ↓ if user clicks "Use password"
   │              SIGKILL the -A sudo, fall through to ↓
   │
   └──[password] sudo -S -- <cmd...>              (pw piped on stdin)
```

The dialog **runs the actual sudo itself** (single-sudo flow). An
earlier two-call design (auth via `sudo -v`, then run via `sudo -n
cmd`) didn't work in non-tty environments because sudo's tty-tied
timestamp falls back to ppid behavior with no terminal — the wrapper's
later sudo had a different ppid than the dialog's auth sudo, so the
auth was invisible to it.

## Components

### `bin/sudo-askpass` (bash wrapper)

- Holds `/run/user/$UID/sudo-askpass.lock` while running so concurrent
  invocations queue and the user only ever sees one dialog at a time
  (so each tap is unambiguous about which command it authorizes).
- Invokes the dialog with the command as positional args after `--`.
- Logs APPROVED / REJECTED / FAILED to
  `~/.local/state/sudo-askpass/asksudo.log` based on the dialog's exit
  code.

> **Note**: the lock serializes the *dialogs*, not the timestamp
> caching. Whether queued invocations land in `cached` state depends
> on sudo's `timestamp_type` — see `gotchas.md` §1.

### `bin/sudo-touch-dialog` (Python+GTK4)

- Adwaita window, app_id `io.github.Jackman3005.SudoTouchDialog` (matched by
  Hyprland rules).
- Three states determined at startup:
  - `cached` if `sudo -n true` succeeds.
  - `touch` if `fido2-token -L` lists a hidraw device.
  - `password` otherwise.
- For `touch`: spawns `sudo -A -- <cmd>` immediately. Uses a FIFO at
  `/run/user/$UID/sudo-touch-<pid>/pw.fifo` and the bridge as
  `SUDO_ASKPASS`, so if pam_u2f times out and the user later picks the
  password fallback, the password we collect is fed in via FIFO without
  needing a separate sudo invocation. (In practice we kill and respawn
  with `-S` for snappy mode-switching — see kill semantics below.)
- For `password`: collects the password and runs `sudo -S -- <cmd>`,
  piping the password on stdin then closing it.

### `bin/sudo-askpass-bridge`

One-liner: `exec cat "$SUDO_ASKPASS_FIFO"`. Sudo invokes it for any
PAM `PROMPT_ECHO_OFF`; it reads from the FIFO the dialog controls.

## Kill semantics

When the user clicks **Cancel** or **Use password** while a
`sudo -A -v` is still mid-auth, we have to kill it. Two non-obvious
points:

- **SIGKILL**, not SIGTERM. `pam_u2f` is blocked inside libfido2's
  `fido_dev_get_assert(ms=-1)` — SIGTERM queues behind that and waits
  for the device to time out (~30s). SIGKILL has the kernel tear down
  the process and close `/dev/hidraw` immediately.
- **Signal by PID, not process group**. The sudo subprocess shares the
  Python dialog's process group (we deliberately don't `setsid`,
  because that would detach sudo from the tty). `os.killpg` would
  signal Python too. We `proc.kill()` directly.

Kills are dispatched on a background daemon thread so the GTK UI flips
instantly — the kernel reaps sudo whenever it gets to it.

## State storage

- **Lock**: `$XDG_RUNTIME_DIR/sudo-askpass.lock`
- **Per-invocation FIFO dir**: `$XDG_RUNTIME_DIR/sudo-touch-<pid>/`
- **Log**: `~/.local/state/sudo-askpass/asksudo.log`

## What the dialog deliberately does *not* do

- Detect per-command NOPASSWD: we always show the dialog, even when
  sudo wouldn't actually require a password. The user wanted a chance
  to reject every sudo regardless.
- Maintain its own auth cache: sudo's timestamp does that, with the
  caveats noted in `docs/gotchas.md`.
- Replace `lxqt-openssh-askpass` system-wide. It's still installed and
  used by anything that calls `ssh-askpass`.
