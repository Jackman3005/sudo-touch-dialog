# Gotchas

Stuff that bit me while building this. Each entry is a workaround in
the current code; don't undo without understanding why.

## 1. Sudo timestamps without a tty

`/etc/sudoers` defaults to `timestamp_type=tty`. Per `man sudoers`:

> If no terminal is present, the behavior is the same as `ppid`.

`ppid` means *each parent process gets its own ticket*. Each Claude
Code Bash tool invocation is a fresh `bash -c "..."`, so sudo's ppid
differs every call → cached state is rarely seen across separate
invocations.

**Fix if you want it**: `Defaults:<user> timestamp_type=global` in
`/etc/sudoers.d/<user>-timestamp` gives you a single user-wide ticket.
Tradeoff: any concurrent sudo from another session also benefits from
that ticket — slightly weaker isolation than per-tty/ppid.

The default in this repo is *not* to set this — tapping per command is
fast with a YubiKey and the per-command authorization is the whole
point of the dialog. If you find yourself authorizing many sudos in
quick succession from agents, the global setting is the right escape
hatch.

## 2. pam_u2f's "cue" goes to stderr, not askpass

Under `sudo -A`, sudo maps PAM message types like this (sudoers source,
`auth/pam.c`):

```
PAM_TEXT_INFO        → SUDO_CONV_INFO_MSG     (stderr)
PAM_PROMPT_ECHO_OFF  → SUDO_CONV_PROMPT_ECHO_OFF (askpass)
```

pam_u2f's `cue` option emits "Please touch the FIDO authenticator." as
PAM_TEXT_INFO. So `SUDO_ASKPASS=lxqt-openssh-askpass` never sees it.
In a GUI session with no terminal, the touch prompt is invisible. The
user waits, pam_u2f hits its 30s timeout, and only *then* does askpass
appear asking for a password.

The dialog avoids this by owning the UI itself.

## 3. Don't `setsid` the sudo subprocess

It's tempting (clean process group, easy `killpg`). Don't:

- Detaches sudo from the controlling tty → if you ever do a two-call
  flow (`sudo -A -v` then `sudo -n cmd`), the no-tty timestamp record
  the first call writes is invisible to the second.
- Combined with `os.killpg(os.getpgid(sudo))`, you'd kill the parent
  process group — the dialog itself dies. You'd see the dialog vanish
  the moment the user clicks "Use password".

Solution: don't setsid; signal sudo directly by PID.

## 4. SIGTERM is not enough to kill pam_u2f

`pam_u2f` calls `fido_dev_get_assert(ms=-1)` — block forever until the
device responds. SIGTERM queues; sudo doesn't actually exit until the
*device* gives up (CTAP2_ERR_ACTION_TIMEOUT, 0x3a, ~30s).

SIGKILL bypasses that — kernel-level termination, fds closed
immediately, /dev/hidraw is released for the next caller.

## 5. Bash shell snapshots cache the `sudo()` function

Claude Code seeds each Bash tool invocation from snapshots in
`~/.claude/shell-snapshots/snapshot-bash-*.sh`. Functions defined in
`~/.bashrc` are captured base64-encoded inside `eval "$(echo '...' |
base64 -d)"` blocks at session start.

Editing `~/.bashrc` alone won't update an active session. To force
the new shim live, decode → replace → re-encode the relevant block in
each snapshot. Example Python:

```python
import base64, re, glob
new = '''sudo () \n{ \n    "$HOME/.local/bin/sudo-askpass" "$@"\n}\n'''
new_b64 = base64.b64encode(new.encode()).decode()
new_b64 = '\n'.join(new_b64[i:i+76] for i in range(0,len(new_b64),76))
pat = re.compile(r"echo '([A-Za-z0-9+/=\n]+)'\s*\|\s*base64 -d")
for path in glob.glob('/home/<user>/.claude/shell-snapshots/snapshot-bash-*.sh'):
    src = open(path).read()
    def repl(m):
        d = base64.b64decode(m.group(1).replace('\n','')).decode('utf-8','replace')
        return f"echo '{new_b64}' | base64 -d" if d.lstrip().startswith('sudo ') else m.group(0)
    open(path,'w').write(pat.sub(repl, src))
```

## 6. Reading `/etc/pam.d/sudo` ordering

Arch/Omarchy ships:

```
auth    sufficient pam_u2f.so cue authfile=/etc/fido2/fido2
#%PAM-1.0
auth    include    system-auth
```

The `pam_u2f` line is *before* the `#%PAM-1.0` comment header. PAM
treats `#`-prefixed lines as comments, so the file still parses
correctly — the U2F line is in effect. Don't be tempted to "fix" the
ordering; it's intentional.

## 7. Adding `debug` to `/etc/pam.d/sudo`

Useful for diagnosing pam_u2f, but it dumps the full HID/CBOR exchange
to stderr — *very* noisy and prints to whatever sudo's stderr is, which
under our wrapper means it shows up in your shell. Remove `debug` once
you're done.
