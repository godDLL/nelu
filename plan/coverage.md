# Nelu language coverage

One table, one status vocabulary, one number for "how many MATCH".  This doc
replaces `plan/cover-corpus.md`, `plan/nelu-language-coverage-gap.md`, and the
coverage sections of `plan/GATES.md` (all moved to `tmp/legacy/`).

## How to read this doc

- **Verdict** — the unified vocabulary the harness uses (see below).
- **Probe** — a `.nelua` file under `examples/` that `plan/harness.py` runs.
  The harness walks `examples/` recursively; nothing is enumerated by hand.
- **Oracle** — `/usr/bin/nelua` (upstream 0.2.0-dev).  "Oracle accepts" means
  it compiles and runs the probe with exit 0.
- **Nelu** — `tmp/nelu` (the clean-room reimplementation, built by `make nelu`).
- **Baseline** — `tmp/harness_baseline.json` (gitignored scratch), captured by
  `python3 plan/harness.py --record`.  A probe's verdict here is the recorded
  baseline; the harness exits non-zero only on a *regression* (a previously
  MATCHing probe going DIFF/CRASH/REJECT, or a new crash).  Baseline captured
  **2026-09-04** on the current tree; re-run `--record` after any change.

### Status vocabulary

| Status | Meaning |
|---|---|
| `MATCH` | oracle accepts; Nelu produces the same stdout and exit code. |
| `DIFF` | both ran but the outputs differ, or the exits differ. |
| `NELU_REJECT` | oracle accepts; Nelu fails to parse/analyse (exit 1). |
| `NELU_CRASH` | oracle accepts; Nelu parses but the generated C fails to compile, or Nelu SIGSEGVs/aborts. |
| `BOTH_FAIL` | neither produces a runnable binary (out of scope for parity). |
| `ORACLE_FAIL` | Nelu built fine but the oracle did not (oracle-side unsupported). |
| `SKIP` | not a standalone program; the oracle does not exit cleanly either. |
| `NOT-RUN` | no probe exists for this element (not yet written). |

### The harness

`python3 plan/harness.py` builds `tmp/nelu` once (via `make nelu`, which honours
`NELU_OUT -> tmp/nelu`), runs every probe, prints one table, and exits 0 on no
regression.  It subsumes six former gate scripts (all in `tmp/legacy/scripts/`):

| former gate | becomes | mode |
|---|---|---|
| `plan/regress.py` over `tmp/corpus_nelua/` | `examples/dump-ast/` | M1 parse-AST token diff |
| `plan/regress.py` over `tmp/m2_corpus/` | `examples/dump-analyzed-ast/` | M2 analyzed-AST vs stored `*.ref` |
| `plan/cmp.py` (40 inline cases) | inline in the harness | token-level AST diff |
| `plan/examples_parity.py` | `examples/*.nelua` | exec (stdout + exit) |
| `plan/wwwcheck.py` | `examples/www/` | exec |
| `plan/cover_gate.py` | `examples/cover/` | exec |

CLI conformance (`plan/cli_conformance.py`, 896 cases) is **not** part of this
harness and is a separate queue in `NOTE_backlog.md`.  Its DIFFs do not appear
here and do not pollute these numbers.

## Headline numbers (2026-09-04 baseline)

| mode | probes | MATCH | DIFF | NELU_REJECT | NELU_CRASH | OTHER |
|---|---|---|---|---|---|---|
| M1 parse-AST (`examples/dump-ast/`) | 28 | 25 | 3 | 0 | 0 | — |
| M2 analyzed-AST (`examples/dump-analyzed-ast/`) | 14 | 14 | 0 | 0 | 0 | — |
| cmp token-level AST (40 inline) | 40 | 39 | 0 | 0 | 0 | 1 ORACLE_FAIL |
| exec (`examples/cover/` + `examples/www/` + top-level) | 166 | 142 | 3 | 6 | 1 | 13 BOTH_FAIL, 1 ORACLE_FAIL, 3 SKIP |
| **total** | **248** | **220** | **3** | **6** | **1** | 17 |

