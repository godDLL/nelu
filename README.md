# Nelu

Nelu is a clean-room reimplementation of the **Nelua** programming language
compiler, written in **Nim** and emitting **C**. It is compiled with `gcc`/`cc`
and targets Nelua 0.2.0-dev parity, with Nelu-specific extensions on top.

- **Binary:** `tmp/nelu` — one binary, no separate interpreter.
- **Version:** `0.2.1`.
- **Oracle under test:** `/usr/bin/nelua` (Build 1635, `0.2.0-dev.1635+a5845056`).
  Its source is vendored at `lualib/nelua/` as read-only reference; we do not
  modify it and do not port it into `src/`.

Nelu is not a port of the oracle's compiler. The oracle's compiler is plain Lua
source run by a C-written Lua 5.4.3 interpreter (`nelua-lua`); Nelu's compiler
is Nim, and the embedded Lua it ships is a *consumer* of plain Lua — it drives
`##` preprocessing and exposes `--script` / `--lua`, not the compiler itself.

## Build

```bash
make nelu     # nim c -d:release --path:src --nimcache:.cache/nim \
              #   --passL:-s -o:tmp/nelu src/main.nim
```

A fresh `--nimcache` matters: a reused one silently picks up stale modules and
produces an inconsistent binary.

## Usage

`tmp/nelu` accepts the Nelua compiler's CLI, plus three embedded-Lua access
points of its own:

```bash
./tmp/nelu examples/helloworld.nelua          # compile and run
./tmp/nelu -b -o out examples/helloworld.nelua # compile to a binary
./tmp/nelu -c examples/helloworld.nelua        # emit C and stop
./tmp/nelu -a examples/helloworld.nelua        # analyze only
./tmp/nelu --lint examples/helloworld.nelua     # syntax check only
./tmp/nelu --print-ast examples/helloworld.nelua

./tmp/nelu --script spec/init.lua              # run a Lua file (embedded engine)
./tmp/nelu --lua                               # interactive Lua REPL
./tmp/nelu --load nelua.runner --script f.lua  # preload a Lua module
```

### Compiler flags

```
-r --release   -b --binary   -c --code (C only)
-a --analyze   --lint        --print-ast
--print-analyzed-ast  --print-ppcode  --print-code  --print-assembly
-P <pragma>    -D <define>   --cc <cc>   --cflags <...> --ldflags <...>
--path <dir>   -L, --add-path <dir>
-o <output>    --cache-dir <dir>  -s --strip-bin  --sanitize
-g <generator> --no-cache  -i, --eval <code>  -R, --runner <runner>
-t, --timing  -T, --more-timing  -M, --maximum-performance
-d, --debug  -V (verbose)  --no-warning  --no-color  --stripflags <...>
--version  --semver  --config  --help
```

### Embedded Lua

`--script <file>` runs a `.lua` file through the embedded Lua 5.4 engine,
bypassing the compiler entirely. `--lua` drops into an interactive REPL on the
same engine. `--load mod[:as]` preloads a Lua module into that engine's global
namespace — `--load nelua.runner` binds `require "nelua.runner"` to the global
`nelua.runner`; `--load g=nelua.runner` binds it to `g`. Several `--load`
accumulate; a module that cannot be required raises a clear `nelua: --load:`
error. `--load` is only valid with `--script` or `--lua`.

During compilation, `##` preprocessing runs `##` statement lines,
`#[expr]#` splices, and `##[[ ... ]]` / `##[=[ ... ]=]` multi-line Lua blocks
through the same embedded engine. Those blocks run against a small C-ABI shim
Nim provides (builtins such as `hygienize`, `static_assert`, `inject`,
`ppregistry`, `cinclude`/`cdefine`/`cemit`, `pragmas`, …); the full oracle
compiler Lua API is *not* loaded by default but is reachable on demand via
`require` (the bundled `lualib/` is on `package.path`).

## State

Verification is a harness, not a claim: `plan/harness.py` runs each probe
through `tmp/nelu` and the oracle and diffs the results. Current run (305
probes, 304 in the recorded baseline + 1 new):

```
TOTAL  9 BOTH_FAIL  2 DIFF  223 MATCH  4 NELU_ACCEPT  12 NELU_CRASH  40
NELU_REJECT  14 ORACLE_FAIL  1 SKIP
OK: no regression.
```

223 probes are byte-identical to the oracle. The remaining divergences are
tracked, not hidden:

- `DIFF` (2) — same flagset, output or exit differs.
- `NELU_CRASH` (12) — ours aborts where the oracle runs. Known codegen gaps.
- `NELU_REJECT` (40) — ours rejects where the oracle accepts. Mostly the
  stdlib: `lib/*.nelua` is the single largest takeover blocker.
- `NELU_ACCEPT` (4) — ours accepts where the oracle rejects. These are
  Nelu's beyond-oracle extensions (e.g. `any` as a tagged runtime type).
- `ORACLE_FAIL` (14) — the oracle itself fails; not our problem.
- `BOTH_FAIL` (9), `SKIP` (1) — nothing to compare.

Gates: `plan/cmp.py` (parser/AST floor), `plan/regress.py` (permanent
regression loop), `plan/examples_parity.py` (end-to-end execution).

## Where things live

```
nelua-lang/
|-- src/            # the compiler (what we ship)
|-- lib/, lualib/   # stdlib + oracle source (read-only reference)
|-- examples/       # our test corpus: top-level, www/, fuzz/, nelu/
|-- tests/, spec/   # the oracle's own, read-only
|-- plan/           # design docs, gate scripts, ticket board (TICKETS.md)
|-- tmp/            # scratch: build artefacts, probes, captures
|-- docs/           # the rendered site source
```

