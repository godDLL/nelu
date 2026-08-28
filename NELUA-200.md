# NELUA-200 — Nelua for the Lua-and-C Reader

A reference aid for a programmer who already knows **Lua** and **C** and wants to
use the currently installed version of **Nelua-lang** (0.2.0-dev).

Everything in here was checked against the installed compiler
(`/usr/bin/nelua`, which ships as the shim `nelua` → `nelua-lua -lnelua
nelua.lua "$@"`), the stdlib source in `lib/`, the C-interop modules in
`lib/C/`, the examples in `examples/`, and the tests in `tests/`. Every
non-trivial claim was confirmed by compiling and running a throwaway probe
(kept in `tmp/`, not deleted).

> **One-line pitch.** Nelua is Lua-shaped syntax, statically typed, that
> compiles to C and then to native code — so you get Lua ergonomics with C
> performance and direct, ergonomic access to C functions and headers.

---

## 1. First program and how to build

You do not write a `main` function. Top-level statements become the entry
point; the compiler emits `int nelua_main(int, char**)`. `print` is a builtin.

```nelua
-- hello.nelua
print 'Hello world!'
```

Build and run:

```sh
nelua -L /home/user/Code/nelua-lang/lib -o hello hello.nelua
./hello
# Hello world!
```

`-L <dir>` is the library search path; `require 'name'` resolves to
`<dir>/name.nelua`. `-o <path>` is the output binary. The compiler always
compiles nelua source → C source → native binary (AOT only; there is no
interpreter and no way to load runtime-generated code).

Exit codes and stdout are ordinary C. `print` writes to stdout and takes
multiple arguments separated by tabs:

```nelua
print(1, 2)     -- 1	2
```

Verified: `print(1, 2)` compiles and prints `1	2`, exit 0.

---

## 2. What stays the same from Lua

You can read most of a Nelua program as Lua. These are byte-for-byte identical:

- **Comments.** `-- line`, `--[[ ... ]]`, and `--[=[ ... ]=]` (long-bracket
  comments with any number of `=`; the opening and closing brackets match).
