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
reads as a summary of the whole thing — and, because every step takes its
inputs as arguments and hands back its result on stdout, as a data-flow
diagram too:

```
parse_args "$@"                             sets REBUILD, MONITOR, USE_TMUX, REMOTE_CONTROL, THEME, SHOW_USAGE, CLAUDE_ARGS
require_airlock                                 before the build, so -r can't spend minutes then fail at the last line
resolve_theme <flag_theme> <env_theme> <colorfgbg>  -> theme for claude's --settings, or nothing
pick_container_engine                       -> docker | podman
create_docker_shim                          -> a directory holding a `docker` that runs podman
build_image_if_needed <engine> <rebuild>        $IMAGE from an inline Dockerfile
drop_vm_cache_on_rebuild <rebuild>
generate_airlock_config <skip_update> <remote_control>  writes airlock.local.toml
home_on_working_filesystem <current_home>   -> the HOME to run airlock with
```

- Keep new steps as functions in that same defined-in-call-order shape.
- **Whatever varies is a positional argument, named into a `local` on the
  first line of the function; outputs are printed.** No step function reads or
  writes script *state*, so its whole contract is visible at the call site.
  When a step needs a value from the environment
  (`AIRLOCK_CLAUDE_SKIP_UPDATE`, `HOME`), the main sequence reads it and passes
  it in.
- **`parse_args` is the one deliberate exemption from that rule: it sets its
  option globals directly instead of printing them.** Its output includes an
  arbitrary-argument array — `CLAUDE_ARGS`, the arguments after `--`,
  forwarded verbatim to `claude` — and arbitrary user strings can't ride
  safely through a delimiter-joined stdout channel, while a bash array can't
  be returned through stdout at all. Setting globals from a function that runs
  in the main shell is the standard bash idiom for this. It initializes every
  global it owns on its first line, so the defaults live in the function.
- **Global constants are the exception: `IMAGE` is used where it's needed
  rather than threaded through arguments.** It never varies, so passing it
  would document nothing and only make the call sites longer.
- **Failure is a nonzero `return` with a message on stderr; only the main
  sequence calls `exit`.** That isn't just tidiness: a function that runs
  inside `$( )` runs in a subshell, where `exit` ends only the subshell and
  the script carries on regardless. Every step is written to be safe to
  capture.
- The main sequence owns all remaining script state — `CONTAINER_ENGINE`,
  `SHIM_DIR`, `HOME`, `THEME` — assigned from the values the steps return; the
  option globals (`REBUILD`, `MONITOR`, `USE_TMUX`, `REMOTE_CONTROL`, `THEME`,
  `SHOW_USAGE`) are assigned by `parse_args` itself, per the exemption above.
  `THEME` appears in both lists the way `HOME` does: `parse_args` seeds it
  with the `--theme` value and the main sequence reassigns it from
  `resolve_theme`, which folds in the env variable and the detection.
- `SHIM_DIR`, the `EXIT` trap that removes it, and the `PATH` that points at it
  are set at top level rather than inside `create_docker_shim`. A trap and an
  export have to be made by the shell that goes on running, and a trap set
  inside a command substitution would fire when that subshell ended — deleting
  the shim before it was ever used.
- `-h`/`--help` sets `SHOW_USAGE` and `break`s out; the main sequence is what
  calls `usage`, keeping `parse_args` pure parsing. `break` rather than
  continuing to parse is what keeps `--help --bogus` exiting 0, as it did when
  `--help` exited from inside the loop.
- The `airlock start` line is deliberately *not* in a function — it's the
  handoff, and keeping it at top level means "what does this script ultimately
  run?" is answered by the last line.
