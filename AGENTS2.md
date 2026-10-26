# AGENTS2.md

Guidance for coding agents working on `airlock-claude2` and
`test-airlock-claude2`. `AGENTS.md` covers the older `airlock-claude`.

## What it is

A single-file launcher, `airlock-claude2`, that runs Claude Code sandboxed
in an `airlock` VM in any directory, built on airlock's packs and
templates. It builds nothing and writes no config: airlock's setup wizard
picks the packs (or a template) on a project's first start, the script
imposes the deny-by-default policy on the launch line, and a short bash
prelude prepares the sandbox before every session. The shipped artifact is
that one script. `test-airlock-claude2` is its suite.

## Where the reasoning lives

The scripts carry no explanatory comments, deliberately. `README2.md`
holds what a user needs; this file holds everything else. Describe only
how things are now; history belongs in commit messages. Prefer encoding
reasoning in a name where a name can carry it.

## Structure and conventions to preserve

One function per step, defined in the order they run and called in that
order at the bottom, so the call sequence reads as a summary and a
data-flow diagram:

```
parse_args "$@"                      sets MONITOR, USE_TMUX, EXEC, REBUILD, SHOW_USAGE, CLAUDE_ARGS
validate_exec_usage <exec> <count>   -x needs a command after --
require_airlock
remove_sandbox_on_rebuild <rebuild>  `airlock remove --force`
sandbox_dir                          -> the sandbox directory `airlock info` reports, or nothing
keep_previous_pty_dump <dump>        sets last run's log aside as <dump>.previous
session_script <use_tmux>            -> the bash script that runs in the sandbox
    (the airlock start line — the handoff)
sandbox_dir                          again: a first run has no sandbox until airlock made one
print_pty_dump_tail <dump> <max>     -> the session's last lines, escape-stripped
```

- Keep new steps as functions in that same shape. **Whatever varies is a
  positional argument, named into a `local` on the first line; outputs
  are printed.** No step reads or writes script state.
- **`parse_args` is the one exemption: it sets its option globals
  directly.** Its output includes `CLAUDE_ARGS`, an arbitrary-argument
  array, which can't ride through stdout. It initializes every global it
  owns on its first line, so the defaults live in the function.
- **Failure is a nonzero `return` with a message on stderr; only the main
  sequence calls `exit`.** A function run inside `$( )` is a subshell,
  where `exit` would end only the subshell.
- `-h`/`--help` sets `SHOW_USAGE` and `break`s out; the main sequence
  calls `usage`. `break` rather than parsing on keeps `--help --bogus`
  exiting 0.
- The `airlock start` line is deliberately *not* in a function. Its exit
  status is captured into `AIRLOCK_EXIT`, the tail is printed, and the
  explicit `exit "$AIRLOCK_EXIT"` hands airlock's status through.
- `${MONITOR:+--monitor}` on that line is **unquoted on purpose**: an
  empty value has to disappear. `"${SESSION_COMMAND[@]}"` is quoted on
  purpose: each forwarded word stays one word.
- The tmux flag is `USE_TMUX`, not `TMUX`: tmux sets `TMUX` itself.
- There are no positive `-m`/`-t` flags; the defaults are on and the
  negatives turn them off.

## Why each step is the way it is

- **No config file is written, and that is what makes templates work.**
  A template can only be chosen in airlock's interactive setup wizard
  (`airlock start` has no `--template` flag), and the wizard runs only
  when the project has no config at all — no `airlock.toml`, no
  `airlock.local.toml`, no local project file in the sandbox directory.
  A script-written `airlock.local.toml` would suppress the wizard and
  with it every template. So the wizard's answers (packs, template,
  clipboard) are the sandbox's config, saved by airlock in the sandbox
  directory, and the project's own `airlock.toml` applies as usual.
- **The policy is `--network deny-by-default` on the launch line.** The
  flag overrides the configured policy for one run and writes nothing
  back; rules from the config still apply. It is the one thing the script
  must impose, and a flag is the only way to impose it without a file.
- **`require_airlock` runs after `parse_args`** so `--help` works on a
  machine without `airlock`.
