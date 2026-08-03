# AGENTS.md

Guidance for coding agents working in this repository.

## What this repo is

A single-file launcher script, `airlock-claude`, whose purpose is to run
Claude Code sandboxed inside an `airlock` VM in *any* directory with zero
manual setup — no per-project image, no hand-written `airlock` config. Run
from a directory, the script builds what it needs, generates config on the
fly, and launches Claude Code with network access denied by default. The
entire repo is this one bash script — there is no build system, package
manifest, or test suite.

The script is heavily commented, and those comments are the primary
explanation of *why* each piece is the way it is. Read it before editing;
this file covers only what the script can't tell you itself.

## Structure and conventions to preserve

The script is a sequence of one-function-per-step, defined in the order they
run and called in that order at the bottom, so the call sequence at the end
reads as a summary of the whole thing:

```
parse_args              # -r/--rebuild-image and -h/--help; nothing is forwarded to claude
pick_container_engine   # docker, else podman behind a `docker` shim
build_image_if_needed   # airlock-claude:latest from an inline Dockerfile
drop_vm_cache_on_rebuild
generate_airlock_config # writes airlock.local.toml
keep_home_on_working_filesystem   # so airlock's hardlinks out of HOME can't cross a filesystem
```

- Keep new steps as functions in that same defined-in-call-order shape.
- The `airlock start` line is deliberately *not* in a function — it's the
  handoff, and keeping it at top level means "what does this script ultimately
  run?" is answered by the last line.
- Only `IMAGE` and the handles that outlive their function are global:
  `REBUILD`, `OCI`, and `SHIM_DIR` (the last because the `EXIT` trap fires long
  after `pick_container_engine` has returned). Everything else is `local`.
- The Dockerfile is an inline heredoc inside `build_image_if_needed`. Its
  `ARG GIT_USER_NAME`/`GIT_USER_EMAIL` pair stays last so a changed git
  identity doesn't invalidate the cached Claude Code install above it.

## Non-obvious behavior

Things that aren't visible from the script or its comments:

- **The first build's working directory decides the baked-in git identity.**
  The host identity is read with `git config --list --includes`, which picks up
  *repo-local* config — so whichever directory you happen to run the first
  build from is what gets written into the image's `/etc/gitconfig`. It's
  captured at build time, so changing the identity on the host needs a `-r`
  rebuild to take effect.
- **The wrapper's update output goes to stderr on purpose**, so `claude -p`
  stdout stays clean for scripting. A failed update is non-fatal — the session
  falls back to the version baked into the image.
- **`DISABLE_AUTOUPDATER=1` in the generated config only disables the
  *background* autoupdater.** It does not affect the explicit `claude update`
  the image's wrapper runs at startup; that update reaches the network because
  the `claude-code` preset already allows `downloads.claude.ai:443` under the
  deny-by-default policy.
- **`airlock` forwards only the env vars the config names**, which is why a
  host `AIRLOCK_CLAUDE_SKIP_UPDATE` has to be written into `[env]` to reach the
  VM at all.
- **The `HOME` redirect exists because `airlock` hardlinks files out of `HOME`**
  into its per-directory state, and a hardlink can't cross a filesystem
  boundary. btrfs subvolumes are the case that surprises people: one mount, but
  separate filesystems as far as `link(2)` is concerned, so the links fail with
  `EXDEV`. Repointing `HOME` at the working directory's filesystem root is what
  puts source and destination on one filesystem. Anything that changes that
  function has to keep that property — it's not about where config is *findable*.

## Working on this script

- There is no build, lint, or test command — validate changes by running
  `./airlock-claude` directly. This requires `docker` or `podman` and the
  `airlock` CLI in `PATH` (a host `claude` is no longer needed).
- To iterate on the image without launching a session, extract the Dockerfile
  heredoc, build it by hand, and probe it with
  `docker run --rm ... claude --version`. Check the non-root case too
  (`--user 1000:1000 -e HOME=/tmp/uhome`), since the VM user isn't guaranteed
  to be root.
- To re-test the build path itself, run `./airlock-claude -r` (or delete the
  image with `docker rmi airlock-claude:latest`) — a plain run only builds when
  the image is missing. Note `-r` is a full `--no-cache --pull` build, so it
  takes minutes, not seconds.
- `airlock.local.toml` and `.airlock/` are runtime artifacts produced by
  running the script / by `airlock` itself, and both are gitignored —
  `.airlock/` holds the VM disk, so it must never reach a commit. Don't
  hand-edit `airlock.local.toml` as a source file either; it's regenerated
  (clobbered) on every invocation of `airlock-claude`.
- `README.md` is the user-facing description of the same script. A change to
  flags, prerequisites, or the launch line usually needs an edit there too.
