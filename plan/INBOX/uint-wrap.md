# Small-uint arithmetic: nelu wraps, the oracle promotes

**Status:** INBOX -- confirmed divergence, no fix.  Rank 5 in
`plan/INBOX/our-improvements.md` §2.2 (Tier B, common-idiom wrong-output).

## What fails (re-measured 2026-09-06, both compilers live)

The previous ticket text was **inverted** and has been corrected here.

| code | oracle | nelu |
|---|---|---|
| `print(200_u8 + 100_u8)` | `300` (promotes, no wrap) | `44` (wraps to width) |
| `local b: uint8 = 200 + 100; print(b)` | **error**: constant `300` out of range for `uint8` | `44` |

The oracle does **not** wrap small-uint arithmetic: it either promotes the
result to a wider type (`300`) or, when the result is assigned to a
fixed-width variable, rejects the out-of-range constant at compile time.
Nelu wraps to the declared width (`44 = 300 mod 256`).

## Why it matters

Real code (RNG state, buffer indices) depends on wrap-to-width semantics for
fixed-width unsigned types.  But the harness matches against the oracle, so to
get MATCH nelu must adopt the oracle's promote-or-reject behaviour, not C's
wrap behaviour.

## Root cause (precise)

The analyzer widens small-uint operands to `int64` for the binary op, but the
C lowering emits a width-truncating cast / wrap for fixed-width unsigned
types.  The wrap point is in the arithmetic-lowering proc in `cgen.nim`.

## Recommended fix (bounded) -- OPPOSITE of the old note

The old ticket recommended *adding* wrapping; that is the wrong direction.
To match the oracle, **remove** the wrap-to-width step for `tkUint8/16/32/64/128`
arithmetic so the widened `int64` result is emitted as-is, and let the
existing out-of-range constant check (which already fires for
`local b: uint8 = 200 + 100`) handle the assignment-time rejection.  Verify the
`print(200_u8 + 100_u8)` case yields `300` and `local b: uint8 = 200 + 100`
still errors.

## Verification

- `tmp/probe_uintwrap.nelua`: `print(200_u8 + 100_u8)` prints `300`, matching the oracle.
- `local b: uint8 = 200 + 100` still errors (no regression on the diagnostic).
- No regression on `int64` / `float` / signed arithmetic.