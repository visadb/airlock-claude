# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file launcher script, `airlock-claude`, whose purpose is to run
Claude Code sandboxed inside an `airlock` VM in *any* directory with zero
manual setup — no per-project image, no hand-written `airlock` config. Run
from a directory, the script builds what it needs, generates config on the
fly, and launches Claude Code with network access denied by default. The
entire repo is this one bash script — there is no build system, package
manifest, or test suite.

## How `airlock-claude` works

Reading the script top to bottom is the fastest way to understand the repo;
the logic is roughly:

1. **Pick a container engine.** Prefers `docker`; if absent, falls back to
   `podman` and creates a temporary shim directory with a `docker` executable
   that forwards to `podman` (added to `PATH` for the rest of the run), since
   `airlock` always shells out to a literal `docker` command.
2. **Build the sandbox image if missing.** `airlock-claude:latest` is built
   from an inline Dockerfile (`python:3.14-slim` + git/curl/ripgrep/jq/etc.)
   only when it doesn't already exist locally.
3. **Resolve the host `claude` binary.** Uses `readlink -f "$(command -v claude)"`
   so the real binary is bind-mounted into the VM read-only.
4. **Generate `airlock.local.toml`.** Overwritten on every run — it is
   untracked/gitignored-by-convention (there is no `.gitignore`, it's just
   never `git add`ed). It sets `network.policy = "deny-by-default"`, points
   `vm.image` at the built image, mounts the host `claude` binary into the
   VM at `/usr/local/bin/claude`, and disables the autoupdater via env var.
5. **Adjust `$HOME` for exotic filesystems.** If the current directory's
   filesystem root isn't `/` or `/home` (e.g. an overlay or network mount),
   `HOME` is redirected to that mount root before launching.
6. **Launch.** Runs `airlock start --monitor -- claude --dangerously-skip-permissions --remote-control`,
   handing control to the `airlock` CLI (an external tool, not part of this
   repo) which starts the VM and execs Claude Code inside it.

## Working on this script

- There is no build, lint, or test command — validate changes by running
  `./airlock-claude` directly. This requires `docker` or `podman`, the
  `airlock` CLI, and `claude` all present in `PATH`.
- `airlock.local.toml` and `.airlock/` are runtime artifacts produced by
  running the script / by `airlock` itself — don't hand-edit
  `airlock.local.toml` as a source file; it's regenerated (clobbered) on
  every invocation of `airlock-claude`.
