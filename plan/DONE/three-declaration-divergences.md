# Three declaration-rule divergencies: oracle vs clean-room Nelua

Scope: investigate three probes that our clean-room compiler (`tmp/nelua`)
accepts but the oracle (`/usr/bin/nelua`) rejects.  Determine, for each, whether
it is a genuine language-rule divergence we should close, a deliberate permissive
choice we should keep, or something in between.  Read-only on `src/`; writes only
to `tmp/` and `plan/`.

Probes: `tmp/div3/probe*.nelua` (fresh, this investigation) plus the pre-existing
`tmp/closures/probe_closure_*.nelua` (re-run, not trusted second-hand).

## Status: CLOSED (implemented and verified)

The recommendation in §1/§6 was adopted and landed in `src/analyzer.nim`.  All
three divergences now reject exactly as the oracle does (all six probes exit 1
with an "undeclared symbol" diagnostic).  The four hunks, transplanted from the
`tmp/20260904-1543-div3/` workcopy onto the live tree (which already carried the
splice-ident fix, so this was a merge not a copy):

- `BuiltinNames` / `HintNames` / `isBuiltinName` / `isTypeKeywordName` /
  `isRecognizedName` tables (new module-level consts/procs).
- call-callee site: `if sym == nil and not isRecognizedName(nm):` emit
  "undeclared symbol" (so `return h()` with `h` undeclared rejects).
- `nkId` reference site: `if not isTypeKeywordName(nm):` emit
  "undeclared symbol" (so a bare out-of-scope `x` rejects; type keywords
  `any`/`integer`/... stay exempt as first-class type values).
- `analyzeFuncDef`: bare `function g()` (nkId name, not already declared) emits
  "undeclared symbol 'g', maybe you forgot to declare it as 'global' or
  'local'?" (divergence #2).  Colon/dot methods are exempt.

Measured corpus cost on the current tree: **0 regressions** across all gates --
`plan/cover_gate.py` (44 files), `plan/cmp.py` (40 cases), `plan/regress.py`
(M2 14/14, M1 25/3/0), `plan/examples_parity.py` (2/5/3), `tmp/wwwcheck.py`
(97/2), `plan/cli_conformance.py` (exit 0).  The §6 caveat about error-message
formatting (no "from: AST node Block" context line, no caret) still stands; the
probes DIFF on combined stdout+stderr but MATCH on exit code and accept/reject.

---

## 1. Summary table

| # | Divergence | Oracle behaviour | Ours | Closes feasible? | Corpus cost | Recommendation |
|---|------------|------------------|------|------------------|-------------|----------------|
| 1 | `## local x = 7` then inner function reads bare `x` | `error: undeclared symbol 'x'` at the read; exit 1 | resolves `x` to `nil`; prints `(null)`; exit 0 | Yes -- one diagnostic in the analyzer | 0 programs | CLOSE |
| 1b | (same root cause) plain undeclared `x`, no `##` | `error: undeclared symbol 'x'`; exit 1 | prints `(null)`; exit 0 | Yes | 0 programs | CLOSE |
| 2 | bare top-level `function g()` (no `global`/`local`) | `error: undeclared symbol 'g', maybe you forgot to declare it as 'global' or 'local'?`; exit 1 | defines `g` as an implicit global; prints `42`; exit 0 | Yes | 0 programs | CLOSE (parity) |
| 3 | module-level `local x` used before its declaration line | `error: undeclared symbol 'x'`; exit 1 | resolves to `nil`; prints `(null)`; exit 0 | Yes | 0 programs | CLOSE |

All three share one underlying gap: **our analyzer never emits an
"undeclared symbol" diagnostic.**  Divergences 1 and 3 are the same bug at the
`nkId` reference site; divergence 2 is the same gap at the `nkFuncDef` definition
site (where the oracle treats the function name as a reference that must already
be declared).

---

## 2. Divergence 1 -- `## local` visibility (and the general undeclared-symbol gap)

### 2.1 Verified oracle vs ours

Probe `tmp/div3/probe1_ddlocal.nelua`:
```
## local x = 7
local function f()
  local function g()
    return x
  end
  return g()
end
print(f())
```

Oracle (exit 1, stderr):
```
probe1_ddlocal.nelua:4:12: error: undeclared symbol 'x'
    return x
           ^
```

Ours (exit 0, stdout): `(null)`

