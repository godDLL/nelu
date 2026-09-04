# Cover Corpus: examples/cover/

Short Nelua programs, one per missing language element, that prove the
construct exists in the Nelua 0.2.0-dev language (the oracle at `/usr/bin/nelua`
accepts every file here). They become regression probes once the clean-room
Nelu compiler (`tmp/nelua`) implements the element.

Generated from the findings in `plan/nelu-language-coverage-gap.md`. Scope:
A-ranked (missing) and B-ranked (parses but misbehaves) findings. No `src/`
was edited, no git command was run, no gate script was touched.

This version was re-checked after four more language features landed in the
live tree (iterator-form `for ... in`, commit `4ea5348`; the `in (expr)`
splice-function keyword; the keyword-as-identifier fix; and the truncate-
operator fix `///`/`%%%`/`>>>`). See Section 4 for what changed.

## 1. Results table

Verdict column = the gap-doc verdict for the construct. Oracle column = oracle
stdout (first line) + exit. Ours column = Nelu stdout (first line) + exit.
Status labels:

- `MATCH` - oracle accepts, Nelu produces the same output and exit.
- `DIFF` - oracle accepts, Nelu exits 0 but prints the wrong value (nil).
- `NELU_REJECT` - oracle accepts, Nelu exits 1 with a parse/keyword error.
- `NELU_CRASH` - oracle accepts, Nelu parses it but the generated C fails to
  compile (exit 1).

Every file below is `ORACLE_ACCEPT` (oracle exit 0); no file is `ORACLE_REJECT`.

