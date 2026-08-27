# Nelua Language Review

> A clean-room specification and architectural review of the **Nelua** systems
> programming language, derived from the project website
> ([nelua.io](https://nelua.io/)), the README, the language specification files,
> and the compiler's own source tree. The goal is to serve as a complete,
> self-contained reference for a **reimplementation in Nim** that still targets C
> and compiles through a C compiler to native code.

- **Language:** Nelua ("Native Extensible Lua")
- **Original author:** edubart (Rafael Barreto)
- **License:** MIT (compiler, stdlib, and dependencies); programs written in
  Nelua may use any license
- **Status:** alpha (0.2.0-dev at time of review); syntax is mostly stable, but
  dynamic features (tables, runtime dynamic typing, exceptions, closures) are
  *not yet implemented*
- **Influences:** Lua, C, and "better C" languages — Nim, Odin, Zig
- **Output model:** Nelua source → C source → native binary (via GCC/Clang/TCC)

---

## 1. Project summary

Nelua is a minimal, efficient, statically-typed, meta-programmable **systems
programming language** heavily inspired by Lua, which compiles to C and then to
native code. It is designed for performance-sensitive applications where plain
Lua would not be efficient — operating systems, real-time systems, game engines,
libraries — while keeping a syntax and feel close to Lua.

The key idea is a **dual mode** language:

- Use **C-style** constructs (type notations, records, arrays, pointers, manual
  memory management) and get near-C performance with the compiler baking
  efficient, specific code for concrete types.
- Use **Lua-style** constructs (tables, metatables, untyped variables, dynamic
  features) and the compiler bakes a runtime library for that dynamic behavior,
  incurring some runtime overhead.

Nelua can do **compile-time metaprogramming through a full Lua preprocessor**.
Since the compiler itself is written in Lua, user preprocessor code can interact
at any point with the compiler's internals and the source's AST. This is what
makes possible classes, generics, and polymorphism *without* adding them to the
core specification — they are implemented as preprocessor libraries.

### 1.1 Why compile to C (and not LLVM)?

- C is still one of the most efficient languages → Nelua can be as efficient as C.
- Any C compiler can be used; Nelua reaches every platform C99 compilers reach,
  including the web via Emscripten.
- The generated C is **human-readable** and can be reused (extracted into a C
  library, bound from other languages, or continued by hand).
- Existing C code and libraries can be leveraged with no cost.
- Great C tooling (debuggers, profilers, static analyzers) applies for free.
- It keeps the Nelua compiler simpler.

### 1.2 Why not LLVM?

- LLVM is a huge dependency; goes against "simple to compile and use".
- Locking to LLVM removes the option of compilers that perform better in some
  situations (e.g. GCC), and is slow to compile huge projects (TCC can compile
  huge projects in milliseconds where LLVM takes minutes).
- LLVM output is not readable; C output gives users a low-level understanding.

### 1.3 Why a garbage collector?

Nelua tries to replicate Lua features and semantics, some of which require a
GC. But it also has manual memory-management constructs, and the GC can be
*completely disabled*. The author's philosophy: GC is good for rapid prototyping
and newcomers; manual memory management is enabled later for performance.

### 1.4 Scope / limitations (alpha)

Not yet implemented: exceptions, tables, runtime dynamic typing, closures
(except top-scope closures), and the `any` type is only partially supported.
There is **no interpreter or JIT** — pure ahead-of-time compilation. Code
generated at runtime cannot be loaded.

---

## 2. Design goals

From the project README:

- Be minimal with a small syntax, manual, and API — but powerful.
- Be efficient by compiling to optimized C, then native code.
- Have syntax, semantics, and features similar to Lua.
- Optionally statically typed with type checking.
- Achieve classes, generics, polymorphism, and other higher constructs by
  metaprogramming.
- Have an optional garbage collector.
- Make possible to create clean DSLs by extending the language grammar.
- Make programming safe for non-experts via run/compile-time checks and by
  avoiding undefined behavior.
- Possibility to emit low-level code (C, assembly).
- Be modular; make users capable of creating compiler plugins to extend it.
- Generate readable, simple, and efficient C code.
- Possibility to output freestanding code (dependency-free; for kernel dev or
  minimal runtimes).
- No single memory-management model; choose GC or manual per use case.

### "Why?" (the author's motivations)

- Love scripting in Lua; love C performance; want best of both in one language
  with unified syntax.
- Reuse or mix existing C/C++/Lua code.
- Want type safety and optimizations.
- Want efficient code while keeping readability and safety.
- Want the language features and manual to be minimal.
- Want to deploy anywhere C runs.
- Want to extend language features by metaprogramming or modding the compiler.
- Want to code with or without GC depending on use case.
- Want to abuse static dispatch over dynamic dispatch for performance and
  correctness.

---

## 3. Language overview (syntax & semantics for Lua users)

Most of Nelua's syntax and semantics are similar to Lua. The differences are
additions — chiefly **type notations** — to make code more efficient and to
enable metaprogramming.

There is no interpreter/VM: all code is compiled directly to native machine
code, so Nelua **cannot load code generated at runtime**. The user is
encouraged to generate code at compile-time with the preprocessor.

Not all Lua features are implemented. Most dynamic parts (tables, runtime
dynamic typing) are not implemented yet. At the moment, you must use **records**
instead of tables and use **type notations**.

### 3.1 Hello world

```lua
print 'Hello world!'
```

### 3.2 Comments

Identical to Lua:

```nelua
-- one line comment

--[[
  multi-line comment
]]

--[=[
  multi-line comment. `=` can be placed multiple times in case you have
  `[[` `]]` tokens inside the comment; it will always match its corresponding
  token.
]=]
```

### 3.3 Variables

Declared like Lua, with an *optional* type annotation:

```nelua
local b = false          -- deduced type 'boolean'
local s = 'test'         -- deduced type 'string'
local one = 1            -- deduced type 'integer'
local pi: number = 3.14  -- explicit type 'number'
```

The compiler uses types for compile-time and runtime checks and to generate
efficient code specialized to the concrete type.

**Type deduction:** a variable with no declared type has its type deduced and
resolved at compile-time (the compiler does its best; in corner cases you
should set a type explicitly). If different types are assigned to the same
variable, the compiler deduces `any` — but `any` is not fully implemented yet,
so that is a compile error.

**Zero initialization:** a declared-but-undefined variable is always initialized
to zero (`false` for booleans, `0` for integers). Nelua encourages the
**Zero Is Initialization (ZII)** idiom; it has no constructors/destructors
(RAII) in favor of this. Zero-init can be *optionally disabled* with the
`<noinit>` annotation.

**`auto` variables:** `local a: auto = 1` deduces the type early from the first
assignment. Mainly used for polymorphic-function arguments.

**`<comptime>` variables:** values known at compile-time, e.g.
`local a <comptime> = 1 + 2`. The compiler exploits these for efficient code
and uses them as compile-time parameters in polymorphic functions.

**`<const>` variables:** assigned once at runtime but cannot mutate. Also usable
on function arguments. Mostly aesthetic (does not affect efficiency).

**Multiple assignment:** `local a, b = 1, 2` and `b, a = a, b` (safe swap using
temporary variables).

### 3.4 Symbols

- **Local symbols** are visible in the current and inner scopes.
- **Global symbols** are visible in other source files and can *only* be
  declared in the top scope with the explicit `global` keyword:
  `global global_a = 1`, `global function global_f() ... end`. Require the file
  to access them.

### 3.5 Control flow

Lua-like `if`/`elseif`/`else`, `while`, `repeat ... until`, numeric `for`,
`for ... in` (iterator), `break`, `continue`. Additions for low-level
programming:

- **`switch` / `case`** — C-like, but no `break` needed (added automatically).
  Case expressions must be **integral** and **compile-time known**.
- **`defer`** — execute a block on scope termination (Go-inspired), guaranteed
  to run in reverse order before any `return`/`break`/`continue`.
- **`goto` / `Label`** (`::label::`).
- **`(do ... end)` expression** — a statement block that yields a value; used
  internally by the compiler and useful as a verbose ternary / for
  metaprogramming.

Numeric `for` is inclusive of both endpoints; the begin/end/step expressions
are evaluated **once**; the iterate variable type is deduced from begin/end.
An **exclusive for** (`for i=0,<5 do`) and a **stepped for**
(`for i=5,0,-1 do`) are supported.

### 3.6 Primitive types

| Nelua type    | C type                | Literal suffixes            |
|---------------|-----------------------|-----------------------------|
| `integer`     | `int64_t`             | `_i`, `_integer`            |
| `uinteger`    | `uint64_t`            | `_u`, `_uinteger`           |
| `number`      | `double`              | `_n`, `_number`             |
| `byte`        | `uint8_t`             | `_b`, `_byte`               |
| `isize`       | `intptr_t`            | `_is`, `_isize`             |
| `int8`        | `int8_t`              | `_i8`, `_int8`              |
| `int16`       | `int16_t`             | `_i16`, `_int16`            |
| `int32`       | `int32_t`             | `_i32`, `_int32`           |
| `int64`       | `int64_t`             | `_i64`, `_int64`            |
| `int128`*     | `__int128`            | `_i128`, `_int128`          |
| `usize`       | `uintptr_t`           | `_us`, `_usize`             |
| `uint8`       | `uint8_t`             | `_u8`, `_uint8`            |
| `uint16`      | `uint16_t`            | `_u16`, `_uint16`           |
| `uint32`      | `uint32_t`            | `_u32`, `_uint32`          |
| `uint64`      | `uint64_t`            | `_u64`, `_uint64`           |
| `uint128`*    | `unsigned __int128`   | `_u128`, `_uint128`         |
| `float32`     | `float`               | `_f32`, `_float32`          |
| `float64`     | `double`              | `_f64`, `_float64`          |
| `float128`*   | `__float128`          | `_f128`, `_float128`        |

`*` = only supported by some C compilers and architectures.

`isize`/`usize` are pointer-width (32-bit on 32-bit systems, 64-bit on 64-bit).
`integer`, `uinteger`, and `number` are *intended to be configurable* — by
default 64-bit everywhere, but customizable at compile-time via the preprocessor.

**C-interoperability primitive types** (use only for importing C functions):

| Type           | C type             | Suffix       |
|----------------|--------------------|--------------|
| `cshort`       | `short`            | `_cshort`    |
| `cint`         | `int`              | `_cint`      |
| `clong`        | `long`             | `_clong`     |
| `clonglong`    | `long long`        | `_clonglong` |
| `cptrdiff`     | `ptrdiff_t`        | `_cptrdiff`  |
| `cchar`        | `char`             | `_cchar`     |
| `cschar`       | `signed char`      | `_cschar`    |
| `cuchar`       | `unsigned char`    | `_cuchar`    |
| `cushort`      | `unsigned short`   | `_cushort`   |
| `cuint`        | `unsigned int`     | `_cuint`     |
| `culong`       | `unsigned long`    | `_culong`    |
| `culonglong`   | `unsigned long long`| `_culonglong`|
| `csize`        | `size_t`           | `_csize`     |
| `clongdouble`  | `long double`      | `_clongdouble`|
| `cstring`      | `char*`            | `_cstring`   |

Numeric literals: decimal, binary (`0b1010` → `uint8`), hex (`0xff` →
`integer`), char (`'A'_u8` → `uint8`), scientific (`1.2e-100`), and
hex-float (`0x1.921FB54442D18p+1`). Integer literals default to `integer`;
fractional literals default to `number`. Suffixes force a type.

**String:** immutable, contiguous, pointer + size, null-terminated buffer for C
compatibility. Lua escape sequences (`\n`, `\t`, `\u{03C0}`, `\x41`, `\65`,
`\z` whitespace-trim, `\` line continuation). Mutable strings use the
`stringbuilder` module.

**Boolean:** `bool` in generated C. `true`/`false`.

**`niltype`:** the type of `nil`; useful with unions (optional types) and for
detecting `nil` args in polymorphic functions.

**`void`:** used internally for the generic pointer (`*void` ≡ `pointer`); also
marks a function with no return.

**`type` type:** the type of a symbol that refers to a type (compile-time only),
e.g. `local MyInt: type = @integer`. The `@` token precedes a type expression in
the middle of statements. `#SomeType` returns the size of a type in bytes.

### 3.7 Composite types

- **Array:** `[N]T` — fixed, compile-time size. Passed **by value** to functions
  (copies). `[0]T` is an *unbounded array* (unknown size), useful only with
  pointers for indexing. `[]T` sugar infers size from initializer. Multidimensional
  arrays supported. Unbounded arrays are unsafe (no bounds checking).
- **Enum:** `@enum{ Sunday=0, Monday, ... }`. First value must be initialized
  explicitly. Defines a type usable as an annotation.
- **Record:** `@record{ name: string, age: integer }` → C struct. Supports typed
  initialization (`{name="Mark", age=20}`), casting initialization
  `(@Person){...}`, ordered-field initialization, and late (zero-init) assignment.
- **Union:** `@union{ i: int64, f: float64 }` → C union. The user tracks the
  active variant.
- **Pointer:** `*integer`, `pointer` (generic, `*void`), `nilptr`. Raw C pointers.
  **Pointer arithmetic is disallowed** — cast to/from integers explicitly.
- **Function type:** `function(x: integer, y: integer): integer` — a pointer to
  a function, convertible to/from generic pointers with explicit casts. Used to
  store callbacks.
- **Span:** `span(integer)` — "fat pointer"/slice: `*[0]T` + size. Runtime
  bounds checking (disableable in release). Safer than raw pointers.
- **Variant type:** `variant(...)` — a union of types (details in sources).
- **Optional type:** `T?`.

### 3.8 Implicit / explicit conversion

- **Implicit:** any scalar can convert to any other scalar, with **runtime
  checks** for loss of precision (crash on narrow-casting failure in debug;
  disableable in release).
- **Explicit:** `(@type)(var)` — skips runtime checks. If a type is aliased to
  a symbol, you can call the symbol: `MyNumber(i)`.

### 3.9 Operators

All Lua operators, plus low-level (C-semantics) additions:

| Name | Syntax | Operation |
|------|--------|-----------|
| or | `a or b` | conditional or |
| and | `a and b` | conditional and |
| lt/gt/le/ge | `<` `>` `<=` `>=` | comparisons |
| ne/eq | `~=` `==` | (in)equality |
| bor/band/bxor | `\|` `&` `~` | bitwise |
| shl/shr/asr | `<<` `>>` `>>>` | logical L/R shift, arithmetic R shift |
| bnot | `~a` | bitwise NOT |
| concat | `a .. b` | concatenation |
| add/sub/mul/div | `+` `-` `*` `/` | arithmetic |
| idiv/tdiv | `//` `///` | floor / truncate division |
| mod/tmod | `%` `%%%` | floor / truncate remainder |
| pow | `a ^ b` | exponentiation (promotes to float) |
| unm/not | `-a` `not a` | negation / boolean NOT |
| len | `#a` | length / sizeof type |
| deref/ref | `$a` `&a` | pointer deref / address-of |

Semantics: `/` and `^` promote to float; `//`/`%` round towards minus infinity;
`<<`/`>>` allow negative/large shifts; `and`/`or`/`not`/`==`/`~=` work on any
type; integer overflows wrap. `///`/`%%%` round towards zero (C semantics);
`>>>` is arithmetic right shift; `$`/`&` are C deref/address-of.

Record **metamethods** (Lua-like) let you define behavior for operators on a
record type: `__lt __le __eq __bor __band __bxor __shl __shr __asr __bnot
__concat __add __sub __mul __div __idiv __tdiv __mod __tmod __pow __unm __len
__index __atindex __tostring __convert __gc __close __next __mnext __pairs
__mpairs`.

---

## 4. Functions

```nelua
local function add(a: integer, b: integer): integer
  return a + b
end
```

- **Return-type inference:** the return type can be deduced when not specified.
- **Recursive calls:** a function that calls itself *must* explicitly set its
  return type.
- **Multiple returns:** as in Lua; can be explicitly typed
  `: (boolean, integer)`. Multiple returns are packed into a C struct.
- **Anonymous functions:** `function(x: integer): integer ... end`. Unlike Lua,
  an anonymous function **cannot be a closure** (cannot use variables from
  enclosing scopes except the topmost scope).
- **Nested functions:** declared inside another function; visible only in inner
  scopes; also **not closures**.
- **Top-scope closures:** functions declared in the top scope *are* closures,
  and are lightweight — top-scope variables live in static storage, so no
  upvalue reference or GC is needed.
- **Variable number of arguments (`...: varargs`):** the function is
  *polymorphic*; the preprocessor specializes it once per distinct argument
  count/types → no runtime branching.
- **Polymorphic functions:** arguments typed `auto` are replaced by the
  incoming call's type at compile time; specializations are memoized.
- **Record functions / methods:** `function Vec2.create(...)` and
  `Rect:translate(...)` (the `self` parameter is implicit, `*Rect`). Method
  calls auto-reference/dereference the receiver.
- **Annotations on functions:** `<inline>` (C `inline`), `<cimport>`, `<cexport>`,
  `<codename>`, `<nodecl>`, `<cinclude>`.

---

## 5. Memory management

- **Default:** a conservative, stop-the-world, mark-and-sweep GC.
- **Disable the GC** with the pragma `nogc` (`-P nogc` on the command line or
  `## pragmas.nogc = true` in source). With GC off you must manually
  deallocate everything, including strings.
- **Allocators:** `default_allocator` (alias of `gc_allocator` or
  `general_allocator`), `general_allocator` (malloc/free), `gc_allocator`
  (GC-tracked, supports finalizers via `__gc`), plus `ArenaAllocator(SIZE, ALIGN)`,
  `StackAllocator(SIZE, ALIGN)`, `PoolAllocator(T, SIZE)`, `HeapAllocator(SIZE)`.
  Allocators implement `alloc/alloc0/xalloc/xalloc0/dealloc/realloc/realloc0/
  xrealloc/xrealloc0/spanalloc*/new/delete` and span variants.
- When the GC is on, memory containing pointers **must** be allocated through
  `gc_allocator`/`default_allocator` so the GC can scan it.
- `<close>` variables: when they go out of scope their `__close` metamethod is
  called (deterministic resource cleanup, like Go's defer / Rust's Drop).

---

## 6. Metaprogramming (the preprocessor)

At compile time a full **Lua preprocessor** is available. It renders code between
its statements; lines beginning with `##` and blocks between `##[[ ... ]]` are
Lua code. Preprocessor constructs:

- **`##` statement lines** and **`##[[ ... ]]` code blocks** — arbitrary Lua,
  evaluated at compile time, persistent across modules (declare functions
  `local` to avoid polluting other modules).
- **`#[expr]#`** — expression replacement (a Nelua value/AST produced by the
  preprocessor replaces the token).
- **`#|expr| #`** — name replacement (an identifier produced by the preprocessor).
- **`#[node]#`** — emit an AST-node expression.
- **`inject_astnode(node)`** — inject a statement AST node at the call site.
- **Preprocessor macros:** define a `## function(name, ...)` and call it as
  `#[macro]#(...)`. Use `expr_macro` for expression-position macros.
- **Code blocks as macro arguments:** `## unroll(4, function() ... ## end)`.
- **Generic code via the preprocessor:** `## function Point(PointT, T) ... ## end`
  then `## Point('PointFloat', 'float64')`.
- **Preprocessing on the fly:** iterate over already-processed symbols
  (`Weekends.value.fields`) and emit code; even *modify* what has been processed
  (`Person.value:add_field('age', ...)`).
- **`static_assert(cond, fmt, ...)`** and **`static_error(fmt, ...)`**.
- **Polymorphic-function specialization:** branch inside the function body on
  `x.type.is_integral` / `is_float` / `is_stringy` etc.
- **Preprocessor modularity:** share preprocessor helpers via standalone
  `.lua` modules required with `## local foo = require "foo"` (set `LUA_PATH` if
  needed).

### Generics

A generic is a preprocessor function evaluated at compile time to produce a
specialized type, via the `generalize` macro:

```nelua
local FixedStackArray: type = #[make_FixedStackArray]#
```

Generics are **memoized** — evaluated once per distinct set of compile-time
arguments. Similar to C++ templates. Used to build `vector`, `sequence`,
`span`.

### Concepts

A concept is a preprocessor function (`concept(...)`) that, at compile time,
decides whether an incoming argument type matches requirements. Used to
specialize polymorphic functions. Variants:

- **`concept(function(attr) ... return bool end)`** — returns `true`/`false`, or
  returns a *type* to infer to (the compiler then implicitly casts the incoming
  arg to that type), or returns `(false, 'error message')` to give a compile
  error.
- **`facultative(T)`** — shortcut for "accepts nil, otherwise behaves like T".
- **`overload(t1, t2, ...)`** — shortcut for dispatching on one of several types.
- Concept properties live on `attr.type` (`is_scalar`, `is_stringy`, `is_integral`,
  `is_float`, `is_pointer`, `is_array`, `is_record`, `is_niltype`, `metafields`,
  custom flags you set like `is_Vec2`). See `nelua/types.lua`.

---

## 7. C interoperability

- **`<cimport>`** — import a C function; Nelua auto-declares it (no header needed).
- **`<cimport 'name'>`** — import under a different symbol.
- **`<nodecl>`** — don't emit a declaration (the C header will).
- **`<cinclude '<stdio.h>'>`** — emit `#include` at the top of the generated C.
- **`## cdefine 'X'`** — emit a `#define`.
- **`## linklib 'SDL2'`** — pass `-lSDL2` to the linker.
- **`## cflags '...'` / `## ldflags '...'`** — extra C compiler / linker flags.
- **`## cemit '...'` / `## cemitdecl '...'` / `## cemitdef '...'`** — emit raw C
  into the current scope / declarations section / definitions section.
- **`<cexport, codename 'mylib_foo'>`** — export a function with a fixed C name
  (for building C libraries).
- **`<cimport, nodecl>` on a constant** — import a C constant.

The compiler emits a single, readable C file with sections: declarations,
definitions, and per-function bodies. It generates `int nelua_main(int, char**)`
as the entry point.

---

## 8. Standard library

All libraries are used with `require 'name'`. Highlights (full signatures in
`docs/pages/libraries.md`):

- **Builtins (not `require`d):** `require`, `print`, `panic`, `error`, `assert`,
  `check` (omitted in release/nochecks), `likely`, `unlikely`, `_VERSION`.
- **arg** — command-line arguments (`arg`, a `sequence(string, GeneralAllocator)`).
- **iterators** — `ipairs`, `mipairs`, `next`, `mnext`, `pairs`, `mpairs`.
- **io / filestream** — `io.open/popen/close/flush/input/output/tmpfile/read/write/
  writef/printf/type/lines`; `filestream` record with `open/flush/close/destroy/
  seek/setvbuf/read/write/writef/lines/isopen/__tostring/_fromfp/_getfp`.
- **math** — `abs/floor/ifloor/ceil/iceil/round/trunc/sqrt/cbrt/exp/exp2/pow/log/cos/
  sin/tan/acos/asin/atan/atan2/cosh/sinh/tanh/log10/log2/acosh/asinh/atanh/deg/rad/
  sign/fract/mod/modf/fmod/frexp/ldexp/min/max/clamp/ult/tointeger/type/randomseed/
  random` + constants `pi`, `huge`, `mininteger`, `maxinteger`, `maxuinteger`.
- **memory** — `copy/move/set/zero/compare/equals/scan/find/spancopy/spanmove/
  spanset/spanzero/spancompare/spanequals/spanfind`.
- **os** — `clock/date/difftime/execute/exit/getenv/remove/rename/setlocale/
  timedesc/time/tmpname/now/sleep`.
- **span** — the `span(T)` generic (fat pointer) with `empty/valid/sub/__atindex/
  __len/__convert`.
- **string** — `create/destroy/__close/copy/byte/sub/subview/find/gmatch/gmatchview/
  rep/match/matchview/reverse/upper/lower/char/format/len/span/__atindex/__len/
  __concat/__eq/__lt/__le/__add/__sub/__mul/__div/__idiv/__tdiv/__mod/__tmod/__pow/
  __unm/__band/__bor/__bxor/__shl/__shr/__asr/__bnot/fillcstring` + module-level
  `tostring`/`tonumber`/`tointeger` + `string.pack/unpack/packsize`.
- **stringbuilder** — mutable byte buffer: `make/destroy/__close/clear/prepare/
  commit/resize/writebyte/write/writef/view/promote/__len/__tostring`.
- **traits** — `typeid/typeinfo/typeidof/typeinfoof/type`.
- **utf8** — `charpattern/char/codes/codepoint/offset/len`.
- **coroutine** — `coroutine` handle (`@*mco_coro`), `create/destroy/push/pop/
  isyieldable/resume/spawn/yield/running/status`. Note: no variable-args in
  yield/resume; pass values via `push`/`pop` with compile-time-known types.
- **hash** — `short/long/combine/hash`.
- **vector** — `vector(T, Allocator)` dynamic array: `make/destroy/__close/clear/
  reserve/resize/copy/push/pop/insert/remove/removevalue/removeif/capacity/
  __atindex/__len/__convert`.
- **sequence** — `sequence(T, Allocator)`, Lua-table-like (1-indexed, grows on
  past-end index, passed by reference): same method set as vector.
- **list** — doubly-linked list: `make/destroy/__close/clear/pushfront/pushback/
  insert/popfront/popback/find/erase/empty/__len/__next/__mnext/__pairs/__mpairs/
  __convert`.
- **hashmap** — `hashmap(K, V, HashFunc, Allocator)`: `make/destroy/__close/clear/
  _find/rehash/reserve/_at/__atindex/peek/remove/loadfactor/bucketcount/capacity/
  __len/__pairs/__mpairs`.
- **allocators** — `default`, `allocator` (interface), `general`, `gc`, `arena`,
  `stack`, `pool`, `heap`.

---

## 9. Observed 0.2.0-dev runtime behavior & known limitations

> **Why this section matters.** The sections above describe the *intended*
> language — what the website and spec files say Nelua should be. This section
> records what **Nelua 0.2.0-dev actually does**: behaviors that diverge from
> Lua, stdlib return shapes that surprise newcomers, and features that are
> broken or unsupported in this specific version. A clean-room reimplementation
> in Nim must decide whether to *replicate* these (for faithful porting of code
> written against 0.2.0-dev) or to *fix* them (and then document the
> differences — otherwise existing code silently breaks). The facts below
> come from real, working Nelua code — the `zxplayer` terminal media player —
> and from running the compiler, not just from the documentation.

### 9.1 Stdlib return shapes that differ from Lua / intuition

Read these before assuming Lua semantics.

- **`os.execute(cmd)` returns `true`/`false`** — a success flag, *not* the
  integer exit code you would get from C's `system()`. Verified:
  `os.execute("true")` → `true`, `os.execute("false")` → `false`. Write
  `if os.execute(cmd) then ... end`, never `os.execute(cmd) == 0`.
- **`string.find` returns `(start, end)` as integers; on no match it returns
  `(0, 0)`, not `nil`.** So `local b, e = s:find(p); hit = (b ~= 0)`. This is
  unlike Lua, where `string.find` returns `nil`.
- **`string.match` returns a *sequence* of captures, not a string.** It cannot
  be fed directly to `tonumber`; walk the captures by hand instead.
- **`string.gmatch` / `string.gmatchview`** return an iterator (over string
  views for `gmatchview`); use `for x in s:gmatchview(pat) do ... end`.
- **No `_` discard symbol.** `b, _ = s:find(p)` is an *"undeclared symbol
  '_'"* error. Use a real name like `e`.
- **`tostring` works on integers and floats** (e.g. `tostring(start)` to build
  a playlist-index string).

### 9.2 Type-system / compiler limitations in 0.2.0-dev

- **`any` is not fully supported.** A function whose return type would be
  deduced as a union of types (`string | number | boolean | table | nil`) is
  rejected with *"unsupported 'any' deduced type"*. Workaround: parse straight
  into concrete record types so every function returns one concrete type.
- **`facultative(T)` (the optional type) cannot be used in return position.**
  A function that may legitimately return "no value" must instead return a
  boolean signal plus the value, e.g. `(false, "", pos)` on failure.
- **`require "C"` loads fine and is the empty namespace record.** `C/init.nelua`
  is only `global C: type = @record{}; return C` — no `C.execvp` is declared
  there. C functions are imported via submodules: `require 'C.stdio'` yields a
  record exposing `.printf`, `.scanf`, `.fprintf`, etc., each annotated
  `<cimport, cinclude'<stdio.h>'>`; `C.stdarg` provides `va_start`/`va_arg`/
  `va_end`. The varargs parameter form is `...: cvarargs` (e.g.
  `C.printf(format: cstring, ...: cvarargs)`), and typed varargs
  (`...: cstring`) also compile — neither is unsupported, and neither breaks
  `require "C"`. `cvalist` is a separate type passed as an ordinary parameter
  (e.g. `C.vprintf(format: cstring, arg: cvalist)`); it is never unpacked from
  `...`. Verified by compiling probes against the installed compiler.
- **No reliable RNG in the stdlib.** There is no usable pure-RNG module, and
  `C.rand()` is unreachable (see above). Users roll their own — a small
  xorshift or LCG with module-local state keeps tests deterministic.
- **Record field names that are C keywords break C code generation.** The C
  emitter writes field names verbatim into C declarations, so a record with a
  field named `int`, `char`, `float`, `void`, `struct`, `unsigned`, or any
  other C keyword produces invalid C: `int64_t int;`, `uint8_t char;`,
  followed by *"two or more data types in declaration specifiers"* /
  *"expected identifier before 'char'"* and a failed static-assert on the
  struct size. Verified by compiling the exact failing snippet. This is the
  real cause of a common "my colon method call doesn't work" report — the
  method and the `auto` parameter are fine; the field names are the problem.
  **Fix:** rename the fields (e.g. `int` → `id`, `char` → `ch`). A clean-room
  reimplementation should either mangle reserved names or reject them at
  parse time with a clear diagnostic.

  Confirmed-working in the same breath (do **not** read these as broken):
  `auto` as a function-parameter type works and is already documented (§4,
  line 384); colon methods on locally-declared record types work; the `#`
  length operator applied to a record *type* returns the struct size in bytes
  (`#Thing` → 32 for `{ id: integer, ch: uint8, label: string }`); and the
  `<const>` inline annotation (`local MAX: uint32 <const> = 500000`) is
  accepted. All verified by compiling and running against `/usr/bin/nelua`.

### 9.3 Semantics that diverge from Lua

- **`local` declarations are NOT hoisted** in Nelua, unlike Lua. A `local`
  name only comes into scope at the line where it is declared. This bites in
  parser-style loops that track a position:

  ```lua
  while true do
    pos = skip_ws(s, pos)              -- uses the OUTER pos
    local ok, key, pos = parse(s, pos) -- declares a NEW local pos
    ...
  end
  ```

  The `pos = skip_ws(s, pos)` at the top still refers to the outer (unchanged)
  position, so every iteration re-parses the same token forever — a 100%-CPU
  spin with no error. **Fix:** give the returned position a different name and
  assign it explicitly (`local ok, key, nextpos = ...; pos = nextpos`). The
  same rule applies to `skip_value`-style helpers that rebind `pos` inside
  their own while loops.

### 9.4 Domain behaviors discovered while driving mpv (v0.41.0)

Not language features, but real constraints a zxplayer-style program must
respect — and an illustration of the kind of version-specific detail that only
turns up by running code:

- **mpv IPC commands must be JSON *array* form** `["cycle","pause"]`. The
  object form `{"command":"pause"}` is rejected with *"invalid parameter"* on
  mpv v0.41.0.
- **`--vo=null` is required in addition to `--no-video`.** With `--no-video`
  alone, mpv v0.41 still picks a video output (gpu-next) and renders a
  visualizer; `--vo=null` forces the null output.
- **mpv must be spawned detached** (`os.execute "mpv ... >/dev/null 2>&1 &"`)
  so it outlives the caller. An `io.popen` pipe couples mpv's lifetime to the
  pipe: closing it (pclose) blocks until mpv exits, and leaving it open leaks.
- **The IPC socket file persists after mpv quits** and `io.open` cannot detect
  a dead socket, so the player queries live properties and treats a dead
  socket as `(0.0, 0.0, false)` rather than crashing the render loop.

### 9.5 How to use this section for the clean-room reimplementation

- **Faithful mode:** replicate the 0.2.0-dev behaviors above verbatim (bool
  `os.execute`, `(0,0)`-on-no-match `string.find`, no `_`, non-hoisted
  `local`). Existing Nelua code — including `zxplayer` — then ports with
  minimal changes.
- **Improved mode ("beyond"):** fix the divergences (hoist `local` like Lua,
  return `nil` from `string.find` on no match, support `_`, fully support
  `any`/`facultative`). You must then **tell users explicitly** where the new
  compiler differs from 0.2.0-dev, or their existing code will silently break.

---

## 10. Compiler architecture (for reimplementation)

The reference compiler is **written in Lua** and runs on Lua 5.4 (+ a vendored
`lpeglabel` parser generator). Understanding its pipeline is the key to a
clean-room reimplementation. The pipeline, from `nelua/runner.lua`:

```
source input
   │
   ▼
 ┌─────────────────────────────┐
 │ 1. aster.parse(input)       │  PEG grammar (syntaxdefs.lua) → AST
 │    (lpeglabel)              │  AST nodes defined in astdefs.lua
 └──────────────┬──────────────┘
                ▼
 ┌─────────────────────────────┐
 │ 2. preprocessor             │  Lua preprocessor runs gradually per node
 │    (preprocessor.lua)       │  on first visit; may inject/replace AST
 └──────────────┬──────────────┘
                ▼
 ┌─────────────────────────────┐
 │ 3. analyzer.analyze(ctx)    │  visitor-based traversal (analyzer.lua),
 │    (analyzer.lua,           │  analyzercontext.lua); type-checking, scope
 │     analyzercontext.lua)    │  resolution, symbol table, sema, attr inference
 └──────────────┬──────────────┘
                ▼
 ┌─────────────────────────────┐
 │ 4. generator.generate(ctx)  │  C code generation (cgenerator.lua),
 │    (cgenerator.lua,         │  CContext + CEmitter (cemitter.lua,
 │     cemitter.lua,           │  ccontext.lua)); produces a single C source
 │     ccontext.lua)           │  string
 └──────────────┬──────────────┘
                ▼
 ┌─────────────────────────────┐
 │ 5. compiler.generate_code   │  write .c file (ccompiler.lua)
 │    → compile_binary         │  invoke C compiler (GCC/Clang/TCC) → binary
 │    → run (optional)         │
 └─────────────────────────────┘
```

### 10.1 Module map (reference implementation)

| Module | Role |
|--------|------|
| `aster.lua` | Parser (PEG via `lpeglabel`), AST node creation, shape checking |
| `astdefs.lua` | AST node shape registry (the AST schema) |
| `syntaxdefs.lua` | The complete PEG grammar + syntax-error messages |
| `preprocessor.lua` | Preprocessor driver (gradual, per-node) |
| `ppcontext.lua` | Preprocessor context (inject nodes/names) |
| `analyzer.lua` | Visitor-based analyzer: type inference, checking, sema |
| `analyzercontext.lua` | Analyzer context (scopes, symbols, codenames) |
| `types.lua` | The type hierarchy (classes for each type kind) |
| `typedefs.lua` | Primitive types, literal suffixes, annotations, type lists |
| `attr.lua` | Attributes attached to AST nodes / symbols |
| `symbol.lua` | Symbol table entries (promoted attrs) |
| `scope.lua` | Scope stack; builtin-symbol creation |
| `cgenerator.lua` | AST → C code visitor |
| `cemitter.lua` | C emitter helpers (literals, casts, qualifiers) |
| `ccontext.lua` | C generation context (visitor context for code gen) |
| `cdefs.lua` / `cbuiltins.lua` | C definitions and builtin C function mappings |
| `ccompiler.lua` | Driving the external C compiler |
| `configer.lua` | Command-line/config parsing |
| `runner.lua` | Top-level driver (the pipeline above) |
| `utils/*` | Class, traits, tabler, iterators, sstream, errorer, pegger, fs, console, executor, etc. |

### 10.2 AST design

The AST is a tagged-node tree. Each node has a `tag` (its shape name) and an
`attr` table holding compile-time facts (`type`, `comptime`, `const`, `value`,
`base`, `lvalue`, `staticstorage`, `codename`, `name`, ...). Key node shapes
(from `astdefs.lua`):

- Statements: `Block`, `VarDecl`, `Assign`, `Return`, `If`, `Switch`, `Do`,
  `Defer`, `While`, `Repeat`, `ForNum`, `ForIn`, `Break`, `Continue`, `Label`,
  `Goto`, `FuncDef`.
- Expressions: `Number`, `String`, `Boolean`, `Nilptr`, `Nil`, `Varargs`, `Id`,
  `IdDecl`, `Function`, `Call`, `CallMethod`, `UnaryOp`, `BinaryOp`, `Paren`,
  `DoExpr`, `InitList`, `Pair`, `DotIndex`, `ColonIndex`, `KeyIndex`, `Type`,
  `Annotation`, `Preprocess`, `PreprocessExpr`, `PreprocessName`.
- Types: `RecordType`, `UnionType`, `EnumType`, `FuncType`, `ArrayType`,
  `PointerType`, `OptionalType`, `GenericType`, `VariantType`, `VarargsType`,
  `RecordField`, `UnionField`, `EnumField`.

Attributes: `is_function`, `is_call`, `is_unpackable`, `is_index`,
`is_operator`, `is_preprocess`.

### 10.3 Type system design

Types are objects (classes) with properties the analyzer and preprocessor query:

- **Integral types** (`int8..int128`, `uint8..uint128`, `isize`, `usize`,
  `integer`, `uinteger`): `is_integral`, signedness, size, alignment.
- **Float types** (`float32/64/128`): `is_float`.
- **Boolean.** **String** (`is_stringy`). **Pointer** (`is_pointer`, `subtype`).
- **Array** (`is_array`, `subtype`, `size`). **Record** (`is_record`, `fields`,
  `metafields`). **Union.** **Enum.** **Function** types.
- **`any`**, **`niltype`**, **`void`**, **`auto`**, **`varargs`**, **`varanys`**.
- Type properties used by concepts/preprocessor: `is_scalar`, `is_stringy`,
  `is_integral`, `is_float`, `is_pointer`, `is_array`, `is_record`, `is_niltype`,
  `metafields`, plus user-settable flags (e.g. `is_Vec2`).
- Types carry a `codename` (the C identifier used in generated code),
  `typeid` (a unique id for runtime `traits.typeidof`), `nickname`, `name`.

### 10.4 C generation

The C generator traverses the analyzed AST with a visitor context, emitting C
into a single file. It produces declarations, then definitions, then a
`nelua_main`. Key responsibilities:

- Map Nelua types to C types (directly, since records→structs, arrays→C arrays,
  pointers→C pointers, enums→C enums).
- Handle implicit/explicit conversions with optional runtime narrow checks.
- Lower multiple returns to small C structs.
- Lower polymorphic/varargs functions to monomorphic C functions (one
  specialization per call signature).
- Lower method calls, metamethod dispatch, and auto(ref/deref) for records/arrays.
- Implement the GC runtime (or omit it when `nogc`).
- Honor annotations: `<inline>`, `<cimport>` (declare/import C functions),
  `<cexport>`/`<codename>` (export), `<noinit>`, `<volatile>`, `<close>`.

---

## 11. Proposed enhancements ("beyond")

For a clean-room Nim reimplementation that aims to match **and go beyond**
Nelua, the following are natural extensions. Each preserves the "compiles to C"
model and the Lua-flavored syntax.

### 11.1 Language-level

1. **Tables / hash maps as a first-class runtime type.** Nelua's roadmap lists
   tables as not-yet-implemented. A `table(K, V)` (or `anytable`) with the usual
   Lua semantics (array + hash parts, `#`, `next`, `pairs`) would close the gap
   with Lua and make the language usable without always reaching for
   `hashmap`.
2. **Full `any` type with runtime type dispatch.** Support dynamic typing in
   the way Lua does, with an efficient tagged-representation `any` value and
   minimal overhead. This enables porting real Lua code.
3. **Exceptions / `perror` with `try`/`catch`/`recover`.** A structured error
   handling mechanism (the FAQ says `error` may become an exception in the
   future). `recover` blocks, `try`, and guaranteed `__close` on error paths.
4. **Closures everywhere (not just top scope).** Currently only top-scope
   functions close over static storage. Real closures (capturing heap-allocated
   upvalues, or via a GC) would make anonymous/nested functions fully useful.
5. **Generators / coroutines-as-first-class values.** A `yield`-based iterator
   protocol without the `coroutine` library's push/pop friction.
6. **`match` expressions and pattern matching** on records, unions, and
   `any` (Rust/Ocaml-flavored).
7. **Operator overloading via `__` metamethods for more operators** (e.g.
   indexing assignment `__newindex`, `__call`, `__unm` for more types).
8. **`constexpr`-style compile-time evaluation** of arbitrary functions (not
   just the preprocessor) — evaluate pure functions at compile time.
9. **`@`-prefixed macro functions** that are syntactically lightweight and
   hygiene-aware, beyond the current `#[ ]#` template mechanism.
10. **Better integer types:** native 128-bit where the C compiler supports it;
    `isize`/`usize` as first-class; configurable `integer`/`uinteger`/`number`
    widths via a single compile-time knob (already planned).

### 11.2 Compiler / implementation-level

11. **A real bytecode VM + JIT option** (optional), keeping AOT compilation as
    the default — so the same language can run interpreted for tooling/tests and
    compiled for deployment.
12. **Self-hosting bootstrap:** the Nim reimplementation should be able to
    compile itself (or a meaningful subset), proving the spec is complete.
13. **Faster, incremental compilation** with a persistent cache and
    dependency tracking (the reference compiler recompiles the whole file).
14. **Better error messages** with source spans, suggestions, and "did you
    mean?" (the reference compiler already has good messages; a reimplementation
    can match and exceed them).
15. **Pluggable backends:** keep C as the primary, but optionally emit LLVM IR,
    WASM, or (for fun) a tiny bytecode — all from the same analyzed AST.
16. **Compiler plugins / AST hooks as a documented public API** so users can
    register custom visitors, type rules, or codegen passes (the reference
    compiler's strength is hackability; make it first-class).
17. **`--sanitize` integration and more compile-time safety checks:**
    uninitialized-read detection, bounds checks on all indexing (not just
    spans), null-pointer checks, integer-overflow panics in debug builds.
18. **Freestanding / no-runtime target:** emit dependency-free C (no libc) for
    kernels and bare-metal — already a goal; a reimplementation should make this
    a clean mode (`-P freestanding`).

### 11.3 Stdlib / ecosystem

19. **A proper `table`/`map` library** as a first-class type (see 11.1.1).
20. **`net`, `thread`, `time`, `fs`** libraries beyond `os` for a fuller
    systems-programming story.
21. **`fmt` / `printf`-style formatting with compile-time format-string
    checking** (a type-safe `string.format`).
22. **Test harness and tooling** integrated (`nelua --test`), plus a formatter,
    linter, and debugger protocol (DAP) integration.

---

## Appendix A — AST node shapes reference

Full list of registered AST shapes (from `astdefs.lua`), each with its field
schema — the contract a clean-room reimplementation must satisfy:

| Shape | Fields | Notes |
|-------|--------|-------|
| `Block` | `[Node...]` | statement list |
| `Number` | `(value:string, literaltype:string)` | integer/float literal |
| `String` | `(value:string, literaltype:string)` | string literal |
| `Boolean` | `(value:boolean)` | `true`/`false` |
| `Nilptr` | `()` | `nilptr` |
| `Nil` | `()` | `nil` |
| `Varargs` | `()` | `...` |
| `DoExpr` | `(Block)` | `(do ... end)` expression |
| `Preprocess` | `(code:string)` | `##` block, removed after run |
| `PreprocessExpr` | `(code:string)` | `#[expr]#` |
| `PreprocessName` | `(code:string)` | `#|name|#` |
| `Pair` | `(name-or-expr:Node, value:Node)` | init-list field |
| `InitList` | `[Pair | Node...]` | `{...}`; `is_unpackable` |
| `DotIndex` | `(name, expr:Node)` | `.field`; `is_index` |
| `ColonIndex` | `(name, expr:Node)` | `:method`; `is_index` |
| `KeyIndex` | `(key:Node, expr:Node)` | `[key]`; `is_index` |
| `Annotation` | `(name, [args:Node...])` | `<...>` |
| `Id` | `(name)` | identifier |
| `IdDecl` | `(name|DotIndex, typeexpr:Node?, [Annotation...])` | declared name |
| `Paren` | `(expr:Node)` | `(expr)` |
| `Type` | `(typeexpr:Node)` | `@typeexpr` |
| `VarargsType` | `(kind)` | one of `varautos`/`varanys`/`cvarargs` |
| `FuncType` | `([argtypes...], [returns...])` | function type |
| `RecordField` | `(name, typeexpr:Node)` | record field |
| `RecordType` | `[RecordField...]` | record type |
| `UnionField` | `(name?, typeexpr:Node)` | union field |
| `UnionType` | `[UnionField...]` | union type |
| `EnumField` | `(name, value:Node?)` | enum field |
| `EnumType` | `(primitivetypeexpr:Node?, [EnumField...])` | enum type |
| `ArrayType` | `(subtype:Node, size:Node?)` | array type |
| `PointerType` | `(subtype:Node?)` | pointer type |
| `OptionalType` | `(subtype:Node)` | `T?` |
| `GenericType` | `(name, [args...])` | generic instantiation |
| `VariantType` | `[typeexpr...]` | variant |
| `Function` | `([IdDecl|VarargsType...], [returns...], [Annotation...], Block)` | anonymous func; `is_function` |
| `Call` | `([args...], caller:Node)` | call; `is_call`, `is_unpackable` |
| `CallMethod` | `(name, [args...], caller:Node)` | method call; `is_call` |
| `UnaryOp` | `(op, right:Node)` | `is_operator`; ops: not/unm/len/bnot/ref/deref |
| `BinaryOp` | `(left:Node, op, right:Node)` | `is_operator`; ops: or/and/eq/ne/le/lt/ge/gt/bor/bxor/band/shl/shr/asr/concat/add/sub/mul/div/idiv/tdiv/mod/tmod/pow |
| `Return` | `[expr...]` | `is_unpackable` |
| `If` | `([Node|Block...], else:Block?)` | |
| `Switch` | `(expr:Node, [([exprs...], Block)...], else:Block?)` | |
| `Do` | `(Block)` | |
| `Defer` | `(Block)` | |
| `While` | `(expr:Node, Block)` | |
| `Repeat` | `(Block, expr:Node)` | |
| `ForNum` | `(IdDecl, begin:Node, cmpop?, end:Node, step:Node?, Block)` | numeric for |
| `ForIn` | `([IdDecl...], [exprs...], Block)` | iterator for |
| `Break` | `()` | |
| `Continue` | `()` | |
| `Label` | `(name)` | `::name::` |
| `Goto` | `(name)` | `goto name` |
| `VarDecl` | `(scope:"local"|"global", [IdDecl...], [initexprs...]?)` | `is_unpackable` |
| `Assign` | `([varnodes...], [valuenodes...])` | `is_unpackable` |
| `FuncDef` | `(scope?, name, [IdDecl|VarargsType...], [returns...], [Annotation...], Block)` | named func; `is_function` |
| `Directive` | `(name:string, args:table)` | internal |

---

## Appendix B — Compiler pipeline configuration & options

Key command-line/config knobs (from `configer.lua` / FAQ):

- `--release` — enable C optimizations, disable runtime checks.
- `-P nochecks` — disable runtime checks.
- `-P nogc` — disable the garbage collector.
- `--debug` — run under GDB and print readable backtraces.
- `--sanitize` — catch misuses leading to crashes/undefined behavior.
- `--cc <cc>` — choose the C compiler (GCC/Clang/TCC/...).
- `--cflags "..."` / `--ldflags "..."` — extra flags.
- `-DFAST` — user-defined preprocessor define (used in `## if FAST then`).
- `--timing` — per-stage timing output.
- `--print-ast` / `--print-analyzed-ast` / `--print-code` — debugging.
- `--lint` — syntax-only check.
- `--generate-code` — emit C only, don't compile.
- `--compile-binary` — compile to binary without running.
- `--eval` / `--run` / `--script` — eval/run/script modes.
- Pragma `unitname` — prefix generated C symbols per translation unit.

---

## Appendix C — Notes for the clean-room Nim implementation

1. **Target model:** Nelua source → (your compiler) → C source → (external C
   compiler) → native binary. The C compiler is an external tool, not a
   dependency you ship — this is the key architectural decision that keeps the
   compiler small and portable.
2. **Parser:** the reference uses a PEG grammar (LPeg/LPegLabel). A clean-room
   reimplementation in Nim can use `parsec`/`regex` or a hand-written recursive
   descent parser. The grammar in `syntaxdefs.lua` (§Appendix reference) is the
   contract; a hand-written parser gives you full control over error messages
   and span tracking.
3. **AST:** implement the node shapes in Appendix A. Tagged unions / objects
   with an `attr` payload. Keep `is_*` flags and `tag`.
4. **Types:** model the type hierarchy from §10.3. Types need `codename`,
   `typeid`, `nickname`, and the `is_*` properties concepts query.
5. **Analyzer:** a visitor pattern over the AST (like the reference's
   `visitors[tag]` dispatch). Maintain a scope stack, symbol table, and an
   `attr` inference engine. The preprocessor runs *gradually* per node on first
   visit — you can instead run it as a separate pre-pass; the observable
   behavior is the same.
6. **Preprocessor:** embed a Lua interpreter (e.g. `nlua`-style or an embedded
   LuaJIT) *or* reimplement the preprocessor macro semantics in Nim. The
   reference's power comes from the preprocessor reaching compiler internals
   (`aster.*`, `types.*`, `traits.*`). For a clean-room version, expose a
   well-documented API for AST manipulation and type introspection at compile
   time — that is the essence, not the specific Lua embedding.
7. **C generation:** a visitor that walks the analyzed AST and emits C. Keep
   the output single-file, readable, with declarations / definitions / bodies
   sections, and a `nelua_main` entry.
8. **Memory management:** implement a conservative mark-sweep GC (or reuse a
   known-good GC like `gc2`/`nim-gc`), or make it pluggable. Support the
   allocator interface (`alloc/alloc0/xalloc/dealloc/realloc/new/delete` and
   span variants) so the stdlib containers work.
9. **Stdlib:** the container library (`vector`, `sequence`, `list`, `hashmap`,
   `span`, `stringbuilder`, allocators) is substantial and is written *in
   Nelua itself* using generics. A reimplementation must support the generic /
   concept / preprocessor features well enough to compile these — they are the
   real test of the compiler.
10. **Compliance testing:** the reference repo ships extensive spec files
    (`spec/*.lua`) that double as executable specifications. Port the most
    important ones to your test suite — they encode the expected behavior of
    the type checker, C generator, and preprocessor precisely.

---

*This review was produced from the project website (`docs/pages/*.md`), the
README, the language specification (`spec/*.lua`), and the compiler source tree
(`lualib/nelua/*.lua`). It is a summary and clean-room specification, not a
verbatim copy of any source file.*