Every MATCH count above is identical to what the six former gate scripts report
on this tree (see "Drop-in fidelity" below); the non-MATCH labels are richer —
the old gates conflated build-failure causes under a single `DIFF`/`SKIP`.

## Coverage table

### 1. Statements

| element | probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|---|
| `switch`/`case`/`else` | `examples/cover/switch-case.nelua` | accepts | `two or three` | **MATCH** | MATCH |
| `fallthrough` in `switch` | `examples/cover/fallthrough.nelua` | accepts | `one` | **MATCH** | MATCH |
| `goto` / `::label::` | `examples/cover/goto-label.nelua` | accepts | `done` | **MATCH** | MATCH |
| `defer ... end` | `examples/dump-analyzed-ast/defer.nelua` | accepts | accepts | **MATCH** (M2) | MATCH |
| `repeat ... until` | `examples/www/repeat_until-ddx.nelua` | accepts | accepts | **MATCH** | MATCH |
| `continue` | `examples/www/check_fail-ddx.nelua` (transitively) | accepts | accepts | **MATCH** | MATCH |
| numeric `for i = a, b, step` | `examples/www/stepped_for-ddx.nelua` | accepts | accepts | **MATCH** | MATCH |
| `for ... in` iterator form | *no oracle-accepted probe* | accepts | rejected ("not supported") | **NOT-RUN** | — |
| `in (expr) do ... end` (DoExpr) | *bundled in `macro-def.nelua`* | accepts | accepts | **MATCH** (via macro-def) | MATCH |
| `## local function NAME ... ## end` macro def | `examples/cover/macro-def.nelua` | accepts | `42` | **MATCH** | MATCH |

Notes:
- `for ... in` and `in (expr)` are documented as A-ranked gaps in the old
  `nelu-language-coverage-gap.md`.  `for ... in` is still rejected by Nelu, but
  no oracle-accepted probe can be written for it (the only one iterates
  `utf8.codes`, which Nelu cannot load).  `in (expr)` is only valid as the body
  of a macro definition, so it is covered inside `macro-def.nelua`, which MATCHes.
- `goto`/`::label::`, `fallthrough`, `switch`/`case` were all A-ranked gaps that
  closed; the probes are kept as positive regression material.

### 2. Expressions and operators

| element | probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|---|
| `///` truncate division | `examples/cover/tdiv.nelua` | `3` | `3` | **MATCH** | MATCH |
| `%%%` truncate modulo | `examples/cover/tmod.nelua` | `2` | `2` | **MATCH** | MATCH |
| `>>>` arithmetic shift right | `examples/cover/asr.nelua` | `4` | `4` | **MATCH** | MATCH |
| `//` floor division (negatives) | `examples/www/floor_div-ddx.nelua` | `-4` | `-4` | **MATCH** | MATCH |
| `1 << 60` large left shift | `examples/www/lshift-ddx.nelua` | `1152921504606846976` | same | **MATCH** | MATCH |
| string escapes `\t\n` | `examples/www/escapes-ddx.nelua` | `5` | `5` | **MATCH** | MATCH |
| `#string` length | `examples/www/string_len-ddx.nelua` | accepts | accepts | **MATCH** | MATCH |
| `..` concat | `examples/www/string_concat-ddx-ffs.nelua` | *oracle rejects* | accepts | **ORACLE_FAIL** | ORACLE_FAIL |
| `local` shadowing inside `do ... end` | `examples/www/scope_shadow-ddx.nelua` | `2`/`1` | same | **MATCH** | MATCH |
| `#Type` sizeof on builtin types | `examples/cover/sizeof-builtin.nelua` | `8` | `8` | **MATCH** | MATCH |
| `#[x]#` splice of a variable reference | `examples/cover/splice-ident.nelua` | `5` | `5` | **MATCH** | MATCH |
| `@integer` in value position | `examples/cover/type-value-position.nelua` | `5` | `5` | **MATCH** | MATCH |

