# Unknown identifiers resolve silently to `any`-typed externs with no diagnostic

**Status:** INBOX -- confirmed gap, no fix.  Rank 9 in
`plan/INBOX/our-improvements.md` §2.7 (Tier B, maintainability).

## What fails

The analyzer has no "undeclared symbol" diagnostic.  An identifier not found in
scope falls through to a hardcoded `builtinNames` list and is treated as
`skBuiltin` with codename `nelua_<name>`.  Identifiers not on that list are
silently treated as `any`-typed externals.  A typo (`undefned`) compiles without
complaint and becomes an external C symbol.

| code | oracle | ours |
|---|---|---|
| `print(undefned)` | `undeclared symbol 'undefned'` | compiles, links to nothing |

## Why it matters

Catching typos.  Also: the global environment is a hardcoded literal, which is
unmaintainable.  Rank 9 -- lower than the crashes because it is a diagnostic gap,
not a wrong-output bug, but it is the difference between a compiler and a
typo-catcher.

## Root cause (precise)

**Oracle cross-read `[S4-3]`.** The oracle's root scope lazily creates builtin
symbols from a data table, `typedefs.builtin_attrs` (`scope.lua`), and primtype
symbols from `primtypes`.  The global environment is a *model*, not a hardcoded
literal.  The oracle also maintains `typedefs.symbol_modules` mapping builtin names
to source modules for error-message suggestions.

## Recommended fix (bounded, two parts)

- **(a) Make the global environment data-driven.** Move `builtinNames` into a table
  in `types.nim` with each entry's codename, signature, and side-effect property.
  Pure refactor, zero behavioural change.  Mirror the oracle's `builtin_attrs`
  structure.  This is `plan/INBOX/our-improvements.md` §4.1 (rank 22) folded in.
- **(b) Add a diagnostic** for identifiers that resolve to neither a scope symbol
  nor an entry in the global table.

**Caveat:** this may be a deliberate emulation of Lua, where an undeclared
identifier is a global lookup that is `nil` at runtime.  If the corpus relies on
that behaviour, make the diagnostic opt-in via a config flag (`strictGlobals`)
rather than unconditional.

**Do not do:** do not make it unconditional without checking the corpus first.

## Verification

- `tmp/probe_undeclared.nelua`: `print(undefned)` emits the diagnostic, matching the oracle's message shape.
- Every currently-MATCHING corpus case still MATCHes (the `strictGlobals` flag is
  off by default, so this is opt-in).