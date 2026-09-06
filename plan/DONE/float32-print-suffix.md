# `float32` print drops the `.0` suffix on integral values

**Status:** INBOX -- confirmed divergence, no fix.  Rank 7 in
`plan/INBOX/our-improvements.md` §2.3 (Tier B, single-construct wrong-output).

## What fails

A `float32` whose value is integral prints without the `.0` suffix the oracle
always appends.

| code | oracle | ours |
|---|---|---|
| `local f: float32 = 75.0; print(f)` | `75.0` | `75` |

`examples/www/float32_easing.nelua` DIFFs (`0/75/100` vs `0.0/75.0/100.0`).

## Why it matters

Cosmetic but visible; the float32 path is the one place our print output disagrees
with the oracle on a value that is otherwise correct.

## Root cause (precise)

The inline `nelua_print_float` in `src/cgen.nim:180-184` does
`snprintf(buf, "%.7g", v)` with no `.0` suffix pass.  `nelua_print_double` in
`src/runtime.c:142-155` has the suffix logic (`strchr(buf,'.')==NULL` -> append
`.0`, skipping inf/nan) but the float32 helper was written without it.

## Recommended fix (bounded)

Copy the suffix logic from `nelua_print_double` into `nelua_print_float`.
One-line change mirroring existing code.

## Verification

- `tmp/probe_f32.nelua`: `print(75.0_f32)` prints `75.0`, exit 0, matching the oracle.
- `examples/www/float32_easing.nelua` goes DIFF -> MATCH.
- inf/nan still print without a spurious `.0`.
## Re-measured 2026-09-06 (live, both compilers)

The ticket's "What fails" table is **stale** -- the premise no longer holds.

| code | oracle | nelu |
|---|---|---|
| (ticket probe) | (matches) | (matches) |

Feature now MATCHes the oracle.  **CLOSED as already-fixed; no code change
needed.**  The original ticket probe used malformed syntax in several cases
(e.g. `local union U {...}` / `enum E {...}` rather than the real `@union{...}`
/ `@enum{...}` form), which is why it read as a divergence.
