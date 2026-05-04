# Agent integration

How to wire this dialog into agent-driven shells (Claude Code, Cursor,
Aider, plain unattended scripts) so every `sudo` lands in the dialog
instead of failing silently or hanging on an invisible prompt.

## The bashrc shim

Most agent harnesses spawn each shell command as a non-interactive
shell (`bash -c "..."` or similar). We need `sudo` to route through
our wrapper in those shells — but **not** in your interactive shell,
where typing `sudo` should still give you the normal terminal prompt.

In `~/.bashrc`, before any `[[ $- != *i* ]] && return` line:

```bash
if [[ $- != *i* ]]; then
    sudo() { "$HOME/.local/bin/sudo-askpass" "$@"; }
    return
fi
```

`$-` includes `i` only for interactive shells. The shim only fires for
non-interactive ones, leaving your terminal experience untouched.

### Snapshot caveat (Claude Code)

Claude Code seeds each Bash tool invocation from snapshots in
`~/.claude/shell-snapshots/snapshot-bash-*.sh`. Functions defined in
`~/.bashrc` are captured base64-encoded into those snapshots at session
start. Editing `~/.bashrc` alone won't update an active session — the
old function definition is baked into the snapshot.

To force the new shim live without restarting the session, decode →
replace → re-encode the relevant block in each snapshot. See
[`gotchas.md` §5](gotchas.md) for the exact Python recipe.

For new sessions, just edit `~/.bashrc` and you're done.

## The `AGENT_SUDO_REASON` env var

The dialog reads `AGENT_SUDO_REASON` and renders it as a one-line
subtitle below the "Authorize this command" header. The intent is to
let an agent explain *why* it's elevating, so the human approver isn't
guessing.

Set per-invocation, **not** session-wide:

```bash
AGENT_SUDO_REASON="installing the zig toolchain" sudo pacman -S zig
AGENT_SUDO_REASON="kernel rebuild for the GPIO fix" sudo limine-mkinitcpio
```

If the var is unset or empty, the subtitle isn't rendered and the
layout looks identical to a no-reason invocation.

### Suggested rule for your agent

Drop this in `~/.claude/CLAUDE.md` (or your agent's equivalent
instruction file):

```markdown
## When running sudo

Always set `AGENT_SUDO_REASON="<short why>"` inline before any sudo
invocation. The value renders as a subtitle in the user's confirmation
dialog so they know *why* the elevation is needed.

Examples:
- `AGENT_SUDO_REASON="installing zig toolchain" sudo pacman -S zig`
- `AGENT_SUDO_REASON="cleaning a stale orphan from the last test" sudo kill 99679`

Keep it short — one phrase, lowercase, no trailing period. Don't quote
the command itself; just describe the intent.
```

## Bash tool timeout (Claude Code)

Claude Code's Bash tool defaults to a 120 s timeout. If the human
takes longer than that to authorize (read the command, fish out the
YubiKey, tap), the tool will SIGTERM the bash subshell and the dialog
will close abruptly.

For commands likely to need fresh auth, the agent should pass a
generous timeout (5 minutes is a good default):

```python
Bash({"command": "sudo ...", "timeout": 300000, ...})
```

Other agent harnesses have similar knobs — check yours.

## Exit-code handling

| Code | Meaning                                          | Agent should…                      |
|------|--------------------------------------------------|------------------------------------|
| 0    | sudo ran; forwards the cmd's exit code.          | continue normally.                 |
| 77   | User explicitly cancelled.                       | **stop**; do not retry.            |
| 1+   | sudo or the wrapped command failed.              | inspect stderr; don't blindly retry. |

The 77 case is important: it's the human saying *"no, don't run that
command"*. Treating it as a transient failure and retrying turns the
dialog into a nag screen and trains the human to click Approve out of
fatigue. Read stderr (`sudo: command rejected by user`) and abort the
whole flow.

## Testing the integration

A quick sanity check that the agent can drive the dialog end-to-end:

```bash
AGENT_SUDO_REASON="agent integration smoke test" sudo true
```

You should see the dialog show up with the subtitle, the command shown
as `sudo true`, and the auth state appropriate to whether your YubiKey
is plugged in.
