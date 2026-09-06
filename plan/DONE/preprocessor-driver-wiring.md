# `##` Lua statement blocks are not run by the compile driver

**Status:** CLOSED -- implemented and verified against the oracle.  Rank 4 in
`plan/INBOX/our-improvements.md` §2.4 (Tier A/B, preprocessor blocker).
Superseded in the board by `plan/INBOX/preprocess-name-splice.md` for the
remaining `#|expr|#` name-splice gap.

## What failed (re-measured 2026-09-06, both compilers live)

| code | oracle | ours (before) | ours (now) |
|---|---|---|---|
| `## x = 7` then `#[x]#` | `7` | `0` | `7` MATCH |

The driver wiring is done.  The remaining preprocessor gap is the `#|expr|#`
*name* splice (`PreprocessName`), a different node from the `#[expr]#`
expression splice that works; see `plan/INBOX/preprocess-name-splice.md`.

## Fix (bounded)

The recommended fix was to wire the existing preprocessor into the `analyze`
entry point right after `parse`, exactly as `NOTE_backlog.md` already
specified.  That seam landed: `src/analyzer.nim:2465-2477` runs
`preprocess(ast, pctx)` over the parse tree as part of `analyze`, so every
pipeline -- including the default `compile` driver -- inherits preprocessing
with no signature change.

## Verification

- `tmp/probe_pp.nelua`: `## x = 7` + `#[x]#` prints `7`, exit 0, matching the oracle.
- `examples/www/splice_embed.nelua` goes DIFF -> MATCH.
- `examples/brainfuck.nelua` runs correctly.
- The long-bracket parsing committed at `f75601a` still works (no regression).

## Notes

- `src/compile.nim:10-16`'s comment still says preprocessing is "NOT folded into
  this driver yet" and cites backlog C3.  That comment is now stale -- the seam
  it describes is landed.  Aligning it is `plan/INBOX/our-improvements.md`
  §4.2 (trivial).  Do not re-wire; the preprocessor is active.
- The documented limitation still holds: our `##` blocks can only use the
  registered builtins and the seeded `primtypes`/`typedefs` globals; they
  cannot read source-level variables or inferred types, unlike the oracle
  (`ppcontext.lua:48`).