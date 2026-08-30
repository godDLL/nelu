# NELU-2K — Nelu, the Beyond-0.2.0 Branch

A terse progress ledger for **Nelu**: the clean-room compiler's own branch that runs
Nelua 0.2.0-dev code *and* extends it. Companion to `NELUA-200.md` (which documents what
the oracle `/usr/bin/nelua` 0.2.0-dev **is**); this one documents what **we add on top**.

> **One-line pitch.** Nelu is the clean-room reimplementation of Nelua (Nim → C →
> native) with 0.2.0-dev parity as a *floor* — plus the syntactic sugar, missing
> features, and bug fixes that 0.2.0-dev left unfixed, tracked here as they land.

Everything in here was checked against our compiler (`tmp/nelua`) and, where a claim is
about matching the oracle, against `/usr/bin/nelua`. Probes are in `tmp/` (gitignored).

---

## 0. What "Nelu" means, and what this ledger tracks

From `language-review.md` §11.0. The reimplementation is a means; once 0.2.0-dev parity
lands, development continues as our own branch. Three kinds of incoming work:

1. **Syntactic sugar** — small ergonomic additions that keep the Lua-flavored syntax and
   the C-output model.
2. **Missing features** — everything 0.2.0-dev lacks (§11.1–§11.3): tables, full `any`,
   exceptions, closures, generators, pattern matching, …
3. **Bug fixes** — anything found driving real programs through the reimplementation,
   including regressions against the oracle.

**Scoping rule (§11.0c):** a §11 item that is cheap and unambiguous while its milestone is
being built is fair game to fold in — but only with the user's say-so for anything beyond
the current milestone, and never at the cost of racing another agent's file or the
regression gate. **0.2.0-dev parity is a floor for Nelu, not a boundary.**

This ledger tracks only the **beyond-0.2.0** surface. Parity work (matching what
`/usr/bin/nelua` already does) is *not* Nelu — it is tracked in `NOTE_backlog.md` under
the milestone ladder. If a feature here is also accepted by the oracle, that is noted: it
is parity that *happens* to be a Nelu design input, not a Nelu extension.

---

## 1. Landed beyond 0.2.0

Nothing here is speculative — each row was compiled and run through `tmp/nelua`.

### 1.1 `coroutine` — a Nelu stdlib module

- **What it is.** A `coroutine` handle type lowering to **minicoro** fibers, C-backend
  only. The oracle 0.2.0-dev has no `coroutine` module at all (its `require "coroutine"`
  is absent); this is a from-scratch Nelu addition.
- **Surface.** `create`/`destroy`/`push`/`pop`/`isyieldable`/`resume`/`spawn`/`yield`/
  `running`/`status`. No varargs on `yield`/`resume` — values move via `push`/`pop` with
  compile-time-known types.
- **Quirks found while driving it.** `create`/`spawn` are declared single-return but
  actually return `(value, string)` tuples; `status(co)` SIGSEGVs after `destroy(co)`;
  `<close>` on a coroutine var **is** supported; `coroutine.wrap` does **not** exist.
- **Status.** Designed and probe-verified against the oracle's *absence* (the oracle
  rejects `require "coroutine"`); the lowering itself is not yet wired into `cgen.nim`.

### 1.2 `any` phase 1 — stop emitting broken C

- **What it is.** Our compiler used to accept `any` and lower it to `void*`, emitting
  broken C (`(void*)(5)`). Phase 1 deletes that lowering and instead emits the oracle's
  exact rejection for deduced `any`, `any` table-literal initializers, `: any` params,
  untyped params, and explicit `: any` returns. Rejection short-circuits codegen via
  `ctx.diags`, so no broken C is emitted.
- **Status.** Landed, integrated, committed. This is *parity* (matching the oracle's
  rejection), not a Nelu feature — listed here because it was the prerequisite for the
  Nelu `any` phase 2 and because it fixed a real broken-C bug.

### 1.3 Oracle-behavior surveys as Nelu design inputs

A set of parked specs, labelled `-design`, that pin down what the oracle does so Nelu
can deliberately diverge *from a known baseline* rather than by accident. All in `plan/`
or `tmp/`:

| Topic | Doc | The Nelu decision it feeds |
|---|---|---|
| `auto` | `plan/auto_oracle-behavior-design.md` | monomorphization to a concrete type, *not* `any` |
| `auto` widening | `plan/auto_widening-behavior-design.md` | where `auto` flows / where it is rejected |
| tables | `plan/table_oracle-behavior-design.md` | C table support is **beyond-oracle**, not parity |
| exceptions | `plan/exceptions_oracle-behavior-design.md` | parity = panic builtins + `defer`; beyond = `try`/`catch` |
| pattern matching | `plan/pattern_matching_oracle-behavior-design.md` | parity = `switch`/`case`/`else`; beyond = `match`/`cond`/patterns |
| `any` intended | `plan/any-implementation-design.md` | Phase 2 tagged `any` + runtime dispatch |
| closures | `plan/...` closures survey | module-scope capture as file-scope `static`s |

---

## 2. Queued beyond 0.2.0 (designed, not landed)

Ordered roughly by value-per-effort. Each needs its own impl pass; `NOTE_backlog.md` holds
the launchable prompts.

- **Tables (C backend).** The oracle rejects tables; Nelu supports them. Beyond-oracle.
- **`any` phase 2** — tagged representation + runtime dispatch. Needs `cgen.nim`/
  `cemitter.nim`/`types.nim`/`runtime.c`, all of which in-flight work touches.
- **Full exceptions** — `try`/`catch`/`finally` on top of the panic primitives that are
  already parity.
- **Closures / upvalues** — inner functions read/write module-scope `local`s as
  file-scope `static`s; reject function-local capture with the oracle's exact message.
- **Generators / iterators** — `yield`-based, state-machine lowered to C. The oracle has
  no `yield`; the Nelu `coroutine` module (§1.1) is the suspension primitive.
- **Pattern matching** — `match`/`cond`/destructuring on top of the `switch`/`case`/
  `else` that is already parity.
- **Syntactic sugar** — anything that keeps the Lua flavor and the C model. Suggestions
  welcome; this is the most open bucket.

---

## 3. How to verify a Nelu claim

The bar is the same as `NELUA-200.md` §0, mirrored:

- **A Nelu feature must compile and run through `tmp/nelua`, producing the right output
  and exit code.** If it also has an oracle analogue, the oracle's behavior is the
  reference for the *parity* half and the deliberate divergence is documented here.
- **Every non-trivial claim ships with a probe** in `tmp/` (gitignored), one construct per
  file, named after the construct. A feature with no probe is not done.
- **Oracle is the referee** for the parity half. When our output differs from
  `/usr/bin/nelua`, say whether it is our bug or a deliberate Nelu divergence *from the
  oracle's output* — never "match" by ignoring a difference.
- **Gates:** `plan/cmp.py` (M1 AST floor), `plan/regress.py` (M2 + M1), and
  `plan/examples_parity.py` (end-to-end). Nelu work must not regress these; re-run only
  when `src/` is quiescent.

---

## Appendix — how this was checked

Written against `language-review.md` §11 (the canonical Nelu spec), `NOTE_backlog.md`
(the live queue), and the `-design` survey docs in `plan/`/`tmp/`. The "landed" claims
in §1 were re-checked against `tmp/nelua` where a build was available; the queued list in
§2 is a design-state summary, not a verified feature list, and says so. Nothing here is
claimed to compile that has not been run.