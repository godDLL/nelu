# `genForIn` supports only a single array iterable

**Status:** INBOX -- confirmed gap, no fix.  Rank 8 in
`plan/INBOX/our-improvements.md` §2.6 (Tier B, common-idiom gap).

## What fails

Multi-value `for k, v in array` is not supported; only a single loop variable works.

| code | oracle | ours |
|---|---|---|
| `for k, v in {10, 20, 30} do print(k, v) end` | `1 10 2 20 3 30` | parse/emit failure |

## Why it matters

`for k, v in array` is the idiomatic way to iterate an array with index and value.
Its absence forces manual index loops.

## Recommended fix (bounded)

Extend `genForIn` to handle the two-variable form for array iterables: emit a
standard C index loop
(`for (int64_t _i = 0; _i < n; _i++) { k = _i; v = arr[_i]; ... }`).  The analyzer
already attaches the iterable type; the change is localised to one proc.
Multi-value tuple iterables (`for a, b in pairs(...)`) are a separate, larger
feature -- defer those.

## Verification

- `tmp/probe_forin.nelua`: `for k, v in {10,20,30} do print(k, v) end` matches the oracle.
- Single-variable `for v in array` still works (no regression).
## Re-measured 2026-09-06 (live, both compilers)

The ticket's "What fails" table is **stale** -- the premise no longer holds.

The claimed oracle output `1 10 2 20 3 30` is **not reproducible**: the oracle
itself crashes on `for k, v in {10, 20, 30} do ... end`:

```
/usr/bin/nelua-lua: .../analyzer.lua:1227: attempt to call a nil value
(method 'get_return_type')
```

So multi-value `for k, v in array` is **unsupported in both compilers**, not a
nelu-only divergence.  No oracle baseline exists to match against.  Kept as a
real feature gap but the ticket text is wrong about the oracle side.