- **`remove_sandbox_on_rebuild` goes through `airlock remove --force`.**
  The sandbox lives in airlock's data directory, where nothing the script
  could delete by path belongs to it. Removal also deletes the wizard's
  local config, so the next start runs the wizard again. A failure aborts
  the run: launching on the old sandbox would silently not be a rebuild.
  There is no `rm -rf .airlock`: a current airlock keeps nothing in the
  project.
- **`sandbox_dir` parses `airlock info --json` with `sed`, not `jq`**,
  because the host isn't guaranteed to have `jq`, and the pretty-printed
  JSON puts `"dir"` on a line of its own. It is called twice: before the
  launch for the rotation (a project with no sandbox yet yields nothing)
  and after, when a first run has a sandbox at last. Its stderr is
  silenced — "No sandbox for …" is the expected answer on a first run.
- **`session_script` builds the prelude on the host and the launch line
  passes it as the one argument of `bash -c`**, with `airlock-claude2` as
  the script's `$0` and the session command as its `"$@"`. Nothing is
  written into the project directory.
- **The prelude runs on every launch and is idempotent.** airlock
  re-creates the sandbox disk by itself when the image or the packs
  change, and a sandbox made by a plain `airlock start` has no tmux
  either; a "did the sandbox exist before" check on the host would miss
  both and launch a tmux that is not there. Instead: `command -v tmux ||
  apk add tmux`, and the files under `/etc` are rewritten each time (one
  heredoc each), so a changed text in a newer script reaches an existing
  sandbox without a `-r`. The tmux install is skipped under `-T`, and a
  failed install exits 1 before tmux is launched, so apk's own error is
  what the user sees rather than "tmux: not found". The `alpine` pack's
  `allow-apk` (default on) is what lets `apk add` through deny-by-default.
- **The wrapper is `bash -c`, not `sh -c`, because of `printf '%q '`.**
  tmux joins its command words with spaces and hands them to a shell, so
  a multi-word `-p "run the tests"` would split into words. Bash's `%q`
  re-quotes each word for that shell. The `claude` pack installs `bash` on
  Alpine, so it is always there.
- **`/etc/claude-code/managed-settings.json` is what puts the session in
  `bypassPermissions`**, with `skipDangerousModePermissionPrompt` so a new
  sandbox doesn't ask. Managed settings are the highest-precedence source,
  apply whichever user runs, and sit outside `~/.claude`, which the
  `claude` pack mounts from the host and shares between sandboxes —
  writing there would clobber the user's own settings. The launch line
  carries no permission flag.
- **`/etc/claude-code/CLAUDE.md` is Claude Code's managed-policy memory**,
  read into every session ahead of the user's and the project's. It is
  the right place for what Claude Code should know about *the sandbox*:
  the 403 the proxy answers denied requests with, that the user can allow
  traffic temporarily, that packages come from `apk` on musl, the Python
  `VERIFY_X509_STRICT` workaround (airlock's per-host leaf certificates
  carry no Authority Key Identifier; `pip` and `curl` are unaffected), to
  leave host-made virtualenvs alone, and to describe the present only.
- **The prelude is a quoted heredoc on the host, and the files it writes
  are quoted heredocs inside it with other delimiters.** Quotes,
  apostrophes and `$` in the content pass through both layers untouched.
  The suite extracts the script from the launch argv and runs `bash -n` on
  it.
- **`/etc/tmux.conf` sets `mouse on`, `set-clipboard on`, a
  `terminal-features` entry asserting OSC 52 for every terminal, and
  `default-terminal "tmux-256color"`.** `mouse on` doesn't cost panes
  their mouse. The `terminal-features` assertion is needed because tmux
  only emits OSC 52 for terminals it believes support it, and the host
  terminal on the far side of the VM isn't one it can recognise. `tmux -u`
  on the handoff forces UTF-8 output regardless of the locale; Alpine's
  musl libc is UTF-8 anyway, but the flag is what keeps Claude Code's
  box-drawing intact if that ever changes.