| file | construct | verdict | oracle (stdout + exit) | ours (stdout + exit) | status |
|---|---|---|---|---|---|
| `macro-def.nelua` | `## local function NAME(args) ... ## end` macro def, `in (expr)` body, `#[name]#(...)` splice-call | A | `42` + 0 | `42` + 0 | MATCH |
| `switch-case.nelua` | `switch`/`case`/`else` statement | A | `two or three` + 0 | `two or three` + 0 | MATCH |
| `facultative-type.nelua` | `facultative(T)` type form | B | `hello` + 0 | `hello` + 0 | MATCH |
| `type-value-position.nelua` | `@integer` in value position (`local T = @integer`) | B | `5` + 0 | `5` + 0 | MATCH |
| `tdiv.nelua` | `///` (truncate division) | B | `3` + 0 | `3` + 0 | MATCH |
| `tmod.nelua` | `%%%` (truncate modulo) | B | `2` + 0 | `2` + 0 | MATCH |
| `asr.nelua` | `>>>` (arithmetic shift right) | B | `4` + 0 | `4` + 0 | MATCH |
| `splice-ident.nelua` | `#[x]#` splice of a variable reference | B | `5` + 0 | `nil` + 0 | DIFF |
| `fallthrough.nelua` | `fallthrough` keyword in `switch` | A | `one` + 0 | `one` + 0 | MATCH |
| `record-type.nelua` | `@record{ ... }` type form | B | `1 a` + 0 | `1 a` + 0 | MATCH |
| `union-type.nelua` | `@union{ ... }` type form | B | `1` + 0 | `1` + 0 | MATCH |
| `enum-type.nelua` | `@enum{ A=0, B=1 }` type form | B | `0` + 0 | `0` + 0 | MATCH |
| `meta-binary-dispatch.nelua` | `__add` binary-op metamethod dispatch | A | `3` + 0 | `3` + 0 | MATCH |
| `meta-unary-dispatch.nelua` | `__unm` unary metamethod dispatch | A | `-5` + 0 | `-5` + 0 | MATCH |
| `meta-len.nelua` | `__len` metamethod (M1) | B | `42` + 0 | `42` + 0 | MATCH |
| `meta-tostring.nelua` | `__tostring` metamethod (M2) | B | `R` + 0 | `R` + 0 | MATCH |
| `meta-call.nelua` | `__call` metamethod (M3) | B | `6` + 0 | `6` + 0 | MATCH |
| `meta-bnot.nelua` | `__bnot` unary metamethod | B | `-6` + 0 | `-6` + 0 | MATCH |
| `goto-label.nelua` | `goto` / `::label::` | A/B | `done` + 0 | `done` + 0 | MATCH |
| `sizeof-builtin.nelua` | `#integer` `#string` `#usize` sizeof on builtin types | A | `8` + 0 | `8` + 0 | MATCH |
| `keyword-import.nelua` | `import` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-macro.nelua` | `macro` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cond.nelua` | `cond` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-varargs.nelua` | `varargs` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-varautos.nelua` | `varautos` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-varanys.nelua` | `varanys` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cvarargs.nelua` | `cvarargs` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-any.nelua` | `any` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-auto.nelua` | `auto` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-integer.nelua` | `integer` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-number.nelua` | `number` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-string.nelua` | `string` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-boolean.nelua` | `boolean` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-isize.nelua` | `isize` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-usize.nelua` | `usize` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cchar.nelua` | `cchar` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cshort.nelua` | `cshort` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cint.nelua` | `cint` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-clong.nelua` | `clong` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cfloat.nelua` | `cfloat` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-cdouble.nelua` | `cdouble` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-void.nelua` | `void` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |
| `keyword-type.nelua` | `type` used as identifier | B | `42` + 0 | `42` + 0 | MATCH |

## 2. Counts

- Files written: **43**
- Oracle accepts (exit 0): **43** (all of them)
- Nelu MATCH (same output and exit): **42**
  - `macro-def.nelua`, `switch-case.nelua`, `facultative-type.nelua`,
    `type-value-position.nelua`, `tdiv.nelua`, `tmod.nelua`, `asr.nelua`,
    `goto-label.nelua`, `fallthrough.nelua`, `sizeof-builtin.nelua`,
    the 23 `keyword-*` files, and (since the metamethods + record/union/enum
    integration) `record-type.nelua`, `union-type.nelua`, `enum-type.nelua`,
    `meta-binary-dispatch.nelua`, `meta-unary-dispatch.nelua`,
    `meta-len.nelua`, `meta-tostring.nelua`, `meta-call.nelua`,
    `meta-bnot.nelua`.
- Nelu exits 0 but prints the wrong value (DIFF): **1**
  - `splice-ident.nelua` (prints `nil` instead of `5`)
- Nelu rejects with a parse/keyword error (NELU_REJECT): **0**
- Nelu parses but the generated C fails to compile (NELU_CRASH): **0**

Open gaps this corpus documents: **1 of 43** files is not yet handled by Nelu
(`splice-ident.nelua`, a DIFF). The 42 MATCH files are gaps that have since
closed (`macro-def`, `tdiv`, `tmod`, `asr`, `goto-label`, `fallthrough`,
`sizeof-builtin`, the 23 `keyword-*` files, the 9 metamethod/record/union/
`enum` probes above) or were already rated C in the gap doc.

## 3. Gates

`plan/cmp.py` and `plan/regress.py` both scan their own scratch corpora
(`tmp/corpus_nelua/`, `tmp/m2_corpus/`, and cmp.py's inline 40 cases); neither
discovers `examples/cover/`. Confirmed run on the current tree:

- `python3 plan/cmp.py` - report-only, exit 0, 1 diff out of 40 (case 25, a
  known oracle-rejects-but-Nelu-parses case). Unaffected by the corpus.
- `python3 plan/regress.py` - **GREEN**: M1 25 MATCH / 3 DIFF / 0 CRASH (at
  baseline), M2 14/14 MATCH. Unaffected by the corpus.
- `python3 plan/examples_parity.py` - 2 MATCH / 5 DIFF / 3 SKIP. The 5 DIFFs
  are all `exit=1` parse failures in `lib/` transitives (e.g.
  `lib/sequence.nelua:233` `for i,field in ipairs(...)`), not regressions from
  the corpus.

None of the 43 cover files produces a SIGSEGV or "Illegal storage access" in
Nelu; the exit-1 files are all C-compile failures, so they add no CRASH to any
gate count.

## 4. Changes since the first version of this doc

Two language features landed in the live tree after the first pass, and the
corpus was re-checked against a fresh `tmp/nelua` build
(`nim c -d:release --path:src -o:tmp/nelua src/main.nim`).

### 4.1 `macro-def.nelua` - gap CLOSED (was A, now MATCH)

The `in (expr)` splice-function keyword landed. `macro-def.nelua` now compiles
and runs in Nelu, printing `42` exactly like the oracle. This file exercises
three inseparable A-ranked findings in one program: the `## local function
NAME(args) ... ## end` macro *definition*, the `in (expr)` body syntax, and the
`#[name]#(...)` splice-call. It is kept as a positive regression probe.

