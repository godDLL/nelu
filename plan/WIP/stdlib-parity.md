# Stdlib / module-system parity push (Nelu)

**Goal.** Our clean-room compiler compiles the Nelua stdlib `lib/*.nelua`, matching
the oracle. Oracle: 16/18 compile (the 2 failures are by-design - `table` is rejected
by the C backend, `builtins` is doc-only and must never be required). Ours: **0/18**.

## Why it is not a coverage tweak

Every stdlib module fails at parse. The most common blocker is `require`, which the
parser has no rule for at all (it is only a lexer keyword and an analyzer
"do-not-emit" name). But `require` alone would unblock **nothing** - I counted
advanced-feature usage per module:

```
0 builtins, table        10 traits, vector      24 hashmap          47 coroutine
3 arg                   11 sequence, span      31 filestream       51 math
9 utf8                  12 hash, io            35 os               167 string
```

Every module uses at least one of:
- attributes - `@record{}`, `@uint32`, `#[concept(...)]#`
- C interop - `<cimport,cinclude>`, `pointer`, `csize`/`cint`
- global namespace records - `global X: type = @record{}`

So this is a **foundational feature push**, not a coverage tweak. It is genuine parity
(the oracle does all of it), just large.

## Phases

1. **Module system** - `require` statement, module path resolution, recursive
   dependency compilation + caching, header emission.
2. **Attributes** - `@` annotations, `#[ ... ]#` meta-annotations, concepts.
3. **C interop** - `<cimport,cinclude>`, C type aliases (`csize`, `cint` ...).
4. **Global namespace records** - `global X: type = @record{}`.
5. **Re-sweep stdlib** - bring modules online one at a time; keep a coverage table
   (`tmp/stdlib_coverage.md`) of oracle-vs-ours exit code, stdout, diff.

## File ownership / the D1 race

Phase 1 needs to *edit* `analyzer.nim` (wire dependency symbols into the parent
scope) and `cgen.nim` (emit `#include "dep.h"`). D1 owns both right now and is
actively editing them. So phase 1 splits:

- **1a (now, non-racing)** - `parser.nim`, `preprocessor.nim`, `compile.nim`,
  `config.nim`. Parse `require`; resolve module paths; compile + cache dependencies
  recursively. Imports `analyzer.nim`/`cgen.nim` read-only (that is fine - the race
  is about *editing* source, not importing it). Deferred: symbol wiring and header
  emission.
- **1b (after D1 lands)** - `analyzer.nim` scope integration + `cgen.nim` header
  emission, then the full `require` round-trip.

## Verification

Oracle baseline per module: `/usr/bin/nelua -o /tmp/t_N lib/N.nelua`; record exit
code + stdout. Ours: `tmp/nelu ...`. Coverage table in `tmp/stdlib_coverage.md`.
---

# Part 2 -- Stdlib coverage survey

Read-only research. Oracle = `/usr/bin/nelua` (authoritative 0.2.0-dev). Ours =
  ([-c] | [-a] | [-b] | [-B] | [-Y] | [-A] | [-H] | [--script] | [--lint] | [--print-ast] | [--print-analyzed-ast] | [--print-ppcode] | [--print-code] | [--print-assembly])
  [-h] [-i] [-d] [-S] [-r] [-M] [-s] [-t] [-T] [-V] [-w] [-C]
  [--no-color] [-R <runner>] [-o <output>] [-D <define>] [-P <pragma>]
  [-g <generator>] [-L <add_path>] [--cc <cc>] [--cflags <cflags>]
  [--ldflags <ldflags>] [--stripflags <stripflags>]
  [--cache-dir <cache_dir>] [--path <path>]
  ([<input>] | [--config] | [-v] | [--semver]) [<runargs>] ...

Nelua 0.2.0-dev

Arguments:
  input                     Input source file
                            Use '-' to read from stdin
  runargs                   Arguments passed to the application
                            Use '--' to avoid conflicts with compiler options

Options:
  -h, --help                Show this help message and exit.
  -c, --code                Compile the backend code only
  -a, --analyze             Analyze the code only
  -b, --binary              Compile the binary only
  -B, --object              Compile as an object file
  -Y, --assembly            Compile as an assembly file
  -A, --static-lib          Compile as a static library
  -H, --shared-lib          Compile as a shared library
  --script                  Run lua a script instead of compiling
  --lint                    Check for syntax errors only
  --print-ast               Print the AST only
  --print-analyzed-ast      Print the analyzed AST only
  --print-ppcode            Print the generated Lua preprocessing code only
  --print-code              Print the generated code only
  --print-assembly          Print the assembly generated code only
  --config                  Print config variables only
  -v, --version             Print compiler detailed version
  --semver                  Print compiler semantic version
  -i, --eval                Evaluate string code from input
  -d, --debug               Run through GDB to get crash backtraces
  -S, --sanitize            Enable undefined/address sanitizers at runtime
  -r, --release             Release build (optimize for speed and disable
                            runtime checks)
  -M, --maximum-performance Maximum performance build (use for benchmarking)
  -s, --strip-bin           Remove symbols from the compiled binary (reduce its
                            size)
  -t, --timing              Show compile timing information
  -T, --more-timing         Show detailed compile timing information
  -V, --verbose             Show compile related information
  -w, --no-warning          Suppress all warning messages
  -C, --no-cache            Don't use any cached compilation
  --no-color                Disable colorized output in the terminal.
        -R <runner>,        Execute compiled output with a runner
  --runner <runner>
        -o <output>,        Output file.
  --output <output>
        -D <define>,        Define values in the preprocessor
  --define <define>
        -P <pragma>,        Set initial compiler pragma
  --pragma <pragma>
           -g <generator>,  Code generator backend to use (lua/c) (default: c)
  --generator <generator>
          -L <add_path>,    Add module search path
  --add-path <add_path>
  --cc <cc>                 C compiler to use (default: gcc)
  --cflags <cflags>         Additional flags to pass to the C compiler (default:
                            )
  --ldflags <ldflags>       Additional flags to pass when linking (default: )
  --stripflags <stripflags> Additional flags to pass when striping (default: -x)
  --cache-dir <cache_dir>   Compilation cache directory (default:
                            /home/user/.cache/nelua)
  --path <path>             Set module search path (default:
                            ./?.nelua;./?/init.nelua;/usr/lib/nelua/lib/?.nelua;/usr/lib/nelua/lib/?/init.nelua) (authoritative 0.2.0-dev). Ours =
Usage: nelua [options] [input ...]

