-- Improvements for the Oracle's Source
--
-- This document identifies concrete improvements for the oracle's implementation,
-- grounded in plan/oracle-language-spec.md (the stage-1 language specification).
-- Every recommendation cites a file and line in lualib/.
--
-- Organization:
--   P1 = correctness / correctness-adjacent (bugs, unsoundness, crashes)
--   P2 = maintainability / dead code / latent defects
--   P3 = performance / design smell / incomplete features
--   P4 = polish / naming / documentation
--
-- NOTE: This is analysis, not a patch. We do not modify the oracle.

================================================================================
P1: CORRECTNESS AND CORRECTNESS-ADJACENT
================================================================================

--------------------------------------------------------------------------------
P1.1 — ensure_type counter is not restored if a type visitor throws
--------------------------------------------------------------------------------
File: lualib/nelua/ccontext.lua, lines 132-176

The `typedecldepth` counter is incremented before visiting a type and decremented
after. If the type visitor throws (e.g. via `node:raisef`), the decrement at line
168 never runs. The counter is a plain integer field on the CContext; it is not
protected by any pcall or scope-guard. A thrown type visitor therefore leaves
`typedecldepth > 0`, which corrupts the `latedecls` drain loop at lines 169-174
(the drain only runs when `typedecldepth == 0`). Subsequent `ensure_type` calls
may skip late-declaration of struct/union pointers, producing incomplete C
typedefs in the emitted output.

Fix: wrap the visitor call (line 154) in a pcall that restores the counter on
failure, or use a scope-guard pattern.

--------------------------------------------------------------------------------
P1.2 — ensure_builtin short-circuit is asymmetric
--------------------------------------------------------------------------------
File: lualib/nelua/ccontext.lua, lines 273-283

`ensure_builtin(name, ...)` short-circuits only when called with zero extra
arguments AND the builtin is already used. When called with extra arguments
(e.g. `ensure_cmath_func` at line 224), it always re-invokes the builtin
definition function even if the builtin was already defined. This can cause
duplicate definitions or re-entry side effects in builtins that are not
idempotent.

Fix: check `self.usedbuiltins[name]` before invoking the builtin function
regardless of argument count, or make builtin definition functions idempotent.

--------------------------------------------------------------------------------
P1.3 — Table literal side effects are not tracked
--------------------------------------------------------------------------------
File: lualib/nelua/analyzer.lua, line 429

`visitor_Table_literal` (lines 420-433) contains the comment
`-- TODO: check side effects?`. Table literal elements are traversed for type
inference but their side effects (function calls, upvalue mutations) are not
recorded on the scope. This means the analyzer cannot detect or warn about
side-effecting expressions inside table constructors, and code motion /
dead-code elimination based on scope side-effect flags may be unsound for
programs that rely on those side effects.

Fix: mark `funcscope.sideeffect = true` when a table literal element is a call
or another side-effecting expression, consistent with how other visitors handle
it.

--------------------------------------------------------------------------------
P1.4 — Pseudo-argument type/attr copying is fragile
--------------------------------------------------------------------------------
File: lualib/nelua/analyzer.lua, lines 1287-1291

`visitor_Call` copies `pseudoargtypes` and `pseudoargattrs` from the function
definition node to the call site. The comment at line 1287 reads
`-- TODO: rethink this pseudo args thing`. The copy is a shallow table copy
that does not account for all cases where pseudo-argument metadata diverges
between the definition and the call. This can produce mismatched types between
the inferred call signature and the actual arguments, leading to spurious
type errors or, in edge cases, unsound inference.

Fix: rework pseudo-argument handling to derive types at the call site from the
function's resolved signature rather than copying mutable tables.

--------------------------------------------------------------------------------
P1.5 — Preprocessed blocks can never be marked `done`
--------------------------------------------------------------------------------
File: lualib/nelua/analyzer.lua, lines 1846-1861

The comment at line 1848 reads `-- TODO: improve this later`. Because new
statements can be injected into a preprocessed block at any time (via
`inject_statement`), the `done` optimization is permanently disabled for
preprocessed blocks. The `done` flag (see `analyzercontext.lua` line 104) is
the analyzer's primary mechanism for skipping re-traversal of already-visited
nodes. Disabling it for all preprocessed blocks means those blocks are re-
traversed on every inference iteration, which is both a performance issue and
a source of non-determinism if injected statements interact with the inference
loop.

