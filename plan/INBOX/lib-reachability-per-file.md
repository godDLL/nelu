# Lib reachability: per-file tickets

**Status:** INBOX -- sub-tasks created after `plan/INBOX/splice-env-locals.md`
lands. Each lib file compiles independently once the splice-block-local
blocker is fixed; each one that still fails gets its own ticket here.

## How to use

1. Land `splice-env-locals.md` (the `##`-block-sees-nelua-locals fix).
2. Re-scan: `for f in lib/*.nelua; do tmp/nelua -c -o /tmp/x $f; done`.
3. For every file that still fails, create `plan/INBOX/lib-<name>.md` with
   the exact error, a minimal repro, and the smallest fix.
4. A file that compiles end-to-end is DONE -- delete its placeholder here.

## The 21 files (baseline: 0/21 compile on committed HEAD)

Grouped by likely family so tickets can be batched:

**String family** (heavy `##` splice + cstring/cvarargs):
- `lib/string.nelua`
- `lib/stringbuilder.nelua`
- `lib/utf8.nelua`

**Numeric / math**:
- `lib/math.nelua`
- `lib/hash.nelua` (the first blocker; unblocks once splice-env is fixed)
- `lib/hashmap.nelua`

**Containers**:
- `lib/list.nelua`
- `lib/vector.nelua`
- `lib/table.nelua`
- `lib/sequence.nelua`
- `lib/span.nelua`

**I/O and OS**:
- `lib/io.nelua`
- `lib/filestream.nelua`
- `lib/os.nelua`
- `lib/arg.nelua`

**Memory / allocators**:
- `lib/memory.nelua`
- `lib/allocators/` (directory)
- `lib/detail/` (directory)

**Misc**:
- `lib/builtins.nelua`
- `lib/coroutine.nelua`
- `lib/errorhandling.nelua`
- `lib/iterators.nelua`
- `lib/traits.nelua`

## Known secondary blockers (from `plan/INBOX/our-improvements.md`)

After the splice-env fix, expect these to surface per-file. Each is already
ranked and documented; a per-file ticket should cite the rank it hits:

- `cstring` locals cannot be assigned a string literal (rank 10, DONE)
- `@union` field access resolves to `any` (rank 11)
- `<comptime>` on a string evaluates as a number (rank 12)
- `likely`/`unlikely` not lowered (rank 13)
- `...: cvarargs` C emission (rank 14)
- dotted `global X.Y` emits invalid C (rank 15, C-emission half open)
- `check()` missing source location (rank 16)
- no C `enum` emitted for enum types (rank 17)

Do NOT re-derive these -- point the per-file ticket at the rank.

## Out of scope

CLI conformance is a separate queue (`NOTE_backlog.md`, harness
`plan/cli_conformance.py`, 896 cases) for a later agent. Do not fold it in.