Note: the form is MULTI-LINE - the `in (expr)` must be on its own line between
the opener and `## end`. The single-line
`## local function f(x) in (expr) ## end` form is NOT valid; the oracle rejects
it too (the `##` line is fed to Lua and `in` is not valid Lua there). The corpus
file uses only the multi-line form.

### 4.2 `for-in-iterator.nelua` - DROPPED

The iterator-form `for ... in` is now parsed and lowered by Nelu (commit
`4ea5348`); it is no longer the A-ranked "not supported" rejection. However it
does NOT yet MATCH the oracle, so it could not be kept as a positive regression
probe:

- Nelu parses and lowers `for ... in`, but the C back-end still fails: the
  lowering emits a `__forcont` state variable of void type, so the generated C
  does not compile. This is a B (parses but misbehaves), not a C.
- The only oracle-accepted `for ... in` probe I could write iterates over
  `utf8.codes(s)`, which `require`s `lib/utf8.nelua`. Nelu cannot load utf8 at
  all right now because utf8 uses `string` (and other over-reserved keywords)
  as identifiers, so the file fails at the keyword cascade before reaching the
  for-in. The for-in rejection is therefore masked by the keyword bug in that
  particular probe.

Because no oracle-accepted `for ... in` probe can be made to MATCH, the file
was removed rather than left as a false "still open" entry. The for-in gap is
now: A closed (parser+sema+lowering landed), C-gen still broken (B), and the
keyword over-reservation in utf8 is the separate blocker that prevents writing
a clean MATCH probe.

### 4.3 The 23 `keyword-*` files - gap CLOSED (were B, now MATCH)

The oracle permits exactly 26 type/annotation/declaration keywords as ordinary
identifiers (`local import = 42; print(import)`). Nelu rejected all of them with
`unexpected keyword '<name>'`. The fix is two-fold:

- `src/lexer.nim`: a new `IdentifierKeywords` const lists the 26, with an
  `isIdentKeyword` predicate.
- `src/parser.nim`: in `parsePrimary`'s `of tkKeyword: else` branch, a type
  keyword that is also an identifier keyword is accepted as a plain `newId`
  before the raise.

The 26 are: `cond`, `require`, `import`, `macro`, `record`, `union`, `enum`,
`varargs`, `varautos`, `varanys`, `cvarargs`, `any`, `auto`, `integer`,
`number`, `string`, `boolean`, `isize`, `usize`, `cchar`, `cshort`, `cint`,
`clong`, `cfloat`, `cdouble`, `void`, `type`. Every control-flow keyword
(`if`/`for`/`while`/`end`/`then`/...), literal (`true`/`false`/`nil`/`nilptr`)
and operator (`and`/`or`/`not`/`break`/`goto`/`continue`/`defer`) stays
reserved -- `local end = 7` is still "syntax error: expected an declaration
expression", matching the oracle.

All 23 corpus files now MATCH (`42` + 0). The three type keywords not covered
by a corpus file (`require`, `record`, `union`) were verified separately
against the oracle and behave identically.

This fix also unblocked `lib/utf8.nelua`, which uses `string` (and other
over-reserved keywords) as identifiers -- the root blocker behind the
`for-in-iterator` probe in 4.2.

