# Nelu beyond-oracle example corpus

20 self-contained Nelua sources under this directory. Each demonstrates a feature
that the oracle `/usr/bin/nelua` (0.2.0-dev) **rejects** while our compiler
`tmp/nelua` (the Nim clean-room reimplementation) **accepts and runs correctly**
(exit 0, sensible output). A broken/misleading example is worse than none, so every
row below was re-probed immediately before this index was written.

**Validity bar per file:** oracle exit != 0 **and** ours exit == 0.

## Table

| # | file | Nelu feature | what oracle does | what ours does | captured output |
|---|------|--------------|------------------|----------------|-----------------|
| 1 | `nelu_any_construct.nelua` | tagged `any` construction (`nlany_from_*`) | exit 1 — `error: compiler deduced type 'any' here` | exit 0 | `42 true 3.5 hello` |
| 2 | `nelu_any_dispatch.nelua` | tagged `any` load/dispatch (`nlany_load_*`) | exit 1 — `from: AST node Block` | exit 0 | `42 true 3.5 hi` |
| 3 | `nelu_any_function.nelua` | `any` parameter / `any` return value | exit 1 — `error: compiler deduced type 'any' here` | exit 0 | `99` |
| 4 | `nelu_cimport_function.nelua` | `<cimport>` pulling a real libc symbol (`sqrt`) | exit 1 — `from: AST node Block` | exit 0 | `4.0` |
| 5 | `nelu_subarray_type.nelua` | `subarray(T)` type constructor + `#` length | exit 1 — `from: AST node Block` | exit 0 | `4` |
| 6 | `nelu_forin_array.nelua` | `for v in array` (array-walk iteration) | exit 1 — `from: AST node Block` | exit 0 | `100` |
| 7 | `nelu_string_concat.nelua` | `..` string concatenation operator | exit 1 — `from: AST node Block` | exit 0 | `foobar n=42 12` |
| 8 | `nelu_mustcheck.nelua` | `<mustcheck>` function annotation | exit 1 — `from: AST node Block` | exit 0 | `5` |
| 9 | `nelu_discard.nelua` | `<discard>` (nodiscard) function annotation | exit 1 — `from: AST node Block` | exit 0 | `12` |
| 10 | `nelu_nogc.nelua` | `<nogc>` (disable GC for a function body) | exit 1 — `from: AST node Block` | exit 0 | `6` |
| 11 | `nelu_noexcept.nelua` | `<noexcept>` function annotation | exit 1 — `from: AST node Block` | exit 0 | `6` |
| 12 | `nelu_raises.nelua` | `<raises>` (may-throw) function annotation | exit 1 — `from: AST node Block` | exit 0 | `14` |
| 13 | `nelu_panic.nelua` | `<panic>` (noreturn-on-throw) function annotation | exit 1 — `from: AST node Block` | exit 0 | `8` |
| 14 | `nelu_export.nelua` | `<export>` symbol annotation | exit 1 — `from: AST node Block` | exit 0 | `11` |
| 15 | `nelu_cvar.nelua` | `<cvar>` C-linkage global | exit 1 — `from: AST node Block` | exit 0 | `4` |
| 16 | `nelu_zeroinit.nelua` | `<zeroinit>` zero-initialised global array | exit 1 — `from: AST node Block` | exit 0 | `0` |
| 17 | `nelu_uninit.nelua` | `<uninit>` uninitialised local | exit 1 — `from: AST node Block` | exit 0 | `9` |
| 18 | `nelu_close.nelua` | `<close>` (RAII-style scoped cleanup) function | exit 1 — `from: AST node Block` | exit 0 | `ok` |
| 19 | `nelu_inferred.nelua` | `<inferred>` type-inference annotation | exit 1 — `from: AST node Block` | exit 0 | `5` |
| 20 | `nelu_experimental.nelua` | `<experimental>` feature-gate annotation | exit 1 — `from: AST node Block` | exit 0 | `5` |

**Coverage split:** 7 real-language features (rows 1–7: tagged `any` ×3,
`<cimport>`, `subarray`, `for v in array`, `..`) + 13 permissive Nim-style
annotations (rows 8–20). The oracle rejects all 20; ours accepts and runs all 20.

## How the oracle rejects

The oracle's annotation grammar is a strict allowlist. Anything outside it is
rejected with a generic `from: AST node Block` diagnostic (exit 1). The three
`any` files are rejected with the more specific `compiler deduced type 'any'
here` message. In every case the oracle refuses to emit C; ours does.

## Candidates tried but NOT landed (skipped)

These were probed and are **not** valid beyond-oracle examples in the current
`tmp/nelua` build. They are listed so a future pass does not re-try them blind.

| feature | why skipped |
|---------|-------------|
| `defer` / `cond` / `match` / `try`-`catch` | not landed — both compilers reject (or oracle accepts = parity) |
| `yield` / generators | not landed |
| tables (`{a=1}` / `t[k]`) | `lib/table.nelua` is a `static_error 'tables are not implement yet'` stub; not landed |
| `require "coroutine"` | **parity** — the oracle also has a `coroutine` module (`/usr/lib/nelua/lib/coroutine.nelua`); not beyond-oracle |
| operator overloading (`__add`, `__index`, `__call`, …) | parity (oracle accepts) but ours has C-emission bugs — not a clean ours-only win |
| `any == any` equality | `nlany_eq` exists in `runtime.c` but is **not** wired into cgen's `==`; C compile fails with `invalid operands to binary ==` |
| `any` inside record fields / arrays | lowers to wrong values in ours (e.g. `Box{value=42}` then read prints `0`); only scalar `any` is correct |
| `subarray` indexing (`s[i]`) | off-by-one and out-of-bounds in ours; `#s` (length) is correct, so the example uses length |
| `<noreturn>` on a void function | **oracle accepts it** (exit 0) — parity, not beyond-oracle |
| `typeof` / `sizeof` / `alignof` as print values | print null / SIGSEGV in ours |
| `offsetof` / `nameof` | SIGSEGV in ours |
| `dynlib` / `importc` weak linking | not landed |
| `require "string"` from a non-project cwd | ours cannot resolve the module (no `lib/` under `tmp/nelu_probes/`); a module-resolution quirk, not a feature |

## Notes

- All probes were run with the harness in `tmp/nelu_probes/_probe.sh` against a
  fresh `nim c -d:release --path:src -o:tmp/nelua src/main.nim` build.
- Each file is self-contained: no file I/O, no SDL, no randomness, one clear
  output line, deterministic.
- Pre-existing files in this directory (e.g. `nelu_closures.nelua`,
  `nelu_table_literal_sideeffect.nelua`, …) are **not** part of this corpus —
  many are broken (both compilers reject, or the oracle accepts) and are left
  untouched.