Notes:
- `///`/`%%%`/`>>>` were B-ranked (parsed but printed `nil`); all closed.
- `lshift`, `floor_div`, `escapes`, `scope_shadow`, `stepped_for` were the five
  runtime DIFFs triaged in `plan/examples-diffs-design.md`; all MATCH on the
  current tree (the fixes landed).  `www_string_concat-ddx-ffs` is a Nelu
  extension the oracle rejects by design — `ORACLE_FAIL`, not a gap.

### 3. Type forms

| element | probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|---|
| `@record{ ... }` | `examples/cover/record-type.nelua` | `1 a` | `1 a` | **MATCH** | MATCH |
| typed record literal `(@T){ ... }` | `examples/cover/record-literal-typed.nelua` | `3.0 4.0 1.0 0.0 3.0 4.0` | C compile failed (`struct nlrec0`) | **NELU_CRASH** | NELU_CRASH |
| `@union{ ... }` | `examples/cover/union-type.nelua` | `1` | `1` | **MATCH** | MATCH |
| `@enum{ A=0, B=1 }` | `examples/cover/enum-type.nelua` | `0` | `0` | **MATCH** | MATCH |
| `facultative(T)` (`?T`) | `examples/cover/facultative-type.nelua` | `hello` | `hello` | **MATCH** | MATCH |
| `pointer(T)` / `*T` | `examples/dump-analyzed-ast/types.nelua` | accepts | accepts | **MATCH** (M2) | MATCH |
| `array(T, N)` / `[]T` | `examples/dump-analyzed-ast/types.nelua` | accepts | accepts | **MATCH** (M2) | MATCH |
| `function(a: T): U` | `examples/dump-analyzed-ast/types.nelua` | accepts | accepts | **MATCH** (M2) | MATCH |
| `@-prefixed type constructor in type position` | `examples/dump-ast/_8.nelua` (`@record {...}`) | *oracle rejects* | parses | **DIFF** (M1) | DIFF |
| same, `@enum`/`@union` | `examples/dump-ast/_11.nelua`, `_12.nelua` | *oracle rejects* | parses | **DIFF** (M1) | DIFF |
| `@sequence(sequence(number))` generic instantiation | `examples/matmul.nelua` (transitively) | accepts | rejected | **NELU_REJECT** | NELU_REJECT |

Notes:
- `record-literal-typed.nelua` is the **one open gap** in the corpus: a
  `src/cgen.nim` lowering bug (typed record literal mis-lowers to an empty
  `struct nlrec0`).  Harness task only — the harness measures, does not repair.
- The three M1 DIFFs (`_8`/`_11`/`_12`) use an `@`-prefixed type constructor
  in type position that the oracle 0.2.0-dev rejects outright, so there is no
  oracle AST to diff against.  They are a corpus-convention issue, not a parser
  bug; the M1 baseline is 25 MATCH / 3 DIFF / 0 CRASH and the gate allows the
  count to improve.

### 4. Keywords as identifiers

The oracle reserves 26 type/annotation/declaration keywords but permits them as
ordinary identifiers; Nelu over-reserved all 26.  Each is a one-line probe
(`local <kw> = 42; print(<kw>)`), oracle and Nelu both print `42`.

| probe | verdict | baseline |
|---|---|---|
| `examples/cover/keyword-any.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-auto.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-boolean.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cchar.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cdouble.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cfloat.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cint.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-clong.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cond.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cshort.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-cvarargs.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-import.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-integer.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-isize.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-macro.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-number.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-string.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-type.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-usize.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-varanys.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-varargs.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-varautos.nelua` | **MATCH** | MATCH |
| `examples/cover/keyword-void.nelua` | **MATCH** | MATCH |

23 of the 26 are probed; `require`, `record`, `union` were verified separately
against the oracle and behave identically.  Control-flow keywords
(`if`/`for`/`while`/`end`/`then`/...), literals (`true`/`false`/`nil`/`nilptr`)
and operators (`and`/`or`/`not`/`break`/`goto`/`continue`/`defer`) stay
reserved, matching the oracle.

