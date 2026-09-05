# `likely()` / `unlikely()` builtins are not lowered to C

**Status:** INBOX -- confirmed divergence, no fix.  Rank 13 in
`plan/INBOX/our-improvements.md` §3.4 (Tier C, stdlib blocker).

## What fails

The C emitter emits `likely(...)` / `unlikely(...)` as plain calls; gcc reports an
implicit declaration.

| code | oracle | ours |
|---|---|---|
| `if unlikely(false) then print("x") else print("y") end` | `y` | gcc: `implicit declaration of function 'likely'` |

## Why it matters

Used in `lib/allocators/heap.nelua`
(`if unlikely(...) then ... return nilptr end`).  Rank 13.

## Root cause (precise)

`likely`/`unlikely` are recognized by the analyzer but the C emitter does not map
them to `__builtin_expect` (or include the builtin header); it emits them as plain
calls.  The oracle defines `NELUA_LIKELY` / `NELUA_UNLIKELY` macros in
`cbuiltins.lua` (oracle section 7.2).

## Recommended fix (bounded)

In the C emitter's call-lowering, map `likely`/`unlikely` to
`__builtin_expect(arg, 1)` / `__builtin_expect(arg, 0)` (or to the
`NELUA_LIKELY`/`NELUA_UNLIKELY` macros from `runtime.c`).  Bounded, one dispatch
entry.

## Verification

- `tmp/probe_likely.nelua`: the case above prints `y`, exit 0, matching the oracle.
- `lib/allocators/heap.nelua` parses past the `unlikely` site (report the new first
  error; do not claim the file is fixed).