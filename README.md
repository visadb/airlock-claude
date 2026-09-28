# airlock-claude

Run Claude Code sandboxed in
[airlock](https://github.com/milankinen/airlock), in any directory, with
zero manual setup. Copy this one script anywhere on your `PATH`; it builds
the sandbox image, generates the `airlock` config, and drops you into a
Claude Code session with network access denied by default.

## Prerequisites

- `docker` or `podman` (used to build the sandbox VM image)
- [`airlock`](https://github.com/milankinen/airlock) (the sandboxing CLI
  that starts the VM)
- a `CLAUDE_CODE_OAUTH_TOKEN` on the host — in the environment or in
  `airlock`'s secret vault; `claude setup-token` on the host generates
  one — unless you log in interactively with `-c`

## Usage

From any directory you want to work in:

```sh
airlock-claude
```

The first run builds a local `airlock-claude:latest` image (a minimal
`python:3.14-slim` base with `git`, `curl`, `ripgrep`, `tmux`, `vim` and
friends, plus Claude Code itself); later runs reuse it, and Claude Code
updates itself at startup so a new release needs no rebuild
(`AIRLOCK_CLAUDE_SKIP_UPDATE=1` skips the check).

The session runs in bypass-permissions mode — the VM is the sandbox, so
permission prompts aren't what's keeping it contained — with network access
denied by default: the Claude API and the `apt`/`pip` mirrors are reachable,
nothing else unless you allow it.

Anything after `--` is passed to `claude` unchanged; with `-x`, it *replaces*
`claude` as the command run in the VM:

```sh
airlock-claude -- --resume
airlock-claude -M -- -p "run the tests and fix failures"
airlock-claude -x -- bash               # a sandboxed shell, no claude
```

### Flags

- `-T`, `--no-tmux` — run `claude` directly instead of inside tmux.
- `-M`, `--no-monitor` — skip `airlock`'s monitor TUI, which shows the
  network policy at work.
- `--mount-rw <dir>`, `--mount-ro <dir>` — bring other host directories
  into the sandbox, read-write or read-only (repeatable; see below).
- `--theme <t>` — pick claude's colour theme (`dark`, `light`, `auto`, …).
  Without it (or the `AIRLOCK_CLAUDE_THEME` variable), the theme is detected
  from the host terminal, since claude's own detection can't see your
  terminal from inside the VM; either way it applies per launch, without
  touching your persisted settings.
- `-c`, `--remote-control` — run with a real interactive login (see
  **Login** below).
- `-x`, `--exec` — run the command after `--` in place of `claude`. The
  claude-only flags (`--theme`, `-c`) don't combine with it.
- `-r`, `--rebuild-image` — rebuild the image from scratch, to pick up newer
  base packages or a changed host git identity (both are baked in at build
  time). Takes minutes; a plain run only builds when the image is missing.

## Things to know

**tmux.** The session runs inside tmux, with mouse and copy-to-host-clipboard
working out of the box, so you can split a pane and have a shell next to
Claude Code without leaving the sandbox. Detaching (`prefix+d`) doesn't leave a session to come back
to — the tmux client is what `airlock` waits on, so detaching stops the VM.

**Login.** Your host `~/.claude` stays on the host; the VM gets its own,
persisted between runs under `~/.airlock/claude`. No login happens in the
sandbox: `airlock`'s `claude-code` preset injects your
`CLAUDE_CODE_OAUTH_TOKEN` into API requests at the host boundary, so the
token never enters the VM. The exception is `-c`, which claude's
`--remote-control` requires: it turns off the injection and has you log in
for real, persisting that login under `~/.airlock/claude` for later `-c`
runs — with the trade-off that those credentials live inside the sandbox.

**Session log.** Every run records the session's raw terminal stream to
`.airlock/sandbox/pty.dump` (one previous run is kept as
`pty.dump.previous`), and when `airlock` exits the last lines are reprinted,
escape-stripped — the monitor and tmux restore the host screen on exit and
would otherwise take a crash's final words with them. The tail goes to
stderr, so `-p` output on stdout stays clean.

**Mounts.** Each `--mount-rw`/`--mount-ro` directory appears in the VM under
the project directory, named after its basename (two mounts can't share
one). The mount point is created in the project directory and remains,
empty, after the session — worth a `.gitignore` entry — and a same-named
project directory is shadowed for the session, untouched underneath. Mounts
last only for the run you pass them on.

**Python HTTPS.** Allowed HTTPS traffic is re-signed by `airlock`'s TLS
proxy, and Python 3.13+ strict certificate checking rejects its certificates
(`Missing Authority Key Identifier`); `curl`, `git`, `pip` and Node are
fine. The image's managed `/etc/claude-code/CLAUDE.md` already tells every
session the per-client workaround, how to recognise a network-policy denial,
and to leave host-made virtualenvs alone.

`airlock.local.toml` and `.airlock/` are runtime artifacts — regenerated per
run and gitignored; don't edit or commit them.

For everything else — how each step works and why it's shaped the way it
is — see [AGENTS.md](AGENTS.md).
