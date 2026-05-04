# Claude Code integration

How this dialog integrates into Claude Code (and any other
non-interactive shell harness).

## The bashrc shim

Claude Code spawns each Bash tool invocation as a non-interactive
shell. We need `sudo` to route through our wrapper in those shells —
without disturbing the user's interactive shell, where they type
`sudo` themselves and get the normal terminal prompt.

In `~/.bashrc`, before any `[[ $- != *i* ]] && return`:

```bash
if [[ $- != *i* ]]; then
    sudo() { "$HOME/.local/bin/sudo-askpass" "$@"; }
    return
fi
```

After editing, you'll likely need to patch the shell snapshots Claude
captured at session start (see `gotchas.md` §5).

## The reason env var

The dialog reads `CLAUDE_SUDO_REASON` and renders it as a one-line
subtitle below the "Authorize this command" header. Keeps you informed
about *why* the agent is asking for sudo.

The agent should set this just-in-time per command, not export it
session-wide:

```bash
CLAUDE_SUDO_REASON="installing the zig toolchain" sudo pacman -S zig
```

Or for multiple:

```bash
CLAUDE_SUDO_REASON="kernel rebuild for the GPIO fix" sudo limine-mkinitcpio
```

If the var is unset or empty, no subtitle is rendered and the layout
looks the same as without the feature.

### Suggested CLAUDE.md rule

Drop this in `~/.claude/CLAUDE.md` (or per-project) so the model
remembers:

```markdown
## When running sudo

Always set `CLAUDE_SUDO_REASON="<short why>"` inline before any sudo
invocation. The value renders as a subtitle in Jack's confirmation
dialog so he knows *why* the elevation is needed.

Examples:
- `CLAUDE_SUDO_REASON="installing zig toolchain" sudo pacman -S zig`
- `CLAUDE_SUDO_REASON="cleaning stale orphan from the last test" sudo kill 99679`

Keep it short — one phrase, lowercase, no trailing period. Don't quote
the command itself; just describe the intent.
```

## Bash tool timeout

The default Bash tool timeout is 120s. If the user takes longer than
that to authorize (read the command, fish out the YubiKey, tap), the
tool will SIGTERM the bash subshell and the dialog will close
abruptly.

For commands likely to need fresh auth, the agent should pass a
generous timeout (e.g. 5 minutes):

```python
Bash({"command": "sudo ...", "timeout": 300000, ...})
```

## Exit code interpretation

- `0` — sudo ran (forwards command's exit code).
- `77` — user cancelled. The agent should treat this as an explicit
  reject, *not* retry. "sudo: command rejected by user" is on stderr.
- other non-zero — sudo failure or the wrapped command itself failed.
  Read stderr to disambiguate; don't blindly retry.
