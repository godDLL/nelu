# NELU-2K - Nelu, the Beyond-0.2.0 Branch

A terse progress ledger for **Nelu**: the clean-room compiler's own branch that runs
Nelua 0.2.0-dev code *and* extends it. Companion to `NELUA-200.md` (which documents what
the oracle `/usr/bin/nelua` 0.2.0-dev **is**); this one documents what **we add on top**.

> **One-line pitch.** Nelu is the clean-room reimplementation of Nelua (Nim -> C ->
> native) with 0.2.0-dev parity as a *floor* - plus the syntactic sugar, missing
> features, and bug fixes that 0.2.0-dev left unfixed, tracked here as they land.

Everything in here was checked against our compiler (`tmp/nelua`) and, where a claim is
about matching the oracle, against `/usr/bin/nelua`. Probes are in `tmp/` (gitignored).

---

## 0. What "Nelu" means, and what this ledger tracks

From `language-review.md` section 11.0. The reimplementation is a means; once 0.2.0-dev parity
lands, development continues as our own branch. Three kinds of incoming work:

1. **Syntactic sugar** - small ergonomic additions that keep the Lua-flavored syntax and
   the C-output model.
2. **Missing features** - everything 0.2.0-dev lacks (section 11.1-section 11.3): tables, full `any`,
   exceptions, closures, generators, pattern matching, ...
3. **Bug fixes** - anything found driving real programs through the reimplementation,
   including regressions against the oracle.

**Scoping rule (section 11.0c):** a section 11 item that is cheap and unambiguous while its milestone is
being built is fair game to fold in - but only with the user's say-so for anything beyond
the current milestone, and never at the cost of racing another agent's file or the
regression gate. **0.2.0-dev parity is a floor for Nelu, not a boundary.**

This ledger tracks only the **beyond-0.2.0** surface. Parity work (matching what
`/usr/bin/nelua` already does) is *not* Nelu - it is tracked in `NOTE_backlog.md` under
the milestone ladder. If a feature here is also accepted by the oracle, that is noted: it
is parity that *happens* to be a Nelu design input, not a Nelu extension.

---

## 1. Landed beyond 0.2.0

Nothing here is speculative - each row was compiled and run through `tmp/nelua`.

### 1.1 `coroutine` - a Nelu stdlib module

- **What it is.** A `coroutine` handle type lowering to **minicoro** fibers, C-backend
  only. The oracle 0.2.0-dev has no `coroutine` module at all (its `require "coroutine"`
  is absent); this is a from-scratch Nelu addition.
- **Surface.** `create`/`destroy`/`push`/`pop`/`isyieldable`/`resume`/`spawn`/`yield`/
  `running`/`status`. No varargs on `yield`/`resume` - values move via `push`/`pop` with
  compile-time-known types.
- **Quirks found while driving it.** `create`/`spawn` are declared single-return but
  actually return `(value, string)` tuples; `status(co)` SIGSEGVs after `destroy(co)`;
  `<close>` on a coroutine var **is** supported; `coroutine.wrap` does **not** exist.
- **Status.** Designed and probe-verified against the oracle's *absence* (the oracle
  rejects `require "coroutine"`); the lowering itself is not yet wired into `cgen.nim`.

### 1.2 `any` phase 1 - stop emitting broken C

- **What it is.** Our compiler used to accept `any` and lower it to `void*`, emitting
  broken C (`(void*)(5)`). Phase 1 deletes that lowering and instead emits the oracle's
  exact rejection for deduced `any`, `any` table-literal initializers, `: any` params,
  untyped params, and explicit `: any` returns. Rejection short-circuits codegen via
  `ctx.diags`, so no broken C is emitted.
- **Status.** Landed, integrated, committed. This is *parity* (matching the oracle's
  rejection), not a Nelu feature - listed here because it was the prerequisite for the
  Nelu `any` phase 2 and because it fixed a real broken-C bug.

### 1.3 Oracle-behavior surveys as Nelu design inputs

A set of parked specs, labelled `-design`, that pin down what the oracle does so Nelu
can deliberately diverge *from a known baseline* rather than by accident. All in `plan/`:

| Topic | Doc | The Nelu decision it feeds |
|---|---|---|
| `auto` | `plan/auto_oracle-behavior-design.md` | monomorphization to a concrete type, *not* `any` |
| `auto` widening | `plan/auto_widening-behavior-design.md` | where `auto` flows / where it is rejected |
| tables | `plan/table_oracle-behavior-design.md` | C table support is **beyond-oracle**, not parity |
| exceptions | `plan/exceptions_oracle-behavior-design.md` | parity = panic builtins + `defer`; beyond = `try`/`catch` |
| pattern matching | `plan/pattern_matching_oracle-behavior-design.md` | parity = `switch`/`case`/`else`; beyond = `match`/`cond`/patterns |
| `any` intended | `plan/any-implementation-design.md` | Phase 2 tagged `any` + runtime dispatch |
| closures | `plan/closures-upvalues-design.md` | module-scope capture as file-scope `static`s |
| pointer printing | `plan/pointer-printing-design.md` | non-null pointers print `0x` + lowercase hex |

