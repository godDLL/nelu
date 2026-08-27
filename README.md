# Nelua-in-Nim: Clean-Room Reimplementation — Work Plan

Target: a Nelua compiler written in **Nim** (Nim 2.2.10, present at `/usr/bin/nim`),
emitting **C**, compiled through an external C compiler (`gcc`/`cc`), covering all
of Nelua 0.2.0-dev and the "beyond" enhancements in
`language-review.md`.

Reference compiler under test: `/usr/bin/nelua`, Build 1635
(`0.2.0-dev.1635+a5845056`).

This plan is written so **two agents can re-implement the language concurrently
with minimal merge conflict**. It is a step-by-step plan, not a second spec:
every file path, module name, ownership, and verification command below is
concrete and executable.

---

## 1. Environment facts verified against the installed toolchain

| Item | Value |
|------|-------|
| Nim | `/usr/bin/nim`, 2.2.10 (present — **not** a blocker) |
| Reference nelua | `/usr/bin/nelua`, Build 1635 |
| C compiler | `/usr/bin/gcc`, `/usr/bin/cc` |
| Reference lib dir | `/home/user/Code/nelua-lang/lib/` (flat `.nelua` + subdirs `allocators/`, `C/`, `detail/`) |

Real CLI flags on Build 1635 (from `nelua --help`; note these differ from
Appendix B of the review — use these):

```
-r --release          -b --binary           -c --code (C only)
-a --analyze          --lint                --print-ast
--print-analyzed-ast  --print-ppcode        --print-code
-P <pragma>           -D <define>           --cc <cc>
--cflags <...>        --ldflags <...>       --path <dir>
-o <output>           --cache-dir <dir>     -s --strip-bin
--sanitize            -g <generator>        --no-cache
```

Module resolution pattern observed in the reference (needed for `require`):
dotted name `allocators.arena` maps to `lib/allocators/arena.nelua`;
`require 'tests.io_test'` maps relative to cwd to `tests/io_test.nelua`;
leading-dot `.require_test_dep` maps relative to the requiring file's directory.
Search order: (1) requiring file's directory (only for `.`-prefixed names),
(2) each `--path` entry, (3) the bundled `lib/` directory shipped with the
compiler.

---

## 2. Gaps found in `language-review.md` & additional spec

The review is excellent, but several things a reimplementation plan *needs* are
missing or wrong for Build 1635. They are recorded here. **`language-review.md`
and its zxplayer mirror are not edited.**

### 2.1 Factual gap: the `require "C"` claim is stale (§9.1)

The review states "`require "C"` is broken for everyone" and that
`C/init.nelua` declares `C.execvp(path: cstring, args: ...cstring)`. Verified
against Build 1635: that is **not** the installed state.

- `require 'C'` loads cleanly; `lib/C/init.nelua` is an **empty record**
  namespace, not a wrapper of execvp.
- C functions are imported via **submodules**: `require 'C.stdio'`, then
  `C.printf(...)`. Verified: `require 'C.stdio'` + `C.printf('cvarargs works %d\n', 1)` compiles and runs.
- The working varargs form is `...: cvarargs` (verified via `lib/C/stdarg`).
  The form `...cstring` typed varargs is what is unsupported.

**Plan consequence:** do not replicate a broken `require "C"`. Ship the real
`C.*` submodule tree from the reference `lib/C/`. Record this correction in
the new compiler's compatibility notes.

### 2.2 Missing: build system & project layout for the Nim compiler

The review never says how the Nim compiler itself is built. Added here:

- Zero external Nim dependencies (no `nimble`). Hand-written parser, hand-written
  GC. This removes a hard blocker.
- `nim.cfg` at the repo root (or `nimble.yaml` + `nimble.lock`) pinning
  `--threads:on --opt:speed --panics:on` for the compiler binary itself.
- Build command: `nim c -d:release --opt:speed -o:nelua src/main.nim`.
- `tmp/` is the only throwaway location; never `/tmp`, never project root.

### 2.3 Missing: the C runtime surface (what generated C actually calls)

