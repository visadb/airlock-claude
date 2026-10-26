# airlock-claude2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new launcher `airlock-claude2` that runs Claude Code in an airlock sandbox built from airlock's packs or a template, with its own test suite and docs, leaving `airlock-claude` untouched.

**Architecture:** One bash script in the one-function-per-step shape of `airlock-claude`. It writes no config: packs and template come from airlock's setup wizard on a project's first start, the deny-by-default policy is a flag on the launch line, and a bash prelude passed to `bash -c` prepares the sandbox (tmux, `/etc/tmux.conf`, `/etc/claude-code/*`) on every launch, idempotently, then execs tmux or the command. The session log (`AIRLOCK_PTY_DUMP`) rotation and tail are carried over as they are.

**Tech Stack:** bash 3.2+ (macOS `/bin/bash`), POSIX `sh` for the test stubs, `airlock` CLI with packs and templates. No container engine, no network in the tests.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-26-airlock-claude2-design.md`. Read it first.
- Shebang `#!/bin/bash`; must run under macOS bash 3.2 (no `${var,,}`, no associative arrays, no fractional `read -t`).
- One function per step, defined in call order, called in that order at the bottom. Inputs are positional arguments named into `local`s on the first line; outputs are printed. `parse_args` sets its globals directly (the one exemption). Failure is a nonzero `return` with a message on stderr; only the main sequence calls `exit`.
- No explanatory comments in the scripts. Reasoning goes in `AGENTS2.md`, user docs in `README2.md`.
- The launch line is top level, not in a function. `${MONITOR:+--monitor}` is unquoted on purpose; `"${SESSION_COMMAND[@]}"` is quoted on purpose.
- The script writes nothing into the project directory. No `airlock.local.toml`, no `.airlock`.
- Every launch passes `--network deny-by-default` and `AIRLOCK_PTY_DUMP=1`.
- The prelude is idempotent and runs on every launch; files under `/etc` are rewritten each time; `apk add tmux` only when tmux is in use and missing.
- Messages are prefixed `airlock-claude2:`.
- Tests: `./test-airlock-claude2` runs in about a second with no `airlock`, no network. Every case runs in its own temp directory; no case may `cd` into this repo. `PATH` is rebuilt from scratch per case. Labels are written as the claim being tested.
- Commits land on `main` directly (solo repo). Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The existing `airlock-claude`, `test-airlock-claude`, `README.md`, `AGENTS.md` are not modified.

---

## File structure

| File | Responsibility |
|------|----------------|
| `airlock-claude2` (create) | The launcher. Steps: `usage`, `parse_args`, `validate_exec_usage`, `require_airlock`, `remove_sandbox_on_rebuild`, `sandbox_dir`, `keep_previous_pty_dump`, `session_script`, the launch line, `strip_terminal_escapes`, `print_pty_dump_tail`. |
| `test-airlock-claude2` (create) | The suite: assertion helpers, an `airlock` stub, per-case temp dirs, cases grouped by section. |
| `README2.md` (create) | User docs for `airlock-claude2`. |
| `AGENTS2.md` (create) | Reasoning and conventions for `airlock-claude2`. |

Tasks build the two scripts up in three increments (arguments and launch line; the prelude; rebuild and session log), then the docs.

---

### Task 1: Suite harness, argument parsing, launch line

**Files:**
- Create: `test-airlock-claude2`
- Create: `airlock-claude2`

**Interfaces:**
- Produces: `parse_args` (sets `MONITOR USE_TMUX EXEC REBUILD SHOW_USAGE CLAUDE_ARGS`), `validate_exec_usage <exec> <count>`, `require_airlock`, `session_script <use_tmux>` (prints the bash script run in the sandbox; in this task only the handoff line), the launch line. The suite's `new_case`, `stub_airlock`, `stub_all`, `stub_all_but_airlock`, `run_script`, `SESSION_SCRIPT` (path of the extracted prelude), and the `LAUNCH:` log format `LAUNCH: start [--monitor] --network deny-by-default -- bash -c <script> airlock-claude2 <words...>`.

- [ ] **Step 1: Write the suite with the harness and the first four sections**

Create `test-airlock-claude2` with exactly this content:

