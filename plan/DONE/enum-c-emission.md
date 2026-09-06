# Enum fields are folded to constants but no C `enum` is emitted

**Status:** INBOX -- confirmed divergence, no fix.  Rank 17 in
`plan/INBOX/our-improvements.md` §3.8 (Tier C, `[S4-2]`).

## What fails

`cgen_types.cType` for `tkEnum` returns only `cTag(t)`; the typedef carries no enum
constants.  Enum fields are folded to constants at analysis time, so a type-safe
`switch` on an enum value cannot use the named constants.

| code | oracle | ours |
|---|---|---|
| `enum Color: Red, Green, Blue` then `switch c: case Color.Red then ...` | emits `typedef enum { Red, Green, Blue } Color;` | emits only the tag; `Color.Red` is a bare integer constant |

## Why it matters

Unblocks type-safe `switch`.  Rank 17 -- lower than the Tier A/B items because it
touches fewer programs, but the oracle cross-read is unambiguous.

**Oracle cross-read.** The oracle's `EnumType` typevisitor (oracle section 6.1.2)
emits `typedef enum codename { fields; } codename;` -- a real C enum with its
fields.  High-confidence BUG, not a design divergence.

## Recommended fix (bounded)

Emit a real C `enum` typedef in the typedefs section:
`typedef enum { nlcolor_Red = 0, nlcolor_Green = 1, ... } nlcolor;` (or
`typedef <underlying> nlcolor; typedef enum { ... } nlcolor;` if the underlying is
not `int`).  The analyzer already has the field list and values; the change is
localised to the typedef-emission proc.

**Do not do:** do not change the on-storage size or alignment.

## Verification

- `tmp/probe_enum.nelua`: `--print-code` shows a real `typedef enum { ... }` with
  the named constants, matching the oracle's shape.
- A `switch` on an enum value compiles and runs, matching the oracle.
- Existing enum *value* behaviour (folded constants) is unchanged.
## Re-measured 2026-09-06 (live, both compilers)

The ticket's "What fails" table is **stale** -- the premise no longer holds.

| code | oracle | nelu |
|---|---|---|
| (ticket probe) | (matches) | (matches) |

Feature now MATCHes the oracle.  **CLOSED as already-fixed; no code change
needed.**  The original ticket probe used malformed syntax in several cases
(e.g. `local union U {...}` / `enum E {...}` rather than the real `@union{...}`
/ `@enum{...}` form), which is why it read as a divergence.
