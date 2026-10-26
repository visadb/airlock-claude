# airlock-claude2 design

A rewrite of `airlock-claude` around airlock's packs and templates. One
bash script, `airlock-claude2`, with its own suite `test-airlock-claude2`,
its own `README2.md` (users) and `AGENTS2.md` (reasoning). The existing
`airlock-claude`, its suite and its docs stay untouched.

## Scope

In: `-M|--no-monitor`, `-T|--no-tmux`, `-x|--exec`, `-r|--rebuild`,
`-h|--help`, `--` forwarding, the `AIRLOCK_PTY_DUMP` session log with
rotation and tail. Alpine-based sandboxes only (the wizard's `alpine`
distro pack, or a template built on it).

Out, for now: themes, extra mounts, git identity, skip-update, the
positive `-m`/`-t` flags, any container engine, any image build, any
generated config file.

## Facts about airlock this design rests on

- A template can only be selected in airlock's interactive setup
  wizard. `airlock start` has no `--template` flag, and the template
  is used only when the wizard generated the config
  (`cmd_start.rs`: `config.generated_project()`).
- The wizard runs only when the project has no config at all
  (`LayeredConfig::has_project_config`: no `airlock.toml`, no
  `airlock.local.toml`, no local project file in the sandbox
  directory). A script-written `airlock.local.toml` suppresses it.
- `airlock start --network <policy>` overrides the configured policy
  for one run and writes nothing back. Rules from the config still
  apply.
- `airlock remove --force` deletes the sandbox directory, which holds
  the wizard's local config. The next start runs the wizard again.
- airlock re-creates the sandbox disk by itself when the image or the
  packs change. The script cannot see that from the outside.
- The `claude` pack installs `bash`, `curl`, `ripgrep` and Claude Code
  on Alpine, mounts `~/.claude` from the host pack directory, sets
  `DISABLE_AUTOUPDATER`, `IS_SANDBOX`, the CA list and the token
  surrogates, and turns on the `anthropic` sign-in service. The
  `alpine` pack allows the apk mirrors by default (`allow-apk`).
- The sandbox runs as root on Alpine. `/etc` is writable and persists on
  the sandbox disk.
- `AIRLOCK_PTY_DUMP=1` is read by the airlock CLI on the host and
  writes `pty.dump` into the sandbox directory, truncating at each
  start. `airlock info --json` reports the directory as `"dir"`.

## Steps, in call order

```
parse_args "$@"                      sets MONITOR, USE_TMUX, EXEC, REBUILD, SHOW_USAGE, CLAUDE_ARGS
validate_exec_usage <exec> <count>   -x needs a command after --
require_airlock
remove_sandbox_on_rebuild <rebuild>  `airlock remove --force`
sandbox_dir                          -> the sandbox directory, or nothing
keep_previous_pty_dump <dump>        sets last run's log aside as <dump>.previous
session_script <use_tmux>            -> the bash script that runs in the sandbox
    (the airlock start line)
sandbox_dir                          again: a first run has a sandbox only now
print_pty_dump_tail <dump> <max>     -> the session's last lines, escape-stripped, to stderr
exit "$AIRLOCK_EXIT"
```

Conventions carried over from `airlock-claude`: one function per step,
defined in call order; inputs as positional arguments named into
`local`s, outputs on stdout; `parse_args` sets its globals directly;
failure is a nonzero `return` with a message on stderr, only the main
sequence exits; the launch line is top level and its status is the
script's.

`parse_args` defaults: `MONITOR=1 USE_TMUX=1 EXEC= REBUILD= SHOW_USAGE=
CLAUDE_ARGS=()`. `-h` sets `SHOW_USAGE` and breaks, so `--help --bogus`
exits 0. Unknown option: message and exit 2. `--` takes the rest.

## The launch line

```
AIRLOCK_PTY_DUMP=1 airlock start ${MONITOR:+--monitor} --network deny-by-default \
  -- bash -c "$SESSION_SCRIPT" airlock-claude2 "${SESSION_COMMAND[@]}"
AIRLOCK_EXIT=$?
```