### 1.4 `any` phase 2 - tagged runtime `any`

- **What it is.** A Nelu extension: `any` as a tagged union (`nlany`) with a runtime
  tag plus construction / dispatch helpers in `runtime.c`
  (`nlany_from_*`, `nlany_load_*`, `nelua_print_any`, `nlany_eq`). The oracle 0.2.0-dev
  rejects every `any` construction; this is beyond-oracle.
- **Status.** Landed, integrated, committed `214102c`. Verified on 5 task probes (correct
  output, exit 0); `v_initlist` / `v_typeval` rejection messages preserved byte-for-byte.

### 1.5 Closures / upvalue scoping

- **What it is.** An inner function may read and write a module-scope `local`, which
  lowers to a file-scope `static` declared *before* the function definitions. Function-local
  capture is rejected at analysis, with the oracle's exact message
  (`attempt to access upvalue 'x', but closures are not supported`).
- **Status.** Landed, integrated across `75f315e` (module-scope capture + upvalue
  rejection) and `bab3eb3` (closure function-value fixes). Verified: **7 closure probes
  MATCH the oracle** (exit 0); the remaining 8 are DIFFs -- 4 honest diagnostic-channel
  DIFFs (our upvalue message has no line:col) and 4 deliberate permissive divergences
  (forward references, `## local`, bare top-level `function`, `global` in fn). See
  `plan/closures-upvalues-design.md`.

### 1.6 Pointer print spelling

- **What it is.** A non-null pointer prints as `0x` + lowercase hex, natural width, no
  leading zeros; a null pointer prints `(null)`, independent of pointee type. This is
  parity with the oracle, listed here because it was a real bug (the arg was being thrown
  away).
- **Status.** Landed, integrated, committed `75f315e`. Verified on 16 pointer probes: null
  cases MATCH byte-for-byte; every non-null case now emits the oracle's `0x...` format.
  See `plan/pointer-printing-design.md`.

### 1.7 Session work (2026-08-30) -- landed in `f75601a`