Options:
  -r, --release            Release build (optimize, disable checks)
  -b, --binary             Produce a binary (default)
  -B, --object             Compile to a relocatable object (.o)
  -Y, --assembly          Emit assembly (.s)
  -A, --static-lib         Archive into a static library (.a)
  -H, --shared-lib         Link into a shared library (.so)
  -c, --code               Emit C and stop
  -a, --analyze            Analyze only, no codegen
  --lint                   Check for syntax errors only
  --script                 Run a Lua script instead of compiling
  --print-ast              Print the AST
  --print-analyzed-ast     Print the analyzed AST
  --print-ppcode           Print the preprocessing code
  --print-code             Print the generated code
  --print-assembly         Print the assembly generated code only
  -P <pragma>              Set initial compiler pragma
  -i <code>                Evaluate a nelua string
  --eval <code>            Evaluate a nelua string
  -D <define>              Define a preprocessor value
  --cc <cc>                C compiler to use (default: gcc)
  --cflags <flags>         Extra flags for the C compiler
  --ldflags <flags>        Extra flags for the linker
  --path <dir>             Add a module search path
  -R <runner>              Execute compiled output with a runner
  --runner <runner>        Execute compiled output with a runner
  -L <dir>, --add-path <dir>  Add a module search path (accumulating)
  -o <output>              Output file
  --cache-dir <dir>        Compilation cache directory
  -s, --strip-bin          Strip symbols from the binary
  --stripflags <flags>     Flags passed to strip (default: -x)
  --sanitize               Enable runtime sanitizers
  -g <generator>           Code generator backend (default: c)
  --no-cache               Do not use cached compilation
  --version                Print the version and exit
  --semver                 Print the semantic version and exit
  --config                 Dump the effective configuration and exit
  -w, --no-warning         Disable warnings (hook; none emitted yet)
  --no-color               Disable ANSI colour (hook; none emitted yet)
  -D <define>              Define a preprocessor value
  --define <define>        Define a preprocessor value
  -P <pragma>              Set initial compiler pragma
  --pragma <pragma>        Set initial compiler pragma
  -M, --maximum-performance Optimize for maximum performance
  -t, --timing             Print per-stage timing
  -T, --more-timing        Print per-file timing
  -d, --debug              Run the binary under GDB
  -V                       Verbose: echo generated C and cc command line
  --help                   Show this help and exit.

`tmp/nelu` (built from current `src/`). No source file was edited; scratch probes
went to `tmp/`.

## 0. Scope correction: where the runtime stdlib actually lives

The task brief names `lualib/nelua/*.lua` as the oracle stdlib. That path is the
**compiler's own Lua source** (analyzer.lua, cgenerator.lua, types.lua, …) plus
`utils/` and `thirdparty/` - it is consumed at *build* time, not at *runtime* by
nelua programs. It is identical in shape between oracle and ours (only the
`plugins/` subdir differs, and that is a compiler plugin, not a runtime module).

The **runtime stdlib** - the `.nelua` modules a program `require`s - lives elsewhere:

| | runtime stdlib |
|---|---|
| Oracle | `/usr/lib/nelua/lib/**/*.nelua` (48 files) |
| Ours | `/home/user/Code/nelua-lang/lib/**/*.nelua` (44 files, incl. `lib/C/` and `lib/detail/`; taken into the tree at `f75601a`) |

Everything below compares these two trees. `require 'math'` resolves to
`lib/math.nelua` (ours) vs `/usr/lib/nelua/lib/math.nelua` (oracle).

## 1. Headline result

> **Count note (2026-09-03).** The "23 total corpus DIFFs" below is the survey's
> own sweep count and is **stale**; it is superseded by `tmp/wwwcheck.py`, which
> now reads **90 PASS / 6 DIFF over 105 files**. The headline still holds in
> substance: of the 6 current DIFFs, exactly one is a stdlib-function gap
> (`math.iround`, needed by `examples/www/www_math.nelua`). The other five are
> 2 oracle-side unsupported (`www_for_in_array`, `www_string_concat`), 2
> `splice_embed` (execution-model gap), and 1 `www_neg_for` (pre-existing analyze
> error).

**Of the 23 total corpus DIFFs (18 `examples/www/` + 5 `examples/`), exactly ONE
is a stdlib-function gap: `math.iround`, needed by `examples/www/www_math.nelua`.**

Breakdown of the 23: 1 stdlib gap + 2 that fail to build **on the oracle itself**
(`www_string_concat`, `www_for_in_array` - not our responsibility) + 20 that are
compiler gaps in ours (parser / preprocessor / analyzer / C-code generator /
lexer), not missing stdlib functions. Of the 18 www DIFFs specifically: 1
stdlib (`www_math`), 2 oracle-side, 15 our-side compiler gaps.

Corpus stdlib demand is concentrated in almost no files: across all three
corpora (10 + 105 + 32 = 147 files) only 9 files `require` any runtime stdlib
module at all, and only 2 of those are in a parity gate. The 78 passing www files
use only language builtins (`print`, `math`/`string`/`table` as global *types*,
array/record literals, operators) and never `require` anything.

## 2. Summary table

"Port size" = approximate lines of the oracle's implementation; "probes" = number
of **gated** corpus files (the parity gates: `examples/`, `examples/www/`,
`examples/nelu/`) that call it. "Parity" = oracle accepts and we must match;
"Extension" = oracle rejects (or does not have it) and we may keep/add.

### 2a. Functions present in oracle, MISSING in ours

| Module | Function | Oracle line | Probes needing it | Port size | Kind |
|---|---|---|---|---|---|
| `math` | `math.iround` | `lib/math.nelua:131` | **1** (`www_math`) | 4 | Parity |
| `math` | `math.itrunc` | `lib/math.nelua:146` | 0 | 4 | Parity |
| `math` | `math.isnan` | `lib/math.nelua:600` | 0 | ~22 | Parity |
| `math` | `math.isinf` | `lib/math.nelua:623` | 0 | 6 | Parity |
| `math` | `math.isfinite` | `lib/math.nelua:632` | 0 | 2 | Parity |
| `string` | `string.concat` | `lib/string.nelua:269` | 0 | ~31 | Parity |
| `string` | `string.gsub` | `lib/string.nelua:685` | 0 | ~149 | Parity |
| `os` | `os.setenv` | `lib/os.nelua:117` | 0 | ~37 | Parity |
| `os` | `os.realtime` | `lib/os.nelua:448` | 0 | ~85 | Parity |
| `io` | `io.print` | `lib/io.nelua:232` | 0 | ~9 | Parity |
| `filestream` | `filestream:printf` | `lib/filestream.nelua:449` | 0 | ~5 | Parity |
| `filestream` | `filestream:print` | `lib/filestream.nelua:455` | 0 | ~18 | Parity |
| `coroutine` | `coroutine:__close` | `lib/coroutine.nelua:59` | 0 | ~14 | Parity |
| `allocators/gc` | `GC:step` | `lib/allocators/gc.nelua:367` | 0 | ~11 | Parity |
| `allocators/gc` | `GC:setstacktop` | `lib/allocators/gc.nelua:471` | 0 | ~14 | Parity |
| `sequence` | `sequenceT:unpack` | `lib/sequence.nelua:304` | 0 | ~10 | Parity |
| `stringbuilder` | `stringbuilderT:__tostringview` | `lib/stringbuilder.nelua:412` | 0 | ~47 | Parity |
| `stringbuilder` | `stringbuilderT:rollback` | `lib/stringbuilder.nelua:158` | 0 | ~300 | Parity |
| `hashmap` | `hashmapT:has` | `lib/hashmap.nelua:324` | 0 | ~10 | Parity |
| `hashmap` | `hashmapT:has_and_get` | `lib/hashmap.nelua:334` | 0 | ~15 | Parity |
| `hashmap` | `hashmapT:erase` | `lib/hashmap.nelua:377` | 0 | ~15 | Parity |
| `hashmap` | `hashmapT:__next` | `lib/hashmap.nelua:494` | 0 | ~10 | Parity |
| `hashmap` | `hashmapT:__mnext` | `lib/hashmap.nelua:501` | 0 | ~10 | Parity |
| `hashmap` | `hashmapT:_next_node` | (internal) | 0 | ~10 | Parity |
| `hashmap` | `hashmap_iteratorT:_next_node` | (internal) | 0 | ~10 | Parity |

