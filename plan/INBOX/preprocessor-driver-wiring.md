# `##` Lua statement blocks are not run by the compile driver

**Status:** INBOX -- the driver wiring is STILL OPEN; the long-bracket parsing is
DONE (committed `f75601a`).  Rank 4 in
`plan/INBOX/our-improvements.md` §2.4 (Tier A/B, preprocessor blocker).

## What fails

The preprocessor is built and tested through `runM6Pipeline` but is **not** run by
the default compile path.  A normal `nelua file.nelua` never invokes it.

| code | oracle | ours |
|---|---|---|
| `## x = 7` then `#[x]#` | `7` | `0` (the splice-ident resolves to the preprocessor's own `x`, which is unset) |

`examples/www/splice_embed.nelua` DIFFs identically, and
`examples/brainfuck.nelua` (which uses `##[=[ ... ]=]` for its source string) cannot
run correctly.

## What is already fixed in the live tree (committed `f75601a`)

The long-bracket form `##[=[ ... ]=]` is now parsed: `parser.nim`
`stripLongBrackets` + `parsePreprocess` flags a self-contained block
(`boolVal = true`), and `preprocessor.nim` runs it as a standalone chunk instead
of subjecting it to `luaBlockDelta` framing.  That is the *parsing* half.  The
*driver* half is unchanged -- this ticket is that half.

## Root cause (precise)

`compile.nim:10-16` documents backlog item C3: only the analyze/print-ppcode paths
run the preprocessor.

## Recommended fix (bounded)

Wire the existing preprocessor into the `analyze` entry point right after `parse`,
exactly as our own backlog note (`NOTE_backlog.md`) already specifies.  One-call
integration.  **Do not** replicate the oracle's gradual, scope-aware, hygienic
architecture (see the `[S4-8]` note in `our-improvements.md`) -- our separate-pass
preprocessor is a legitimate, simpler design.  The honest, documented limitation is
that our `##` blocks can only use the registered builtins and the seeded
`primtypes`/`typedefs` globals; they cannot read source-level variables or
inferred types, unlike the oracle (`ppcontext.lua:48`).  Document that gap
explicitly.  (The related but distinct "`##` blocks must see nelua-scope locals"
gap is `plan/INBOX/splice-env-locals.md` -- that is a separate ticket.)

## Verification

- `tmp/probe_pp.nelua`: `## x = 7` + `#[x]#` prints `7`, exit 0, matching the oracle.
- `examples/www/splice_embed.nelua` goes DIFF -> MATCH.
- `examples/brainfuck.nelua` runs correctly.
- The long-bracket parsing committed at `f75601a` still works (no regression).