### 4.4 `tdiv.nelua` / `tmod.nelua` / `asr.nelua` - gap CLOSED (were DIFF, now MATCH)

The truncate operators `///` (truncate division), `%%%` (truncate modulo) and
`>>>` (arithmetic shift right) were parsed and semantically typed but not
emitted. Three inseparable pieces landed together:

- `src/sema.nim` `inferBinary`: new `of "tdiv", "tmod", "asr"` case, integer-only.
- `src/analyzer.nim` `tryFoldBinary`: folding for all three (with a new
  `arithShr` helper that saturates at the bit width, since `>>>` is not C's
  UB shift-by-`>=64`).
- `src/cgen.nim` `genBinaryOp`: three new cases emitting runtime helpers
  `nltdiv` / `nltmod` / `nlasr` (C `/`, `%`, `>>`, which are exactly the
  truncate semantics).

All 13 operand-sign combinations MATCH, including edge cases `b = 0`, `b = 63`,
`b = 64`, `b = 100`. The operators are used for real in
`lib/detail/strconv.nelua` and `lib/string.nelua`.

### 4.5 `goto-label.nelua` - gap CLOSED (was NELU_REJECT, now MATCH)

The `::label::` goto-label fix landed via the parser-gaps agent's copy
(`tmp/2026-09-04-0157-parser-gaps/`).  `parseBlock` used to `break` on
`tkColonColon`, treating a label as a block terminator; the fix removes that
break so `parseStatement` (which already handles `::name::` and returns
`newLabel(name)`) receives it.  Five more parser fixes from that copy were
integrated onto the live tree as well, all gate-neutral:

- `isTypeKeyword` now recognises `auto`, `void`, `type`, `any` (was only the
  12 concrete primitive types).
- `parseType` builds a dot-index chain (`os.timedesc`, `primtypes.isize`)
  before the generic-instantiation check, so `facultative(os.timedesc)`
  parses its argument correctly.
- Function-type args accept an unnamed type argument (`function(*coro): void`),
  distinguished from a named `name: type` parameter by whether an identifier
  is immediately followed by `:`.
- `parsePreprocessName` scans forward for the matching `|#` and captures the
  raw Lua text between the delimiters, so `#|'a'..i|#` works after preceding
  tokens (was hardcoded to a single `tkIdent` at index 2).
- `parsePrimary` accepts type keywords as identifier values in any position
  (subsumed by the §4.3 keyword fix, which is strictly more general).

The sixth fix in that copy (type-keyword-as-value) was not applied: the live
tree already accepts type keywords as values via the `isIdentKeyword` branch,
which covers all 26 identifier keywords including every type keyword.

The remaining `lib/` cascade (`hash.nelua:73`, `iterators.nelua`, the whole
`allocators/` + `vector` + `hashmap` chain) is the pre-existing
"stdlib not reachable" gap -- a macro/preprocessor line-tracking bug whose
reported `73:51` location is bogus (line 73 is the 7-char `end`), not a parser
defect.  Out of scope for this corpus.

### 4.6 `fallthrough.nelua` - gap CLOSED (was NELU_CRASH, now MATCH)

The `fallthrough` keyword in `switch` was parsed as a bare `nkId` expression
statement, so `cgen` emitted `fallthrough;` -- an undeclared C identifier, which
is why the generated C failed to compile. The fix gives Nelu a real `nkFallthrough`
node kind (matching the reference, whose `--print-ast` emits `Fallthrough {}`)
and emits `__attribute__((fallthrough));` in C. Two inseparable pieces landed
together:

- `src/parser.nim` `parseStatement`: dispatch the `fallthrough` keyword to
  `newFallthrough()` before the `case` check; the `--print-ast` `dump` proc gains
  an `of nkFallthrough` branch (its `case` is exhaustive with no `else`, so it
  would not compile without one).
