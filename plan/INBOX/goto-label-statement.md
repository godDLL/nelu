# `goto` + `::label:` cannot appear as a statement

**Status:** INBOX -- confirmed divergence, no fix.  Rank 1 in
`plan/INBOX/our-improvements.md` §1.1 (Tier A, oracle-stdlib blocker).

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