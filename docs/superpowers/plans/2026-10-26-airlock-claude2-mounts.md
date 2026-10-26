# airlock-claude2 mounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--mount-rw`/`--mount-ro` to `airlock-claude2`, carried as a marked block in `airlock.local.toml`, refused on a run where airlock's wizard would appear.

**Architecture:** New step functions in the existing one-function-per-step script: resolve and validate the mounts into arrays, decide whether the wizard would run, strip-and-append the marked block, then the unchanged launch. The suite gets three sections driving the real script against the existing `airlock` stub.

**Tech Stack:** bash 3.2+, the existing `test-airlock-claude2` harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-26-airlock-claude2-mounts-design.md` (read first) on top of `docs/superpowers/specs/2026-10-26-airlock-claude2-design.md`.
- Shebang `#!/bin/bash`; must run under macOS bash 3.2.
- One function per step, defined in call order, called in that order at the bottom; locals on the first line; outputs printed; failure is a nonzero `return` with a message on stderr prefixed `airlock-claude2:`; only the main sequence exits. Array exemptions: `parse_args` (sets `MOUNTS_RW`, `MOUNTS_RO`), `resolve_extra_mounts` (sets `MOUNT_SOURCES`, `MOUNT_TARGETS`, `MOUNT_READ_ONLY`), `extra_mounts_block` (reads them).
- No comments in the scripts. Reasoning goes in `AGENTS2.md`, user docs in `README2.md`.
- The launch line is unchanged.
- Block markers, exactly: first line `# BEGIN airlock-claude2 mounts (rewritten on every airlock-claude2 run)`, last line `# END airlock-claude2 mounts`.
- Tests: every case runs in its own temp directory via `new_case`/`run_script`; labels are claims; `TOOLS` holds `sed tail cat tr mv rm mkdir`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commits land on `main`.
- `airlock-claude`, `test-airlock-claude`, `README.md`, `AGENTS.md` are not modified.

---

### Task 1: Mount flags, the block, the first-run refusal

**Files:**
- Modify: `airlock-claude2`
- Modify: `test-airlock-claude2` (three new sections before the summary line `printf '\n%s\n' "----------------------------------------"`)

**Interfaces:**
- Consumes: `parse_args`, `require_airlock`, `sandbox_dir`, `remove_sandbox_on_rebuild`, the stub's `STUB_NO_SANDBOX`, `STUB_BOX`, `REMOVE:`/`LAUNCH:` log lines, the `CONFIG`-less harness (add a `CONFIG` helper).
- Produces: `resolve_extra_mount <flag> <dir> <read_only>`, `resolve_extra_mounts`, `without_mounts_block <file>`, `project_config_present`, `refuse_mounts_on_first_run <count> <rebuild> <sandbox_dir> <has_config>`, `toml_escaped <s>`, `extra_mounts_block`, `write_mounts_block <block>`.

- [ ] **Step 1: Add the tests**

Add this helper to `test-airlock-claude2` right after the `SESSION_SCRIPT() { ... }` line:

```bash
CONFIG() { echo "$WORK/airlock.local.toml"; }
```

Insert these three sections immediately before the summary line:

```bash
section "extra mounts"
new_case; stub_all
mkdir -p "$CASE_DIR/other"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 0 "$RC" "--mount-rw with a directory exits 0"
assert_grep '^\[mounts."other"\]$' "$(CONFIG)" "--mount-rw adds a mounts table named after the directory"
assert_grep "^source = \"$CASE_DIR/other\"\$" "$(CONFIG)" "the mount's source is the host directory"
assert_grep '^target = "other"$' "$(CONFIG)" "the mount's target is the basename, relative to the project"
assert_grep '^read_only = false$' "$(CONFIG)" "--mount-rw mounts read-write"
assert_eq "# BEGIN airlock-claude2 mounts (rewritten on every airlock-claude2 run)" "$(sed -n 1p "$(CONFIG)")" \
  "the block opens with its marker, which says the block is the script's"
assert_eq "# END airlock-claude2 mounts" "$(tail -n 1 "$(CONFIG)")" "the block closes with its marker"
assert_grep "^LAUNCH:" "$LOG" "--mount-rw still launches"

new_case; stub_all
mkdir -p "$CASE_DIR/reference"
run_script --mount-ro "$CASE_DIR/reference"
assert_grep '^\[mounts."reference"\]$' "$(CONFIG)" "--mount-ro adds a mounts table"
assert_grep '^read_only = true$' "$(CONFIG)" "--mount-ro mounts read-only"

new_case; stub_all
mkdir -p "$CASE_DIR/one" "$CASE_DIR/two" "$CASE_DIR/three"
run_script --mount-rw "$CASE_DIR/one" --mount-rw "$CASE_DIR/two" --mount-ro "$CASE_DIR/three"
assert_grep '^\[mounts."one"\]$' "$(CONFIG)" "the flags are repeatable (first)"
assert_grep '^\[mounts."two"\]$' "$(CONFIG)" "the flags are repeatable (second)"
assert_grep '^\[mounts."three"\]$' "$(CONFIG)" "read-write and read-only mounts combine"
assert_eq "false
false
true" "$(sed -n 's/^read_only = //p' "$(CONFIG)")" "each mount keeps its own mode"
assert_eq "1" "$(grep -c '^# BEGIN airlock-claude2 mounts' "$(CONFIG)")" "all mounts share one block"

new_case; stub_all
mkdir -p "$CASE_DIR/joined"
run_script --mount-ro="$CASE_DIR/joined"
assert_grep '^\[mounts."joined"\]$' "$(CONFIG)" "--mount-ro=dir is the joined form"

new_case; stub_all
mkdir -p "$CASE_DIR/sibling"
run_script --mount-rw ../sibling
assert_grep "^source = \"$CASE_DIR/sibling\"\$" "$(CONFIG)" "a relative directory is resolved to its host path"

new_case; stub_all
mkdir -p "$CASE_DIR/with space" "$CASE_DIR/"'qu"ote'
run_script --mount-rw "$CASE_DIR/with space" --mount-ro "$CASE_DIR/"'qu"ote'
assert_grep '^\[mounts."with space"\]$' "$(CONFIG)" "a name with a space stays one TOML key"
assert_grep '^\[mounts."qu\\"ote"\]$' "$(CONFIG)" "a double quote in the name is escaped in the key"
assert_grep 'source = ".*qu\\"ote"' "$(CONFIG)" "a double quote in the path is escaped in the source"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
run_script --mount-ro "$CASE_DIR/other" -x -- bash
assert_rc 0 "$RC" "mounts combine with -x"
assert_grep '^\[mounts."other"\]$' "$(CONFIG)" "the mount reaches the config with -x"

new_case; stub_all
run_script --mount-rw
assert_rc 2 "$RC" "--mount-rw without a value exits 2"
assert_grep "needs a directory" "$CASE_DIR/err" "missing mount value explains itself"

new_case; stub_all
run_script --mount-ro "$CASE_DIR/does-not-exist"
assert_rc 2 "$RC" "a nonexistent mount directory exits 2"
assert_grep "not a directory" "$CASE_DIR/err" "a nonexistent mount directory explains itself"
assert_absent "$(CONFIG)" "a bad mount writes no config"
assert_not_grep "LAUNCH:" "$LOG" "a bad mount does not launch"

new_case; stub_all
touch "$CASE_DIR/plain-file"
run_script --mount-rw "$CASE_DIR/plain-file"
assert_rc 2 "$RC" "a file as a mount source exits 2"

new_case; stub_all
mkdir -p "$CASE_DIR/a/same" "$CASE_DIR/b/same"
run_script --mount-rw "$CASE_DIR/a/same" --mount-ro "$CASE_DIR/b/same"
assert_rc 2 "$RC" "two mounts with one basename exit 2"
assert_grep "both appear as ./same" "$CASE_DIR/err" "the basename collision is named"

new_case; stub_all
run_script --mount-rw .
assert_rc 2 "$RC" "mounting the project directory itself exits 2"
assert_grep "always mounted" "$CASE_DIR/err" "the project-directory mount explains itself"

new_case; stub_all
run_script --mount-ro /
assert_rc 2 "$RC" "mounting the filesystem root exits 2"

section "mounts and the local config file"
new_case; stub_all
mkdir -p "$CASE_DIR/other"
printf '[vm]\ncpus = 2\n' > "$(CONFIG)"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 0 "$RC" "an existing airlock.local.toml is accepted"
assert_eq "[vm]" "$(sed -n 1p "$(CONFIG)")" "content already in the file stays first"
assert_grep '^cpus = 2$' "$(CONFIG)" "content already in the file is kept"
assert_eq "# END airlock-claude2 mounts" "$(tail -n 1 "$(CONFIG)")" "the block is appended after it"
assert_eq "" "$(sed -n 3p "$(CONFIG)")" "one blank line separates the kept content from the block"

new_case; stub_all
mkdir -p "$CASE_DIR/one" "$CASE_DIR/two"
run_script --mount-rw "$CASE_DIR/one"
run_script --mount-ro "$CASE_DIR/two"
assert_not_grep '"one"' "$(CONFIG)" "the next run's block replaces the previous mounts"
assert_grep '^\[mounts."two"\]$' "$(CONFIG)" "the next run's mounts are in"
assert_eq "1" "$(grep -c '^# BEGIN airlock-claude2 mounts' "$(CONFIG)")" "replacing leaves one block, not two"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
printf '[vm]\ncpus = 2\n' > "$(CONFIG)"
run_script --mount-rw "$CASE_DIR/other"
run_script
assert_rc 0 "$RC" "a run without mount flags exits 0"
assert_grep '^cpus = 2$' "$(CONFIG)" "a run without mount flags keeps the content that is not the script's"
assert_not_grep "airlock-claude2 mounts" "$(CONFIG)" "a run without mount flags removes the block"
assert_not_grep "mounts\." "$(CONFIG)" "no mount survives a run without mount flags"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
run_script --mount-rw "$CASE_DIR/other"
run_script
assert_absent "$(CONFIG)" "a file that held only the block is removed, so it cannot suppress the wizard later"

new_case; stub_all
mkdir -p "$CASE_DIR/other" "$(CONFIG)"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 1 "$RC" "an unreadable airlock.local.toml exits 1"
assert_grep "could not read airlock.local.toml" "$CASE_DIR/err" "an unreadable airlock.local.toml says so"
assert_not_grep "LAUNCH:" "$LOG" "an unreadable airlock.local.toml does not launch"

section "mounts on a first run"
new_case; stub_all
mkdir -p "$CASE_DIR/other"
export STUB_NO_SANDBOX=1
run_script --mount-rw "$CASE_DIR/other"
assert_rc 2 "$RC" "mounts on a project with no sandbox exit 2"
assert_grep "run once without mounts" "$CASE_DIR/err" "the refusal says the wizard has to create the sandbox first"
assert_absent "$(CONFIG)" "the refusal writes no file, so the wizard is not suppressed"
assert_not_grep "LAUNCH:" "$LOG" "the refusal does not launch"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
export STUB_NO_SANDBOX=1
printf '[packs]\nalpine = { version = "1" }\n' > "$WORK/airlock.toml"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 0 "$RC" "mounts on a first run are fine when an airlock.toml keeps the wizard away"
assert_grep '^\[mounts."other"\]$' "$(CONFIG)" "the block is written next to the project's airlock.toml"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
export STUB_NO_SANDBOX=1
printf '[vm]\ncpus = 2\n' > "$(CONFIG)"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 0 "$RC" "mounts on a first run are fine when a hand-written airlock.local.toml keeps the wizard away"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
export STUB_NO_SANDBOX=1
printf '%s\n' '# BEGIN airlock-claude2 mounts (rewritten on every airlock-claude2 run)' '[mounts."old"]' \
  'source = "/old"' 'target = "old"' 'read_only = false' '# END airlock-claude2 mounts' > "$(CONFIG)"
run_script --mount-rw "$CASE_DIR/other"
assert_rc 2 "$RC" "an old block of the script's own does not count as config that keeps the wizard away"

new_case; stub_all
mkdir -p "$CASE_DIR/other" "$STUB_BOX"; : > "$STUB_BOX/disk.img"
run_script -r --mount-rw "$CASE_DIR/other"
assert_rc 2 "$RC" "-r with mounts exits 2, since the rebuilt sandbox needs the wizard"
assert_not_grep "^REMOVE:" "$LOG" "-r with mounts is refused before anything is removed"
assert_exists "$STUB_BOX/disk.img" "the sandbox survives a refused -r"

new_case; stub_all
mkdir -p "$CASE_DIR/other"
run_script --mount-rw "$CASE_DIR/other"
run_script -r
assert_grep "^REMOVE: remove --force$" "$LOG" "-r without mounts removes the sandbox"
assert_absent "$(CONFIG)" "-r without mounts also drops a block-only file, so the wizard runs again"
assert_grep "^LAUNCH:" "$LOG" "-r without mounts launches"
```