- **`AIRLOCK_PTY_DUMP=1` is an env prefix on the launch line.** It is read
  by the airlock CLI on the host, which writes every byte of the guest
  pty to `pty.dump` in the sandbox directory, truncating at each start.
  `keep_previous_pty_dump` runs immediately before the launch for that
  reason; one `.previous` generation is kept, best-effort.
- **`print_pty_dump_tail` runs after `airlock start` returns and goes to
  stderr.** After, because the monitor and tmux restore the host screen on
  exit; stderr so `claude -p` stdout stays clean. A missing or empty dump
  prints nothing.
- **`strip_terminal_escapes` is best-effort text recovery, not a terminal
  emulator.** CR becomes LF first so overprinted lines land as separate
  lines with the final state last; then OSC, DCS/SOS/PM/APC, CSI,
  charset-select and remaining two-byte ESC sequences are stripped, in
  that order — the two-byte catchall must come last. `LC_ALL=C` keeps sed
  and tr byte-oriented so UTF-8 passes through. `tail -c 65536` in the
  caller bounds the work.
- **The script runs `airlock` with the user's own `HOME`, untouched**, so
  `airlock start` and the user's own `airlock info`/`remove` agree on
  which sandbox is theirs.

## Non-obvious behavior

- **The wizard needs a terminal.** A project's first run must be
  interactive; a `-p` run in a project with no sandbox stops with
  airlock's "no config, no terminal" error.
- **The `claude` pack owns the install, the updates, the tokens and
  `~/.claude`.** `claude update` works inside the session; a new sandbox
  gets the newest version. A sign-in is shared by every sandbox with the
  pack, and a logout in one signs out all.
- **`airlock remove` under `-r` discards whatever lived on the sandbox
  disk**, apk packages included. `~/.claude` is a host mount and survives.
- **The theme is not resolved.** Claude Code's `auto` resolves dark inside
  the VM (its OSC 11 query stops at tmux). Pass `-- --settings
  '{"theme":"light"}'` if that matters.

## Working on the script

- Run `./test-airlock-claude2` after any change. It drives the real
  script against a stub `airlock` on a PATH built from scratch, so it
  needs no `airlock`, no network, and finishes in about a second. `-v`
  echoes each case's captured output. Add cases in the same shape when
  you add behavior.
- What the suite cannot reach: anything that boots a VM. The prelude is
  checked as *text* (it reaches `bash -c`, parses under `bash -n`, writes
  the expected files, ends with the expected `exec`); nothing verifies
  that `apk add tmux` succeeds, that the files land, or that airlock
  accepts the launch. For those, run `./airlock-claude2` on a machine
  with the `airlock` CLI.
- `README2.md` is the user-facing description. A change to flags or the
  launch line usually needs an edit there too.

## Working on the test suite

- **Every case runs in its own temp working directory, and no case may
  `cd` into this repo.** The `airlock` stub keeps its pretend sandbox at
  `STUB_BOX`, under the case directory; its `info` answers with that path
  and its `remove` deletes it, as the real one does.
- **`PATH` is rebuilt from scratch for each case** — the stub plus a
  symlink directory (`TOOLS`) of the real tools the script and the stub
  shell out to. A tool the script newly uses has to be added to `TOOLS`,
  or every case that reaches it fails in a way that looks like the
  feature is broken.
- **The stub writes the `bash -c` script argument to
  `$CASE_DIR/session-script`** (the `SESSION_SCRIPT` helper names it) and
  logs the argv with the script replaced by `<script>`, so launch
  assertions stay one line and the prelude is checked as a file. Only the
  first `-c` is taken, so a forwarded `sh -c …` isn't mistaken for it.
- **Stubs read their behavior from exported env vars** (`STUB_PTY_DUMP`,
  `STUB_EXIT`, `STUB_REMOVE_EXIT`, `STUB_NO_SANDBOX`, `DUMP_ARGV`), reset
  in `new_case`.
- **A missing stub is expressed as `stub_all_but_airlock`**, never as an
  omitted call.
- **`assert_not_grep` fails on a missing file rather than passing.**
- Assertion labels carry the intent of each case; write them as the claim
  being tested, not as a description of the mechanics.
