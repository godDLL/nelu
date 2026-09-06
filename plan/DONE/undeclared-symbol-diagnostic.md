# Unknown identifiers resolve silently to `any`-typed externs with no diagnostic

**Status:** CLOSED -- implemented and verified against the oracle.  Rank 9 in
`plan/INBOX/our-improvements.md` §2.7 (Tier B, maintainability).

## What failed (re-measured 2026-09-06, both compilers live)

| code | oracle | ours (before) | ours (now) |
|---|---|---|---|
| `print(undefned_symbol)` | `undeclared symbol 'undefned_symbol'` | compiles, links to nothing | `undeclared symbol 'undefned_symbol'` MATCH |

The silent-`any`-extern fallthrough is gone: an identifier that resolves to
neither a scope symbol nor a registered builtin now emits the diagnostic
instead of becoming an external C symbol.

## Fix (bounded)

The recommended fix was part (b) -- add a diagnostic for identifiers that
resolve to neither a scope symbol nor an entry in the global table.  It
landed unconditional (matching the oracle, which also rejects unconditionally)
rather than behind a `strictGlobals` flag; the Lua-implicit-global caveat in
the ticket's recommended fix did not apply to the corpus.  Part (a), the
data-driven global-table refactor (`our-improvements.md` §4.1, rank 22), is
**not** done -- the table is still a hardcoded literal.  That is a separate
refactor ticket and is not required for the diagnostic to work.

## Verification

- `tmp/probe_undef.nelua`: `print(undefned_symbol)` emits
  `error: undeclared symbol 'undefned_symbol'`, matching the oracle's message
  shape; both fail the build the same way (MATCH).
- Recorded in `plan/harness_baseline.json` as `exam/neg_undeclared_symbol` ->
  MATCH (both compilers fail the build).

## Notes

- The diagnostic is unconditional.  If a future corpus case relies on
  Lua-style implicit globals (an undeclared identifier resolving to a runtime
  `nil` global), that case would now break -- re-measure before relying on
  this.  So far the corpus has no such case.