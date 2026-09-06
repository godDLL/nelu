# Function literal bound to a local: `local f = function() ... end`

**Status:** CLOSED -- implemented and verified against the oracle.  The
function-value half of the closures/upvalues feature in its simplest form
(`plan/INBOX/closures-upvalues.md`).  Closes the anonymous-function item of
`plan/INBOX/emitter-segfaults-common-idioms.md`.

## What failed (re-measured 2026-09-06, both compilers live)

| code | oracle | ours (before) | ours (now) |
|---|---|---|---|
| `local f = function(x: integer): integer return x + 1 end; print(f(41))` | `42` | `error: in print: cannot handle type "void"` | `42` MATCH |
| `local g = function(x: integer): integer return x * 2 end; print(g(21))` | `42` | same | `42` MATCH |
| `local f = function(): integer return 7 end; print(f())` | `7` | same | `7` MATCH |

## Root cause (precise)

Two defects, both in the function-value path:

1. **Analyzer: `analyzeExpr` has no `nkFunction` case.** `analyzeExpr`
   (`src/analyzer.nim:540`) falls through to `else: return nil` for the
   anonymous-function node kind `nkFunction` (distinct from `nkFuncDef`, the
   *named* function kind).  So a function literal used as an initializer
   returns nil, and `analyzeVarDecl`'s fallback
   (`src/analyzer.nim:838`, `if vtype == nil: vtype = BuiltinTypes["nil"]`)
   gives the binding the `nil` type.  A call `f(41)` through a nil-typed callee
   infers `void`, and the print dispatch emits "cannot handle type void".

2. **Codegen: a function-typed local's initializer was emitted as
   `f = /*?nkFuncDef*/;`.** Even once the analyzer typed the local, `genVarDecl`
   (`src/cgen.nim:2005`) lowered the funcdef initializer via `genExpr`, which
   has no `nkFunction` case and returns the `/*?nkFunction*/` placeholder, so
   gcc rejected the C.

## Fix (bounded, two files)

- **`src/analyzer.nim` `analyzeVarDecl`:** when a vardecl initializer is an
  `nkFunction` literal, promote it to a named `nkFuncDef` carrying the binding's
  name and codename (`<unit>_<localname>` -- the oracle monomorphizes and
  names the function after its binding), call `analyzeFuncDef`, and type the
  local as the resulting function type.  `nkFunction` and `nkFuncDef` share the
  same child layout (args & returns & annotations & body); only `nkFuncDef`
  carries the name as `str` plus a leading name node, which `analyzeFuncDef`
  expects.  Analyzer/cgen reference `nkFuncDef` only, so the kind change is
  safe.  The call `f(41)` then resolves through the function-typed-local path
  (`src/analyzer.nim:135`) and lowers to the function's codename.

- **`src/cgen.nim` `genVarDecl`:** skip the initializer assignment when the
  init is a `nkFuncDef` and the variable is function-typed.  The function is
  emitted separately by `collectFuncDefs` as a static function whose codename
  IS the local's codename, and every call through the binding lowers to that
  codename directly -- there is no function-pointer value to assign.

## Verification

- `exam/fn_value.nelua` -> `42` MATCH (recorded in `plan/harness_baseline.json`).
- `local g = function(x: integer): integer return x * 2 end; print(g(21))`
  -> `42` MATCH; `local f = function(): integer return 7 end; print(f())`
  -> `7` MATCH.
- `plan/harness.py`: `OK: no regression.` (310 baseline).
- The statement form `local function f() ... end` still works (was already
  MATCH); this ticket adds the value form.

## Known limitation (not fixed, out of scope)

- **Reassignment of a function literal** (`local f = function() ... end;
  f = function() ... end`) still fails at C gen: the literal in assignment
  position keeps `nkFunction` kind (the analyzer conversion above only runs
  for vardecl *initializers*), so `genAssign` -> `genExpr` returns the
  `/*?nkFunction*/` placeholder.  Handling it needs the literal in arbitrary
  expression position to get its own unique codename -- that is the general
  function-value/closure feature (`plan/INBOX/closures-upvalues.md`), not the
  bounded "literal bound to a local and called through it" case this ticket
  closes.  The oracle accepts reassignment (`82`), so this is a real gap, but
  it is not a regression: the value form was unanalyzed before this ticket
  too.

## Notes

- This is the simplest form of closures/upvalues: a function value bound to
  a local and called through that local, with **no capture**.  Do not expand
  scope to closures capturing upvalues here -- that is a separate ticket.
- The `needsCompile` workaround (`main.nim:82-88`) is not removed by this
  ticket; re-check it against the print-AST paths before touching it (it is
  the canary).