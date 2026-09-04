# NASM opportunities in the Nelua-in-Nim compiler

Assessment grounded in the actual source, with measurements. ASCII only.


**Status:** DONE -- assessment complete, grounded in the actual source with measurements; concluded.

## Bottom line

**Partial NASM-ification is not a good next move.** There is no function or
codegen path in this codebase where hand-written NASM beats what gcc 16.2.1 at
`-O2 -fno-plt -flto` already produces, and NASM cannot remove the gcc dependency
itself (NASM does not compile C; the emitted translation unit still needs gcc).
The real, measurable codegen costs in this project -- duplicated per-site panic
functions, per-type accessor functions, the debug-build `nlcheck_*` call overhead
-- are all C-*emitter* design issues, fixable in `cgen.nim` / `cbuiltins.lua`, and
none of them are NASM-shaped. The single best use of effort right now is not
NASM; it is the emitter dedup listed below as a side finding.

## What I looked at, and how

- `src/runtime.c` (416 lines) -- the runtime linked into every program.
  Compiled to assembly with `gcc -O2 -S` and inspected every function's
  instruction sequence.
- `src/cgen.nim` (1707 lines) and `src/cemitter.nim` (196 lines) -- the C
  emitter. Read in full; traced `coerce`, `genBinaryOp`, `genCall`, the
  `nelua_print` dispatch, `genSwitch`, `genFuncDef`, and the `genC` entry point.
- `src/compile.nim` (245 lines) -- the driver and its single link line.
- `src/analyzer.nim`, `src/types.nim` -- compile-time machinery.
- `src/hasher.c`, `src/sys.c`, `src/luainit.c` -- compiler-internal Lua C modules.
- `src/nelua-decl/gcc-lua/` -- the existing GCC-plugin precedent.
- Measured the real pipeline: `examples/matmul.nelua` (200x200) and a 1M-integer
  sum loop, emitted through the **Nim** `cgen.nim` path (built a scratch driver
  in `tmp/`), then compiled and timed the phases separately.

Two structural facts that shape everything below:

1. **The shipped codegen is the Lua emitter, not `cgen.nim`.** Running
   `./nelua-lua -lnelua nelua.lua --print-code matmul.nelua` produces output
   headed `/* ------------------------------ DIRECTIVES ---... */` with
   `nelua_assert_line_2`, `nelua_assert_line_3`, ... and
   `nelua_span_*____atindex` -- fingerprints of `lualib/nelua/cbuiltins.lua`
   (see `cbuiltins.lua:743`, `context.rootscope:generate_name('nelua_assert_line')`).
   `src/cgen.nim` is the clean-room reimplementation in progress; its output is
   headed `/* === nelua runtime (embedded by cgen.nim ... */` and uses one shared
   `nelua_assert_line`. The user's question names `cgen.nim`, so the findings
   below are for the Nim path, with the Lua-emitter duplication called out
   separately because it is the bigger real cost.
2. **The compile step dominates the runtime.** For matmul: emit 0.15s, gcc
   compile 0.87s, run 0.06s. Anything that only affects the 60ms run cannot
   touch the thing the user actually waits on.

## Ranked candidates

### C1 -- `runtime.c` hot functions: `nlidiv`, `nlmod`, `nllen`, the `nelua_print_*`
set, `nlany_from_*`, `nlany_load_*`, `nlstring_concat`, `nlstr`, `nlclose`
(`src/runtime.c:368-402`, `134-193`, `200-323`, `338-361`)

- **What:** The entire runtime that ships with every program. 416 lines.
- **Why NASM might beat C:** This is the only place where hand-written asm is
  even in the running -- raw speed on a tight loop.
- **The reality (measured):** gcc 16.2.1 at `-O2` already emits optimal code for
  every one of them:
  - `nlidiv` -> `cqto; idivq; test; cmov` (11 insns). The hardware divide is
    used; the Lua floor-branch is a `cmov`. A NASM version is the same instructions.
  - `nlmod` -> same shape, `leaq (%rdx,%rsi), %rax; cmovs`.
  - `nllen` -> `movq %rsi, %rax; ret` (2 insns). Unbeatable.
  - `nlclose` -> `jmp *free@GOTPCREL`. `nlpow` -> `jmp *pow@GOTPCREL`.
    Perfect tail calls into glibc.
  - `nelua_print_int64`/`_uint64` -> 4 insns then `jmp *fprintf@GOTPCREL`.
    `nelua_print_string` -> 3 insns then `jmp *fwrite@GOTPCREL`.
    `nelua_print_bool` -> `testl; cmovne; jmp *fputs@GOTPCREL`.
  - `nlany_from_int`/`_uint` -> `movl $tag, (%rdi); movq %rsi, 8(%rdi); ret`.
  - `nlany_from_ptr` (`runtime.c:242`) -> gcc already compiles the clever
    `negq/sbbl/and $6` tag trick verbatim.
  - `nlany_load_int`/`_uint` -> a 3-level binary search on the tag (`cmpl; je; ja;
    jne`), not a jump table, but the function is ~20 insns and only reached for
    `any`-typed values.
  - `nelua_print_double` is the biggest (~30 insns + `snprintf` + an inf/nan
    scan), but it is I/O-bound on glibc's `snprintf`/`fputs`; asm cannot touch
    that.
