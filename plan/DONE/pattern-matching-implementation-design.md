# Pattern matching (`switch`/`case`/`else`) — implementation design

Status: **DONE, 2026-08-30**. Implements the oracle's `switch`/`case`/`else`
statement on the previously-dead `nkSwitch` node. Authoritative oracle survey:
`plan/pattern_matching_oracle-behavior-design.md` (34 probes). This doc is the
behavior spec + verification record for the implementation.

**Result: 34/34 oracle probes match** on acceptance category *and* stdout
(where the oracle accepts). Analyzed-AST structure is byte-identical to the
oracle; C lowering is structurally identical.

---

## 1. What landed (files owned by this task)

| File | Change |
|---|---|
| `src/parser.nim` | `canStartExpr`, `parseSwitchBlock`, `parseSwitch`; `of "switch"` arm in `parseStatement`; statement-position `case` rejection; `dumpSwitchChildren` + `nkSwitch` branch in `dump`; forward decl of `dump` |
| `src/analyzer.nim` | `analyzeSwitch`; `of nkSwitch` in `analyzeStmt`; `buildSwitchCases` + `of nkSwitch` in `dumpAnaled`; **new** `loopDepth` field + inc/dec in `analyzeWhile`/`analyzeForNum`/`analyzeForIn`/`analyzeRepeat`; `nkBreak`/`nkContinue` validation in `analyzeStmt` |
| `src/cgen.nim` | `bodyEndsInJump`; `genSwitch`; `of nkSwitch` in `genStmt` |
| `src/ast.nim`, `src/astshapes.nim`, `src/lexer.nim` | **read-only** — `newSwitch` flattens cases into `[subject, vals..., body, ...]`; `nkSwitch: @[nfChildren]`; `switch` is a keyword, `case` is a contextual `tkIdent` |

No node kind was invented. `nkSwitch` already existed and is reused as-is; the
contract is the flat children layout produced by `newSwitch`, and every
consumer (analyzer, codegen, dump) recovers case boundaries by scanning for
`nkBlock` (case bodies are always `nkBlock`; case values never are).

---

## 2. Behavior spec (the supported surface)

A `switch` statement:

```
switch <expr>
  case <iv1> [, <iv2> ...] then <block>
  ...
  [else <block>]
end
```

1. **Subject.** `<expr>` must be convertible to an integral type. Non-integral
   subjects are a compile error:
   `switch statement must be convertible to an integral type, but got type '<t>' (non integral)`
2. **Case values.** One or more comma-separated, **compile-time foldable
   integral** constants. `1+1` folds to `2`; `x*2` does not fold and is
   rejected: `case statement must evaluate to a compile time integral value`.
   Float/boolean/nil case values are rejected on the same rule.
3. **Comma cases → consecutive C labels.** `case 1, 2 then <body>` emits
   `case 1: case 2: { <body> break; }` — C fallthrough labels all guarding one
   shared body. First matching label runs the body.
4. **`else` → `default`.** There is no `default` keyword; `else` is the only
   fallback clause and takes a block directly (`else then ...` is a syntax
   error).
5. **No fallthrough between cases.** Each case body ends with an implicit
   `break`. The trailing `break;` is omitted **iff** the body ends in
   `return`/`break`/`continue`/`goto` (a noreturn jump), since a dead `break`
   there is harmless and the oracle does the same.
6. **No matching case, no `else`** → silent no-op; control passes after `end`.
7. **`then` is mandatory** after the case value list.
8. **`break`/`continue` bind to the enclosing loop, never to the switch.**
   `break`/`continue` outside any loop is a compile error:
   `break statement is not inside a loop` / `continue statement is not inside
   a loop`.
9. **Empty switch** (`switch 42 / end`, no case/else) is an error:
   `expected 'case' keyword in 'switch' statement`.
10. **`switch` is statement-only**, not an expression.

---

## 3. Verification — 34/34 probes

Probes live in `tmp/oracle_probe/` (throwaway, unique filenames because the
oracle caches `--print-ast` by name). Harness: `/tmp/probe_run.py`.

Legend: **A** = accepted, **E** = error. "Match" = same acceptance category
*and*, for accepted probes, identical stdout. Error probes match on the
rejection category; error *text* matches the oracle verbatim where our
diagnostic path carries the same message (see §8 for the two systemic
format differences).