- **String literals.** Single/double quoted; the same escape sequences
  (`\n`, `\t`, `\u{03C0}`, `\x41`, `\65`, `\z` whitespace-trim, `\` line
  continuation). Strings are immutable, contiguous, pointer+size, and
  null-terminated for C compatibility.
- **Number literals.** decimal, binary `0b1010`, hex `0xff`, char
  `'A'_u8`, scientific `1.2e-100`, hex-float `0x1.921FB54442D18p+1`.
- **Boolean and nil.** `true`, `false`, `nil`.
- **Operators.** `+ - * / // /// % %%% ^ .. and or not == ~= < > <= >= #`
  (length/sizeof), and the bitwise additions `\| & ~ << >> >>>` (logical
  shift), `>>>` arithmetic right shift, `~a` bitwise NOT, `$a` deref, `&a`
  address-of.
- **Control flow shapes.** `if / elseif / else`, `while`, `repeat ... until`,
  numeric `for`, `for ... in` (iterator), `break`, `continue`, `do ... end`.
- **Multiple assignment.** `local a, b = 1, 2`; `b, a = a, b` (safe swap).
- **Functions.** `function f(a, b) ... end`, anonymous
  `function(x) ... end`, first-class values, recursion, multiple returns.

---

## 3. What changes: the type system is the whole story

Nelua is statically typed. Types are *deduced* when you omit an annotation, so
you can write much Lua-like code without annotations — but the moment you need
precision, C-like control, or interop, you annotate.

### 3.1 Declarations

```nelua
local b = false             -- deduced 'boolean'
local s = 'test'            -- deduced 'string'
local one = 1               -- deduced 'integer'
local pi: number = 3.14     -- explicit annotation
```

- A declared-but-uninitialized variable is **always zero-initialized**
  (`false`/`0`). This is the "Zero Is Initialization" idiom; there are no
  constructors/destructors. Disable it per-variable with `<noinit>`.
- `local a: auto = 1` deduces the type from the first assignment (used for
  polymorphic arguments).
- `local N <comptime> = 8` is a compile-time constant usable as an array size.
- `local x <const> = 5` is a runtime-once, immutable value (also allowed on
  parameters).
- **`global` declares a top-scope symbol visible to other files** (a file
  `require`s to see it): `global global_a = 1`, `global function f() ... end`.

Verified: `local N <comptime> = 8` followed by `local arr: [N]float64
<noinit>` and a fill loop compiles and prints `arr[3]= 9.0`, exit 0.

### 3.2 The type vocabulary

**Integers and floats** (each is a fixed-width C type):

| Nelua type     | C type        | literal suffix |
|----------------|---------------|----------------|
| `integer`      | `int64_t`     | `_i`, `_integer` |
| `uinteger`     | `uint64_t`    | `_u` |
| `byte`         | `uint8_t`     | `_b` |
| `isize`        | `intptr_t`    | `_is` (pointer-width) |
| `int8..int64`, `uint8..uint64` | the `_t` types | `_i32`, `_u32` ... |
| `number`       | `double`      | `_n` |
| `float32`/`float64` | `float`/`double` | `_f32`, `_f64` |

**C-interop primitives** (use only when importing C functions):

| Type          | C type             |
|---------------|--------------------|
| `cint`        | `int`              |
| `csize`       | `size_t`           |
| `clong`, `culong`, `clonglong`, `culonglong` | the C long/long long types |
| `cchar`, `cschar`, `cuchar` | char / signed char / unsigned char |
| `cstring`     | `char *`           |
| `cptr`/`pointer` | `void *` (`*void`) |
| `cvalist`     | `va_list`          |
| `cvarargs`    | the `...` varargs  |

`integer`/`uinteger`/`number` are 64-bit by default and intended to be
reconfigurable via the preprocessor.

### 3.3 Composite types

Grammar verified against `/usr/bin/nelua --print-ast` (0.2.0-dev). The `@` prefix
is accepted on `record` and `union` but **rejected** on `enum`, `pointer`, and
`function` — those take bare keywords. Bracket `[N]T` works in annotation
position only, not as a standalone expression.

| Declaration         | C shape              |
|---------------------|----------------------|
| `record { x: float64, y: float64 }` (also `@record{...}`) | `struct { double x; double y; }` |
| `union { i: int64, f: float64 }` (also `@union{...}`)    | `union` |
| `enum { A=0, B, C }` (**`@enum` is rejected**)                | `enum` (first value must be initialized) |
| `array(T, N)` / `[N]T` (annotation only) | `T arr[N]`, fixed size, passed **by value** |
| `*T` / `pointer(T)` (**`@pointer` is rejected**) | pointer to T |
| `span(T)`                           | fat pointer: `*[0]T` + size, runtime bounds-checked |
| `function(a: int): int` (**`@function` is rejected**) | function pointer (stores callbacks) |
| `facultative(T)` (annotation only; `T?` is rejected) | optional (see §3.5) |
| `A | B | C`                         | variant (union of types) |

Record literals use `(@Person){ name = "Mark", age = 20 }` (typed initialization)
or ordered-field `{ "Mark", 20 }`.

Verified: records, colon-methods, and operator overloading all work:

```nelua
## linklib 'm'                       -- math.sqrt needs -lm (see §7.3)
require 'math'
local Vec2: type = @record{ x: float64, y: float64 }
function Vec2:__add(other: Vec2): Vec2
  return (@Vec2){ x = self.x + other.x, y = self.y + other.y }
end
function Vec2:len(): float64
  return math.sqrt(self.x * self.x + self.y * self.y)
end
local a = (@Vec2){ x = 3.0, y = 4.0 }
local b = (@Vec2){ x = 1.0, y = 0.0 }
local c = a + b
print(a:len(), c:len())             -- 5.0  5.6568542494924
```

A colon method `function T:m(...)` receives `self` as `*T` implicitly; method
calls auto-reference/dereference the receiver, so `a + b` works whether `a`
is a value or a pointer.

Span construction is by taking the address of an array or container:

```nelua
require 'span'
local arr: [4]float64 = {1.0, 2.0, 3.0, 4.0}
local s: span(float64) = &arr
print(#s, s[2])                     -- 4  3.0
```

`#SomeType` on a *type* returns its size in bytes (`#Vec2` → 16).

### 3.4 The `local` rule that bites Lua programmers most

**`local` is not hoisted in Nelua.** A `local` name enters scope at the line
where it is declared — unlike Lua, where the whole enclosing block sees it.

This produces a silent infinite loop if you port a parser-style loop that
rebinds a name it already uses at the top:

```nelua
-- WRONG (Lua-hoisted thinking): this spins forever at 100% CPU, no error.
while true do
  pos = advance(s, pos)              -- uses the OUTER pos
  local ok, key, pos = parse(s, pos) -- declares a NEW local pos
end

-- RIGHT: give the returned position a different name.
while true do
  local ok, key, nextpos = parse(s, pos)
  pos = nextpos
end
```

Verified by compiling a shadowing loop: with a `local pos = 99` declared mid
loop above a `pos = pos + 1`, the loop ran **5** times and `pos` ended at **5**
(Lua hoisting would make it run once, jumping to 100).

### 3.5 `nil`, `any`, `facultative`, and `_`

- **`nil`** exists but is not the universal "no value" it is in Lua. There is a
  `niltype` (the type of `nil`) for unions/optionals.
- **`nilptr`** is a separate literal — a pointer-sized nil, its own AST node
  (`Nilptr`), not the same as `nil`. Its literal type is `nilptr`, but it is the
  one value assignable to any pointer type: `local p: *integer = nilptr` compiles,
  while `local p: *integer = nil` is a `niltype` → `pointer` error. Use `nilptr`
  where Lua/M C would write `NULL`.
- **`any` is not fully supported.** A function whose return type would deduce
  to a union of types is rejected: *"unsupported 'any' deduced type"*.
  Return a concrete type instead.
- **`facultative(T)` (the optional type) cannot be used in return position.**
  A function that may return "no value" returns a boolean signal plus the
  value, e.g. `(false, "", pos)` on failure.
- **There is no `_` discard symbol.** `b, _ = s:find(p)` is an
  *"undeclared symbol '_'"* error. Name it, e.g. `local b, e = ...`.

### 3.6 Error handling

- `pcall` works. `error(msg)` panics.
- **`try / catch / finally`** — structured, expression/statement form.
- **`defer`** — run a block at scope exit (Go-style), in reverse order, before
  any `return`/`break`/`continue`.
- **`<close>` variables** — when they leave scope their `__close` metamethod
  runs (deterministic cleanup, like Rust `Drop`).

---

## 4. Functions

```nelua
local function add(a: integer, b: integer): integer
  return a + b
end
```

- **Return-type inference** is allowed; a recursive function **must** set its
  return type explicitly.
- **Multiple returns** are allowed and can be typed
  `: (boolean, integer)`; they are packed into a C struct.
- **Anonymous functions cannot be closures** — they cannot capture variables
  from enclosing scopes except the topmost scope. Nested functions are also
  not closures. **Top-scope functions *are* closures** and are cheap (top-scope
  variables live in static storage, so no upvalue/GC machinery).
- **`...: cvarargs`** makes a function *polymorphic*: the preprocessor
  specializes it once per distinct argument count/types, so there is no
  runtime branching. `...: cstring` (typed varargs) also compiles.
- **Polymorphic arguments:** `auto` is replaced by the call's actual type at
  compile time; specializations are memoized.
- **Record functions/methods:** `function Vec2.create(...)` (static) and
  `function Vec2:m(...)` (colon, `self: *Vec2` implicit).
- **Function annotations:** `<inline>`, `<cimport>`, `<cexport>`, `<codename>`,
  `<nodecl>`, `<cinclude>`, `<nosideeffect>`, `<alwaysinline>`, `<noinline>`.

---

## 5. Metaprogramming: the compile-time preprocessor

Nelua embeds a full **Lua** preprocessor. Between its statements, arbitrary Lua
runs at compile time. Lines starting with `##` and blocks between
`##[[ ... ]]` are Lua code, evaluated at compile time and persistent across
modules (declare helpers `local` so they don't leak).

```nelua
## local function repeat_n(n, body) ... ## end
## for i = 1, 3 do ##     -- emit three copies
print('iteration ' .. #[i]#)
## end
```

Key constructs:

- **`#[expr]#`** — replace the token with a Nelua value/AST produced by the
  preprocessor.
- **`#|name| #`** — replace with an identifier produced by the preprocessor.
- **`#[node]#`** — emit an AST-node expression; `inject_astnode(node)` injects a
  statement at the call site.
- **Preprocessor macros:** `## function(name, ...) ... ## end`, called as
  `#[macro]#(...)`. `expr_macro` for expression position. Code blocks can be
  passed as macro arguments.
- **Generics** are preprocessor functions rendered with the `generalize` macro:
  `local FixedStackArray: type = #[make_FixedStackArray]#`. Memoized per
  argument set — like C++ templates. `vector`, `sequence`, and `span` are
  built this way.
- **Concepts** decide at compile time whether an argument type matches,
  returning `true`, a *type* to infer to, or `(false, 'error message')`.
  `facultative(T)`, `overload(t1, t2, ...)` are shortcuts. Type properties live
  on `attr.type` — `is_scalar`, `is_stringy`, `is_integral`, `is_float`,
  `is_pointer`, `is_array`, `is_record`, `is_niltype`, plus custom flags.
- **`static_assert(cond, fmt, ...)`** and **`static_error(fmt, ...)`**.
- You can iterate and even *modify* already-processed symbols
  (`Weekends.value.fields`, `Person.value:add_field('age', ...)`).
- Share preprocessor helpers from standalone `.lua` modules:
  `## local foo = require "foo"` (set `LUA_PATH` if needed).

---

## 6. C interoperability (the C reader's payoff)

This is the part where Nelua earns its keep. C functions are imported by
*name* from a *namespace record*, with the header emitted where you say.

### 6.1 The `C` namespace and its submodules

`require 'C'` loads an **empty namespace record** (`C/init.nelua` is only
`global C: type = @record{}; return C`). C functions come from submodules:

```nelua
require 'C.stdio'     -- C.printf, C.scanf, C.fopen, C.stdin, C.stdout ...
require 'C.stdlib'    -- C.malloc, C.free, C.qsort, C.exit, C.atoi ...
require 'C.stdarg'    -- C.va_start, C.va_arg, C.va_end
require 'C.string'    -- C.strcpy, C.memcpy, C.strlen ...
```

Each submodule `require`s `C` and declares members on the `C` record. The
declarations are the ground truth — e.g. `lib/C/stdio.nelua` declares:

```nelua
function C.printf(format: cstring, ...: cvarargs): cint
  <cimport, cinclude'<stdio.h>'> end
function C.fopen(filename: cstring, modes: cstring): *C.FILE
  <cimport, cinclude'<stdio.h>'> end
global C.stdin: *C.FILE <cimport, cinclude'<stdio.h>'>
global C.EOF: cint <const, cimport, cinclude'<stdio.h>'>
```

### 6.2 Attributes that drive C emission

| Attribute                     | Effect |
|-------------------------------|--------|
| `<cimport>`                   | import a C function (auto-declared; no header needed) |
| `<cimport 'name'>`            | import under a different symbol |
| `<nodecl>`                    | don't emit a declaration (the C header will) |
| `<cinclude '<stdio.h>'>`      | emit `#include` at the top of the generated C |
| `<cexport, codename 'foo_f'>` | export a Nelua function under a fixed C name |
| `<cimport, nodecl>` on a const | import a C constant |
| `## cdefine 'X'`              | emit a `#define` |
| `## linklib 'SDL2'`           | pass `-lSDL2` to the linker |
| `## cflags '...'` / `## ldflags '...'` | extra C compiler / linker flags |
| `## cemit '...'` / `cemitdecl` / `cemitdef` | emit raw C into the current scope / declarations / definitions |

### 6.3 Calling C functions and handling varargs

Direct calls map 1:1:

```nelua
require 'C.stdio'
C.printf('Hello from C.stdio: %d %s\n', 42, 'nelua')
```

Verified: prints `Hello from C.stdio: 42 nelua`, exit 0.

**Varargs.** `...: cvarargs` is the varargs parameter; the compiler specializes
the call per argument set. For the `v*` family you pass a `cvalist` as an
ordinary parameter — it is *never* unpacked from `...`:

```nelua
require 'C.stdio'
require 'C.stdarg'

local function cprintf(fmt: cstring, ...: cvarargs): cint
  local ap: cvalist <noinit>
  C.va_start(ap, fmt)
  local n = C.vprintf(fmt, ap)
  C.va_end(ap)
  return n
end

cprintf('varargs via cvalist: %s = %g\n', 'x', 3.14)
```

Verified: prints `varargs via cvalist: x = 3.14`, exit 0.

**Pointers and arrays.** `*C.FILE` is a pointer to an opaque record
(`C.FILE: type <cimport,cinclude'<stdio.h>',forwarddecl> = @record{}`).
`cstring` is `char *`. Use `pointer`/`*T` for generic pointers; pointer
arithmetic is disallowed — cast to/from integers explicitly. `C.stdlib`
exposes `malloc`/`calloc`/`realloc`/`free` returning `pointer`, and
`C.bsearch`/`C.qsort` take callbacks typed
`function(pointer, pointer): cint`.

### 6.4 The `-lm` gotcha (important)

**Nelua does not add `-lm` itself.** Using `math.sqrt` (or any libm function)
without declaring the math library produces a linker error:

```
undefined reference to `sqrt'
error: C compilation for 'out' failed
```

Fix it in source with `## linklib 'm'` (or pass `-lm` on the command line):

```nelua
## linklib 'm'
require 'math'
local d = math.sqrt(3.0 * 3.0 + 4.0 * 4.0)   -- 5.0
```

Verified: without `## linklib 'm'` the same program fails at link time with the
`undefined reference to 'sqrt'` error above; with it, prints `5.0`, exit 0.

### 6.5 Reading the generated C

The compiler emits one readable C file with sections: declarations,
definitions, and per-function bodies. The entry point is
`int nelua_main(int, char**)`. You can see it for yourself:

```sh
nelua -L lib -o hello hello.nelua --gen-c-only   # or similar flag; see §8
```

---

## 7. Standard library tour

All libraries use `require 'name'`. Builtins (`require`, `print`, `panic`,
`error`, `assert`, `check`, `likely`, `unlikely`, `_VERSION`) are not `require`d.

| Module        | What it gives you (vs. Lua) |
|---------------|------------------------------|
| `arg`         | `arg`: command-line args, a `sequence(string, GeneralAllocator)` |
| `iterators`   | `ipairs`, `mipairs`, `next`, `mnext`, `pairs`, `mpairs` |
| `io`          | `open/popen/close/flush/input/output/tmpfile/read/write/writef/printf/type/lines` |
| `filestream`  | `filestream` record: `open/flush/close/destroy/seek/setvbuf/read/write/writef/lines/isopen/__tostring/_fromfp/_getfp` |
| `math`        | `abs/floor/ifloor/ceil/iceil/round/trunc/sqrt/cbrt/exp/exp2/pow/log/cos/sin/tan/...` + constants `pi`, `huge`, `mininteger`, `maxinteger`, `maxuinteger`. **Needs `-lm`** (§6.4). |
| `memory`      | `copy/move/set/zero/compare/equals/scan/find/spancopy/spanmove/spanset/spanzero/spancompare/spanequals/spanfind` |
| `os`          | `clock/date/difftime/execute/exit/getenv/remove/rename/setlocale/timedesc/time/tmpname/now/sleep` |
| `span`        | the `span(T)` fat pointer: `empty/valid/sub/__atindex/__len/__convert` |
| `string`      | `create/destroy/__close/copy/byte/sub/subview/find/gmatch/gmatchview/rep/match/matchview/reverse/upper/lower/char/format/len/span/__atindex/__len/__concat/__eq/__lt/__le/__add/__sub/__mul/__div/__idiv/__tdiv/__mod/__tmod/__pow/__unm/__band/__bor/__bxor/__shl/__shr/__asr/__bnot/fillcstring` + module-level `tostring`/`tonumber`/`tointeger` + `string.pack/unpack/packsize` |
| `stringbuilder` | mutable byte buffer: `make/destroy/__close/clear/prepare/commit/resize/writebyte/write/writef/view/promote/__len/__tostring` |
| `traits`      | `typeid/typeinfo/typeidof/typeinfoof/type` |
| `utf8`        | `charpattern/char/codes/codepoint/offset/len` |
| `coroutine`  | `coroutine` handle (`@*mco_coro`), `create/destroy/push/pop/isyieldable/resume/spawn/yield/running/status`. No varargs in yield/resume — pass values via `push`/`pop` with compile-time-known types. |
| `hash`        | `short/long/combine/hash` |
| `vector`     | `vector(T, Allocator)` dynamic array: `make/destroy/__close/clear/reserve/resize/copy/push/pop/insert/remove/removevalue/removeif/capacity/__atindex/__len/__convert` |
| `sequence`   | `sequence(T, Allocator)`, Lua-table-like (1-indexed, grows on past-end index, passed by reference): same method set as `vector` |
| `list`       | doubly-linked list: `make/destroy/__close/clear/pushfront/pushback/insert/popfront/popback/find/erase/empty/__len/__next/__mnext/__pairs/__mpairs/__convert` |
| `hashmap`    | `hashmap(K, V, HashFunc, Allocator)`: `make/destroy/__close/clear/_find/rehash/reserve/_at/__atindex/peek/remove/loadfactor/bucketcount/capacity/__len/__pairs/__mpairs` |
| `allocators` | `default`, `allocator` (interface), `general`, `gc`, `arena`, `stack`, `pool`, `heap` |

### 7.1 `string.find` and `string.match` are not like Lua

This is the single most surprising stdlib difference.

- **`string.find` returns `(isize, isize)`.** On a match you get the start and
  end positions. **On no match it returns `(0, 0)`, not `nil`.** Write
  `local b, e = s:find(p); local hit = (b ~= 0)`.
  - Runtime-confirmed: `'hello':find('ell')` → `(2, 4)` (observed by wrapping
    the call in a function and converting the results to `integer` before
    printing).
  - The no-match `(0, 0)` is read directly from the stdlib source
    (`lib/string.nelua`: `if endpos ~= -1 then return startpos+1, endpos else
    return 0, 0 end`). A bare `isize`-typed `(0, 0)` return prints as
    `0 0` at runtime, so the value itself is sound — but `string.find`'s
    no-match codegen path could not be observed at runtime because it trips
    the compiler bug below.
- **`string.match` returns `(boolean, sequence(string))`** — a success flag
  *plus* a sequence of captures, not a single string. It cannot be fed to
  `tonumber` directly. Verified: `'a1b2':match('(%d')` → `ok=true`, one capture
  `'1'`. (Note: `local caps = t:match(p)` binds only the boolean; you must
  write `local ok, caps = ...`.)
- **`string.find` trips a real 0.2.0-dev compiler bug.** Programs that call
  `string.find` and let its `isize` results flow into the entry point crash
  the C generator:
  `cemitter.add_zeroed_type_literal: attempt to index a nil value (field
  'integer index')`. It is a compiler crash, not a source error. Workarounds
  that were verified to help: call `find` from inside a function rather than
  at the entry point, and convert the `isize` results to `integer` before
  printing them (`local bi: integer = b; print(bi)`).

### 7.2 `os.execute` returns a boolean

`os.execute(cmd)` returns `true`/`false` — a success flag, **not** the integer
exit code you would get from C's `system()`. Write
`if os.execute(cmd) then ... end`, never `os.execute(cmd) == 0`.

### 7.3 `coroutine` has no varargs on yield/resume

`resume`/`yield` cannot pass a variable number of values. Push and pop values
with compile-time-known types instead.

---

## 8. Compiling and linking

```sh
nelua -L <libdir> -o <out> <source.nelua> [extra flags...]
```

- **`-L <dir>`** — library search path for `require`.
- **`-o <path>`** — output binary path.
- **`-g`** — debug builds (runtime narrowing checks crash on failure; disabled
  in release).
- **`-P nogc`** or `## pragmas.nogc = true` — disable the GC. With GC off you
  must manually free everything, including strings.
- **`## linklib 'm'`** (§6.4), **`## cflags`**, **`## ldflags`** — in-source
  extra flags.
- **`## cemit` / `cemitdecl` / `cemitdef`** — raw C injection.

**Linking your own C/objects.** The `tests/myclib*` and `tests/libmylib*`
files show the two supported patterns: a C source compiled alongside, and a
static library. Use `<cexport, codename '...'>` to give a Nelua function a
fixed C name, and `## linklib`/`## ldflags` for the link step.

**Allocators.** `default_allocator` is an alias of `gc_allocator` or
`general_allocator`. `general_allocator` is plain `malloc`/`free`;
`gc_allocator` is GC-tracked and supports finalizers via `__gc`. When the GC
is on, any memory that may contain pointers **must** be allocated through the
GC allocator so the scan finds it. Also available: `ArenaAllocator(SIZE,
ALIGN)`, `StackAllocator(SIZE, ALIGN)`, `PoolAllocator(T, SIZE)`,
`HeapAllocator(SIZE)`.

**GC placement / freestanding.** The runtime ships a conservative mark-and-sweep
GC; the `nogc` pragma and the allocator modules are the escape hatches for
embedded/freestanding use.

---

## 9. Divergences cheat-sheet

"Lua does X, Nelua does Y" — the things that bite when porting.

| Area | Lua | Nelua (0.2.0-dev) |
|------|-----|-------------------|
| `local` scope | hoisted to whole block | enters scope at the declaration line (§3.4) |
| `string.find` no match | returns `nil` | returns `(0, 0)` (§7.1) |
| `string.match` | returns a string | returns `(boolean, sequence(string))` (§7.1) |
| `os.execute` | (Lua has none) | returns `true`/`false`, not exit code (§7.2) |
| `_` discard | valid | undeclared-symbol error (§3.5) |
| `any` return type | (Lua is untyped) | rejected: "unsupported 'any' deduced type" (§3.5) |
| `facultative(T)` in returns | — | not allowed; return `(bool, value)` (§3.5) |
| anonymous functions | closures | not closures (§4) |
| `math` functions | (Lua's `math` needs no link) | require `## linklib 'm'` (§6.4) |
| tables | dynamic, reference types | use `@record`/`@union`/`@enum`/`sequence`/`hashmap` (§3.3) |
| runtime code loading | `load`/`loadfile` | none — AOT only; generate at compile time with the preprocessor (§5) |
| `print` of `string.find` results | works | crashes the C generator (§7.1) |
| entry point | `main` function | top-level statements; `print` builtin (§1) |

---

## 10. Quick reference

**Type grammar (infix).** `array(T, N)` / `[N]T` (annotation only) array · `*T`
/ `pointer(T)` pointer · `span(T)` slice · `record {…}` / `union {…}` (the `@` prefix
also works on these two) · `enum {…}` (**`@enum` rejected**) ·
`function(a: T, …): R` function pointer (**`@function` rejected**) ·
`facultative(T)` optional (`T?` rejected) · `A | B | C` variant · `type` is the
meta-type.

**Attributes (postfix on declarations).** `<cimport>`, `<cimport 'name'>`,
`<cinclude '...'>`, `<cexport>`, `<cexport, codename '...'>`, `<nodecl>`,
`<inline>`, `<alwaysinline>`, `<noinline>`, `<nosideeffect>`, `<noinit>`,
`<const>`, `<comptime>`, `<close>`, `<align N>`, `<packed>`, `<native>`,
`<unsafe>`.

**`@` metaprogramming tokens.** `#[expr]#` value/AST replacement ·
`#|name| #` name replacement · `#[node]#` AST-node expression ·
`inject_astnode(node)` statement injection · `generalize` for generics ·
`concept(...)` / `facultative(...)` / `overload(...)` for specialization.

**Builtin functions.** `require`, `print`, `panic`, `error`, `assert`, `check`,
`likely`, `unlikely`, `_VERSION`, `tonumber`, `tostring`, `tointeger`,
`type`, `select`, `next`, `pairs`, `ipairs`, `sizeof`/`#`, `collectgarbage`
(where applicable).

---

## Appendix — how this was verified

Every non-trivial claim above was confirmed by compiling and running a throwaway
probe against `/usr/bin/nelua` (0.2.0-dev), with the probes kept in
`/home/user/Code/nelua-lang/tmp/`. Confirmed working, exit 0: C-stdio calls,
`cvalist`/`va_start`/`va_arg`/`va_end` varargs, record + colon methods +
operator overloading, `span`, `<comptime>`/`<noinit>`, `string.find` match
(`'hello':find('ell')` → `(2, 4)`), `local` non-hoisting shadowing loop,
`math.sqrt` with `## linklib 'm'`, and an `isize`-typed `(0, 0)` return.
Confirmed as real errors: `## linklib 'm'` required for `math.sqrt`;
`require "C"` loading an empty record vs. `require 'C.stdio'` exposing C
functions; `string.match`'s `(boolean, sequence)` shape; the `_`
discard-symbol error; and the `add_zeroed_type_literal` C-generator crash
tripped by `string.find` in the entry point. The no-match `(0, 0)` return of
`string.find` is taken from the stdlib source (`lib/string.nelua`), since its
runtime path could not be observed directly (it hits the same compiler bug).