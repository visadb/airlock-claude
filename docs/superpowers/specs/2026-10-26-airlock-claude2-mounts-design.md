# airlock-claude2 mounts design

Adds `--mount-rw <dir>` and `--mount-ro <dir>` to `airlock-claude2`.
Extends `docs/superpowers/specs/2026-10-26-airlock-claude2-design.md`,
whose "writes no config" rule gets one exception: a marked block in
`airlock.local.toml` that holds the mounts.

## Flags

`--mount-rw <dir>`, `--mount-ro <dir>`, also `--mount-rw=<dir>` and
`--mount-ro=<dir>`. Repeatable, combinable with `-x`. Each directory is
resolved to its absolute host path and mounted into the VM under the
project directory as its basename, read-write or read-only.

Validation (each failure: message on stderr, exit 2, nothing written,
no launch): a value is present; it is a directory; it is not the project
directory (always mounted); it is not `/`; no two mounts share a
basename.

## The block

The mounts are one marked block of `airlock.local.toml` in the project:

```
# BEGIN airlock-claude2 mounts (rewritten on every airlock-claude2 run)
[mounts."other"]
source = "/abs/path/other"
target = "other"
read_only = false
# END airlock-claude2 mounts
```

On every run: the existing file (if any) is read with the old block
stripped (`# BEGIN airlock-claude2 mounts` to `# END airlock-claude2
mounts`, inclusive); if mounts were given, a fresh block is appended
after the kept content (one blank line between); if the result holds
only whitespace the file is removed; otherwise it is written. Content
outside the block is never changed. Nothing is written when the file is
absent and no mounts were given. A read or write failure prints
`airlock-claude2: could not read|write airlock.local.toml in <dir>` and
exits 1 before the launch.

A `# BEGIN airlock-claude2 mounts` line without its `# END` line is
refused (message on stderr, exit 1, file untouched) rather than stripped
to the end of the file. A run without mounts leaves a file that holds no
block byte-identical. A control character in a mount path is rejected
(exit 2), since a TOML basic string cannot carry it.

TOML escaping of the key, source and target: `\` → `\\`, `"` → `\"`.

## First-run refusal

Mounts are refused (exit 2, message: run once without mounts so
airlock's setup wizard can create the sandbox) when all hold: mounts
were given; `-r` was passed or no sandbox exists (`airlock info --json`
yields no directory); and the project has no config that would already
keep the wizard away. "Has config" means any of `airlock.{toml,json,yaml,yml}`
or `airlock.local.{json,yaml,yml}` exists, or `airlock.local.toml` exists
with content outside the block. The check runs before `airlock remove`,
so `-r` with mounts fails without touching the sandbox.

## Steps, in call order

```
parse_args "$@"                      also MOUNTS_RW, MOUNTS_RO
validate_exec_usage <exec> <count>
require_airlock
resolve_extra_mounts                 sets MOUNT_SOURCES, MOUNT_TARGETS, MOUNT_READ_ONLY (array exemption)
without_mounts_block <file>          -> the file minus the block
project_config_present               -> 1 if the project has config the wizard would respect, or nothing
sandbox_dir                          -> the sandbox directory, or nothing
refuse_mounts_on_first_run <count> <rebuild> <sandbox_dir> <has_config>
remove_sandbox_on_rebuild <rebuild>
toml_escaped <s>
extra_mounts_block                   -> the marked block, or nothing (reads the arrays)
write_mounts_block <block>           rewrites airlock.local.toml, or removes it
sandbox_dir, keep_previous_pty_dump, session_script, launch, tail  (unchanged)
```

`resolve_extra_mounts` and `extra_mounts_block` are the second array
exemption: bash arrays can't ride through stdout, so the resolved
mounts are globals set by the one and read by the other, like
`CLAUDE_ARGS` from `parse_args`.

## airlock behaviour to document

- A changed mount set is a config change: `airlock start` asks once,
  interactively; without a terminal it aborts with exit 2, so change
  mounts in an interactive run first.
- The mount point directory airlock creates under the project remains,
  empty, after the session; a same-named project directory is shadowed
  for the session.
- `airlock.local.toml` belongs in the project's `.gitignore`.

## Tests

Section "extra mounts": the old suite's cases (rw, ro, repeatable with
per-mount modes, joined form, relative path, space and quote in names,
`-x` combination, missing value, nonexistent, plain file, basename
collision, project dir, root) with the block markers as first and last
line. Section "mounts and the local config file": foreign content kept
and the block appended after it; block replaced on the next run; a run
without flags removes the block and keeps the rest; a block-only file
is removed; a directory in the file's place fails with exit 1 and no
launch. Section "mounts on a first run": no sandbox refuses (exit 2,
no file, no launch); allowed with an `airlock.toml`; allowed with a
foreign `airlock.local.toml`; refused when `airlock.local.toml` holds
only an old block; `-r` with mounts refuses before any removal; `-r`
without mounts removes a leftover block-only file.
