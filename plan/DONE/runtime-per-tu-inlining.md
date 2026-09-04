# Runtime per-TU inlining + libm elimination


**Status:** DONE -- implemented.  Runtime helpers are now emitted as static per-TU definitions in the C preamble; `src/runtime.c` is no longer linked; `-lm` is conditional on `<math.h>`.

## Why

Today every compiled Nelua program links `src/runtime.c` as a separate
translation unit and passes `-lm`:

```
gcc ... <unit>.c runtime.c -lm -o <unit>
```

That is two things we want gone:

1. **The separate runtime link.** A generated translation unit should be
   self-contained.  The oracle does this: every helper it needs is emitted as a
   `static` definition right in the preamble, so `gcc` sees one `.c` file and
   nothing else.
2. **The libm dependency.** The only libm symbol our runtime touches is `pow`,
   through `nlpow` (the `^` power operator).  "Get rid of libm generally
   speaking" means the runtime must not depend on libm as a linked library —
   each TU that needs math gets its own `static` wrapper over `<math.h>`, like
   the oracle does.

## Current state (verified this session)

- `src/runtime.c` (416 lines) defines ~17 helpers:
  `nelua_print_double/string/bool/nil/ptr/sep/newline/any`,
  `nlany_from_*` / `nlany_load_*` / `nlany_eq`,
  `nlstring_concat` / `nlstring_free`, `nllen`, `nlpow`, `nlclose`,
  `nlcheck_int_overflow` / `nlcheck_uint_overflow` / `nlcheck_float_overflow`.
- `src/cgen.nim`'s `RUNTIME_C` preamble already emits the `nlstring`, `nlany`,
  `nlany_tag` typedefs per-TU (self-contained).  It emits **extern
  declarations** for the ~17 helpers so the TU links against `runtime.c`.
- `nlpow` is the sole libm user:
  `double nlpow(double a, double b){ return pow(a, b); }`.
- `src/compile.nim:295` links `runtime.c` + `-lm` for `okBinary` only
  (object / assembly / static-lib / shared-lib do not link it).
- Our compiler does not yet emit `math.*` member access (a parser gap); the only
  codegen path that reaches a math helper today is `^` → `nlpow`.

## Oracle behaviour (corrected — empirically verified)

The oracle does **not** implement math itself.  For `require "math"` programs
it emits, per TU and per used builtin, a thin wrapper such as:

```c
static NELUA_INLINE double nelua_math_floor_1(double x){ return floor(x); }
static NELUA_INLINE double nelua_math_sqrt_1(double x){ return sqrt(x); }
static NELUA_INLINE double nelua_math_pow_1(double x, double y){ return pow(x, y); }
```

It `#include`s `<math.h>` and passes `-lm` on the cold-build cc line:

```
gcc -x c "v.c" -x none -fwrapv -fno-strict-aliasing -g -lm -o "v"
```

Note: on this system plain `gcc` links `<math.h>` calls with **no** `-lm`
(verified: `gcc -o m m.c` with `sqrt(2.0)` compiles and runs).  So the
oracle's `-lm` is a no-op here, and so is ours.

## Goal

Match the oracle's per-TU inlining architecture:

- Each generated TU emits `static` (or `static NELUA_INLINE`) **definitions**
  of only the runtime helpers it actually references, in the preamble.
- No separate `runtime.c` link.  `compile.nim` stops referencing it.
- `nlpow` becomes a per-TU `static NELUA_INLINE` wrapper over `<math.h>`.
  `-lm` is dropped (no-op here; the runtime no longer links libm at all).
- Behaviour identical: same programs, same output, same cc flags minus the
  runtime link and `-lm`.

## Plan (for the isolated-copy agent)

Work on a copy under `tmp/<DATE>-<TIME>-<taskname>/`.  Never touch live
`src/`, never git.  Leave the copy in place as evidence; the coordinator
integrates.

1. **Track referenced helpers.** On the `Gen` object, keep a set of which
   runtime helpers the TU actually calls (print, any, string, math, panic,
   narrow-check).  Record it as each call is emitted in `genCall` /
   `genBuiltin` / the operator arms.

2. **Emit definitions, not declarations.** In `RUNTIME_C`, replace the blanket
   extern-declaration block with logic that emits a `static` /
   `static NELUA_INLINE` *definition* for each helper present in the set.
   Helpers already inlined inline (`nelua_abort`, `nelua_error_line`,
   `nelua_panic_string`, `nelua_assert_line`, `nelua_print_float`) stay as-is
   — they are already `static inline` and self-contained.

   For each helper, the body moves out of `src/runtime.c` and into the
   preamble text.  Keep the bodies identical (same C, same formatting) so
   behaviour is unchanged; only the linkage changes from `extern`-linked to
   `static`-per-TU.

3. **Math.** Emit `#include <math.h>` in the preamble when any math helper is
   referenced.  `nlpow` becomes:
   ```c
   static NELUA_INLINE double nlpow(double a, double b){ return pow(a, b); }
   ```
   (mirror the oracle's `nelua_math_*_1` naming convention if a future
   `math.*` codegen path is added — not required for `^` today).

4. **Stop linking the runtime.** In `src/compile.nim`, remove the
   `runtimeC` reference and the ` -lm` suffix from the `okBinary` cc command.
   Object / assembly / static-lib / shared-lib already do not link it — they
   must continue to produce self-contained output (a `.o` or `.s` must not
   reference symbols it cannot resolve).

5. **Verify.**
   - Build: `rm -rf /tmp/nimclean && nim c -d:release --path:src -o:tmp/nelua --nimcache:/tmp/nimclean src/main.nim` (fresh cache).
   - `nelua -V <prog>` cc line must contain neither `runtime.c` nor `-lm`.
   - Run a program exercising each helper family: `^` (nlpow), `print` of
     int/double/string/bool/nil, string concat, `any`, `assert`/`check`,
     `error`.  Output must be byte-identical to the pre-change build.
   - `examples_parity.py` gate must not regress (the 5 pre-existing DIFFs are
     parser gaps, unrelated — they must remain DIFF, not newly fail).

## Risks / notes

- **Larger TUs.** Inlining the print/any/string helpers bloats each TU.  That
  is the oracle's tradeoff too; `static` keeps it correct and avoids duplicate
  symbol errors across TUs.
- **`nltype_of_*` externs.** The preamble declares `extern const nltype
  nltype_of_int64` etc.  These are descriptors; check whether they are defined
  in `runtime.c` (in which case they move into the preamble too) or emitted
  elsewhere.  Do not break the `any` tagging path.
- **Shared library (`okSharedLib`).** If a shared lib is built from multiple
  TUs, `static` helpers are local to each TU (no cross-TU sharing) — correct,
  just not shared.  Confirm the existing shared-lib path still links.
- **Out of scope.** Parser gaps (`xoshiro256.nelua:10:3`, sequence, record
  inheritance), the 12 analyzer SIGSEGVs, and the preprocessor splice gap are
  not part of this task.