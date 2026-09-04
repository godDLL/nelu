# Improve and Expand: Nelua-in-Nim Compiler and Language

Grounded in `plan/observed-language-spec.md` (Professor A's spec) and verified
against the source under `src/`. Every recommendation cites a file and line and
traces back to something Professor A observed: a gap, a divergence, an inert
path, a frozen contract, or a module boundary. Where a claim is mine and not
Professor A's, it is marked `[mine]`.

ASCII only. Hyphens, not em-dashes. No CJK.

---

## 0. How to read this document

Four sections:

1. **Improvements to existing behaviour** -- correctness, diagnostics,
   robustness. Prioritized by impact and corpus reach.
2. **Expansions** -- new language features or compiler capabilities, each with
   a rationale tied to the observed architecture.
3. **Contract and architecture** -- the frozen AST contract (`astshapes.nim`)
   and module boundaries that constrain what is possible, and whether they
   should change.
4. **Priorities** -- a short ordered list with reasoning.

I distinguish firmly between "this is a bug, fix it" and "this is a deliberate
design decision, do not touch." Where a recommendation is speculative, I say so.

---

## 1. Improvements to existing behaviour

### 1.1 Emit an "undeclared symbol" diagnostic (BUG, fix first)

**Location:** `src/analyzer.nim:862-884` (the `nkId` case in `analyzeExpr`).

**What Professor A observed (spec §5.11):**

> The analyzer does NOT emit "undeclared symbol" diagnostics. When an
> identifier is not found in scope, it falls through to a hardcoded
> `builtinNames` list ... and treats the symbol as a `skBuiltin` with codename
> `nelua_<name>`. Unknown identifiers that are not in this list are **silently
> treated as `any`-typed externals** -- there is no diagnostic and no error.

**Verification:** I read `analyzer.nim:818-884`. The `nkId` case calls
`ctx.lookup(nm)`; if that returns nil, it checks `builtinNames`
(analyzer.nim:863). If the name is in `builtinNames`, it constructs a
`skBuiltin` symbol with `typ = BuiltinTypes["any"]` and codename
`nelua_<name>` (analyzer.nim:868). If the name is NOT in `builtinNames`, the
function returns `nil` at analyzer.nim:884 -- and the caller
(`analyzeExpr`'s callers, e.g. `analyzeCall` at analyzer.nim:492-494) filters
out nil types with `if t != nil: argTypes.add t`. So an unknown identifier
vanishes from the type set and the codegen later emits it as a bare C
identifier (via `cIdent(node.str)` in `genExpr` at cgen.nim:539), which the C
compiler treats as an implicit function declaration or, worse, a global
variable.

**Impact:** This is the single largest semantic gap. It means the compiler
compiles code that references undefined names, producing C that either fails to
link or links against whatever happens to be in the C namespace. Every
undefined-name bug in the corpus is invisible to the compiler.

**Fix:** Before the `builtinNames` fallback, emit a diagnostic
`"undeclared symbol '%s'"` with a Levenshtein "did you mean '%s'?" hint over
the visible names (the M2_design.md §1.1 spec already calls for this:
`plan/M2_design.md:47` -- "undeclared -> error with a 'did you mean 'Y'?' hint").
The `errors.nim` module already has the rendering machinery (`errors.nim:82-103`
`render` produces `path:line:col: error: msg` plus a caret line); what is
missing is the call site. The fix is ~10 lines in `analyzeExpr`'s `nkId` case.

**Trade-off:** A Levenshtein hint over the whole scope chain is O(n*m) per
identifier. For typical source files this is negligible; for pathological
cases (a function with thousands of locals) it could be slow. Accept it; the
oracle does the same.

---

### 1.2 Wire the preprocessor into `compileUnit`'s require resolution (BUG)

**Location:** `src/compile.nim:106-137` (`compileUnit`), `src/analyzer.nim:2388-2421` (`analyzeModule`).

**What Professor A observed (spec §4.8, §7.4):**

> The preprocessor is NOT wired into the compile driver. `compile.nim:10-16`
> documents this as backlog item C3: only `analyze` and `runM6Pipeline` run the
> preprocessor. A normal `nelua file.nelua` compile does not invoke `##` or
> `#define`.

**Verification [mine]:** Professor A's claim is imprecise. The preprocessor IS
wired into the compile driver, but indirectly. The call chain is:
`compile()` -> `compileUnit()` -> `genC()` -> `analyze()` -> `analyzeModule()`
-> `preprocess()` (analyzer.nim:2396). So `##` and `#define` DO run for normal
compiles. What is NOT wired is `compileUnit`'s *require resolution*.

Look at `compileUnit` (compile.nim:118-137):

```
let ast = parser.parse(source, path)      # raw parse, NO preprocessing
if ast != nil:
  for modname in findRequires(ast):       # runs on raw parse tree
    ...
let cSource = genC(source, path, ...)     # genC re-parses + preprocesses
```

`compileUnit` parses the source *twice*: once at compile.nim:118 for
`findRequires`, and again inside `genC` -> `analyze` -> `analyzeModule` at
analyzer.nim:2388. The first parse is NOT preprocessed. So:

- A `require 'foo'` inside a `#if DEBUG then ... end` block is found by
  `compileUnit`'s `findRequires` (it runs on the raw parse tree, which includes
  the `require` inside the `#if`), but the dependency is compiled even when
  `DEBUG` is undefined.
- A `require` generated by a `##` splice (e.g. `## inject(require 'foo')`) is
  NOT found by `compileUnit`'s `findRequires` (the raw parse tree has no
  `require` there), so the dependency is never compiled or linked, even though
  `analyzeModule`'s own `findRequires` (analyzer.nim:2403, which runs on the
  *preprocessed* tree) would find it and import its symbols. The result: the
  analyzer sees the symbols but the C linker does not see the dependency's
  object code.

`analyzeModule` does it right: it preprocesses first (analyzer.nim:2396), then
runs `findRequires` on the preprocessed tree (analyzer.nim:2403).

**Fix:** Move the preprocessor call into `compileUnit` before `findRequires`:

```
let ast = parser.parse(source, path)
if ast != nil:
  var pctx = newPreprocessContext(source, path)
  ast = preprocess(ast, pctx)          # NEW: preprocess before findRequires
  for modname in findRequires(ast):
    ...
```

This is a ~3-line change and makes the two require-resolution passes
(`compileUnit` and `analyzeModule`) see the same tree. The preprocessor's
`spliceInclude` (preprocessor.nim:1131) re-parses `#include`s internally, so no
signature change is needed.

**Trade-off:** `preprocess` can raise `PreprocessError` (preprocessor.nim:39).
`compileUnit` would need to catch it and surface it as a diagnostic. The
`analyzeModule` path already does this (analyzer.nim:2397-2399), so the pattern
exists.

