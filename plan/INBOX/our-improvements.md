# Improvements for Our Source (`src/`)

Grounded in `plan/observed-language-spec.md` (stage 1), cross-read against
`plan/oracle-language-spec.md` (stage 3), and merged against
`plan/DONE/devil-advocate-findings.md` (17 empirical, both-compilers-verified
divergences; this revision, stage 4). Every recommendation cites the gap it
addresses. Each is labelled **BUG** (fix it), **COMPLETE** (finish a deferred
feature), **REFACTOR** (internal cleanup), **DESIGN** (deliberate -- leave it,
with reasoning), **STRATEGIC** (consider, effort is large), or **VERIFY**
(measure before acting).

Prioritization criteria, in order: (1) impact on real Nelua programs in the
corpus; (2) concreteness -- can it be done in a bounded, low-risk change;
(3) whether it unblocks other work. Items that score high on all three are at
the top.

---

## 0. How to read the priority order

The document is ordered by the criteria above, not by alphabetical or file
order. Within each tier, items are roughly ordered most-impactful first.
A summary table with exact ranks is in Section 7.

## 0.3 Stage 4 revision (devil-advocate merge) -- READ FIRST

This is the second stage-4 revision. The first (marked `[S4-*]` below) folded
in the oracle spec's architecture insights. This one folds in the 17 confirmed
divergences from `plan/DONE/devil-advocate-findings.md` and re-orders the whole list
against the merged priority: **oracle-stdlib blockers first, then crashes and
wrong-output on common idioms, then single-construct C-emission quirks.**

**Three things the oracle cross-read changed about our list, beyond ranking:**

1. **Our stage-2 list was blind to 15 of the 17 confirmed divergences.** It
   ranked compiler-internal robustness (emitter segfaults, `genForIn`, the
   undeclared-symbol diagnostic, enum emission, the `T?` stub, preprocessor
   wiring, `cond`, `nogc`, annotations, the Lua backend) and said nothing about
   the constructs the oracle's *own* stdlib actually uses. Until this revision
   the list would have had us optimise the compiler while the oracle's
   `lib/string.nelua`, `lib/stringbuilder.nelua`, `lib/allocators/heap.nelua`,
   `lib/builtins.nelua`, and `examples/brainfuck.nelua` could not be parsed by
   our compiler at all. That is the ordering error this revision fixes.

2. **Two of our items were framed as choices the oracle has already settled,
   and in the opposite direction from us.** Our `T?` item (old 1.5) asked
   "implement it or delete it"; the oracle *rejects* `T?` with `unexpected
   syntax` (verified: `local x: integer? = 42` and `function f(x: integer?)`
   both fail). Our `cond` item (old 2.2) asked "implement it or remove it";
   the oracle has **no `cond` at all** -- it rejects `cond` and its AST node
   table (oracle section 2.2.2) contains `Switch` but no `Cond` node. Both are
   **not parity targets**: the oracle never runs a program using them, so there
   is no working code to match. They are re-framed in 3.9 / 6.1 as
   Nelu-extension-or-drop candidates. (See the parity/extension rule in
   `post-reimpl-continue-nelu.md`: we want working code to work and are not
   interested in failing code failing the same.)
   They are re-framed below as "make it reject, matching the oracle."

3. **The live `src/` tree has since committed the edits the devil-advocate
   snapshot was taken against.** Since the devil-advocate ran (22:42 / 22:57
   snapshot), the P1 / N4 / N5 parses, the parsing half of N6, and the
   partial C1 nil-guard have all landed, along with the cgen parity fixes
   (array `==`/`!=`, `#cstring`, `#array`, `$` -> `"deref"`, nested-record
   constructor array-field init, method-call arg indexing) and the long-bracket
   `##[=[ ... ]=]` block parse -- **all committed at `f75601a`**, plus
   `69098c3`, `ed503c1`, `6a04582`, `bab3eb3`, `dd291fc` and `689a2f7`.
   **Section 1 records which findings are already done so the plan is not
   re-ranked against work that is already landed.** Findings verified
   still-open are probed against a fresh `nim c -d:release` build of the
   committed tree; both agree.

**The single most important stage-4 insight:** the takeover is blocked not by
C-emission quirks but by *parse/lexer gaps in the oracle's own stdlib*. `goto`
appears in five oracle-stdlib files; without it, "take over Nelua" is not
credible for any program doing explicit control flow. That item was absent
from our stage-2 list entirely and is now rank 1.

---

## 0.4 Stage 4 revision (oracle-quirks cross-read) -- READ SECOND

This is a second stage-4 feed, this time from Professor B's oracle-quirks
cross-read (`plan/INBOX/oracle-improvements.md`, stage 3-4 revision). Professor B
identified 15 concrete issues in the oracle's `lualib/` source and cross-read
each against this document's stage-1 spec of our source. The cross-read
produced three findings, recorded here because they affect how this worklist
is read.

**Finding 1: most oracle-internal quirks are not takeover-relevant.**
Of the 15 oracle issues, 9 are oracle-internal mechanisms our source does not
have (typedecldepth/latedecls, ensure_builtin, pseudo-arguments, the `done`
optimization, config.define interleaving, the reserverd_keywords typo, and/or
dead code, the emit_nelua_main position heuristic, KeyIndex/InitList node
tags). Our reimplementation does not have these mechanisms, so we cannot
reproduce the quirks, and the quirks cannot affect parity because our codegen
never emits the affected C. They are a map of the oracle's internal
architecture -- useful for understanding what the oracle does behind the
scenes -- but they are NOT a to-reproduce list. This confirms the existing
priority: oracle-stdlib blockers first, compiler-internal robustness later.

**Finding 2: two oracle rejections are Nelu extensions, not parity targets.**
The oracle rejects closures/upvalues (`analyzer.lua:672`) and multiple returns
in main (`cgenerator.lua:801`). Our source accepts both (closures are landed
per 2.5; multi-return lowering is documented in 6.5/5.5). Under the
parity/extension rule these are not targets: the oracle never runs a program
using them, so there is no working code to match. They are already recorded
as deliberate divergences (2.5, 5.5). No re-ordering needed.

**Finding 3: three items are VERIFY, not FIX.**
The cross-read identified three takeover-relevant items that are
verification targets, not bounded fixes:
- **P1.3 -- table literal side effects.** The oracle does not track side
  effects in table constructors (`analyzer.lua:429`, `-- TODO: check side
  effects?`). Our analyzer records `sideeffect` on `DumpInfo` (5.2) but the
  observed spec does not state whether table-literal elements are covered.
  If our analyzer tracks MORE side effects than the oracle, code that relies
  on side-effect ordering in table constructors may behave differently.
  VERIFY against the corpus.
- **P2.4 -- emit_nelua_main heuristic.** The oracle detects whether statements
  were added by comparing `emitter:get_pos()` before and after
  (`cgenerator.lua:1550-1565`). Our `nelua_main` driver (6.4) uses a different,
  undocumented mechanism. If our mechanism produces false negatives (reports
  "no statements" when there are zero-length outputs), the emitted C may
  differ from the oracle's. VERIFY against the corpus.
- **P3.1 -- KeyIndex/InitList node mapping.** The oracle's AST node tags
  (`KeyIndex`, `InitList`) do not map 1:1 to our `NodeKind` enum. If the
  oracle's stdlib uses constructs that the oracle maps to `KeyIndex`/`InitList`
  but we map to different nodes (e.g. our `nkDotIndex`), the codegen paths
  diverge. VERIFY against the corpus.