The review lists `cdefs.lua`/`cbuiltins.lua` but never enumerates the C runtime
contract. Added: the compiler emits a **C runtime header** (see
§2.7/§8) that every generated C file prepends. The generated code calls into
these symbols; the plan owns their definition. Minimum surface:

- GC: `nelua_gc_alloc`, `nelua_gc_alloc0`, `nelua_gc_dealloc`,
  `nelua_gc_realloc`, `nelua_gc_step`, `nelua_gc_collect`, `nelua_gc_barrier`,
  `nelua_gc_register_finalizer`.
- Allocators (only when GC off or for `general_allocator`):
  `nelua_alloc_malloc`, `nelua_alloc_free`, `nelua_alloc_realloc`.
- String runtime: `nelua_string_create`, `nelua_string_destroy`,
  `nelua_string_len`, `nelua_string_eq`, `nelua_string_concat`,
  `nelua_string_view`, `nelua_string_to_cstring`.
- Builtins: `nelua_print`, `nelua_println`, `nelua_panic`, `nelua_error`,
  `nelua_assert`, `nelua_check`, `nelua_likely`, `nelua_unlikely`,
  `nelua_require`.
- Type info: `nelua_typeinfo` table (for `traits.typeidof`).
- Varargs / cvalist helpers: `nelua_cvalist_start`, `nelua_cvalist_arg`,
  `nelua_cvalist_end`.
- Span helpers: `nelua_span_make`, `nelua_span_len`, `nelua_span_atindex`.
- Multiple-return struct: generated per function (small C struct).

### 2.4 Missing: module compilation model

Decided: **one C file per Nelua program, all required modules inlined into it**
under a `unitname`-prefixed static namespace (e.g. `nelua_mod_<name>__`).
This preserves the review's "single readable C file" property and avoids a
link-step dependency for M0–M8. Enhancement later: per-module `.o` files +
`--cache-dir` incremental compilation (review §11.13).

### 2.5 Missing: faithful vs. improved mode decision point

Review §9.5 asks the choice but the plan must fix it. Decided: **faithful mode
for M0–M8** (replicate 0.2.0-dev behavior so existing code ports), with a
documented compatibility list. The list of divergences to replicate verbatim:

1. `local` is **not** hoisted (comes into scope at its declaration line).
2. `string.find` returns `(0, 0)` on no match, never `nil`.
3. `string.match` returns a *sequence* of captures, not a string.
4. No `_` discard symbol — `_` is an undeclared identifier.
5. `os.execute` returns `true`/`false`, not an exit code.
6. `any` is unsupported (deduced-`any` is a compile error); `facultative(T)`
   cannot be used in return position.
7. Record fields that are C keywords break C emission (either mangle them or
   reject them at parse time with a clear diagnostic — **recommend: reject**).

If later an "improved mode" is added, every change above must be documented in
the compiler's compatibility notes.

### 2.6 Missing: GC placement and freestanding mode

Decided: the GC lives in the emitted C runtime header, so it is present in
every translation unit and can be removed wholesale by `-P nogc` or
`-P freestanding`. Conservative mark-sweep: roots are (a) the C stack (scanned
conservatively via `setjmp`-based frame walking or a registered root list),
(b) global/static storage, (c) allocator-managed heap objects. `-P nogc`
omits all GC symbols; the user then manually frees everything including
strings.

### 2.7 Missing: error reporting contract

The review praises the reference's diagnostics. Added contract: every compiler
error carries a **source span** `(path, line, col, offset, length)` and a
one-line message plus an optional hint. The `errors.nim` module owns a single
`NeluaError` type; nothing else may format output. `--no-color` is the default
in non-TTY.

---

## 3. File / module layout

All Nim sources live under `src/`. The tree:

```
nelua-lang/
├── README.md                       # this plan
├── language-review.md              # spec (read-only)
├── tmp/                            # throwaway probes only
├── nim.cfg                         # compiler build flags
├── src/
│   ├── main.nim                    # CLI entry: parse opts, drive pipeline
│   ├── cli.nim                     # option parsing (parseopt; no deps)
│   ├── config.nim                  # Config object: pragmas, paths, cc, flags
│   ├── span.nim                    # SourceLoc (path, line, col, offset)
│   ├── errors.nim                  # NeluaError, spanned diagnostics, report
│   │
│   ├── lexer.nim                   # tokenizer (Lua-compatible lexemes)
│   ├── parser.nim                  # hand-written recursive descent -> AST
│   ├── ast.nim                     # AST node object types + attr payload
│   ├── astshapes.nim               # node-shape registry (tag -> fields)
│   │
│   ├── types.nim                   # type object hierarchy + is_* properties
│   ├── symbol.nim                  # Symbol entry (promoted attrs)
│   ├── scope.nim                   # scope stack + builtin-symbol creation
│   │
│   ├── preprocessor.nim            # preprocessor driver (macro semantics)
│   ├── ppcontext.nim               # preprocessor ctx (inject nodes/names)
│   │
│   ├── analyzer.nim                # visitor-based analyzer
│   ├── analyzercontext.nim         # analyzer ctx (scopes, symbols, codenames)
│   │
│   ├── codegen.nim                 # AST -> C visitor
│   ├── cemitter.nim                # C emitter helpers (casts, literals)
│   ├── ccontext.nim                # codegen context (state per file)
│   ├── ccompiler.nim               # drive the external C compiler
│   │
│   ├── runtime.nim                 # renders nelua_runtime.h text
│   ├── module.nim                  # require / module path resolution
│   ├── builtins.nim                # builtin function registry
│   │
│   └── tests/
│       ├── harness.nim              # nim unittest helpers
│       ├── parser_spec.nim
│       ├── typechecker_spec.nim
│       ├── preprocessor_spec.nim
│       └── codegen_spec.nim
├── lib/                            # stdlib Nelua source (copied from reference)
│   ├── *.nelua  allocators/*.nelua  C/*.nelua  detail/*.nelua
├── examples/                       # reference acceptance programs
└── spec/                           # reference spec files (read-only reference)
```

`runtime/nelua_runtime.h` is generated by `runtime.nim` at build time and
shipped; it is the C contract from §2.3.

---

## 4. Two work streams & file ownership

### Stream A — Front-end (parse, types, analyze, preprocessor)

Owns everything from the tokenizer through the fully-analyzed AST.

| Files owned by A | Purpose |
|------------------|---------|
| `src/span.nim`, `src/errors.nim` | source location + diagnostics (shared contract) |
| `src/cli.nim`, `src/config.nim` | CLI parsing + config/pragmas (shared contract) |
| `src/lexer.nim` | tokenizer |
| `src/parser.nim`, `src/ast.nim`, `src/astshapes.nim` | recursive-descent parser + AST |
| `src/types.nim` | type hierarchy + properties (shared contract) |
| `src/scope.nim`, `src/symbol.nim` | scope stack + symbol table |
| `src/preprocessor.nim`, `src/ppcontext.nim` | preprocessor macros in Nim |
| `src/analyzer.nim`, `src/analyzercontext.nim` | type inference, sema, annotations |
| `src/module.nim` | require / module path resolution (shared contract) |
| `src/tests/parser_spec.nim` | parser tests |
| `src/tests/typechecker_spec.nim` | type-checker tests |
| `src/tests/preprocessor_spec.nim` | preprocessor tests |

A's deliverable: a `Frontend` module exposing
`parse(source, path) -> AstProgram` and `analyze(ast, config) -> AnalyzedProgram`,
where `AnalyzedProgram` is the AST with `attr` fully populated (types, lvalue,
comptime, const, codename, staticstorage) and a populated symbol table.

### Stream B — Back-end (codegen, runtime, driver, stdlib)

Owns C emission, the C runtime, and the end-to-end driver.

| Files owned by B | Purpose |
|------------------|---------|
| `src/codegen.nim`, `src/cemitter.nim`, `src/ccontext.nim` | AST -> C visitor |
| `src/ccompiler.nim` | invoke gcc/cc, capture errors, map to diagnostics |
| `src/runtime.nim` | renders `runtime/nelua_runtime.h` (C contract from §2.3) |
| `src/builtins.nim` | builtin function registry (print/panic/assert/require) |
| `src/main.nim` | top-level driver wiring Frontend -> Backend -> cc |
| `lib/**` | stdlib Nelua source (copied verbatim from reference; B owns integration) |
| `examples/**` | acceptance programs (B owns running them) |
| `src/tests/codegen_spec.nim` | codegen tests |

