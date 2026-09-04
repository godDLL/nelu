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

### WIP (active)

| Ticket | Status | Summary |
|---|---|---|
| `plan/WIP/stdlib-parity.md` | active | Stdlib / module-system parity push; compiles `lib/*.nelua` through Nelu. Part 1 = plan + phases, Part 2 = coverage survey, Part 3 = inheritance + two language gaps. |
| `plan/WIP/locals-in-functions-bug.md` | diagnostic | Task 1: locals-in-functions characterisation; reproduced, no fix. |
| `plan/WIP/any-implementation-design.md` | Phase 1 green | `any` implementation; Phase 1 parity floor done, Phase 2 open. |
| `plan/WIP/record-pointer-resolution.md` | WIP | `*Record` resolves to `pointer(any)` instead of `pointer(record)`; minimal fix prototyped and verified on a throwaway copy but NOT applied to live `src/`. Integrate it. |

### DONE (completed)

| Ticket | Status | Summary |
|---|---|---|
| `plan/DONE/three-declaration-divergences.md` | CLOSED | Undeclared-symbol diagnostics; all three divergences closed, 0 corpus cost. |
| `plan/DONE/pattern-matching-implementation-design.md` | DONE | `switch`/`case`/`else` pattern matching implemented. |
| `plan/DONE/devil-advocate-findings.md` | ALL FIXED | Devil-advocate findings, all four fixed. |
| `plan/DONE/driver-segv-fixes.md` | DONE | Driver SIGSEGV fix for `(@*[0]byte)(e)`. |
| `plan/DONE/cstring_constness_fix.md` | RESEARCH | cstring const-ness gap; characterisation and minimal fix. |
| `plan/DONE/www_math_preprocess_fix.md` | RESEARCH | www_math SIGSEGV root cause and minimal fix. |
| `plan/DONE/pointer-printing-design.md` | DONE | Pointer printing design to match the oracle. |
| `plan/DONE/missing-cli-flags.md` | STALE | CLI flag gap list; superseded by the NOTE_backlog queue. |
| `plan/DONE/runtime-per-tu-inlining.md` | DONE | Runtime per-TU inlining + libm elimination; runtime helpers now static per-TU, `src/runtime.c` no longer linked, `-lm` conditional on `<math.h>`. |
| `plan/DONE/nasm-opportunities.md` | DONE | NASM opportunities assessment; grounded in the actual source with measurements; concluded. |

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