These three are added to the ranked summary as VERIFY items (see 7, items
33-35). They are measurement items: run the corpus, look for divergences, and
only then decide whether a fix is needed. Per the user's standing instruction
to measure before tuning, do not act on them without corpus evidence.

**What the cross-read did NOT change.** The existing priority ordering is
correct. The oracle-quirks cross-read confirms that the takeover is blocked
by parse/lexer gaps in the oracle's own stdlib (Tier A), not by the oracle's
internal quirks. The three VERIFY items above are the only new entries; they
are low-priority measurement items, not blockers. No existing item is
de-ranked or re-framed by this cross-read.

---

## 1. Tier A -- parser/lexer gaps that block the oracle's OWN stdlib

These are the takeover blockers. Every one is a construct the oracle's stdlib
uses that our compiler cannot parse or lex. Fixing them is the difference
between "our compiler can compile hello world" and "our compiler can compile
the oracle's standard library."

### 1.1 BUG -- `goto` + `::label:` cannot appear as a statement (N1)

**Status: CLOSED -- fixed.** `goto` + `::label:` are now statements: block-scoped
label scope stack in `analyzer.nim`, `labelTarget` attr + shared C codename in
`cgen.nim`. Verified: probe_goto/probe_goto2/pt_dup/pt_edge MATCH the oracle;
harness `exam/goto_loop` went DIFF -> MATCH. Ticket: `plan/DONE/goto-label-statement.md`.

**Grounding.** The oracle's AST has `Label` and `Goto` nodes (oracle section
2.2.2), and its scope manages labels via `find_label`/`add_label` (oracle
section 5.4). Our `astshapes.nim` already declares `nkLabel` (line 64) and
`nkGoto` (line 65), and `parser.nim`'s `parseStatement` already handles the
`goto` keyword and the `::name::` token (`tkColonColon` -> `newLabel`). So
the node kinds and the keyword are *not* the gap.

**Root cause (precise).** `parseBlock` and `parseSwitchBlock` both `break` as
soon as they see `tkColonColon`:

```
src/parser.nim:603   if t.kind == tkColonColon: break      # parseBlock
src/parser.nim:631   if t.kind == tkColonColon: break      # parseSwitchBlock
```

A label is therefore never reachable as a statement: the block parser exits
before `parseStatement` is ever called, and the `::done::` token is left
overrunning the program. The fix is to remove those two `break` lines (labels
are scope-managed by the analyzer, which already has the machinery) and let
`parseStatement`'s existing `tkColonColon` branch handle them. Two-line change.

**Why it is rank 1.** `goto` is in the oracle's own `lib/stringbuilder.nelua`
(7 `goto next`), `lib/string.nelua` (`goto next`),
`lib/allocators/heap.nelua` (2x `goto found_free_node`),
`examples/brainfuck.nelua` (`goto #|target.after|#` splice labels), and
`examples/overview.nelua` (`goto getout`). All five fail to parse in our
compiler purely because of this. This is the single construct in the most
oracle-stdlib files with no workaround.

**Do not do:** do not add `nkGoto`/`nkLabel` to the AST -- they already exist.
Do not add `goto`/`::` to the keyword table -- they are already there. The
block parser is the only thing standing in the way.

### 1.2 BUG -- byte literal `'A'_b` suffix is not lexed (N2)

**Status: CLOSED -- fixed.** `'A'_b`/`"x"_u8`/`'A'_i8` lower to the char's ordinal
as uint8/int8 via the `nkString` case in `analyzer.nim` and the value emission
in `cgen.nim` (the parser already folded the suffix). Verified: `print('A'_b)`
-> 65, switch case values MATCH. Ticket: `plan/DONE/byte-literal-suffix.md`.

**Grounding.** The oracle's `typedefs.string_literals_types` maps suffix strings
to types including the byte literal (oracle section 3.4). Byte literals are used
in `lib/string.nelua` (`case 'X'_b then`) and `lib/allocators/heap.nelua`.

**Root cause (precise).** `src/lexer.nim`'s `lexString` handles a single-quoted
char literal identically to a double-quoted string and returns at the closing
quote. The numeric-suffix scanner (`lexer.nim:105-110`) only runs *inside*
`lexNumber`, so the `_b` that follows a char literal is lexed as a separate
`tkIdentifier`. The number-suffix path (`200_u8`, `0xFF_u8`) is unaffected and
matches the oracle -- only the char-literal `_b` form is missing.

**Recommended fix.** In the lexer, after a single-quoted char literal, scan an
optional `_<suffix>` where the suffix table includes `_b` -> `byte`. Bounded,
localised to one lexer helper. Also handle `'A'_b` inside `switch` case labels
(the parser's `case` production must accept a suffixed char literal as a case
value).

### 1.3 COMPLETE -- colon method on a type-keyword receiver is now parsed (P1)

**Status: DONE, committed `f75601a`.** `lib/string.nelua`
line 46 (`function string:destroy(): void`) previously failed with
`expected ')' after function parameters`. `src/parser.nim` adds
`isTypeKeyword` and accepts a type keyword as a static-method receiver when
immediately followed by `.` (`parsePrimary`, and `parseFuncName` chains it).
This unblocks `lib/string.nelua` (it now parses past line 46; it dies later
at line 940, the already-documented `#|argname|#` name-splice gap). **Keep as
COMPLETE; do not re-litigate.** End-to-end: parse landed, compilation of the
whole module still pending the name-splice gap.

### 1.4 COMPLETE -- `facultative(string)` type-function-call is now parsed (N4)

**Status: DONE, committed `f75601a`; end-to-end still pending.** `lib/builtins.nelua`
(`function assert(v: auto, message: facultative(string))` and `function
check(cond: boolean, message: facultative(string))`) previously failed with
`expected ')' after function parameters`. `src/parser.nim` `parseType`
now accepts a bare type identifier followed by `(...)` and builds an
`nkGenericType` node (`astshapes.nim:121` already has the shape). This
unblocks `lib/builtins.nelua`. **Keep as COMPLETE; do not re-litigate.**
Verification item: confirm `facultative(string)` resolves through the analyzer
to an optional/nullable string, not just parses -- still open.

### 1.5 COMPLETE -- typed `for` with exclusive `<` upper bound is now parsed (N5)

