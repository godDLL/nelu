# Dotted `global X.Y` declarations emit syntactically invalid C

**Status:** INBOX -- the parse half is DONE (committed `f75601a`); the C-emission
half is STILL OPEN.  Rank 15 in `plan/INBOX/our-improvements.md` §3.6 (Tier C).

## What fails

The parse half now succeeds, but the C emitter keeps the literal `.` in the
global-decl codename, producing syntactically invalid C.

| code | oracle | ours |
|---|---|---|
| `global Rect.field: integer = 5` | `undeclared symbol 'Rect'` (rejects) | `static int64_t h1_dotted_Rect.field;` -- gcc chokes on the `.` |

The clean finding is "ours accepts and emits invalid C", not a runtime divergence:
the oracle rejects the bare form, so the parity-consistent behaviour is to reject
`global X.Y` too.

## What is already fixed (committed `f75601a`)

`src/parser.nim` `parseIdDecl` now builds a dot-index chain for dotted declaration
names and records the full dotted string on the node.  So parsing
`global Rect.field: integer = 5` now succeeds.  This ticket is the C-emission half.

## Root cause (precise)

`cemitter.cIdent` sanitizes identifiers but the global-declaration codename path
does not sanitize `.` in dotted names; the emitted C keeps the literal `.`.

## Recommended fix (bounded, two options, pick one)

- **Sanitize path:** sanitize `.` (and any other non-identifier character) to `_`
  when emitting a global-decl codename, reusing `cIdent`'s logic.
- **Diagnostic path (matches the oracle):** since the oracle rejects the bare form,
  emit a diagnostic for `global X.Y` rather than accepting and lowering it.

Either path is bounded; the diagnostic path matches the oracle.

## Verification

- `tmp/probe_dottedglobal.nelua`: either prints the oracle's rejection, or emits
  valid C and runs; either way, exit code and output match the oracle.
- Dotted *method-call* names (a different construct) still work.