The same probe WITHOUT the `##` line, `tmp/div3/probe1_plain.nelua`, gives
*identical* results: oracle exit 1 `undeclared symbol 'x'`, ours exit 0 `(null)`.
So the `##` line is not the cause.

### 2.2 Root cause (verified against the current file)

`## local x = 7` is parsed by `src/parser.nim:863-884` (`parsePreprocess`) as an
`nkPreprocess` leaf whose `str` is the raw line text ` local x = 7`.  The M6
preprocessor (`src/preprocessor.nim:1391` `preprocess`) runs that text through the
embedded Lua engine (`src/preprocessor.nim:1360` `runPreprocessChunk`) and splices
back whatever the chunk *injects*.  A bare `## local x = 7` injects nothing: the
preprocessor's Lua callbacks only splice on `inject`/`inject_astnode`/
`inject_statement` (`src/preprocessor.nim:412-435`, `727-740`), none of which this
line triggers.  The `x` is a Lua-local only.  The `--print-analyzed-ast` dump
confirms: no `x` declaration survives into the analyzed tree.

The real gap is in name resolution.  `src/analyzer.nim:790-865` (the `nkId` case of
`analyzeExpr`):

- line 792: `let sym = ctx.lookup(nm)` -- for an undeclared `x`, returns `nil`.
- line 843: falls through to "not in scope: treat as builtin name fallback".
- line 848-864: if `nm` is a builtin name, synthesise a builtin symbol.
- **line 865: `return nil`** -- no diagnostic is ever emitted for a genuinely
  undeclared identifier.

The caller discards the `nil` harmlessly in some places and dereferences it in
others:
- `src/analyzer.nim:1847-1849` `analyzeReturn` does `discard analyzeExpr(ctx, c)`,
  so `return x` in a void function silently drops `x` (this is why `probe1` prints
  `(null)` instead of crashing).
- A bare `print(x)` with undeclared `x` SIGSEGVs in codegen (`tmp/probe_undeclared_print.nelua`,
  exit 139) because `src/cgen.nim:539` emits a bare `cIdent("x")` on a nil attr.

The oracle reports `undeclared symbol 'x'` at the read site and stops.  Our
compiler has no such diagnostic anywhere (`grep -rn "undeclared" src/` returns
nothing).

**The previous agent's attribution to "splice Stage 4 (making `##`-locals visible
to splices)" is incorrect.**  The preprocessor correctly consumes the `##` line;
the bug is entirely in the analyzer's missing undeclared-symbol diagnostic.

### 2.3 Feasibility and corpus cost of closing

Fix: at `src/analyzer.nim:865`, before `return nil`, emit
`ctx.diags.add ctx.path & ": error: undeclared symbol '" & nm & "'"` and return nil.
Approximately 3 lines; no new state.

Corpus cost: **0 programs**.  Measured by `tmp/div3/measure_corpus.py`: across
136 `.nelua` files in `examples/`, `examples/www/`, `lib/`, the set of programs
our compiler accepts (exit 0) is a strict subset of the set the oracle accepts
(exit 0).  There are **0** programs our compiler accepts that the oracle rejects.
Since the oracle already enforces the closed rule, closing cannot break any
program that currently works.  (It would additionally turn the current SIGSEGV
on `print(undeclared)` into a clean error, which is an improvement.)

Note on output parity: the oracle's error text carries "from: AST node Block"
context lines and a caret, which our reporter does not emit.  So a closed probe
would still DIFF on combined stdout+stderr (the `examples_parity.py` gate combines
them); it would, however, MATCH on the material fact -- exit 1, reject instead of
accept.  Matching the oracle's exact error format is a separate effort.

### 2.4 Recommendation

**CLOSE.**  It is a plain bug, not a deliberate permissive choice; the fix is
small; the corpus cost is measured at 0.

---

## 3. Divergence 2 -- bare top-level `function`

### 3.1 Verified oracle vs ours

Probe `tmp/div3/probe2_barefn.nelua`:
```
function g()
  return 42
end
print(g())
```

Oracle (exit 1, stderr):
```
probe2_barefn.nelua:1:10: error: undeclared symbol 'g', maybe you forgot to declare it as 'global' or 'local'?
function g()
         ^
```

Ours (exit 0, stdout): `42`