B's deliverable: a `Backend` module exposing
`generateCode(analyzed, config) -> CSource` and
`compileBinary(csource, config, outpath)`, plus the driver in `main.nim`.

### Shared contract files (published first; frozen; off-limits to the other stream)

These are the seam. Both streams build against a **frozen snapshot** of them.

| Contract file | Owned by | Published at | Consumers |
|---------------|----------|--------------|-----------|
| `src/span.nim`, `src/errors.nim` | A | M0 | A, B |
| `src/cli.nim`, `src/config.nim` | A | M0 | A, B |
| `src/ast.nim`, `src/astshapes.nim` | A | M1 | A, B |
| `src/types.nim` | A | M2 | A, B |
| `src/scope.nim`, `src/symbol.nim` | A | M2 | A |
| `src/module.nim` | A | M3 | A, B |
| `runtime/nelua_runtime.h` | B | M5 | B (and A for annotations) |
| `src/builtins.nim` | B | M5 | B |

Rule: once a contract file is published, the owning stream may not change its
public signature without a written delta accepted by the other stream. Private
helpers inside a contract file stay free.

---

## 5. Coordination strategy

1. **Contract-first.** At the end of each milestone the owning stream publishes
   the contract files listed above into a frozen `interface/` snapshot (plain
   files; no git needed). The other stream builds against that snapshot.
2. **Merge cadence.** End of every milestone: both streams copy their owned files
   into one working tree and run the integration build
   (`nim c -d:release --opt:speed -o:nelua src/main.nim`). Failures are resolved
   by the stream that owns the failing file; the contract owner resolves
   contract-breakage disputes.
3. **Divergence resolution.** If A and B disagree on an AST shape or a type
   property, the spec in `language-review.md` (Appendix A + §10.3) is the
   tie-breaker. If the spec is silent, the stream that needs the feature files a
   short "additional spec" addition in this README (§2) and the other stream
   implements it in its own contract file; no silent divergence.
4. **No git.** No `git add/commit/reset/checkout/branch`. Coordination is by
   file copy + this README's milestone table. Work goes in `tmp/` for probes.
5. **Verification authority.** `/usr/bin/nelua` is the oracle for acceptance.
   Where the new compiler's output/behavior differs from the oracle, the
   difference must be intentional (faithful-mode list §2.5) and documented.

---

## 6. Decisions settled by the spec (do NOT re-litigate)

- Target model: Nelua source -> (new compiler) -> C source -> (gcc/cc) -> binary.
- AST node shapes: implement exactly the shapes and fields in Appendix A of
  the review, with `tag`, `attr`, and the `is_*` flags.
- Type hierarchy and properties: §10.3 (`is_integral`, `is_float`,
  `is_stringy`, `is_pointer`, `is_array`, `is_record`, `is_niltype`,
  `metafields`, `codename`, `typeid`, `nickname`, `name`).
- C generation: single readable C file, sections (directives / declarations /
  definitions / bodies), `nelua_main` entry.
- CLI options: map Appendix B to the real Build 1635 flags in §1.
- Stdlib surface: §8 (all modules and their functions). Ship the reference
  `lib/*.nelua` verbatim; the new compiler must compile them.
- Preprocessor semantics: §6 (`##` lines, `##[[ ]]` blocks, `#[expr]#`,
  `#|name|#`, `#[node]#`, `inject_astnode`, macros, `expr_macro`,
  `generalize`, `concept`, `facultative`, `overload`, `static_assert`,
  `static_error`, `require "foo"` of `.lua` modules).
- Memory management: optional conservative mark-sweep GC; allocator interface
  `alloc/alloc0/xalloc/xalloc0/dealloc/realloc/realloc0/xrealloc/xrealloc0/
  spanalloc*/new/delete` + span variants; `<close>` variables via `__close`.
- Record metamethods: the full `__` list in §3.9.

## 7. Decisions still open (with recommendation)