Fix: track whether a block has been "sealed" (no more injections expected) and
mark it `done` at that point, or restructure gradual preprocessing so that
injections happen in a bounded phase before the inference loop.

================================================================================
P2: MAINTAINABILITY, DEAD CODE, AND LATENT DEFECTS
================================================================================

--------------------------------------------------------------------------------
P2.1 — Dead code in and/or short-circuit emission
--------------------------------------------------------------------------------
File: lualib/nelua/cgenerator.lua, lines 1378-1414

In `visitor.BinaryOp` for the `and`/`or` short-circuit path:
  - The variable `t1_` (line 1380) is declared and assigned from `lnode` but is
    NEVER READ in the `and` case (only `t2_` and `cond_` are used at line 1400).
  - The zero-initialized `t2_` value (line 1385) is also dead in the `and` case
    because line 1400 reads `cond_ ? t2_ : <zeroed>`, where `t2_` was assigned
    inside the `if(cond_)` block.
In the `or` case `t1_` IS read (line 1412: `cond_ ? t1_ : t2_`), so only the
`and` branch has truly dead code. The comment at line 1382 reads
`--TODO: be smart and remove this unused code`.

Fix: remove the unused `t1_` declaration/assignment in the `and` branch, and
remove the dead zero-initialized `t2_` fallback.

--------------------------------------------------------------------------------
P2.2 — config.define handling is interleaved with preprocessing emission
--------------------------------------------------------------------------------
File: lualib/nelua/preprocessor.lua, line 175

The comment at line 175 reads `if config.define and not ppcontext.defined then
-- TODO: move code`. The `config.define` handling (lines 175-180) is interleaved
with the preprocessing code emission (lines 181-193). This mixes two concerns:
(1) populating the preprocessor environment from CLI `-D` defines, and
(2) generating and loading the preprocessor Lua code. If the define-handling
code throws, the preprocessor code is partially emitted and the error path is
unclean.

Fix: separate the two phases. Populate `ppcontext` from `config.define` before
generating the preprocessor code, and ensure the code generation is atomic.

--------------------------------------------------------------------------------
P2.3 — Typo: "reserverd_keywords"
--------------------------------------------------------------------------------
File: lualib/nelua/cdefs.lua, line 548

`cdefs.reserverd_keywords` is misspelled (should be `reserved_keywords`).
Referenced at line 667 as `cdefs.reserverd_keywords`. The typo is consistent
across both references, so it is a latent defect rather than a runtime bug, but
it makes the identifier harder to search for and correct.

Fix: rename to `reserved_keywords` at both line 548 and line 667.

--------------------------------------------------------------------------------
P2.4 — emit_nelua_main uses position-based heuristic
--------------------------------------------------------------------------------
File: lualib/nelua/cgenerator.lua, lines 1550-1565

`emit_nelua_main` detects whether statements were added to the emitter by
comparing `emitter:get_pos()` before and after visiting the function body.
This is a position-based heuristic: if the visitor adds zero-length output
(e.g. an empty statement or a comment), the heuristic reports "no statements"
falsely. It is fragile with respect to emitter internals.

Fix: use an explicit counter on the emitter or context (e.g.
`self.statements_added`) that visitors increment when they emit a statement,
rather than comparing buffer positions.

================================================================================
P3: PERFORMANCE, DESIGN SMELL, AND INCOMPLETE FEATURES
================================================================================

--------------------------------------------------------------------------------
P3.1 — Multiple "not implemented yet" errors in code generation
--------------------------------------------------------------------------------
File: lualib/nelua/cgenerator.lua, lines 417 and 731

`visitor.KeyIndex` (line 417) and `visitor.InitList` (line 731) both contain
`error('not implemented yet')`. These are hard runtime errors if the analyzer
ever passes a `KeyIndex` or `InitList` node to the C generator. The analyzer
may accept these constructs (they are valid AST nodes) but the C generator
cannot emit them. Users get a confusing "not implemented yet" crash rather than
a clean "this feature is not supported" message at analysis time.