Same for a bare function with a return annotation, `tmp/div3/probe2b_barefn_ann.nelua`
(`function main(): integer`): oracle exit 1 with the same message; ours exit 0, `42`.
The oracle also rejects a bare `function g()` nested inside a `do` block
(`tmp/t13.nelua`), so the rule is not "top-level only".

The oracle accepts the qualified forms: `global function g()`, `local function g()`,
and `global g` declared before `function g()` (`tmp/t1-3.nelua`).  It accepts bare
*method* definitions (`function Point:sum()`, `function CellField.new()`) because
the method name is not a plain identifier reference.

### 3.2 Root cause (verified against the current file)

`src/parser.nim:907` dispatches a bare `function` keyword to
`parseFuncDef("")` (empty qualifier).  `src/parser.nim:667-699` builds an
`nkFuncDef` whose `str` is `""` and whose `children[0]` is a bare `nkId` name
(`parseFuncName`, `src/parser.nim:656-665`, returns a plain `nkId` for a bare
name, an `nkColonIndex`/`nkDotIndex` for a method).

`src/analyzer.nim:1297-1372` `analyzeFuncDef`:
- line 1298-1299: `nameNode = node.children[0]`, `nameStr = nameNode.str`.
- line 1306: `if nameNode.kind == nkColonIndex` -- the method case, which injects
  an implicit `self` and registers the method on the record type.
- **line 1368: `let sym = register(ctx, symName, skFunc, ftype, node)`** -- for a
  bare function this registers `g` as a fresh global function in the current
  scope without first checking that `g` was already declared.

The oracle treats `function g()` as desugaring to `g = function()`: the assignment
target `g` is a *reference*, and a reference to an undeclared symbol is an error
with the "maybe you forgot to declare it as 'global' or 'local'?" hint.  Our
compiler instead treats the bare definition as an implicit global declaration.

Note: our parser does not accept `global function g()` at all
(`src/parser.nim:906` only handles `global` as a var-decl), which is a separate,
pre-existing parser gap.  After closing #2 the migration path for top-level
functions is `local function g()`, which both compilers accept.

### 3.3 Feasibility and corpus cost of closing

Fix: in `analyzeFuncDef`, when `node.str == ""` (bare) and `nameNode.kind == nkId`
(not a method) and `ctx.lookup(nameStr) == nil`, emit
`ctx.path & ": error: undeclared symbol '" & nameStr &
"', maybe you forgot to declare it as 'global' or 'local'?"`.

Corpus cost: **0 programs**.  Two independent measurements, both zero:
1. Oracle-based: 0 programs our compiler accepts that the oracle rejects (the
   oracle enforces this rule, so any program it accepts has no bare function
   definition).
2. Raw occurrence count: `tmp/div3/measure_corpus.py` scans all 136 corpus files
   for `^[ \t]*function <name>(` lines that are not method syntax (`:`/`.`) and
   not inside a `##[[` Lua block.  Count = **0**.  (A naive line-grep without the
   `##[[` filter flags `examples/overview.nelua:833 function unroll(count, block)`,
   but that line is inside a multi-line Lua preprocessor block and is never parsed
   as a nelua function; the oracle rejects `overview.nelua` for unrelated reasons
   -- `require 'span'` and a `do`-expression -- not for `unroll`.)

The previous agent's claim that "closing this would break the `examples/` corpus
because many programs use bare top-level `function main()`" is **false**.  There
is no `function main` anywhere in the corpus except in the qualified form
`local function main` (`lib/allocators/gc.nelua:494`, `spec/*_spec.lua` entries).

### 3.4 Recommendation

**CLOSE** for parity.  The corpus cost is measured at 0, the rule is the
oracle's deliberate "no implicit globals" design, and the migration path
(`local function main()`) is available and accepted by both compilers.

If the downstream Nelu dialect later wants bare top-level functions as an
ergonomic convenience, that can be re-introduced as a documented deliberate
permissive divergence; but for the 0.2.0-dev parity floor, reject it.

---

## 4. Divergence 3 -- forward reference to a module-level `local`

### 4.1 Verified oracle vs ours

Probe `tmp/div3/probe3_fwdref.nelua`:
```
local function g()
  return x
end
local x = 10
print(g())
```

Oracle (exit 1, stderr):
```
probe3_fwdref.nelua:2:10: error: undeclared symbol 'x'
    return x
           ^
```