- [ ] **Step 2: Run the suite to see the new sections fail**

Run: `./test-airlock-claude2 | grep -c FAIL`
Expected: a nonzero count; "unknown option: --mount-rw" is the dominant failure.

- [ ] **Step 3: Extend `parse_args`**

In `airlock-claude2`, change the first line of `parse_args` to:

```bash
  MONITOR=1 USE_TMUX=1 EXEC= REBUILD= SHOW_USAGE= CLAUDE_ARGS=() MOUNTS_RW=() MOUNTS_RO=()
```

and add these cases before the `-x|--exec)` case:

```bash
      --mount-rw|--mount-ro)
        if [[ $# -lt 2 ]]; then
          echo "airlock-claude2: $1 needs a directory" >&2
          return 2
        fi
        if [[ $1 == --mount-rw ]]; then MOUNTS_RW+=("$2"); else MOUNTS_RO+=("$2"); fi
        shift ;;
      --mount-rw=*) MOUNTS_RW+=("${1#--mount-rw=}") ;;
      --mount-ro=*) MOUNTS_RO+=("${1#--mount-ro=}") ;;
```

Update `usage`: add `[--mount-rw <dir>] [--mount-ro <dir>]` to both synopsis lines (reflow to keep them under 80 columns), and these entries after `-T, --no-tmux`:

```
  --mount-rw <dir>  Mount another host directory into the VM, read-write,
                    under the project directory as its basename: e.g.
                    --mount-rw ../other-project appears as ./other-project
                    in the session. Repeatable. The mounts are kept in a
                    marked block of airlock.local.toml, rewritten on every
                    run, and need a sandbox to exist already (run once
                    without mounts first, so the setup wizard can run).
  --mount-ro <dir>  Like --mount-rw, but read-only.
```

- [ ] **Step 4: Add the step functions**

Insert after `require_airlock`:

```bash
resolve_extra_mount() {
  local flag=$1 dir=$2 read_only=$3
  local source target existing
  if [[ -z $dir ]]; then
    echo "airlock-claude2: $flag needs a directory" >&2
    return 2
  fi
  if [[ ! -d $dir ]]; then
    echo "airlock-claude2: $flag: not a directory: $dir" >&2
    return 2
  fi
  source=$(CDPATH= cd -- "$dir" 2>/dev/null && pwd) || {
    echo "airlock-claude2: $flag: cannot resolve: $dir" >&2
    return 2
  }
  if [[ $source == "$PWD" ]]; then
    echo "airlock-claude2: $flag: $dir is the project directory, which is always mounted" >&2
    return 2
  fi
  target=${source##*/}
  if [[ -z $target ]]; then
    echo "airlock-claude2: $flag: cannot mount the filesystem root" >&2
    return 2
  fi
  for existing in ${MOUNT_TARGETS[@]+"${MOUNT_TARGETS[@]}"}; do
    if [[ $existing == "$target" ]]; then
      echo "airlock-claude2: two mounts would both appear as ./$target; rename one on the host" >&2
      return 2
    fi
  done
  MOUNT_SOURCES+=("$source")
  MOUNT_TARGETS+=("$target")
  MOUNT_READ_ONLY+=("$read_only")
}

resolve_extra_mounts() {
  MOUNT_SOURCES=() MOUNT_TARGETS=() MOUNT_READ_ONLY=()
  local dir
  for dir in ${MOUNTS_RW[@]+"${MOUNTS_RW[@]}"}; do
    resolve_extra_mount --mount-rw "$dir" false || return $?
  done
  for dir in ${MOUNTS_RO[@]+"${MOUNTS_RO[@]}"}; do
    resolve_extra_mount --mount-ro "$dir" true || return $?
  done
}

without_mounts_block() {
  local file=$1
  sed '/^# BEGIN airlock-claude2 mounts/,/^# END airlock-claude2 mounts$/d' "$file"
}

project_config_present() {
  local ext
  for ext in toml json yaml yml; do
    [[ -e airlock.$ext ]] && { printf '1\n'; return 0; }
  done
  for ext in json yaml yml; do
    [[ -e airlock.local.$ext ]] && { printf '1\n'; return 0; }
  done
  if [[ -f airlock.local.toml ]] && [[ -n $(without_mounts_block airlock.local.toml | tr -d '[:space:]') ]]; then
    printf '1\n'
  fi
  return 0
}
```