Fix: either implement the visitors or move the check to the analyzer so the
error is raised during type checking with a descriptive message.

--------------------------------------------------------------------------------
P3.2 — Closures and upvalues are explicitly unsupported
--------------------------------------------------------------------------------
File: lualib/nelua/analyzer.lua, line 672

`node:raisef("attempt to access upvalue '%s', but closures are not supported")`.
Closures (inner functions that reference outer local variables) are rejected at
analysis time. This is a significant language limitation. Nested functions that
do not capture upvalues work, but any capture is a hard error.

Fix: implement upvalue capture (e.g. by boxing captured variables or promoting
them to heap-allocated cells), or at minimum provide a clear, early error
message with a link to documentation.

--------------------------------------------------------------------------------
P3.3 — Variant and optional types are explicitly unsupported
--------------------------------------------------------------------------------
File: lualib/nelua/analyzer.lua, lines 919 and 923

`node:raisef("variant type not implemented yet")` and
`node:raisef("optional type not implemented yet")`. These are type-system
features that the analyzer recognizes syntactically but cannot handle. Users
discovering these features get a raw "not implemented yet" error.

Fix: implement variant and optional types, or provide a documented migration
path (e.g. "use a union with a nil variant" / "use a pointer to T").

--------------------------------------------------------------------------------
P3.4 — Multiple returns in main is not supported
--------------------------------------------------------------------------------
File: lualib/nelua/cgenerator.lua, line 801

`node:raisef("multiple returns in main is not supported")`. The entrypoint
emission (`emit_entrypoint`, lines 1568-1591) assumes the main function has a
single return. Functions with multiple returns (a common pattern for error
handling) are rejected only when they are the program entrypoint.

Fix: support multiple returns in the entrypoint by wrapping the call in a
function that collects all return values, or by lowering to a different
entrypoint convention.

================================================================================
P4: POLISH, NAMING, AND DOCUMENTATION
================================================================================

--------------------------------------------------------------------------------
P4.1 — Comment hygiene: stale TODOs without tracking
--------------------------------------------------------------------------------
Files: lualib/nelua/analyzer.lua (lines 429, 1287, 1848),
       lualib/nelua/cgenerator.lua (line 1382),
       lualib/nelua/preprocessor.lua (line 175),
       lualib/nelua/ccontext.lua (line 132, implicit)

The oracle contains at least six `-- TODO:` comments that mark known issues.
None of them are tracked in an issue tracker or referenced from a design
document. Without tracking, TODOs accumulate and are never resolved or
de-scoped.

Fix: maintain a TODO registry (a file in plan/ or a GitHub issue board) that
each TODO references, with an owner and a target milestone.

--------------------------------------------------------------------------------
P4.2 — Inconsistent error message style
--------------------------------------------------------------------------------
Files: lualib/nelua/analyzer.lua (lines 672, 919, 923),
       lualib/nelua/cgenerator.lua (lines 417, 731, 801)

Some "not supported" errors use `node:raisef` (which formats with source
position and a message), while others use bare `error('not implemented yet')`
(which does not include source position or context). Users get inconsistent
diagnostics: some errors point at the exact source location, others do not.

Fix: standardize on `node:raisef` for all analysis-time and codegen-time
errors, and use a consistent message format.

================================================================================
SUMMARY
================================================================================

Priority  P1 (correctness):      5 items (P1.1-P1.5)
Priority  P2 (maintainability):  4 items (P2.1-P2.4)
Priority  P3 (features/limits):  4 items (P3.1-P3.4)
Priority  P4 (polish):          2 items (P4.1-P4.2)
         TOTAL:                 15 items

All items are grounded in plan/oracle-language-spec.md and cite specific
file:line references in lualib/.

================================================================================
STAGE 3-4: CROSS-READ AGAINST plan/observed-language-spec.md (OUR SOURCE)
================================================================================

This section is the stage-3/4 revision. Stage 3 cross-read every item in this
document against Professor A's stage-1 spec of our source
(`plan/observed-language-spec.md`, grounded in `src/`). Stage 4 records the
delta: which items are takeover-relevant (we must reproduce the quirk or
record a deliberate divergence), which are oracle-internal (our source does
not have the mechanism -- moot for takeover), and which are shared
limitations (both implementations have the same gap).