- **Cost:** Writing and maintaining a hand-rolled NASM copy of this file; a
  second toolchain to support on Windows (NASM COFF) and Linux (ELF); the real
  risk that a hand-rolled float-formatting path diverges from glibc's and breaks
  the "run the same as the oracle" parity bar. Every function is already at or
  near the theoretical minimum.
- **Verdict: NOT WORTH IT.** There is no instruction to save.

### C2 -- Debug-build `nlcheck_*` per-operation call overhead
(`src/cgen.nim:78-89` preamble macros; emitted loop below)

- **What:** In a non-release build, `nlcheck_int(x)` expands to
  `(nlcheck_int_overflow((int64_t)(x), "int"), (int64_t)(x))` -- a real call per
  checked operation. The Nim-emitted hot loop for `sum(1000000)` is:
  `for (i=1; i<=n; i+=1) s = s + nlcheck_int((int64_t)i);`
- **Why NASM might beat C:** A call/ret per iteration looks like overhead.
- **The reality:** `nlcheck_int_overflow` (`runtime.c:409`) is literally
  `(void)x; (void)what;` -- a `ret`. The only cost is the call/ret pair (~2
  cycles), and it is **fully elided in release builds** (`NLNOCHECK` ->
  `((int64_t)(x))`, a bare cast). Measured release-mode assembly of the same
  loop: gcc auto-unrolls it into an add chain
  (`leaq 1(%rdx,%rax,2), %rdx; addq $2, %rax; cmp; jne`). No NASM hand-unroll
  could match that generically, and it is free anyway.
- **Cost:** Zero benefit; would only complicate the debug path.
- **Verdict: NOT WORTH IT.** If anything this is an argument *against* adding
  per-op machinery, not for NASM.

### C3 -- `nlany` tag dispatch: `nlany_load_*`, `nlany_eq`, `nelua_print_any`
(`src/runtime.c:266-323`, `249-259`)

- **What:** Switch-on-tag extraction and equality. gcc emits a binary search on
  the 5-way tag rather than a jump table.
- **Why NASM might beat C:** A `jmp *table(,%rax,8)` could shave a branch or two
  versus gcc's tree, in the hot direction.
- **The reality:** These are only reached for values the analyzer typed `any`.
  `cgen.nim:22-25` itself records that polymorphic `auto` params lower to
  `any`/`void*` rather than being monomorphized -- i.e. `any` is a *reported gap*,
  not a hot path. Even if it were hot, gcc's tree is ~3 comparisons on a 5-way
  set; the win is speculative sub-cycle noise, and only when `any` is actually
  frequent. `nlany_from_ptr` already shows gcc will use the clever bit-trick
  itself.
- **Cost:** Hand-maintaining a jump table that must exactly match the C struct
  layout and tag enum; parity risk on every load path.
- **Verdict: WORTH DOING LATER, ONLY IF `any` BECOMES HOT.** Not now.

### C4 (side finding, NOT a NASM candidate) -- per-site panic-function
duplication in the Lua emitter

`lualib/nelua/cbuiltins.lua:743` does
`context.rootscope:generate_name('nelua_assert_line')` for every `assert`/`check`
site, and `cbuiltins.lua:758-786` inlines the full `fwrite(...); nelua_abort()`
body into each one. A real `matmul` build carries `nelua_assert_line_2` through
`_6` -- five copies of the same 140-byte panic routine and its source-location
string. This is genuine binary bloat and a real per-check cost, and it is the
largest concrete codegen inefficiency I found.

**But it is not NASM-shaped.** It is fixed by deduplicating the panic helper in
the emitter (emit one `nelua_assert_line(cond, msg, file, line)` and call it),
which the Nim `cgen.nim` path already does correctly (`cgen.nim:168` defines one
shared `nelua_assert_line`; `cgen.nim:693-708` calls it). So the fix is an
emitter change, and it is arguably a higher-value use of effort than anything in
this document.

### C5 -- Emitting an object file directly from the compiler

- **What:** Skip C entirely and write ELF/Mach-O/COFF from Nim.
- **Why NASM might beat C:** Removes the gcc compile step (0.87s of the matmul
  wall clock).
