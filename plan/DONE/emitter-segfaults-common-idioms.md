# C emitter SIGSEGVs on anonymous functions, method calls, and if/elseif chains

**Status:** CLOSED -- all three constructs now MATCH the oracle.  The
anonymous-function item landed as `plan/DONE/function-literal-as-value.md`.
Rank 6 in `plan/INBOX/our-improvements.md` §2.5 (Tier B, corpus-wide).

## What fails (re-measured 2026-09-06, both compilers live)

| code | oracle | ours (before) | ours (now) |
|---|---|---|---|
| `cf:flip()` (colon method on a `@record{}` receiver) | `true` | SIGSEGV | `true` MATCH |
| `if x == 1 then ... elseif x == 2 then ... else ... end` | `2` | SIGSEGV | `2` MATCH |
| `local f = function(x: integer): integer return x + 1 end; print(f(41))` | `42` | SIGSEGV | `error: in print: cannot handle type "void"` |

Method calls and if/elseif chains now compile and match the oracle.  The
remaining failure for anonymous functions is **not a SIGSEGV** -- it is an
analyzer diagnostic: `f` is inferred as `nil`-typed, so `f(41)` is `void` and
`print` rejects it.  See root cause below.

## Root cause (precise, for the remaining anonymous-function case)

`analyzeExpr` (`src/analyzer.nim:540`) has **no `nkFuncDef` case**; it falls
through to `else: return nil` (`src/analyzer.nim:773`).  So a function
expression used as an initializer -- `local f = function(x: integer): integer
... end` -- returns nil from `analyzeExpr`, and `analyzeVarDecl`'s fallback
(`src/analyzer.nim:838`, `if vtype == nil: vtype = BuiltinTypes["nil"]`) gives
`f` the `nil` type.  A call `f(41)` through a nil-typed callee therefore
infers `void`, and the print dispatch (`src/analyzer.nim:117-120`) emits
"cannot handle type void" -- matching the oracle's *diagnostic shape* but for
the wrong reason (the oracle runs the function and prints `42`; ours never
gets there because `f` has no function type at all).

`analyzeFuncDef` (`src/analyzer.nim:1256`) builds the `tkFunction` type and
registers a function symbol, but it is only reached through `analyzeStmt`
(`src/analyzer.nim:1963`) -- the statement path -- not through `analyzeExpr`.
A function *literal* in expression position is never analyzed, so it never
gets a codename or a function type, and the local binding it initializes is
`nil`.

## Recommended fix (bounded)

Add an `of nkFuncDef:` case to `analyzeExpr` that calls `analyzeFuncDef` and
returns the function type.  Two things to get right:

1. **Codename.** A literal has no source name.  The oracle monomorphizes and
   names the function after its binding (`<unit>_<localname>`).  Pass a
   `specCodename` so the emitted C is `<unit>_f`, not an anonymous placeholder.
2. **Symbol registration.** `analyzeFuncDef` registers a `skFunc` symbol; for a
   literal bound to a local, the local's type must be the function type (so
   `f(41)` resolves through the function-typed-local path at
   `src/analyzer.nim:135`, not the nil fallback).

The change is localised to `analyzeExpr` plus a codename thread through
`analyzeFuncDef`'s existing `specCodename` parameter (already used for
monomorphized auto-param functions, `src/analyzer.nim:1249`).

## Verification

- `local f = function(x: integer): integer return x + 1 end; print(f(41))`
  prints `42`, exit 0, matching the oracle.
- `local g = function(x: integer): integer return x * 2 end; print(g(21))`
  prints `42`.
- No regression: `plan/harness.py` stays at 309 baseline, `OK: no regression.`
- The `needsCompile` workaround (`main.nim:82-88`) may be removable for the
  print-AST paths once this lands; re-check before removing (it is the canary).

## Notes

- This is the closures/upvalues feature (`plan/INBOX/closures-upvalues.md`) in
  its simplest form: a function value bound to a local and called through it.
  The upvalue environment is already landed; this ticket is just the
  function-as-value half.
- Do not expand scope to closures capturing upvalues here -- that is a
  separate ticket.  Bound this to "literal bound to a local, called through
  that local, no capture."