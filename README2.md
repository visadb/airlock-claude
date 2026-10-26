# airlock-claude2

Run Claude Code sandboxed in
[airlock](https://github.com/milankinen/airlock), in any directory, on top
of airlock's own packs and templates. Copy this one script anywhere on your
`PATH`; it starts the project's sandbox with network access denied by
default and drops you into a Claude Code session inside tmux.

## Prerequisites

- [`airlock`](https://github.com/milankinen/airlock), a version with packs
  and templates (`airlock templates` exists).
- Nothing else: no container engine, no image build. The sandbox is
  airlock's `alpine` pack plus its `claude` pack, or a template built from
  them.

## Usage

From any directory you want to work in:

```sh
airlock-claude2
```

**First run in a project.** airlock's setup wizard appears. Select
`alpine` as the base image and `claude` under coding agents, or select a
template if you have one, then `start`. airlock installs the packs onto
the sandbox disk (a minute or two) and the session begins. Later runs
skip the wizard. The wizard needs a terminal, so run a project's first
session interactively before scripting `-p` runs in it.

**Templates.** `airlock templates create <name>` runs the same wizard
once and keeps the result; a sandbox made from the template starts at
once, with nothing to install. The wizard lists your templates at the top.

The session runs in bypass-permissions mode — the VM is the sandbox, so
permission prompts aren't what's keeping it contained — with network
access denied by default: the Claude API and sign-in hosts (from the
`claude` pack), the Alpine package mirrors (from the `alpine` pack) and
whatever rules your project's `airlock.toml` adds are reachable, nothing
else.

Anything after `--` is passed to `claude` unchanged; with `-x`, it
*replaces* `claude` as the command run in the VM:

```sh
airlock-claude2 -- --resume
airlock-claude2 -M -- -p "run the tests and fix failures"
airlock-claude2 -x -- bash               # a sandboxed shell, no claude
```

### Flags

- `-T`, `--no-tmux` — run `claude` directly instead of inside tmux.
- `-M`, `--no-monitor` — skip `airlock`'s monitor TUI, which shows the
  network policy at work.
- `--mount-rw <dir>`, `--mount-ro <dir>` — bring other host directories
  into the sandbox, read-write or read-only (repeatable; see **Mounts**
  below).
- `-x`, `--exec` — run the command after `--` in place of `claude`.
- `-r`, `--rebuild` — remove the project's sandbox (`airlock remove`) and
  start again, so airlock makes a fresh one and the wizard runs again.
  Anything installed inside the VM is lost; your persisted Claude settings
  and login are not.

## Things to know

**What runs before the session.** Every launch first runs a short script
inside the sandbox: it installs tmux with `apk add` if it is missing (unless
`-T`), writes `/etc/tmux.conf` (mouse on, copies go to the host clipboard),
and writes Claude Code's managed settings (bypass permissions) and managed
`CLAUDE.md` under `/etc/claude-code`. The files are rewritten on every launch,
so a newer script reaches an existing sandbox without `-r`, and a sandbox
airlock re-created behind your back heals itself.

**tmux.** The session runs inside tmux, so you can split a pane and have a
shell next to Claude Code without leaving the sandbox. Detaching
(`prefix+d`) doesn't leave a session to come back to — the tmux client is
what `airlock` waits on, so detaching stops the VM.

**Login.** Your host `~/.claude` stays on the host; the `claude` pack mounts
its own, shared by every sandbox with the pack. Run `/login` in the
session: the sign-in page opens in your host browser, the real tokens stay
on the host, and the session only ever sees surrogates. A
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` on the host (or in
`airlock`'s vault) is used the same way.

**Network.** The script passes `--network deny-by-default` on every run.
That overrides the policy in your `airlock.toml` for the run; the rules in
it still apply. Allow more by adding rules there, or temporarily from the
monitor.

**Mounts.** Each `--mount-rw`/`--mount-ro` directory appears in the VM
under the project directory, named after its basename (two mounts can't
share one). The mounts are written as one marked block in the project's
`airlock.local.toml` — created if missing, the block replaced on every
run and removed on a run without mount flags, anything else in the file
left alone — so add `airlock.local.toml` to the project's `.gitignore`.
The block is bounded by `# BEGIN airlock-claude2 mounts` and
`# END airlock-claude2 mounts` lines; don't edit inside it, and keep both
lines, since a block missing its END line stops the script.
A changed mount set is a configuration change: `airlock` asks about it
once at start; accept it. Without a terminal that question aborts, so
change mounts in an interactive run first. Mounts need a sandbox to
exist already: on a project's first run they are refused, because the
file would keep the setup wizard from appearing; run once without them.
The mount point `airlock` creates in the project directory remains,
empty, after the session, and a same-named project directory is
shadowed for the session, untouched underneath.

**Session log.** Every run records the session's raw terminal stream to
`pty.dump` in the sandbox directory (`airlock info` shows it; one previous
run is kept as `pty.dump.previous`), and when `airlock` exits the last
lines are reprinted, escape-stripped — the monitor and tmux restore the
host screen on exit and would otherwise take a crash's final words with
them. The tail goes to stderr, so `-p` output on stdout stays clean.

**Python HTTPS.** Allowed HTTPS traffic is re-signed by `airlock`'s TLS
proxy, and Python 3.13+ strict certificate checking rejects its
certificates (`Missing Authority Key Identifier`); `curl`, `git` and `pip`
are fine. The managed `/etc/claude-code/CLAUDE.md` already tells every
session the per-client workaround, how to recognise a network-policy
denial, that packages come from `apk`, and to leave host-made virtualenvs
alone.

Apart from the mounts block, the script writes no config. The wizard's
answers live in the sandbox directory, and `airlock remove` deletes them
with it; a project's own `airlock.toml` applies as usual.

For how each step works and why it's shaped the way it is, see
[AGENTS2.md](AGENTS2.md).