| # | Behavior | Oracle | Ours | Note |
|---|---|---|---|---|
| 1 | minimal switch | A → `two` | A → `two` | |
| 2 | `case` requires `then` | E | E | message identical |
| 3 | no fallthrough (x=1) | A → `one` | A → `one` | |
| 4 | `case else` | E | E | `else` is a clause, not a value |
| 5 | `case _` | E | E | no wildcard; `_` is an undeclared symbol |
| 6 | comma cases `1,2,3` | A → `low` | A → `low` | C: consecutive labels; **Lua: E** (see §7) |
| 7 | non-matching, no else | A → silent | A → silent | |
| 8 | string subject | E | E | non-integral |
| 9 | non-comptime `case x*2` | E | E | message identical |
| 10 | string subject + int case | E | E | |
| 11 | float case value | E | E | |
| 12 | boolean case value | E | E | |
| 13 | nil case value | E | E | |
| 14 | boolean subject | E | E | |
| 15 | nested switch | A → `inner` | A → `inner` | |
| 16 | `switch` + `return` (untyped param) | E | E | both C backends fail (the `any`/untyped-return limitation, not a switch bug) |
| 17 | `break` inside switch+loop | A | A | break hits the enclosing loop |
| 18 | `break` in switch, no loop | E | E | message identical (new `loopDepth` validation) |
| 19 | `continue` inside switch+loop | A | A | |
| 20 | `else` branch | A → `other` | A → `other` | |
| 21 | `else then` | E | E | |
| 22 | `switch` as a value | E | E | statement-only |
| 23 | `case -1`, `case 256` | A → `neg` | A → `neg` | full int64 range |
| 24 | empty switch | E | E | message identical |
| 25 | subject evaluated once | A | A | verified: exactly one call in `switch(...)` (see §5) |
| 26 | `cint` subject | A → `c` | A → `c` | |
| 27 | duplicate case values | E | E | **both** fail at C-compile with `duplicate case value` |
| 28 | `switch` inside `for` | A | A | |
| 29 | `switch` in typed function | A → `10` | A → `10` | typed return `: integer` required on ours (see §8) |
| 30 | `match` keyword | E | E | not a keyword |
| 31 | `cond` keyword | E | E | not a keyword |
| 32 | `case` outside `switch` | E | E | message identical |
| 33 | `if`-expression | E | E | statement-only |
| 34 | `record`/`union`/`enum` | E | E | Nelu features, absent in 0.2.0-dev |

### Verbatim accepted-probe output (oracle / ours)

```
P01  oracle: two [exit=0]   ours: two [exit=0]
P03  oracle: one [exit=0]   ours: one [exit=0]
P06  oracle: low [exit=0]   ours: low [exit=0]
P20  oracle: other [exit=0] ours: other [exit=0]
P23  oracle: neg [exit=0]   ours: neg [exit=0]
```

### Verbatim error-probe output (first matching line)

```
P02  oracle: ...:4:5: syntax error: expected `then` keyword to begin a statement block
     ours:   ...:4:5: error: expected `then` keyword to begin a statement block
P09  oracle: ...: error: `case` statement must evaluate to a compile time integral value
     ours:   ...: error: `case` statement must evaluate to a compile time integral value
P18  oracle: ...: error: `break` statement is not inside a loop
     ours:   ...: error: `break` statement is not inside a loop
P24  oracle: ...: syntax error: expected `case` keyword in `switch` statement
     ours:   ...: error: expected `case` keyword in `switch` statement
P27  oracle: error: duplicate case value      ours: error: duplicate case value
```

---

## 4. C lowering (structurally identical to the oracle)

For `switch x / case 1,2 then print("low") / case 3 then print("mid") /
else print("other") / end`:

Oracle C:
```c
switch(tmp_x) {
  case 1:
  case 2: { print("low"); break; }
  case 3: { print("mid"); break; }
  default: { print("other"); break; }
}
```

Ours:
```c
switch (tmp_x) {
  case 1:
  case 2:
  { print("low"); break; }
  case 3:
  { print("mid"); break; }
  default: { print("other"); break; }
}
```

Identical semantics: comma cases are consecutive C labels; `else` is
`default`; a trailing `break;` is emitted after each body unless the body ends
in a noreturn jump. The subject is emitted once, directly in the `switch(`
argument — matching the oracle's **C** backend, which does not hoist the
subject (only its Lua backend hoists to `__switchvalN`).

---

## 5. Subject evaluated once (probe 25)

Verified by code inspection rather than a runtime counter, because a
side-effecting subject needs a closure and our compiler has a pre-existing
closure/upvalue gap (§8). For `switch getval()`:

- Oracle C: `switch(tmp_getval())` — exactly one call.
- Ours C:   `switch (tmp_getval())` — exactly one call.

Both evaluate the subject exactly once. By construction our `genSwitch`
emits `switch (<genExpr(subject)>)`, so the property holds for any subject.

---

## 6. AST shape (analyzed)

