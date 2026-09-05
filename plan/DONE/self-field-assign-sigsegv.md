# `self.x = self.x * s` (binary-op RHS on a self-field lvalue) SIGSEGVs

**Status:** CLOSED -- re-verified 2026-09-05; the described SIGSEGV does not reproduce in the current tree, no fix applied
in the current tree.  Rank 3 in `plan/INBOX/our-improvements.md` §2.1.

## What fails (as originally reported)

An assignment whose LHS is a `self`-field and whose RHS is a **binary** op was
reported to SIGSEGV our compiler (exit 139), with the oracle printing `6`.

| code | oracle | ours (now) |
|---|---|---|
| `local function m(self) self.x = self.x * 2; return self.x end` | rejects: "compiler deduced type 'any'" (exit 1) | C compile error on `nlany.x` (exit 1) |

Note: the literal probe in the original report is not oracle-valid -- the oracle
itself rejects the untyped `self` when the function is referenced.  The idiom the
report points at is the colon-method form, which is
`examples/www/recmethod_mutate.nelua`.

## Re-verification (2026-09-05, copy `tmp/2026-09-05-1829-self-field-assign-sigsegv/`)

Built with `nim c -d:release --path:src -o:tmp/nelua src/main.nim` (same flags as
the live tree).  No source changes were made; the copy's `src/` is byte-identical
to the live `src/`.

| probe | oracle | ours | MATCH |
|---|---|---|---|
| `tmp/probe_selfassign.nelua` (colon method `R:scale`, `self.x = self.x * 2`) | `6`, exit 0 | `6`, exit 0 | yes |
| `examples/www/recmethod_mutate.nelua` | `6 8` / `10 10`, exit 0 | `6 8` / `10 10`, exit 0 | yes |
| `self.x = self.x * self.x` (binary RHS, self-field) | `9 4`, exit 0 | `9 4`, exit 0 | yes |
| `self.x = -self.x` (unary RHS) | `-3 4`, exit 0 | `-3 4`, exit 0 | yes |
| `self.arr[i] = self.arr[i] * 2` (nkKeyIndex LHS) | `6 4`, exit 0 | `6 4`, exit 0 | yes |
| `--print-ast` on both probes | exit 0 | exit 0 | yes |
| `--print-analyzed-ast` on both probes | exit 0 | exit 0 | yes |

Corpus sweep: all 43 `.nelua` under `examples/`+`tests/` compiled with exit-139
count = 0; the same 43 run through `--print-analyzed-ast` also produced zero
exit-139s.

## Why no fix was needed

The root cause as described -- "type inference for the indexed LHS returns nil
and a later deref segfaults" -- is already guarded in the current tree:

- `analyzeDotIndex` (`src/analyzer.nim:419`) never returns nil: every base-type
  branch is guarded by `bt != nil` and the fallthrough is
  `if a.typ == nil: a.typ = BuiltinTypes["any"]` (present since the M2
  foundation, commit `01102d1e`).
- `analyzeAssign` (`src/analyzer.nim:1688`) non-`nkId` targets go to
  `discard analyzeExpr(ctx, t)`; there is no `calleeType`/operand-type deref in
  `analyzeAssign` at all, so the recommended one-line guard has nothing to wrap.
- `cgen.realType`/`cgen.coerce` both nil-guard their type arguments
  (`if fromT == nil or toT == nil: return expr`), so a nil target type degrades
  to an uncoerced assignment rather than segfaulting.

The `analyzeCall` nil-guard the report cites as a partial fix
(`if calleeType != nil and calleeType.returns.len >= 1`) is on a different path
and was never relevant to this assignment bug.

## Action

Close the ticket.  The recommended fix is a no-op on the current tree; applying
it would be churn (AGENT.md §3.5).  The ticket's literal probe should be rewritten
to give `self` a known type (colon method or typed param) to be oracle-valid.

## Why it matters

A mutate-a-field-with-a-computed-value idiom.  Rank 3: highest-rank crash that is
a bounded fix.

## Root cause (precise)

`analyzeAssign` (`src/analyzer.nim:1844`) handles `nkId` targets but sends
`nkDotIndex`/`nkIndex` targets (like `self.x`) to the generic
`analyzeExpr(ctx, t)` path.  When the RHS is a binary op, type inference for the
indexed LHS returns nil and a later deref segfaults.

**Partial fix already landed.** The live `src/analyzer.nim` `analyzeCall` adds a
nil-guard for the `nkDotIndex` *caller* branch (`if calleeType != nil and
calleeType.returns.len >= 1`), which stops the static-method-call crash.  That is
a *different* path from the assignment path in `analyzeAssign` and does not fix
this bug.

## Recommended fix (bounded)

One-line guard around the `calleeType`/operand-type deref in `analyzeAssign`,
mirroring the guard just landed in `analyzeCall`.  Also make the print-AST paths
degrade gracefully instead of crashing (see `plan/INBOX/emitter-segfaults-common-idioms.md`).

## Verification

- `tmp/probe_selfassign.nelua` prints `6`, exit 0, matching the oracle.
- `examples/www/recmethod_mutate.nelua` no longer SIGSEGVs.
- `--print-analyzed-ast` on both must not crash.