| # | Decision | Recommendation |
|---|----------|----------------|
| 1 | Preprocessor: embed a Lua VM vs. reimplement macro semantics in Nim | **Reimplement in Nim.** The macro surface in §6 is fully specified; a Nim implementation removes a large dependency and keeps the compiler self-contained. Expose a documented Nim API for AST/type introspection at compile time (that is the essence, per review §Appendix C.6). Only if a stdlib helper genuinely needs `require "foo"` of a `.lua` module do we add a minimal Lua VM later. |
| 2 | Parser: reuse a PEG/LPeg generator vs. hand-written recursive descent | **Hand-written recursive descent.** Gives source spans, full control over error messages, zero dependencies, and matches review §Appendix C.2. The grammar contract is Appendix A + the syntax in §3. |
| 3 | GC: reuse `gc2`/nim-gc vs. hand-write conservative mark-sweep in emitted C | **Hand-write in the emitted C runtime header** (§2.3/§2.6). Keeps the single-file, freestanding-capable model and makes `-P nogc` a clean removal. Conservative stack scanning is the risky part; mitigate with a registered-root-list mode as a fallback. |
| 4 | Stdlib: re-port in Nim vs. ship reference `lib/*.nelua` | **Ship the reference `lib/*.nelua` verbatim** (they are MIT Nelua source, not the compiler). This makes the stdlib the *real* acceptance test of the compiler's generic/concept/preprocessor support (review §Appendix C.9). |
| 5 | Faithful vs. improved mode | **Faithful for M0–M8** (§2.5). Improved mode only after the faithful compiler passes all gates, with explicit compatibility notes. |
| 6 | `integer`/`uinteger`/`number` width knob | Implement as a single config knob, default 64-bit everywhere (§3.6). |
| 7 | Freestanding mode | `-P freestanding` omits libc-dependent parts of the runtime header; already a goal, make it a clean mode. |
| 8 | Test harness | Nim `unittest` for the compiler (`src/tests/*.nim`); Nelua programs run through the new compiler and diffed against `/usr/bin/nelua` for acceptance. |

---

## 8. Ordered milestone plan with verification gates

Each milestone lists: must-complete, verify command(s), pass criteria.

### M0 — Scaffold, CLI, span, errors
- Create `nim.cfg`, `src/main.nim`, `src/cli.nim`, `src/config.nim`,
  `src/span.nim`, `src/errors.nim`, `src/tests/harness.nim`.
- **Verify:** `nim c -d:release --opt:speed -o:nelua src/main.nim` builds;
  `./nelua --version` prints a version string; `./nelua --help` parses.
- **Gate:** clean build + version/help output.

### M1 — Lexer + parser + AST
- `src/lexer.nim`, `src/parser.nim`, `src/ast.nim`, `src/astshapes.nim`.
- Parser is hand-written recursive descent producing the Appendix A node shapes.
- **Verify:** for each `examples/*.nelua`, `./nelua --print-ast <f>` produces a
  tree with no parse errors; `src/tests/parser_spec.nim` passes (round-trip and
  error cases). Compare node-tag counts against the reference's
  `--print-ast` output, normalized (strip whitespace/order where the reference
  reorders).
- **Gate:** all `examples/*.nelua` parse; spec parser tests pass.

### M2 — Type system, scope, symbols
- `src/types.nim`, `src/scope.nim`, `src/symbol.nim`. Publish `types.nim` contract.
- **Verify:** `src/tests/typechecker_spec.nim` passes — ported cases from
  `spec/typechecker_spec.lua` covering deduction, zero-init, `auto`, `<const>`,
  `<comptime>`, `global`, method receivers, polymorphic args.
- **Gate:** type-checker unit tests pass.

### M3 — Preprocessor
- `src/preprocessor.nim`, `src/ppcontext.nim`. Publish `module.nim` contract.
- **Verify:** `src/tests/preprocessor_spec.nim` passes — ported cases from
  `spec/preprocessor_spec.lua` covering `##`, `##[[ ]]`, `#[expr]#`, `#|name|#`,
  `inject_astnode`, macros, `expr_macro`, `generalize`, `concept`,
  `facultative`, `overload`, `static_assert`, `static_error`, `require "foo"`.