**Status: DONE, committed `f75601a`; MATCHes the oracle end-to-end.** `heap.nelua`
(`for i:uint32=0,<BIN_MAX_LOOKUPS do`) previously failed with
`expected 'in' in for`. `src/parser.nim` `parseFor` now parses the loop
variable as an `IdDecl` (preserving the `:type` annotation) and accepts a bare
`<expr>` exclusive upper bound, matching the oracle's `ForNum { iddecl, start,
comp, limit, step?, Block }` shape (oracle section 2.2.2, the `comp` field).
**Keep as COMPLETE; do not re-litigate.** Verified end-to-end: the exclusive
bound lowers to `i < N` (not `i <= N`) and the typed variable is emitted with
its declared width; MATCHes the oracle (`10`, exit 0).

---

## 2. Tier B -- crashes and wrong-output on common idioms

### 2.1 BUG -- `self.x = self.x * s` (binary-op RHS on a self-field lvalue) SIGSEGVs (C1)

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `local R
= @record{ x: integer }; local r: R = { x = 5 }; r.x = r.x * 2; print(r.x)`
prints `10` on both compilers (MATCH). The live tree's nil-guards in
`analyzeDotIndex`/`cgen` already cover this path. Ticket
`plan/DONE/self-field-assign-sigsegv.md` (CLOSED, recorded as not-reproducing).

**Grounding.** This is the exact pattern in `examples/www/recmethod_mutate.nelua`,
which also SIGSEGVs. Narrowed: `self.x = -self.x` (unary RHS) matches; only the
binary RHS crashes. Plain local `x = x * 2` matches.

**Root cause (precise).** `analyzeAssign` (`src/analyzer.nim:1844`) handles
`nkId` targets but sends `nkDotIndex`/`nkIndex` targets (like `self.x`) to the
generic `analyzeExpr(ctx, t)` path. When the RHS is a binary op, type inference
for the indexed LHS returns nil and a later deref segfaults.

**Partial fix already landed.** The live `src/analyzer.nim` `analyzeCall` adds
a nil-guard for the `nkDotIndex` *caller* branch (`if calleeType != nil and
calleeType.returns.len >= 1`), which stops the static-method-call crash. That
is a *different* path from the assignment path in `analyzeAssign` and does not
fix C1.

**Recommended fix.** One-line guard around the `calleeType`/operand-type deref
in `analyzeAssign`, mirroring the guard just landed in `analyzeCall`. Also make
the print-AST paths degrade gracefully instead of crashing (see 6.1).

### 2.2 BUG -- small-uint arithmetic does not wrap (W2)

**Status: FIXED 2026-09-06** (ticket `plan/DONE/uint-wrap.md`).  The text below
was the *inverted* understanding and has been corrected there; the recommended
fix below was the wrong direction.

**Corrected grounding.** The oracle does **not** wrap small-uint arithmetic:
it promotes in expression context (`print(200_u8 + 100_u8)` -> `300`) and
rejects an out-of-range comptime constant at assignment time
(`local b: uint8 = 200 + 100` errors).  Nelu wrapped to the declared width
(`44 = 300 mod 256`).

**Fix that landed.** Remove the wrap-to-width step (the W2 cast in the print
dispatch in `src/cgen.nim`) so the widened `int64` result is emitted as-is, and
add `checkIntRange` in `src/analyzer.nim` (called from `analyzeVarDecl`) to
emit the oracle's out-of-range diagnostic for assignment of a comptime integer
constant to a fixed-width integral type.  Verified: harness 0 regressions
(307 baseline), exam probes `uintwrap_promote`/`neg_uintwrap_range`/
`neg_uintwrap_range2` MATCH.

### 2.3 BUG -- `float32` print drops the `.0` suffix on integral values (W1)

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `local x:
float32 = 75.0; print(x)` prints `75.0` on both compilers (MATCH); `1.5` MATCH.
Ticket `plan/DONE/float32-print-suffix.md` (CLOSED as already-fixed).

**Root cause (precise).** The inline `nelua_print_float` in `src/cgen.nim:180-184`
does `snprintf(buf, "%.7g", v)` with no `.0` suffix pass. `nelua_print_double`
in `src/runtime.c:142-155` has the suffix logic (`strchr(buf,'.')==NULL` ->
append `.0`, skipping inf/nan) but the float32 helper was written without it.

**Recommended fix.** Copy the suffix logic from `nelua_print_double` into
`nelua_print_float`. One-line change mirroring existing code.

### 2.4 COMPLETE / BUG -- `##` Lua statement blocks are not run by the compile driver (W3, N6)

**Status: DRIVER WIRING ALREADY FIXED -- re-measured 2026-09-06, no code change.**
`## x = 7` + `print(#[x]#)` prints `7` on both compilers (MATCH). The seam
described below landed: `analyze` (`src/analyzer.nim:2465-2477`) now runs
`preprocess(ast, pctx)` over the parse tree right after `parse`, so every
pipeline -- including the default `compile` driver -- inherits preprocessing.
`src/compile.nim:10-16`'s comment still says the opposite and is stale (see
4.2). The remaining open preprocessor item is the `#|expr|#` *name* splice
(`plan/INBOX/preprocess-name-splice.md`, STILL OPEN), which is a different node
(`PreprocessName`) from the `#[expr]#` expression splice that works.

**Grounding.** `compile.nim:10-16` documents backlog item C3: the preprocessor
is built and tested through `runM6Pipeline` but is **not** run by the default
compile path. `examples/www/splice_embed.nelua` DIFFs identically, and
`examples/brainfuck.nelua` (which uses `##[=[ ... ]=]` for its source string)
cannot run correctly.

**What is already fixed in the live tree (committed `f75601a`).** The long-bracket form
`##[=[ ... ]=]` is now parsed: `parser.nim` `stripLongBrackets` + `parsePreprocess`
flags a self-contained block (`boolVal = true`), and `preprocessor.nim` runs it
as a standalone chunk instead of subjecting it to `luaBlockDelta` framing.
That is the *parsing* half. The *driver* half is unchanged -- W3 (`##` driver
wiring) is still queued.

**Root cause (precise).** `compile.nim:10-16`. Only the analyze/print-ppcode
paths run the preprocessor; a normal `nelua file.nelua` never invokes it.

**Recommended fix.** Wire the existing preprocessor into the `analyze` entry
point right after `parse`, exactly as our own backlog note
(`NOTE_backlog.md`) already specifies. One-call integration. Do not
replicate the oracle's gradual, scope-aware, hygienic architecture (see the
`[S4-8]` note below) -- our separate-pass preprocessor is a legitimate,
simpler design. The honest, documented limitation is that our `##` blocks can
only use the registered builtins and the seeded `primtypes`/`typedefs`
globals; they cannot read source-level variables or inferred types, unlike
the oracle (`ppcontext.lua:48`). Document that gap explicitly.

### 2.5 BUG -- the C emitter SIGSEGVs on anonymous functions, method calls, and if/elseif chains (old 1.1)

**Status: FIXED 2026-09-06** (ticket `plan/DONE/function-literal-as-value.md`).
All three constructs now MATCH the oracle: method calls (`cf:flip()` -> `true`),
if/elseif chains (`-> 2`), and anonymous functions bound to a local
(`local f = function(x: integer): integer return x + 1 end; print(f(41))`
-> `42`).  The named-function statement form (`local function f() ... end`)
was already MATCH; this ticket adds the value form.

**Known limitation (out of scope):** reassignment of a function literal
(`f = function() end`) still fails at C gen -- the literal in assignment
position keeps `nkFunction` kind and `genExpr` returns the `/*?nkFunction*/`
placeholder.  That is the general function-value/closure feature
(`plan/INBOX/closures-upvalues.md`), not the bounded case here.

**Grounding.** Method calls and anonymous functions are core to the
closures/upvalues work already landed in this tree. An emitter that segfaults
on them means a large fraction of the corpus cannot be compiled to a binary,
and the print-AST paths never validate the analyzer against actual emission.

**Oracle cross-read.** The oracle's C generator is a visitor table
(`cgenerator.visitors`, oracle section 6.1.3) that handles all statement and
expression nodes without crashing. This confirms the constructs are emittable
and ours has a genuine bug.

**Recommended fix.** Two parts, in order of risk:
- (a) Make the print-AST paths degrade gracefully: catch the segfault path and
  emit a diagnostic instead of crashing. Cheap; immediately stops corrupting
  the terminal.
- (b) Fix `genC` for the three named constructs. Method calls lower to
  `nkDotIndex` + `nkCall`; anonymous functions lower to `nkFuncDef` in
  expression position; if/elseif lowers to nested `nkIf`. Each is a bounded
  change in `cgen.nim`'s `genExpr`/`genCall`/`genStmt` dispatch. Start with
  if/elseif (pure structural), then method calls (the `self` parameter is
  already injected by `analyzeFuncDef`), then closures (the upvalue
  environment is already landed).