```bash
#!/bin/bash

set -u

VERBOSE=
[ "${1:-}" = "-v" ] && VERBOSE=1

SUITE_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$SUITE_DIR/airlock-claude2
[ -x "$SCRIPT" ] || { echo "not executable: $SCRIPT" >&2; exit 1; }

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/airlock-claude2-tests.XXXXXX") || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

PASSED=0
FAILED=0

pass() {
  local label=$1
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "$label"
}
fail() {
  local label=$1 detail=${2:-}
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "$label"
  [ -n "$detail" ] && printf '        %s\n' "$detail"
  return 0
}

section() { local title=$1; printf '\n%s\n' "$title"; }

assert_rc() {
  local expected=$1 actual=$2 label=$3
  if [ "$expected" = "$actual" ]; then pass "$label"
  else fail "$label" "expected exit $expected, got $actual"; fi
}
assert_eq() {
  local expected=$1 actual=$2 label=$3
  if [ "$expected" = "$actual" ]; then pass "$label"
  else fail "$label" "expected [$expected], got [$actual]"; fi
}
assert_grep() {
  local pattern=$1 file=$2 label=$3
  if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then pass "$label"
  else fail "$label" "no match for [$pattern] in $(basename "$file")"; fi
}
assert_not_grep() {
  local pattern=$1 file=$2 label=$3
  if [ ! -f "$file" ]; then fail "$label" "file to search does not exist: $file"
  elif grep -q -- "$pattern" "$file"; then fail "$label" "unexpected match for [$pattern]"
  else pass "$label"; fi
}
assert_exists() {
  local path=$1 label=$2
  if [ -e "$path" ]; then pass "$label"; else fail "$label" "missing: $path"; fi
}
assert_absent() {
  local path=$1 label=$2
  if [ -e "$path" ]; then fail "$label" "should not exist: $path"; else pass "$label"; fi
}

TOOLS=$TMPROOT/tools
mkdir -p "$TOOLS"
for t in sed tail cat tr mv rm mkdir; do
  p=$(command -v "$t") || { echo "required tool not found: $t" >&2; exit 1; }
  ln -s "$p" "$TOOLS/$t"
done

new_case() {
  CASE_DIR=$(mktemp -d "$TMPROOT/case.XXXXXX")
  BIN=$CASE_DIR/bin
  WORK=$CASE_DIR/work
  FAKE_HOME=$CASE_DIR/home
  LOG=$CASE_DIR/log
  STUB_BOX=$CASE_DIR/boxes/k3x7q2ma
  mkdir -p "$BIN" "$WORK" "$FAKE_HOME"
  : > "$LOG"
  export LOG CASE_DIR STUB_BOX
  export DUMP_ARGV= STUB_PTY_DUMP= STUB_EXIT= STUB_REMOVE_EXIT= STUB_NO_SANDBOX=
  RC=0
}

stub_airlock() {
  cat > "$BIN/airlock" <<'EOF'
#!/bin/sh
case "$1" in
  info)
    if [ -n "${STUB_NO_SANDBOX:-}" ]; then
      echo "No sandbox for $PWD — run \`airlock start\` first" >&2
      exit 1
    fi
    printf '{\n  "id": "k3x7q2ma",\n  "location": "data-dir",\n  "project": "%s",\n  "dir": "%s",\n  "status": "stopped"\n}\n' "$PWD" "$STUB_BOX"
    exit 0 ;;
  remove)
    echo "REMOVE: $*" >> "$LOG"
    rm -rf "$STUB_BOX"
    exit "${STUB_REMOVE_EXIT:-0}" ;;
esac
LINE=
NEXT_IS_SCRIPT=
for arg; do
  if [ -n "$NEXT_IS_SCRIPT" ]; then
    printf '%s\n' "$arg" > "$CASE_DIR/session-script"
    arg='<script>'
    NEXT_IS_SCRIPT=
  elif [ "$arg" = -c ] && [ ! -e "$CASE_DIR/session-script" ]; then
    NEXT_IS_SCRIPT=1
  fi
  LINE="$LINE $arg"
  if [ -n "${DUMP_ARGV:-}" ]; then echo "ARGV[$arg]" >> "$LOG"; fi
done
echo "LAUNCH:$LINE" >> "$LOG"
echo "LAUNCH_PTY_DUMP: ${AIRLOCK_PTY_DUMP:-unset}" >> "$LOG"
if [ -n "${STUB_PTY_DUMP:-}" ]; then
  mkdir -p "$STUB_BOX"
  printf '%b' "$STUB_PTY_DUMP" > "$STUB_BOX/pty.dump"
fi
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$BIN/airlock"
}

stub_all() { stub_airlock; }
stub_all_but_airlock() { :; }

run_script() {
  ( cd "$WORK" && PATH="$BIN:$TOOLS" HOME="$FAKE_HOME" \
      "$SCRIPT" "$@" > "$CASE_DIR/out" 2> "$CASE_DIR/err" )
  RC=$?
  if [ -n "$VERBOSE" ]; then
    [ -s "$CASE_DIR/out" ] && sed 's/^/        out: /' "$CASE_DIR/out"
    [ -s "$CASE_DIR/err" ] && sed 's/^/        err: /' "$CASE_DIR/err"
  fi
  return 0
}

SESSION_SCRIPT() { echo "$CASE_DIR/session-script"; }

section "syntax"
if bash -n "$SCRIPT" 2>"$TMPROOT/syntax.err"; then
  pass "script parses under bash -n"
else
  fail "script parses under bash -n" "$(cat "$TMPROOT/syntax.err")"
fi

section "argument handling"
new_case; stub_all
run_script --help
assert_rc 0 "$RC" "--help exits 0"
assert_grep "Usage: airlock-claude2" "$CASE_DIR/out" "--help prints usage to stdout"
assert_grep "passed to claude verbatim" "$CASE_DIR/out" "--help documents -- forwarding"
assert_grep "\-M, --no-monitor" "$CASE_DIR/out" "--help documents --no-monitor"
assert_grep "\-T, --no-tmux" "$CASE_DIR/out" "--help documents --no-tmux"
assert_grep "\-x, --exec" "$CASE_DIR/out" "--help documents --exec"
assert_grep "\-r, --rebuild" "$CASE_DIR/out" "--help documents --rebuild"
assert_grep "setup wizard" "$CASE_DIR/out" "--help says the first run goes through airlock's wizard"
assert_grep "pty.dump" "$CASE_DIR/out" "--help documents the session log"
assert_grep "airlock info" "$CASE_DIR/out" "--help says where to find the sandbox directory the log is in"
assert_not_grep "LAUNCH:" "$LOG" "--help does not launch"

new_case; stub_all
run_script -h
assert_rc 0 "$RC" "-h exits 0"

new_case; stub_all_but_airlock
run_script --help
assert_rc 0 "$RC" "--help works with airlock absent"

new_case; stub_all
run_script -r --help
assert_rc 0 "$RC" "--help after another flag exits 0"
assert_grep "Usage: airlock-claude2" "$CASE_DIR/out" "--help after another flag still prints usage"
assert_not_grep "REMOVE:" "$LOG" "--help after -r removes nothing"

new_case; stub_all
run_script --bogus
assert_rc 2 "$RC" "unknown option exits 2"
assert_grep "unknown option" "$CASE_DIR/err" "unknown option explains itself"
assert_not_grep "LAUNCH:" "$LOG" "unknown option does not launch"

new_case; stub_all
run_script --bogus --help
assert_rc 2 "$RC" "unknown option before --help still exits 2"

new_case; stub_all
run_script -- --bogus
assert_rc 0 "$RC" "arguments after -- are not parsed as this script's options"

new_case; stub_all
run_script -- --help
assert_rc 0 "$RC" "--help after -- belongs to claude"
assert_not_grep "Usage: airlock-claude2" "$CASE_DIR/out" "--help after -- does not print this script's usage"
assert_grep "claude --help" "$LOG" "--help after -- reaches claude"

section "dependency checks"
new_case; stub_all_but_airlock
run_script
assert_rc 1 "$RC" "missing airlock exits 1"
assert_grep "airlock not found in PATH" "$CASE_DIR/err" "missing airlock names the dependency"
assert_not_grep "LAUNCH:" "$LOG" "missing airlock does not launch"

section "launch"
new_case; stub_all
run_script
assert_rc 0 "$RC" "happy path exits 0"
assert_eq "LAUNCH: start --monitor --network deny-by-default -- bash -c <script> airlock-claude2 claude" \
  "$(grep '^LAUNCH:' "$LOG")" "launch argv is exact"
assert_not_grep "dangerously-skip-permissions" "$LOG" "launch passes no permission flag"
assert_absent "$WORK/airlock.local.toml" "no config file is written; the wizard and the project's own config decide"
assert_absent "$WORK/.airlock" "nothing is written into the project directory"
assert_exists "$(SESSION_SCRIPT)" "the sandbox-side script travels as the one argument of bash -c"

new_case; stub_all
run_script --no-monitor
assert_eq "LAUNCH: start --network deny-by-default -- bash -c <script> airlock-claude2 claude" \
  "$(grep '^LAUNCH:' "$LOG")" "--no-monitor drops the monitor flag and keeps the policy"

new_case; stub_all
run_script -M
assert_not_grep "monitor" "$LOG" "-M is the short form"

new_case; stub_all
run_script --no-tmux
assert_eq "LAUNCH: start --monitor --network deny-by-default -- bash -c <script> airlock-claude2 claude" \
  "$(grep '^LAUNCH:' "$LOG")" "--no-tmux changes the sandbox-side script, not the launch argv"
assert_eq 'exec "$@"' "$(tail -n 1 "$(SESSION_SCRIPT)")" "--no-tmux hands straight to the command"
assert_not_grep "tmux" "$(SESSION_SCRIPT)" "--no-tmux leaves tmux out of the sandbox-side script"

new_case; stub_all
run_script -T
assert_not_grep "tmux" "$(SESSION_SCRIPT)" "-T is the short form"

new_case; stub_all
run_script
EXPECTED_HANDOFF=$(cat <<'EOF'
exec tmux -u new-session -A -s claude "$(printf '%q ' "$@")"
EOF
)
assert_eq "$EXPECTED_HANDOFF" "$(tail -n 1 "$(SESSION_SCRIPT)")" \
  "by default the last line hands the words to tmux, each re-quoted with %q so a multi-word word survives tmux's join"

new_case; stub_all
run_script -M -T
assert_eq "LAUNCH: start --network deny-by-default -- bash -c <script> airlock-claude2 claude" \
  "$(grep '^LAUNCH:' "$LOG")" "-M and -T together still impose the policy"

new_case; stub_all
run_script -- --resume
assert_eq "LAUNCH: start --monitor --network deny-by-default -- bash -c <script> airlock-claude2 claude --resume" \
  "$(grep '^LAUNCH:' "$LOG")" "arguments after -- reach claude"

new_case; stub_all
run_script --
assert_eq "LAUNCH: start --monitor --network deny-by-default -- bash -c <script> airlock-claude2 claude" \
  "$(grep '^LAUNCH:' "$LOG")" "a bare -- forwards nothing"

new_case; stub_all
export DUMP_ARGV=1
run_script -M -T -- -p "multi word prompt"
assert_eq "LAUNCH: start --network deny-by-default -- bash -c <script> airlock-claude2 claude -p multi word prompt" \
  "$(grep '^LAUNCH:' "$LOG")" "forwarded arguments combine with wrapper flags"
assert_grep 'ARGV\[multi word prompt\]' "$LOG" "a multi-word argument survives as one word"
assert_grep 'ARGV\[airlock-claude2\]' "$LOG" "the script name is the \$0 of bash -c, ahead of the words"

section "exec"
new_case; stub_all
run_script -x -- bash
assert_rc 0 "$RC" "-x with a command exits 0"
assert_eq "LAUNCH: start --monitor --network deny-by-default -- bash -c <script> airlock-claude2 bash" \
  "$(grep '^LAUNCH:' "$LOG")" "-x replaces claude with the command after --"
assert_not_grep "airlock-claude2 claude" "$LOG" "claude itself is gone from the launch"

new_case; stub_all
export DUMP_ARGV=1
run_script -M -T --exec -- sh -c "echo two words"
assert_eq "LAUNCH: start --network deny-by-default -- bash -c <script> airlock-claude2 sh -c echo two words" \
  "$(grep '^LAUNCH:' "$LOG")" "--exec combines with the wrapper flags"
assert_grep 'ARGV\[echo two words\]' "$LOG" "a multi-word command argument survives as one word"

new_case; stub_all
run_script -x
assert_rc 2 "$RC" "-x without -- exits 2"
assert_grep "needs a command after --" "$CASE_DIR/err" "-x without a command explains itself"
assert_not_grep "LAUNCH:" "$LOG" "-x without a command does not launch"

new_case; stub_all
run_script -x --
assert_rc 2 "$RC" "-x with an empty -- exits 2"

printf '\n%s\n' "----------------------------------------"
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
```

