# airlock-claude

Run Claude Code sandboxed in `airlock`, in any directory, with zero manual
setup. Copy this one script anywhere on your `PATH` and it builds whatever it
needs, generates the `airlock` config for you, and drops you into a Claude
Code session with network access denied by default — no image to hand-build,
no config to hand-write.

## Prerequisites

- `docker` or `podman` (used to build the sandbox VM image)
- `airlock` (the sandboxing CLI that starts the VM)

You don't need Claude Code installed on the host — it's installed into the
sandbox image, so this works the same on macOS and Linux. Your host `~/.claude`
is carried into the VM, so an existing login carries over.

## Usage

From any directory you want to work in:

```sh
airlock-claude
```

That's it — no per-project setup required. The first run in any environment
builds a local `airlock-claude:latest` image (a minimal `python:3.14-slim`
base with `git`, `curl`, `ripgrep`, `jq`, `less`, `procps`, `unzip`,
`openssh-client`, `tmux`, and `locales`, plus Claude Code itself); every run
after that reuses it.
Each invocation writes a fresh `airlock.local.toml` for the current directory
and starts Claude Code inside an `airlock` VM.

Claude Code runs in bypass-permissions mode, which is the point of the
exercise: the VM is the sandbox, so permission prompts aren't what's keeping
the session contained. That comes from the image rather than a command-line
flag — `/etc/claude-code/managed-settings.json`, Claude Code's system-level
settings file, sets `permissions.defaultMode` to `bypassPermissions` — so it
holds for any `claude` started inside the VM, not just the one this script
launches. Network access is denied by default, apart from what `airlock`'s
`claude-code` preset allows — enough for Claude Code to reach the API and its
own update endpoint, and nothing else unless you say so.

An image built before that setting existed starts with prompts on instead;
rebuild it with `-r`.

### Updates

Claude Code updates itself at startup, so you never have to rebuild the image
just to pick up a new release. Set `AIRLOCK_CLAUDE_SKIP_UPDATE=1` to skip the
check; if it fails (no network, say), the session simply starts on the version
already in the image.

### tmux

Claude Code runs inside `tmux`, so the session isn't stuck being one
full-screen program — you can open a second window or split a pane and have a
shell next to Claude Code without leaving the sandbox. When Claude Code exits
the tmux session ends and the VM comes down, exactly as it does without tmux.
Detaching is the one thing that doesn't behave the way tmux normally does:
`prefix+d` ends the tmux client, and that client is the process `airlock` is
waiting on, so detaching stops the VM rather than leaving a session to come
back to.

To run Claude Code directly instead:

```sh
airlock-claude -T        # or --no-tmux
```

`tmux` is configured for the mouse out of the box via `/etc/tmux.conf` —
tmux's system-level config, so it applies whichever user the VM runs as, and
your own `~/.tmux.conf` still overrides it. It sets:

- `mouse on`, so scrolling, pane selection and border-dragging work in tmux
  itself. This doesn't cost the session its mouse: tmux forwards events to any
  pane whose program has asked for mouse reporting, so Claude Code and `nvim`
  inside tmux still get theirs.
- `set-clipboard on`, plus a `terminal-features` entry asserting OSC 52
  support for every terminal, so copying in tmux reaches your host clipboard
  from inside the VM. The entry is needed because tmux only emits OSC 52 for
  terminals it believes support it, and the host terminal on the far side of
  the VM isn't something it can recognise.
- `default-terminal "tmux-256color"`, so starting tmux doesn't drop the
  session to 8 colours. That terminfo entry is already in `ncurses-base`,
  which the base image has, so nothing extra is installed for it — and
  nothing should be. Installing `ncurses-term` on top destroys the entries
  `ncurses-base` owns, `xterm-256color` included, and then `tmux` won't start
  at all: `missing or unsuitable terminal: xterm-256color`.

The image generates `en_US.UTF-8` at build time — the `locales` package plus a
one-line `/etc/locale.gen`, so exactly that locale is built and nothing else —
sets `LANG` to it, and starts tmux with `-u`. The last two say
the same thing twice on purpose. The base image sets no `LANG` at all, which
leaves the VM in the POSIX locale, and tmux decides whether its terminal is
UTF-8 by reading `LC_ALL`/`LC_CTYPE`/`LANG`. A tmux that concludes "not UTF-8"
rewrites the box-drawing characters passing through it into VT100 ACS escapes
and mangles anything multi-byte — so Claude Code's borders arrive as `q` and
`x` and its crab comes out broken, even though Claude Code emitted perfectly
good UTF-8. `-u` makes tmux's output UTF-8 regardless of that check, and is
what was confirmed to fix the rendering; `LANG` fixes the locale itself, which
everything else in the VM reads too.