### 5. Metamethods

| element | probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|---|
| `__len` (M1) | `examples/cover/meta-len.nelua` | `42` | `42` | **MATCH** | MATCH |
| `__tostring` (M2) | `examples/cover/meta-tostring.nelua` | `R` | `R` | **MATCH** | MATCH |
| `__call` (M3) | `examples/cover/meta-call.nelua` | `6` | `6` | **MATCH** | MATCH |
| `__bnot` unary | `examples/cover/meta-bnot.nelua` | `-6` | `-6` | **MATCH** | MATCH |
| `__add` binary dispatch | `examples/cover/meta-binary-dispatch.nelua` | `3` | `3` | **MATCH** | MATCH |
| `__unm` unary dispatch | `examples/cover/meta-unary-dispatch.nelua` | `-5` | `-5` | **MATCH** | MATCH |
| `__index` (M4) | *no oracle-accepted probe* | rejects `r.x` | — | **NOT-RUN** | — |
| `__gc`/`__close`/`__next`/`__pairs`/`__mpairs`/`__convert`/`__atindex` | *not cleanly probeable* | wired | not wired | **NOT-RUN** | — |

M1–M5 are wired and MATCH; the remaining metamethods are marked (d) in the old
gap doc because the oracle requires specific method signatures that could not
be nailed down, so no oracle-accepted probe exists.

### 6. Preprocessor / macros / splices

| element | probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|---|
| `#[expr]#` splice (literal) | `examples/cover/macro-def.nelua` (transitively) | accepts | accepts | **MATCH** | MATCH |
| `#[x]#` splice of a variable reference | `examples/cover/splice-ident.nelua` | `5` | `5` | **MATCH** | MATCH |
| `#[name]#(...)` splice-call of a macro | `examples/cover/macro-def.nelua` | `42` | `42` | **MATCH** | MATCH |
| `## if / ## elseif / ## else / ## end` framing | `examples/www/preproc_if-ddx.nelua` | accepts | accepts | **MATCH** | MATCH |
| `##[[ ... ]]` long block | `examples/brainfuck.nelua` (transitively) | accepts | rejected | **NELU_REJECT** | NELU_REJECT |
| `#|name|#` name replacement | `examples/fibonacci.nelua` (transitively) | accepts | rejected | **NELU_REJECT** | NELU_REJECT |
| `static_assert` success path | `examples/www/check_fail-ddx.nelua` (transitively) | accepts | accepts | **MATCH** | MATCH |

### 7. Stdlib module reachability

All 21 top-level `lib/*.nelua` modules fail to compile through Nelu for a
handful of root causes (multi-line macro definition, `for ... in`, keyword
over-reservation, `in (expr)`, member access in `## if` conditions).  They are
not individually probed here; the probes that exercise them transitively are
the examples-parity DIFFs (below).  The old `nelu-language-coverage-gap.md`
§8 has the full root-cause table; it is superseded by this doc and the
examples-parity verdicts.

### 8. Examples parity (top-level `examples/*.nelua`)

| probe | oracle | Nelu | verdict | baseline |
|---|---|---|---|---|
| `helloworld-ddx.nelua` | `hello world` | same | **MATCH** | MATCH |
| `mersenne-ddx.nelua` | Mersenne primes | same | **MATCH** | MATCH |
| `brainfuck.nelua` | `Hello World!` | parse error (`##[=[` block) | **NELU_REJECT** | NELU_REJECT |
| `fibonacci.nelua` | `55` x4 | analyze error in `lib/math.nelua` (`#|name|#`) | **NELU_REJECT** | NELU_REJECT |
| `gameoflife.nelua` | clears board | analyze error in `lib/hash.nelua` (keyword `string`) | **NELU_REJECT** | NELU_REJECT |
| `matmul.nelua` | `-18.8963499125` | analyze error (`@sequence(sequence(number))`) | **NELU_REJECT** | NELU_REJECT |
| `record_inheretance.nelua` | full output | parse error (`##[[` + `#|name|#`) | **NELU_REJECT** | NELU_REJECT |
| `condots.nelua` | benchmark loop | runs forever | **SKIP** | SKIP |
| `snakesdl.nelua` | SDL game loop | runs forever | **SKIP** | SKIP |
| `overview.nelua` | illustrative | oracle exits 1 | **SKIP** | SKIP |