Then: `chmod +x test-airlock-claude2`.

- [ ] **Step 2: Run the suite to see it fail**

Run: `./test-airlock-claude2`
Expected: exit 1 with `not executable: .../airlock-claude2` (the script does not exist yet).

- [ ] **Step 3: Write the script: usage, parse_args, validation, the launch line**

Create `airlock-claude2` with exactly this content:

```bash
#!/bin/bash

usage() {
  cat <<'USAGE'
Usage: airlock-claude2 [-M|--no-monitor] [-T|--no-tmux] [-r|--rebuild]
                       [-h|--help] [-- <claude args...>]
       airlock-claude2 [-M|--no-monitor] [-T|--no-tmux] [-r|--rebuild]
                       -x|--exec -- <command...>

Runs Claude Code sandboxed in an airlock VM in the current directory, with
network access denied by default. On a project's first run airlock's setup
wizard asks which packs or template to use: pick alpine and claude, or a
template built on them.

The session runs inside tmux, under airlock's monitor TUI, by default.
Before it starts, tmux is installed into the sandbox if missing, and the
tmux config, Claude Code's managed settings (bypass permissions) and
managed CLAUDE.md are written under /etc.

When the session ends, the last lines of its output are printed again —
the monitor and tmux restore the host screen on exit, taking the session's
final words with them — and the whole terminal log of the run is kept as
pty.dump in the sandbox directory (`airlock info` shows it), with the
previous run's log beside it as pty.dump.previous.

  -M, --no-monitor  Run without the monitor TUI, handing the host terminal
                    straight to the session.
  -T, --no-tmux     Run claude directly instead of inside tmux.
  -x, --exec        Run the command given after -- instead of claude, in
                    the same VM and, by default, the same tmux and monitor
                    wrappers.
  -r, --rebuild     Remove the project's sandbox (`airlock remove`) before
                    starting, so airlock makes a fresh one and the setup
                    wizard runs again. Anything installed inside the VM is
                    lost; the persisted Claude settings and login are not.
  -h, --help        Show this help.

Arguments after -- are passed to claude verbatim:

  airlock-claude2 -- --resume
  airlock-claude2 -M -- -p "run the tests"

With -x, the arguments after -- replace claude entirely:

  airlock-claude2 -x -- bash
  airlock-claude2 -M -T -x -- python3 -m http.server
USAGE
}

parse_args() {
  MONITOR=1 USE_TMUX=1 EXEC= REBUILD= SHOW_USAGE= CLAUDE_ARGS=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --) shift; CLAUDE_ARGS=("$@"); return 0 ;;
      -M|--no-monitor) MONITOR= ;;
      -T|--no-tmux) USE_TMUX= ;;
      -x|--exec) EXEC=1 ;;
      -r|--rebuild) REBUILD=1 ;;
      -h|--help) SHOW_USAGE=1; break ;;
      *)
        echo "airlock-claude2: unknown option: $1" >&2
        echo "Try 'airlock-claude2 --help'." >&2
        return 2 ;;
    esac
    shift
  done
}

validate_exec_usage() {
  local exec_given=$1 command_word_count=$2
  [[ -n $exec_given ]] || return 0
  if (( command_word_count == 0 )); then
    echo "airlock-claude2: --exec needs a command after --" >&2
    return 2
  fi
}

require_airlock() {
  if ! command -v airlock >/dev/null 2>&1; then
    echo "airlock not found in PATH" >&2
    return 1
  fi
}

session_script() {
  local use_tmux=$1
  if [[ -n $use_tmux ]]; then
    cat <<'HANDOFF'
exec tmux -u new-session -A -s claude "$(printf '%q ' "$@")"
HANDOFF
  else
    cat <<'HANDOFF'
exec "$@"
HANDOFF
  fi
}

parse_args "$@" || exit $?
[[ -n $SHOW_USAGE ]] && { usage; exit 0; }

validate_exec_usage "$EXEC" "${#CLAUDE_ARGS[@]}" || exit $?

require_airlock || exit 1

SESSION_SCRIPT=$(session_script "$USE_TMUX")
if [[ -n $EXEC ]]; then
  SESSION_COMMAND=("${CLAUDE_ARGS[@]}")
else
  SESSION_COMMAND=(claude "${CLAUDE_ARGS[@]}")
fi

AIRLOCK_PTY_DUMP=1 airlock start ${MONITOR:+--monitor} --network deny-by-default -- bash -c "$SESSION_SCRIPT" airlock-claude2 "${SESSION_COMMAND[@]}"
AIRLOCK_EXIT=$?
exit "$AIRLOCK_EXIT"
```

