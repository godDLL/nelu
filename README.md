# Nelua-in-Nim: Clean-Room Reimplementation — Work Plan

Target: a Nelua compiler in **Nim** (2.2.10, `/usr/bin/nim`), emitting **C**,
compiled through `gcc`/`cc`, covering Nelua 0.2.0-dev and the beyond-enhancements
in `language-review.md`.

Reference under test: `/usr/bin/nelua`, Build 1635 (`0.2.0-dev.1635+a5845056`).

This is a step-by-step plan, not a second spec: every path, ownership, and
verification command is concrete and executable. It is kept terse on purpose —
`language-review.md` is the canonical spec; this file records decisions and state
that change.

- The oracle's source is vendored at `lualib/nelua/` — read for semantics, but
  **do not modify and do not port into `src/`**.
- After the reimplementation lands, development continues as the user's own
  branch **Nelu** (syntactic sugar, missing features, bug fixes). 0.2.0-dev
  parity is a *floor* for Nelu, not a boundary.

## Table of contents

1. [Environment](#1-environment)
2. [Current status](#2-current-status)
3. [Where things live](#3-where-things-live)
4. [File ownership](#4-file-ownership)
5. [How to verify](#5-how-to-verify)
6. [Decisions settled](#6-decisions-settled)
7. [Decisions open](#7-decisions-open)
8. [Risks](#8-risks)
9. [Quick-start](#9-quick-start)

---

## 1. Environment

| Item | Value |
|------|-------|
| Nim | `/usr/bin/nim`, 2.2.10 |
| Reference nelua | `/usr/bin/nelua`, Build 1635 |
| C compiler | `/usr/bin/gcc`, `/usr/bin/cc` |

Real CLI flags on Build 1635 (these differ from Appendix B of the review — use
these):

```
-r --release   -b --binary   -c --code (C only)
-a --analyze   --lint        --print-ast
--print-analyzed-ast  --print-ppcode  --print-code
-P <pragma>    -D <define>   --cc <cc>
--cflags <...> --ldflags <...> --path <dir>
-o <output>    --cache-dir <dir>  -s --strip-bin
--sanitize      -g <generator>     --no-cache
```

Module resolution (needed for `require`): dotted `allocators.arena` →
`lib/allocators/arena.nelua`; `require 'tests.io_test'` → relative to cwd;
leading-dot `.foo` → relative to the requiring file's dir. Search order:
requiring file's dir (only for `.`-prefixed names), then `--path` entries, then
the bundled `lib/`.

---

## 2. Current status

| Milestone | Scope | State |
|-----------|-------|-------|
| M1 | lexer + parser + AST | committed |
| M2 | type system, scope, symbols | committed |
| M3 | preprocessor | committed; Lua-side `##`/inject in flight |
| M4 | analyzer | committed |
| M5 | C runtime | committed (dead code — see `language-review.md`) |
| M6 | codegen | committed |
| M7 | end-to-end compile + run | committed (driver fix pending commit) |
| M8 | stdlib compilation | committed |
| M9 | bootstrap | stretch |
| M10 | beyond-features sprints | queued: exceptions (in flight), pattern matching, enum, `any` phase 2, tables, closures, generators |

Active work (live queue in `tmp/NOTE_backlog.md`):
- **Module system** — phase 1a (parse + resolve + recursive compile + cache)
  committed `02e162f`; **phase 1b** (analyzer scope-wiring + cgen inline dep
  emission) done, gate-verified, **not yet committed**.
- **Bounded examples parser gaps** — in flight (literal suffixes, `<comptime>`,
  `[N]T`, print tab separator, defensiveness).
- **`any` type** — phase 1 done & integrated; phase 2 (tagged) deferred.
- **Exceptions** — in flight.
- **Queued:** pattern matching, record/enum type system.

---

## 3. Where things live

```
nelua-lang/
├── AGENT.md            # standing brief for agents (read this first)
├── README.md           # this plan
├── language-review.md  # canonical spec/architecture (read-only)
├── NELUA-200.md        # reader reference aid, checked against the oracle
├── CONTRIBUTING.md     # untracked
├── nim.cfg             # compiler build flags
├── tmp/                # scratch: build artefacts, probes, captures. Stays until the user deletes it.
├── plan/               # design docs + survey probes (scratch, not tracked)
├── src/                # the compiler (what we ship)
├── lib/, lualib/       # stdlib + oracle source (read-only reference)
├── examples/, tests/, spec/   # oracle's own corpus (read-only reference)
└── plan/              # design docs + gates (tracked): cmp.py, regress.py,
                      #   examples_parity.py
```

`src/` modules (current):

| Module | Role |
|--------|------|
| `main.nim` | CLI entry: parse opts, drive the pipeline |
| `compile.nim` | compile driver (parse → preproc → analyze → codegen → cc) |
| `config.nim` | Config object: pragmas, paths, cc, flags |
| `cli.nim` | CLI option parsing |
| `span.nim`, `errors.nim` | source location + diagnostics |
| `lexer.nim` | tokenizer |
| `parser.nim` | recursive descent → AST |
| `ast.nim`, `astshapes.nim` | AST node types + shape registry |
| `sema.nim` | semantic-analysis helpers |
| `types.nim` | type object hierarchy + properties |
| `preprocessor.nim` | preprocessor driver |
| `luaengine.nim` | embedded Lua 5.x VM running `##` blocks (see §6) |
| `analyzer.nim` | visitor-based analyzer |
| `cgen.nim`, `cemitter.nim`, `cgen_types.nim` | AST → C visitor + C type mapping |
| `runtime.c` | C runtime the generated code links against |

Vendored third-party (read-only, **do not port**): `src/lua/*`, `src/lpeglabel/`,
`src/rpmalloc/`, `src/luainit.c`.

`tmp/` contents worth knowing:
- `tmp/NOTE_backlog.md` — the task queue.
- `tmp/m2_corpus/`, `tmp/corpus_nelua/` — oracle AST dumps the gates diff against.

---

## 4. File ownership

Tasks own **only** their listed new files and must not edit files owned by other
tasks or the gate scripts. Current owners (check `git status` — it shows
in-flight edits):

| Owner | Files |
|-------|-------|
| bounded-gaps (running) | `parser.nim`, `lexer.nim`, `analyzer.nim`, `cgen.nim` |
| exceptions (running) | exceptions feature files (see its design doc) |
| `any` (done, integrated) | `cgen_types.nim`, `analyzer.nim` (any-rejection blocks) |
| module phase 1b (mine) | `analyzer.nim`, `cgen.nim` |
| gate scripts (mine) | `plan/cmp.py`, `plan/regress.py`, `plan/examples_parity.py` |

**Concurrency: never launch more than 2 agents at once.** Files edited by
multiple agents race — queue the rest and re-check ownership before launching.
`analyzer.nim` and `cgen.nim` are currently edited by three owners each.

---

## 5. How to verify

- **Build:** `nim c -d:release --path:src -o:tmp/nelua src/main.nim`
- **Oracle dumps:** `--print-ast` (M1), `--print-analyzed-ast` (M2→M4).
- **Gates:** `python3 plan/cmp.py` (M1 diff floor), `python3 plan/regress.py` (permanent
  regression loop), `python3 plan/examples_parity.py` (end-to-end execution).
- **End-to-end:** parse → preprocessor → analyze → codegen → gcc with
  `src/runtime.c` + `-lm` → run. The real test is a compiled program producing
  the right output and exit code 0.

Note: `regress.py` rebuilds `tmp/nelua` whenever any `src/*.nim|*.c` is newer
than the binary. While any agent is mid-edit on shared `src/`, that rebuild
produces an inconsistent binary and the gate goes red on unrelated code — a
false alarm. Re-run only when `src/` is quiescent.

---

## 6. Decisions settled (do NOT re-litigate)

- Target model: Nelua source → (new compiler) → C source → (gcc/cc) → binary.
- AST node shapes: exactly Appendix A of the review, with `tag`, `attr`, `is_*`.
- Type hierarchy properties: `is_integral`, `is_float`, `is_stringy`,
  `is_pointer`, `is_array`, `is_record`, `is_niltype`, `metafields`, `codename`,
  `typeid`, `nickname`, `name`.
- C generation: single readable C file, sections (directives / declarations /
  definitions / bodies), `nelua_main` entry.
- Stdlib: ship the reference `lib/*.nelua` verbatim; the new compiler must
  compile them.
- Parser: hand-written recursive descent (source spans, full error control).
- GC: conservative mark-sweep in the emitted C runtime header; `-P nogc` removes
  it cleanly.
- **Preprocessor: embedded Lua VM, not a Nim reimplementation.** `luaengine.nim`
  compiles `src/lua/*` + `luainit.c` into the binary and runs `##` blocks as Lua
  chunks (state persists across blocks and across `require`d modules within one
  compilation; `resetLuaState()` isolates each compile). This reversed the
  "reimplement in Nim" recommendation — the macro surface is now Lua-driven.
- **Faithful-mode divergences to replicate verbatim** (M0–M8):
  1. `local` is not hoisted (scope at its declaration line).
  2. `string.find` returns `(0, 0)` on no match, never `nil`.
  3. `string.match` returns a *sequence* of captures, not a string.
  4. No `_` discard — `_` is an undeclared identifier.
  5. `os.execute` returns `true`/`false`, not an exit code.
  6. `any` is unsupported (deduced-`any` is a compile error); `facultative(T)`
     cannot be used in return position.
  7. C-keyword record fields break C emission — reject at parse time.

---

## 7. Decisions still open

| # | Decision | Recommendation |
|---|----------|----------------|
| 1 | 128-bit int/float type width | single config knob, default 64-bit everywhere |
| 2 | Freestanding mode | `-P freestanding` omits libc-dependent runtime parts |
| 3 | Test harness | Nim `unittest` for the compiler; nelua programs diffed against the oracle |
| 4 | `any` full representation | tagged + runtime dispatch (phase 2), deferred until codegen files free up |
| 5 | C type-name mangling for records/unions/enums | define in `types.nim` codename rules (Q1) |
| 6 | `traits.typeidof` id assignment | monotonic per type, stable across runs (Q2) |
| 7 | `--cache-dir` incremental compilation | enhancement; accept full recompilation for M0–M8 (Q3) |

---

## 8. Risks

| Risk | Sev | Mitigation |
|------|-----|------------|
| Preprocessor generality (generics, concepts, AST mutation) is the hardest subsystem; stdlib containers depend on it | H | Invest M3–M4 before codegen; port `preprocessor_spec` first |
| C codegen correctness for metamethod dispatch, multi-return structs, polymorphic specialization | H | M7 acceptance gate; structural `--print-code` diff |
| Conservative GC stack scanning is error-prone | M | Make `-P nogc` work from M5 so the non-GC path is testable first |
| Merge friction on shared contract files (`ast.nim`, `types.nim`) | M | Freeze contracts per milestone; contract owner resolves disputes |
| Spec inaccuracies propagate into the implementation | L | Every acceptance test runs against `/usr/bin/nelua`; record corrections here |
| Nim 2.2.10 skew vs. features used | L | Pin `nim.cfg`; stdlib only, zero nimble deps |

---

## 9. Quick-start

```bash
# build the compiler
nim c -d:release --path:src -o:tmp/nelua src/main.nim

# analyze only
./tmp/nelua -a examples/fibonacci.nelua

# compile a program to a binary
./tmp/nelua -b -o /tmp/out examples/helloworld.nelua
/tmp/out

# acceptance diff against the oracle
/usr/bin/nelua -b -o /tmp/ref examples/fibonacci.nelua
./tmp/nelua -b -o /tmp/new examples/fibonacci.nelua
diff <(/tmp/ref) <(/tmp/new) && echo PASS
```

Throwaway probes go in `project/tmp/`, never `/tmp` and never the project root.
No `git` commands unless the user explicitly instructs it.