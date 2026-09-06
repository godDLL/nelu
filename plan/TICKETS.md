# Tickets

Formal index for the `plan/` ticketing system.  New tickets go in `INBOX/`,
active ones in `WIP/`, finished ones in `DONE/`.  This file is the single place
to see the whole board.

## Convention

- A **ticket** is a task brief for an agent: it has a scope, a status, and an
  owner-able deliverable.  It lives as a `.md` file in one of the three buckets.
- **`INBOX/`** -- queued, not started.  A brief that says "do not start yet" is
  an INBOX ticket; the brief IS the ticket.
- **`WIP/`** -- active.  Something an agent is currently working on, or research
  feeding an active implementation.
- **`DONE/`** -- completed (implemented, or research concluded with a verdict).
  Kept as evidence; a DONE ticket is not re-opened, it is replaced by a new INBOX
  ticket if the work resumes.
- Design docs, reference specs, and gate scripts are **not tickets**.  They live
  in `plan/` root as inputs to tickets and are enumerated at the bottom.
- Cross-references use the bucket path (`plan/WIP/stdlib-parity.md`), so a ticket
  keeps its references working when it moves.

## Status vocabulary (per-ticket `Status:` header)

| Label | Meaning |
|---|---|
| `brief only -- do not start yet` | INBOX; exists to hand an agent a target |
| `CLOSED` | DONE; implemented and verified against the oracle |
| `RESEARCH` | read-only on `src/`; no edit, verdict recorded |
| `DESIGN` / `design spec` | INBOX or WIP; not implemented, awaiting a build or a pass |
| `STILL OPEN` | INBOX; confirmed gap, no fix |
| `STALE` | DONE; superseded, do not use as a work list |

## Board

### INBOX (queued)

| Ticket | Status | Summary |
|---|---|---|
| `plan/INBOX/harness-rework-brief.md` | brief only | Consolidate the conformance/gating/examples mess into one harness + one coverage doc; old probes move to `tmp/`. |
| `plan/INBOX/MAN_NELU-improvements.md` | proposals | Structured improvement list from walking the manual end-to-end. |
| `plan/INBOX/improve-and-expand.md` | proposals | Broader improve-and-expand candidate list. |
| `plan/INBOX/oracle-improvements.md` | proposals | Improvements for the oracle's own source. |
| `plan/INBOX/our-improvements.md` | STILL OPEN | Improvements for our `src/`; verified gaps with no fix yet. |
| `plan/INBOX/any-intended-design.md` | design spec | The intended Nelu `any` design; not implemented, awaiting a build. |
| `plan/INBOX/any-phase2-design.md` | design spec | `any` phase 2 tagged-representation design for the implementer. |
| `plan/INBOX/record-enum-design.md` | design-pass | Record/enum design; follow-up implementation pending. |
| `plan/INBOX/type-as-value-design.md` | draft | Type-as-value design; minimal slice done, full doc open. |
| `plan/INBOX/auto-type-inference.md` | design spec | `auto` type inference feature. Oracle infers `local x: auto = 1`→int64, `auto == auto`→true, rejects `auto` on anonymous functions. Nelu: var-decl inference FIXED (`56ae152`), print-of-auto FIXED (`45dee17`), auto-return FIXED via global-fn fix (`413ad66`); auto-param and auto-on-anonymous are both-reject MATCH (no divergence). Only #4 (auto as a type value) remains, part of the broader type-as-value gap. |
| `plan/INBOX/closures-upvalues.md` | design spec | Closure / upvalue scoping beyond 0.2.0; design doc for the implementation agent, nothing implemented. |
| `plan/INBOX/exceptions-implementation.md` | design spec | Exceptions implementation design; not started. Companion `plan/INBOX/exceptions-oracle-behavior.md`. |
| `plan/INBOX/exceptions-oracle-behavior.md` | reference | Oracle exception behavior reference; companion to `plan/INBOX/exceptions-implementation.md`. |
| `plan/INBOX/c-pointer-array-lowering.md` | design spec | Pointer / array / record C-lowering spec; the pointer-to-array emission blocker is not fixed in `src/`. |
| `plan/INBOX/genforin-multi-value.md` | STALE | Rank 8. Multi-value `for k, v in array`. Premise falsified 2026-09-06: the oracle itself crashes on it (`get_return_type` nil), so it is unsupported in both compilers, not a nelu-only divergence. Real feature gap, but no oracle baseline to match. |
| `plan/INBOX/cvarargs-parameter-emission.md` | STILL OPEN | Rank 14. `...: cvarargs` in a cimport function emits a stray `___` token. Blocks stringbuilder.nelua. |
| `plan/INBOX/dotted-global-c-emission.md` | STILL OPEN | Rank 15. Dotted `global X.Y` emits syntactically invalid C (literal `.` in the codename). Parse half DONE (`f75601a`); C half open. |
| `plan/DONE/global-function-c-emission.md` | CLOSED | Named top-level `global foo; function foo() ...` emitted a duplicate `nilptr` variable (`int64_t foo();` AND `static nilptr foo;`) → C `redeclared as different kind of symbol`. Not auto-specific (plain global fns break too); blocked auto-type-inference facets #5/#6. **Fixed 2026-09-06** (`413ad66`): skip the variable emission in the globals pass when the name resolves to a function (the function symbol overwrites the var symbol by name). Verified: `global foo; function foo() return 42` → `42` MATCH; `function foo(): auto return 42` → `42` MATCH (previously blocked); harness 0 regressions. |
| `plan/INBOX/check-source-location.md` | STILL OPEN | Rank 16. `check(false, msg)` omits the source location from the message (cosmetic). |
| `plan/INBOX/splice-env-locals.md` | SCOPE DONE (2026-09-06) | `##` splice blocks now see nelua-scope locals via `__nelua_scope` + positional injection. Verified: `## if v.type.is_cfloat then` works on both compilers, positional visibility matches, harness 0 regressions / 223 MATCH. **Verification (hash.nelua compiles) NOT met** -- blocked on `#|name|#`. |
| `plan/INBOX/preprocess-name-splice.md` | STILL OPEN | `#|expr|#` computed-identifier splice. Blocks hash/math/utf8/sequence/coroutine/string (7 lib files). Parser missing `.#|expr|#`; preprocessor consumes the node instead of evaluating it; analyzer never resolves it. |
| `plan/INBOX/lib-reachability-per-file.md` | scaffold | Sub-task scaffold: land `splice-env-locals`, re-scan the 21 `lib/*.nelua` files, give each still-failing one its own ticket. Baseline 0/21 compile. |