Then: `chmod +x airlock-claude2`.

- [ ] **Step 4: Run the suite to see it pass**

Run: `./test-airlock-claude2`
Expected: last line `NN passed, 0 failed`, exit 0. If a label fails, the detail line under it shows the expected and actual values; fix the script, not the label.

- [ ] **Step 5: Commit**

```bash
git add airlock-claude2 test-airlock-claude2
git commit -m "Add airlock-claude2: arguments and launch line on airlock packs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The prelude

**Files:**
- Modify: `airlock-claude2` (replace `session_script`)
- Modify: `test-airlock-claude2` (new section before the summary)

**Interfaces:**
- Consumes: `session_script <use_tmux>` from Task 1, the suite's `SESSION_SCRIPT` path.
- Produces: the full sandbox-side script: tmux install (tmux only), `/etc/tmux.conf`, `/etc/claude-code/managed-settings.json`, `/etc/claude-code/CLAUDE.md`, then the handoff.

- [ ] **Step 1: Add the "session script" section to the suite**

Insert this block into `test-airlock-claude2` immediately before the line `printf '\n%s\n' "----------------------------------------"`:

```bash
section "session script"
new_case; stub_all
run_script
if bash -n "$(SESSION_SCRIPT)" 2>"$CASE_DIR/ss.err"; then
  pass "the sandbox-side script parses under bash -n"
else
  fail "the sandbox-side script parses under bash -n" "$(cat "$CASE_DIR/ss.err")"
fi
assert_eq 'command -v tmux >/dev/null 2>&1 || apk add --quiet tmux || exit 1' \
  "$(sed -n 1p "$(SESSION_SCRIPT)")" "tmux is installed first, only if missing, and a failed install stops the session"