Method: for each oracle improvement, we ask three questions.
  (a) Does our source have the same mechanism, and does it have the same
      quirk?  -> must reproduce, or record a divergence.
  (b) Does our source have the mechanism but without the quirk?  -> our
      cleaner behaviour is a deliberate divergence; record it.
  (c) Does our source not have the mechanism at all?  -> moot; we cannot
      reproduce a mechanism we do not have, and the quirk cannot affect
      parity because our codegen never emits the affected C.

--------------------------------------------------------------------------------
STAGE 3-4.1 — Mapping table
--------------------------------------------------------------------------------

Item    Oracle quirk (file:line)                  Our source (observed-spec)   Class
------  --------------------------------------  --------------------------  ------
P1.1    typedecldepth not restored on throw      Not present. Our cgen.nim    (c)
        (ccontext.lua:132-176)                   uses typeSeen/typesSeq
                                                (6.4); no typedecldepth/
                                                latedecls queue documented.

P1.2    ensure_builtin asymmetric short-circuit Not present. Our preprocessor  (c)
        (ccontext.lua:273-283)                   registers builtins via
                                                registerPreprocessorBuiltins
                                                (4.4); no ensure_builtin API.

P1.3    Table literal side effects not tracked  DumpInfo records sideeffect    (b)/(a)
        (analyzer.lua:429)                      (5.2); whether table-literal
                                                elements are covered is not
                                                stated explicitly. Our
                                                analyzer appears to track
                                                MORE side effects than the
                                                oracle. Needs verification.

P1.4    Pseudo-arg type/attr copying fragile     Not present. analyzeCall      (c)
        (analyzer.lua:1287-1291)                (5.6) has no pseudoargtypes/
                                                pseudoargattrs machinery.

P1.5    Preprocessed blocks never `done`        Preprocessor not wired into   (c)
        (analyzer.lua:1846-1861)                the compile driver (4.8,
                                                backlog C3). Our default path
                                                never creates preprocessed
                                                blocks, so the `done`
                                                optimization gap is moot.

P2.1    Dead code in and/or short-circuit        Our cgen.nim emits and/or      (b)
        (cgenerator.lua:1378-1414)               via arithCast/coerce (6.5);
                                                no documented dead code.
                                                Our cleaner emission is a
                                                deliberate divergence;
                                                behaviour-preserving, so
                                                no reproduction needed.

P2.2    config.define interleaved with pp emit    Preprocessor not wired      (c)
        (preprocessor.lua:175)                   (4.8); our config.defines
                                                (7.2) is consumed by the
                                                preprocessor separately.

P2.3    Typo "reserverd_keywords"               Not present. Our cgen uses    (c)
        (cdefs.lua:548, 667)                    cIdent (6.3); no keyword
                                                reservation table documented.

P2.4    emit_nelua_main position heuristic      nelua_main + main() emitted  (b)
        (cgenerator.lua:1550-1565)               (6.4); how our driver
                                                detects added statements is
                                                not documented. Likely a
                                                different mechanism. Our
                                                mechanism is a deliberate
                                                divergence; verify it does
                                                not produce false negatives.

P3.1    KeyIndex/InitList `not implemented yet`  Our AST has nkDotIndex (2.5)  (b)
        (cgenerator.lua:417, 731)                and table constructors; the
                                                oracle's KeyIndex/InitList
                                                tags do not map 1:1 to our
                                                NodeKind enum. Our cgen
                                                handles the equivalent
                                                constructs (or has its own
                                                gaps, see our-improvements
                                                3.1/3.2). Divergence in
                                                AST node mapping, not a
                                                behaviour gap.