- The `${MONITOR:+--monitor}`, `${USE_TMUX:+tmux -u new-session -A -s claude}`,
  `${REMOTE_CONTROL:+...}` and `${THEME:+...}` expansions on that line are
  **unquoted on purpose**: an empty one has to disappear entirely rather than
  become an empty argument. Quoting them "to satisfy shellcheck" breaks `-M`,
  `-T`, `-c` and the theme, and the suite's exact-argv assertions catch it.
  Inside `${THEME:+...}` the escaped quotes around the settings JSON are the
  opposite and load-bearing the other way: they keep `{"theme":"dark"}` one
  word through the unquoted expansion, and the suite's `ARGV` dump asserts
  that too. The theme sits before `"${CLAUDE_ARGS[@]}"` so a user-forwarded
  `--settings` can override it wherever `claude` resolves a repeat last-wins. `"${CLAUDE_ARGS[@]}"`
  at the end is the opposite, quoted on purpose: a quoted `[@]` expansion
  keeps each forwarded argument exactly one word — a multi-word `-p` prompt
  included — and an empty array still vanishes rather than becoming an empty
  argument, because `"${arr[@]}"` of an empty array expands to zero words.
  It sits last so the user's arguments can override what the wrapper adds
  wherever `claude` resolves a repeated flag last-wins.
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
- **`resolve_theme` settles dark-versus-light on the host because Claude
  Code's own detection can't.** Claude Code asks its terminal for the
  background colour with an OSC 11 query, but from inside the VM that query
  stops at tmux, which doesn't forward it to the host terminal, so the
  sandboxed session guesses. The host side can ask, with the same query, so
  the script does — before handing the terminal to `airlock`. The probe
  order encodes trust: an actual terminal answer outranks the macOS
  appearance (dark terminals on light desktops are common), which outranks
  the `COLORFGBG` heuristic (set once at terminal startup and often stale).
  An empty result means no `--settings` flag at all, so claude's own
  persisted theme stands rather than being stomped by a default.
- **The theme rides on `--settings '{"theme":…}'` rather than in any file.**
  `managed-settings.json` is baked at image build, which would freeze the
  theme until a `-r`; the VM's `~/.claude` is the user's own persisted state
  (mounted from `~/.airlock/claude`), and writing there would permanently
  clobber a choice they made in-session. The per-invocation flag scopes the
  override to the launch, which is exactly the scope the theme has on the
  host. It runs early, next to `require_airlock`, so a typo'd `--theme`
  fails before a build can spend minutes.
- **`theme_from_terminal_background` gates on `-t 0 && -t 2`, not `-t 1`.**
  `resolve_theme` runs inside `$( )`, where stdout is the capture pipe, so
  `-t 1` would be false precisely when the script is used normally; stderr
  is the stream still pointing at the terminal. The gate is also what keeps
  the suite — which redirects both — from sending real escape queries at
  whatever terminal runs the tests.
- **The OSC reply `read` uses an integer `-t 1` on purpose**: macOS
  `/bin/bash` is 3.2, where a fractional timeout is an error, and the
  `#!/bin/bash` shebang resolves to it there. The full second is only ever
  waited out by a terminal that answers BEL-terminated or not at all —
  `read -d '\'` returns the moment an ST terminator's backslash arrives, and
  on timeout it still hands over what it consumed, which is why a
  BEL-terminated reply parses anyway (`channel_as_8_bit` strips the trailing
  terminator as non-hex).
- **`create_docker_shim` exists because `airlock` always shells out to a
  literal `docker` command**, so a podman-only host needs something by that
  name to forward to podman. The shim directory is created with an explicit
  `mktemp` template: bare `mktemp -d` is a GNU convenience, and BSD `mktemp` —
  what macOS ships — requires the template. macOS is the case that reaches this
  path, since podman is the usual engine there.
- **`drop_vm_cache_on_rebuild` exists because `airlock` caches the VM disk it
  converts from the OCI image** under `.airlock`, so a freshly built image goes
  unused until that cache is gone.
- **`generate_airlock_config` builds `skip_update_line` above the heredoc and
  expands it inside `[env]`** rather than appending the key after the fact. An
  appended key joins whichever table ends up last, so adding a table below
  `[env]` would silently move it out and stop the opt-out reaching the VM.
  Under `-c` there *is* a table below `[env]` — the middleware override — which
  is exactly why the opt-out has to stay lexically inside `[env]`, above it;
  the suite asserts that placement.