Move the existing `sandbox_dir` function so it comes right after `project_config_present`, then insert after it:

```bash
refuse_mounts_on_first_run() {
  local mount_count=$1 rebuild=$2 sandbox=$3 has_config=$4
  (( mount_count > 0 )) || return 0
  [[ -z $has_config ]] || return 0
  if [[ -n $rebuild || -z $sandbox ]]; then
    echo "airlock-claude2: --mount-rw/--mount-ro need a sandbox to exist already: run once without mounts, so airlock's setup wizard can create it" >&2
    return 2
  fi
}
```

Keep `remove_sandbox_on_rebuild` next. Insert after it:

```bash
toml_escaped() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s\n' "$s"
}

extra_mounts_block() {
  (( ${#MOUNT_SOURCES[@]} > 0 )) || return 0
  local i source target
  printf '# BEGIN airlock-claude2 mounts (rewritten on every airlock-claude2 run)\n'
  for ((i = 0; i < ${#MOUNT_SOURCES[@]}; i++)); do
    source=$(toml_escaped "${MOUNT_SOURCES[i]}")
    target=$(toml_escaped "${MOUNT_TARGETS[i]}")
    printf '[mounts."%s"]\nsource = "%s"\ntarget = "%s"\nread_only = %s\n' \
      "$target" "$source" "$target" "${MOUNT_READ_ONLY[i]}"
  done
  printf '# END airlock-claude2 mounts\n'
}

write_mounts_block() {
  local block=$1
  local kept= content
  if [[ -e airlock.local.toml ]]; then
    kept=$(without_mounts_block airlock.local.toml 2>/dev/null) || {
      echo "airlock-claude2: could not read airlock.local.toml in $PWD" >&2
      return 1
    }
  fi
  content=$kept
  [[ -n $block ]] && content=${content:+$content$'\n\n'}$block
  if [[ -z $(printf '%s' "$content" | tr -d '[:space:]') ]]; then
    [[ -e airlock.local.toml ]] && rm -f airlock.local.toml
    return 0
  fi
  printf '%s\n' "$content" > airlock.local.toml || {
    echo "airlock-claude2: could not write airlock.local.toml in $PWD" >&2
    return 1
  }
}
```