### WIP (active)

| Ticket | Status | Summary |
|---|---|---|
| `plan/WIP/stdlib-parity.md` | active | Stdlib / module-system parity push; compiles `lib/*.nelua` through Nelu. Part 1 = plan + phases, Part 2 = coverage survey, Part 3 = inheritance + two language gaps. |
| `plan/WIP/any-implementation-design.md` | Phase 1 green | `any` implementation; Phase 1 parity floor done, Phase 2 open. |

### DONE (completed)

| Ticket | Status | Summary |
|---|---|---|
| `plan/DONE/likely-unlikely-lowering.md` | CLOSED | Rank 13. `likely()`/`unlikely()` now lower to `__builtin_expect(cond, 1/0)` in `src/cgen.nim`; the analyzer returns `boolean` for hint calls and non-bool args are coerced to `true` (matching the oracle's `NELUA_LIKELY`/`NELUA_UNLIKELY`). Verified: probe MATCH oracle, harness `likely_branch`/`unlikely_loop` MATCH. heap.nelua's remaining blocker is a separate pre-existing analyzer SIGSEGV. |
| `plan/DONE/float32-print-suffix.md` | CLOSED | Rank 7. `float32` print drops the `.0` suffix on integral values. **Re-measured 2026-09-06: already fixed** (`1.0`/`1.5` MATCH the oracle on both compilers). Original probe used wrong syntax; closed as already-fixed, no code change. |
| `plan/DONE/union-field-access.md` | CLOSED | Rank 11. `@union` field access resolves to `any`. **Re-measured 2026-09-06: already works** (`@union{f: float32, i: uint32}` -> `1.5`/`1069547520` MATCH the oracle). Original probe used wrong `local union U {...}` syntax; closed as already-fixed, no code change. |
| `plan/DONE/enum-c-emission.md` | CLOSED | Rank 17. No C `enum` emitted for enum types. **Re-measured 2026-09-06: already works** (`@enum{...}` -> `2`/`1`/`2` MATCH the oracle over `enum_basic`/`enum_named`/`enum_arith`). Original probe used wrong `enum E {...}` syntax; closed as already-fixed, no code change. |
| `plan/DONE/comptime-string-eval.md` | CLOSED | Rank 12. `<comptime>` on a `string` global/local evaluates the string as a number. **Re-measured 2026-09-06: already fixed** (`global _VERSION: string <comptime> = "1.0"; print(_VERSION)` -> `1.0` MATCH the oracle). Closed as already-fixed, no code change. |
| `plan/DONE/three-declaration-divergences.md` | CLOSED | Undeclared-symbol diagnostics; all three divergences closed, 0 corpus cost. |
| `plan/DONE/record-pointer-resolution.md` | CLOSED | `*Record` resolves to `pointer(record)`, not `pointer(any)`; the §4.3 two-line fix was already in `src/analyzer.nim` (`analyzeFuncDef`), the §5 address-of consequence was already handled. Verified: tally went MATCH 4/FAIL 5 -> MATCH 11/FAIL 0 over `tmp/rpr/run.sh`. |
| `plan/DONE/locals-in-functions-bug.md` | CLOSED | Function-body `local` declarations were dropped by `genVarDecl`'s two-pass split. Fix landed at `cgen.nim:1788-1812` (declaration pass gated on `isGlobal`, zero-initialised, no `static`) plus the oracle's `global`-in-function rejection at `cgen.nim:1745`. Verified: probe1/probe2 (8 scope forms)/probe6 all MATCH the oracle. |
| `plan/DONE/uint-wrap.md` | CLOSED | Rank 5. Small-uint arithmetic: nelu wrapped (`200_u8 + 100_u8` -> `44`), the oracle promotes (`300`) or errors on assignment. **Fixed 2026-09-06**: removed the W2 small-uint wrap cast in the print dispatch (`src/cgen.nim`) and added `checkIntRange` in `src/analyzer.nim` (called from `analyzeVarDecl`) to emit the oracle's out-of-range diagnostic at assignment time. Verified: `print(200_u8 + 100_u8)` -> `300` MATCH, `local b: uint8 = 200 + 100` errors MATCH, harness 0 regressions (307 baseline). Exam probes `uintwrap_promote`/`neg_uintwrap_range`/`neg_uintwrap_range2` recorded. |
| `plan/DONE/preprocessor-driver-wiring.md` | CLOSED | Rank 4. `##` Lua statement blocks are not run by the default compile path. **Fixed 2026-09-06**: the seam landed in `analyze` (`src/analyzer.nim:2465-2477` runs `preprocess` right after `parse`), so every pipeline inherits preprocessing; `## x = 7` + `#[x]#` -> `7` MATCH. `compile.nim:10-16`'s comment is now stale (see `our-improvements.md` §4.2). Remaining open preprocessor item is the `#|expr|#` name splice (`plan/INBOX/preprocess-name-splice.md`). |
| `plan/DONE/undeclared-symbol-diagnostic.md` | CLOSED | Rank 9. Unknown identifiers resolve silently to `any`-typed externs. **Fixed 2026-09-06**: `print(undefned_symbol)` now emits `error: undeclared symbol 'undefned_symbol'` MATCH. The global-table data-driven refactor (`our-improvements.md` §4.1) is NOT done -- the table is still a hardcoded literal -- but is not required for the diagnostic. |
| `plan/DONE/function-literal-as-value.md` | CLOSED | Rank 6 (anonymous functions). `local f = function(x: integer): integer return x + 1 end; print(f(41))` -> `42` MATCH. **Fixed 2026-09-06**: `analyzeVarDecl` promotes an `nkFunction` literal to a named `nkFuncDef` with the binding's codename and types the local as its function type (`src/analyzer.nim`); `genVarDecl` skips the initializer assignment for a function-typed local whose init is a funcdef (`src/cgen.nim`). Verified: `fn_value`/`fn_multi`-style probes MATCH, harness 0 regressions (310 baseline). Known limitation: reassignment of a function literal (`f = function() end`) still fails -- that is the general closure feature (`plan/INBOX/closures-upvalues.md`), out of scope here. |
| `plan/DONE/emitter-segfaults-common-idioms.md` | CLOSED | Rank 6. C emitter SIGSEGVs on anonymous functions, method calls, and if/elseif chains. **Fixed 2026-09-06**: method calls (`cf:flip()` -> `true`) and if/elseif (`-> 2`) were already MATCH; anonymous functions in expression position landed via `plan/DONE/function-literal-as-value.md`. All three constructs now MATCH the oracle. `needsCompile` workaround (`main.nim:82-88`) may now be removable for the print-AST paths -- re-check before touching (it is the canary). |
| `plan/DONE/pattern-matching-implementation-design.md` | DONE | `switch`/`case`/`else` pattern matching implemented. |
| `plan/DONE/devil-advocate-findings.md` | ALL FIXED | Devil-advocate findings, all four fixed. |
| `plan/DONE/driver-segv-fixes.md` | DONE | Driver SIGSEGV fix for `(@*[0]byte)(e)`. |
| `plan/DONE/cstring_constness_fix.md` | RESEARCH | cstring const-ness gap; characterisation and minimal fix. |
| `plan/DONE/www_math_preprocess_fix.md` | RESEARCH | www_math SIGSEGV root cause and minimal fix. |
| `plan/DONE/pointer-printing-design.md` | DONE | Pointer printing design to match the oracle. |
| `plan/DONE/missing-cli-flags.md` | STALE | CLI flag gap list; superseded by the NOTE_backlog queue. |
| `plan/DONE/runtime-per-tu-inlining.md` | DONE | Runtime per-TU inlining + libm elimination; runtime helpers now static per-TU, `src/runtime.c` no longer linked, `-lm` conditional on `<math.h>`. |
| `plan/DONE/goto-label-statement.md` | CLOSED | Rank 1. `goto` + `::label:` now a statement: block-scoped label scope stack in `analyzer.nim`, `labelTarget` attr + shared C codename in `cgen.nim`. Verified: probe_goto/probe_goto2/pt_dup/pt_edge MATCH; harness `exam/goto_loop` DIFF -> MATCH. |
| `plan/DONE/byte-literal-suffix.md` | CLOSED | Rank 2. `'A'_b`/`"x"_u8`/`'A'_i8` lower to the char's ordinal as uint8/int8 (`analyzer.nim` `nkString` case + `cgen.nim` value emission). Verified: `print('A'_b)` -> 65, switch case values MATCH. |
| `plan/DONE/nasm-opportunities.md` | DONE | NASM opportunities assessment; grounded in the actual source with measurements; concluded. |
| `plan/DONE/analyzer-split-refactor.md` | CLOSED | Split `src/analyzer.nim` (128K / 3063 lines, the biggest source file) into 3 files for reading context: `analyzer_ctx.nim` (context + accessors), `analyzer_core.nim` (pure helpers), `analyzer.nim` (analysis core + dump + entry, kept whole because it is mutually recursive). Pure refactor, no behavior change. Verified: clean build, harness 0 regressions (219 MATCH). |
| `plan/DONE/self-field-assign-sigsegv.md` | CLOSED | Rank 3. `self.x = self.x * s` (binary-op RHS on a self-field lvalue) was reported to SIGSEGV `analyzeAssign`; re-verified 2026-09-05 on the live tree and it does NOT reproduce (colon-method form MATCHes oracle, 6/9; 43-file corpus sweep 0 exit-139). No fix applied -- the nil-guards in `analyzeDotIndex`/`cgen` already cover it. |
| `plan/DONE/multi-return-destructuring.md` | CLOSED | Rank 8. Multi-return destructuring: `local a, b = f()` binds each position, `print(f())` expands open calls, multi-return call in single-value position contributes only its first return. Fix in `analyzer.nim` (`expandedReturnTypes` + open-call return-type deduction) and `cgen.nim` (`genMultiRetFirst`, print-arg expansion). Verified: isolated probe MATCHes oracle; harness 0 regressions (304 baseline), `exam/fn_multi` new MATCH. |

## Not tickets (reference / design / tooling, live in `plan/` root)

- **Gate scripts (tooling):** `cmp.py`, `regress.py`, `examples_parity.py`,
  `cover_gate.py`, `cli_conformance.py`, `wwwcheck.py`.
- **Gate map / reference:** `GATES.md`, `repo-cruft-lineage.md`,
  `cover-corpus.md`, `lexer-parser-completeness.md`.
- **Language specs (reference):** `observed-language-spec.md`,
  `oracle-language-spec.md`.
- **Design specs (inputs to future tickets):** `traits-metaprogramming-survey.md`,
  `M2_design.md`, `M3_design.md`, `gate-m1-diffs-design.md`,
  `splice-design.md`, `splice-stage4-design.md`,
  `preprocessor-at-expr-design.md`, `splice_brainstorm.md`,
  `diagnostics_flags_blueprint.md`, `path_flags_blueprint.md`,
  `output_execution_blueprint.md`, `scratch-stage34-notes.md`,
  `tetrix-rotation-gaps.md`, `lib-after-splice-S03-coverage.md`,
  `survey-remaining-diffs.md`, `examples-diffs-triage.md`,
  `examples-diffs-design.md`.

If a design spec in the root becomes an active task, it moves to `WIP/` (or
`INBOX/` if not started) and this index is updated.