- `SESSION_COMMAND` is `(claude "${CLAUDE_ARGS[@]}")`, or with `-x`
  `("${CLAUDE_ARGS[@]}")`.
- `${MONITOR:+--monitor}` is unquoted on purpose so an empty value
  disappears. `"${SESSION_COMMAND[@]}"` is quoted on purpose so every
  forwarded word stays one word.
- `--network deny-by-default` is what the script exists to impose. It
  is a flag, not a config file, because a config file would suppress
  the wizard and with it templates.
- `bash -c "$SESSION_SCRIPT" airlock-claude2 ...`: the word after the
  script is `$0` inside the script; the session command is `"$@"`.
- No config file is written. Packs, template and clipboard are the
  wizard's answers on a project's first start, saved by airlock in the
  sandbox directory. The project's own `airlock.toml`, if any, applies
  as usual.

## The session script (prelude)

Built by `session_script <use_tmux>` from a single-quoted heredoc on
the host, run by `bash -c` in the sandbox on every launch. Idempotent.

1. With tmux in use:
   `command -v tmux >/dev/null || apk add --quiet tmux || exit 1`
   (`allow-apk` lets it through deny-by-default; a failure shows apk's
   own error and stops before a "tmux: not found").
2. Always rewrite `/etc/tmux.conf`:
   ```
   set -g mouse on
   set -g set-clipboard on
   set -as terminal-features ",*:clipboard"
   set -g default-terminal "tmux-256color"
   ```
3. Always rewrite `/etc/claude-code/managed-settings.json`:
   ```
   { "permissions": { "defaultMode": "bypassPermissions" },
     "skipDangerousModePermissionPrompt": true }
   ```
4. Always rewrite `/etc/claude-code/CLAUDE.md`: the old text without the
   Node.js/nvm section. Kept: the proxy and the 403 "denied by network
   policy" line; asking the user for temporary network access and
   reminding them to revert it; the Python `VERIFY_X509_STRICT`
   recipes; host-made virtualenvs; "describe the present only". Added:
   a short "Alpine" section: packages come from `apk add`, the mirrors
   are allowed, musl rather than glibc.
5. The handoff:
   - with tmux: `exec tmux -u new-session -A -s claude "$(printf '%q ' "$@")"`
   - without: `exec "$@"`

Why rewrite instead of write-if-missing: the files are the script's
own, the rewrite is one `printf` each, and a changed text in a newer
script reaches an existing sandbox without a `-r`.

Why every launch instead of "only when no sandbox existed": airlock
re-creates the disk on image or pack changes, and a sandbox made by a
plain `airlock start` has no tmux. An existence check on the host would
miss both and launch a tmux that is not there.

Why `bash -c` and `%q`: tmux joins its command words with spaces and
runs them through a shell, so a multi-word `-p "run the tests"` splits.
Bash's `printf %q` re-quotes each word. The claude pack guarantees
`bash` on Alpine.

Why `/etc/claude-code`: managed policy settings and memory are the
highest-precedence sources, apply to whichever user runs, and sit
outside `~/.claude`, which the pack mounts from the host and shares
between sandboxes.

The prelude is a quoted heredoc on the host (`<<'PRELUDE'`), and the
files it writes in the sandbox are quoted heredocs inside it with other
delimiters, so quotes, apostrophes and `$` in the content pass through
both layers untouched. The suite extracts the script from the launch
argv and runs `bash -n` on it.

## `-r|--rebuild`

`airlock remove --force` to stderr; a failure aborts with exit 1
before the launch, since launching on the old sandbox would silently
not be a rebuild. The next start shows the wizard again. Whatever was
installed on the sandbox disk is gone; `~/.claude` (host mount) and the
sign-in survive.

## Session log

Unchanged from `airlock-claude`: `sandbox_dir` parses `airlock info
--json` with `sed`; `keep_previous_pty_dump` moves `pty.dump` to
`pty.dump.previous` before the launch; after it,
`print_pty_dump_tail` strips escapes from the last 64 KiB and prints
up to 15 non-empty lines to stderr under a header naming the whole log.
A missing or empty dump prints nothing.