`keep_previous_pty_dump`, `session_script`, `strip_terminal_escapes`, `print_pty_dump_tail` stay after these, unchanged. Final definition order: usage, parse_args, validate_exec_usage, require_airlock, resolve_extra_mount, resolve_extra_mounts, without_mounts_block, project_config_present, sandbox_dir, refuse_mounts_on_first_run, remove_sandbox_on_rebuild, toml_escaped, extra_mounts_block, write_mounts_block, keep_previous_pty_dump, session_script, strip_terminal_escapes, print_pty_dump_tail.

- [ ] **Step 5: Extend the main sequence**

Replace the lines from `require_airlock || exit 1` through `remove_sandbox_on_rebuild "$REBUILD" || exit 1` with:

```bash
require_airlock || exit 1

resolve_extra_mounts || exit $?
refuse_mounts_on_first_run "${#MOUNT_SOURCES[@]}" "$REBUILD" "$(sandbox_dir)" "$(project_config_present)" || exit $?

remove_sandbox_on_rebuild "$REBUILD" || exit 1

write_mounts_block "$(extra_mounts_block)" || exit 1
```

The rest of the main sequence (rotation, session script, launch, tail, exit) is unchanged.

- [ ] **Step 6: Run the suite to see it pass**

Run: `bash -n airlock-claude2 && ./test-airlock-claude2 | tail -1`
Expected: `N passed, 0 failed`. Also run `./test-airlock-claude | tail -1` to confirm the old suite is untouched (`212 passed, 0 failed`). Keep both scripts at mode 0755.

- [ ] **Step 7: Commit**

```bash
git add airlock-claude2 test-airlock-claude2
git commit -m "airlock-claude2: --mount-rw/--mount-ro as a marked block in airlock.local.toml

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Docs

**Files:**
- Modify: `README2.md`
- Modify: `AGENTS2.md`

- [ ] **Step 1: README2.md**

In the Flags list, after the `-M, --no-monitor` entry, add:

```markdown
- `--mount-rw <dir>`, `--mount-ro <dir>` — bring other host directories
  into the sandbox, read-write or read-only (repeatable; see **Mounts**
  below).
```

In the "Things to know" section, after the **Network** paragraph, add:

```markdown
**Mounts.** Each `--mount-rw`/`--mount-ro` directory appears in the VM
under the project directory, named after its basename (two mounts can't
share one). The mounts are written as one marked block in the project's
`airlock.local.toml` — created if missing, the block replaced on every
run and removed on a run without mount flags, anything else in the file
left alone — so add `airlock.local.toml` to the project's `.gitignore`.
A changed mount set is a configuration change: `airlock` asks about it
once at start; accept it. Without a terminal that question aborts, so
change mounts in an interactive run first. Mounts need a sandbox to
exist already: on a project's first run they are refused, because the
file would keep the setup wizard from appearing; run once without them.
The mount point `airlock` creates in the project directory remains,
empty, after the session, and a same-named project directory is
shadowed for the session, untouched underneath.
```

Change the sentence "The script writes no config file. The wizard's answers live in the sandbox directory, and `airlock remove` deletes them with it; a project's own `airlock.toml` applies as usual." to:

```markdown
Apart from the mounts block, the script writes no config. The wizard's
answers live in the sandbox directory, and `airlock remove` deletes them
with it; a project's own `airlock.toml` applies as usual.
```

- [ ] **Step 2: AGENTS2.md**

Replace the step diagram with:

```
parse_args "$@"                      sets MONITOR, USE_TMUX, EXEC, REBUILD, SHOW_USAGE, CLAUDE_ARGS, MOUNTS_RW, MOUNTS_RO
validate_exec_usage <exec> <count>   -x needs a command after --
require_airlock
resolve_extra_mounts                 sets MOUNT_SOURCES, MOUNT_TARGETS, MOUNT_READ_ONLY (the array exemption)
project_config_present               -> 1 if the project has config the wizard would respect, or nothing
sandbox_dir                          -> the sandbox directory `airlock info` reports, or nothing
refuse_mounts_on_first_run <count> <rebuild> <sandbox_dir> <has_config>
remove_sandbox_on_rebuild <rebuild>  `airlock remove --force`
extra_mounts_block                   -> the marked [mounts] block, or nothing (reads the arrays)
write_mounts_block <block>           rewrites the block in airlock.local.toml, or removes the file
sandbox_dir                          again, for the rotation
keep_previous_pty_dump <dump>        sets last run's log aside as <dump>.previous
session_script <use_tmux>            -> the bash script that runs in the sandbox
    (the airlock start line — the handoff)