- **Gate:** preprocessor unit tests pass.

### M4 — Analyzer (full front-end)
- `src/analyzer.nim`, `src/analyzercontext.nim`.
- **Verify:** for each `examples/*.nelua`, `./nelua -a <f>` (analyze only) exits
  0. Then compile+run the acceptance set (§9) through the new compiler and diff
  against `/usr/bin/nelua`.
- **Gate:** analyze-only is clean on all examples; front-end contract frozen.

### M5 — C runtime header
- `src/runtime.nim` renders `runtime/nelua_runtime.h` (§2.3 surface). Publish it.
- **Verify:** a standalone C program that `#include`s the header and calls
  `nelua_print("hi")`, `nelua_gc_alloc`/`free`, and `nelua_string_create`
  compiles with `gcc -Wall -Wextra` with no warnings, links, and runs.
- **Gate:** runtime header compiles standalone.

### M6 — Codegen (AST -> C)
- `src/codegen.nim`, `src/cemitter.nim`, `src/ccontext.nim`.
- **Verify:** `./nelua --print-code <f>` on a representative set (hello world,
  `fibonacci`, `matmul`, a record-with-methods program, a polymorphic-function
  program) produces valid C. `src/tests/codegen_spec.nim` passes.
- **Gate:** `--print-code` output is syntactically valid C (pipe through
  `gcc -fsyntax-only`).

### M7 — End-to-end compile + run (the big gate)
- `src/ccompiler.nim`, `src/builtins.nim`, `src/main.nim` wiring.
- **Verify (acceptance set):** for each program in the set below, run BOTH
  `/usr/bin/nelua -b -o <ref> <f>` and `./nelua -b -o <new> <f>`, then compare
  `./<ref>` and `./<new>` stdout + exit code. Programs:
  - `examples/helloworld.nelua`, `fibonacci.nelua`, `matmul.nelua`,
    `gameoflife.nelua`, `brainfuck.nelua`, `mersenne.nelua`, `overview.nelua`,
    `record_inheretance.nelua`
  - plus a hand-written record-with-methods program, a polymorphic-function
    program, a `switch`/`defer`/`goto` program, and a span + stringbuilder program.
- **Gate:** 100% stdout+exit match against the oracle on the acceptance set.

### M8 — Stdlib compilation
- Compile the entire `lib/*.nelua` tree (allocators, C submodules, containers:
  vector, sequence, list, hashmap, span, stringbuilder, string, traits, utf8,
  coroutine, hash, memory, io, os, math, iterators, arg, filestream) through the
  new compiler, then run `tests/*.nelua` against it.
- **Verify:** a representative test subset runs through the new compiler with
  stdout+exit matching the oracle (e.g. `tests/vector_test.nelua`,
  `sequence_test.nelua`, `hashmap_test.nelua`, `span_test.nelua`,
  `stringbuilder_test.nelua`, `traits_test.nelua`, `allocators_test.nelua`).
- **Gate:** stdlib compiles; the container tests pass against the new compiler.

### M9 — Bootstrap attempt (stretch)
- Attempt to compile a meaningful subset of the new compiler's own front-end
  (lexer/parser/ast) written in Nelua, through the new compiler. This proves
  the spec is complete enough to self-host.
- **Gate:** a non-trivial Nelua program that exercises generics, concepts, and
  the preprocessor compiles and runs through the new compiler. If it fails, the
  gaps are recorded as additional spec in this README.

### M10 — Beyond-features sprints (one at a time, each with its own gate)
Order by dependency:
1. `table(K, V)` first-class runtime type (review §11.1.1).
2. Full `any` type with runtime dispatch (§11.1.2).
3. Exceptions: `try`/`catch`/`recover` + `perror` (§11.1.3).
4. Closures everywhere (§11.1.4).
5. `match` expressions / pattern matching (§11.1.6).
6. Pluggable backends (LLVM IR / WASM / bytecode) (§11.2.15).
7. Incremental compilation with persistent cache (§11.2.13).
Each sprint: spec the change in this README, implement, add acceptance tests,
verify against the oracle where applicable.

