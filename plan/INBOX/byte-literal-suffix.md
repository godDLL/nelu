# Byte literal `'A'_b` suffix is not lexed

**Status:** INBOX -- confirmed divergence, no fix.  Rank 2 in
`plan/INBOX/our-improvements.md` §1.2 (Tier A, oracle-stdlib blocker).

## What fails

A single-quoted char literal followed by the `_b` byte-suffix type annotation is
lexed as two tokens: the char literal, then a stray `_b` identifier.  gcc rejects
the identifier.

| code | oracle | ours |
|---|---|---|
| `local b: byte = 'A'_b; print(b)` | `65` | stray `_b` identifier, C compile error |

## Why it matters

Byte literals appear in `lib/string.nelua` (`case 'X'_b then`) and
`lib/allocators/heap.nelua`.  Rank 2: second only to `goto` in stdlib reachability.

## Root cause (precise)

`src/lexer.nim`'s `lexString` handles a single-quoted char literal identically to
a double-quoted string and returns at the closing quote.  The numeric-suffix
scanner (`lexer.nim:105-110`) runs only *inside* `lexNumber`, so the `_b` that
follows a char literal is lexed as a separate `tkIdentifier`.  The number-suffix
path (`200_u8`, `0xFF_u8`) is unaffected and already matches the oracle -- only
the char-literal `_b` form is missing.

## Recommended fix (bounded)

In the lexer, after a single-quoted char literal, scan an optional `_<suffix>`
where the suffix table includes `_b` -> `byte`.  Localised to one lexer helper.
Also handle `'A'_b` inside `switch` case labels (the parser's `case` production
must accept a suffixed char literal as a case value).

## Verification

- `tmp/probe_bytelit.nelua`: `print('A'_b)` prints `65`, exit 0, matching the oracle.
- `case 'X'_b then ...` parses and lowers correctly.
- Re-scan `lib/string.nelua` and `lib/allocators/heap.nelua`: report the new first
  error (do not claim the file is fixed -- other blockers remain).