- `src/cgen.nim`: `genStmt` emits `__attribute__((fallthrough));`, and
  `bodyEndsInJump` now treats `nkFallthrough` as a jump -- without this,
  `genSwitch` emits a dead `break;` after a fallthrough-terminated case body,
  which would break out of the switch and suppress the fallthrough. The
  oracle's C backend does the same (its `Fallthrough` node carries
  `is_breakflow = true`, so it omits the trailing `break;`).
- `src/astshapes.nim` / `src/ast.nim` / `src/analyzer.nim`: the node kind, the
  `newFallthrough()` constructor, its empty layout, and a no-op
  `analyzeStmt` branch.

`fallthrough.nelua` now MATCHes the oracle (`one\ntwo`). Extra edge cases all
MATCH too: a plain switch with no fallthrough, chained fallthroughs
(`1`->`2`->`3`), and fallthrough into `else`/`default`. `python3 plan/cmp.py`
is still `1 diffs out of 40` and `python3 plan/regress.py` is still GREEN
(M2 14/14 MATCH; M1 25 MATCH / 3 DIFF / 0 CRASH) -- both unchanged from
baseline.

### 4.7 `sizeof-builtin.nelua` - gap CLOSED (was DIFF, now MATCH)

`#integer` / `#string` / `#usize` printed `nil` because the preprocessor's Lua
state had no `primtypes` reflection table, so the splice evaluated to nil.
The fix exposes `primtypes` (built from both `BuiltinTypes` and
`PrimitiveTypes`) with `size`, `align`, `bitsize`, `min`, `max`,
`mantdigits`, `decimaldigits`, and `is_convertible_from`; min/max are pushed
as Lua integers when the value fits int64 (exact arithmetic, overflow wraps
like Lua 5.4) and as floats otherwise. Four inseparable pieces landed together:

- `src/preprocessor.nim`: the `primtypes` table plus the `cTypeIndex` cases
  (`size`, `align`, `min`, `max`, ...) and the `cIsConvertibleFrom` callback.
- `src/luaengine.nim`: an FFI `lua_pushinteger` so `#integer`/`#usize` print
  `8`, not `8.0`.
- `src/analyzer.nim` `analyzeUnaryOp`: `#` now resolves its operand as a type
  expression first (`analyzeTypeExpr`), folding `size(type)` into a comptime
  value; the integer-result path converts to `isize` to match the oracle.
  Integer literals with magnitude >= 2^63 parse as float (the oracle is Lua
  5.4 `tonumber`, so `#[primtypes.isize.min]#` splices to a float literal and
  `print(-9223372036854775808)` yields `-9.2233720368548e+18`).
- `src/cgen.nim` `genUnaryOp`: comptime short-circuit for `#` -- emit the
  folded value directly instead of routing through `nllen()`.

`sizeof-builtin.nelua` now MATCHes the oracle (`8` / `16` / `8`), and
`#[primtypes.isize.min]#` == `-9.2233720368548e+18` exactly. `cmp` still
`1 diffs out of 40`, `regress` still GREEN (M2 14/14; M1 25 MATCH / 3 DIFF /
0 CRASH), `examples_parity` 2/5/3, www sweep 97 PASS / 2 DIFF -- all
unchanged from baseline. The remaining `require 'nelua.<module>'` item was
investigated and determined non-applicable: the oracle behaves identically
(looks for `.nelua` files; the `nelua` global is nil in both states).

### 4.8 The 9 metamethod / record / union / enum probes - gap CLOSED (all were NELU_CRASH, now MATCH)

The metamethods agent (`tmp/2026-09-04-METAMETHODS/`) closed the remaining
NELU_CRASH block in one pass. All nine now MATCH the oracle exactly:
`record-type` (`1 a`), `union-type` (`1`), `enum-type` (`0`),
`meta-binary-dispatch` (`3`), `meta-unary-dispatch` (`-5`), `meta-len`
(`42`), `meta-tostring` (`R`), `meta-call` (`6`), `meta-bnot` (`-6`).