- **The reality:** `cgen.nim:1562-1571` `genC` returns a **string**. There is no
  raw-byte emission anywhere, no object format knowledge, and no hook for it
  (`main.nim` parses `-g <generator>` but never dispatches it -- `cgen.nim` is
  hardcoded). Writing an ELF writer that reproduces gcc's relocations,
  optimizations, and platform ABI is a multi-month project, and it would destroy
  the parity bar by definition (any divergence is a behavioural change).
- **Cost:** Enormous; would have to be re-done per OS and per ISA.
- **Verdict: NOT WORTH IT.** Not a NASM move at all -- it is a native-backend
  project, an order of magnitude larger than this whole compiler.

### C6 -- Removing gcc as a dependency

- **What:** The philosophical goal -- "keep Nelua alive in tools we know, not in
  C".
- **Why NASM might beat C:** NASM is not C.
- **The reality:** NASM assembles `.asm`. It does **not** compile the emitted C
  translation unit, which is the bulk of every program and which `cgen.nim`
  produces as text. The driver's single link line is
  `compile.nim:194`:
  `gcc -o bin emitted.c runtime.c -lm`. Inserting a NASM object means:
  `nasm -f elf64 runtime.asm -o runtime.o`, then
  `gcc -o bin emitted.c runtime.o -lm`. gcc is still there, now with NASM as an
  *additional* dependency. The only thing NASM removes is `runtime.c` from the
  gcc invocation -- which saves microseconds, because `runtime.c` is 416 lines
  that gcc compiles in milliseconds and already optimises perfectly (C1).
- **Cost:** A second toolchain to ship, support on Windows COFF, debug, and
  maintain, for a runtime that is already optimal.
- **Verdict: NOT WORTH IT.** NASM cannot reduce the toolchain; it can only enlarge
  it. The way to stop shipping C is a native backend (C5), not asm snippets.

## What I looked at and found NOTHING worth doing

- **`src/analyzer.nim` (2593 lines) and `src/types.nim` (915 lines):** purely
  compile-time Nim. Their *output* is the analyzed AST and type metadata, which
  `cgen.nim` walks to emit C *text*. There is no binary output to move to NASM;
  the question does not apply. The compile step is already fast relative to gcc.
- **`src/hasher.c`, `src/sys.c`, `src/luainit.c`:** Lua C modules linked into
  the compiler's own `nelua-lua` interpreter (blake2b, base58, nanotime, os
  env). They are not shipped with every Nelua program -- the per-program
  runtime is `src/runtime.c` alone. They are also already hand-written C (and
  `hasher.c` is a near-verbatim reference blake2b). No NASM candidate.
- **`src/nelua-decl/gcc-lua/`:** a third-party GCC *plugin* used by the `nldecl`
  tool to extract C declarations from headers. This is the project's one
  existing "alternative to plain C compilation" move, and it actually argues
  *against* the NASM direction: it reached for a GCC plugin (still GCC) for a
  narrow, justified job -- binding generation -- not for runtime machinery. It
  is not part of the compile pipeline that produces user binaries.
- **`src/cemitter.nim`:** pure formatting helpers (`cNumberLit`, `cStringLit`,
  `cIdent`, `cCast`, `cQualifiers`). No codegen paths, no static sequences, no
  dispatch tables. Nothing to NASM.
- **`genSwitch` (`cgen.nim:1279`), `emitMultiRet` (`cgen.nim:375`),
  `emitTypedef` (`cgen.nim:334`):** all emit plain C `switch`/`typedef`/struct.
  gcc generates any jump tables or padding. There is no place the emitter writes
  raw bytes or could write an object file.

## Compact summary

**Top 3 candidates, ranked by value:**
1. C4 (side finding) -- deduplicate the per-site panic functions in the Lua
   emitter / align `cgen.nim`'s shared helper. Real bloat, real cost, real fix,
   and it is an emitter change -- not NASM.
2. C3 -- `nlany` tag dispatch as a jump table. Only worth doing if `any` becomes
   a hot path; currently speculative.
3. Nothing else. C1, C2, C5, C6 are all "not worth it" with measured evidence.

**Single best one:** there is no NASM move worth doing now. The best available
action is C4, and it lives in the emitter, not in an assembler.

**Honest caveat about feasibility:** even C3, the only thing with a NASM-shaped
win, is a parity risk for a path that is currently rare and that the design is
moving away from. The measured truth is that gcc 16.2.1 already optimises every
runtime function to the instruction-level minimum, and the dominant cost in the
pipeline is gcc compiling the emitted C -- which NASM cannot touch. Partial
NASM-ification would add a second toolchain, add maintenance, and buy nothing
measurable. The right next move is emitter hygiene (C4), not an assembler.