`--print-analyzed-ast` is byte-identical to the oracle modulo the systemic
`nk` prefix:

```
Switch {
  Id { attr={...}, "x" },            # subject
  {                                   # cases container (bare { })
    { Number{...,"1"}, Number{...,"2"} },   # case value list (bare { })
    Block { Call { ... } }             # case body
    ...
    Block { Call { ... } }             # else block (trailing)
  }
}
```

The raw `--print-ast` additionally differs in leaf rendering (ours emits
`Id "x"` inline with a trailing empty `{}`, the oracle nests it as
`Id { "x" }`) — a **pre-existing, systemic** difference present on non-switch
programs too (e.g. `local x = 1`), not introduced here.

---

## 7. Backend divergence — Lua backend: N/A

Our compiler has **no Lua codegen backend** (`src/compile.nim` always uses
`genC`; `config.generator` is parsed by `cli.nim` but never read). The
Lua-backend half of the oracle survey is therefore not testable here, and the
known Lua/C divergence (comma cases, duplicate-case handling) cannot be
exercised.

For the record, the oracle's documented divergence is: the **C** backend
emits a real C `switch` (duplicate case values are a C-compile error
`duplicate case value`; comma cases are consecutive labels); the **Lua**
backend lowers to an `if`/`elseif` chain, cannot parse comma cases
(`'then' expected near ','`), and silently takes the first of duplicate
values. We match the C behavior exactly (probe 27 both produce
`duplicate case value`; probe 6 both accept comma cases).

---

## 8. Pre-existing gaps NOT fixed by this task (documented, not claimed)

These are out of scope for `switch`/`case`/`else` and are left for their
owners. They surface in the probe suite and are the reason probes 16/25/29
needed careful formulation:

1. **Untyped-function return deduction.** An untyped function with
   `return <value>` returns `nil` on ours (the return value is dropped); the
   oracle deduces the return type. Typed returns (`: integer`) work on both.
   Affects probes 16, 25, 29. Verified pre-existing: `local function f()
   return 10 end; print(f())` prints `nil` on ours, `10` on the oracle, on a
   program with no switch.
2. **Closure / upvalue scoping.** Nested functions cannot read `local`
   variables from an enclosing scope (neither top-level nor function-level).
   The oracle closes over them. Verified pre-existing: `local counter = 0;
   local function tick(): integer counter = counter + 1; return counter end;
   print(tick())` → oracle `1`, ours fails at C-compile
   (`'counter' undeclared`). This is why probe 25's natural formulation
   (a counter) is replaced by a closure-free `getval()` plus code inspection.
3. **Systemic dump/`nk`-prefix + error-format differences** (pre-existing, in
   the general `dump`/diagnostic paths, not in `dumpSwitchChildren`):
   - raw `--print-ast` leaf rendering (`Id "x"` vs `Id { "x" }`);
   - `nk` prefix on node names (ours `nkSwitch`, oracle `Switch`);
   - parser errors are `path:line:col: error: msg` on ours vs
     `path:line:col: syntax error: msg` on the oracle; analyzer diags are
     `path: error: msg` on ours with no line:col, and are wrapped in
     `/* nelua: ... */` at the top level.
   Error *messages* themselves match the oracle verbatim where our diagnostic
   path carries them (P02/P09/P18/P24/P32 — see §3).

---

## 9. Out of scope in 0.2.0-dev (§6 of the oracle survey — not implemented, not claimed)

- `match` / `cond` / `case`-as-a-keyword / if-expressions / ternary
- wildcard patterns (`case _`), record/union/enum destructuring, type patterns
- `switch` as an expression (statement-only)
- `default` keyword (use `else`)
- non-integral subjects or case values
- backend parity for comma cases / duplicate cases on a Lua backend (N/A — no Lua backend)
- `case` used outside `switch` (statement-position `case` is rejected with
  `unexpected syntax`, matching the oracle; residual contextual acceptances
  such as `local case = 1`, `t.case`, `f(case)` are pre-existing and
  unaddressed)

---

## 10. Reproducing

```
cd /home/user/Code/nelua-lang
nim c -d:release --path:src -o:tmp/nelua src/main.nim            # build
python3 /tmp/probe_run.py                                        # 34/34 harness
/usr/bin/nelua <file>                                            # oracle (C backend)
./tmp/nelua <file>                                               # ours (C backend)
./tmp/nelua -c <file> -o out.c                                   # emit C
./tmp/nelua --print-ast <file>                                   # raw AST
./tmp/nelua --print-analyzed-ast <file>                          # analyzed AST
```

Probe files: `tmp/oracle_probe/pNN.nelua` (throwaway).