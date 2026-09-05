# `@union` field access and print is broken

**Status:** INBOX -- confirmed divergence, no fix.  Rank 11 in
`plan/INBOX/our-improvements.md` §3.2 (Tier C, single-construct C-emission).

## What fails

Accessing a union field resolves it to `any`, which drives the wrong C emission.

| code | oracle | ours |
|---|---|---|
| `local u: @union { a: integer, b: float32 }; u.a = 5; print(u.a)` | `5` | `u.a = nlany_from_int(5)` then `nelua_print_any(u.a)`; gcc rejects both |

## Why it matters

Unions are a core language feature.  Rank 11 -- lower than the Tier A/B items because
it touches fewer programs, but it is a bounded, one-branch fix.

## Root cause (precise)

The union *typedef* emission is correct: `cgen.nim` emits
`typedef union <tag> { cDecl(f.typ, f.name); ... } <tag>;` using each field's
declared type, and `analyzer.nim`'s `nkUnionType` handler preserves the field type.
The gap is in **field access**: `analyzeDotIndex`
(`src/analyzer.nim`, ~717-755) handles `tkRecord` and `tkEnum` receivers but has
**no `tkUnion` branch**, so a union field's `attr.typ` falls through to
`BuiltinTypes["any"]`.  The `any`-typed attr then drives the `nlany_from_*` wrap
and the `nelua_print_any` dispatch.

## Recommended fix (bounded)

Add a `tkUnion` branch to `analyzeDotIndex` mirroring the `tkRecord` branch: look
up `node.str` in `rt.fields` and set `a.typ = f.typ`.  Bounded, one-branch change.
This is the same pattern the record branch already uses.

## Verification

- `tmp/probe_union.nelua`: the case above prints `5`, exit 0, matching the oracle.
- Record and enum field access still work (no regression).