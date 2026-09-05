# `<comptime>` on a string global/local evaluates the string as a number

**Status:** INBOX -- confirmed divergence, no fix.  Rank 12 in
`plan/INBOX/our-improvements.md` §3.3 (Tier C, stdlib blocker).

## What fails

A `string` value under `<comptime>` is run through the numeric comptime evaluator
instead of being kept as a string literal.

| code | oracle | ours |
|---|---|---|
| `global _VERSION: string <comptime> = "1.0"; print(_VERSION)` | `1.0` | `nelua_print_string(1.0)` |

## Why it matters

Used in `lib/builtins.nelua` (`global _VERSION: string <comptime>`),
`lib/utf8.nelua`, and `lib/stringbuilder.nelua`
(`local L_FMTFLAGS: string <comptime> = "-+ #0"`).  `lib/stringbuilder.nelua`
fails at this exact line in ours.

## Root cause (precise)

The `<comptime>` codegen path evaluates the initializer at compile time and for a
`string` runs the value through the numeric comptime evaluator instead of keeping
it as a string literal (`cgen.nim` `genVarDecl` comptime handling, ~542-560 and
~1257).

## Recommended fix (bounded)

In the comptime evaluation path, branch on the declared type: if the target is
`string`, keep the literal as an `nlstring` (do not run it through
`numberTypeAndValue`).  Localised to the comptime fold in `genVarDecl` / the
analyzer's comptime folding.

## Verification

- `tmp/probe_comptime_str.nelua`: the case above prints `1.0`, exit 0, matching the oracle.
- Numeric `<comptime>` still folds correctly (no regression).