### 2b. Modules present in oracle, MISSING entirely in ours

| Module | Public API | Probes needing it | Port size | Kind |
|---|---|---|---|---|
| `allocators/aligned` | `AlignedAllocatorT` (alloc, dealloc, get_realptr) | 0 | 77 | Parity |
| `detail/minicoro` | `minicoro` (create/init/resume/yield/status/…) 16 funcs | 0 | 2139 | Parity (coroutine backend) |
| `detail/strchar` | `strchar` (isalpha/isdigit/tolower/…) 14 funcs | 0 | 119 | Parity |
| `detail/strconv` | `strconv` (str2int/int2str/str2num/num2str) 4 funcs | 0 | 361 | Parity |
| `detail/strpack` | `strpack` (pack/unpack/packsize) 3 funcs | 0 | 391 | Parity |
| `detail/strpatt` | `StrPatt` (create/match/get_capture/…) 7 funcs | 0 | 418 | Parity |
| `detail/strprintf` | `strprintf.snprintf` | 0 | 3080 | Parity |
| `errorhandling` | (only an internal `cgenerator.visitors.Call` symbol - false positive) | 0 | 310 | n/a |

None of these eight modules is required by any corpus file. They are transitive
dependencies only: `strchar`/`strpatt`/`strpack`/`strprintf` are pulled by the
oracle's `string.nelua`; `minicoro` by the oracle's `coroutine.nelua`; `aligned`
by `allocators.allocator.nelua`. **Ours does not need most of them**: our
`string.nelua` substitutes `detail.patternmatcher` for `detail.strpatt` and never
`require`s `strchar`/`strpack`/`strprintf`; our `coroutine.nelua` is a separate
(bigger) implementation that does not use `minicoro`.

### 2c. Functions we have but implement differently / that are broken

| Module | Function | Probes needing it | Divergence | Kind |
|---|---|---|---|---|
| `math` | `math.random` | 3 (`condots` SKIP, `gameoflife` DIFF, `snakesdl` SKIP) | **SIGSEGV** in ours; oracle returns floats. Different RNG (ours = xoshiro256 with different seeding). | Parity (broken) |
| `string` | `string.lower` (and the whole `require 'string'` chain) | 1 (`overview` SKIP) | `require 'string'` **SIGSEGVs our compiler** at load time | Blocker |
| `span` | `span.empty`/`len`/etc. | 1 (`overview` SKIP) | `require 'span'` **SIGSEGVs our compiler** at load time | Blocker |
| `os` | `os.sleep` | 1 (`gameoflife` DIFF) | `require 'os'` fails to **parse** our `os.nelua` at line 165 (`(@string){}` cast) | Compiler gap |
| `traits` | `traits.is_attr`/`is_number`/`is_type` | 1 (`overview` SKIP) | Ours-only; oracle has `traits.typeid`/`traits.typeinfo` instead | Extension |
| `detail/xoshiro256` | `Xoshiro256:random` (ours) vs `randomfloat`/`randomuint` (oracle) | 0 | Renamed API | Extension |

### 2d. Nelu extensions we ship that the oracle does not

| Module | Function | Notes |
|---|---|---|
| `detail/patternmatcher` | `PatternMatcher` (create/match/get_capture/…) 6 funcs | Our replacement for the oracle's `detail/strpatt`. **Crashes our analyzer** (`--print-analyzed-ast` SIGSEGV), which is the root cause of the `require 'string'` blocker. |
| `traits` | `is_attr`/`is_number`/`is_type` | Used only by `overview` (SKIP). |
| `math` | different RNG, `import_cmath_func1_int` | Non-divergent on corpus inputs. |

## 3. Per-function detail

### 3.1 `math.iround` - the only corpus-driven stdlib gap

- **What it does**: returns `math.round(x)` cast to `integer` (always-integral
  result, unlike `math.round` which preserves float type).
- **Oracle source**: `lib/math.nelua:131-134` (4 lines):
  ```nelua
  function math.iround(x: an_scalar): integer <inline,nosideeffect>
    return math.round(x)
  end
  ```
- **How the corpus uses it**: `examples/www/www_math.nelua:3`
  (`print(math.iround(2.5))`) and `examples/www/seqtoy/seqtoy.nelua:561`
  (`math.iround(4*sinc_impulse(...))`). `seqtoy` lives in a subdirectory and is
  not in the www parity gate; `www_math` is.
- **Exact divergence**: our `lib/math.nelua` has no `math.iround`. Verified by
  grep and by the function-level diff. Once the in-flight `##[[` parse fix lets
  our compiler load `lib/math.nelua`, `www_math` will then fail on the missing
  `math.iround` (it also calls only `ifloor/clamp/abs/min/max/sin/pi`, all of
  which we have).
- **Port**: trivial - copy the 4-line oracle body. Depends on `math.round` and
  `an_scalar`, both already present in our `math.nelua`.

### 3.2 The `require 'string'` / `require 'span'` blockers (not corpus-gated, but severe)

- **`require 'string'`**: SIGSEGVs our compiler at load. Root cause traced:
  our `string.nelua` `require`s `detail.patternmatcher`, and
  `require 'detail.patternmatcher'; print(1)` SIGSEGVs during **analysis**
  (`--print-ast` succeeds, `--print-analyzed-ast` crashes). So our Nelu
  `patternmatcher` replacement is broken, and it takes the whole `string`
  ecosystem down with it. Transitively blocks `os`, `filestream`,
  `stringbuilder`, `utf8` (all of which `require 'string'`).
- **`require 'span'`**: SIGSEGVs our compiler at load (verified standalone).
- **`require 'memory'`/`sequence'`/`iterators'`/`allocators.default'`**:
  SIGSEGV our compiler at load (verified standalone).