- **`-c` disables the preset's `claude-auth-token` middleware in the generated
  config; clearing the env var alone would not be enough.** The middleware's
  `env.TOKEN = "${CLAUDE_CODE_OAUTH_TOKEN}"` template resolves from the host
  env with the airlock secret vault as fallback, and airlock *aborts
  `airlock start` when it resolves in neither* — so without the override, `-c`
  would fail on precisely the machine it exists for, one with no token set up.
  And when the token does resolve, the middleware overwrites the
  `Authorization` header on every `api.anthropic.com` request, stomping the
  credentials of the interactive login `-c` exists to enable. `enabled = false`
  on the preset's named entry is airlock's supported override mechanism: local
  config merges over presets, and a disabled middleware is skipped before its
  templates are ever resolved.
- **The placeholder token is cleared with `env -u` on the launch line, not in
  the config.** The placeholder comes from the preset's `[env]` table, and
  airlock's config merge cannot *remove* a key a preset set — later files can
  only override values, and a `null` never overwrites — so the variable is
  stripped at exec time instead. It has to go entirely: Claude Code treats a
  present `CLAUDE_CODE_OAUTH_TOKEN` as its credential and skips interactive
  login, which is what breaks `--remote-control` in the first place. The login
  that `-c` forces lands in `~/.claude`, which the preset persists to
  `~/.airlock/claude/settings` on the host, so it survives across runs.
- **A failed config write aborts the run instead of falling through to the
  launch.** Otherwise `airlock` would start on whatever `airlock.local.toml` a
  previous run left in the directory, or on its own defaults, and the
  deny-by-default policy this script exists to impose would silently not be the
  one in effect.
- **`home_on_working_filesystem` echoes back the `HOME` it was given unless
  `df` produced something that looks like an absolute path**, because
  `df --output` is GNU-only — BSD `df` rejects it, so a Mac without coreutils'
  `gdf` gets no answer at all. Printing the answer unguarded would set `HOME`
  to the empty string: `HOME` relocated, but not onto the working filesystem,
  which is the failure this step exists to prevent, reached by another route.

## The Dockerfile

`README.md` explains the parts a user sees — the `en_US.UTF-8` locale and
`tmux -u`, the mouse and clipboard settings, and the permission bypass. What
it doesn't cover:

- **`DEBIAN_FRONTEND` is scoped to the `RUN` command** rather than set as an
  `ENV`, so it doesn't follow the image into the session. `locales` is the one
  package here with anything to ask.
- **`/etc/locale.gen` is overwritten, not appended to**, so exactly one locale
  is built.
- **`ncurses-base` is reinstalled immediately after `ncurses-term`.**
  `ncurses-term` is there for the Alacritty terminfo entries (`alacritty`,
  `alacritty+common`, `alacritty-direct`), but installing it on this image
  makes the entries `ncurses-base` owns disappear from the filesystem,
  `xterm-256color` and `tmux-256color` included, and `tmux` then refuses to
  start. The packages don't overlap, so a plain install shouldn't be able
  to do that; the working theory is that it's an artefact of the virtiofs +
  overlayfs stack airlock builds images on, not of `apt` itself. It isn't
  understood, only observed. Reinstalling `ncurses-base` afterward restores
  its entries, so that's the fix. The order matters: the reinstall has to
  come *after* `ncurses-term`, in the same `RUN` so the apt lists are still
  present, and before they're deleted. `--reinstall` is what makes apt
  touch a package that's already at the wanted version.
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
- **`/etc/claude-code/CLAUDE.md` is Claude Code's managed-policy memory**,
  the memory-file counterpart of `managed-settings.json`: Claude Code reads
  it into every session on the machine, whichever user runs it, ahead of
  `~/.claude/CLAUDE.md` and the project's. It was confirmed to load for
  `claude -p` too, by writing a probe word there and asking for it. It's the
  right place for anything Claude Code should know about *the sandbox* rather
  than about a project, because the alternatives don't work from a launcher:
  `~/.claude` in the VM is the host's `~/.airlock/claude/settings`, which the
  user owns and the `claude-code` preset mounts in — writing a `CLAUDE.md`
  there would clobber theirs — and a project `CLAUDE.md` would mean writing
  into every directory the script is run from.
