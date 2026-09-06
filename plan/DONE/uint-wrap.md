# Small-uint arithmetic: nelu wraps, the oracle promotes

**Status:** CLOSED -- implemented and verified against the oracle.  Rank 5 in
`plan/INBOX/our-improvements.md` §2.2 (Tier B, common-idiom wrong-output).

## What failed (re-measured 2026-09-06, both compilers live)

The previous ticket text was **inverted** and has been corrected here.

| code | oracle | nelu (before fix) |
|---|---|---|
| `print(200_u8 + 100_u8)` | `300` (promotes, no wrap) | `44` (wraps to width) |
| `local b: uint8 = 200 + 100; print(b)` | **error**: constant `300` out of range for `uint8` | `44` |

The oracle does **not** wrap small-uint arithmetic: it either promotes the
result to a wider type (`300`) or, when the result is assigned to a
fixed-width variable, rejects the out-of-range constant at compile time.
Nelu wrapped to the declared width (`44 = 300 mod 256`).

## Root cause (precise)

Two distinct defects, both in the C-lowering / analyzer boundary:

1. **Expression context (print).** The print-dispatch in `src/cgen.nim` cast
   each small-uint argument back down to its declared width before handing it
   to the wide print helper, so `200_u8 + 100_u8` (computed as the `int64`
   `300` by the analyzer) was cast to `uint8` and wrapped to `44`.  The cast
   was removed; the widened `int64` result now reaches the print helper as-is.

2. **Assignment context.** The ticket's recommended fix assumed an
   out-of-range constant check "already fires" for
   `local b: uint8 = 200 + 100`.  It does **not** exist anywhere in `src/`.
   Nelu let the C truncating cast wrap the value silently.  Added
   `checkIntRange` in `src/analyzer.nim` (forward-declared, called from
   `analyzeVarDecl`'s init loop): when the initializer is a comptime integer
   (`ia.comptime` + `ia.value` from the constant folder) and the declared type
   is a fixed-width integral type, parse the value and emit the oracle's
   diagnostic if it is out of range.  The diagnostic text matches the oracle's
   wording, including the type name (`byte` -> `uint8`, `integer` ->
   `int64`, `usize` -> `usize`) and the min/max per bit width.

## Fix (bounded)

- `src/cgen.nim`: removed the W2 small-uint wrap cast in the print dispatch.
- `src/analyzer.nim`: added `checkIntRange` and its call site in
  `analyzeVarDecl`; guarded against the `low(int64) - 1` overflow that the
  first version hit (it crashed on *every* integer var-decl, `local x = -5`
  among them) by computing signed min/max without overflowing for the 64-bit
  case.

## Verification

- `tmp/probe_uintwrap.nelua`: `print(200_u8 + 100_u8)` prints `300`, matching
  the oracle.
- `local b: uint8 = 200 + 100` now errors with the oracle's diagnostic
  (NELU_ACCEPT -> MATCH); same for `200_u8 + 100_u8`, `int8 = -200`,
  `uint8 = 256`, `uint16 = 70000`.
- In-range values are untouched: `uint8 = 255` -> `255`, `int8 = 127` -> `127`,
  `int8 = -128`, `uint64 = 18446744073709551615` (passes the check; the
  print-side `0` for that literal is a separate pre-existing codegen issue,
  out of scope here).
- Harness: `python3 plan/harness.py` -> `OK: no regression.` (307 baseline
  entries).  New exam probes `uintwrap_promote`, `neg_uintwrap_range`,
  `neg_uintwrap_range2` recorded in `plan/harness_baseline.json`.

## Notes

- The huge-literal edge case (`local b: uint64 = 99999999999999999999999999`
  with no `_u` suffix) is handled by the oracle via big integers but by nelu
  via float parsing, so nelu's `ia.value` is a float string there and the
  check skips it.  Out of scope for this ticket; would need a big-int path.
- `local x = -5` (no annotation) infers `integer`; the check correctly treats
  it as in-range and does not fire.