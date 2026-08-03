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
   only when it doesn't already exist locally. The image also installs Claude
   Code itself via `https://claude.ai/install.sh` — the host binary is *not*
   mounted in, because it's built for the host OS (a macOS `claude` cannot run
   in the Linux VM). Install details that matter:
   - It installs under a fixed `HOME` (`/opt/claude`, exported as
     `CLAUDE_INSTALL_HOME`) so the launcher path doesn't depend on which user
     the VM runs as, and the tree is left world-writable (`chmod -R a+rwX`) so
     a non-root VM user can still update it.
   - `/opt/claude/.local/bin` is *appended* to `PATH` — `/usr/local/bin` must
     stay ahead of it so `claude` resolves to the wrapper below, but having the
     install dir on `PATH` at all suppresses Claude Code's "not in your PATH"
     warning on every update.
   - `/usr/local/bin/claude` is a wrapper that runs `claude update` (with `HOME`
     pointed at `/opt/claude`, so the updater resolves the image's install
     rather than the VM user's home) and then `exec`s the real launcher with
     the session's real `HOME`. This is what lets a new Claude Code release
     land without rebuilding the image. Update output goes to stderr so
     `claude -p` stdout stays clean, a failed update is non-fatal (falls back
     to the version baked into the image), and a `/tmp` stamp file limits the
     update to once per VM boot so nested `claude` calls can't swap the binary
     out from under a running session. `AIRLOCK_CLAUDE_SKIP_UPDATE=1` skips it.
   - The host's git identity is baked in so commits made inside the VM are
     attributed correctly. The script reads `git config --list --includes` on
     the host and takes the *last* `user.name` / `user.email` line (that
     listing is ordered by increasing precedence, so last = effective), passes
     them as build args, and the image writes them with `git config --system`
     — i.e. to `/etc/gitconfig`, so they apply whichever user the VM runs as,
     while a real `~/.gitconfig` in the mounted home still wins. Either value
     may be empty (host has no identity set), in which case that key is simply
     not written; the `ARG`/`RUN` pair is kept last in the Dockerfile so a
     changed identity doesn't invalidate the cached Claude Code install above.
     Two consequences worth knowing: the identity is captured at *build* time,
     so changing it on the host needs `docker rmi airlock-claude:latest` to
     take effect; and because `--list --includes` picks up repo-local config,
     whatever directory the first build runs in decides what gets baked in.
3. **Generate `airlock.local.toml`.** Overwritten on every run — it is
   untracked/gitignored-by-convention (there is no `.gitignore`, it's just
   never `git add`ed). It sets `network.policy = "deny-by-default"`, points
   `vm.image` at the built image, and disables the *background* autoupdater via
   env var (`DISABLE_AUTOUPDATER=1` does not affect the explicit `claude update`
   the wrapper runs). The `claude-code` preset already allows
   `downloads.claude.ai:443`, which is where install/update fetch from, so the
   startup update works under the deny-by-default policy.
4. **Adjust `$HOME` for exotic filesystems.** If the current directory's
   filesystem root isn't `/` or `/home` (e.g. an overlay or network mount),
   `HOME` is redirected to that mount root before launching.
5. **Launch.** Runs `airlock start --monitor -- claude --dangerously-skip-permissions --remote-control`,
   handing control to the `airlock` CLI (an external tool, not part of this
   repo) which starts the VM and execs Claude Code inside it.

## Working on this script

- There is no build, lint, or test command — validate changes by running
  `./airlock-claude` directly. This requires `docker` or `podman` and the
  `airlock` CLI in `PATH` (a host `claude` is no longer needed). To iterate on
  the image without launching a session, extract the Dockerfile heredoc, build
  it by hand, and probe it with `docker run --rm ... claude --version`; check
  the non-root case too (`--user 1000:1000 -e HOME=/tmp/uhome`), since the VM
  user isn't guaranteed to be root. To re-test the build itself, delete the
  image first (`docker rmi airlock-claude:latest`) — the script only builds
  when it's missing.
- `airlock.local.toml` and `.airlock/` are runtime artifacts produced by
  running the script / by `airlock` itself — don't hand-edit
  `airlock.local.toml` as a source file; it's regenerated (clobbered) on
  every invocation of `airlock-claude`.