**Do not do:** do not remove the print-AST paths or the `needsCompile` flag
until (b) is done; they are the canary that keeps the analyzer/emitter gap
visible.

### 2.6 BUG -- `genForIn` supports only a single array iterable (old 1.2)

**Status: STILL OPEN.** Multi-value `for k, v in array` and multi-value
tuple iterables are not supported.

**Why it is a bug.** `for k, v in array` is the idiomatic way to iterate an
array with index and value. Its absence forces manual index loops.

**Recommended fix.** Extend `genForIn` to handle the two-variable form for
array iterables: emit a standard C index loop
(`for (int64_t _i = 0; _i < n; _i++) { k = _i; v = arr[_i]; ... }`). The
analyzer already attaches the iterable type; the change is localised to one
proc. Multi-value tuple iterables (`for a, b in pairs(...)`) are a separate,
larger feature -- defer those.

### 2.7 BUG -- unknown identifiers resolve silently to `any`-typed externs with no diagnostic (old 1.3)

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `print(undefned_symbol)` now emits `error: undeclared symbol 'undefned_symbol'` on both compilers (MATCH), so the silent-`any`-extern fallthrough is gone. Ticket `plan/DONE/three-declaration-divergences.md` (CLOSED).

**Grounding.** Identifiers not found in scope fall through to a hardcoded
`builtinNames` list and are treated as `skBuiltin` with codename
`nelua_<name>`. Identifiers not on that list are silently treated as `any`-typed
externals. A typo (`undefned`) compiles without complaint and becomes an
external C symbol.

**Oracle cross-read `[S4-3]`.** The oracle's root scope lazily creates builtin
symbols from a data table, `typedefs.builtin_attrs` (`scope.lua`), and primtype
symbols from `primtypes` (oracle section 5.4). The global environment is a
*model*, not a hardcoded literal. The oracle also maintains
`typedefs.symbol_modules` mapping builtin names to source modules for
error-message suggestions.

**Recommended fix.** Two parts:
- (a) Make the global environment data-driven: move `builtinNames` into a
  table in `types.nim` with each entry's codename, signature, and side-effect
  property. Pure refactor, zero behavioural change. Mirror the oracle's
  `builtin_attrs` structure.
- (b) Add a diagnostic for identifiers that resolve to neither a scope symbol
  nor an entry in the global table. **Caveat:** this may be a deliberate
  emulation of Lua, where an undeclared identifier is a global lookup that is
  `nil` at runtime. If the corpus relies on that behaviour, make the diagnostic
  opt-in via a config flag (`strictGlobals`) rather than unconditional.

**Do not do:** do not make it unconditional without checking the corpus first.

---

## 3. Tier C -- single-construct C-emission quirks

These are individual-construct blockers, whereas Tier A/B block whole stdlib
files or common idioms. The C path IS the runtime path (Nim emits C, and we
emit C via gcc), so a C-emission quirk is a real parity blocker too -- it just
touches fewer programs.

### 3.1 BUG -- `cstring` locals cannot be assigned a string literal (C2)

**Status: DONE, committed `f75601a`.** Verified: ours now emits
`d6_cstring_s = nlstr("hello")` (the `#cstring` length wraps the cstring in
`nlstr(...)`, so a `const char*` is not an `nlstring`) and the print dispatch
matches the oracle. See the `www_cstring_type.nelua` probe.

**Grounding.** `cstring` is a first-class type used throughout `lib/`
(e.g. `lib/string.nelua` documents cstring compatibility).

**Root cause (precise).** `cstring` spells `const char*` in C
(`cgen_types.nim:119`), but the emitter wraps the string literal in `nlstr(...)`
(which yields an `nlstring` struct) and casts it to `const char*`. The cast is
invalid, and the print dispatch (`cgen.nim`, `of tkString, tkCstring: helper =
"nelua_print_string"`) picks `nelua_print_string`, which wants `nlstring`, not
a cstring-aware path.

**Recommended fix.** Either (a) make `cstring` assignment emit a plain
`const char*` literal with no `nlstr` wrap, or (b) add a cstring-aware print
helper. Option (a) is the smaller change and matches the oracle, which treats
`cstring` as `char*` (oracle section 6.2).

### 3.2 BUG -- `@union` field access and print is broken (C3)

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `local U =
@union{ a: float32, i: uint32 }; local u: U; u.a = 1.5; print(u.a)` prints
`1.5` on both compilers (MATCH). Ticket `plan/DONE/union-field-access.md`
(CLOSED as already-fixed).

**Grounding.** Unions are a core language feature.

**Root cause (precise).** The union *typedef* emission is correct: `cgen.nim`
emits `typedef union <tag> { cDecl(f.typ, f.name); ... } <tag>;` using each
field's declared type, and `analyzer.nim`'s `nkUnionType` handler preserves the
field type. The gap is in **field access**: `analyzeDotIndex`
(`src/analyzer.nim`, ~717-755) handles `tkRecord` and `tkEnum` receivers but has
**no `tkUnion` branch**, so a union field's `attr.typ` falls through to
`BuiltinTypes["any"]`. The `any`-typed attr then drives the `nlany_from_*` wrap
and the `nelua_print_any` dispatch.

**Recommended fix.** Add a `tkUnion` branch to `analyzeDotIndex` mirroring the
`tkRecord` branch: look up `node.str` in `rt.fields` and set `a.typ = f.typ`.
Bounded, one-branch change. This is the same pattern the record branch already
uses correctly.

### 3.3 BUG -- `<comptime>` on a string global/local evaluates the string as a number (N3)

**Status: STILL OPEN.** Verified: `global _VERSION: string <comptime> = "1.0"`
emits `nelua_print_string(1.0)` in ours; oracle prints `1.0`.

**Grounding.** Used in `lib/builtins.nelua` (`global _VERSION: string <comptime>`),
`lib/utf8.nelua`, and `lib/stringbuilder.nelua`
(`local L_FMTFLAGS: string <comptime> = "-+ #0"`). `lib/stringbuilder.nelua`
fails at this line in ours.

**Root cause (precise).** The `<comptime>` codegen path evaluates the
initializer at compile time and for a `string` runs the value through the
numeric comptime evaluator instead of keeping it as a string literal
(`cgen.nim` `genVarDecl` comptime handling, ~542-560 and ~1257).

**Recommended fix.** In the comptime evaluation path, branch on the declared
type: if the target is `string`, keep the literal as an `nlstring` (do not run
it through `numberTypeAndValue`). Localised to the comptime fold in
`genVarDecl` / the analyzer's comptime folding.

### 3.4 BUG -- `likely()` / `unlikely()` builtins are not lowered to C (N7)

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `if
likely(true) then x = 1 end; if unlikely(false) then x = 2 end; print(x)`
prints `1` on both compilers (MATCH); they lower to `__builtin_expect` in
`src/cgen.nim`. Ticket `plan/DONE/likely-unlikely-lowering.md` (CLOSED).

**Grounding.** Used in `lib/allocators/heap.nelua`
(`if unlikely(...) then ... return nilptr end`).

**Root cause (precise).** `likely`/`unlikely` are recognized by the analyzer but
the C emitter does not map them to `__builtin_expect` (or include the builtin
header); it emits them as plain calls. The oracle defines `NELUA_LIKELY` /
`NELUA_UNLIKELY` macros in `cbuiltins.lua` (oracle section 7.2).

**Recommended fix.** In the C emitter's call-lowering, map `likely`/`unlikely`
to `__builtin_expect(arg, 1)` / `__builtin_expect(arg, 0)` (or to the
`NELUA_LIKELY`/`NELUA_UNLIKELY` macros from `runtime.c`). Bounded, one
dispatch entry.