All five non-MATCH top-level examples are PARSE/ANALYZE failures rooted in four
parser/preprocessor gaps (`##[[`/`##[=[` multi-line Lua blocks, `#|name|#`
name replacement, dotted `global`/method names, `@ident(args)` generic
instantiation) plus one analyzer crash on static method calls — triaged in
`plan/examples-diffs-triage.md`.  None is a runtime-behaviour DIFF; none is a
regression (all are in the baseline).

### 9. `examples/www/` parity (112 files)

97 MATCH, 1 NELU_REJECT (`www_math.nelua` — analyze error in
`lib/detail/xoshiro256.nelua`), 1 ORACLE_FAIL (`www_string_concat-ddx-ffs.nelua`
— a Nelu extension the oracle rejects by design), 13 BOTH_FAIL (the `-ffs`
files: oracle-rejects that neither compiler runs).

## Drop-in fidelity

The harness reports the same MATCH/DIFF/CRASH verdicts the six former gate
scripts report on this tree:

| gate | old tally | harness tally |
|---|---|---|
| `plan/regress.py` M1 | 25 MATCH / 3 DIFF / 0 CRASH | 25 MATCH / 3 DIFF / 0 CRASH |
| `plan/regress.py` M2 | 14/14 MATCH | 14 MATCH / 0 DIFF |
| `plan/cmp.py` | 1 diff out of 40 (case 25) | 39 MATCH / 1 ORACLE_FAIL (case 25) |
| `plan/cover_gate.py` | 43 MATCH / 1 NELU_CRASH | 43 MATCH / 1 NELU_CRASH |
| `plan/wwwcheck.py` | 97 PASS / 2 DIFF / 13 SKIP | 97 MATCH / 1 NELU_REJECT / 1 ORACLE_FAIL / 13 BOTH_FAIL |
| `plan/examples_parity.py` | 2 MATCH / 5 DIFF / 3 SKIP | 2 MATCH / 5 NELU_REJECT / 3 SKIP |

MATCH counts are identical everywhere.  The non-MATCH labels are richer: the old
gates' single `DIFF`/`SKIP` now disambiguate the actual cause (parse/analyze
reject vs C-gen crash vs both-fail vs oracle-side unsupported), which is the
point of the unified vocabulary.

## Open gaps

1. **`record-literal-typed.nelua`** — NELU_CRASH.  Typed record literal
   `(@T){ ... }` mis-lowers to an empty `struct nlrec0` in `src/cgen.nim`.
   Harness task only; the harness measures, does not repair.
2. **Six NELU_REJECT examples** (`brainfuck`, `fibonacci`, `gameoflife`,
   `matmul`, `record_inheretance`, `www_math`) — stdlib reachability blocked by
   the parser/preprocessor gaps listed in §8.  Not regressions; in the baseline.
3. **Three M1 DIFFs** (`dump-ast/_8`/`_11`/`_12`) — `@`-prefixed type
   constructor the oracle rejects; corpus-convention issue, at baseline.
4. **`for ... in` iterator form** — no oracle-accepted probe exists, so
   NOT-RUN.  Nelu rejects it ("not supported").
5. **`__index` and the iteration/pair metamethods** — NOT-RUN; the oracle
   requires signatures that could not be nailed down.

## Old docs

`plan/cover-corpus.md`, `plan/nelu-language-coverage-gap.md`, and the coverage
sections of `plan/GATES.md` are in `tmp/legacy/docs/`.  `plan/examples-diffs-triage.md`
and `plan/examples-diffs-design.md` are in `tmp/legacy/` (their DIFFs are all
closed or in-baseline; kept for reference).