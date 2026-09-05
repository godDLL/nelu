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
| `plan/INBOX/closures-upvalues.md` | design spec | Closure / upvalue scoping beyond 0.2.0; design doc for the implementation agent, nothing implemented. |
| `plan/INBOX/exceptions-implementation.md` | design spec | Exceptions implementation design; not started. Companion `plan/INBOX/exceptions-oracle-behavior.md`. |
| `plan/INBOX/exceptions-oracle-behavior.md` | reference | Oracle exception behavior reference; companion to `plan/INBOX/exceptions-implementation.md`. |
| `plan/INBOX/c-pointer-array-lowering.md` | design spec | Pointer / array / record C-lowering spec; the pointer-to-array emission blocker is not fixed in `src/`. |
| `plan/INBOX/multi-return-destructuring.md` | STILL OPEN | Multi-return destructuring broken: `local a, b = f()` leaves trailing bindings nil, `print(f())` drops extras. Caught by `exam/fn_multi`. |
| `plan/INBOX/self-field-assign-sigsegv.md` | STILL OPEN | Rank 3. `self.x = self.x * s` (binary-op RHS on a self-field lvalue) SIGSEGVs in `analyzeAssign` (`analyzer.nim:1844`). recmethod_mutate.nelua. |
| `plan/INBOX/preprocessor-driver-wiring.md` | STILL OPEN | Rank 4. `##` Lua statement blocks are not run by the default compile path (`compile.nim:10-16`). Long-bracket parsing DONE (`f75601a`); driver half open. |
| `plan/INBOX/uint-wrap.md` | STILL OPEN | Rank 5. Small-uint arithmetic does not wrap: `200_u8 + 100_u8` prints `300`, oracle `44`. uint8_wrap.nelua. |
| `plan/INBOX/emitter-segfaults-common-idioms.md` | STILL OPEN | Rank 6. C emitter SIGSEGVs on anonymous functions, method calls, and if/elseif chains. `needsCompile` workaround persists (`main.nim:82-88`). |
| `plan/INBOX/float32-print-suffix.md` | STILL OPEN | Rank 7. `float32` print drops the `.0` suffix on integral values (`cgen.nim:180-184`). float32_easing.nelua. |
| `plan/INBOX/genforin-multi-value.md` | STILL OPEN | Rank 8. `genForIn` supports only a single array iterable; `for k, v in array` unsupported. |
| `plan/INBOX/undeclared-symbol-diagnostic.md` | STILL OPEN | Rank 9. Unknown identifiers resolve silently to `any`-typed externs with no diagnostic. Global table refactor (§4.1) folded in. |
| `plan/INBOX/union-field-access.md` | STILL OPEN | Rank 11. `@union` field access resolves to `any`: `analyzeDotIndex` has no `tkUnion` branch (`analyzer.nim` ~717-755). |
| `plan/INBOX/comptime-string-eval.md` | STILL OPEN | Rank 12. `<comptime>` on a `string` global/local evaluates the string as a number. Blocks builtins.nelua, utf8.nelua, stringbuilder.nelua. |
| `plan/INBOX/likely-unlikely-lowering.md` | STILL OPEN | Rank 13. `likely()`/`unlikely()` builtins not lowered to C (no `__builtin_expect`). Blocks heap.nelua. |
| `plan/INBOX/cvarargs-parameter-emission.md` | STILL OPEN | Rank 14. `...: cvarargs` in a cimport function emits a stray `___` token. Blocks stringbuilder.nelua. |
| `plan/INBOX/dotted-global-c-emission.md` | STILL OPEN | Rank 15. Dotted `global X.Y` emits syntactically invalid C (literal `.` in the codename). Parse half DONE (`f75601a`); C half open. |
| `plan/INBOX/check-source-location.md` | STILL OPEN | Rank 16. `check(false, msg)` omits the source location from the message (cosmetic). |
| `plan/INBOX/enum-c-emission.md` | STILL OPEN | Rank 17. No C `enum` emitted for enum types (`cgen_types.cType` returns only `cTag(t)`). Unblocks type-safe `switch`. |
| `plan/INBOX/splice-env-locals.md` | STILL OPEN | Core `lib/` blocker. `##` splice blocks cannot see nelua-scope locals (`## if v.type.is_cfloat then` fails with `global 'v'`). Natural extension of the `ec60323` scope machinery in `src/preprocessor.nim`. Unblocks hash.nelua. |
| `plan/INBOX/lib-reachability-per-file.md` | scaffold | Sub-task scaffold: land `splice-env-locals`, re-scan the 21 `lib/*.nelua` files, give each still-failing one its own ticket. Baseline 0/21 compile. |

### WIP (active)

| Ticket | Status | Summary |
|---|---|---|
| `plan/WIP/stdlib-parity.md` | active | Stdlib / module-system parity push; compiles `lib/*.nelua` through Nelu. Part 1 = plan + phases, Part 2 = coverage survey, Part 3 = inheritance + two language gaps. |
| `plan/WIP/any-implementation-design.md` | Phase 1 green | `any` implementation; Phase 1 parity floor done, Phase 2 open. |

### DONE (completed)

| Ticket | Status | Summary |
|---|---|---|
| `plan/DONE/three-declaration-divergences.md` | CLOSED | Undeclared-symbol diagnostics; all three divergences closed, 0 corpus cost. |
| `plan/DONE/record-pointer-resolution.md` | CLOSED | `*Record` resolves to `pointer(record)`, not `pointer(any)`; the §4.3 two-line fix was already in `src/analyzer.nim` (`analyzeFuncDef`), the §5 address-of consequence was already handled. Verified: tally went MATCH 4/FAIL 5 -> MATCH 11/FAIL 0 over `tmp/rpr/run.sh`. |
| `plan/DONE/locals-in-functions-bug.md` | CLOSED | Function-body `local` declarations were dropped by `genVarDecl`'s two-pass split. Fix landed at `cgen.nim:1788-1812` (declaration pass gated on `isGlobal`, zero-initialised, no `static`) plus the oracle's `global`-in-function rejection at `cgen.nim:1745`. Verified: probe1/probe2 (8 scope forms)/probe6 all MATCH the oracle. |
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