assert_grep "^cat > /etc/tmux.conf <<" "$(SESSION_SCRIPT)" "the system tmux config is written on every launch"
assert_grep "^set -g mouse on$" "$(SESSION_SCRIPT)" "tmux config turns the mouse on"
assert_grep "^set -g set-clipboard on$" "$(SESSION_SCRIPT)" "tmux config forwards copies to the host clipboard"
assert_grep '^set -as terminal-features ",\*:clipboard"$' "$(SESSION_SCRIPT)" "tmux config asserts OSC 52 support for every terminal"
assert_grep '^set -g default-terminal "tmux-256color"$' "$(SESSION_SCRIPT)" "tmux config keeps 256 colours"
assert_grep "^mkdir -p /etc/claude-code$" "$(SESSION_SCRIPT)" "the managed Claude Code directory is created"
assert_grep "^cat > /etc/claude-code/managed-settings.json <<" "$(SESSION_SCRIPT)" "the managed settings are written on every launch"
assert_grep '"defaultMode": "bypassPermissions"' "$(SESSION_SCRIPT)" "managed settings bypass permission prompts"
assert_grep '"skipDangerousModePermissionPrompt": true' "$(SESSION_SCRIPT)" "managed settings pre-accept the bypass warning"
assert_grep "^cat > /etc/claude-code/CLAUDE.md <<" "$(SESSION_SCRIPT)" "the managed memory is written on every launch"
assert_grep "denied by network policy" "$(SESSION_SCRIPT)" "managed memory describes the 403 the proxy answers denied requests with"
assert_grep "remind them to revert the airlock" "$(SESSION_SCRIPT)" "managed memory tells Claude Code it can ask for temporary network access"
assert_grep "apk add" "$(SESSION_SCRIPT)" "managed memory says packages come from apk"
assert_grep "VERIFY_X509_STRICT" "$(SESSION_SCRIPT)" "managed memory tells Claude Code how to get Python past the TLS proxy"
assert_grep "delete or overwrite a virtualenv you did not create in this session" "$(SESSION_SCRIPT)" \
  "managed memory keeps Claude Code out of the host's virtualenvs"
assert_grep "Never add notes about how something used to work" "$(SESSION_SCRIPT)" "managed memory forbids history in comments and docs"
assert_not_grep "nvm" "$(SESSION_SCRIPT)" "managed memory carries nothing about the old image's nvm"
assert_eq "1" "$(grep -c '^exec ' "$(SESSION_SCRIPT)")" "exactly one exec line hands off"

new_case; stub_all
run_script -T
assert_not_grep "apk add" "$(SESSION_SCRIPT)" "-T installs no tmux"
assert_grep "^cat > /etc/tmux.conf <<" "$(SESSION_SCRIPT)" "-T still writes the tmux config, for a tmux started by hand"
assert_grep "/etc/claude-code/CLAUDE.md" "$(SESSION_SCRIPT)" "-T still writes the managed memory"
assert_eq 'exec "$@"' "$(tail -n 1 "$(SESSION_SCRIPT)")" "-T ends with a plain exec"

new_case; stub_all
run_script -x -- bash
assert_grep "/etc/claude-code/managed-settings.json" "$(SESSION_SCRIPT)" "-x sessions get the same prelude"
assert_grep "apk add --quiet tmux" "$(SESSION_SCRIPT)" "-x under tmux installs tmux too"
```

- [ ] **Step 2: Run the suite to see the new section fail**

Run: `./test-airlock-claude2`
Expected: the "session script" section shows FAIL for the apk, tmux.conf, managed-settings and CLAUDE.md claims; earlier sections still pass; exit 1.

- [ ] **Step 3: Replace `session_script` with the full prelude**

In `airlock-claude2`, replace the whole `session_script` function with:

```bash
session_script() {
  local use_tmux=$1
  if [[ -n $use_tmux ]]; then
    cat <<'TMUX_INSTALL'
command -v tmux >/dev/null 2>&1 || apk add --quiet tmux || exit 1
TMUX_INSTALL
  fi
  cat <<'PRELUDE'
cat > /etc/tmux.conf <<'TMUX_CONF'
set -g mouse on
set -g set-clipboard on
set -as terminal-features ",*:clipboard"
set -g default-terminal "tmux-256color"
TMUX_CONF
mkdir -p /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'SETTINGS'
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
cat > /etc/claude-code/CLAUDE.md <<'CLAUDE_MD'
# Sandbox notes (airlock-claude2)

This session runs inside an airlock VM. Outbound network access is denied
except for allowlisted hosts, and the HTTPS traffic that is allowed goes
through the airlock TLS proxy, which re-signs every host with its own
"airlock CA". The system trust store already includes that CA, so curl,
git and pip work unchanged.

An HTTP request the policy denies is answered by the proxy itself with
403 Forbidden and the body "denied by network policy" (one line). That
response means the airlock policy blocked the request, not that the
remote server refused it.

## Blocked traffic can be allowed interactively

The user can usually enable traffic that does not match the allow/deny
rules of the airlock policy, temporarily and interactively, from outside
the session. If network access beyond the allowlist would be important
for the task, ask the user to allow the traffic instead of working
around the block. When they do, remind them to revert the airlock
network policy once the part of the work that needed the extra access
is done.

## Alpine Linux

The sandbox is Alpine Linux on musl, not glibc. Install packages with
apk add; the Alpine package mirrors are allowed under the network policy.
A prebuilt binary built for glibc does not run here: look for a musl
build or for the apk package instead.

## Python HTTPS fails with "Missing Authority Key Identifier"

Every Python HTTPS client fails certificate verification here: urllib,
http.client, urllib3, requests, httpx and aiohttp all raise
CERTIFICATE_VERIFY_FAILED with "Missing Authority Key Identifier" (requests
and httpx may say "unable to get local issuer certificate" first). Python
3.13+ turns on VERIFY_X509_STRICT by default, and the per-host certificates
the proxy issues carry no Authority Key Identifier extension, so strict
checking rejects them. SSL_CERT_FILE and REQUESTS_CA_BUNDLE do not help.

Fix: build one SSL context with strict checking off and pass it explicitly.
Verification itself stays on; do not use verify=False or CERT_NONE.

    import ssl
    ctx = ssl.create_default_context()
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT

    urllib.request.urlopen(url, context=ctx)
    http.client.HTTPSConnection(host, context=ctx)
    urllib3.PoolManager(ssl_context=ctx)
    httpx.get(url, verify=ctx)            # or httpx.Client(verify=ctx)
    session.get(url, ssl=ctx)             # aiohttp

    class Adapter(requests.adapters.HTTPAdapter):    # requests
        def init_poolmanager(self, *args, **kwargs):
            kwargs["ssl_context"] = ctx
            return super().init_poolmanager(*args, **kwargs)
    s = requests.Session(); s.mount("https://", Adapter())

For a one-off download, curl works without any of this.

## Virtualenvs you find here belong to the host

The working directory is shared with the host, so any .venv, venv or other
virtualenv already in it was almost certainly created on the host, with a
different Python at a different path. Its interpreter symlinks, pyvenv.cfg
and compiled wheels will not match this sandbox. Never activate, reuse,
delete or overwrite a virtualenv you did not create in this session. Make
your own under a different name, for example python3 -m venv .venv-airlock,
and leave the existing one alone.

## Describe the present only

When you write or change comments or documentation, describe how things
are now. Never add notes about how something used to work, what an
approach replaced, or why an old way is gone. That history belongs in
the commit message, and nowhere else.
CLAUDE_MD
PRELUDE
  if [[ -n $use_tmux ]]; then
    cat <<'HANDOFF'
exec tmux -u new-session -A -s claude "$(printf '%q ' "$@")"
HANDOFF
  else
    cat <<'HANDOFF'
exec "$@"
HANDOFF
  fi
}
```

Note the nesting: `PRELUDE` is the host heredoc; `TMUX_CONF`, `SETTINGS` and `CLAUDE_MD` are heredocs that run inside the sandbox. All are quoted delimiters, so nothing expands on either side.

- [ ] **Step 4: Run the suite to see it pass**

Run: `./test-airlock-claude2`
Expected: `NN passed, 0 failed`, exit 0.

- [ ] **Step 5: Check the prelude by hand once**

Run:
```bash
cd "$(mktemp -d)" && mkdir bin && printf '#!/bin/sh\nfor a; do [ "$seen" ] && { printf "%%s" "$a" > script; break; }; [ "$a" = -c ] && seen=1; done\n' > bin/airlock && chmod +x bin/airlock && PATH="$PWD/bin:$PATH" /Users/visa/src/airlock-claude/airlock-claude2 >/dev/null; bash -n script && grep -c '^cat > ' script
```
Expected: `3` (three files written) and no syntax error. Remove the temp directory afterwards.

- [ ] **Step 6: Commit**

```bash
git add airlock-claude2 test-airlock-claude2
git commit -m "airlock-claude2: prepare the sandbox on every launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Rebuild and the session log