P3.2    Closures/upvalues rejected               Our source SUPPORTS closures  (a) DIVERGENCE
        (analyzer.lua:672)                      (our-improvements 2.5 notes
                                                "closures/upvalues work
                                                already landed"). The oracle
                                                rejects upvalue capture; we
                                                accept it. This is a Nelu
                                                extension, not a parity
                                                target -- the oracle never
                                                runs a closure program.

P3.3    Variant/optional types unsupported      Both have incomplete         (d) SHARED
        (analyzer.lua:919, 923)                 support (3.7, 6.8). Same
                                                limitation; no divergence.

P3.4    Multiple returns in main rejected       Our source SUPPORTS multi-    (a) DIVERGENCE
        (cgenerator.lua:801)                    return lowering (6.5,
                                                multiRetTag/mrCounter, 6.2);
                                                not listed as a limitation
                                                in 6.8. The oracle rejects
                                                multiple returns in the
                                                entrypoint; we accept it.
                                                If the oracle's stdlib has
                                                a multi-return main, the
                                                oracle rejects it and we
                                                accept it -- a behavioural
                                                divergence. Verify against
                                                the corpus.

P4.1    Stale TODOs without tracking             Our spec documents 9 known    (d) SHARED
                                                gaps in 8.7; our source has
                                                the same accumulation
                                                problem, just better
                                                aggregated.

P4.2    Inconsistent error message style        Our errors.nim standardizes  (b) DELIBERATE
        (analyzer.lua:672,919,923;               on NeluaError/render        DIVERGENCE
        cgenerator.lua:417,731,801)              (7.6): path:line:col: error:
                                                msg + hint + caret. The
                                                oracle mixes node:raisef
                                                and bare error(). Our
                                                cleaner style is a design
                                                choice; no reproduction
                                                needed.

Key: (a) = takeover-relevant divergence, (b) = deliberate divergence (our
cleaner behaviour), (c) = oracle-internal (moot for takeover), (d) = shared
limitation (no action).

--------------------------------------------------------------------------------
STAGE 3-4.2 — The delta: what the cross-read changed about this list
--------------------------------------------------------------------------------

The cross-read produces three findings, each of which changes how this list
should be read by a takeover reimplementation.

1. MOST ITEMS ARE ORACLE-INTERNAL, NOT TAKEOVER-RELEVANT.
   Of the 15 items, 9 are class (c): the oracle's internal mechanisms
   (typedecldepth, ensure_builtin, pseudo-arguments, the `done` optimization,
   the config.define interleaving, the reserverd_keywords typo, the and/or
   dead code, the position heuristic, the KeyIndex/InitList node tags) have no
   counterpart in our source. Our reimplementation does not have these
   mechanisms, so we cannot reproduce the quirks, and the quirks cannot affect
   parity because our codegen never emits the affected C. These items are
   useful as a map of the oracle's internal architecture -- they tell the
   reimplementation what the oracle does behind the scenes -- but they are
   NOT a to-reproduce list. The coordinator was right to call them "a map of
   the oracle's internal quirks and broken bits"; they are a map, not a
   checklist.

2. TWO ITEMS ARE BEHAVIOURAL DIVERGENCES THE ORACLE REJECTS AND WE ACCEPT.
   P3.2 (closures/upvalues) and P3.4 (multiple returns in main) are cases
   where the oracle raises a hard error and our source accepts the construct.
   Under the parity/extension rule ("we want working code to work and are not
   interested in failing code failing the same"), these are NOT parity
   targets: the oracle never runs a program using them, so there is no
   working code whose behaviour we must match. They are Nelu extensions. The
   takeover-relevant question is not "should we reproduce the rejection?" but
   "does the oracle's stdlib use these constructs?" If it does not (likely,
   since the oracle rejects them), no action is needed. If it does, we have a
   divergence to document -- but the oracle cannot run such a program, so the
   divergence is unobservable.

3. TWO ITEMS ARE SHARED LIMITATIONS, NOT DIVERGENCES.
   P3.3 (variant/optional types) and P4.1 (untracked TODOs) are gaps both
   implementations share. They are not takeover risks because neither
   implementation can handle the constructs, so there is no behavioural
   difference to reproduce. They are candidates for the shared-completeness
   worklist, not the parity worklist.

--------------------------------------------------------------------------------
STAGE 3-4.3 — Revised priority for takeover purposes
--------------------------------------------------------------------------------

Re-ordered against the takeover criterion ("does the oracle's stdlib exercise
this construct, and does our source handle it the same way?"):

  TAKEOVER-RELEVANT (verify or reproduce):
    P1.3  Table literal side effects -- if the oracle's stdlib uses
          side-effecting table constructors and our analyzer tracks them
          differently, the emitted C may differ. VERIFY against the corpus.
    P2.4  emit_nelua_main heuristic -- if the oracle's stdlib relies on
          nelua_main behaviour and our heuristic differs, the emitted C may
          differ. VERIFY against the corpus.
    P3.1  KeyIndex/InitList node mapping -- the oracle's AST node tags do not
          map 1:1 to our NodeKind enum. If the oracle's stdlib uses
          constructs that the oracle maps to KeyIndex/InitList but we map to
          different nodes, the codegen paths diverge. VERIFY against the
          corpus.

  NOT TAKEOVER-RELEVANT (oracle-internal or shared):
    P1.1, P1.2, P1.4, P1.5, P2.1, P2.2, P2.3, P3.2, P3.3, P3.4, P4.1, P4.2

  DELIBERATE DIVERGENCES (our source is cleaner; no action):
    P2.1 (cleaner and/or emission), P4.2 (standardized error format),
    and the closures/upvalues and multiple-returns-in-main acceptances
    (P3.2, P3.4) -- both are Nelu extensions, not parity targets.

--------------------------------------------------------------------------------
STAGE 3-4.4 — Feed into plan/INBOX/our-improvements.md
--------------------------------------------------------------------------------

The three takeover-relevant items (P1.3, P2.4, P3.1) are verification items,
not fixes. They are recorded in plan/INBOX/our-improvements.md as a new VERIFY
entry (see the stage-4 note there). The deliberate divergences (P2.1, P4.2,
P3.2, P3.4) confirm items already in our-improvements.md: the closures
acceptance (2.5), the multi-return lowering (5.5), and the standardized error
format (7.6). No re-ordering of our-improvements.md is required by this
cross-read -- the existing priority (oracle-stdlib blockers first) already
correctly ranks the takeover-relevant work. The cross-read's contribution is
negative: it confirms that the oracle's internal quirks are noise for our
worklist, and the real takeover risks are the three verification items
above.

================================================================================
END OF STAGE 3-4 REVISION
================================================================================

This document is stage 2 (improvements for the oracle's source) with a
stage-3/4 cross-read against plan/observed-language-spec.md appended. The
stage-3/4 revision was requested by the coordinator after the initial stage-2
delivery, on the grounds that the improvements list is a map of the oracle's
internal quirks and broken bits -- precisely the knowledge a takeover
reimplementation needs wherever real code depends on an oracle quirk. The
cross-read shows that most of those quirks are oracle-internal (our source
does not have the mechanisms) and therefore not reproduction targets; the
takeover-relevant items are three verification items (P1.3, P2.4, P3.1) and
two deliberate divergences (P3.2, P3.4) already recorded in
plan/INBOX/our-improvements.md. All text is ASCII-only; file:line citations are
against lualib/ (oracle) and src/ (our source, via the observed spec).

================================================================================
STATUS NOTE (2026-09-03)
================================================================================

Two items in this doc have moved on since the stage-3/4 revision and are
recorded here so the doc is not misread as current state:

- **P3.1 (metamethod-dispatch family, M1-M4).** M1 (`__len` via `#`) and M2
  (`__tostring` via `print()`) are now fixed in `src/cgen.nim` and MATCH the
  oracle; M4's array-field-init blocker is fixed too (`f75601a`), so M4 is
  unblocked. Only M3 (`__call` codegen) remains open. The "ranks 1 of 25 by
  stdlib-file breadth" framing in `plan/DONE/devil-advocate-findings.md` still
  holds for the family as a whole, but the ranking itself should be
  re-derived on the next Devil's advocate run.

- **P3.2 (closures / upvalues).** Now 7 of 15 probes MATCH the oracle, up from
  the 0 MATCH this doc originally recorded. Module-scope capture lowers to
  file-scope `static`s and function-local capture is rejected with the
  oracle's exact message (committed `75f315e` + `bab3eb3`). See
  `plan/closures-upvalues-design.md` 0 and `NELU-2K.md` 1.5.