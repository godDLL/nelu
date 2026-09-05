# `likely()` / `unlikely()` builtins are lowered to C

**Status:** CLOSED -- implemented and verified 2026-09-05. Rank 13 in
`plan/INBOX/our-improvements.md` §3.4 (Tier C, stdlib blocker).

## What failed (before)

The Nelu C emitter (`src/cgen.nim`) emitted `likely(...)` / `unlikely(...)` as
plain calls; gcc reported an implicit declaration.

| code | oracle | ours (before) |
|---|---|---|
| `if unlikely(false) then print("x") else print("y") end` | `y` | gcc: `implicit declaration of function 'likely'` |

## What was done

Two changes, both in the finished agent's workdir, verified byte-identical to
the live tree:

1. **`src/analyzer.nim` `analyzeCall`** -- `likely`/`unlikely` are boolean branch
   hints: the call yields a `boolean` (the oracle coerces any non-boolean,
   non-nil argument to `true`), not the argument's type and not the generic
   `void` every other unknown callee gets.
   ```nim
   if isHintName(nm):
     calleeType.returns.add BuiltinTypes["boolean"]
   else:
     calleeType.returns.add BuiltinTypes["void"]
   ```

2. **`src/cgen.nim` `genCall`** -- `of "likely":` / `of "unlikely":` dispatch
   entries emitting `__builtin_expect(cond, 1)` / `__builtin_expect(cond, 0)`.
   Non-boolean conditions (integer 0, empty string, ...) are truthy for the
   branch hint: the oracle only treats boolean `false` as a failing condition,
   so a literal `true` is emitted for non-bool args (`(cond, true)`) rather than
   passing the value straight into a `bool` C parameter (which fails to compile
   for strings and does the wrong thing for integers).

This matches the oracle's `NELUA_LIKELY` / `NELUA_UNLIKELY` macros
(`lualib/nelua/cbuiltins.lua`): `__builtin_expect(x, 1)` / `__builtin_expect(x, 0)`.

## Verification

- `tmp/probe_likely.nelua` (`if unlikely(false) then ... else ...`, plus
  `likely(true/false/0/1/""/nil`) prints `y a c e g`, exit 0 -- MATCHES the
  oracle exactly, including the non-bool coercion (`likely(0)` -> then-branch).
- Codegen comparison vs the Lua reference matches for `true`/`false`/`0`/`1`/
  `"x"`: both emit `__builtin_expect(<cond>, 1)` with `(cond, true)` coercion
  for non-bool args.
- Harness exam probes MATCH the oracle: `exam/likely_branch.nelua` -> `1`,
  `exam/unlikely_loop.nelua` -> `1` (both compilers).

## Notes / not claimed

- `lib/allocators/heap.nelua` still does not compile through Nelu, but the
  blocker is no longer `likely`/`unlikely`: Nelu's analyzer SIGSEGVs on that
  file independently of this change (reproduces on the committed baseline with
  the likely/unlikely changes stashed). The `implicit declaration` cgen error
  is gone; the remaining crash is a separate analyzer bug -- see
  `plan/INBOX/emitter-segfaults-common-idioms.md`-class tickets.
- `likely(nil)` is a degenerate divergence: the oracle rejects it
  ("expected an argument at index 1 but got nil"); Nelu coerces it to
  `__builtin_expect((NULL, true), 1)`. Out of scope -- `likely(nil)` is
  nonsensical and not exercised by any corpus file.