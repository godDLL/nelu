# `self.x = self.x * s` (binary-op RHS on a self-field lvalue) SIGSEGVs

**Status:** INBOX -- reproduced, no fix.  Rank 3 in
`plan/INBOX/our-improvements.md` §2.1 (Tier B, common-idiom crash).

## What fails

An assignment whose LHS is a `self`-field and whose RHS is a **binary** op SIGSEGVs
our compiler (exit 139).  The oracle prints `6`.

| code | oracle | ours |
|---|---|---|
| `local function m(self) self.x = self.x * 2; return self.x end` | `6` | SIGSEGV (exit 139) |

Narrowed: `self.x = -self.x` (unary RHS) matches; only the binary RHS crashes.
Plain local `x = x * 2` matches.  The exact pattern is in
`examples/www/recmethod_mutate.nelua`, which also SIGSEGVs.

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