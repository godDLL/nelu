# Small-uint arithmetic does not wrap

**Status:** INBOX -- confirmed divergence, no fix.  Rank 5 in
`plan/INBOX/our-improvements.md` §2.2 (Tier B, common-idiom wrong-output).

## What fails

Fixed-width unsigned arithmetic overflows instead of wrapping to the declared
width.

| code | oracle | ours |
|---|---|---|
| `local b: uint8 = 200 + 100; print(b)` | `44` | `300` |

`examples/www/uint8_wrap.nelua` DIFFs the same way.

## Why it matters

Real code (RNG state, buffer indices) depends on wrap-to-width semantics for
fixed-width unsigned types.

## Root cause (precise)

The analyzer widens small-uint operands to `int64` for the binary op and the C
lowering emits the `int64` result; there is no wrap-to-width step for
fixed-width unsigned types.  The oracle wraps to the declared width.

## Recommended fix (bounded)

After `inferBinary` produces the result type for a fixed-width unsigned operand
pair, mask the emitted C expression to the type's width.  Note
`(uint8_t)(a + b)` is **not** enough -- the sub-expression must be masked before
assignment, or the assignment must be a width-truncating cast.  Locate the wrap
point in the arithmetic-lowering proc in `cgen.nim` and add a truncating cast for
`tkUint8/16/32/64/128`.  No `nlcheck_uint_overflow`.

## Verification

- `tmp/probe_uintwrap.nelua`: `print(200_u8 + 100_u8)` prints `44`, exit 0, matching the oracle.
- `examples/www/uint8_wrap.nelua` goes DIFF -> MATCH.
- No regression on `int64` / `float` / signed arithmetic.