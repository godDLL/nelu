# Multi-return destructuring is broken in Nelu

**Status:** INBOX -- confirmed divergence, no fix.  Caught by `plan/harness.py`
probe `exam/fn_multi.nelua` (recorded DIFF in `tmp/harness_baseline.json`).

## What fails

Multiple return values are a first-class Nelua/Lua feature.  Nelu gets the
single-value case right but mangles the multi-value case:

| code | oracle | Nelu |
|---|---|---|
| `local a = two()` | `1` | `1`  (OK) |
| `local a, b = two()` | `1 2` | `1 nil`  (**b is nil**) |
| `print(two())` | `1 2` | `1`  (**extra returns dropped**) |
| `local a, b = two(); print(a+b)` | `3` | `nil`  (**b nil, then `1+nil` -> nil**) |

`two` is `local function two() return 1, 2 end` in all cases.

## Why it matters

This is not a C-emission quirk.  It is a core language semantic, and the
oracle's own `lib/*.nelua` stdlib uses multi-return destructuring pervasively
(every `string.find`, `string.gsub`, `io.read`-with-format, etc. returns
multiple values that callers destructure).  So this gap is simultaneously:

1. a **wrong-output** bug on a common idiom (high impact per the ranking
   criteria in `plan/INBOX/our-improvements.md`),
2. a **stdlib blocker** -- any `lib/*.nelua` file that destructures a
   multi-return will silently get nil for trailing bindings,
3. **unblocks** the `plan/INBOX/splice-env-locals.md` work, because once
   `lib/hash.nelua` etc. can even be *parsed*, multi-return correctness is
   what makes their output match the oracle.

## Scope of the fix (bounded)

Make the analyzer/codegen treat a multi-value `return` / call result like the
oracle: the value list propagates as a tuple, and destructuring assignment
`local a, b = f()` binds each position; extra values are discarded, missing
positions are nil.  The single-value path already works, so the change is
narrowing the divergence rather than building the feature from scratch.

## Verification

- `exam/fn_multi.nelua` must go DIFF -> MATCH.
- The four cases above must all match the oracle.
- Re-run `plan/harness.py`: 0 regressions, `fn_multi` MATCH.

## Note

This is a **real** divergence the harness caught -- exactly the instrument's
job.  It is recorded as a known DIFF (not a regression) in the baseline.  Do
not "fix" the probe to make it green; the probe is correct and Nelu is wrong.