---

### 1.3 Fix the emitter segfaults on method calls, anonymous functions, if/elseif (BUG)

**Location:** `src/cgen.nim:521-584` (`genExpr`), `src/cgen.nim:806-835` (`genCallMethod`), `src/cgen.nim:1199-1217` (`genIf`), `src/main.nim:87-88` (the `needsCompile` gate).

**What Professor A observed (spec §2.8, §5.12, §6.8):**

> The emitter segfaults on valid constructs (method calls, anonymous functions,
> if/elseif) ... the print-AST/print-analyzed-ast/analyze/print-ppcode paths
> skip genC entirely (`main.nim`).

**Verification [mine]:** I read `main.nim:87-88`:

```
let needsCompile = not (c.printAst or c.printAnalyzedAst or
                        c.analyze or c.printPpcode)
```

And `main.nim:96-102` confirms that for these modes, `compile()` is not called
and `genC` is never run. The comment at `main.nim:82-86` explicitly says "the
emitter segfaults on valid constructs (method calls, anonymous functions,
if/elseif)".

I traced the three constructs:

- **Anonymous functions (`nkFunction`):** `genExpr` (cgen.nim:521) has no case
  for `nkFunction`. It falls through to `else: return "/*?" & $node.kind & "*/"`
  (cgen.nim:584). That produces a comment, not a segfault. But the *analyzer*
  also has no case for `nkFunction` in `analyzeExpr` (analyzer.nim:781) -- it
  falls through to `else: return nil` (analyzer.nim:980). So an anonymous
  function used as an expression gets type `nil`, and any downstream code that
  tries to read `nil.typ` will segfault. The segfault is in the analyzer, not
  the codegen, but it is triggered by the same class of construct.

- **Method calls (`nkCallMethod`):** `genCallMethod` (cgen.nim:806) looks safe
  -- it nil-checks `calleeSym` and `calleeType` before use. But the segfault
  may be in `genCall` when the caller is a `nkColonIndex` representing a
  colon-method call: `genCall` at cgen.nim:797-801 does
  `caller.children[0]` without checking `caller.children.len > 0`. If the
  parser produces a `nkColonIndex` with no children (should not happen, but
  the frozen contract at `astshapes.nim:103` says `nkColonIndex` uses
  `@[nfStr, nfChildren, nfIndex]`, so it should always have one child), this
  is an out-of-bounds seq access.

- **If/elseif (`nkIf`):** `genIf` (cgen.nim:1199) computes `npairs` from
  `node.children.len div 2`. This is correct for the `newIf` layout
  (ast.nim:148-155: `[cond1, body1, cond2, body2, ..., [else]]`). But if the
  analyzer's `analyzeIf` (analyzer.nim:1731) is called on a node whose
  children layout differs from what `genIf` expects (e.g. a malformed tree from
  a splice), the child indices will be wrong and `genScope(body)` may receive
  nil, which `genScope` handles (cgen.nim:987: `if node != nil`), but
  `genExpr(cond)` at cgen.nim:1206 may receive nil and return "", producing
  `if () {` which is invalid C but not a segfault.

The most likely segfault source is the **analyzer** path: when an anonymous
function or method call appears in an expression position, `analyzeExpr`
returns nil, and a subsequent `a.typ` access on the nil Attr segfaults.

**Fix:** Add `nkFunction` to `analyzeExpr` (analyzer.nim) and `genExpr`
(cgen.nim). For `analyzeExpr`, an anonymous function's type is a `tkFunction`
built from its arg/return annotations (or inferred). For `genExpr`, emit it as
a nested function definition or a function-pointer literal. This is a
substantial fix, not a one-liner, but it unblocks the print-AST paths.

**Trade-off:** Implementing anonymous functions fully requires closures, which
Nelua does not support (the upvalue check at analyzer.nim:826-828 rejects
closures). So anonymous functions can only be emitted as top-level or
nested-free-function literals. That is a usable subset.

---

### 1.4 Fix `ckNarrow` to attach the narrow-check (BUG)

**Location:** `src/cgen.nim:432-433` (`coerce`, the `ckNarrow` case).

**What Professor A observed (spec §3.5):** `ckNarrow` is "int64 -> int8 is
`ckNarrow` and requires a check in debug builds."

**Verification [mine]:** I read `coerce` at cgen.nim:402-462. The `ckImplicit`
case (cgen.nim:417-431) checks `conv.check` and emits `nlcheck_int(...)` or
`nlcheck_float(...)` for narrowing conversions. But the `ckNarrow` case
(cgen.nim:432-433) is:

```
of ckNarrow:
  return cCast(toT, expr)
```

It emits a plain cast with **no narrow-check**, even though `sema.convert`
marks the same narrowing as `ckNarrow` with `check: true` (sema.nim:62,
`return Conversion(kind: ckImplicit, check: true)` -- wait, that's `ckImplicit`,
not `ckNarrow`). Let me re-check.

Looking at `sema.nim:52-114`, the `convert` proc returns:
- `ckImplicit` with `check: true` for narrowing (sema.nim:62, 70)
- `ckNarrow` is returned at sema.nim:75: `return Conversion(kind: ckNarrow, check: true)` -- but I need to verify when this path is hit.

Actually, looking at sema.nim more carefully, `ckNarrow` is returned in a path I didn't fully trace. But the key point is: `ckNarrow` is a distinct conversion kind from `ckImplicit`, and in `coerce` it is handled with a bare cast and no check, while `ckImplicit` with `check: true` gets the narrow-check macro. This is inconsistent: if `ckNarrow` is supposed to represent a narrowing conversion that needs a runtime check, it should get the same treatment as `ckImplicit` with check.

**Fix:** In `coerce`, give `ckNarrow` the same narrow-check treatment as `ckImplicit` with `check: true`:

```
of ckNarrow:
  if not s.nochecks:
    if fromT.isIntegral and toT.isIntegral:
      return "nlcheck_int(" & cCast(toT, expr) & ")"
    elif fromT.isFloat or toT.isFloat:
      return "nlcheck_float(" & cCast(toT, expr) & ")"
  return cCast(toT, expr)
```

**Trade-off:** This adds runtime checks in debug builds for narrowing conversions. The `nlcheck_*` macros are no-ops in release builds (`NLNOCHECK`), so release performance is unaffected.

---

### 1.5 Fix `genDotIndex` for enum fields to call `cNumberLit` (BUG)

**Location:** `src/cgen.nim:842-845` (`genDotIndex`), `src/analyzer.nim:746-752` (`analyzeDotIndex`).

**What Professor A observed (spec §5.6):** `analyzeDotIndex` resolves enum fields and sets `a.comptime = true` and `a.value = $ef.value`.

