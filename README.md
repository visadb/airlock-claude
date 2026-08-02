# airlock-claude

Run Claude Code sandboxed in `airlock`, in any directory, with zero manual
setup. Copy this one script anywhere on your `PATH` and it builds whatever it
needs, generates the `airlock` config for you, and drops you into a Claude
Code session with network access denied by default — no image to hand-build,
no config to hand-write.

## Prerequisites

- `docker` or `podman` (used to build/run the sandbox VM image)
- `airlock` (the sandboxing CLI that starts the VM)
- `claude` (the Claude Code CLI) available in `PATH`

## Usage

From any directory you want to work in:

```sh
airlock-claude
```

That's it — no per-project setup required. The first run in any environment
builds a local `airlock-claude:latest` image (a minimal `python:3.14-slim`
base with `git`, `curl`, `ripgrep`, `jq`, `less`, `procps`, `unzip`, and
`openssh-client`); every run after that reuses it. Each invocation writes a
fresh `airlock.local.toml` for the current directory and starts Claude Code
inside an `airlock` VM with network access denied by default.

If only `podman` is available, the script transparently shims a `docker`
command that forwards to `podman`, since `airlock` always invokes `docker`
directly.

## How it works

1. **Container engine detection** — prefers `docker`; falls back to `podman`
   via a temporary `docker`-forwarding shim if `docker` isn't installed.
2. **Sandbox image build** — builds `airlock-claude:latest` if it doesn't
   already exist locally.
3. **Config generation** — writes `airlock.local.toml` in the current
   directory, configuring:
   - `network.policy = "deny-by-default"`
   - the sandbox VM image to use
   - a read-only mount of the host's `claude` binary into the VM at
     `/usr/local/bin/claude`
   - `DISABLE_AUTOUPDATER=1` in the VM environment
4. **Launch** — runs `airlock start --monitor -- claude --dangerously-skip-permissions --remote-control`,
   handing off to `airlock` to start the VM and run Claude Code inside it.

`airlock.local.toml` is regenerated (overwritten) on every run and is not
meant to be hand-edited or committed.
