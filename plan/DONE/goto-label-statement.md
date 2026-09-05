# `goto` + `::label:` can now appear as a statement

**Status:** CLOSED -- fixed, verified against the oracle.  Rank 1 in
`plan/INBOX/our-improvements.md` §1.1 (Tier A, oracle-stdlib blocker).

## What was wrong

`parseBlock`/`parseSwitchBlock` `break` on `tkColonColon`, so `::label::` and
`goto` could not appear inside a block at all.

## Fix

Three files, all in `src/`:

- `src/types.nim` -- added `labelTarget*: Node` to `Attr` (the resolved `nkLabel`
  node a `goto` jumps to; cgen shares one C codename between the label site and
  every goto that targets it).
- `src/analyzer.nim` -- a separate block-scoped label scope stack
  (`labelScopes` + `pushLabelScope`/`popLabelScope`/`registerLabel`/
  `lookupLabel`), kept isolated from the symbol scopes so variable scoping is
  untouched. `analyzeBlock` runs a label pre-pass (registering every direct
  child `::label::` before analyzing any statement) so forward gotos resolve;
  `analyzeStmt` resolves `nkGoto` to its target and reports "no visible label"
  and duplicate-label diagnostics matching the oracle.
- `src/cgen.nim` -- `labelCodename` lazily assigns a unique C identifier to a
  label node (stored on the node's Attr so the label and its gotos agree);
  `genStmt` emits `nlbl_N:` for `nkLabel` and `goto nlbl_N;` for `nkGoto`.

Label semantics match the oracle: block-scoped (a label in a loop body is not
visible outside it), forward gotos allowed, gotos out of a nested block to an
outer label allowed, duplicate labels in one block rejected.

## Verification

- `probe_goto`, `probe_goto2`, `pt_dup`, `pt_edge` all MATCH the oracle
  (output and exit code), including a goto across a nested-block boundary and
  multiple gotos to one label.
- Conformance harness: 0 regressions, **1 improvement** (`exam/goto_loop`
  DIFF -> MATCH).
- The diagnostic case (`probe_goto_sem`) reports the same error text as the
  oracle; ours additionally reports the second error the oracle stops at
  (both exit 1).

## What fails

A label statement (`::name::`) is never reachable: `parseBlock` and
`parseSwitchBlock` both `break` as soon as they see `tkColonColon`, so the label
is left overrunning the program and every `goto`-using file fails to parse.

| code | oracle | ours |
|---|---|---|
| `::done::\n  return\ngoto done` | parses, prints `5` | `unexpected token after end of program` |

## Why it matters

`goto` is in five oracle-stdlib files with no workaround:
`lib/stringbuilder.nelua` (7× `goto next`), `lib/string.nelua` (`goto next`),
`lib/allocators/heap.nelua` (2× `goto found_free_node`),
`examples/brainfuck.nelua` (`goto #|target.after|#` splice labels),
`examples/overview.nelua` (`goto getout`).  This is the single construct in the
most oracle-stdlib files.  Rank 1 for that reason.

## Root cause (precise)

The node kinds and the keyword are **already present** -- `astshapes.nim:64-65`
declares `nkLabel`/`nkGoto`, and `parser.nim`'s `parseStatement` already handles
the `goto` keyword and `::name::` token (`tkColonColon` -> `newLabel`).  The gap
is purely the block parser:

```
src/parser.nim:603   if t.kind == tkColonColon: break      # parseBlock
src/parser.nim:631   if t.kind == tkColonColon: break      # parseSwitchBlock
```

A label is therefore never reachable as a statement: the block parser exits
before `parseStatement` is ever called.  Labels are scope-managed by the
analyzer, which already has the machinery.

## Recommended fix (bounded)

Remove those two `break` lines and let `parseStatement`'s existing
`tkColonColon` branch handle labels.  Two-line change, no AST or keyword-table
edit.

**Do not do:** do not add `nkGoto`/`nkLabel` to the AST or `goto`/`::` to the
keyword table -- both already exist.

## Verification

- `tmp/probe_goto.nelua` (label + goto) prints `5`, exit 0, matching the oracle.
- `--print-analyzed-ast` shows a `Label`/`Goto` node, not a parse error.
- Re-scan the five affected `lib/`/`examples/` files: they must parse past the
  `goto` sites (they will still fail later on other blockers; report the new
  first error, do not claim the file is fixed).