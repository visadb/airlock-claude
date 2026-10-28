# AGENTS.md

Guidance for coding agents working in this repository.

## What it is

A single-file launcher, `airlock-claude`, that runs Claude Code sandboxed
in an `airlock` VM in any directory, built on airlock's packs and
templates. It builds nothing and writes no config but its one marked block:
airlock's setup wizard picks the packs (or a template) on a project's
first start, the script imposes the deny-by-default policy on the launch
line, and a short bash prelude prepares the sandbox before every session.
The shipped artifact is that one script. `test-airlock-claude` is its
suite.

## Where the reasoning lives

The scripts carry no explanatory comments, deliberately. `README.md`
holds what a user needs; this file holds everything else. Describe only
how things are now; history belongs in commit messages. Prefer encoding
reasoning in a name where a name can carry it.

## Structure and conventions to preserve

One function per step, defined in the order they run and called in that
order at the bottom, so the call sequence reads as a summary and a
data-flow diagram:

```
parse_args "$@"                      sets MONITOR, USE_TMUX, EXEC, REBUILD, REMOTE_CONTROL, SHOW_USAGE, CLAUDE_ARGS, MOUNTS_RW, MOUNTS_RO
validate_exec_usage <exec> <count>   -x needs a command after --
require_airlock
resolve_extra_mounts                 sets MOUNT_SOURCES, MOUNT_TARGETS, MOUNT_READ_ONLY (the array exemption)
without_config_block <file>          -> the file minus the block (1: unreadable, 2: no END line)
project_config_present               -> 1 if the project has config the wizard would respect, or nothing
sandbox_dir                          -> the sandbox directory `airlock info` reports, or nothing
refuse_config_without_sandbox <count> <remote_control> <rebuild> <sandbox_dir> <has_config>
remove_sandbox_on_rebuild <rebuild>  `airlock remove --force`
extra_mounts_config                  -> the [mounts] tables, or nothing (reads the arrays)
sandbox_dir                          again, for -c's Claude Code directory
remote_control_config <remote_control> <sandbox_dir>  -> -c's tables, or nothing
config_block <mounts> <remote_control>                -> the marked block around both, or nothing
write_config_block <block>           rewrites the block in airlock.local.toml, or removes the file
sandbox_dir                          again, for the rotation
keep_previous_pty_dump <dump>        sets last run's log aside as <dump>.previous
session_script <use_tmux> <remote_control>  -> the bash script that runs in the sandbox
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
  `resolve_extra_mounts` and `extra_mounts_config` share the exemption for
  the same reason: the resolved mounts are three parallel arrays, set by
  the one and read by the other.
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

- **The script writes no config except its marked block, and that is
  what makes templates work.**
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
- **The mounts and the `-c` settings are one marked block of
  `airlock.local.toml`, rewritten on every run.** `airlock start` has no
  mount or service flag, so a config file is the only way in, and
  `airlock.local.toml` is the one airlock reads but a project doesn't
  commit. The block is bounded by `# BEGIN airlock-claude config` and
  `# END airlock-claude config` so the script can replace
  exactly its own lines and leave a hand-written file's other content
  alone; the BEGIN line says the block is rewritten, so a user editing the
  file knows not to edit inside it. A run without mount flags or `-c` removes the
  block, and a file left holding only whitespace is removed with it —
  otherwise a leftover file would suppress the wizard after `-r`. That
  rule applies after a block was stripped: a whitespace-only file the
  script did not write is kept, and a run without mount flags or `-c` leaves a
  file that holds no block byte-identical, so a hand-written
  `airlock.local.toml` is never rewritten just because the script ran. A
  `# BEGIN` line without its `# END` line is refused with a message and
  exit 1 rather than stripped to the end of the file; the reader
  (`without_config_block`) is pure bash and reports status 1 for
  unreadable, 2 for unterminated. Under `-r` that refusal happens after
  `airlock remove`, so a `-r` on such a file removes the sandbox and then
  stops before the launch. Any other read or write failure also aborts
  before the launch, since airlock would start on the previous file and
  silently not have the mounts. `resolve_extra_mount` rejects a mount path
  containing control characters (exit 2), because a TOML basic string
  can't carry a raw newline and `toml_escaped` covers only `\` and `"`.