sandbox_dir                          again: a first run has no sandbox until airlock made one
print_pty_dump_tail <dump> <max>     -> the session's last lines, escape-stripped
```

In "Structure and conventions to preserve", extend the `parse_args` bullet: after "so the defaults live in the function." add: "`resolve_extra_mounts` and `extra_mounts_block` share the exemption for the same reason: the resolved mounts are three parallel arrays, set by the one and read by the other."

In "Why each step is the way it is", change the first bullet's opening to "**The script writes no config except the mounts block, and that is what makes templates work.**" and add these bullets after the `remove_sandbox_on_rebuild` bullet:

```markdown
- **The mounts are one marked block of `airlock.local.toml`, rewritten on
  every run.** `airlock start` has no mount flag, so a config file is the
  only way in, and `airlock.local.toml` is the one airlock reads but a
  project doesn't commit. The block is bounded by `# BEGIN airlock-claude2
  mounts` and `# END airlock-claude2 mounts` so the script can replace
  exactly its own lines and leave a hand-written file's other content
  alone; the BEGIN line says the block is rewritten, so a user editing the
  file knows not to edit inside it. A run without mount flags removes the
  block, and a file left holding only whitespace is removed with it —
  otherwise a leftover file would suppress the wizard after `-r`. A read
  or write failure aborts before the launch, since airlock would start on
  the previous file and silently not have the mounts.
- **`refuse_mounts_on_first_run` runs before `remove_sandbox_on_rebuild`.**
  A file in the project keeps the wizard from running, so mounts can't be
  combined with the start that creates the sandbox: no sandbox yet, or
  `-r`, and no project config of the user's own (`airlock.*`, a non-TOML
  `airlock.local.*`, or an `airlock.local.toml` with content outside the
  block — a leftover block of the script's own doesn't count). Checking
  before the removal is what keeps `-r --mount-rw x` from destroying the
  sandbox and then failing.
```

In "Non-obvious behavior", add:

```markdown
- **A changed mount set is a config change.** `airlock start` compares
  the config with the last run's and asks once; `--yes` or no terminal
  aborts with exit 2. The script does not pass
  `--allow-configuration-changes`, because that would also wave through
  an `airlock.toml` edited by code inside the sandbox.
- **The mount point stays behind.** airlock creates the target directory
  under the project and leaves it, empty, after the session; `.gitignore`
  it along with `airlock.local.toml`.
```

In "Working on the test suite", add a bullet: "The `CONFIG` helper names `airlock.local.toml` in the case's work directory; the stub's `remove` deletes only the pretend sandbox, as the real one does, so the suite can assert what the script itself does to the file."

- [ ] **Step 3: Check and commit**

Run `./test-airlock-claude2 | tail -1` (unchanged, must still pass) and read both docs once against `airlock-claude2 --help`.

```bash
git add README2.md AGENTS2.md
git commit -m "Document the airlock-claude2 mount flags

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