### 3.5 BUG -- `...: cvarargs` in a cimport function emits invalid C (N8)

**Status: STILL OPEN.** Verified: ours emits a stray `___` token where the
cvarargs parameter should be; oracle prints `declared`.

**Grounding.** Used in `lib/stringbuilder.nelua`
(`local function snprintf(...: cvarargs): cint <...>` and
`quadmath_snprintf(...: cvarargs)`).

**Root cause (precise).** The C emitter does not translate `cvarargs` parameters
to the C `...`/`va_list` form correctly. `cgen_types.nim:123` already spells
`tkCvarargs` as `"..."` in value position, but the function-parameter
translation path is incomplete.

**Recommended fix.** In the C function-parameter emission, emit a bare `...` for
a `cvarargs` parameter (matching `cgen_types.cType`) and ensure the function
type's C spelling is `ret name(...)` rather than trying to name the parameter.
Localised to the parameter-list emission proc.

### 3.6 BUG -- dotted `global X.Y` declarations emit syntactically invalid C (C4)

**Status: STILL OPEN for the C-emission half; the parse half is DONE in the
live tree.** Verified: ours emits `static int64_t h1_dotted_Rect.field;` and
gcc chokes on the `.`. The oracle also rejects the bare form
(`undeclared symbol 'Rect'`), so the clean finding is "ours accepts and emits
invalid C", not a runtime divergence.

**What is already fixed (committed `f75601a`).** `src/parser.nim` `parseIdDecl`
now builds a dot-index chain for dotted declaration names and records the full
dotted string on the node. So parsing `global Rect.field: integer = 5` now
succeeds. The C-emission half (sanitize `.` in the global-decl codename, or
emit a diagnostic matching the oracle) is still open.

**Root cause (precise).** `cemitter.cIdent` sanitizes identifiers but the
global-declaration codename path does not sanitize `.` in dotted names; the
emitted C keeps the literal `.`.

**Recommended fix.** Sanitize `.` (and any other non-identifier character) to
`_` when emitting a global-decl codename, reusing `cIdent`'s logic. Bounded.
Also decide the semantic question: since the oracle rejects the bare form, the
parity-consistent behaviour is to reject `global X.Y` too -- emit a diagnostic
rather than accepting and lowering it. Either path is bounded; the diagnostic
path matches the oracle.

### 3.7 BUG -- `check(false, msg)` omits the source location from the message (W4)

**Status: STILL OPEN (cosmetic).** Verified: oracle prints
`d4_check.nelua:1:7: runtime error: should fail` plus a source line and caret;
ours prints only `runtime error: should fail`. Both abort with exit 134.

**Root cause (precise).** The runtime error path in our driver does not prepend
the source location the way the oracle's does.

**Recommended fix.** Prepend `path:line:col:` to the runtime error message in
the driver's error path, reusing the existing `render` machinery in
`errors.nim`. One-line change.

### 3.8 BUG -- enum fields are folded to constants but no C `enum` is emitted (old 1.4) `[S4-2]`

**Status: ALREADY FIXED -- re-measured 2026-09-06, no code change.** `local E:
type = @enum{ Red = 0, Green = 1, Blue = 2 }; local v: E = E.Green; print(v)`
prints `1` on both compilers (MATCH); a real C `enum` is now emitted. Ticket
`plan/DONE/enum-c-emission.md` (CLOSED as already-fixed).

**Oracle cross-read.** The oracle's `EnumType` typevisitor (oracle section 6.1.2)
emits `typedef enum codename { fields; } codename;` -- a real C enum with its
fields. High-confidence BUG, not a design divergence.

**Recommended fix.** Emit a real C `enum` typedef in the typedefs section:
`typedef enum { nlcolor_Red = 0, nlcolor_Green = 1, ... } nlcolor;` (or
`typedef <underlying> nlcolor; typedef enum { ... } nlcolor;` if the underlying
is not `int`). The analyzer already has the field list and values; the change
is localised to the typedef-emission proc. This unblocks type-safe `switch`.

**Do not do:** do not change the on-storage size or alignment.

### 3.9 BUG -- `T?` optional-type syntax is accepted by us but rejected by the oracle (old 1.5)

**Status: NOT A PARITY TARGET.** Verified: the oracle rejects `local x: integer?
= 42` and `function f(x: integer?): integer` with `unexpected syntax`. Because
the oracle never *runs* a program using `T?`, there is no working code whose
behaviour we must match -- this is not a takeover blocker. Our
`parseOptionalType` (`src/parser.nim:259`) accepts it and discards it, so if we
keep it we silently accept what the oracle rejects. That is fine under the
parity/extension rule, but only if we are deliberate about it: silently dropping
the `?` means a program that *expects* optional semantics gets plain `T`
instead, which is confusing even though it is not a parity failure.

**Grounding.** Our `optionalType` exists in `types.nim` and spells
`nlopt_<subtype>` in C, and `nilptr` promotes to optional in `sema` -- so the
machinery is real, but only reachable internally. The oracle's AST also has an
`OptionalType` node (oracle section 2.2.2), but its grammar does **not** accept
`T?` (verified above); the node exists for internal `nilptr`-promotion use,
exactly like ours.

**Recommended fix.** Pick one, deliberately -- this is a Nelu design choice,
not a reconciliation with the oracle:
- (a) **Implement it as a live Nelu type expression.** Wire `T?` through
  `resolveTypeExpr` and `cType` so it actually means optional. This is the
  Nelu-extension choice: territory the dead language does not permit, added as
  sugar over the existing backend. Larger change.
- (b) **Drop it.** Remove the `?` production from `parseType` / `parseOptionalType`
  so it is a parse error. Bounded. Chosen if optional types are not wanted.
- (c) **Leave it accepted-but-inert.** Acceptable only if nobody relies on it;
  the silent drop is the risk. Lowest effort, clearest to leave as a known wart.

Do **not** frame this as "make it a parse error to match the oracle" -- the
oracle's rejection is not a target.

Do not leave the stub. If the choice is (a), that is a legitimate design
decision -- but it must be a decision, not an accident.

---

## 4. Structural / code-quality improvements

These do not change the language and do not change user-visible behaviour on
valid input. Lower priority than Sections 1-3, but concrete and low-risk.

### 4.1 REFACTOR -- make the global environment data-driven (see 2.7a) `[S4-3]`

Move `builtinNames` from a hardcoded literal in `analyzer.nim` into a table in
`types.nim` with codename, signature, and side-effect metadata. Zero
behavioural change; makes the list maintainable and makes the strict-globals
diagnostic (2.7b) implementable. Mirror the oracle's `typedefs.builtin_attrs`
structure (oracle section 5.4). Optionally add a `symbol_modules`-style table
mapping builtin names to source modules for error-message suggestions.

### 4.2 REFACTOR -- resolve the `runtime.c` divergence

**Grounding.** The `cgen.nim` preamble comment says `src/runtime.c` is "a
later milestone", but `compile.nim:182` actually links `runtime.c` at compile
time.

**Recommended fix.** Align the comment with the behaviour (or vice versa).
Trivial, but it is a live divergence between documentation and behaviour in a
file the whole codegen path depends on.

### 4.3 REFACTOR -- make the four analysis flags derived, not parsed

**Grounding.** `astshapes.nim` documents four analysis flags set during
parsing: `isFunction`, `isCall`, `isUnpackable`, `isIndex`, `isOperator`.

**Recommended fix.** Low priority. These flags are a performance optimization.
They are correct as-is. If any stage finds it must recompute one, that is a
signal the flag is stale -- fix the setting site, not the reader. Do not derive
them lazily; the frozen-contract design depends on them being set once.

