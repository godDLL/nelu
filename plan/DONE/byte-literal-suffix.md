# Byte literal `'A'_b` suffix

**Status:** CLOSED -- fixed, verified against the oracle.  Rank 2 in
`plan/INBOX/our-improvements.md` §1.2 (Tier A, oracle-stdlib blocker).

## What was wrong

The `_b`/`_u8`/`_i8` suffix on a single-quoted char literal was treated as a
plain string, so `local b: byte = 'A'_b` lowered to `(uint8_t)(nlstr("A"))`
and gcc rejected the string aggregate where an integer was expected.

## Fix

Two files, all in `src/`:

- `src/analyzer.nim` -- the `nkString` case now reads `node.litType`.  For
  `_b`/`_u8`/`_i8` it takes the decoded character (the lexer already decodes
  escapes into `node.str`, so `'\n'_b` is one newline byte, not the two raw
  chars), requires it to be exactly one character (matching the oracle's
  "literal suffix '...' expects a string of length 1"), and types the literal
  as `uint8` (`_b`/`_u8`) or `int8` (`_i8`) with value `$ord(ch)`.
- `src/cgen.nim` -- `genExpr`'s `nkString` case emits the resolved integer value
  directly for suffixed literals instead of `nlstr(...)`.

The parser already folded the suffix onto the string token, so no lexer change
was needed.  `case 'X'_b then` / `switch ... case 'X'_b then` work because the
case value is parsed as an ordinary expression.

Supported string suffixes (matching the oracle): `_b` -> uint8, `_u8` -> uint8,
`_i8` -> int8, all giving the denoted character's ordinal.  Length != 1 is
rejected.  Note: `\ddd` decimal escapes are still unsupported by the lexer
(pre-existing gap, affects plain strings too, e.g. `print('\092')` differs);
they are out of scope for this ticket.

## Verification

- `print('A'_b)` -> `65`, matching the oracle; `local b: byte = 'A'_b; print(b)`
  -> `65`.
- `"x"_u8` -> 120, `'\n'_b` -> 10, `'Z'_b` -> 90, `'A'_i8` -> 65 (int8): all MATCH.
- `switch x case 'X'_b then ...` MATCH.
- `'AB'_b` reports "literal suffix '_b' expects a string of length 1", matching
  the oracle (both exit 1).
- Conformance harness: 0 regressions.

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