- **`refuse_config_without_sandbox` runs before `remove_sandbox_on_rebuild`.**
  A file in the project keeps the wizard from running, so mounts can't be
  combined with the start that creates the sandbox: no sandbox yet, or
  `-r`, and no project config of the user's own (`airlock.*`, a non-TOML
  `airlock.local.*`, or an `airlock.local.toml` with content outside the
  block — a leftover block of the script's own doesn't count). Checking
  before the removal is what keeps `-r --mount-rw x` from destroying the
  sandbox and then failing. `-c` needs an existing sandbox whatever the
  config, because its Claude Code directory lives in the sandbox
  directory, which `-r` removes and a first run doesn't have yet.
- **`-c` exists because the `anthropic` network service refuses
  Remote Control.** On `api.anthropic.com` the service accepts only its
  own surrogates and injected masked secrets as credentials, and answers
  anything else with a 401 (`airlock_foreign_credential`). Remote
  Control's transport authenticates with a worker credential the API
  mints for the session (`worker_jwt`, `session_ingress_token`), so it is
  refused, and Claude Code gives up with close code 4094 (milankinen/airlock#23).
  `-c` writes `[network.services] anthropic = false`, which leaves the
  `claude` pack's `claude-tokens` inject rule as plain header injection;
  a rule allowing `platform.claude.com:443`, the token host `/login`
  needs once the service no longer allows it; and a `[mounts.claude-dir]`
  override that points the pack's `~/.claude` mount at
  `remote-control-claude` in the sandbox directory (`missing =
  "create-dir"`). Without the service, `/login` writes the real tokens
  into `~/.claude/.credentials.json`; in the pack's directory, shared by
  every sandbox with the pack, other sandboxes would read them and,
  with the service still on, have every API call refused. The sandbox
  directory belongs to this sandbox alone, and `airlock remove` deletes
  it, login included. The prelude unsets
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which the pack sets and
  which hides `/remote-control`; it is unset in the prelude rather than
  set in the block because an `[env]` table in the block would collide
  with one in a hand-written `airlock.local.toml`.
- **`sandbox_dir` parses `airlock info --json` with `sed`, not `jq`**,
  because the host isn't guaranteed to have `jq`, and the pretty-printed
  JSON puts `"dir"` on a line of its own. It is called twice: before the
  launch for the rotation (a project with no sandbox yet yields nothing)
  and after, when a first run has a sandbox at last. Its stderr is
  silenced — "No sandbox for …" is the expected answer on a first run.
- **`session_script` builds the prelude on the host and the launch line
  passes it as the one argument of `bash -c`**, with `airlock-claude` as
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
  tmux runs its command through a shell only when it receives a single
  command argument (given several words it calls `execvp` directly), and
  the handoff passes one string so the path is the same for every command.
  `printf '%q '` re-quotes each word for that shell, so a multi-word
  `-p "run the tests"` stays one word. The shell that reads the string is
  tmux's `default-shell` (busybox `ash` for root on Alpine), so a word
  containing a newline, which `%q` writes as `$'…'`, depends on that shell
  understanding `$'…'`; busybox `ash` does. The `claude` pack installs
  `bash` on Alpine, so the wrapper is always there.
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

- **A changed mount set is a config change.** `airlock start` compares
  the config with the last run's and asks once; `--yes` or no terminal
  aborts with exit 2. The script does not pass
  `--allow-configuration-changes`, because that would also wave through
  an `airlock.toml` edited by code inside the sandbox.
- **The mount point stays behind.** airlock creates the target directory
  under the project and leaves it, empty, after the session; `.gitignore`
  it along with `airlock.local.toml`.
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

- Run `./test-airlock-claude` after any change. It drives the real
  script against a stub `airlock` on a PATH built from scratch, so it
  needs no `airlock`, no network, and finishes in about a second. `-v`
  echoes each case's captured output. Add cases in the same shape when
  you add behavior.
- What the suite cannot reach: anything that boots a VM. The prelude
  reaches `bash -c` as a file, parses under `bash -n`, and is run against
  a substitute `/etc`, where the suite checks the files it writes and the
  `exec` it ends with. Only `apk add tmux`, tmux itself and airlock's
  acceptance of the launch remain outside the suite. For those, run
  `./airlock-claude` on a machine with the `airlock` CLI.
- `README.md` is the user-facing description. A change to flags or the
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
- **The `CONFIG` helper names `airlock.local.toml` in the case's work
  directory; the stub's `remove` deletes only the pretend sandbox, as the
  real one does, so the suite can assert what the script itself does to
  the file.**
- **A missing stub is expressed as `stub_all_but_airlock`**, never as an
  omitted call.
- **`assert_not_grep` fails on a missing file rather than passing.**
- Assertion labels carry the intent of each case; write them as the claim
  being tested, not as a description of the mechanics.
