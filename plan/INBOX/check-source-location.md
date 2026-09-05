# `check(false, msg)` omits the source location from the message

**Status:** INBOX -- confirmed divergence, no fix (cosmetic).  Rank 16 in
`plan/INBOX/our-improvements.md` §3.7 (Tier C, cosmetic).

## What fails

The runtime error path does not prepend the source location the way the oracle's
does.

| code | oracle | ours |
|---|---|---|
| `check(false, "should fail")` | `d4_check.nelua:1:7: runtime error: should fail` + source line + caret | `runtime error: should fail` only |

Both abort with exit 134, so the failure mode matches; only the message differs.

## Why it matters

Cosmetic.  Rank 16 -- lowest-rank Tier C item, but it is a one-line change and the
oracle's behaviour is unambiguous.

## Root cause (precise)

The runtime error path in our driver does not prepend the source location the way
the oracle's does.

## Recommended fix (bounded)

Prepend `path:line:col:` to the runtime error message in the driver's error path,
reusing the existing `render` machinery in `errors.nim`.  One-line change.

## Verification

- `tmp/probe_check.nelua`: `check(false, "should fail")` prints the location-prefixed
  message plus source line and caret, matching the oracle's shape.
- `check(true, ...)` still passes (no regression).