`src/` modules: `main.nim` (CLI), `compile.nim` (driver), `config.nim`,
`cli.nim`, `lexer.nim`, `parser.nim`, `ast.nim`/`astshapes.nim`, `sema.nim`,
`types.nim`, `preprocessor.nim`, `luaengine.nim` (embedded Lua), `analyzer.nim`,
`cgen.nim`/`cemitter.nim`/`cgen_types.nim` (AST → C). Vendored third-party
(`src/lua/*`, `src/lpeglabel/`, `src/rpmalloc/`, `src/luainit.c`) are
read-only and are **not** ported.

## Nelu beyond 0.2.0

0.2.0-dev parity is a *floor* for Nelu, not a boundary. Beyond-oracle work falls
into three kinds: **syntactic sugar** (keeps the Lua flavor and the C model),
**missing features** the oracle lacks, and **bug fixes** found driving real
programs through our compiler. A beyond-oracle feature that happens to also be
accepted by the oracle is parity, not a Nelu extension — it is noted as such.

**The parity/extension split (durable rule):** working code must work; we do not
care whether failing code fails the same way. A divergence only matters when the
oracle *runs* a program ours rejects (or vice versa); for constructs the oracle
never runs, the question is whether *we* run it, not whether we match it.

### Landed

- **`any` phase 2 — tagged runtime `any`.** A Nelu extension: `any` as a tagged
  union (`nlany`) with a runtime tag plus construction / dispatch helpers
  (`nlany_from_*`, `nlany_load_*`, `nelua_print_any`, `nlany_eq`). The oracle
  0.2.0-dev rejects every `any` construction; this is beyond-oracle.
- **`any` phase 1 — stop emitting broken C.** Deletes the `void*` lowering and
  instead emits the oracle's exact rejection for deduced `any`, `any` table
  literals, `: any` params, untyped params, and explicit `: any` returns.
  This is parity (matching the oracle's rejection), listed because it was the
  prerequisite for phase 2 and fixed a real broken-C bug.
- **Closures / upvalue scoping.** An inner function may read and write a
  module-scope `local`, which lowers to a file-scope `static` declared before
  the function definitions. Function-local capture is rejected at analysis with
  the oracle's exact message. 7 closure probes MATCH the oracle.
- **Pointer print spelling.** A non-null pointer prints as `0x` + lowercase hex
  (natural width, no leading zeros); a null pointer prints `(null)`,
  independent of pointee type. Parity with the oracle; it was a real bug (the
  arg was being thrown away).
- **`coroutine` — a Nelu stdlib module.** A `coroutine` handle type lowering to
  minicoro fibers (C backend only). The oracle has no `coroutine` module at all.
  Designed and probe-verified against the oracle's *absence*; the lowering is
  not yet wired into `cgen.nim`.

### Queued (designed, not landed)

- **Tables (C backend).** The oracle rejects tables; Nelu supports them.
- **Full exceptions** — `try`/`catch`/`finally` on top of the panic primitives
  that are already parity.
- **Generators / iterators** — `yield`-based, state-machine lowered to C. The
  oracle has no `yield`; the Nelu `coroutine` module is the suspension primitive.
- **Pattern matching** — `match`/`cond`/destructuring on top of the `switch`/
  `case`/`else` that is already parity.
- **Syntactic sugar** — anything that keeps the Lua flavor and the C model.

The full ledger for this branch was `NELU-2K.md`; its durable content is here,
and its stale gate numbers and dead doc references are dropped in favor of the
live State section above. New beyond-0.2.0 work is queued in `plan/TICKETS.md`.

## Design decisions (settled, do not re-litigate)

- Nelua source → (Nelu compiler) → C source → (gcc/cc) → binary.
- AST node shapes follow the oracle's; type-hierarchy properties
  (`is_integral`, `is_float`, `is_pointer`, `is_array`, `is_record`, …) match.
- C generation: one readable C file, sections (directives / declarations /
  definitions / bodies), `nelua_main` entry.
- **Embedded Lua VM for preprocessing**, not a Nim reimplementation.
  `luaengine.nim` compiles `src/lua/*` + `luainit.c` into the binary and runs
  `##` blocks as Lua chunks (state persists across blocks and across `require`d
  modules within one compilation; `resetLuaState()` isolates each compile).
- **One binary `nelu`.** The oracle's `nelua-lua` interpreter is subsumed:
  `--script` and `--lua` run its pure-Lua work through the embedded engine, and
  `--load` takes over the `-l mod` flag the oracle intended but never shipped.
- **Our own compiler everywhere, including preprocessing.** The embedded Lua
  is a sub-tool Nelu drives; the pp Lua runs against a Nim-provided C-ABI shim,
  not the oracle's compiler Lua.
- **The oracle's `.lua` compiler is reference only.** We have our own code and
  concepts; the stdlib is being taken over *against our compiler*, so our
  `lib/*.nelua` must not depend on requiring oracle compiler modules.
- Faithful-mode divergences we replicate verbatim: `local` is not hoisted;
  `string.find` returns `(0, 0)` on no match; `string.match` returns a sequence
  of captures; `_` is an undeclared identifier, not a discard; `os.execute`
  returns `true`/`false`; `any` is unsupported in faithful mode.

## Contributing

Throwaway probes go in `tmp/`, never `/tmp` and never the project root. No
`git` commands unless you explicitly instruct it. The ticket board is
`plan/TICKETS.md`; new work goes in `plan/INBOX/`, active in `plan/WIP/`,
finished in `plan/DONE/`.