The agent's copy was based on `d01c8a1` (pre-fallthrough) and touched only
two files. Integration onto the live tree (which already carries fallthrough,
multi-dim, and primtypes) was:

- `src/cgen.nim`: the agent's patch applied cleanly -- M5 binary metamethod
  dispatch in `genBinaryOp` (a record carrying `__add`/.../`__concat` routes
  through `genMetaCall`) and M5 unary dispatch in `genUnaryOp` (`__unm`,
  `__bnot`).
- `src/analyzer.nim`: the agent's patch did **not** apply cleanly -- the
  primtypes rewrite had restructured `analyzeUnaryOp`, so the M5-unary hunk's
  context no longer matched. All six analyzer hunks were applied manually at
  their now-correct anchors:
  - M5 binary result-type dispatch in `inferBinary` and M5 unary in
    `analyzeUnaryOp` (so `(a + b).v` resolves the field type instead of
    collapsing to `any`).
  - a `funcReturnType` field on the analyzer context, saved/restored around
    `analyzeFunc`'s body, so an init list in `return { ... }` inherits the
    function's return type rather than becoming an anonymous empty struct.
  - `analyzeReturn` routes `nkInitList` children through `analyzeInitList`
    with the enclosing return type.
  - a `local R: type = @record{...}` / `@enum(...){...}` type binding carries
    its concrete type on the symbol (and the C tag `<unit>_<binding>`), so a
    later `r: R` resolves to the record/enum Type instead of the opaque `type`
    metatype. This is what makes `record-type`/`union-type`/`enum-type`
    compile and run instead of failing in C emission.

`splice-ident.nelua` is the only remaining open gap in the corpus (1 of 43):
`#[x]#` splice of a variable reference still prints `nil` instead of `5`.

Gates after integration, all unchanged from baseline: `cmp` 1 diff/40,
`regress` GREEN (M2 14/14 MATCH; M1 25 MATCH / 3 DIFF / 0 CRASH),
`examples_parity` 2 MATCH / 5 DIFF / 3 SKIP, www sweep 97 PASS / 2 DIFF.

## 5. Findings that could not be turned into oracle-accepted probes

- **`in (expr)` as a standalone statement.** The gap doc lists this as a
  standalone A-ranked statement (`in (expr) do ... end`). In the oracle it is
  not standalone at all: a bare `in (expr)` only appears as the *body* of a
  `## local function NAME(args) ... ## end` macro definition. Every standalone
  attempt hit the oracle error "no do expression block found to use `in`
  statement" or a downstream cascade. It is covered bundled inside
  `macro-def.nelua`, which now MATCHes.
- **`__index` metamethod (M4).** Marked (d) in the gap doc. The oracle rejects
  `r.x` on a record with `__index` ("cannot index field 'x' on value of type
  'R'"), so no oracle-accepted probe could be written. Dropped.
- **`__gc`, `__close`, `__next`, `__pairs`, `__mpairs`, `__mnext`,
  `__convert`, `__atindex`.** Marked (d); the oracle requires specific method
  signatures that could not be nailed down. Dropped.
- **`static_assert` failure path.** Marked (d); the oracle rejects it by
  design ("static assertion failed"), so it cannot be an oracle-accepted
  coverage probe. Dropped.
- **`#name` named splice.** Marked (d); standalone probe syntax not nailed down
  for the oracle. Dropped.
- **`variant(...)` type form.** Nelu-only extension (verdict D); the oracle
  prints "not implemented yet". Intentional divergence, no probe written.
- **`goto` / `::label::`.** Included (`goto-label.nelua`) though the gap doc
  ranks it low and marks it A/B. The oracle accepts it; Nelu's `parseBlock`
  breaks on `::` ("expected 'end' to close function"). Smallest of the A-ranked
  probes, kept for completeness.

All scratch output for these probes lives in `/tmp/cov3/` (`<name>_o.txt`
oracle, `<name>_i.txt` Nelu, `results.tsv` summary). The corpus itself is at
`examples/cover/*.nelua` (43 files).