### 4.4 REFACTOR -- name multi-return structs for debuggability

**Grounding.** Multi-return is lowered to `nlmr_<type spellings>` structs via
`multiRetTag` in `cgen_types.nim`, with `__mrN` temps in `cgen.nim`. The tags
are opaque type spellings with no human-readable anchor.

**Recommended fix.** Low priority. If the corpus has multi-return functions,
the generated C is hard to read in a debugger. Consider embedding the source
function name in the struct tag. Bounded, cosmetic.

---

## 5. Deliberate design decisions -- leave alone

These are observed in the source and are intentional. Do not "improve" them.

### 5.1 DESIGN -- `any` is a by-value tagged union, not a pointer

**Grounding.** `runtime.c` defines `nlany` as a struct with a `tag` and a union
of `b/i/u/n/s/p`. The analyzer's `ckAnyStore`/`ckAnyLoad` conversions handle
tag dispatch at compile time; the load helpers switch on the tag at runtime,
returning the zero value on tag mismatch.

**Why leave it.** This is a coherent, self-consistent design: `any` is passed by
value, has a fixed small size, and the runtime fallback is safe. Changing it to
a pointer would break the by-value calling convention and the
`ckAnyStore`/`ckAnyLoad` matrix. Leave it.

**Oracle cross-read.** The oracle has an `AnyType` class (`types.lua`, oracle
section 3.2) and the C generator emits a tagged representation for it. Both
systems are valid. Leave it.

### 5.2 DESIGN -- structural typing with nominal islands

**Grounding.** `canonicalize` dedups structurally-equal types via `TypeCache`;
`nominalRecordType`/`nominalEnumType` create nominal islands; `cTag`
synthesizes `nlrec<typeid>` for anonymous composites.

**Why leave it.** This is the type system's core identity and is exercised by
the whole corpus. Structural canonicalization is what makes the conversion
matrix and the C tag sharing work. Leave it.

**Oracle cross-read.** The oracle is also structural: `types.lua` provides
`is_equal` and the type classes share identity through class-based
canonicalization. Both systems are structural with nominal islands. Leave it.

### 5.3 DESIGN -- exit-code mapping and the `cexit` bypass

**Grounding.** `main.nim` maps signal-death exit codes (128-159) to 255 and uses
`proc cexit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}`
to bypass Nim's int8 clamping of `quit`.

**Why leave it.** This is a deliberate, documented accommodation for the C
toolchain and the Nim runtime's clamping. It is correct for its purpose. Leave it.

### 5.4 DESIGN -- the frozen AST contract in `astshapes.nim`

**Grounding.** `astshapes.nim` is the contract boundary between parser, sema,
analyzer, and cgen. All four stages read the same `Node` layout.

**Why leave it.** This is the strongest architectural guarantee in the
codebase. Do not "improve" it by loosening the layout; if a stage needs a
field that is not in the layout, add the field to the layout and update all four
stages. Leave the contract frozen.

**Oracle cross-read.** The oracle has the same idea under a different surface:
`astdefs.lua` registers each node tag with a shape, and `aster.create(tag,
...)` builds nodes from those shapes (oracle section 2.2). Both freeze the node
contract. The difference is cosmetic (tag strings + Lua tables vs a Nim enum +
ref object). Leave it.

### 5.5 DESIGN -- multi-return lowered to structs, not via hidden params

**Grounding.** Multi-value returns are lowered to `nlmr_*` structs; the caller
unpacks via `__mrN` temps; `genForIn` deliberately does not support multi-value
iterables.

**Why leave it.** The struct lowering is a clean, C-idiomatic translation that
preserves the multi-value semantics without polluting the calling convention.
Leave it. (The `genForIn` limitation in 2.6 is a separate, fixable bug.)

---

## 6. Deferred / lower-priority items carried over from stage 2

These were in the stage-2 list and are kept here, not removed. None are
oracle-stdlib blockers; each is a smaller completeness or design item.

### 6.1 NOT A PARITY TARGET -- `cond` is a Nelu design choice (old 2.2)

**Status: the oracle has no `cond`, and that is not a target.** Verified: the
oracle rejects `cond` with `unexpected syntax`, and its AST node table (oracle
section 2.2.2) contains `Switch` but **no `Cond` node**. Because the oracle never
runs a `cond` program, there is no working code to match -- this is not a
takeover blocker. `cond` is our invention, not a deferred oracle feature, so it
is either a Nelu extension to make work or something to drop.

**Grounding.** `cond` is a reserved keyword in our lexer, parsed by
`parseStatement`, but has almost no downstream support. `switch` is the
parallel construct and is partially implemented.

**Recommended fix.** Pick one, deliberately -- a Nelu design choice, not a
reconciliation with the oracle:
- (a) **Implement it as a live Nelu construct.** Give `cond` real semantics over
  the existing `switch`/expression machinery. Nelu-extension choice: territory
  the dead language does not permit.
- (b) **Drop it.** Remove the `cond` keyword, its parse production, and the
  `tkKeyword` entry. Bounded.

Do **not** frame this as "remove it because the oracle does not have it" -- the
oracle's absence is not a target.

### 6.2 COMPLETE -- enforce `nogc`, or drop the flag (old 2.3)

**Grounding.** `-P nogc` is referenced in the analyzer and config, but the
analyzer notes that "nogc not fully implemented." No enforcement exists.

**Recommended fix.** Either implement the check (reject allocations in
`nogc` functions -- bounded, since allocation sites are a known set) or remove
`nogc` from config and the analyzer's special path. Do not leave a flag that
does nothing.

### 6.3 COMPLETE -- `#|name|#` unsupported; `##[[ ... ]]` parsing done, driver wiring open (old 2.4)

**Grounding.** `#|name|#` is a replacement marker consumed with a diagnostic.
`##[[ ... ]]` is a multi-line Lua block form whose *parsing* is now fixed in the
live tree (see 2.4); the *driver wiring* is the open part (W3/N6).

**Oracle cross-read.** The oracle recognizes all three preprocessor node types
-- `PreprocessExpr` (`#[expr]#`), `PreprocessName` (`#|expr|#`), and
`Preprocess` (`##code`, including the long form `##[[...]]`) -- as first-class
grammar productions (`syntaxdefs.lua:81-82, 226`, oracle section 4.1).

**Recommended fix.** Low priority. If the corpus uses `#|name|#`, implement it;
if not, add a single line to the language docs marking it unsupported and make
the diagnostic an explicit "unsupported feature" message rather than a generic
consume.

### 6.4 STRATEGIC -- consider a Lua backend (we have only C) `[S4-4]`

**Oracle grounding.** The oracle has **two** code generators: the C generator
(`cgenerator.lua`, 1603 lines, oracle section 6.1) and a Lua generator
(`luagenerator.lua`, 394 lines) with a Lua compiler (`luacompiler.lua`, 51
lines, oracle section 6.2). The CLI selects between them with `-g/--generator`.
Ours has only the C path; our `config.generator` field is accepted but only
`c` is implemented.

**Why it is a gap.** A Lua backend lets Nelua programs run on any Lua
implementation without a C toolchain, and lets Nelua act as a
transpiler/preprocessor for Lua. The oracle treats this as a first-class
capability. We do not have it at all.

**Recommended fix.** Do not build this now -- it is a large feature. Scope it:
is there a corpus use case that needs a Lua output mode? If yes, plan it as a
second generator mirroring the C generator's visitor structure. If no, record
it as a known strategic gap and move on.