- **Corpus impact**: the only gated files that `require` any of
  `string`/`span`/`memory`/`sequence`/`iterators` are `overview` (SKIP - oracle
  itself exits 1) and `www_mipairs` (SKIP - both build-fail). **No gated PASS or
  DIFF file requires them.** So these are latent, not DIFF-driving. But they are
  real: `gameoflife` (DIFF) `require`s `os`+`io`, which transitantly `require
  'string'`; it parse-fails in `os.nelua`/`io.nelua` before the load crash is
  reached.
- These are compiler-analyzer stability bugs, not stdlib-omission gaps. The
  oracle's `string`/`span` load fine.

### 3.3 `os.nelua` parse failure (compiler gap, not stdlib)

- `require 'os'` fails: `lib/os.nelua:165:38: error: expected ')' after generic
  type arguments`. Line 165 is `return true, (@string){}, 0` inside
  `os.rename` - a type-as-value cast of an empty table to `string`. The oracle's
  `os.nelua` uses the identical construct and parses it. This is our compiler's
  type-as-value/cast gap (recently touched by the "type-as-value in analyzer"
  commit), not a missing function.

### 3.4 `math.random` (broken, not corpus-gated)

- Oracle: `math.randomseed(12345); math.random()` returns a reproducible float
  sequence. Ours: SIGSEGV. Used by `condots` (SKIP/timeout), `gameoflife`
  (DIFF - parse-fails first), `snakesdl` (SKIP/timeout). No gated PASS file.
- Our `math.nelua` RNG is a Nelu xoshiro256 variant with different seeding; the
  crash appears to be a nil deref in the random path. Worth fixing because
  `gameoflife` needs it once its parse gaps are cleared.

### 3.5 `require` silently returns nil for missing modules (behavior gap)

- Oracle: `require 'does.not.exist'` → `error: in require: module '...' not
  found: no file '.../does/not/exist.nelua'`.
- Ours: returns nil silently; the program compiles with an empty value and only
  fails later (e.g. C compile error `variable or field '…' declared void` /
  `… = ;`). Verified with `require 'does.not.exist'` and `require
  'detail.strchar'` (a module we do not ship).
- This **masks** stdlib gaps: a probe that `require`s a module we lack will not
  get a clear "module not found" error, so the failure looks like a downstream
  cgen/analyzer bug instead. This should be fixed before relying on require
  errors to triage.

### 3.6 Functions we have and that pass on corpus inputs

