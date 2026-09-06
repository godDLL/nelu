# `#|expr|#` computed-identifier splice

**Status:** INBOX -- blocks 7 `lib/*.nelua` files.  Separate feature from
`splice-env-locals`; that ticket's scope is done, this is the next blocker.

## What it is

`#|expr|#` is a nelua-level (not `##`) splice: the `expr` is a Lua expression
evaluated at compile time to produce a *string identifier*, which then stands in
as a function name, local name, field name, or identifier reference.  The oracle
keeps it as an `nkPreprocessName` node in the AST (`IdDecl { PreprocessName {
"expr" } }`, `DotIndex { PreprocessName, base }`, ...) and resolves it later.

All observed usages are inside `##` splice-function / `## for` blocks, so the
`expr` references `##`-locals (e.g. `#|name|#` where `name` is the `##`-local
param of `import_cmath_func1`).  This means the evaluation happens at
**preprocess time** in the frame's chunk -- the same place `#[expr]#` splices are
collected and run (see `collectSpliceParts` / `gBlockSplices` / `gSpliceResults`).

## Where it's used

| file | line | form |
|---|---|---|
| `lib/hash.nelua` | 92 | `v.#|field.name|#` -- computed **field access** |
| `lib/math.nelua` | 62,68,74 | `local function #|name|#(...)` -- computed **function name** |
| `lib/utf8.nelua` | 137 | `local function #|fname|#(...)` -- computed **function name** |
| `lib/sequence.nelua` | 308 | `local #|'v'..k|#: T = ...` -- computed **local name** |
| `lib/coroutine.nelua` | 83,84,92,104 | `local #|argname|#: ...`, `&#|argname|#`, `local #|'r'..i|#: ...` -- local name + **address-of** |
| `lib/string.nelua` | 770 | `local #|'a'..i|#: string = ...` -- computed **local name** |

## Current state in Nelu

- **Parser** (`src/parser.nim`): `parsePreprocessName` (line 404) parses
  `#|expr|#` into `nkPreprocessName(str: <raw expr text>)`.  It is wired into
  `parseUnary` (expression position -> `nkId(str:"", children:[pp])`),
  `parseIdDecl` (local name -> `nkIdDecl(str: raw, children:[pp])`) and
  `parseFuncName`/`parseFuncDef` (function name -> `nkIdDecl` for `local`).
  **MISSING:** `.#|expr|#` computed field access in `parsePostfix` (line ~552
  does `p.advance().value` after `.`, which fails on the `#` token).  This is the
  hash.nelua parse error.
- **Preprocessor** (`src/preprocessor.nim`): `of nkPreprocessName` at line 2169
  and the `nkBlock` child case at line 2099 both do
  `ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build;
  node consumed"` and return `newNil()`.  Nothing evaluates the splice.
- **Analyzer**: `replaceSplices` handles `nkPreprocessExpr` (`#[expr]#`) but not
  `nkPreprocessName`.  Parent nodes read the name from `.str`, which still holds
  the *raw expr text* (`'v'..k`) rather than the evaluated string, so even if the
  node survived, `analyzeVarDecl`/`analyzeFuncDef`/`analyzeDotIndex` would bind
  the wrong identifier.

## The fix (bounded)

1. **Parser** `parsePostfix`: after `.`, try `parsePreprocessName()`; on success
   emit a `nkDotIndex` whose field is the `nkPreprocessName` (store it as a child,
   not in `.str`, since the name is not known at parse time).  `newDotIndex` takes
   a `string` field; a computed field needs a node child -- either add an overload
   or construct the `nkDotIndex` inline (set `str:""`, `children:[base, pp]`,
   `isIndex=true`).
2. **Preprocessor**: mirror the `#[expr]#` path.  Extend `collectSpliceParts` to
   also collect `nkPreprocessName` nodes, capturing `tostring(<expr>)` into the
   frame chunk (so `##`-locals are visible), and store the evaluated string keyed
   by node pointer (analogous to `gSpliceResults`).  Stop consuming the node.
3. **Analyzer** `replaceSplices`: add an `nkPreprocessName` case that resolves to
   a string (prefer the preprocess result, fall back to live-scope evaluation via
   `evaluateSplice`-style `return (tostring(expr))`), and add parent cases for
   `nkIdDecl` / `nkDotIndex` / `nkFuncDef`-name that *set the parent's `.str` to
   the resolved string* and replace the splice child with an `nkId`.  This must
   run before `analyzeVarDecl`/`analyzeFuncDef`/`analyzeDotIndex` read the name --
   `analyzeBlock` already calls `replaceSplices` on each child before
   `analyzeStmt`, so wiring it into `replaceSplices` gives the right ordering.
4. **Address-of** `&#|argname|#`: the operand is `nkId(str:"", children:[pp])`.
   The generic `nkPreprocessName` replacement (return `newId(name)`) handles this
   once `replaceSplices` recurses into the `nkId`'s children.

## Verification

After the fix, `lib/hash.nelua` must compile end-to-end through `tmp/nelu`
(`-c -o /tmp/x lib/hash.nelua`), then re-scan the 7 files.  Compare against the
oracle: `#|name|#` is a nelua-level feature the oracle supports, so matching
output is the bar.  Guard: `plan/harness.py` must stay at 0 regressions.

## Not in scope

- `#|name|#` at *top level* outside any `##` block with no in-scope identifier
  (untested in the corpus; the oracle's behaviour is the reference).
- Exposing the full compiler API to evaluate arbitrary `#|expr|#` -- the content
  is plain Lua + the existing pp shim builtins, same as `#[expr]#`.