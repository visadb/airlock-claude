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
base with `git`, `curl`, `ripgrep`, `jq`, `less`, `procps`, `unzip`, and
`openssh-client`, plus Claude Code itself); every run after that reuses it.
Each invocation writes a fresh `airlock.local.toml` for the current directory
and starts Claude Code inside an `airlock` VM.

Claude Code runs with `--dangerously-skip-permissions`, which is the point of
the exercise: the VM is the sandbox, so permission prompts aren't what's
keeping the session contained. Network access is denied by default, apart from
what `airlock`'s `claude-code` preset allows — enough for Claude Code to reach
the API and its own update endpoint, and nothing else unless you say so.

### Updates

Claude Code updates itself at startup, so you never have to rebuild the image
just to pick up a new release. Set `AIRLOCK_CLAUDE_SKIP_UPDATE=1` to skip the
check; if it fails (no network, say), the session simply starts on the version
already in the image.

### The monitor TUI

`airlock` wraps the session in a monitor TUI that shows the network policy at
work. That costs the session its mouse: the monitor reads the host terminal
itself and forwards only key events, so the mouse-reporting sequences Claude
Code enables on the alternate screen never reach the VM, and the session can't
be scrolled or clicked. The same goes for any full-screen program you start
inside the sandbox — `nvim` loses `set mouse=a` under the monitor too.

When you'd rather have the mouse:

```sh
airlock-claude -M        # or --no-monitor
```

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
4. **Home directory adjustment** — `airlock` hardlinks files out of `HOME` into
   its per-directory state, and a hardlink can't cross a filesystem boundary —
   including a btrfs subvolume boundary, which isn't a separate mount but is a
   separate filesystem as far as `link(2)` is concerned. So when the working
   directory's filesystem root is something other than `/` or `/home`, `HOME`
   is repointed at that root, putting it on the same filesystem as the state
   being linked into.
5. **Launch** — runs `airlock start --monitor -- claude --dangerously-skip-permissions --remote-control`
   (without `--monitor` under `-M`), handing off to `airlock` to start the VM
   and run Claude Code inside it.

`airlock.local.toml` is regenerated (overwritten) on every run and is not
meant to be hand-edited or committed. `airlock` keeps the VM disk it converts
from the image in `.airlock/`, which likewise shouldn't be committed; both are
gitignored here.