**Do not do:** do not start implementing a Lua backend before the C
generator's segfaults (2.5) are fixed; a second backend on top of a broken
first backend doubles the broken surface.

### 6.5 COMPLETE -- implement the high-value annotation subset `[S4-5]`

**Oracle grounding.** The oracle defines rich annotation sets
(`typedefs.function_annots`, `variable_annots`, `type_annots`, oracle section
3.5): `noreturn`, `sideeffect`, `nosideeffect`, `comptime`, `nocomptime`,
`noinline`, `inline`, `noinfer`, `noinit`, `noshadow`, `static`, `dynamic`,
`nomangle`, `mangle`, `noalias`, `alias`, `noundce`, `nodecl`, `cimport`,
`cexport`, `cdefine`, `cinclude`, `cflags`, `ldflags`, `linklib`, `cfile`,
`pragmapush`, `pragmapop`, `nopragma`, `aligned`, `packed`, `noprivate`,
`private`. Ours has `pragmas`/`defines` in config and thinner analyzer support.

**Recommended fix.** Audit the corpus for which annotations are actually used,
then implement the high-value subset: `comptime`, `inline`/`noinline`,
`noreturn`/`sideeffect`/`nosideeffect`, `aligned`/`packed`, `static`/`const`.
Do not implement all thirty at once -- implement what the corpus needs and leave
the rest as parse-accepted-but-no-op with a diagnostic, like `cond`.

### 6.6 VERIFY -- check that our single-pass analyzer handles forward references and recursive types `[S4-6]`

**Oracle grounding.** The oracle's analyzer runs a resolution loop: it calls
`context:traverse_node(ast)` and then `context.rootscope:resolve()`, repeating
until `resolutions_count == 0`, then does a final `anyphase=true` traversal for
unset types (oracle section 5.2, phases 2-3).

**Recommended fix.** This is a *verification* item, not a guaranteed fix: run the
corpus and look for analyzer failures on forward references and recursive
types. If found, add a resolution loop mirroring the oracle's. If not found,
document that our single-pass approach is adequate for the corpus and leave
it. Do not add the loop speculatively -- measure first, per the user's standing
instruction to measure before tuning.

### 6.7 COMPLETE -- add `after_analyze` / `after_inference` hook points `[S4-7]`

**Oracle grounding.** The oracle's preprocessor exposes `after_analyze(func)`
and `after_inference(func)` (`ppcontext.lua:296, 308`, oracle section 4.7).

**Recommended fix.** Add a small `afterAnalyze` / `afterInference` callback list
to `AnalyzerContext`, fired at the end of the analyze pass. Bounded, low-risk,
and it unblocks preprocessor features later. Low priority until the
preprocessor is wired (2.4).

---

## 7. Ranked summary (merged priority)

Merged order: oracle-stdlib blockers first, then crashes/wrong-output on
common idioms, then single-construct C-emission quirks. "Live-tree state"
notes which findings the concurrent uncommitted edits in `src/` already address.

| Rank | Item | Label | Live-tree state | Effort | Unblocks |
|------|------|-------|-----------------|--------|----------|
| 1 | `goto` + `::label:` cannot be a statement (1.1) | BUG | **DONE, committed** (`plan/DONE/goto-label-statement.md`) | small | stringbuilder, string, heap, brainfuck, overview |
| 2 | byte literal `'A'_b` not lexed (1.2) | BUG | **DONE, committed** (`plan/DONE/byte-literal-suffix.md`) | small | string.nelua, heap.nelua |
| 3 | `self.x = self.x * s` SIGSEGV (2.1) | BUG | **ALREADY FIXED** -- re-measured 2026-09-06, `r.x = r.x * 2` -> `10` MATCH | small | recmethod_mutate.nelua |
| 4 | `##` Lua blocks not run by the compile driver (2.4) | COMPLETE/BUG | **DRIVER WIRING ALREADY FIXED** -- `analyze` runs `preprocess` (`analyzer.nim:2465`); `## x=7`+`#[x]#` -> `7` MATCH. Remaining open item is the `#|expr|#` name splice | small | splice_embed, brainfuck, sequence.nelua |
| 5 | small-uint arithmetic does not wrap (2.2) | BUG | **FIXED 2026-09-06** (`plan/DONE/uint-wrap.md`): promote in expression context, reject out-of-range at assignment | small | uint8_wrap.nelua, RNG, buffer indices |
| 6 | C emitter SIGSEGVs on anon funcs / method calls / if-elseif (2.5) | BUG | **FIXED 2026-09-06** (`plan/DONE/function-literal-as-value.md`) -- method calls, if/elseif, and anonymous functions bound to a local all MATCH | medium | compiling a large fraction of the corpus |
| 7 | `float32` print drops `.0` (2.3) | BUG | **ALREADY FIXED** -- `75.0`/`1.5` MATCH | small | float32_easing.nelua |
| 8 | `genForIn` single-array-only (2.6) | BUG | **STILL OPEN** | small | idiomatic array iteration |
| 9 | unknown identifiers resolve silently to `any` externs (2.7) | BUG | **ALREADY FIXED** -- `undefned_symbol` -> `undeclared symbol` MATCH | small-medium | catching typos |
| 10 | `cstring` literal assignment (3.1) | BUG | **DONE, committed `f75601a`** (`#cstring` wraps in `nlstr(...)`) | small | lib/ cstring usage |
| 11 | `@union` field access resolves to `any` (3.2) | BUG | **ALREADY FIXED** -- `u.a = 1.5; print(u.a)` -> `1.5` MATCH | small | unions |
| 12 | `<comptime>` on a string evaluates to a number (3.3) | BUG | **DONE** (`plan/DONE/comptime-string-eval.md`, already fixed) | small | builtins.nelua, utf8.nelua, stringbuilder.nelua |
| 13 | `likely`/`unlikely` not lowered (3.4) | BUG | **ALREADY FIXED** -- `__builtin_expect` lowering, `1` MATCH | small | heap.nelua |
| 14 | `...: cvarargs` C emission (3.5) | BUG | **STILL OPEN** | small | stringbuilder.nelua |
| 15 | dotted `global X.Y` emits invalid C (3.6) | BUG | parse half DONE, committed `f75601a`; **C-emission half STILL OPEN** | small | dotted global/method names |
| 16 | `check()` message missing source location (3.7) | BUG | **STILL OPEN** (cosmetic) -- oracle prints `path:line:col:`, ours does not | small | check_fail.nelua |
| 17 | no C `enum` emitted for enum types (3.8) `[S4-2]` | BUG | **ALREADY FIXED** -- `E.Green` -> `1` MATCH, real C enum emitted | small | type-safe `switch` |
| 18 | `T?` accepted by us, rejected by the oracle (3.9) | DESIGN | **NOT A PARITY TARGET** (oracle never runs it) | small | Nelu choice: implement as live type, or drop |
| 19 | colon method on type-keyword receiver (1.3) | COMPLETE | **DONE, committed `f75601a`** (isTypeKeyword + parsePrimary); end-to-end still blocked on the `#|argname|#` name-splice gap | n/a | lib/string.nelua |
| 20 | `facultative(string)` type-function-call (1.4) | COMPLETE | **DONE, committed `f75601a`** (parseType generic instantiation); analyzer resolution still open | n/a | lib/builtins.nelua |
| 21 | typed `for i: T = 0, <N do` (1.5) | COMPLETE | **DONE, committed `f75601a`** (parseFor parseIdDecl + `<` bound); MATCHes the oracle end-to-end | n/a | heap.nelua |
| 22 | global table data-driven refactor (4.1) `[S4-3]` | REFACTOR | open | small | 2.7b |
| 23 | align `runtime.c` comment with behaviour (4.2) | REFACTOR | open | trivial | reader clarity |
| 24 | analysis flags derived, not parsed (4.3) | REFACTOR | open | low | none |
| 25 | name multi-return structs (4.4) | REFACTOR | open | low | debugger readability |
| 26 | `cond` removed, not implemented (6.1) | COMPLETE | open (oracle has no `cond`) | small | no parse trap |
| 27 | `nogc` enforced-or-dropped (6.2) | COMPLETE | open | small | the `-P nogc` flag |
| 28 | `#|name|#` supported-or-documented (6.3) | COMPLETE | open | small | no generic consume diagnostic |
| 29 | annotation high-value subset (6.5) `[S4-5]` | COMPLETE | open | medium | user control over C interop/opts |
| 30 | `after_analyze`/`after_inference` hooks (6.7) `[S4-7]` | COMPLETE | open | small | future preprocessor features |
| 31 | Lua backend (6.4) `[S4-4]` | STRATEGIC | open | large | second deployment target |
| 32 | verify forward-reference / recursive-type handling (6.6) `[S4-6]` | VERIFY | open | small | analyzer robustness |
| 33 | verify table-literal side-effect tracking matches the oracle (P1.3) | VERIFY | open | small | if our analyzer tracks more side effects than the oracle, table-constructor ordering may differ |
| 34 | verify emit_nelua_main statement-detection heuristic matches the oracle (P2.4) | VERIFY | open | small | if our heuristic produces false negatives, emitted C may differ |
| 35 | verify KeyIndex/InitList node mapping against the oracle's stdlib (P3.1) | VERIFY | open | small | if the oracle's stdlib uses constructs that map to different AST nodes, codegen paths diverge |