**Files:**
- Modify: `airlock-claude2` (add `remove_sandbox_on_rebuild`, `sandbox_dir`, `keep_previous_pty_dump`, `strip_terminal_escapes`, `print_pty_dump_tail`; extend the main sequence)
- Modify: `test-airlock-claude2` (two new sections before the summary)

**Interfaces:**
- Consumes: `REBUILD` from `parse_args`; the `airlock` stub's `info`, `remove`, `STUB_PTY_DUMP`, `STUB_EXIT`, `STUB_REMOVE_EXIT`, `STUB_NO_SANDBOX`.
- Produces: `remove_sandbox_on_rebuild <rebuild>`, `sandbox_dir`, `keep_previous_pty_dump <dump>`, `strip_terminal_escapes` (filter), `print_pty_dump_tail <dump> <max_lines>`.

- [ ] **Step 1: Add the "rebuild" and "session log" sections to the suite**

Insert this block into `test-airlock-claude2` immediately before the line `printf '\n%s\n' "----------------------------------------"`:

```bash
section "rebuild"
new_case; stub_all
run_script
assert_not_grep "^REMOVE:" "$LOG" "a plain run keeps the sandbox"

new_case; stub_all
mkdir -p "$STUB_BOX"; : > "$STUB_BOX/disk.img"
run_script -r
assert_rc 0 "$RC" "-r exits 0"
assert_grep "^REMOVE: remove --force$" "$LOG" "-r removes the sandbox through airlock, without a prompt"
assert_absent "$STUB_BOX/disk.img" "the sandbox disk is gone"
assert_eq "REMOVE" "$(grep -o '^REMOVE\|^LAUNCH' "$LOG" | head -1)" "the removal happens before the launch"
assert_grep "^LAUNCH: start" "$LOG" "-r still launches, which brings the wizard back"

new_case; stub_all
run_script --rebuild
assert_grep "^REMOVE: remove --force$" "$LOG" "--rebuild is the long form"

new_case; stub_all
export STUB_REMOVE_EXIT=1
run_script -r
assert_rc 1 "$RC" "a failed removal exits 1"
assert_not_grep "^LAUNCH:" "$LOG" "a failed removal does not launch on the old sandbox"

section "session log"
new_case; stub_all
run_script
assert_grep "LAUNCH_PTY_DUMP: 1" "$LOG" "launch asks airlock to dump the session pty"
assert_not_grep "last session output" "$CASE_DIR/err" "no dump means no tail"

new_case; stub_all
export STUB_PTY_DUMP='plain first line\r\n\0033]0;title\0007\0033[1mbold\0033[0m styled line\r\n'
run_script
assert_grep "last session output" "$CASE_DIR/err" "a dump is followed by its tail"
assert_grep "$STUB_BOX/pty.dump" "$CASE_DIR/err" "the tail names the whole log, in the sandbox directory"
assert_grep "plain first line" "$CASE_DIR/err" "dump text reaches the tail"
assert_grep "bold styled line" "$CASE_DIR/err" "escape sequences are stripped from around the text"
assert_not_grep "$(printf '\033')" "$CASE_DIR/err" "no raw escape bytes reach the terminal"
assert_not_grep "last session output" "$CASE_DIR/out" "the tail goes to stderr, keeping stdout clean for -p"

new_case; stub_all
NUMBERED=''
i=1
while [ "$i" -le 20 ]; do NUMBERED="${NUMBERED}numbered line $i\r\n"; i=$((i + 1)); done
export STUB_PTY_DUMP=$NUMBERED
run_script
assert_grep "numbered line 20" "$CASE_DIR/err" "the tail ends at the last line of the dump"
assert_grep "numbered line 6" "$CASE_DIR/err" "the tail reaches 15 lines back"
assert_not_grep "numbered line 5\$" "$CASE_DIR/err" "the tail stops at 15 lines"

new_case; stub_all
export STUB_PTY_DUMP='overwritten frame\rfinal frame\r\n'
run_script
assert_grep "final frame" "$CASE_DIR/err" "the last carriage-return overwrite survives"
assert_not_grep "framefinal frame" "$CASE_DIR/err" "overwritten frames are not glued together"

new_case; stub_all
export STUB_EXIT=7 STUB_PTY_DUMP='session died\r\n'
run_script
assert_rc 7 "$RC" "airlock's exit status is preserved past the tail"
assert_grep "session died" "$CASE_DIR/err" "the tail still prints when airlock fails"

new_case; stub_all
mkdir -p "$STUB_BOX"
printf 'earlier session\n' > "$STUB_BOX/pty.dump"
export STUB_PTY_DUMP='current session\r\n'
run_script
assert_grep "earlier session" "$STUB_BOX/pty.dump.previous" "the previous run's log is kept"
assert_grep "current session" "$STUB_BOX/pty.dump" "the new run's log replaces it"
assert_grep "current session" "$CASE_DIR/err" "the tail shows the new run"
assert_not_grep "earlier session" "$CASE_DIR/err" "the rotated log stays out of the tail"

new_case; stub_all
export STUB_NO_SANDBOX=1 STUB_PTY_DUMP='orphan output\r\n'
run_script
assert_rc 0 "$RC" "an unresolvable sandbox directory does not fail the run"
assert_not_grep "last session output" "$CASE_DIR/err" "no sandbox directory means no tail"
assert_not_grep "No sandbox for" "$CASE_DIR/err" "airlock info's complaint stays silent"
```