One consequence of a named locale rather than `C.UTF-8`: `LANG` sets
`LC_COLLATE` as well, so `sort`, `ls` and glob ranges use English collation —
which ignores punctuation and case — instead of byte order. Export
`LC_COLLATE=C` in the session if you need scripts to sort the C way.

If your `airlock-claude:latest` image was built before `tmux` was added to it,
the launch fails with `tmux: command not found` — a plain run only builds when
the image is missing, so an existing image is never refreshed on its own. Run
`airlock-claude -r` once to rebuild with `tmux` in it, or `-T` to carry on
without.

### The monitor TUI

`airlock` wraps the session in a monitor TUI that shows the network policy at
work. It sits between the host terminal and the VM's pty, reading host input
itself and forwarding it on. Current `airlock` forwards mouse events along with
keys, so the session keeps its mouse under the monitor — Claude Code scrolls
and clicks, and so do full-screen programs you start inside the sandbox, `tmux`
and `nvim` included. Older `airlock` forwarded keys only; if the mouse is dead
in your session, that's the thing to check first.

To run without the monitor:

```sh
airlock-claude -M        # or --no-monitor
```

### Remote control

Normally no login happens in the sandbox at all: `airlock`'s `claude-code`
preset keeps your real `CLAUDE_CODE_OAUTH_TOKEN` on the host and injects it
into API requests at the host boundary, so the VM only ever sees a
placeholder. That's the safest mode — the token can't be stolen from inside
the sandbox — but Claude Code's `--remote-control` doesn't work on an
injected token; it needs a real interactive login. To get one:

```sh
airlock-claude -c        # or --remote-control
```

`-c` disables the preset's token injection for the run, hides the placeholder
token from the session, and passes `--remote-control` to `claude`. With no
token in sight, Claude Code asks you to log in; the login is stored under
`~/.airlock/claude` on the host (where the preset persists the sandbox's
`~/.claude`), so later `-c` runs reuse it rather than asking again. The
trade-off is that in this mode the session's credentials live inside the
sandbox like any ordinary login.

### Rebuilding the image

To rebuild the sandbox image from scratch — to pick up newer base packages, or
a git identity you've changed since the image was built — run:

```sh
airlock-claude -r        # or --rebuild-image
```

That builds with no layer cache and re-pulls the base image, and removes the
current directory's `.airlock` so `airlock` converts the new image rather than
the VM disk it cached from the old one. It takes minutes rather than seconds;
a plain run only builds when the image is missing.

## How it works

1. **Container engine detection** — prefers `docker`; falls back to `podman`
   via a temporary `docker`-forwarding shim if `docker` isn't installed, since
   `airlock` always invokes `docker` directly.
2. **Sandbox image build** — builds `airlock-claude:latest` if it doesn't
   already exist locally (or unconditionally, with `-r`), installing Claude
   Code into it with `https://claude.ai/install.sh`. `claude` on the image's
   `PATH` is a small wrapper that updates the install in place and then hands
   off to the real binary, which is why a new release doesn't need an image
   rebuild. Your git identity is read from the host at build time (the
   effective `user.name` and `user.email` from `git config --list --includes`)
   and written to `/etc/gitconfig` in the image, so commits made inside the VM
   are attributed to you. Since that happens at build time, run
   `airlock-claude -r` to pick up a changed identity.
3. **Config generation** — writes `airlock.local.toml` in the current
   directory, configuring:
   - `network.policy = "deny-by-default"`, with the `claude-code` preset
   - the sandbox VM image to use
   - `DISABLE_AUTOUPDATER=1` in the VM environment (that only turns off the
     *background* updater — the startup update still runs)
   - with `-c`, the preset's token-injecting middleware disabled
4. **Home directory adjustment** — `airlock` hardlinks files out of `HOME` into
   its per-directory state, and a hardlink can't cross a filesystem boundary —
   including a btrfs subvolume boundary, which isn't a separate mount but is a
   separate filesystem as far as `link(2)` is concerned. So when the working
   directory's filesystem root is something other than `/` or `/home`, `HOME`
   is repointed at that root, putting it on the same filesystem as the state
   being linked into.
5. **Launch** — runs
   `airlock start --monitor -- tmux -u new-session -A -s claude claude`,
   handing off to `airlock` to start the VM and run Claude Code inside it.
   No permission flag appears here: the image's
   `/etc/claude-code/managed-settings.json` already puts the session in
   bypass-permissions mode.
   `-M` drops `--monitor`; `-T` drops the `tmux` wrapper, leaving `claude`
   as the command `airlock` runs; `-c` runs claude as
   `env -u CLAUDE_CODE_OAUTH_TOKEN claude --remote-control`, stripping the
   preset's placeholder token so the interactive login kicks in.

`airlock.local.toml` is regenerated (overwritten) on every run and is not
meant to be hand-edited or committed. `airlock` keeps the VM disk it converts
from the image in `.airlock/`, which likewise shouldn't be committed; both are
gitignored here.