- **The content written with `printf '%s\n' '...'` must contain no
  apostrophe.** Each line is a single-quoted shell word inside a `RUN`, so an
  apostrophe ends the quote and the build fails at that layer. The suite
  greps for the shape and also runs every `RUN` command through `sh -n`, so
  a bad line fails in a second rather than after a multi-minute build.

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
- **Python HTTPS fails in the sandbox because of `VERIFY_X509_STRICT`, not a
  missing CA.** Every Python client (`urllib`, `http.client`, `urllib3`,
  `requests`, `httpx`, `aiohttp`) rejects the proxy's certificates with
  `Missing Authority Key Identifier`; Python 3.13+ sets the strict flag in
  `ssl.create_default_context()`, and the leaf certificates `airlock` mints
  per host (`get_or_create_config` in `app/airlock-cli/src/network/tls.rs`,
  built from `rcgen::CertificateParams::new` with nothing but a CN and a SAN)
  carry no AKI extension. `pip` and `curl` are unaffected. `SSL_CERT_FILE`
  changes nothing, since `/usr/lib/ssl/cert.pem` already resolves to the
  merged bundle. The managed `CLAUDE.md` carries the per-client workaround
  (a context with the flag cleared), each recipe verified against pypi.org
  from inside the VM. The real fix is upstream in `airlock`: have the leaf
  certificates carry an Authority Key Identifier — in `rcgen` that's
  `use_authority_key_identifier_extension = true` on the leaf's params,
  with the CA carrying a Subject Key Identifier — after which the note can
  go. A `sitecustomize.py` in the image that clears the flag globally was
  considered and rejected: it wouldn't reach virtualenvs, which don't see the
  base `site-packages`, and would only paper over the gap for the base
  interpreter.
- **`airlock` forwards only the env vars the config names**, which is why a
  host `AIRLOCK_CLAUDE_SKIP_UPDATE` has to be written into `[env]` to reach the
  VM at all. `AIRLOCK_CLAUDE_THEME` deliberately isn't in `[env]`: nothing in
  the VM reads it — it's consumed on the host by `resolve_theme` and delivered
  as a `claude` flag instead.
- **The theme only applies when tmux creates the session.** `new-session -A`
  attaches to an existing session named `claude` and ignores the rest of its
  command line, so on the rare path where a previous session is still alive,
  a changed host theme (like any changed `claude` flag) waits for the next
  fresh session.
- **Claude Code's `theme=auto` always resolves dark inside the VM, and no
  config can change that** — verified against claude 2.1.273 and tmux 3.5a
  by running each under a scripted pty. Auto detection is one OSC 11
  background query (`ESC ] 11 ; ? ESC \`, observed ~0.3s after launch)
  answered with `rgb:RRRR/GGGG/BBBB`; when no answer arrives, dark is the
  default. Inside the VM no answer can arrive: tmux neither forwards an
  application's OSC 11 query to its outer terminal nor answers it from what
  it knows — tested with the outer terminal answering tmux's own background
  query (tmux does ask at attach, then never shares the answer) and with an
  explicit `window-style bg=`, both ignored — and on the `-T` path the query
  stops at airlock's monitor pty instead. Nor is there another way to hand
  claude the answer: no env variable or settings key carries a background
  colour (a `CLAUDE_THEME` env var is an open upstream request,
  anthropics/claude-code#10074). A query-answering pty shim inside the image
  was considered and rejected: to answer it would need the host's background
  colour — everything `resolve_theme` already does — plus a new moving part
  in the image. That dead end is why the theme is resolved on the host at
  all. If tmux ever answers OSC 11 on behalf of its client, or the monitor
  passes queries through, auto would work end-to-end and `resolve_theme`
  could go. One unresolved observation from the same harness: claude's
  onboarding theme picker rendered byte-identically whether the query was
  answered light, dark, or not at all — the reply was consumed but never
  changed the UI, and the logged-in REPL wasn't reachable headless, so auto
  may be dark-pinned in more places than tmux.
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
  install layer, and every `RUN` parses as shell) — nothing verifies it
  builds, that the wrapper updates, or that airlock accepts the generated
  config. For those, run `./airlock-claude`
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
