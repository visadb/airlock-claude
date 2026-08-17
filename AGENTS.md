# AGENTS.md

Guidance for coding agents working in this repository.

## What this repo is

A single-file launcher script, `airlock-claude`, whose purpose is to run
Claude Code sandboxed inside an `airlock` VM in *any* directory with zero
manual setup — no per-project image, no hand-written `airlock` config. Run
from a directory, the script builds what it needs, generates config on the
fly, and launches Claude Code with network access denied by default. The
shipped artifact is that one bash script — there is no build system and no
package manifest. `test-airlock-claude` sits alongside it as a test suite but
is not part of what you drop on `PATH`.

## Where the reasoning lives

The scripts carry no explanatory comments, deliberately. `README.md` holds
everything a user of the script needs to know; this file holds everything
else — why each step is shaped the way it is, and which properties an edit
must not break. Anything the code cannot say for itself is written down in one
of those two files and nowhere else.

Keep it that way. When a change needs an explanation, put the explanation
here (or in `README.md` if a user would want it) rather than in a comment, and
prefer encoding it in a name where a name can carry it — `USE_TMUX`,
`config_in_precedence_order` and `/tmp/.airlock-claude-updated-this-boot` all
exist in that shape on purpose. Don't copy reasoning from here back into the
code; two copies drift.

## Structure and conventions to preserve

The script is a sequence of one-function-per-step, defined in the order they
run and called in that order at the bottom, so the call sequence at the end
reads as a summary of the whole thing:

```
parse_args              # -M/-T/-r/-h and their long forms; nothing is forwarded to claude
require_airlock         # before the build, so -r can't spend minutes then fail at the last line
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
- Both `${MONITOR:+--monitor}` and `${USE_TMUX:+tmux -u new-session -A -s claude}`
  on that line are **unquoted on purpose**: an empty one has to disappear
  entirely rather than become an empty argument. Quoting them "to satisfy
  shellcheck" breaks `-M` and `-T`, and the suite's exact-argv assertions catch
  it.
- Only `IMAGE` and the handles that outlive their function are global:
  `REBUILD`, `MONITOR`, `USE_TMUX`, `OCI`, and `SHIM_DIR` (the last because the
  `EXIT` trap fires long after `pick_container_engine` has returned).
  Everything else is `local`.
- The tmux flag is `USE_TMUX`, not `TMUX`: tmux sets `TMUX` itself to mark a
  shell as being inside a session, so a variable of ours by that name would be
  read as that one.
- The Dockerfile is an inline heredoc inside `build_image_if_needed`. Its
  `ARG GIT_USER_NAME`/`GIT_USER_EMAIL` pair stays last so a changed git
  identity doesn't invalidate the cached Claude Code install above it.

## Why each step is the way it is

- **`require_airlock` runs after `parse_args` and before the build.** After
  `parse_args`, so `--help` still works on a machine without `airlock`
  installed; before the build, because under `-r` the build spends minutes on
  `--no-cache --pull` first, and failing after that would hand the user
  `airlock: command not found` in exchange for the wait.
- **`pick_container_engine` shims `docker` when only podman is present**
  because `airlock` always shells out to a literal `docker` command. The shim
  directory is created with an explicit `mktemp` template: bare `mktemp -d` is
  a GNU convenience, and BSD `mktemp` — what macOS ships — requires the
  template. macOS is the case that reaches this path, since podman is the usual
  engine there.
- **`drop_vm_cache_on_rebuild` exists because `airlock` caches the VM disk it
  converts from the OCI image** under `.airlock`, so a freshly built image goes
  unused until that cache is gone.
- **`generate_airlock_config` builds `skip_update_line` above the heredoc and
  expands it inside `[env]`** rather than appending the key after the fact. An
  appended key joins whichever table ends up last, so adding a table below
  `[env]` would silently move it out and stop the opt-out reaching the VM.
- **A failed config write exits instead of falling through to the launch.**
  Otherwise `airlock` would start on whatever `airlock.local.toml` a previous
  run left in the directory, or on its own defaults, and the deny-by-default
  policy this script exists to impose would silently not be the one in effect.
- **`keep_home_on_working_filesystem` guards on the answer looking like an
  absolute path** because `df --output` is GNU-only — BSD `df` rejects it, so a
  Mac without coreutils' `gdf` gets no answer at all. An unguarded assignment
  would export an empty `HOME`, which relocates `HOME` without putting it on
  the working filesystem: the same failure the function exists to prevent,
  reached by another route.

## The Dockerfile

`README.md` explains the parts a user sees — the `ncurses-term` trap, the
`en_US.UTF-8` locale and `tmux -u`, the mouse and clipboard settings, and the
permission bypass. What it doesn't cover:

- **`DEBIAN_FRONTEND` is scoped to the `RUN` command** rather than set as an
  `ENV`, so it doesn't follow the image into the session. `locales` is the one
  package here with anything to ask.
- **`/etc/locale.gen` is overwritten, not appended to**, so exactly one locale
  is built.
- **`CLAUDE_INSTALL_HOME=/opt/claude` is a fixed path outside any home
  directory**, so the launcher path doesn't depend on which user the VM ends up
  running as, and the tree is left world-writable (`chmod -R a+rwX`) so a
  non-root VM user can still update it. The VM user isn't guaranteed to be
  root.
- **`/opt/claude/.local/bin` is *appended* to `PATH`, not prepended.**
  `/usr/local/bin` has to stay ahead so `claude` resolves to the wrapper, but
  having the install directory on `PATH` at all stops Claude Code warning about
  it on every update.
- **The wrapper overrides `HOME` for the update only**, so the updater resolves
  the image's install rather than the VM user's home. The session itself keeps
  the real `HOME`, which is where its config and credentials live.
- **The update runs once per VM boot**, gated on a stamp file in `/tmp`:
  nested `claude` calls must not swap the binary out from under a running
  session.

## Non-obvious behavior

Things that aren't visible from the script at all:

- **The first build's working directory decides the baked-in git identity.**
  The host identity is read with `git config --list --includes`, which picks up
  *repo-local* config — so whichever directory you happen to run the first
  build from is what gets written into the image's `/etc/gitconfig`. The list
  is printed in *increasing* precedence order, which is why the script takes
  the last occurrence of each key. It's captured at build time, so changing the
  identity on the host needs a `-r` rebuild to take effect.
- **The wrapper's update output goes to stderr on purpose**, so `claude -p`
  stdout stays clean for scripting. A failed update is non-fatal — the session
  falls back to the version baked into the image.
- **`DISABLE_AUTOUPDATER=1` in the generated config only disables the
  *background* autoupdater.** It does not affect the explicit `claude update`
  the image's wrapper runs at startup; that update reaches the network because
  the `claude-code` preset already allows `downloads.claude.ai:443` under the
  deny-by-default policy.
- **The permission bypass is in the image, not on the launch line.** The last
  line runs `claude` with no permission flag; what puts the session in
  `bypassPermissions` mode is `/etc/claude-code/managed-settings.json`, written
  by the Dockerfile. Same reasoning as `/etc/gitconfig` and `/etc/tmux.conf` —
  it applies whichever user the VM runs as, and being outside `HOME` it isn't
  displaced when `airlock` populates the VM's home from the host's — except
  that managed settings are the *highest*-precedence source, so a host
  `~/.claude/settings.json` can't override it. The consequence for the launcher
  is that an image built before this existed starts with prompts on, and `-r`
  is the fix.
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

- Run `./test-airlock-claude` after any change. It drives the real script
  against stub `docker`/`podman`/`airlock`/`df`/`git` binaries on a PATH built
  from scratch, so it needs no container engine, no `airlock`, and no network,
  and finishes in about a second. `-v` echoes each case's captured output.
  Exit status is the result; add cases in the same shape when you add behavior.
- What the suite cannot reach: anything that requires actually building the
  image or booting a VM. The Dockerfile is only checked as *text* (it reaches
  the build on stdin, starts at the right base, keeps the `ARG` pair below the
  install layer) — nothing verifies it builds, that the wrapper updates, or
  that airlock accepts the generated config. For those, run `./airlock-claude`
  directly on a machine with `docker` or `podman` and the `airlock` CLI.
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

## Working on the test suite

- **Every case runs in its own temp working directory, and no case may `cd`
  into this repo.** The script writes `airlock.local.toml` into the current
  directory and does `rm -rf .airlock` under `-r`, so a case that ran here
  would clobber files.
- **`PATH` is rebuilt from scratch for each case** — the stubs plus a symlink
  directory (`TOOLS`) of the handful of real tools the script shells out to —
  so a `docker` or `airlock` installed on the host can't leak in and quietly
  turn a stub assertion into a real invocation. `df` is left out of `TOOLS` on
  purpose, so `stub_all_but_df` can withhold it entirely; the `df` stub is the
  only source of it.
- **Stubs read their behavior from exported env vars** (`STUB_IMAGE_MISSING`,
  `STUB_BUILD_FAILS`, `DF_MODE`, `PROBE_DOCKER`), which is what lets them be
  written once as literal heredocs and varied per case. `new_case` resets them
  all.
- **A missing stub is expressed as a `stub_all_but_*` helper**, never as
  omitted calls, because the absence is otherwise invisible at the call site.
- **`assert_not_grep` fails on a missing file rather than passing.** An
  absent-by-typo path would otherwise satisfy every "should not contain"
  assertion in the suite.
- Assertion labels carry the intent of each case — they are what a reader sees
  on failure, so write them as the claim being tested ("`--no-monitor` drops
  the monitor flag"), not as a description of the mechanics.
