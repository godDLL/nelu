# Split `src/analyzer.nim` into 3 files

**Status:** CLOSED -- implemented and verified against the oracle.  Motivation
is **reading context**, not performance: `src/analyzer.nim` was the largest
source file in the project (128K, 3063 lines) and the whole thing loaded into
context whenever the analyzer was in scope.

## Resulting structure (measured)

| File | Lines | Contents |
|---|---|---|
| `src/analyzer_ctx.nim` | 152 | `DumpInfo`, `AnalyzerContext`, `AnalyzerResult`, `computeUnitname`, `newScope`, `getUpFunctionScope`, the four label-scope helpers, `register`, `lookup`, `getAttr`, `getDump`, `hash`. |
| `src/analyzer_core.nim` | 464 | type string renderer (`neluaTypeName`, `returnsStr`), builtin/recognized-name tables, `bootstrap`, literal typing, constant folding, and the `require` pure helpers (`findRequires`, `resolveModule`, `importSymbols`). |
| `src/analyzer.nim` | 2467 (was 3063) | the mutually-recursive analysis core + dump + entry point + the D2 require-resolution workhorse (`analyzeModule`, `analyze`). Imports and re-exports the other two. |

The estimates in the original ticket were ~230 / ~280 / ~2550; the measured
values land in the same ballpark (analyzer_core came in larger because the
literal-typing and constant-folding sections are denser than the header
suggests).

## Why it could not be a free-for-all split

`AnalyzerContext` and `DumpInfo` were defined *inside* `analyzer.nim`, so every
split file needs them in a shared module.  Worse, the
expression/statement/monomorphization sections are **mutually recursive**:
the forward-declaration block declares 16 procs whose real definitions are
scattered across the analysis sections (e.g. `dumpAnaled` is forward-declared
and defined much later; `dumpExprString` is called from `analyzeForNum` but
defined in the dump section).  Nim has no cross-module forward declaration, so
that whole cluster must live in **one** module.

## How it was done (two passes)

### Pass 1 -- context + pure helpers (the original 3-file split)


A **pure refactor**: no proc changes, no behavior changes, no signature
changes.  The mechanical edits were:

- `analyzer_ctx.nim` (new): sections 2-6 and 15 of the original moved verbatim,
  with `*` added to the procs the analysis core needs to call
  (`getUpFunctionScope`, `pushLabelScope`, `popLabelScope`, `registerLabel`,
  `lookupLabel`, `getDump`, `hash`).  Imports `ast`, `types`, `sema`, `tables`,
  `hashes`, `os`, `strutils`.
- `analyzer_core.nim` (new): sections 7-11 moved verbatim, with `*` added to the
  procs the analysis core needs (`splitNumberSuffix`, `numberTypeAndValue`,
  `stripQuotes`, `valueQuoteKind`, `floorDiv`, `arithShr`, `tryFoldBinary`,
  `tryFoldUnary`, `isComptime`).  Imports `ast`, `types`, `sema`, `tables`,
  `sequtils`, `strutils`, `math`, `analyzer_ctx`.
- `analyzer.nim`: sections 1 (header) and 12-18 kept; sections 2-11 deleted;
  `import analyzer_ctx`, `import analyzer_core`, `export analyzer_ctx`,
  `export analyzer_core` added.  The `hash` proc moved to `analyzer_ctx`
  (it is needed by the `Table[Node, ..]` accessors there).

Two procs (`binaryOpName`, `unaryOpName`) were *not* moved out of the original:
they are already duplicated in `parser.nim`, which `analyzer.nim` imports, so
`analyzer.nim` uses `parser`'s copies and the `analyzer_core` copies were
deleted rather than shipped a third time.

The only ripple into other files was import-driven: `analyzer_ctx.nim` had to
gain `os`, `strutils`, `hashes` and `analyzer_core.nim` had to gain `sequtils`,
`strutils`, `math` (the originals got these from `analyzer.nim`'s import list).
No `types.nim`, `cgen.nim`, `main.nim`, or `compile.nim` changes were needed in either pass.

### Pass 2 -- the `require` pure helpers

`findRequires`, `resolveModule`, and `importSymbols` are leaf-ish: they touch
only the AST, `Config`, the file system, and `AnalyzerContext`/`Symbol`, and
make **no** call into the analysis core.  The whole D2 section was surveyed
first (see "Why the require workhorse was not split out" below); only these
three pure helpers could move without an import cycle or caller edits.

- Moved verbatim into `analyzer_core.nim` (which already imports
  `analyzer_ctx`, so it has `AnalyzerContext`/`Symbol`), with `import os` and
  `import config` added.  `importSymbols` gained a `*` (it was internal-only
  in the original, but `analyzer.nim`'s `analyzeModule` now calls it across
  the module boundary).
- Deleted from `analyzer.nim`; `analyzeModule`/`analyze`/`runM6Pipeline` stay
  put because they call `analyzeBlock`/`finalize`/`bootstrap`, so they depend
  on `analyzer.nim` and cannot leave without a cycle.

## Why the require workhorse was not split out

`analyzeModule`, `analyze`, and `runM6Pipeline` call *into* the core (`analyzeBlock`, `finalize`, `bootstrap`, `countAssignTargets`, `getAttr`, `computeUnitname`), so they depend on `analyzer.nim`.  The core makes **no** call back into them (verified by grep over sections 12-16), so the dependency is one-way -- but two things still block moving them:

1. `analyze*` is the public API, consumed as `analyze(...)` unqualified in    `cgen.nim:2316` and `analyzer.analyze(...)` qualified in `main.nim:285,342`,    both via `import analyzer`.  Moving it forces either a re-export (which    requires `analyzer.nim` to import the new module -> **cycle**) or edits to    `cgen.nim` and `main.nim`.
2. `runM6Pipeline` is called only from `analyzer.nim`'s own `when isMainModule`    self-test (lines 2467-2509), so it cannot leave without `analyzer.nim`    importing the new module -> again a cycle.

The three helpers moved in Pass 2 are ~78 lines (3.1% of the file); the whole D2 section is ~152 lines (6.0%).  The workhorse stays for the reasons above.

## Acceptance bar -- all met

- `nim c -d:release --path:src -o:tmp/nelua src/main.nim` builds clean.
- Conformance harness: **0 regressions**, 219 MATCH, 304 baseline entries.
  One improvement: `exam/goto_loop` DIFF -> MATCH (carried over from the goto
  ticket; the split itself changed nothing).
- Proc-level check: all 91 top-level procs of the original `analyzer.nim` are
  present after the split (89 in the three new files; `binaryOpName` and
  `unaryOpName` in `parser.nim`, which already had them).  The 17 textual diffs
  between original and new are exactly: 17 added `*` export markers (16 in
  Pass 1, plus `importSymbols` in Pass 2 -- all required so `analyzer.nim` can
  call the moved procs across the module boundary), two of which also dropped a
  trailing blank line (`getDump`, `isComptime`).  No logic changes.

## Verification

Same as the acceptance bar.  Measured on the integrated live tree:

```
TOTAL  9 BOTH_FAIL  2 DIFF  219 MATCH  4 NELU_ACCEPT  15 NELU_CRASH
       40 NELU_REJECT  14 ORACLE_FAIL  1 SKIP
baseline entries: 304   regressions: 0   improvements: 1   new: 0
OK: no regression.
```