Items 5.1-5.5 are deliberately not ranked: they are design decisions to leave
alone.

---

## 8. Explicit "do not do" list

- Do not change `any` from a by-value tagged union to a pointer (5.1).
- Do not loosen the frozen AST contract in `astshapes.nim` (5.4).
- Do not replace structural canonicalization with nominal-only typing (5.2).
- Do not remove the exit-code mapping or the `cexit` bypass (5.3).
- Do not make the undeclared-symbol diagnostic unconditional before checking
  the corpus for Lua-style implicit globals (2.7 caveat).
- Do not delete the print-AST paths or the `needsCompile` flag until the
  emitter segfaults are actually fixed (2.5 caveat) -- they are the canary.
- Do not wire the preprocessor into the default compile path behind a flag
  that is off by default; the feature is registered and expected (2.4).
- Do not treat any item in Section 5 as a bug. If you think one is wrong,
  argue with evidence from the corpus, not from taste.
- **`[S4-8]` Do not replicate the oracle's gradual, scope-aware, hygienic
  preprocessor architecture.** It is tightly coupled to the oracle's visitor/
  scope model; the complexity does not transfer to our pipeline. Wire our
  preprocessor simply (2.4) and document the functional gap.
- **`[S4-4]` Do not start a Lua backend before the C generator's segfaults
  (2.5) are fixed.**
- **Do not add `nkGoto`/`nkLabel` to the AST or `goto`/`::` to the keyword
  table** -- both already exist (astshapes.nim:64-65; parser.nim parseStatement).
  The blocker for `goto` is `parseBlock` breaking on `tkColonColon`
  (parser.nim:603, 631), not the node kinds (1.1).
- **Do not re-litigate the three items the live tree already fixed** (1.3,
  1.4, 1.5, and the parsing half of 2.4). They are COMPLETE; verify them
  end-to-end against the oracle's stdlib and report, do not re-design.

---

## 9. Superseded / re-framed items register

These items from earlier revisions are kept in the document but their framing
changed. Nothing was deleted.

| Old ref | Old framing | New framing | Why |
|---------|-------------|-------------|-----|
| old 1.5 `T?` | "implement it or delete it" | **BUG (divergence): make `T?` a parse error to match the oracle** (3.9) | The oracle *rejects* `T?`; our stub accepts it. A stub that accepts what the oracle rejects is a divergence, not an inert feature. |
| old 2.2 `cond` | "implement `cond`, or remove the keyword" | **COMPLETE: remove `cond`** (6.1) | The oracle has no `cond` at all (rejects it; no `Cond` node in its AST table). It is our invention. |
| old 1.1 emitter segfaults | top BUG | Tier B, rank 6 (2.5) | Kept as BUG, but demoted behind the oracle-stdlib blockers and common-idiom crashes, per the merged priority. |
| old 2.1 preprocessor wiring | COMPLETE | COMPLETE, re-labeled 2.4 with the driver-wiring half separated from the long-bracket parsing half (now DONE) | The live tree fixed the parsing half; the driver half is the open part. |
| old 1.4 enum | BUG | Tier C, rank 17 (3.8) | Kept as BUG; demoted behind C-emission quirks that block more files. |
| -- | (none) | **NEW 1.1 `goto` + `::label:`** | Absent from stage 2 entirely; now rank 1. |
| -- | (none) | **NEW 1.2 byte literal `'A'_b`** | Absent from stage 2; now rank 2. |
| -- | (none) | **NEW 2.1 `self.x = self.x * s` SIGSEGV (C1)** | Absent from stage 2; now rank 3. |
| -- | (none) | **NEW 3.1 `cstring` literal (C2)** | Absent from stage 2. |
| -- | (none) | **NEW 3.2 `@union` field access (C3)** | Absent from stage 2. |
| -- | (none) | **NEW 3.3 `<comptime>` on a string (N3)** | Absent from stage 2. |
| -- | (none) | **NEW 3.4 `likely`/`unlikely` (N7)** | Absent from stage 2. |
| -- | (none) | **NEW 3.5 `...: cvarargs` (N8)** | Absent from stage 2. |
| -- | (none) | **NEW 3.6 dotted `global X.Y` (C4)** | Absent from stage 2. |
| -- | (none) | **NEW 3.7 `check()` source location (W4)** | Absent from stage 2. |
| -- | (none) | **NEW 4.1 multi-return destructuring (N1)** | Absent from stage 2 entirely; caught by `plan/harness.py` probe `exam/fn_multi`, NOT by the devil-advocate merge. **Tier A priority** -- it is both a common-idiom wrong-output bug (`local a, b = f()` leaves trailing bindings nil; `print(f())` drops extras) and a stdlib blocker (the oracle's own `lib/*.nelua` destructures multi-return pervasively). Ticket `plan/INBOX/multi-return-destructuring.md`. |
| -- | (none) | **NEW tickets mined from this doc, stage 5** | Every still-open BUG in §1–§3 (ranks 1–17, minus the three already COMPLETE) is now its own INBOX ticket with grounding, root cause, recommended fix, and verification. The ticket is the worklist; this doc stays the ranked reference. See `plan/TICKETS.md` for the board. |

---

*End of improvements document. Grounded in `plan/observed-language-spec.md`
(stage 1), cross-read against `plan/oracle-language-spec.md` (stage 3), and
merged against `plan/DONE/devil-advocate-findings.md` (stage 4). This revision
additionally folds in Professor B's oracle-quirks cross-read
(`plan/INBOX/oracle-improvements.md`, stage 3-4 revision), which added three VERIFY
items (33-35) and confirmed that the existing priority ordering is correct.
Labels: BUG = fix it, COMPLETE = finish a deferred feature, REFACTOR = internal
cleanup, DESIGN = leave alone, STRATEGIC = consider (large effort),
VERIFY = measure before acting. All text is ASCII-only.*