- [ ] **Step 2: Run the suite to see the new sections fail**

Run: `./test-airlock-claude2`
Expected: FAIL on "-r removes the sandbox through airlock", "a dump is followed by its tail", "the previous run's log is kept" and their neighbours; exit 1.

- [ ] **Step 3: Add the step functions**

In `airlock-claude2`, insert these functions between `require_airlock` and `session_script`:

```bash
remove_sandbox_on_rebuild() {
  local rebuild=$1
  [[ -n $rebuild ]] || return 0
  airlock remove --force >&2 || return 1
}

sandbox_dir() {
  airlock info --json 2>/dev/null | sed -n 's/^ *"dir": *"\(.*\)",\{0,1\}$/\1/p'
}

keep_previous_pty_dump() {
  local dump=$1
  if [[ -s $dump ]]; then
    mv -f "$dump" "$dump.previous"
  fi
}
```

And insert these after `session_script`, before the main sequence:

```bash
strip_terminal_escapes() {
  local esc=$'\033' bel=$'\007'
  LC_ALL=C tr -d '\000' \
    | LC_ALL=C tr '\r' '\n' \
    | LC_ALL=C sed -E \
        -e "s/${esc}\][^${bel}${esc}]*(${bel}|${esc}\\\\)?//g" \
        -e "s/${esc}[PX^_][^${esc}]*(${esc}\\\\)?//g" \
        -e "s/${esc}\[[^@-~]*[@-~]//g" \
        -e "s/${esc}[()][0-9A-Za-z]//g" \
        -e "s/${esc}.//g" \
    | LC_ALL=C tr -d '\001-\010\013\014\016-\037\177'
}

print_pty_dump_tail() {
  local dump=$1 max_lines=$2
  [[ -s $dump ]] || return 0
  local last_lines
  last_lines=$(tail -c 65536 "$dump" | strip_terminal_escapes \
    | LC_ALL=C sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -n "$max_lines")
  [[ -n $last_lines ]] || return 0
  printf 'airlock-claude2: last session output (whole log: %s):\n' "$dump"
  printf '%s\n' "$last_lines" | sed 's/^/  /'
}
```

- [ ] **Step 4: Extend the main sequence**

Replace everything from `require_airlock || exit 1` to the end of `airlock-claude2` with:

```bash
require_airlock || exit 1

remove_sandbox_on_rebuild "$REBUILD" || exit 1

SANDBOX_DIR=$(sandbox_dir)
[[ -n $SANDBOX_DIR ]] && keep_previous_pty_dump "$SANDBOX_DIR/pty.dump"

SESSION_SCRIPT=$(session_script "$USE_TMUX")
if [[ -n $EXEC ]]; then
  SESSION_COMMAND=("${CLAUDE_ARGS[@]}")
else
  SESSION_COMMAND=(claude "${CLAUDE_ARGS[@]}")
fi

AIRLOCK_PTY_DUMP=1 airlock start ${MONITOR:+--monitor} --network deny-by-default -- bash -c "$SESSION_SCRIPT" airlock-claude2 "${SESSION_COMMAND[@]}"
AIRLOCK_EXIT=$?

SANDBOX_DIR=$(sandbox_dir)
[[ -n $SANDBOX_DIR ]] && print_pty_dump_tail "$SANDBOX_DIR/pty.dump" 15 >&2
exit "$AIRLOCK_EXIT"
```

The function definition order in the file must now be: `usage`, `parse_args`, `validate_exec_usage`, `require_airlock`, `remove_sandbox_on_rebuild`, `sandbox_dir`, `keep_previous_pty_dump`, `session_script`, `strip_terminal_escapes`, `print_pty_dump_tail`, then the main sequence.