Ours (exit 0, stdout): `(null)`

The function-forward-reference variant `tmp/div3/probe3b_fwdfunc.nelua`
(`local function g() return h() end` ... `local function h() ...`) behaves the
same: oracle exit 1 `undeclared symbol 'h'`, ours exit 0 `(null)`.

### 4.2 Root cause (verified against the current file)

`src/analyzer.nim:1915-1918` `analyzeBlock` walks the block's children in source
order and calls `analyzeStmt` on each.  There is no hoisting pre-pass: a `local`
declares its symbol only when its own statement is reached
(`analyzeVarDecl`, `src/analyzer.nim:962`; a function body is analyzed inline at
`analyzeFuncDef:1394`).  So a reference that textually precedes the declaration is
a reference to a symbol not yet in scope.

That reference goes through the same `nkId` path as divergence 1:
`src/analyzer.nim:792` `ctx.lookup(nm)` returns nil, and line 865 returns nil with
no diagnostic.  The void-function `return` discards it (`src/analyzer.nim:1847`),
so the program prints `(null)`.

This is **consistent with the standing design decision that `local` is NOT
hoisted** (scope at its declaration line).  Under that decision a forward
reference is out of scope and *should* be an error -- which is exactly what the
oracle does.  Our compiler resolving it to `nil` is a bug, not a deliberate
permissive choice.  The previous agent's characterisation of this as a "deliberate
Nelu permissive divergence" is incorrect: it is the same undeclared-symbol gap as
divergence 1.

### 4.3 Feasibility and corpus cost of closing

Same fix as divergence 1 (the `nkId` diagnostic at `src/analyzer.nim:865`), so the
cost is the same ~3 lines.

Corpus cost: **0 programs** -- identical measurement to divergence 1: 0 programs
our compiler accepts that the oracle rejects.  The oracle enforces source order on
locals, and every program the oracle accepts therefore has no forward reference
to a module-scope local.

### 4.4 Recommendation

**CLOSE.**  It is the same bug as divergence 1, the fix is the same, the corpus
cost is measured at 0, and closing is consistent with the standing "local is not
hoisted" design decision rather than conflicting with it.

---

## 5. What the previous agent's claims were, and which hold up

| Previous agent's claim | Verdict |
|------------------------|---------|
| Divergence 1 is a "deliberate Nelu permissive divergence" | PARTIALLY CONFIRMED: ours does accept and the oracle does reject, but the root cause is a missing diagnostic, not a deliberate permissive choice. |
| Divergence 1's cause is "splice Stage 4 (making `##`-locals visible to splices)" | **NOT CONFIRMED.**  The `## local x = 7` is correctly consumed by the preprocessor and never creates a nelua symbol; the same divergence reproduces with a plain undeclared `x` and no `##` line at all. |
| Closing #1 would "break the examples/ corpus" | **NOT CONFIRMED.**  Measured corpus cost = 0 programs. |
| Divergence 2 is a "deliberate Nelu permissive divergence" | CONFIRMED as to the accept/reject difference; but the claim that closing would break the corpus is false. |
| Closing #2 would break the corpus "because many programs use bare top-level `function main()`" | **NOT CONFIRMED.**  0 bare top-level plain `function <name>(` occurrences exist in the corpus; `function main` appears only as `local function main`. |
| Divergence 3 is a "deliberate Nelu permissive divergence"; "locals are not hoisted" | The accept/reject difference is CONFIRMED, but the "deliberate permissive" label is **NOT CONFIRMED**: the "local is not hoisted" design decision is fully consistent with the oracle's rejection; resolving to `nil` is a bug. |

---

## 6. Bottom line

All three divergencies trace to a single missing diagnostic -- "undeclared symbol"
-- in the analyzer's name resolution (`src/analyzer.nim:790-865` for references,
`:1368` for bare function definitions).  None of them is a deliberate permissive
choice that the corpus depends on.  Closing all three is feasible with a small,
localised change and has a **measured corpus cost of 0 programs** on
`examples/`, `examples/www/`, and `lib/`.

The one thing that would *not* close cleanly is the exact error-message format:
the oracle emits "from: AST node Block" context lines and a caret that our
reporter does not, so the probes would still DIFF on combined stdout+stderr
(though they would MATCH on exit code and on accept/reject).  That formatting gap
is pre-existing and orthogonal to these three divergencies.