---

## 9. Acceptance test methodology

1. **Oracle.** `/usr/bin/nelua -b -o <ref> <f>`; run `./<ref>`; capture stdout
   + exit code. This is the golden value.
2. **New compiler.** `./nelua -b -o <new> <f>`; run `./<new>`; capture stdout
   + exit code.
3. **Diff.** Compare byte-exact stdout and the exit code. Any difference is a
   bug unless it is an intentional faithful-mode divergence (§2.5) or an
   explicitly documented improved-mode change.
4. **C-level diff.** For codegen debugging, compare `--print-code` output
   structurally (normalize whitespace, strip the directive banner) between the
   oracle and the new compiler; a structural diff localizes generator bugs.
5. **Determinism.** Acceptance tests must be deterministic: no RNG, no wall
   clock in the compared output. Use `tests/` fixtures; keep throwaway probes in
   `tmp/`.
6. **Harness.** A small script (python3 is fine) in `tmp/` or a `tests/run.sh`
   that loops the acceptance set and reports PASS/FAIL per program. Do not
   leave it in the project root; if it is permanent it lives in `tests/`.

---

## 10. Risks & open questions

| Risk | Severity | Mitigation |
|------|----------|------------|
| R1 Preprocessor generality (generics, concepts, AST mutation) is the hardest subsystem; the stdlib containers depend on it | High | Invest M3–M4 before touching codegen; port `preprocessor_spec` first; keep the preprocessor API minimal and well-documented |
| R2 C codegen correctness for metamethod dispatch, method call auto(ref/deref), multiple-return structs, polymorphic specialization | High | M7 acceptance gate with record/method and polymorphic programs; structural `--print-code` diff |
| R3 Conservative GC stack scanning is error-prone across compilers/architectures | Medium | Make `-P nogc` work from M5 onward so the non-GC path is testable first; add GC last, behind a flag |
| R4 Merge friction on the shared contract files (`ast.nim`, `types.nim`) | Medium | Freeze contracts per milestone (§5); written deltas; contract owner resolves disputes |
| R5 Spec inaccuracies (e.g. the stale `require "C"` claim in §9.1) could propagate into the implementation | Low | Every acceptance test is run against `/usr/bin/nelua`; record corrections in §2.1 |
| R6 128-bit integer/float types only on some C compilers/architectures | Low | Detect at C-compile time and degrade gracefully; do not block earlier milestones |
| R7 Nim 2.2.10 skew vs. the features used | Low | Pin `nim.cfg`; use only stdlib (zero nimble deps) |
| R8 `any`/tables unsupported in the reference means some Lua code cannot be ported until M10 | Medium | Acceptance set uses only features the reference supports; `any`/tables are M10 scope |
| R9 Two-stream parallelism means a stream may build against a stale contract snapshot | Medium | Milestone-end integration build (§5.2); a stream that breaks the build owns the fix |

Open questions (carry forward, not blockers):
- Q1: exact C type name mangling for records/unions/enums (must be deterministic and
  collision-free across modules) — define in `types.nim` codename rules by M2.
- Q2: how `traits.typeidof` ids are assigned (monotonic per type, stable across runs?)
  — decide by M5 so the runtime header can declare the table.
- Q3: `--cache-dir` incremental compilation is an enhancement; for M0–M8 accept full
  recompilation (§2.4).

---

## 11. Quick-start for either stream

```bash
# build the compiler (once M5+ is present)
nim c -d:release --opt:speed -o:nelua src/main.nim

# analyze only (Stream A gate)
./nelua -a examples/fibonacci.nelua

# compile a program to a binary (Stream B gate)
./nelua -b -o /tmp/out examples/helloworld.nelua
/tmp/out

# acceptance diff (Stream B gate)
/usr/bin/nelua -b -o /tmp/ref examples/fibonacci.nelua
./nelua -b -o /tmp/new examples/fibonacci.nelua
diff <(/tmp/ref) <(/tmp/new) && echo PASS
```

Throwaway probes always go in `project/tmp/`, never `/tmp` and never the project
root. No `git` commands unless the user explicitly instructs it.