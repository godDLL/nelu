# C emitter SIGSEGVs on anonymous functions, method calls, and if/elseif chains

**Status:** INBOX -- reproduced, no fix.  Rank 6 in
`plan/INBOX/our-improvements.md` §2.5 (Tier B, corpus-wide).

## What fails

The C emitter SIGSEGVs at codegen on three common constructs:

| code | oracle | ours |
|---|---|---|
| `local f = function(x: integer): integer ... end; print(f(41))` | `41` | SIGSEGV at codegen |
| a method call `r:add(10)` | `13` | SIGSEGV |
| `if a then ... elseif b then ... else ... end` | correct | SIGSEGV |

`main.nim:82-88` still sets `needsCompile = false` for `--print-ast` /
`--print-analyzed-ast` / `--analyze` / `--print-ppcode` with the comment "the
emitter segfaults on valid constructs (method calls, anonymous functions,
if/elseif)".  That flag is the canary -- do not remove it until (b) below is done.

## Why it matters

Method calls and anonymous functions are core to the closures/upvalues work already
landed in this tree.  An emitter that segfaults on them means a large fraction of
the corpus cannot be compiled to a binary, and the print-AST paths never validate
the analyzer against actual emission.

**Oracle cross-read.** The oracle's C generator is a visitor table
(`cgenerator.visitors`) that handles all statement and expression nodes without
crashing.  The constructs are emittable; ours has a genuine bug.

## Recommended fix (bounded, two parts)

- **(a) Make the print-AST paths degrade gracefully.** Catch the segfault path and
  emit a diagnostic instead of crashing.  Cheap; immediately stops corrupting the
  terminal.
- **(b) Fix `genC` for the three named constructs.** Method calls lower to
  `nkDotIndex` + `nkCall`; anonymous functions lower to `nkFuncDef` in expression
  position; if/elseif lowers to nested `nkIf`.  Each is a bounded change in
  `cgen.nim`'s `genExpr`/`genCall`/`genStmt` dispatch.  Order of risk: start with
  if/elseif (pure structural), then method calls (the `self` parameter is already
  injected by `analyzeFuncDef`), then closures (the upvalue environment is already
  landed).

## Verification

- All three constructs above compile and print the oracle's output, exit 0.
- `--print-analyzed-ast` on a method call and an anonymous function no longer
  SIGSEGVs (this is what currently forces `needsCompile = false`).
- `plan/harness.py`: 0 regressions on the cases that already MATCH.