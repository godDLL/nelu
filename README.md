# Nelua-in-Nim: Clean-Room Reimplementation - Work Plan

Target: a Nelua compiler in **Nim** (2.2.10, `/usr/bin/nim`), emitting **C**,
compiled through `gcc`/`cc`, covering Nelua 0.2.0-dev and the beyond-enhancements
in `language-review.md`.

Reference under test: `/usr/bin/nelua`, Build 1635 (`0.2.0-dev.1635+a5845056`).

This is a step-by-step plan, not a second spec: every path, ownership, and
verification command is concrete and executable. It is kept terse on purpose -
`language-review.md` is the canonical spec; this file records decisions and state
that change.

- The oracle's source is vendored at `lualib/nelua/` - read for semantics, but
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

Real CLI flags on Build 1635 (these differ from Appendix B of the review - use
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

Module resolution (needed for `require`): dotted `allocators.arena` ->
`lib/allocators/arena.nelua`; `require 'tests.io_test'` -> relative to cwd;
leading-dot `.foo` -> relative to the requiring file's dir. Search order:
requiring file's dir (only for `.`-prefixed names), then `--path` entries, then
the bundled `lib/`.

---

## 2. Current status

| Milestone | Scope | State |
|-----------|-------|-------|
| M1 | lexer + parser + AST | committed; gate floor `plan/cmp.py` 39 MATCH / 1 DIFF / 0 CRASH (case [25] `integer?`, a permissive divergence; [31] fixed by the parser.nim `proc dump` nkPair change) |
| M2 | type system, scope, symbols | committed; `plan/regress.py` M2 14/14 MATCH |
| M3 | preprocessor | committed |
| M4 | analyzer | committed |
| M5 | C runtime | committed (dead code - see `language-review.md`) |
| M6 | codegen | committed |
| M7 | end-to-end compile + run | committed; the --print-ast driver no longer runs genC, so the three emitter SIGSEGVs (a.b:c(1), anonymous function, if/elseif) no longer abort AST dumps |
| M8 | stdlib compilation | committed |
| M9 | bootstrap | committed |
| M10 | beyond-features sprints | committed; latest commit `110630f` ("Parity: build-cache layout, C-compiler flags, arg-order spill, version 0.2.1"). The `f75601a` cycle landed: cgen/analyzer fixes, `--lint` syntax-only, long-string strip; take spec/, lib/, lualib/ into the tree. Since `82cd86b` this cycle also landed: scope_shadow + stepped_for (`69098c3`), unit-scope block locals + Pair dump fix (`ed503c1`), splice Stage 4 steps 5-6 (`6a04582`), closure function-value fixes (`bab3eb3`), 11 oracle-behavior fixes (`dd291fc`, `689a2f7`), plus tetrix_rotation, locals-in-functions, lshift/escapes/floor_div, type-as-value, nilptr-to-pointer, closures/upvalue scoping, pointer print spelling, any phase 2. See NOTE_backlog.md. Later: `fedf44e` numeric-for `<=`/`>`/`>=` bound specifiers; runtime per-TU inlining + libm removal (`src/cgen.nim` preamble now emits only-referenced helpers as `static` per-TU, `src/compile.nim` no longer links `src/runtime.c`, `-lm` emitted only when the preamble pulled in `<math.h>`). |

The `src/` tree is clean at `fedf44e`; everything below is committed, not uncommitted. (The `examples/fuzz/` and `examples/nelu/` corpora, plus `DEVIL.md`, are uncommitted work-in-progress from the corpus agents.) Our binary reports **v0.2.1** (`src/main.nim`).

Active work (live queue in `NOTE_backlog.md`):
- **Parser agent** (`src/parser.nim`, `src/preprocessor.nim`, `src/compile.nim`) - P1/N4/N5, the `tkLString` long-string strip, `#|name|#` splice, and the `##[=[ ... ]=]` block parse all landed at `f75601a`. Still queued: P3 `require` as an expression, P2 dotted field type, N2 byte literal `_b`, N1 `goto`/`::label:`, W3 `##` driver wiring, P4 generic instantiation.
- **Fresh cgen agent** (`src/cgen.nim`, `src/analyzer.nim`, `src/runtime.c`, `src/types.nim`, `src/cgen_types.nim`) - M1/M2/M4 metamethod dispatch landed; this session's parity fixes (array `==`/`!=` element-wise, `#cstring` wraps in `nllen(nlstr(...))`, `#array` constant-fold, `$` -> `"deref"`, nested-record constructor array-field init, method-call arg indexing) landed at `f75601a`. The `5f3d20e` cycle landed: `cstring` now emits `char*` (was `const char*`, matching the oracle), CLI parity (no args prints usage + exit 0, `-V` verbose echoes the gcc line), output modes `-B`/`--object`, `-Y`/`--assembly`, `-A`/`--static-lib`, `-H`/`--shared-lib` with `-o` redirection, `--selftest` removed, and the `inferBinary` nil-operand guard in `sema.nim`. Still queued: M3 `__call` codegen, C5 `<forwarddecl>`, C3 `@union`, N3 `<comptime>` string, W1 float32 `.0`, W2 small-uint wrap, W4 `check()` location; plus the colon method-call `nkColonIndex` SIGSEGV (same C1 root cause).
- **CLI flag agents (3, DONE & integrated into `110630f`)** - each worked on its own isolated copy under `tmp/2026-09-03-1642-*`: **path-flags** (`-L`/`--add-path`, `--path` system-lib default, the `require "allocators.general"` SIGSEGV, `--config` dump), **output-execution** (`--print-assembly`, `-i`/`--eval`, `-R`/`--runner`, `--script`), **diagnostics** (`-t`/`-T`/`-M`/`-w`/`--no-color`/`--stripflags`/`-d`/`--config`/`--semver`/`--define`/`--pragma`). All three overlap on `cli.nim`/`compile.nim`/`config.nim`/`main.nim`, integrated one at a time, in the order path -> output-execution -> diagnostics.
- **Correctness agents (2, DONE & integrated into `110630f`)** - **arg-order** (function args evaluate left-to-right like the oracle via a GNU statement-expression spill; drives `fuzz_stack`/`fuzz_queue`) and **multi-assign** (RHS of `a, b = f()` must not reuse the updated `a`; drives `fuzz_fibonacci_iterative`, `fuzz_median_array`, `fuzz_gcd`/`fuzz_lcm`).
- **Runtime per-TU inlining + libm removal (DONE, integrated; uncommitted)** - isolated copy at `tmp/2026-09-03-2005-runtime-inlining/`; design doc `plan/runtime-per-tu-inlining-design.md`. `src/cgen.nim`'s `RUNTIME_C` extern-declaration block is replaced by `genPreamble(refs)`, which emits a `static` DEFINITION of only the helpers the TU actually calls (tracked in `Gen.refs`); `src/compile.nim` no longer links `src/runtime.c` and emits `-lm` only when the preamble pulled in `<math.h>` (non-math TUs are libm-free). `src/runtime.c` is unchanged -- its bodies were moved verbatim into the preamble. Verified: build clean, all 7 probes byte-identical to baseline, `examples_parity` 2 MATCH / 5 DIFF / 3 SKIP and `wwwcheck` 91 PASS / 5 DIFF unchanged, cc line for a non-math program is `gcc ... -o out prog.c` (no runtime.c, no -lm). Note: `-lm` is kept conditionally -- the design doc's "-lm is a no-op here" claim is false; even the oracle's own generated C fails to link `pow` at the default `-g` tier without it.
- **`www_neg_for` numeric-for bound specifiers (DONE, mine)** - `parseFor` now accepts `<=`/`>`/`>=` as bound specifiers (`tkLe`/`tkGt`/`tkGe`), mapping to cmpop `le`/`gt`/`ge`; the analyzer and cgen already handled all four. `wwwcheck` improved 90/6 -> **91 PASS / 5 DIFF**.
- **Corpus agents (2, DONE)** - `examples/fuzz/` (50 algorithms, oracle-verified, verdicts 22 MATCH / 5 DIFF / 21 CRASH / 2 HANG) and `examples/nelu/` (20 beyond-oracle examples, each verified oracle-rejects / ours-accepts). Both are devil harnesses: the breakage they find is the work queue.
- **cmp.py [31] Pair dump gap** - DONE: fix landed in `src/parser.nim` (`proc dump` nkPair branch); cmp.py now 39 MATCH / 1 DIFF.
- **tetrix_rotation** - DONE & committed `82cd86b`; www target MATCH.
- **Closures / upvalues** - landed across `75f315e` + `bab3eb3`. 7 of 15 probes MATCH the oracle; function-local capture is rejected at analysis with the oracle's exact message.
- **Pointer printing** - landed & committed `75f315e`.
- **Exceptions / pattern matching / any phase 2** - DONE, integrated & committed.

---

## 3. Where things live

```
nelua-lang/
|-- AGENT.md            # standing brief for agents (read this first)
|-- README.md           # this plan
|-- language-review.md  # canonical spec/architecture (read-only)
|-- NELUA-200.md        # reader reference aid, checked against the oracle
|-- CONTRIBUTING.md     # untracked
|-- nim.cfg             # compiler build flags
|-- tmp/                # scratch: build artefacts, probes, captures. Stays until the user deletes it.
|-- plan/               # design docs + survey probes (scratch, not tracked)
|-- src/                # the compiler (what we ship)
|-- lib/, lualib/       # stdlib + oracle source (read-only reference)
|-- examples/, tests/, spec/   # oracle's own corpus (read-only reference)
+-- plan/              # design docs + gates (tracked): cmp.py, regress.py,
                      #   examples_parity.py
```

`src/` modules (current):

| Module | Role |
|--------|------|
| `main.nim` | CLI entry: parse opts, drive the pipeline |
| `compile.nim` | compile driver (parse -> preproc -> analyze -> codegen -> cc) |
| `config.nim` | Config object: pragmas, paths, cc, flags |
| `cli.nim` | CLI option parsing |
| `span.nim`, `errors.nim` | source location + diagnostics |
| `lexer.nim` | tokenizer |
| `parser.nim` | recursive descent -> AST |
| `ast.nim`, `astshapes.nim` | AST node types + shape registry |
| `sema.nim` | semantic-analysis helpers |
| `types.nim` | type object hierarchy + properties |
| `preprocessor.nim` | preprocessor driver |
| `luaengine.nim` | embedded Lua 5.x VM running `##` blocks (see section 6) |
| `analyzer.nim` | visitor-based analyzer |
| `cgen.nim`, `cemitter.nim`, `cgen_types.nim` | AST -> C visitor + C type mapping |
| `runtime.c` | C runtime the generated code links against |

Vendored third-party (read-only, **do not port**): `src/lua/*`, `src/lpeglabel/`,
`src/rpmalloc/`, `src/luainit.c`.

`tmp/` contents worth knowing:
- `NOTE_backlog.md` - the task queue.
- `tmp/m2_corpus/`, `tmp/corpus_nelua/` - oracle AST dumps the gates diff against.

---

## 4. File ownership

Tasks own **only** their listed new files and must not edit files owned by other
tasks or the gate scripts. Current owners (check `git status` - it shows
in-flight edits):

| Owner | Files |
|-------|-------|
| scope_shadow + stepped_for (DONE, committed `69098c3`) | `src/analyzer.nim` |
| locals-in-functions -> unit-scope block locals (DONE, committed `ed503c1`) | `src/cgen.nim` |
| splice Stage 4 steps 5-6 (DONE, committed `6a04582`) | `src/types.nim`, `src/preprocessor.nim` |
| cmp.py [31] Pair dump gap (DONE, committed `f75601a`) | `plan/pair-dump-gap-design.md` |
| gate scripts (mine) | `plan/cmp.py`, `plan/regress.py`, `plan/examples_parity.py` |
| exceptions (done, integrated) | exceptions feature files (see its design doc) |
| `any` (done, integrated) | `src/cgen_types.nim`, `src/analyzer.nim` (any-rejection blocks) |
| type-as-value (done, integrated) | `src/analyzer.nim` |
| nilptr-to-pointer (done, integrated) | `src/sema.nim` |
| lshift/escapes/floor_div (done, integrated) | `src/cgen.nim`, `src/lexer.nim`, `src/runtime.c` |
| closures/upvalues + pointer print (done, integrated) | `src/cgen.nim`, `src/analyzer.nim`, `src/runtime.c` |
| M1 gate + --print-ast driver (mine) | `src/main.nim`, `plan/regress.py`, `plan/cmp.py` |

**Concurrency: there is no fixed limit on how many agents may run at once.**
The only constraint is that two agents must never edit the same file at the same
time: impl agents work on isolated copies (section 3.7 of AGENT.md) so they
cannot collide on `src/`, and design/research agents are read-only on the live
tree. The table above is a snapshot of where each piece of work landed; the
ownership it records is by commit, not by an in-flight agent. Always re-read
`git status` and `NOTE_backlog.md` before starting a new impl agent, because the
live queue moves as commits land.

---

## 5. How to verify

- **Build:** `nim c -d:release --path:src -o:tmp/nelua src/main.nim`
- **Oracle dumps:** `--print-ast` (M1), `--print-analyzed-ast` (M2->M4).
- **Gates:** `python3 plan/cmp.py` (M1 diff floor), `python3 plan/regress.py` (permanent
  regression loop), `python3 plan/examples_parity.py` (end-to-end execution).
- **End-to-end:** parse -> preprocessor -> analyze -> codegen -> gcc with
  `src/runtime.c` + `-lm` -> run. The real test is a compiled program producing
  the right output and exit code 0.

Note: `regress.py` rebuilds `tmp/nelua` whenever any `src/*.nim|*.c` is newer
than the binary. While any agent is mid-edit on shared `src/`, that rebuild
produces an inconsistent binary and the gate goes red on unrelated code - a
false alarm. Re-run only when `src/` is quiescent.

---

## 6. Decisions settled (do NOT re-litigate)

- Target model: Nelua source -> (new compiler) -> C source -> (gcc/cc) -> binary.
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
  "reimplement in Nim" recommendation - the macro surface is now Lua-driven.
- **Faithful-mode divergences to replicate verbatim** (M0-M8):
  1. `local` is not hoisted (scope at its declaration line).
  2. `string.find` returns `(0, 0)` on no match, never `nil`.
  3. `string.match` returns a *sequence* of captures, not a string.
  4. No `_` discard - `_` is an undeclared identifier.
  5. `os.execute` returns `true`/`false`, not an exit code.
  6. `any` is unsupported (deduced-`any` is a compile error); `facultative(T)`
     cannot be used in return position. This is the *oracle* behaviour and is
     parity with it. Beyond-oracle, Nelu adds a tagged runtime `any` (phase 2,
     committed `214102c`) -- see `NELU-2K.md` 1.2/1.4 and
     `plan/any-implementation-design.md`.
  7. C-keyword record fields break C emission - reject at parse time.

---

## 7. Decisions still open

| # | Decision | Recommendation |
|---|----------|----------------|
| 1 | 128-bit int/float type width | single config knob, default 64-bit everywhere |
| 2 | Freestanding mode | `-P freestanding` omits libc-dependent runtime parts |
| 3 | Test harness | Nim `unittest` for the compiler; nelua programs diffed against the oracle |
| 4 | `any` full representation | tagged + runtime dispatch (phase 2) - DONE, landed `214102c`; see `plan/any-phase2-design.md` |
| 5 | C type-name mangling for records/unions/enums | define in `types.nim` codename rules (Q1) |
| 6 | `traits.typeidof` id assignment | monotonic per type, stable across runs (Q2) |
| 7 | `--cache-dir` incremental compilation | enhancement; accept full recompilation for M0-M8 (Q3) |

---

## 8. Risks

| Risk | Sev | Mitigation |
|------|-----|------------|
| Preprocessor generality (generics, concepts, AST mutation) is the hardest subsystem; stdlib containers depend on it | H | Invest M3-M4 before codegen; port `preprocessor_spec` first |
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