- [ ] **Step 5: Run the suite to see it pass**

Run: `./test-airlock-claude2`
Expected: `NN passed, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add airlock-claude2 test-airlock-claude2
git commit -m "airlock-claude2: -r through airlock remove, session log tail

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Docs

**Files:**
- Create: `README2.md`
- Create: `AGENTS2.md`

**Interfaces:**
- Consumes: the finished script's flags and behaviour from Tasks 1 to 3.

- [ ] **Step 1: Write README2.md**

Create `README2.md` with exactly this content:

````markdown
# airlock-claude2

Run Claude Code sandboxed in
[airlock](https://github.com/milankinen/airlock), in any directory, on top
of airlock's own packs and templates. Copy this one script anywhere on your
`PATH`; it starts the project's sandbox with network access denied by
default and drops you into a Claude Code session inside tmux.

## Prerequisites

- [`airlock`](https://github.com/milankinen/airlock), a version with packs
  and templates (`airlock templates` exists).
- Nothing else: no container engine, no image build. The sandbox is
  airlock's `alpine` pack plus its `claude` pack, or a template built from
  them.

## Usage

From any directory you want to work in:

```sh
airlock-claude2
```

**First run in a project.** airlock's setup wizard appears. Select
`alpine` as the base image and `claude` under coding agents, or select a
template if you have one, then `start`. airlock installs the packs onto
the sandbox disk (a minute or two) and the session begins. Later runs
skip the wizard. The wizard needs a terminal, so run a project's first
session interactively before scripting `-p` runs in it.

**Templates.** `airlock templates create <name>` runs the same wizard
once and keeps the result; a sandbox made from the template starts at
once, with nothing to install. The wizard lists your templates at the top.

The session runs in bypass-permissions mode — the VM is the sandbox, so
permission prompts aren't what's keeping it contained — with network
access denied by default: the Claude API and sign-in hosts (from the
`claude` pack), the Alpine package mirrors (from the `alpine` pack) and
whatever rules your project's `airlock.toml` adds are reachable, nothing
else.

Anything after `--` is passed to `claude` unchanged; with `-x`, it
*replaces* `claude` as the command run in the VM:

```sh
airlock-claude2 -- --resume
airlock-claude2 -M -- -p "run the tests and fix failures"
airlock-claude2 -x -- bash               # a sandboxed shell, no claude
```

### Flags

- `-T`, `--no-tmux` — run `claude` directly instead of inside tmux.
- `-M`, `--no-monitor` — skip `airlock`'s monitor TUI, which shows the
  network policy at work.
- `-x`, `--exec` — run the command after `--` in place of `claude`.
- `-r`, `--rebuild` — remove the project's sandbox (`airlock remove`) and
  start again, so airlock makes a fresh one and the wizard runs again.
  Anything installed inside the VM is lost; your persisted Claude settings
  and login are not.

## Things to know

**What runs before the session.** Every launch first runs a short script
inside the sandbox: it installs tmux with `apk add` if it is missing,
writes `/etc/tmux.conf` (mouse on, copies go to the host clipboard), and
writes Claude Code's managed settings (bypass permissions) and managed
`CLAUDE.md` under `/etc/claude-code`. The files are rewritten on every
launch, so a newer script reaches an existing sandbox without `-r`, and a
sandbox airlock re-created behind your back heals itself.

**tmux.** The session runs inside tmux, so you can split a pane and have a
shell next to Claude Code without leaving the sandbox. Detaching
(`prefix+d`) doesn't leave a session to come back to — the tmux client is
what `airlock` waits on, so detaching stops the VM.

**Login.** Your host `~/.claude` stays on the host; the `claude` pack mounts
its own, shared by every sandbox with the pack. Run `/login` in the
session: the sign-in page opens in your host browser, the real tokens stay
on the host, and the session only ever sees surrogates. A
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` on the host (or in
`airlock`'s vault) is used the same way.

**Network.** The script passes `--network deny-by-default` on every run.
That overrides the policy in your `airlock.toml` for the run; the rules in
it still apply. Allow more by adding rules there, or temporarily from the
monitor.

**Session log.** Every run records the session's raw terminal stream to
`pty.dump` in the sandbox directory (`airlock info` shows it; one previous
run is kept as `pty.dump.previous`), and when `airlock` exits the last
lines are reprinted, escape-stripped — the monitor and tmux restore the
host screen on exit and would otherwise take a crash's final words with
them. The tail goes to stderr, so `-p` output on stdout stays clean.

**Python HTTPS.** Allowed HTTPS traffic is re-signed by `airlock`'s TLS
proxy, and Python 3.13+ strict certificate checking rejects its
certificates (`Missing Authority Key Identifier`); `curl`, `git` and `pip`
are fine. The managed `/etc/claude-code/CLAUDE.md` already tells every
session the per-client workaround, how to recognise a network-policy
denial, that packages come from `apk`, and to leave host-made virtualenvs
alone.

The script writes no config file. The wizard's answers live in the
sandbox directory, and `airlock remove` deletes them with it; a project's
own `airlock.toml` applies as usual.

For how each step works and why it's shaped the way it is, see
[AGENTS2.md](AGENTS2.md).
````

- [ ] **Step 2: Write AGENTS2.md**

Create `AGENTS2.md` with exactly this content:

````markdown
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
  `printf` each), so a changed text in a newer script reaches an existing
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
````

- [ ] **Step 3: Check the docs against the script**

Run:
```bash
grep -c -- '-r, --rebuild' airlock-claude2 README2.md AGENTS2.md
grep -n 'network deny-by-default' airlock-claude2 README2.md AGENTS2.md | wc -l
./test-airlock-claude2 | tail -1
```
Expected: each file has at least one match on the first two lines; the last line is `NN passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add README2.md AGENTS2.md
git commit -m "Document airlock-claude2 for users and agents

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