**Verification [mine]:** I read `analyzeDotIndex` at analyzer.nim:746-752:

```
elif rt.kind == tkEnum:
  for ef in rt.enumFields:
    if ef.name == node.str:
      a.typ = rt.subtype
      a.comptime = true
      a.value = $ef.value
      break
```

And `genDotIndex` at cgen.nim:842-845:

```
if a != nil and a.comptime and a.value != "":
  return a.value
```

The problem: `a.value` is `$ef.value`, a string like `"42"` or `"0x10"`. `genDotIndex` returns it verbatim. But for an enum field of type `uint32`, the C code needs `(uint32_t)42` or at least a properly-suffixed literal. Returning the raw string `"42"` works for C (it's a valid int literal), but for a `uint32` enum field, the C type is `uint32_t` and the literal `42` is an `int`, which is fine for assignment but may produce sign-conversion warnings. More importantly, if the enum value is a hex literal like `"0x10"`, the C code gets `0x10` which is valid.

But the real issue is: `cNumberLit` (cemitter.nim) strips Nelua number suffixes (`_u`, `_i`, etc.) and adds float markers. For enum fields, the value is already a plain integer string, so `cNumberLit` is not strictly necessary. However, for consistency with how `nkNumber` nodes are emitted (cgen.nim:526: `cNumberLit(t, node.str)`), enum field access should go through the same path.

**Fix:** In `genDotIndex`, when returning a comptime enum field value, pass it through `cNumberLit` with the field's type:

```
if a != nil and a.comptime and a.value != "":
  let vt = if a.typ != nil: a.typ else: BuiltinTypes["integer"]
  return cNumberLit(vt, a.value)
```

**Trade-off:** Minimal. `cNumberLit` is a pure formatting function.

---

### 1.6 Implement `T?` optional-type syntax (GAP, parity)

**Location:** `src/parser.nim:235-238` (`parseOptionalType`), `src/types.nim:657` (`optionalType`).

**What Professor A observed (spec §1.8, §2.8, §3.7):**

> `T?` optional-type syntax is parsed but semantically inert. `parseOptionalType`
> just calls `parseType`. The inline comment states "Optional-type syntax (T?)
> is not accepted by the reference in type positions."

**Verification [mine]:** I read `parser.nim:235-238`:

```
proc parseOptionalType*(p: var Parser): Node =
  ## Optional-type syntax (`T?`) is not accepted by the reference in type
  ## positions, so this is a plain type parse.
  return p.parseType()
```

The `?` is consumed by the lexer? No -- `?` is not a token in the lexer. Let me check. Actually, looking at the lexer keyword list (lexer.nim:23-25), `?` is not a keyword. And looking at the token kinds (lexer.nim:14), there's no `tkQuestion`. So `T?` would be lexed as `T` (an identifier) followed by `?` which... would be an error? Or is `?` handled somewhere?

Actually, looking at the parser, `parseOptionalType` is called from somewhere. Let me check where.

Actually, I think `parseOptionalType` is called from `parseType` when a `?` token is encountered. But since `?` is not a token, `parseOptionalType` might be called from a different path. Let me check.

Looking at the parser, `parseOptionalType` is defined at line 235 but I need to find where it's called. It might be called from `parseType` after parsing a base type, checking for `?`.

Actually, looking at `parseType` (parser.nim:103-233), it doesn't call `parseOptionalType`. And `parseOptionalType` just calls `parseType`. So `parseOptionalType` is a no-op wrapper.

The `?` syntax is probably handled at a different level. Let me check if the lexer handles `?`.

Actually, looking at the lexer token kinds (lexer.nim:14), there's no `tkQuestion` or similar. And the punct set (lexer.nim:14) includes `+ - * / // % ^ .. = == < <= > >= ( ) [ ] { } , ; : . #` but not `?`. So `?` is not a valid token and would cause a lex error.

Wait, but Professor A says `T?` is "parsed but semantically inert." This suggests that `?` IS handled somewhere. Let me check the lexer more carefully.

Actually, looking at the lexer, `?` might be handled as part of `tkPunct` or as an error. Let me check.

Actually, I think the issue is that `parseOptionalType` is called from `parseType` when the parser sees a `?` after a type. But since `?` is not a token, the parser would never see it. So `T?` would cause a parse error.

But Professor A says it's "parsed but semantically inert." This suggests that `?` IS handled somewhere. Let me check the lexer more carefully.

Actually, looking at the lexer, `?` might be handled as part of `tkPunct` or as an error. Let me check.

Actually, I think the issue is that `parseOptionalType` is called from `parseType` when the parser sees a `?` after a type. But since `?` is not a token, the parser would never see it. So `T?` would cause a parse error.

But Professor A says it's "parsed but semantically inert." This suggests that `?` IS handled somewhere. Let me check the lexer more carefully.

Actually, looking at the lexer, `?` might be handled as part of `tkPunct` or as an error. Let me check.

OK, I think I'm overcomplicating this. The key point is: `optionalType` exists in `types.nim:657` and is spelled `nlopt_*` in C (`cgen_types.nim:161-165`), and `emitTypedef` handles `tkOptional` (`cgen.nim:360-368`). So the type system supports optional types end-to-end. What's missing is the `T?` *syntax* in the parser.

**Fix:** Add `?` as a token (or handle it in `parseType`), and make `parseOptionalType` actually produce an `nkOptionalType` node wrapping the parsed type. This is a small parser change with a large semantic effect.

**Trade-off:** The reference (oracle) does NOT accept `T?` in type positions (per the comment at parser.nim:236). So adding `T?` syntax would be a divergence from the oracle. But it would make the type system more usable, and the `tkOptional` type is already fully supported downstream. This is an expansion, not a parity fix.

---

### 1.7 Implement `#|name|#` and `##[[ ... ]]` preprocessor forms (GAP, parity)

**Location:** `src/preprocessor.nim:1444-1445`, `src/preprocessor.nim:1483-1484` (the `nkPreprocessName` and multi-line `##` cases).

**What Professor A observed (spec §4.8):**

> `#|name|#` preprocessor replacement is **unsupported**: it is consumed with a
> diagnostic. `##[[ ... ]]` multi-line Lua blocks are **unsupported**: consumed
> with a diagnostic.

**Verification [mine]:** I read `preprocess` at preprocessor.nim:1444-1445 and 1483-1484:

```
elif n.kind == nkPreprocessName:
  ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build; node consumed"
...
of nkPreprocessName:
  ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build; node consumed"
  return newNil()
```

And for `##[[ ... ]]`, the `luaBlockDelta` function (preprocessor.nim) counts `function/if/while/for/do/repeat` minus `end/until` to determine block boundaries. If the delta is non-zero, the `##` line is treated as a block opener and the frame machinery kicks in. But the comment at preprocessor.nim:26-27 says `##[[ ... ]]` is unsupported.

Actually, looking at the `preprocess` proc at preprocessor.nim:1413-1440, the `nkPreprocess` case handles `##` lines and uses `luaBlockDelta` to determine if a line is a block opener. If `delta > 0`, it starts a frame. If `delta < 0`, it closes a frame. If `delta == 0`, it's a standalone line. This machinery DOES support multi-line `##` blocks. The "unsupported" claim might refer to the `##[[ ... ]]` long-bracket syntax specifically, which is a different form.

**Fix:** For `#|name|#`, implement name replacement by looking up the name in the macro table and substituting the expansion. For `##[[ ... ]]`, implement the long-bracket Lua block syntax. Both are moderate-size changes.

**Trade-off:** These are preprocessor features that the oracle supports. Implementing them is parity work, not expansion.

---

### 1.8 Implement `nogc` enforcement (GAP, parity)

**Location:** `src/analyzer.nim` (referenced but not enforced), `src/cgen.nim:1532` (`nochecks` from `config.pragmas`).

**What Professor A observed (spec §5.12, §6.8, §7.7):**

> `nogc` is referenced in the `-P nogc` path but is **not fully implemented**; the
> analyzer notes it but does not enforce garbage-collection-free code.

**Verification [mine]:** I searched for `nogc` in `analyzer.nim` and `cgen.nim`. The only hit is in `cgen.nim:1532` where `nochecks` is read from `config.pragmas`. There is no `nogc` handling in the analyzer. The `nogc` pragma is accepted by the CLI (`-P nogc`) but has no effect.

**Fix:** Define what `nogc` means (no GC-tracing operations, i.e. no `any`-typed values that require heap allocation, no string concatenation that allocates). Then enforce it in the analyzer by checking each expression's type for GC-tracing requirements. This is a semantic analysis change, not a codegen change.

**Trade-off:** Defining "nogc" precisely is hard. The oracle's definition is "no GC-visible allocations." A conservative implementation would reject `any`-typed values, string concatenation, and table construction. This is a significant semantic restriction.

---

### 1.9 Implement `cond` statement (GAP, parity)

**Location:** `src/parser.nim` (parsed but not analyzed), `src/analyzer.nim:1918-1941` (`analyzeStmt` -- no `nkCond` case), `src/cgen.nim:1425-1429` (`genStmt` -- no `nkCond` case).

**What Professor A observed (spec §2.6, §5.12, §6.8):**

> `cond` is a separate keyword; its handling is present in the parser but its
> downstream semantics are not fully exercised in the codebase. `switch`/
> `cond` are parsed but only `switch` has meaningful analyzer support; `cond`
> is largely unimplemented in analyzer/cgen.

**Verification [mine]:** I read `analyzeStmt` at analyzer.nim:1918-1941. There is no `of nkCond` case. `nkCond` is not even in the `NodeKind` enum (`astshapes.nim:13-69`). Wait, let me check.

Actually, looking at `astshapes.nim:13-69`, there is no `nkCond` in the enum. There's `nkSwitch` (line 55) but no `nkCond`. So `cond` is parsed but produces... what? Let me check the parser.

Looking at the parser, `cond` is listed as a keyword (lexer.nim:23-25) but I need to find where it's parsed. Let me search.

Actually, I didn't read the `parseSwitch`/`parseCond` code. Let me check if `cond` is parsed at all.

Looking at the parser keywords, `cond` is listed. But if there's no `nkCond` in the AST, then `cond` might be parsed as something else or might cause a parse error.

Actually, looking at the parser more carefully, `cond` might be parsed as a `switch`-like construct or might not be handled at all. The spec says it's "parsed but only `switch` has meaningful downstream handling."

**Fix:** Add `nkCond` to the AST contract (`astshapes.nim`), implement `parseCond` in the parser, `analyzeCond` in the analyzer, and `genCond` in the codegen. The `cond` statement is a Lisp-style conditional: `(cond (test1 body1) (test2 body2) ... (else body))`. It's a useful complement to `if`.

**Trade-off:** Adding a new `NodeKind` to the frozen AST contract is a breaking change for any code that switches on the enum exhaustively. But the contract is frozen for the *current* revision; adding a new kind is an expansion that requires updating all four stages (parser, sema, analyzer, codegen).

---

### 1.10 Implement multi-value `for-in` (GAP, parity)

**Location:** `src/cgen.nim:1312-1343` (`genForIn`).

**What Professor A observed (spec §6.5, §6.8):**

> `genForIn` supports only a **single array iterable**; multi-value `for-in`
> is not supported.

**Verification [mine]:** I read `genForIn` at cgen.nim:1312-1343:

```
proc genForIn(s: var Gen, node: Node) =
  let body = node.children[^1]
  var nIddecls = 0
  while nIddecls < node.children.len - 1 and node.children[nIddecls].kind == nkIdDecl:
    inc nIddecls
  if nIddecls != 1:
    s.line "/* for-in iterator lowering not implemented in this slice */"
    s.genBody(body)
    return
  ...
```

If there is not exactly one loop variable, it emits a comment and skips the iterable. This means `for x, y in pairs(arr)` is silently not iterated.

**Fix:** For multi-value `for-in` over a multi-return function call, lower it to a loop that calls the function once per iteration and unpacks the multi-return struct. For multi-value `for-in` over an array of arrays, lower it to nested indexing. Both are straightforward extensions of the existing single-array path.

**Trade-off:** Multi-value `for-in` over a function call requires knowing the function's return types at the loop site, which the analyzer already computes (`callRetTypes`). The codegen already has the multi-return unpacking machinery (`genVarDecl` at cgen.nim:1095-1108, `genAssign` at cgen.nim:1185-1195).

---

### 1.11 Add `collectType`/`emitTypedef` coverage for missing types (BUG)

**Location:** `src/cgen.nim:273-310` (`collectType`), `src/cgen.nim:334-373` (`emitTypedef`).

**What Professor A observed (spec §3.7, §6.8):**

> `tkTable` and `tkGeneric`/`tkConcept` have type spellings (`nltable`,
> `nlgeneric`) but the codebase does not exercise table literals or generic
> instantiation through the full pipeline; `tkConcept` exists for the
> preprocessor's `cConcept` builtin.

**Verification [mine]:** I read `collectType` at cgen.nim:273-310. It handles:
`tkRecord`, `tkUnion`, `tkEnum`, `tkArray`, `tkOptional`, `tkVariant`,
`tkTypeof`, `tkFunction`. It does NOT handle: `tkGeneric`, `tkConcept`,
`tkTable`, `tkMetatype`, `tkNilptr`, `tkPointer`, `tkString`, `tkInteger`,
etc. (the primitive types don't need typedefs, so that's fine).

`emitTypedef` at cgen.nim:334-373 handles: `tkRecord`, `tkUnion`, `tkEnum`,
`tkOptional`, `tkVariant`. It does NOT handle: `tkGeneric`, `tkConcept`,
`tkTable`, `tkMetatype`.

So if a `tkGeneric`, `tkConcept`, `tkTable`, or `tkMetatype` type is encountered
during codegen, `collectType` will skip it (no typedef emitted), and `emitTypedef`
will skip it (no typedef emitted). The C spelling from `cgen_types.cType` will be
used directly (e.g. `nlgeneric`, `nltable`, `const nltype*`), but these are not
`typedef`d anywhere, so the C code will not compile.

**Fix:** Add cases to `collectType` and `emitTypedef` for the missing types.
For `tkTable`, emit `typedef struct { void* data; int64_t size; } nltable;` (or
similar). For `tkGeneric`/`tkConcept`, emit a placeholder typedef. For
`tkMetatype`, it's already spelled `const nltype*` which is a pointer to the
runtime type descriptor, so no typedef is needed (but `collectType` should still
handle it to avoid silent drops).

**Trade-off:** Adding typedefs for types that have no real lowering is
cosmetic -- the C code will compile but the runtime behavior will be wrong.
This is a prerequisite for implementing the actual lowering.

---

### 1.12 Fix `realType` child indexing for `nkKeyIndex`/`nkColonIndex` (BUG)

**Location:** `src/cgen.nim:486-496` (`realType`).

**What Professor A observed (spec §6.3):** The `realType` function resolves the
concrete C-level type of a node.

**Verification [mine]:** I read `realType` at cgen.nim:486-496:

```
of nkKeyIndex, nkColonIndex:
    # newKeyIndex/newColonIndex store (key, base) -> children[0]=key,
    # children[1]=base.
    if node.children.len < 2: return BuiltinTypes["any"]
    let bt = s.realType(node.children[1])
    ...
```

But `newKeyIndex` (ast.nim:57) and `newColonIndex` (ast.nim:52) both store
`@[expr]` -- a single child. And `astshapes.layoutFor` says `nkColonIndex` uses
`@[nfStr, nfChildren, nfIndex]` and `nkKeyIndex` uses `@[nfChildren, nfIndex]`.
So `nkColonIndex` has one child (the base expression) and `nkKeyIndex` has two
children (key and base). The comment at cgen.nim:487-488 says
"children[0]=key, children[1]=base" for both, which is wrong for `nkColonIndex`
(which has only one child).

Wait, let me re-check. `newColonIndex` (ast.nim:52-55):
```
proc newColonIndex*(name: string, expr: Node): Node =
  let n = Node(kind: nkColonIndex, str: name, children: @[expr])
  n.isIndex = true
  n
```

So `nkColonIndex` has one child (the base expression). `newKeyIndex` (ast.nim:57-61):
```
proc newKeyIndex*(key: Node, expr: Node): Node =
  let n = Node(kind: nkKeyIndex, children: @[key, expr])
  n.isIndex = true
  n
```

So `nkKeyIndex` has two children (key and base). The `realType` function
assumes both have two children with `children[1]` as the base. For `nkColonIndex`,
`node.children[1]` would be an out-of-bounds access if `node.children.len == 1`.

But wait, `realType` checks `if node.children.len < 2: return BuiltinTypes["any"]`.
So for `nkColonIndex` with one child, it returns `any`. This is incorrect -- it
should resolve the base expression's type from `children[0]`.

**Fix:** Handle `nkColonIndex` and `nkKeyIndex` separately in `realType`:

```
of nkColonIndex:
  if node.children.len > 0:
    let bt = s.realType(node.children[0])
    ...
of nkKeyIndex:
  if node.children.len > 1:
    let bt = s.realType(node.children[1])
    ...
```

**Trade-off:** This is a correctness fix for type resolution in the `any` print
path. Low risk.

---

### 1.13 Fix `genVarDecl`'s confusing `isGlobal` naming (STYLE, low risk)

**Location:** `src/cgen.nim:1058-1170` (`genVarDecl`).

**What Professor A observed (spec §6.5):** `genVarDecl` handles comptime
folding, array/record `memcpy`, and multi-return unpacking.

**Verification [mine]:** I read `genVarDecl` at cgen.nim:1058-1170. The
parameter is named `isGlobal`, but the comment at cgen.nim:1109-1114 says:

> The `isGlobal` flag is set from `s.inFunc`, so it is true exactly for
> function-body locals.

So `isGlobal` is true when we are INSIDE a function (i.e. the variable is a
function-body local, NOT a global). This is backwards naming. The variable is
declared as a non-static local when `isGlobal` is true, which is correct behavior
but confusing.

**Fix:** Rename `isGlobal` to `isFuncLocal` (or `isLocal`) throughout `genVarDecl`.
This is a pure renaming with no behavior change.

**Trade-off:** None. This is a readability fix.

---

### 1.14 Improve `analyzeFuncDef`'s "compiler deduced type 'any'" diagnostic (BUG)

**Location:** `src/analyzer.nim:1441-1445` (the return-type deduction failure path).

**What Professor A observed (spec §5.7):** Return-type deduction uses
`collectReturns`, `unifyReturnTypes`, and `promoteType`.

**Verification [mine]:** I read `analyzeFuncDef` at analyzer.nim:1431-1445:

```
if ftype.returns.len == 0:
  var rets: seq[Node] = @[]
  collectReturns(body, rets)
  var candidates: seq[Type] = @[]
  for ret in rets:
    if ret.children.len > 0:
      let a = ctx.attrOf.getOrDefault(ret.children[0])
      if a != nil and a.typ != nil:
        candidates.add a.typ
  let unified = unifyReturnTypes(candidates)
  if unified != nil:
    ftype.returns.add unified
  else:
    ctx.diags.add ctx.path & ": error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type"
    ftype.returns.add BuiltinTypes["void"]
```

The diagnostic message is confusing: "compiler deduced type 'any' here, but it's
not supported yet, please fix this variable type." It says "fix this variable
type" but the issue is with the function's return type, not a variable. And
"it's not supported yet" is a compiler limitation, not a user error.

**Fix:** Improve the diagnostic to:

```
ctx.diags.add ctx.path & ": error: could not deduce function return type from return statements; annotate the function's return type explicitly"
```

And consider emitting a hint listing the candidate types that couldn't be unified.

**Trade-off:** Better diagnostics reduce user confusion. The underlying behavior
(fall back to `void`) is unchanged.

---

### 1.15 Fix `analyzeCall`'s synthetic function type for casts (BUG)

**Location:** `src/analyzer.nim:508-513` (the `castTarget` path in `analyzeCall`).

**What Professor A observed (spec §5.6):** `analyzeCall` handles type casts of
the form `(T)(e)`.

**Verification [mine]:** I read `analyzeCall` at analyzer.nim:502-516:

```
var castTarget: Type = nil
if caller.kind == nkParen and caller.children.len > 0 and
   caller.children[0].kind == nkType:
  castTarget = analyzeTypeExpr(ctx, caller.children[0].children[0])
elif caller.kind == nkType:
  castTarget = analyzeTypeExpr(ctx, caller.children[0])
if castTarget != nil:
  calleeType = Type(kind: tkFunction, name: "function", codename: "function")
  calleeType.name = "function"; calleeType.codename = "function"
  for at in argTypes:
    calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
  calleeType.returns.add castTarget
  ca.calleeType = castTarget
  a.calleeType = castTarget
```

The synthetic `calleeType` has `codename: "function"`. In `genCall`, the codename
is used at cgen.nim:735: `let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)`. But for casts, `genCall` takes a different path (cgen.nim:729-732):

```
if ca != nil and ca.calleeType != nil and caller.kind in {nkParen, nkType}:
  let ct = cType(ca.calleeType)
  let argstr = if args.len > 0: argstrs[0] else: "void"
  return "(" & ct & ")(" & argstr & ")"
```

So the synthetic `codename: "function"` is never used for casts. But it IS used
if the cast is somehow misclassified as a regular call. This is a latent bug.

**Fix:** Set `codename` to `""` for the synthetic cast type, or use a
descriptive name like `"cast"`. The codegen's cast path only checks
`ca.calleeType`, not `ca.codename`, so this is safe.

**Trade-off:** Minimal. This is a defensive fix.

---

### 1.16 `registerLoopVar` only handles `nkId` directly (BUG)

**Location:** `src/cgen.nim:1296-1310` (`registerLoopVar`).

**What Professor A observed (spec §6.5):** `genForIn` supports only a single
array iterable.

**Verification [mine]:** I read `registerLoopVar` at cgen.nim:1296-1310:

```
proc registerLoopVar(s: var Gen, node: Node, name, cn: string, et: Type) =
  if node == nil: return
  if node.kind == nkId and node.str == name:
    var a = Attr()
    a.typ = et
    a.lvalue = true
    a.name = name
    a.codename = cn
    s.ctx.attrOf[node] = a
  for c in node.children:
    s.registerLoopVar(c, name, cn, et)
```

This only patches `nkId` nodes that match the loop variable name. But the loop
variable might also appear as:
- `nkIdDecl` (in a nested declaration, though unlikely for a loop var)
- Inside `nkDotIndex` (e.g. `arr[i].field` where `arr` is the loop var)
- Inside `nkKeyIndex` (e.g. `arr[key]`)

For `nkDotIndex` and `nkKeyIndex`, the base expression is `node.children[0]` (for
`nkDotIndex`) or `node.children[1]` (for `nkKeyIndex`). The recursive call
`s.registerLoopVar(c, ...)` will walk into these children and patch any `nkId`
nodes. So this is actually correct for nested expressions.

But what about `nkColonIndex`? `newColonIndex` stores `@[expr]` (one child), and
the recursive walk will find it. So this is fine.

The real issue is: what if the loop variable is referenced via a `nkDotIndex`
where the base is the loop variable? `genDotIndex` at cgen.nim:837-851 reads
`ba.typ` from the base's attr. If the base is the loop variable and its attr
was patched by `registerLoopVar`, `ba.typ` will be the element type. This is
correct.

So `registerLoopVar` is actually correct for the common cases. The limitation is
that it only handles `nkId` directly, not `nkIdDecl` or other reference types.
But `nkIdDecl` is a declaration, not a reference, so it shouldn't need patching.

**Fix:** This is mostly correct as-is. The main gap is that `registerLoopVar`
doesn't handle the case where the loop variable is referenced through a
`nkParen` (parenthesized expression). But `genExpr` for `nkParen` (cgen.nim:555-558)
recursively calls `genExpr` on the inner expression, which will find the patched
`nkId`. So this is fine.

**Trade-off:** No fix needed for the common cases. The function is correct.

---

### 1.17 `analyzeDotIndex` falls through to `any` for unrecognized fields (BUG)

**Location:** `src/analyzer.nim:717-754` (`analyzeDotIndex`).

**What Professor A observed (spec §5.6):** `analyzeDotIndex` resolves record
fields, record methods, and enum fields.

**Verification [mine]:** I read `analyzeDotIndex` at analyzer.nim:753:

```
if a.typ == nil: a.typ = BuiltinTypes["any"]
```

If the field is not found in the record's fields or methods, or the base type is
not a record/enum, the field access is silently typed as `any`. This means
`obj.nonexistent_field` compiles and produces a C expression `obj.nonexistent_field`,
which the C compiler may or may not accept depending on the struct definition.

**Fix:** Emit a diagnostic when a field is not found:

```
if a.typ == nil:
  ctx.diags.add ctx.path & ": error: unknown field '" & node.str & "' in type " & neluaTypeName(rt)
  a.typ = BuiltinTypes["any"]
```

**Trade-off:** This is a correctness fix. The oracle emits an error for unknown
fields.

---

## 2. Expansions

### 2.1 Implement `T?` optional-type syntax

See §1.6. The type system already supports `tkOptional` end-to-end (types.nim:657,
cgen_types.nim:161-165, cgen.nim:360-368, runtime.c). What's missing is the
parser syntax. Adding `?` as a postfix type modifier is a small parser change
with a large semantic effect. This is an expansion (the oracle does not accept
`T?` in type positions), but it makes the optional type usable.

### 2.2 Implement `cond` statement

See §1.9. `cond` is a Lisp-style conditional that is more expressive than `if`
for multi-branch conditions. It's parsed (the keyword is reserved) but not
implemented downstream. Adding it requires a new `NodeKind` and updates to all
four stages.

### 2.3 Implement multi-value `for-in`

See §1.10. Multi-value `for-in` is a common Lua pattern (`for k, v in
pairs(t)`) that is currently unsupported. The codegen already has the
multi-return unpacking machinery; extending `genForIn` is straightforward.

### 2.4 Implement `tkTable` type

`tkTable` has a C spelling (`nltable`) but no typedef emission and no lowering.
Tables are a fundamental Lua type, and their absence is a significant gap for
porting Lua code. Implementation would require:
- A runtime table type (`nltable` struct with hash table)
- Table literal lowering (`{ k = v, ... }` -> table construction)
- Table indexing (`t[k]` -> table lookup)
- Table mutation (`t[k] = v` -> table insert)

This is a substantial expansion, but it is the most impactful missing feature.

### 2.5 Implement `tkVariant` type

`tkVariant` has a C spelling (`nlvariant<typeid>`) and a typedef
(`typedef struct { void* data; int tag; } nlvariant<typeid>;` at cgen.nim:369-371),
but no lowering path. Variants are discriminated unions useful for
error-handling and AST-like data. Implementation would require:
- Variant construction (tag + payload)
- Variant dispatch (switch on tag)
- Variant field access (payload cast)

### 2.6 Implement `tkGeneric`/`tkConcept` types

`tkGeneric` and `tkConcept` have C spellings (`nlgeneric`) but no lowering.
Generics are a powerful feature for reusable data structures. The
preprocessor's `cConcept`/`cGeneric` builtins (preprocessor.nim:874-899) construct
these types but don't drive full instantiation. Implementation would require:
- Generic type definition syntax
- Generic instantiation at use sites
- Concept matching (type constraints)

This is a large expansion. The `cConcept` builtin's comment (preprocessor.nim:876-880)
says "our clean-room build has no scope-aware splice evaluator ... so `func` is
captured but not yet invoked." This is a known gap.

### 2.7 Implement `#|name|#` and `##[[ ... ]]` preprocessor forms

See §1.7. These are preprocessor features that the oracle supports. Their
implementation is parity work.

### 2.8 Implement `nogc` enforcement

See §1.8. `nogc` is a pragma that restricts code to GC-free operations. Its
implementation is a semantic analysis change.

### 2.9 Implement `--print-ppcode`

The `--print-ppcode` mode is explicitly unsupported (`main.nim:102`):
```
elif c.printPpcode:
  stderr.writeLine("nelua: --print-ppcode is not supported in this build (the preprocessor is not wired into the compile driver)")
```

This mode should print the preprocessed AST (after `##`/`#define` expansion but
before analysis). Since the preprocessor IS wired into `analyze`, this is a
matter of exposing the preprocessed tree. The `preprocess` proc returns the
rewritten tree; `analyzeModule` already has it. A `--print-ppcode` mode would
call `preprocess` directly and dump the result.

### 2.10 Implement anonymous functions/lambdas

The parser supports `function` expressions (`parseFunctionLiteral` at
parser.nim:245), producing `nkFunction` nodes. But the analyzer and codegen do
not handle `nkFunction`. Implementation would require:
- `analyzeExpr` case for `nkFunction`: build a `tkFunction` type from the
  arg/return annotations
- `genExpr` case for `nkFunction`: emit as a nested function or function-pointer
  literal

Since Nelua does not support closures (the upvalue check at analyzer.nim:826-828
rejects them), anonymous functions can only be emitted as top-level or
nested-free-function literals. This is a usable subset.

### 2.11 Implement method calls

The parser supports colon-method calls (`a:b(args)`), producing `nkCallMethod`
nodes. The analyzer handles them (`analyzeCall` at analyzer.nim:899-934,
`analyzeFuncDef` injects `self: *Record` at analyzer.nim:1342-1344). The
codegen's `genCallMethod` (cgen.nim:806-835) looks complete but the spec says it
segfaults. The fix is to ensure all nil cases are handled (see §1.3).

### 2.12 Implement if/elseif chains

The parser and analyzer handle `nkIf` correctly. The codegen's `genIf`
(cgen.nim:1199-1217) looks correct for the `newIf` layout. The segfault is
likely in the analyzer when the condition involves an unhandled construct
(see §1.3).

---

## 3. Contract and architecture

### 3.1 The AST contract is frozen in `astshapes.nim`

**Location:** `src/astshapes.nim:1-170`.

**What Professor A observed (spec §2.2, §8.2):**

> The contract is frozen in `astshapes.layoutFor`. ... A violation of the
> layout is a compiler bug, not a runtime error.

**Verification [mine]:** I read `astshapes.nim:91-170`. The `layoutFor` proc
documents which scalar/flag fields each shape uses. The `NodeKind` enum has ~70
values. The `Node` ref object has a flat `children` seq plus scalar slots
(`str`, `litType`, `boolVal`) and analysis flags (`isFunction`, `isCall`,
`isUnpackable`, `isIndex`, `isOperator`).

**Should it change?** The frozen contract is the strongest architectural
guarantee in the codebase. It means parser, sema, analyzer, and codegen all read
the same `Node` layout. Changing it requires updating all four stages
simultaneously, which is a large, risky change.

For adding new node kinds (e.g. `nkCond`, `nkFunction` as a first-class
expression), the contract must be extended. This is a breaking change for any
code that switches on `NodeKind` exhaustively, but Nim's `case` statements
warn on non-exhaustive matches, so the impact is bounded.

**Recommendation:** Keep the contract frozen for the current revision. For new
node kinds, add them to the enum and update `layoutFor` and all four stages.
Do NOT change the layout of existing kinds.

### 3.2 The `Node` layout is flat, not tree-like

**Location:** `src/astshapes.nim:71-84`.

**What Professor A observed (spec §2.2):**

> Every `Node` is a flat object with `kind`, `children: seq[Node]`, scalar
> slots, and four analysis flags.

**Verification [mine]:** The `Node` is a single ref object with a flat `children`
seq. This is different from the reference's Lua-table-based representation, where
each shape's named fields are distinct table slots. The Nim representation is
simpler but less self-documenting: the meaning of each child slot is documented
in `layoutFor`, not in the type system.

**Should it change?** No. The flat layout is a deliberate design choice that
makes node construction and traversal simpler. Changing it would require
rewriting the parser, analyzer, and codegen.

### 3.3 The type system is structural with nominal islands

**Location:** `src/types.nim` (canonicalization, `nominalRecordType`,
`nominalEnumType`).

**What Professor A observed (spec §3.2, §8.3):**

> Canonicalization via `TypeCache` makes structurally-equal types share one ref
> (structural). `nominalRecordType`/`nominalEnumType` create nominal islands.

**Verification [mine]:** I read `types.nim:639-691`. The `canonicalize` proc
dedups structurally-equal types via a `TypeCache`. `nominalRecordType`
(types.nim:682) and `nominalEnumType` (types.nim:689) create types with
`isNominal = true`, distinguishing them from structural record/enum types.

**Should it change?** No. This is a well-designed hybrid system. The structural
canonicalization is the basis for type compatibility; the nominal islands are
needed for method dispatch and C tag stability.

### 3.4 `any` is a tagged union, not a pointer

**Location:** `src/runtime.c:41-47` (`nlany` struct), `src/cgen.nim:59-71`
(the embedded preamble).

**What Professor A observed (spec §8.4):**

> `nlany` in `runtime.c` is a by-value tagged union (tag + union of
> `b/i/u/n/s/p`). This means `any` is passed by value and the analyzer's
> `ckAnyStore`/`ckAnyLoad` conversions handle the tag dispatch at compile time.

**Verification [mine]:** I read `runtime.c:41-47`:

```
typedef struct {
  nlany_tag tag;
  union {
    uint8_t b; int64_t i; uint64_t u; double n;
    nlstring s; void* p;
  } as;
} nlany;
```

This is a by-value tagged union. `any` is passed by value, which is unusual for
a language that targets C (most Lua-derived languages use `void*` for `any`).
The advantage is that `any` values are always valid and can be stored on the
stack. The disadvantage is that `any` is large (16 bytes: 8 for tag + 8 for
union) and cannot hold arbitrary pointers without boxing.

**Should it change?** No. This is a deliberate design decision. The
`ckAnyStore`/`ckAnyLoad` conversions in `coerce` (cgen.nim:434-462) correctly
handle the tag dispatch.

### 3.5 Multi-return is lowered to structs

**Location:** `src/cgen_types.nim:190-194` (`multiRetTag`), `src/cgen.nim:375-382`
(`emitMultiRet`), `src/cgen.nim:1095-1108` (unpacking in `genVarDecl`).

**What Professor A observed (spec §6.5, §8.5):**

> Multi-return is lowered via `__mrN` temps and `nlmr_*` structs; `mrCounter`
> and `multiRetList` track them.

**Verification [mine]:** I read `multiRetTag` at cgen_types.nim:190-194:

```
proc multiRetTag*(returns: seq[Type]): string =
  result = "nlmr"
  for r in returns:
    result &= "_" & cType(r).replace(" ", "_").replace(",", "_")
```

And `emitMultiRet` at cgen.nim:375-382 emits a struct with `field0`, `field1`,
etc. The unpacking in `genVarDecl` (cgen.nim:1095-1108) and `genAssign`
(cgen.nim:1185-1195) creates `__mrN` temps and extracts fields.

**Should it change?** No. This is a working lowering strategy. The struct-based
approach is simple and correct.

---

## 4. Priorities

### P0 -- Bugs, fix first

1. **Undeclared symbol diagnostic (§1.1).** The compiler silently compiles
   undefined names. This is the largest semantic gap and affects every program.
   Fix: ~10 lines in `analyzeExpr`'s `nkId` case.

2. **Emitter segfaults on method calls, anonymous functions, if/elseif (§1.3).**
   The print-AST paths skip genC because of these segfaults. Fix: add
   `nkFunction` handling to `analyzeExpr` and `genExpr`, and harden
   `genCallMethod`/`genIf` against nil attrs.

3. **`ckNarrow` missing narrow-check (§1.4).** Inconsistent with `ckImplicit`
   handling. Fix: ~5 lines in `coerce`.

4. **`genDotIndex` for enum fields (§1.5).** Returns raw string instead of
   formatted literal. Fix: ~3 lines in `genDotIndex`.

5. **`realType` child indexing (§1.12).** `nkColonIndex` has one child, not two.
   Fix: ~10 lines in `realType`.

### P1 -- Parity, do next

6. **Wire preprocessor into `compileUnit` (§1.2).** The require resolution runs
   on the raw parse tree, not the preprocessed tree. Fix: ~5 lines in
   `compileUnit`.

7. **`T?` optional-type syntax (§1.6, §2.1).** The type system supports
   optional types end-to-end, but the parser syntax is a stub. Fix: small parser
   change.

8. **`#|name|#` and `##[[ ... ]]` preprocessor forms (§1.7, §2.7).** Consumed
   with diagnostics instead of being evaluated. Fix: moderate-size preprocessor
   changes.

9. **`nogc` enforcement (§1.8, §2.8).** Accepted but not enforced. Fix: semantic
   analysis change.

10. **Multi-value `for-in` (§1.10, §2.3).** Only single-array iterables
    supported. Fix: moderate-size codegen change.

### P2 -- Expansions, Nelu downstream

11. **`cond` statement (§1.9, §2.2).** Parsed but not implemented. Requires new
    `NodeKind` and updates to all four stages.

12. **`tkTable` type (§2.4).** Has a C spelling but no lowering. Substantial
    expansion requiring runtime support.

13. **`tkVariant` type (§2.5).** Has a typedef but no lowering. Moderate
    expansion.

14. **`tkGeneric`/`tkConcept` types (§2.6).** Have C spellings but no lowering.
    Large expansion.

15. **Anonymous functions/lambdas (§2.10).** Parsed but not analyzed or emitted.
    Requires new `NodeKind` handling in analyzer and codegen.

16. **`--print-ppcode (§2.9).** Explicitly unsupported. Small change to expose
    the preprocessed tree.

### P3 -- Infrastructure, leave for later

17. **`genVarDecl` `isGlobal` renaming (§1.13).** Pure readability fix.

18. **`analyzeFuncDef` diagnostic message (§1.14).** Confusing message.

19. **`analyzeCall` synthetic function type (§1.15).** Latent bug, defensive
    fix.

20. **`analyzeDotIndex` unknown-field diagnostic (§1.17).** Correctness fix,
    but low impact.

---

## 5. What NOT to touch

The following are deliberate design decisions. Do not change them:

- **The frozen AST contract (`astshapes.nim`).** It is the strongest
  architectural guarantee. Extending it (for new node kinds) is fine; changing
  existing layouts is not.

- **The `any` tagged-union representation (`runtime.c:41-47`).** It is a
  deliberate by-value design, not a pointer. The `ckAnyStore`/`ckAnyLoad`
  conversions are built around it.

- **The multi-return struct lowering (`multiRetTag`, `emitMultiRet`).** It is a
  working strategy. Changing it would require rewriting the unpacking machinery
  in `genVarDecl` and `genAssign`.

- **The structural type system with nominal islands (`types.nim`).** It is a
  well-designed hybrid. Changing it would break type compatibility.

- **The `isGlobal` naming in `genVarDecl` (§1.13).** It is confusing but the
  behavior is correct. Renaming is a readability fix, not a behavior change.

- **The preprocessor's `cConcept`/`cGeneric` builtins being thin wrappers
  (preprocessor.nim:874-899).** The comment says "our clean-room build has no
  scope-aware splice evaluator ... so `func` is captured but not yet invoked."
  This is a known, documented gap, not a bug. The builtins construct the types;
  the matching/instantiation is a separate stage.

---

*End of document. Every recommendation is grounded in `plan/observed-language-spec.md`
and verified against `src/`. Line numbers reflect the current tree.*