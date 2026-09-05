# `...: cvarargs` in a cimport function emits invalid C

**Status:** INBOX -- confirmed divergence, no fix.  Rank 14 in
`plan/INBOX/our-improvements.md` §3.5 (Tier C, stdlib blocker).

## What fails

A `cimport` function with a `...: cvarargs` parameter emits a stray `___` token where
the C varargs parameter should be.

| code | oracle | ours |
|---|---|---|
| `local function snprintf(...: cvarargs): cint <cimport> end; print("declared")` | `declared` | stray `___`, C compile error |

## Why it matters

Used in `lib/stringbuilder.nelua`
(`local function snprintf(...: cvarargs): cint <...>` and
`quadmath_snprintf(...: cvarargs)`).  Rank 14.

## Root cause (precise)

The C emitter does not translate `cvarargs` parameters to the C `...`/`va_list`
form correctly.  `cgen_types.nim:123` already spells `tkCvarargs` as `"..."` in value
position, but the function-parameter translation path is incomplete.

## Recommended fix (bounded)

In the C function-parameter emission, emit a bare `...` for a `cvarargs` parameter
(matching `cgen_types.cType`) and ensure the function type's C spelling is
`ret name(...)` rather than trying to name the parameter.  Localised to the
parameter-list emission proc.

## Verification

- `tmp/probe_cvarargs.nelua`: the case above prints `declared`, exit 0, matching the oracle.
- A cimport function with a real `cvarargs` body still compiles.