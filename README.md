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
- optionally a `CLAUDE_CODE_OAUTH_TOKEN` on the host — in the environment or
  in `airlock`'s secret vault; `claude setup-token` generates one. Without
  it, `/login` inside the session signs you in through your host browser
  (see **Login** below)

## Usage

From any directory you want to work in:

```sh
airlock-claude
```

The first run builds a local `airlock-claude:latest` image (a minimal
`python:3.14-slim` base with `git`, `curl`, `ripgrep`, `tmux`, `vim` and
friends, the latest LTS Node.js installed through `nvm`, plus Claude Code
itself); later runs reuse it, and Claude Code
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
- `-x`, `--exec` — run the command after `--` in place of `claude`. The
  claude-only flag `--theme` doesn't combine with it.
- `-r`, `--rebuild-image` — rebuild the image from scratch, to pick up newer
  base packages, and remove the project's sandbox (`airlock remove`) so the new
  image gets a fresh one. Anything installed inside the VM is lost; your
  persisted Claude settings and login are not. Takes minutes; a plain run
  only builds when the image is missing.

## Things to know

**tmux.** The session runs inside tmux, with mouse and copy-to-host-clipboard
working out of the box, so you can split a pane and have a shell next to
Claude Code without leaving the sandbox. Detaching (`prefix+d`) doesn't leave a session to come back
to — the tmux client is what `airlock` waits on, so detaching stops the VM.

**Login.** Your host `~/.claude` stays on the host; the VM gets its own,
persisted between runs under `~/.airlock/claude`. With a
`CLAUDE_CODE_OAUTH_TOKEN` on the host, `airlock`'s `claude-code` preset
injects it into API requests at the host boundary and the session only ever
sees a surrogate. Without one, run `/login` in the session: `airlock`'s
`anthropic` sign-in service opens the sign-in page in your host browser,
keeps the real tokens encrypted on the host (it needs `airlock`'s secret
vault; the default keyring works) and again hands the session surrogates.
That sign-in is shared by every `airlock` sandbox that enables the service,
and logging out in one logs out all.

**Git identity.** Commits made in the session carry your host identity: on
every run the script reads `user.name` and `user.email` as git sees them
from the project directory (repo-local config included) and passes them in
as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`; a `GIT_AUTHOR_NAME` and friends set on
the host take precedence. Nothing is baked into the image.

**Session log.** Every run records the session's raw terminal stream to
`pty.dump` in the sandbox directory (`airlock info` shows it; one previous
run is kept as `pty.dump.previous`), and when `airlock` exits the last lines
are reprinted,
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

`airlock.local.toml` is a runtime artifact — regenerated per run and
gitignored; don't edit or commit it. The sandbox itself lives in `airlock`'s
data directory, not in the project.

For everything else — how each step works and why it's shaped the way it
is — see [AGENTS.md](AGENTS.md).