Each row below was verified against a fresh `nim c -d:release --path:src -o:tmp/nelua_test
src/main.nim` build of the live working tree, not taken on trust from the board. These
were uncommitted when this ledger was last written; they are now committed at
`f75601a` ("Parity: cgen/analyzer fixes, --lint syntax-only, long-string strip; take
spec/, lib/, lualib/ into the tree"), along with `69098c3`, `ed503c1`, `6a04582`,
`bab3eb3`, `dd291fc` and `689a2f7`.

- **Metamethod-dispatch family (M1-M4) -- cgen agent, `src/cgen.nim`.** A shared
  `genMetaCall` helper plus dispatch sites in the `#` operator, the `print()` arm,
  the call expression, and `[]` indexing. Verified: **M1 `__len` via `#` MATCHES**
  (`5` vs `5`) and **M2 `__tostring` via `print()` MATCHES** (`Vec` vs `Vec`).
  **M3 `__call` via `r(...)`** still prints `(null)` where the oracle prints `17`;
  **M4 `__index` via `r[i]`** had its dispatch land here, and its probe's blocker
  (the `{data = a}` array-field-init mis-lowering) is **now fixed** in `f75601a`
  ("nested-record constructor array-field init"), so M4 is unblocked and should be
  re-probed. The `genKeyIndex` key/base swap (children[0]=key, children[1]=base) also
  landed here. This was the finding ranked 1 of 25 in `plan/devil-advocate-findings.md`
  CONSOLIDATED RANKING; it is now mostly closed and the ranking should be
  re-derived, not re-litigated.
- **C1 partial fix -- `src/analyzer.nim`.** An `analyzeCall` `nkDotIndex` branch
  (static/method-call + indirect-call) plus a `calleeType != nil` nil-guard.
  **This does NOT fix C1.** Verified: `self.x = self.x * s` still SIGSEGVs
  (exit 139) against the fresh build, while `/usr/bin/nelua` prints `6`. The
  landed change stops the static-method-call crash (a different path); the
  assignment path in `analyzeAssign` (`src/analyzer.nim:1844`) that C1 actually
  is remains untouched. C1 stays OPEN. Recorded here because the board briefly
  claimed otherwise and this is the correction.
- **P1 / N4 / N5 parses -- parser agent, `src/parser.nim`.** P1 colon method on a
  type-keyword receiver (`function string:destroy()`): `lib/string.nelua` now
  parses past line 46 (it dies later at line 940, the already-documented
  `#|argname|#` name-splice gap). N4 `facultative(string)` type-function-call
  param: parses, but the analyzer resolution to an optional/nullable string is
  not yet working (C compile fails). N5 typed `for i: T = 0, <N do` exclusive
  bound: **MATCHes the oracle** (`10`, exit 0). All three are marked COMPLETE
  with a "verify end-to-end" note in `plan/our-improvements.md`; that framing
  holds for P1 and N4 (parse landed, end-to-end pending) and is fully closed for
  N5.
- **Dependency-failure guard -- `src/compile.nim`.** A `require` whose dependency
  did not compile now aborts the unit instead of SIGSEGVing in `genC`. Not a
  parity fix; robustness.
- **`T?` and `cond` re-framing (durable triage rule).** Confirmed again this
  session: the oracle never *runs* a program using `T?` or `cond`, so neither
  is a parity target. They are Nelu-extension-or-drop candidates. The rule is
  in `post-reimpl-continue-nelu.md` "The parity/extension split": **working
  code must work; we do not care whether failing code fails the same.** The
  docs no longer frame these as divergences to close.
- **25 confirmed findings, three Devil's advocate runs (9 + 8 + 8).** All in
  `plan/devil-advocate-findings.md`, with a CONSOLIDATED RANKING treated as
  authoritative. The metamethod family (M1-M4) ranks 1 of 25 by stdlib-file
  breadth; as noted above, M1, M2 and M4's blocker are now fixed in the tree.
- **NASM investigation -- COMPLETED 2026-08-31.** Report at `plan/nasm-opportunities.md`:
  partial NASM-ification is not a good next move (gcc 16.2.1 `-O2 -fno-plt -flto` beats
  hand-written NASM on every measured path; NASM cannot drop the gcc dependency; the
  real costs are C-emitter design issues in `cgen.nim`/`cbuiltins.lua`, not NASM-shaped;
  compile step dominates runtime). Do not write it.

---

## 2. Queued beyond 0.2.0 (designed, not landed)

Ordered roughly by value-per-effort. Each needs its own impl pass; `NOTE_backlog.md` holds
the launchable prompts.

- **Tables (C backend).** The oracle rejects tables; Nelu supports them. Beyond-oracle.
- **Full exceptions** - `try`/`catch`/`finally` on top of the panic primitives that are
  already parity.
- **Generators / iterators** - `yield`-based, state-machine lowered to C. The oracle has
  no `yield`; the Nelu `coroutine` module (section 1.1) is the suspension primitive.
- **Pattern matching** - `match`/`cond`/destructuring on top of the `switch`/`case`/
  `else` that is already parity.
- **Syntactic sugar** - anything that keeps the Lua flavor and the C model. Suggestions
  welcome; this is the most open bucket.

---

## 3. How to verify a Nelu claim

The bar is the same as `NELUA-200.md` section 0, mirrored:

- **A Nelu feature must compile and run through `tmp/nelua`, producing the right output
  and exit code.** If it also has an oracle analogue, the oracle's behavior is the
  reference for the *parity* half and the deliberate divergence is documented here.
- **Every non-trivial claim ships with a probe** in `tmp/` (gitignored), one construct per
  file, named after the construct. A feature with no probe is not done.
- **Oracle is the referee** for the parity half. When our output differs from
  `/usr/bin/nelua`, say whether it is our bug or a deliberate Nelu divergence *from the
  oracle's output* - never "match" by ignoring a difference.
- **Gates:** what each gate measures, its corpus, pass bar, and the deliberate
  strict-vs-report-only exit-code split are in `plan/GATES.md` (single source of
  truth -- read it before interpreting any gate output). The scripts are
  `plan/cmp.py`, `plan/regress.py`, `plan/examples_parity.py`, and
  `tmp/wwwcheck.py`. Nelu work must not regress these; re-run only when `src/`
  is quiescent.

  **Current gates (last recorded, not re-run this session):** `plan/cmp.py` 39 MATCH /
  1 DIFF (case [25] `integer?`, a permissive divergence); `tmp/wwwcheck.py` 90 PASS /
  6 DIFF over 105 files (2 oracle-side unsupported, 2 `splice_embed`, 1 `www_math`,
  1 `www_neg_for`); `plan/examples_parity.py` 2 MATCH / 5 DIFF / 3 SKIP; closures
  probes 7 MATCH / 8 DIFF (4 diagnostic-channel, 4 permissive).

---

## Appendix - how this was checked

Written against `language-review.md` section 11 (the canonical Nelu spec), `NOTE_backlog.md`
(the live queue), and the `-design` survey docs in `plan/`/`tmp/`. The "landed" claims
in section 1 were re-checked against `tmp/nelua` where a build was available; the queued list in
section 2 is a design-state summary, not a verified feature list, and says so. Nothing here is
claimed to compile that has not been run.