# Splice blocks must see nelua-scope locals

**Status:** PARTIAL -- builtin-typed locals work; **user-typed symbols do not**.
Re-measured 2026-09-06 (see below).  Verification still not met.

## What was implemented

The ticket's stated scope is landed in `src/preprocessor.nim` + `src/types.nim`:

- `gPreprocessScope` (module-global `Scope`, reset in `resetPreprocessorState`) is
  pushed per `nkFuncDef` carrying that function's params (via `declaredTypeOf`),
  and per-block `local` declarations are added positionally by `injectNeluaLocals`.
- A `__nelua_scope(name)` Lua builtin (registered on the embedded engine) resolves a
  nelua local to its typed `Symbol` wrapper, so `##` blocks can read it.  Each nelua
  declaration injects `<name> = __nelua_scope("<name>")` into the shared `##` chunk
  at its textual position, giving **positional** visibility (a `##` line sees only
  locals/params declared above it textually -- matching the oracle, which errors
  "attempt to index a nil value (global 'X')" for a local declared below).
- `is_cfloat` / `is_cdouble` / `is_record` added to `Type` and to the `cTypeIndex`
  builtin so `v.type.is_cfloat` resolves for `v: cdouble` (false) and `v: cfloat` (true).

Verified on both `tmp/nelu` and `/usr/bin/nelua`:
- `## if v.type.is_cfloat then` for `v: cdouble` -> "not cfloat"; for `v: cfloat` -> "cfloat".
- Positional visibility: a `##` line referencing a local declared *after* it errors on
  both compilers with the same "global 'X'" message.
- Auto-param case `v: auto` resolves to `int64` (default) with correct `is_*` truthiness.
- Harness: 0 regressions, 223 MATCH, 4 improvements (goto_loop, likely_branch,
  unlikely_branch, unlikely_loop), 1 new (exam/fn_multi). The earlier `def_c`
  regression (custom `_ENV` isolating splice globals) was diagnosed and reverted.

## Verification NOT met -- blocked on `#|name|#`

`lib/hash.nelua` still does not compile.  It gets PAST the `## if v.type.is_cfloat`
part now, but dies at the `#|name|#` computed-identifier splice (see
`plan/INBOX/preprocess-name-splice.md`).  7 `lib/*.nelua` files use `#|name|#`:
hash, math, utf8, sequence, coroutine, string (+ strpack has none).  This is a
separate feature from splice-env-locals; the ticket's *scope* is done, its
*verification* is not, and is not claimed to be.

## The real blocker (measured 2026-09-06) -- user-typed symbols

The ticket's own example (`v: cdouble`, a **builtin** type) works.  What does not
is a symbol whose type is a **user** type.  Minimal divergence, both compilers
run, oracle wins:

```nelua
local R = @record{ size: integer }
local function f(a: R)
## local t = a.type
return #[t.size]#
end
print(f({ size = 7 }))     -- oracle: 8 (exit 0); nelu: "attempt to index a nil value (global 'a')"
```

Nelu fails at `global 'a'`: the function param `a` is never injected into the
`##` chunk.  Root cause, precise:

1. `preprocessor.nim:2206-2210` adds the param to `gPreprocessScope.symbols` with
   `typ: declaredTypeOf(child)`.
2. `declaredTypeOf` (line 1148) -> `resolveTypeKey` (line 1139) only knows
   **builtins and primitive types** (`BuiltinTypes`/`PrimitiveTypes`).  A user type
   such as `R` resolves to `nil`.
3. `preprocessor.nim:2037-2040` gates the injection on `sym.typ != nil`, so a
   user-typed param is **skipped entirely** -- not even the symbol wrapper exists.
4. Even if the guard were removed, `cSymIndex` `of "type"` (line 1205) would return
   `pushTypeWrapper(nil)`, so `a.type` would still be nil.  The Type object for `R`
   is created by the **analyzer**, which has not run yet.

**Why it is architectural, not a one-line fix.**  The oracle resolves `##`-block
identifiers via a **live analyzer scope lookup** -- `ppcontext.lua:48-49`:
`return context.scope.symbols[key]`, where `context.scope` is the scope at the
point the `##` block runs, because the oracle's preprocessor runs **interleaved
with analysis**.  Nelu runs preprocessing **once, before analysis**, so it cannot
see resolved user types; `gPreprocessScope` is a substitute that only knows
builtins.  Closing this gap means either (a) interleaving preprocessing with
analysis like the oracle, or (b) teaching `gPreprocessScope` to track user type
bindings and their resolved Type objects -- both are substantial.

Also measured: `## local x = a + 1` for `a: integer` fails on **both** compilers
("attempt to perform arithmetic on a table value (global 'a')") -- a `##` line sees
a symbol as a *wrapper*, not a value, so arithmetic on it is unsupported in both.
This is NOT a divergence; do not chase it.

## What fails

Every `lib/*.nelua` file uses `##` splice blocks that reference nelua-scope
locals and their types, e.g. `hash.nelua`:

```
local v: cdouble = ...
## if v.type.is_cfloat then
  local function frexp(x: cfloat, exp: *cint): cfloat <cimport'frexpf',...> end
## else
  local function frexp(x: cdouble, exp: *cint): cdouble <cimport'frexp',...> end
## end
```

The `##` block runs in the preprocessor's Lua environment, where nelua locals
are not visible. Observed error:

```
error while preprocessing block: ... attempt to index a nil value (global 'v')
```

Verified on committed HEAD `tmp/nelua`: `## if v.type.is_cfloat then` with
`local v: cdouble = 1.0` above fails; the same file with the `##` blocks
removed compiles. Also verified: `#[math.huge]#` splice-idents in expression
position already work (that is NOT the blocker).

## The fix (bounded)

Make the `##` splice block's Lua environment expose the **live analyzer
scope's locals and their types**, so a `##` block can read a nelua local and
index its type. This is a natural extension of the machinery already committed
in `ec60323` (`src/preprocessor.nim` `gActiveScope` / `lookup` /
`resolveTypeKey` / `getWrapperSymbol`, which made `#[x]#` splice-idents
resolve at analysis time). The same scope lookup that serves `#[x]#` should
serve `##` blocks.

Scope of this ticket: make `## if <nelua-local>.<type-field> then ... ## else
... ## end` work, and `## <nelua-local> = ...` work. Do NOT go further into
`__nelua_mark`/`__nelua_inject` multi-chunk embedding (that is a separate,
unproven path -- see `plan/INBOX/splice-multichunk-mark-inject.md`).

## Verification

After the fix, `lib/hash.nelua` must compile end-to-end through `tmp/nelua`
(`-c -o /tmp/x lib/hash.nelua`). Then re-scan all 21 `lib/*.nelua` files;
each one that still fails gets its own ticket (see
`plan/INBOX/lib-reachability-per-file.md`).

## Note on the abandoned agent

An agent worked 8 hours on `__nelua_mark`/`__nelua_inject` in
`tmp/20260904-1543-lib-stdlib/` and produced 0/21 compiling lib files. Its
workcopy is preserved as evidence but is superseded by this ticket: it never
touched the actual blocker (splice-block local visibility) and its
preprocessor changes are based on a pre-`ec60323` baseline. Do not integrate
that workcopy without re-deriving against the current `src/`.