## Error handling

| Case | Behaviour |
|------|-----------|
| unknown option | message + "Try --help", exit 2 |
| `-x` without a command | message, exit 2 |
| `airlock` not on PATH | message, exit 1 |
| `airlock remove` fails under `-r` | exit 1, no launch |
| `apk add tmux` fails in the sandbox | apk's error, session exits 1 |
| airlock exits nonzero | tail still printed, status passed through |

## Tests: `test-airlock-claude2`

Same shape as `test-airlock-claude`: `set -u`, pass/fail counters,
`assert_rc/eq/grep/not_grep/exists/absent`, a `TOOLS` symlink dir of
the real tools the script uses (`sed tail cat rm mv tr mkdir`), one
temp work dir per case (never this repo), `PATH` rebuilt per case,
stubs driven by exported env vars reset in `new_case`, labels as
claims.

Stubs: `airlock` only; `TOOLS` holds `sed tail cat tr mv rm mkdir`.
- `airlock`: `info --json` prints a fake sandbox JSON with `"dir":
  "$STUB_BOX"`, or exits 1 with the "No sandbox for" line under
  `STUB_NO_SANDBOX`; `remove` logs `REMOVE: ...`, removes `$STUB_BOX`,
  exits `STUB_REMOVE_EXIT`; anything else logs `LAUNCH: <argv>`, each
  word as `ARGV[...]` under `DUMP_ARGV`, `LAUNCH_PTY_DUMP: <value>`,
  writes `STUB_PTY_DUMP` to `$STUB_BOX/pty.dump`, exits `STUB_EXIT`.
  The stub also writes the `bash -c` script argument to
  `$CASE_DIR/session-script` for the text checks.
- `bash -n` for the prelude runs on the host `PATH`; the script's shebang
  is absolute.

Case groups:
- syntax: `bash -n` on the script.
- arguments: `--help` (exit 0, usage, documents each flag, no launch,
  works without airlock), `-h`, `-r --help`, unknown option (2),
  `--bogus --help` (2), `-- --bogus` (0), `-- --help` reaches claude.
- dependency: missing airlock exits 1 with its message, no launch.
- launch argv: default, `-M`, `-T`, `-M -T`, `-- --resume`, bare `--`,
  multi-word forwarded arg as one word, `--network deny-by-default`
  always present, `bash -c` with `airlock-claude2` as `$0`, no
  `airlock.local.toml` written.
- exec: `-x -- bash`, `-x` with wrapper flags and a multi-word word,
  `-x` without `--` (2), `-x --` (2).
- session script (extracted text): `bash -n` passes; `apk add` only
  with tmux; the four tmux.conf lines; `managed-settings.json` with
  `bypassPermissions` and `skipDangerousModePermissionPrompt`;
  `CLAUDE.md` with the 403 line, the revert reminder,
  `VERIFY_X509_STRICT`, the virtualenv line, the history rule, the apk
  note; no `nvm`; `exec tmux -u new-session -A -s claude` with
  `printf '%q '` when tmux is on, `exec "$@"` when off; under `-T` the
  prelude is run against a substitute `/etc` and the written files are
  checked.
- rebuild: plain run does not remove; `-r` logs `remove --force`
  before `LAUNCH`; failed remove exits 1 without a launch.
- session log: all cases from the old suite carried over.

## Docs

`README2.md`: what it is, prerequisites (`airlock` only), first run
(the wizard: pick `alpine` + `claude`, or a template; `airlock
templates create` to make one), usage and the three flags plus `-r`,
`--` forwarding and `-x`, things to know (tmux and detaching, login via
the pack, session log, what `-r` removes, deny-by-default and
`allow-apk`, Python HTTPS). Points at `AGENTS2.md`.

`AGENTS2.md`: the step list as above, the conventions to preserve, the
reasoning per step (the facts section of this spec, rewritten as
present-tense "why"), the prelude rules (no apostrophe, idempotent,
rewrite), working on the script and the suite.