The 78 passing www files exercise `math.abs`, `math.min`, `math.max`,
`math.sin`, `math.sqrt`, `math.pi`, `math.clamp`, `math.floor`, `math.ifloor`,
`math.randomseed` (via `mersenne`'s own Twister, not stdlib), and the `string`/
`math`/`table` global *types*. All produce oracle-matching output. No evidence of
divergence in these.

## 4. Recommended port order

All parity ports below are small and independent of each other. Order is by
corpus impact first, then by dependency safety.

1. **`math.iround`** (4 lines, `lib/math.nelua:131`). The only function that
   drives a gated DIFF. Also add `math.itrunc` while there (4 lines, same
   neighborhood) since it is the same class of "integer-rounded variant" and is
   trivial. Unblocks `www_math` once the `##[[` parse fix lands.
2. **`math.isnan` / `math.isinf` / `math.isfinite`** (~30 lines total,
   `lib/math.nelua:600-635`). Zero corpus probes today, but `isfinite` is
   `not isnan and not isinf`, so they form one unit; `isnan` is the only
   non-trivial one (float-bit manipulation). Cheap, completes the `math` parity
   surface.
3. **`require` must error on missing modules** (compiler change, not stdlib).
   Before porting anything else, fix this so gaps are diagnosable. Small change
   in the require-resolution path.
4. **Fix the `detail/patternmatcher` analyzer crash** (or drop it and port the
   oracle's `detail/strpatt` instead). This unblocks `require 'string'`, which
   unblocks `os`/`filestream`/`stringbuilder`/`utf8`. Highest-leverage fix after
   the math ports, even though it gates no current DIFF.
5. **`io.print`** (~9 lines, `lib/io.nelua:237`) and **`filestream:print` /
   `filestream:printf`** (~23 lines, `lib/filestream.nelua:449-473`). Both are
   trivial one-liners that delegate to `writef`/`printf` machinery we already
   have. Zero corpus probes, but they complete the `io`/`filestream` surface.
6. **`string.concat`** (~31 lines, `lib/string.nelua:269`) and **`string.gsub`**
   (~149 lines, `lib/string.nelua:685`). `gsub` is the heavy one (pattern
   replacement over `strpatt`/`patternmatcher`). Zero corpus probes. Port
   `concat` now (cheap); defer `gsub` until the pattern-matcher subsystem is
   healthy (step 4).
7. **`os.setenv`** (~37 lines, `lib/os.nelua:117`) and **`os.realtime`**
   (~85 lines, `lib/os.nelua:448`). Zero corpus probes. `realtime` is the
   larger one (clock_gettime / timespec). Port `setenv` now, `realtime` after.
8. **`coroutine:__close`** (~14 lines, `lib/coroutine.nelua:59`),
   **`GC:step` / `GC:setstacktop`** (~25 lines, `lib/allocators/gc.nelua:367,
   471`), **`sequenceT:unpack`** (~10 lines, `lib/sequence.nelua:304`),
   **`stringbuilderT:__tostringview` / `rollback`** (~350 lines,
   `lib/stringbuilder.nelua:158,412`). All zero corpus probes; `rollback` is the
   only large one. Port the small ones freely; defer `rollback`.
9. **`hashmap` parity** (~70 lines across 7 functions,
   `lib/hashmap.nelua:324-501`). Zero corpus probes. Our `hashmap` is smaller than
   the oracle's; these fill the iterator/erase/has surface. Medium effort, no
   corpus pull.
10. **Port the eight missing modules** (`aligned`, `minicoro`, `strchar`,
    `strconv`, `strpack`, `strpatt`, `strprintf`). **None is corpus-driven.**
    Only worth doing if a future probe needs them, or if the oracle's
    `string.nelua`/`coroutine.nelua` is to be dropped in verbatim (which would
    then pull them in). `strprintf` (3080 lines) and `minicoro` (2139 lines) are
    large; do not port on speculatation.

**Extensions (do not port - oracle does not have them; keep ours):**
`detail/patternmatcher` (fix it, do not replace it with `strpatt`),
`traits.is_attr`/`is_number`/`is_type`, `Xoshiro256:random`, the `math` RNG
variant, `import_cmath_func1_int`.

## 5. Explicitly undetermined / could not determine

- **Exact line count for `string.gsub` and `stringbuilderT:rollback`.** The
  heuristic end-detector stops at the next top-level `function`/`global`/`##`,
  which underestimates `gsub` (near end of file) and overestimates `rollback`
  (rest of file). Treat "~149" and "~300" as order-of-magnitude only; read the
  oracle source for the true span.
- **Whether `math.random` is fixable by a small patch or needs the RNG rewrite.**
  I only confirmed it SIGSEGVs; I did not locate the nil-dereference site.
- **Whether the `require 'string'`/`require 'span'` crashes are pre-existing or a
  recent regression.** They are reproducible now; I did not bisect against an
  older `tmp/nelu`.
- **The 5 `examples/` DIFFs are fully characterized as parse/compiler gaps by
  `plan/examples-diffs-triage.md`; I did not re-derive them here.** They are not
  stdlib gaps (verified: `fibonacci`/`gameoflife` need only `math.floor`/
  `math.sqrt`/`math.random`/`math.randomseed`/`os.sleep`/`io.flush`/`io.write`,
  all of which we define - the failures are in *parsing* `math.nelua`'s
  `#|name|#`, `os.nelua`'s `string.copy`, `io.nelua`'s `global io.stderr`, and
  `matmul`'s `@sequence(sequence(number))`).
- **`mersenne.nelua` is a MATCH but does not exercise stdlib `math.random`** -
  it implements its own Mersenne Twister. So the `math.random` divergence has
  zero gated impact.
- **The `examples/nelu/` corpus (10 MATCH / 1 extension / 0 DIFF) requires no
  stdlib module at all** (verified by grep over all 32 files), so it has no
  stdlib gaps to report.
- **The 2 oracle-side build failures** (`www_string_concat`: `'n=' .. 42`;
  `www_for_in_array`: `from: AST node Block`) are the oracle's own limitations,
  not ours.

## 6. Reproduction commands

```
# www parity gate (18 DIFF / 78 PASS / 8 SKIP of 105)
python3 tmp/wwwcheck.py

# examples parity gate (2 MATCH / 5 DIFF / 3 SKIP of 10)
python3 plan/examples_parity.py

# function-level stdlib diff (oracle vs ours)
python3 /tmp/extract3.py > /tmp/fn_diff.txt

# corpus stdlib demand
python3 /tmp/scan_corpus2.py

# require silently returns nil for missing modules (ours errors, oracle does not)
tmp/nelu -b -o /tmp/x tmp/req4.nelua      # req4: require 'does.not.exist'
/usr/bin/nelua -b -o /tmp/x tmp/req4.nelua

# math.iround missing in ours, present in oracle
grep -n "function math.iround" lib/math.nelua            # nothing
grep -n "function math.iround" /usr/lib/nelua/lib/math.nelua   # line 131
```
---

# Part 3 -- Stdlib inheritance + two language gaps

pattern-matching agent left open: untyped-function return deduction, closure/upvalue
scoping). Research only - no `src/` edits, no gate-script edits, no commit.

Tools: oracle `/usr/bin/nelua` (Nelua 0.2.0-dev, build 1635, git a5845056);
ours `tmp/nelu` (built `nim c -d:release --path:src -o:tmp/nelu src/main.nim`).
Probe files live in `/tmp/research_probes/` (throwaway, unique filenames because the
oracle caches `--print-ast` by name). Driver: `/tmp/research_probes/driver.py`,
survey: `/tmp/research_probes/survey/run.py`.

---

## Task 2 - why the inherited stdlib (`lib/`) won't compile through us

### 2.1 Method

`lib/` is a **require-dependency graph, not a set of standalone files** - compiling
`lib/math.nelua` alone fails on *both* compilers (`error: undeclared symbol 'Xoshiro256'`,
defined in `lib/detail/xoshiro256.nelua`). So the honest probe is require-based: copy the
oracle's own `tests/<module>_test.nelua` (each one `require`s its module and exercises
real symbols - these are the oracle's *own* behavioral spec for the module) to a unique
temp name, compile+run through the oracle and through ours, and diff stdout + exit code.

Classification: **MATCH** (same exit code + identical stdout), **DIFF** (both run, output
diverges), **FAIL(us)** (oracle OK, we don't), **FAIL(both)** (neither runs).

Coverage note: the brief lists 20 modules. I probed 18: all of the above except
`arg`, `iterators`, `filestream` (substituted `allocators`, which is the dependency root
for `arg`/`vector`/`list`/`hashmap`/`stringbuilder` and is the more informative probe),
plus `table` (a `static_error`, FAIL(both) trivially). `arg` requires `sequence`+
`allocators.general`, `iterators` is exercised through every container test, and
`filestream` is exercised through `io_test`; all three are therefore covered transitively
by the modules in the table.

### 2.2 Findings table - 18 probed modules

| Module | Driver | Category | First divergence (ours) |
|---|---|---|---|
| math | `tests/math_test.nelua` | **FAIL(us)** | `lib/math.nelua:4:21: error: expected type after '@'` |
| string | `tests/string_test.nelua` | **FAIL(us)** | `:4:32: error: unexpected token` (`#[primtypes.isize.max]#`) |
| traits | `tests/traits_test.nelua` | **FAIL(us)** | `:4:10: error: unexpected keyword 'type'` (`type(1)`) |
| memory | `tests/memory_test.nelua` | **FAIL(us)** | `:7:14: error: expected type after '@'` |
| builtins | `tests/builtins_test.nelua` | **FAIL(us)** | `:17:17: error: expected type after '@'` |
| vector | `tests/vector_test.nelua` | **FAIL(us)** | `:4:21: error: unexpected keyword 'integer'` (`vector(integer)`) |
| coroutine | `tests/coroutine_test.nelua` | **FAIL(us)** | `:68:30: error: unexpected token` |
| io | `tests/io_test.nelua` | **FAIL(us)** | `:139:17: error: unexpected keyword 'string'` (`string.format`) |
| utf8 | `tests/utf8_test.nelua` | **FAIL(us)** | `:4:33: error: unexpected keyword 'string'` (`sequence(string)`) |
| hash | `tests/hash_test.nelua` | **FAIL(us)** | `:15:28: error: expected type after '@'` |
| stringbuilder | `tests/stringbuilder_test.nelua` | **FAIL(us)** | `:8:25: error: expected ')' after method arguments` (`'\n'_byte`) |
| allocators | `tests/allocators_test.nelua` | **FAIL(us)** | `:8:39: error: expected ')' after expression` (`ArenaAllocator(1024,8)`) |
| sequence | `tests/sequence_test.nelua` | **FAIL(both)** | oracle: `runtime error: assertion failed` at `:14` (oracle's own test is out of sync with build 1635) |
| span | `tests/span_test.nelua` | **FAIL(both)** | oracle: `no viable type conversion from 'pointer(int64)' to 'int64'` at `{ &arr[0], 4 }` |
| os | `tests/os_test.nelua` | **FAIL(both)** | oracle: `a return statement is missing before function end` at `:70` |
| hashmap | `tests/hashmap_test.nelua` | **FAIL(both)** | oracle: `hashmap.nelua:148` transitive analyze error |
| list | `tests/list_test.nelua` | **FAIL(both)** | oracle: `no viable type conversion from 'int64' to 'pointer(listnode(int64))'` at `:99` |
| table | `lib/table.nelua` | **FAIL(both)** | `static_error 'tables are not implement yet'` - tables are not implemented in 0.2.0-dev at all |

Net: **0 MATCH, 0 DIFF, 12 FAIL(us), 6 FAIL(both)**. Not one stdlib module compiles
and runs through us. The four `FAIL(both)` modules besides `table` are the oracle's *own*
tests failing on the oracle - i.e. the test files are out of sync with build 1635, so
even the oracle can't pass them; the bar there is "match the oracle on programs the
oracle accepts", not "make these specific tests pass".

### 2.3 The parse-level blocker taxonomy

Every `FAIL(us)` dies at **parse time**, on one of seven constructs the stdlib uses
pervasively. All seven are oracle-accepted / ours-rejected. File counts are over the
44 `.nelua` files in `lib/` (+ `lib/C`, `lib/detail`, `lib/allocators`).

| # | Construct | Oracle | Ours | Used by | Verbatim ours error |
|---|---|---|---|---|---|
| 1 | `@` type expression: `@record{}`, `@*int64`, `@uint32`, `@integer` | parses (`Type { RecordType {} }`) | **fails** | 33 files | `error: expected type after '@'` |
| 2 | `#[expr]#` preprocessor expression (`#[primtypes.isize.max]#`, `#[concept(...)]#`) | parses (`PreprocessExpr`) | **fails** | 24 files | `error: unexpected token` |
| 3 | `$ptr` dereference | works | **fails** | 5 files | `error: unexpected token` |
| 4 | `#@type` sizeof (`#@int64`) | works (`8`) | **fails** | 3 files | `error: unexpected token` |
| 5 | `&x` address-of | works | **fails** (only binary `&`) | 10 files | parser treats it as band |
| 6 | keyword as identifier: `type(1)`, `string.format(...)`, `vector(integer)`, `sequence(string)` | works | **fails** | many files | `error: unexpected keyword 'type'` / `'string'` / `'integer'` |
| 7 | parameterized type call in annotation: `ArenaAllocator(1024,8)`, `@vector(int64, *A)` | works | **fails** | allocator tests | `error: expected ')' after expression` |

**Blocker #1 is a one-line parser bug.** `src/parser.nim` `parsePrimary`, `of tkAt` case
(`src/parser.nim:325-329`):

```nim
of tkAt:
  let ty = p.parseType()          # BUG: p.tok is still the '@' -- never advanced
  if ty != nil:
    return newType(ty)
  raise ParseError(loc: t.loc, msg: "expected type after '@'")
```

`parseType` returns `nil` for `tkAt`, so *every* `@`-expression raises. Adding
`p.advance()` before `parseType()` fixes the whole class. This is the single cheapest
win in the table - it is **not** the biggest blocker, because it is trivial.

**Blockers #2-#7 are missing features, not bugs.** None has a parse case:
- `#[ ... ]#` has no `parsePrimary` case at all; `#` is the unary length operator
  (`src/parser.nim:408-410`). The AST node `nkPreprocessExpr` already exists
  (`src/parser.nim:1029`) and the preprocessor pass already consumes it
  (`src/preprocessor.nim:3-4`), so the *lowering* is partly built - the **parse** case
  is what's missing. `#[concept(...)]#` is how the stdlib defines type concepts
  (`lib/math.nelua:13-14`, `lib/hashmap.nelua:423`, `lib/sequence.nelua:298`,
  `lib/list.nelua:332`, `lib/span.nelua:110`, `lib/stringbuilder.nelua:442`,
  `lib/vector.nelua:252`). Without it, **none of the generic containers compile**,
  which is the majority of the stdlib.
- `$`, `#@`, `&`-address-of are genuinely absent operators (no `tkDollar`/`tkSizeof` in
  the lexer; `&` is only `tkBand` at `src/lexer.nim:328`). Needed for the memory/span/
  string/hashmap modules.
- Keywords-as-identifiers: `parsePrimary`'s `of tkKeyword` only accepts
  `true/false/nil/nilptr/function` (`src/parser.nim:330-347`); everything else
  (`type`, `string`, `integer`, `vector`, ...) raises `unexpected keyword`. The oracle
  treats these as ordinary identifiers once they are declared (e.g. `type` is a
  `global function` after `require "traits"`; `string` is the module namespace).
- Parameterized type calls (`Type(args)` in a type annotation) are not parsed in type
  position; `parseType` handles `record{}`/`union{}`/`enum{}`/`array()`/`pointer()`/
  `function()` but not `Identifier(args)`.

### 2.4 Semantic blockers (cross-reference Task 3)

Two non-parse blockers also gate the stdlib and are researched in §3:

1. **Untyped-function return deduction.** `lib/` functions such as `math`'s
   `choose_float_type` and many `#[generalize(...)]#`-generated bodies return values
   through untyped functions. Ours lowers the return to `void` and drops the value.
   See §3.1.
2. **Closure / upvalue declaration ordering.** The stdlib's `gc.nelua`, `hashmap.nelua`,
   `string.nelua` use top-level `local`s read by nested functions. Ours emits the static
   variable declaration *after* the function that references it, so the C compile fails
   with `'tmp_..._counter' undeclared (first use in this function)`. The oracle emits a
   DECLARATIONS section (all statics + forward function decls) before the DEFINITIONS
   section. See §3.2.

### 2.5 Note on `FAIL(both)`

`sequence`, `span`, `list`, `hashmap`, `os` tests fail on the **oracle** with real type
errors (e.g. `span_test.nelua:5:30: no viable type conversion from 'pointer(int64)' to
'int64'`). These are the oracle's own test files being out of sync with build 1635.
`table.nelua` is a `static_error` - tables are simply not implemented in 0.2.0-dev.
This is honest context, not a finding about us: the stdlib bar is "match the oracle on
programs the oracle accepts", and for these five modules the oracle does not accept its
own tests.

### 2.6 Verdict

**The stdlib bar - "all of `lib/` compiles and matches the oracle" - is NOT reachable
from here without a substantial, feature-sized chunk of work, and it is not reachable
by fixing bugs alone.**

The honest breakdown:

- **Reachable with ~1 line:** blocker #1 (`@` advance). This unblocks parsing of
  `@record{}`/`@*int64`/`@uint32` etc., which is what 33 files start with. It is a real
  bug and should be fixed regardless.
- **Reachable with a bounded preprocessor change:** blocker #2 (`#[expr]#`). The node
  kind and the lowering pass already exist; only the parse case is missing. This is the
  single highest-leverage missing piece - it gates *every* generic container
  (`sequence`, `span`, `vector`, `list`, `hashmap`, `stringbuilder`), which is most of
  the stdlib's surface.
- **Not reachable without new operators:** blockers #3-#5 (`$`, `#@`, `&`). These are
  genuinely absent from the lexer/parser. Adding three operators is a few days of work
  but is real new language surface, not a bug.
- **Not reachable without parser broadening:** blocker #6 (keywords as identifiers) and
  #7 (parameterized type calls). These change how `parsePrimary`/`parseType` accept
  tokens, with knock-on effects on the analyzer and codegen.
- **Not reachable without the semantic work of §3:** return deduction + upvalue
  declaration ordering.

**Single biggest blocker: the `#[expr]#` preprocessor-expression parse case.** Not
because it is the hardest (it is not - the node and the lowering already exist), but
because it is the one that gates the most files: 24 of 44 stdlib files use `#[ ... ]#`,
and without it the generic-container modules (`sequence`, `span`, `vector`, `list`,
`hashmap`, `stringbuilder`) cannot even be *required*, let alone matched. Fixing only
the `@` advance bug (blocker #1) would let `math`, `traits`, `hash`, `builtins`,
`memory` parse further - but then hit `#[concept(...)]#` inside `math` and stop.

**Honest recommendation:** do not chase "all of `lib/`" as a gate. It is the wrong
shape even for the oracle (its own tests fail on 5 modules). The reachable, meaningful
bar is: **each module that the oracle accepts on its own test also compiles+matches on
ours.** That is a per-module, oracle-verified bar, and it is what `regress.py`-style
require harnessing would measure. The work to reach it is the parse taxonomy above +
the two §3 designs.

---

## Task 3 - two pre-existing gaps

### 3.1 Gap 1 - untyped-function return deduction

#### 3.1.1 Oracle behavior (build 1635)

An untyped `local function f() ... end` (no `: T` return annotation) has its return
type **deduced from the return expressions in the body**. `traits.typeinfoof(f()).name`
is the faithful reporter (the `type()` builtin auto-widens integers to `number`, so do
not use it for this). Reproducing commands and verbatim output:

```
$ cat > t.nelua <<'EOF'
require "traits"
local function f() return 42 end
print(traits.typeinfoof(f()).name)
EOF
$ /usr/bin/nelua t.nelua
int64
```

| Return expression(s) | `traits.typeinfoof(f()).name` | Note |
|---|---|---|
| `return 42` | `int64` | literal stays `int64`, not widened to `number` |
| `return 3.14` | `float64` | |
| `return "x"` | `string` | |
| `return true` | `boolean` | |
| `return nil` | `niltype` | |
| `return end` (bare return) | `void` | `print(f())` → `error: in print: cannot handle type "void"` |
| (no return statement at all) | `void` | same `void` error |
| `return v1, v2, ...` (multiple) | **type of the first return value** | `return "a", 1` → `string`; `return 1, "a"` → `int64` |
| `return 1` in both branches of `if/else` | `int64` | unified across branches |
| `return 1` in one branch, `return "a"` in another | **compile error** | `traits.nelua:48:28: error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type` |

Rule in words: **collect every return expression reachable in the body (all control
branches); for a multi-value return take the first value's type; unify across all
collected types; if the unification yields `any` (incompatible types) it is a hard
error; if no return expression exists the type is `void`.** Integer literals keep their
`int64` type (they are *not* auto-widened during deduction).

#### 3.1.2 Ours

Ours does **not** deduce - it hardcodes `void`. `src/analyzer.nim:1062-1070`:

```nim
for r in returns:                      # `returns` = explicit `: T` annotations only
  let rt = analyzeTypeExpr(ctx, r, false)
  if rt != nil:
    ...
    ftype.returns.add rt
if ftype.returns.len == 0: ftype.returns.add BuiltinTypes["void"]   # untyped -> void
```

When `returns` is empty (the untyped case) the type is unconditionally `void`, and the
return value is dropped. The existing `deduceAutoReturns` proc
(`src/analyzer.nim:962-985`) only iterates over *already-present* `ftype.returns`, so
it only fires for an **explicit `: auto`** annotation - it never runs for the no-annotation
case. Verified behavior on ours:

```
$ cat > t.nelua <<'EOF'
local function f() return 42 end
print(f())
EOF
$ ./tmp/nelu t.nelua
nil                                  # ours: value dropped, returns nil
$ /usr/bin/nelua t.nelua
42                                   # oracle
```

And `local x: integer = f()` fails at C-compile because `f` is emitted as
`void tmp_..._f()` and `(int64_t)(f())` is invalid C.

#### 3.1.3 Design for Nelu

In `analyzeFuncDef` (`src/analyzer.nim:1037`), after `analyzeBlock(ctx, body)` and before
the existing `deduceAutoReturns` call, add a **return-type deduction pass** when the
function has no explicit return annotation (`ftype.returns.len == 0`):

1. Walk `body` collecting every `nkReturn` node (recurse into `if`/`elseif`/`else`,
   `while`, `repeat`, `for`, `do` blocks, but **not** into nested `nkFuncDef` - nested
   functions have their own return type). A helper `collectReturns(node)` is the natural
   generalization of the existing `findFirstReturn` at `src/analyzer.nim:950-960`.
2. For each collected return:
   - zero children → candidate `void` (bare `return`).
   - one child → candidate type = `ctx.attrOf[child].typ`.
   - two+ children → candidate type = `ctx.attrOf[children[0]].typ` (first value).
3. Unify the candidate set:
   - empty set (no return anywhere) → `void`.
   - all candidates identical → that type.
   - candidates unify to a common type → that type.
   - candidates are incompatible → emit `ctx.path & ": error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type"` (the oracle's exact message, already used at `src/analyzer.nim:1059`).
4. Assign the unified type to `ftype.returns[0]`. The existing `deduceAutoReturns` then
   leaves it alone (it only touches `tkAuto`).

This is a local, additive change inside `analyzeFuncDef`; it reuses the existing
`attrOf` type cache and the existing `any`-error string, so no new infrastructure is
needed. It must run **after** `analyzeBlock` (return-expression types are only known
then) and **before** the `funcTypeStrOf` rendering at `src/analyzer.nim:1116`.

**Flag:** the `any`-param path at `src/analyzer.nim:1056-1059` already emits the same
"compiler deduced type 'any'" message, so this is consistent with the existing diagnostic
style.

### 3.2 Gap 2 - closure / upvalue scoping

#### 3.2.1 Oracle behavior (build 1635) - *corrected*

> **Correction to `plan/oracle_probe/closures_oracle-behavior-design.md`.** That doc's
> "bottom line" - *"the C backend does not support closures at all. Any access to an
> outer local from inside a nested function is a hard compile error"* - is an
> over-generalization. Every probe in that suite (c03-c39) uses a **function-local**
> outer variable (declared inside `make()`), which *is* rejected. The doc never tested
> a **top-level (module-scope) `local`** read by a nested function. It is wrong about
> that case, and its conclusion ("a 0.2.0-parity implementation must implement full
> upvalue/closure semantics") is too strong. The correct rule is below.

The oracle's C backend supports upvalues to **module-scope** variables only, and lowers
them as ordinary file-scope `static` variables - no heap-allocated closure objects, no
upvalue structs. Reproducing:

```
$ cat > t.nelua <<'EOF'
local counter = 0
local function tick(): integer
  counter = counter + 1
  return counter
end
print(tick())
print(tick())
print(counter)
EOF
$ /usr/bin/nelua t.nelua
1
2
2
```

| Upvalue target | Oracle C | Verbatim error when rejected |
|---|---|---|
| top-level `local`, declared **before** the nested function - read | works (`5`) | |
| top-level `local`, declared before - **write/mutate** | works (`1`, `2`, `2`) | |
| top-level `local`, read by a function nested inside a function nested at top level | works (`7`) | |
| top-level `local`, declared **after** the nested function (forward reference) | **rejected** | `:2:29: error: undeclared symbol 'x'` |
| `global` variable - read or write | works (`9`; `1`, `2`) | |
| **function-local** variable | **rejected** | `:3:31: error: attempt to access upvalue 'x', but closures are not supported` |
| **function parameter** | **rejected** | `:5:12: error: attempt to access upvalue 'y', but closures are not supported` |
| closure **returned** so it outlives the enclosing call (function-local capture) | **rejected** | same `closures are not supported` message |
| implicit global (assign without `global`) | **rejected** | `:4:12: error: undeclared symbol 'G'` |

Rule in words: **an inner function may read/write any module-scope `local` or `global`
that is declared before it; the variable is shared by reference (the inner sees the
variable, not a snapshot); loop variables and function-locals and parameters are NOT
captured, and the analyzer rejects them with `attempt to access upvalue 'X', but
closures are not supported`.** There is no heap closure lifetime to manage, because the
only capturable storage is already file-scope and lives forever. The oracle's emitted C
puts every top-level static (with its initializer) plus forward function declarations in
a `/* DECLARATIONS */` section, then all function definitions in a `/* DEFINITIONS */`
section (`closure_read` oracle C: `static int64_t ..._counter = 0;` at line 82, before
`..._tick` at line 87).

#### 3.2.2 Ours

Ours has **two** distinct defects, neither of which is a missing closure object:

1. **Declaration ordering (the actual runtime blocker).** Ours emits the top-level
   static variable declaration *after* the function that references it. For `closure_read`
   the emitted C is:
   ```c
   void tmp_..._tick();                    /* line 92: forward decl of the FUNCTION is fine */
   void tmp_..._tick() {                  /* line 93 */
     tmp_..._counter = (tmp_..._counter + 1);   /* line 94: uses counter */
     return tmp_..._counter;
   }
   static int64_t tmp_..._counter;        /* line 96: declared AFTER use */
   ```
   C result: `error: 'tmp_..._counter' undeclared (first use in this function)`. The
   function forward-declaration machinery already works (ours emits
   `int64_t tmp_..._f();` before `int64_t tmp_..._f() {...}`); it is the **static
   variable** declarations that are emitted in source order instead of up front.
   For a read-only case (`nested_read_top`, `up_global`) ours *compiles* but prints
   `nil` - because the variable is zero-initialized at its (late) declaration site and
   the read happens before the initializer runs; same root cause.

2. **No function-local/parameter rejection.** Ours does not emit the oracle's
   `closures are not supported` error. It silently tries to lower `closure_return`
   and produces broken C (`static void ..._g` - the inner function is mis-typed
   `void` because *its* return is being dropped by the §3.1 gap - and
   `invalid use of void expression`). So ours fails noisily at C-compile where the
   oracle fails cleanly at analyze, with a worse message.

#### 3.2.3 Design for Nelu

Two changes, both localized to the C emitter and analyzer; no closure object, no
upvalue struct, no GC pressure - matching the oracle's model.

**(a) Analyzer - reject non-module-scope upvalues.** In the symbol-resolution path
(when an `nkId` inside a nested `nkFuncDef` resolves to a variable), check the symbol's
scope depth:
- if the symbol is a module-scope `local` or `global` → allow (it is file-scope static);
- if it is a function-local or a parameter of an *enclosing* function → emit
  `ctx.path & ": error: attempt to access upvalue '" & name & "', but closures are not supported"`,
  matching the oracle verbatim;
- a forward reference to a not-yet-declared module-scope `local` →
  `error: undeclared symbol 'X'` (already the default for unknowns).

This makes ours fail at analyze like the oracle, instead of miscompiling.

**(b) C emitter - two-section output.** In `src/cgen.nim`, split the translation unit
into a DECLARATIONS section and a DEFINITIONS section:

1. **DECLARATIONS section** (emitted first, after the runtime includes): every
   top-level static-storage variable, declared **with its initializer** exactly as the
   oracle does (`static int64_t ..._counter = 0;`), followed by forward declarations of
   every function (`static int64_t ..._tick(void);`).
2. **DEFINITIONS section** (emitted after): all function bodies, then the `nelua_main`
   body, then `int main`.

This is a reordering of what `cgen` already emits - no new constructs. It fixes the
`'counter' undeclared` C-compile error and the read-before-init `nil`, for both
top-level-`local` and `global` upvalues, and makes the read/mutate cases match the
oracle (`1\n2\n2`). Combined with (a), the returned-closure and parameter cases will
then error at analyze with the oracle's exact message instead of miscompiling.

**Verification target** (all currently oracle-`OK` / ours-`FAIL`):
- `closure_read` → `1\n2\n2`
- `nested_read_top` → `5`
- `up_global` → `9`; `up_mutate_global` → `1\n2`
- `closure_return`, `closure_mutate`, `up_param` → `attempt to access upvalue 'x'/'y', but closures are not supported`

**Flag:** this deliberately does **not** implement heap-allocated closures / returned
closures / per-iteration loop-variable capture - the oracle rejects all of those on the
C backend anyway, so matching the oracle means *not* implementing them. The Lua backend
in `plan/oracle_probe/closures_oracle-behavior-design.md` and
`generators_oracle-behavior-design.md` supports them, but our compiler has no Lua backend
(`src/compile.nim` always uses `genC`; `config.generator` is parsed by `cli.nim` but
never read), so that half is not a parity target.

---

## Existing plans that already cover parts (do not duplicate)

- `plan/oracle_probe/closures_oracle-behavior-design.md` - the closures/coro survey.
  **Partially wrong** (see §3.2.1 correction): its "C backend supports no closures at
  all" bottom line conflates function-local capture (rejected) with module-scope
  capture (supported). Its per-probe findings (c03-c39) are correct for the probes as
  written; only the generalization is over-broad. The `generators_oracle-behavior-design.md`
  half is N/A to us (no Lua backend).
- `plan/oracle_probe/generators_oracle-behavior-design.md` - coroutine/generator
  behavior. N/A to the C backend; relevant only if a Lua backend is ever added.
- `plan/DONE/pattern-matching-implementation-design.md` §8 - already documents both these
  gaps as pre-existing and unresolved; this doc is the follow-up research + design.
- `plan/exceptions-implementation-design.md`, `plan/M2_design.md`, `plan/M3_design.md` -
  unrelated.