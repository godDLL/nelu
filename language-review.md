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
  dynamic features (tables, runtime dynamic typing, structured exception
  handling) are *not yet implemented*; top-scope closures and the `error()`
  runtime panic primitive exist, but the full closure / exception model does not.
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

Not yet implemented: structured exception handling (`try`/`catch`/`recover`),
tables, runtime dynamic typing, closures (except top-scope closures). The
`error(msg)` runtime panic primitive exists; the `any` type is not supported in
value position. There is **no interpreter or JIT** — pure ahead-of-time
compilation. Code generated at runtime cannot be loaded.

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

Grammar verified against `/usr/bin/nelua --print-ast` (0.2.0-dev). The `@` prefix
is a *type-expression* marker, not a general type syntax: it is accepted on
`record` and `union` (both `@record{...}` and the bare `record {...}` parse), but
**rejected** on `enum`, `pointer`, and `function` (those take bare keywords only).
In annotation position the bare form is the common one and always works.

- **Array:** `array(T, N)` — fixed, compile-time size. The bracket form `[N]T` is
  accepted only in *annotation* position (`local a: [10]integer`) and **not** as a
  standalone expression. `[0]T` is an *unbounded array* (unknown size), useful only
  with pointers for indexing. `[]T` sugar infers size from initializer.
  Multidimensional arrays supported. Unbounded arrays are unsafe (no bounds
  checking). Passed **by value** to functions (copies).
- **Enum:** `enum { Sunday=0, Monday, ... }` — **`@enum` is rejected.** First value
  must be initialized explicitly. Defines a type usable as an annotation.
- **Record:** `record { name: string, age: integer }` (also `@record{...}`) → C struct.
  Supports typed initialization (`{name="Mark", age=20}`), cast initialization
  `(@Person){...}`, ordered-field initialization, and late (zero-init) assignment.
- **Union:** `union { i: int64, f: float64 }` (also `@union{...}`) → C union. The
  user tracks the active variant.
- **Pointer:** `*integer` or `pointer(integer)` (generic `pointer` = `*void`), plus
  `nilptr`. **`@pointer(...)` is rejected.** Raw C pointers. **Pointer arithmetic
  is disallowed** — cast to/from integers explicitly.
- **Function type:** `function(x: integer, y: integer): integer` — a pointer to a
  function, convertible to/from generic pointers with explicit casts. Used to store
  callbacks. **`@function(...)` is rejected.**
- **Span:** `span(integer)` — "fat pointer"/slice: `*[0]T` + size. Runtime bounds
  checking (disableable in release). Safer than raw pointers.
- **Variant type:** `A | B | C` — a union of types (separator is the `|` token).
- **Optional type:** `facultative(T)` works as an annotation; `T?` is **rejected**.
  `facultative` cannot appear in return position (§3.5).

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

- **`os.execute(cmd)` returns `(boolean, string, integer)`** — a success flag,
  a status string (`"exit"`), and the integer exit code you would get from C's
  `system()`. Verified: `os.execute("true")` → `true  exit  0`,
  `os.execute("false")` → `false  exit  1`. `if os.execute(cmd) then ... end`
  still works (multi-return truncation); the exit code is available as the
  third return.
- **`string.find` returns `(start, end)` as integers; on no match it returns
  `(0, 0)`, not `nil`.** So `local b, e = s:find(p); hit = (b ~= 0)`. This is
  unlike Lua, where `string.find` returns `nil`.
- **`string.match` returns a *sequence* of captures, not a string.** It cannot
  be fed directly to `tonumber`; walk the captures by hand instead.
- **`string.gmatch` / `string.gmatchview`** return an iterator (over string
  views for `gmatchview`); use `for x in s:gmatchview(pat) do ... end`.
- **`_` is a valid identifier** (no special discard semantics in 0.2.0-dev).
  `local b, e = s:find(p)` works, and so does `local b, _ = s:find(p)`.
- **`tostring` works on integers and floats** (e.g. `tostring(start)` to build
  a playlist-index string).

### 9.2 Type-system / compiler limitations in 0.2.0-dev

- **`any` is not fully supported.** A function whose return type would be
  deduced as a union of types (`string | number | boolean | table | nil`) is
  rejected with the message
  `error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type`.
  Workaround: parse straight into concrete record types so every function
  returns one concrete type.
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
  `os.execute`, `(0,0)`-on-no-match `string.find`, valid `_` identifier,
  non-hoisted `local`). Existing Nelua code — including `zxplayer` — then ports
  with minimal changes.
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
  **Not done in this build:** M2's `Attr.conv` is declared but never populated
  by the current analyzer (binary-op conversions are computed and discarded),
  so no runtime narrow checks are emitted. See the gap note in
  `src/cgen.nim:20-21`.
- Lower multiple returns to small C structs.
- Lower polymorphic/varargs functions to monomorphic C functions (one
  specialization per call signature). **Done in this build:** polymorphic
  `auto` is monomorphized (D1, committed `40fca09`); `AnalyzerResult` has a
  `specials` field (`src/analyzer.nim:71-73`), and `auto` params lower to a
  concrete monomorphized type rather than `any`/`void*`. See
  `plan/auto_oracle-behavior-design.md`.
- Lower method calls, metamethod dispatch, and auto(ref/deref) for records/arrays.
- Implement the GC runtime (or omit it when `nogc`).
- Honor annotations: `<inline>`, `<cimport>` (declare/import C functions),
  `<cexport>`/`<codename>` (export), `<noinit>`, `<volatile>`, `<close>`.

### 10.5 Clean-room reimplementation map and verification oracles

The reference is written in Lua (§10.1). The clean-room reimplementation is **Nim**
and its module map is one file per concern:

| Clean-room Nim module | Role | Milestone |
|-----------------------|------|-----------|
| `src/astshapes.nim` | frozen AST node-shape contract (zero imports) | M1 |
| `src/ast.nim` | AST node constructors and tree walkers | M1 |
| `src/lexer.nim` / `src/parser.nim` | lexer and recursive-descent parser | M1 |
| `src/span.nim` / `src/errors.nim` / `src/config.nim` / `src/cli.nim` | source spans, diagnostics, config, CLI | M1 infra |
| `src/main.nim` | CLI entry point: wires `Config` → `compile` driver, `--print-ast`/`--print-analyzed-ast` dispatch | C1 |
| `src/types.nim` | `Type`/`TypeKind`/`Attr`/`Conversion`/`Symbol`/`Scope`, builtin types, structural canonicalization | M2 |
| `src/sema.nim` | pure type rules (`inferUnary`/`inferBinary`/`commonType`/`convert`/`checkCall`/`resolveTypeExpr`) | M2 |
| `src/analyzer.nim` | `AnalyzerContext`, scope/symbol ops, P3 registration, P4 visitor, polymorphic specialization, `dumpAnaled` | M2 |
| `src/preprocessor.nim` | gradual per-node macro/preprocess pass | M6 |
| `src/cgen_types.nim` / `src/cemitter.nim` | C-type mapping and emitter helpers (analyzer-free) | M3 |
| `src/cgen.nim` | AST → C visitor | M3 |
| `src/compile.nim` | end-to-end driver seam | M4 |
> **Note:** `src/typedesc.nim` was a dead module: it was committed but nothing
> imports it (its only `src/` reference was its own `isMainModule` echo). The
> runtime type-info registry it claimed to emit was never produced here —
> `src/cgen.nim` emits those `extern` declarations inline in its `RUNTIME_C`
> preamble and `src/runtime.c` holds the definitions. `typedesc.nim` has been
> removed.

**Verification oracles (both flags on `/usr/bin/nelua`):**
- `--print-ast` — the untyped AST. The M1 acceptance bar; `plan/cmp.py` normalizes
  both dumps to a `(kind, scalar)` token stream and diffs.
  **`cmp.py` has a hard ceiling, verified: its mine-side tokenizer sets
  `kind = first whitespace token of every `nk`-prefixed line`, so `kind` is
  *always* a non-empty string and it can never emit a `(None, scalar)` token.
  The oracle, however, emits kindless `(None, op)` for binary/unary operator
  children and `(None, "false")` for absent optional slots. Any program
  containing such a token is therefore a guaranteed DIFF regardless of dump
  output — 26 of the 40 `cmp.py` cases, and 0 diffs is unattainable while
  `cmp.py` is unchanged (it is the gate and is not edited). The 14 MATCH cases
  are exactly the kindless-free ones; that is the theoretical floor.**
- `--print-analyzed-ast` — the **typed** AST, the real M2→M4 contract. Every node
  carries an `attr` payload (`type`, `codename`, `lvalue`, `staticstorage`,
  `vardecl`, `used`, `comptime`, `value`, `base`, `parenttype`, `calleeSym`, …).
  Conventions the reimplementation must match for the M2 conformance sweep to be
  a diffable oracle: `BinaryOp` renders as `BinaryOp { left, "op", right }`
  (operator is a *child string* between the operands, canonical names
  `add`/`sub`/`lt`/`eq`/`and`/`or`/`unm`/`len`/…); `UnaryOp` as
  `UnaryOp { "op", right }`; `If` as `If { { cond, block, cond, block, … }, elseblock }`
  (branch group first); `Call` as `Call { args…, caller }` (caller last); absent
  optional slots render as `false`.

  Two further notes on the typed-AST oracle:
  - `nilptr` is its own AST node kind (`Nilptr`), distinct from `nil`. Its literal
    type is `nilptr` but it is the value assignable to any pointer type; `nil`
    stays `niltype` and is *not* pointer-compatible.
  - The live `/usr/bin/nelua --print-analyzed-ast` attaches `pseudoargattrs` and
    `pseudoargtypes` (pointer-table fields) to **Call** nodes. The M2 conformance
    corpus in `tmp/m2_corpus/` is an earlier snapshot that omits them, so the
    14/14 match is against that snapshot; re-snapshotting against the live oracle
    would require emitting those two fields on calls.

---

## 11. Proposed enhancements ("beyond")

For a clean-room Nim reimplementation that aims to match **and go beyond**
Nelua, the following are natural extensions. Each preserves the "compiles to C"
model and the Lua-flavored syntax.

### 11.0 Post-reimplementation direction ("Nelu")

> **At the start of the day we want a source we can work with, and this is what
> we're doing right now. BUT at the end of the day, we want a language we can work
> with, that runs our existing code but also fixes the things Nelua left unfixed,
> fills the gaps it did not support yet, and can be 2.0-ed — can be extended beyond
> by design and by source-code editing in a well-adapted toolchain.**

The reimplementation is a means, not the end product. Once the clean-room
0.2.0-dev parity target is met, development continues as **our own branch of
Nelua** — referred to internally as **Nelu** — rather than stopping. The Nelu
track has three kinds of incoming work:

1. **Syntactic sugar** — small ergonomic additions on top of the reimplementation
   that keep the Lua-flavored syntax and the C-output model.
2. **Missing features** — everything 0.2.0-dev lacks that §11.1–§11.3 enumerates
   (tables, full `any`, exceptions, closures, generators, pattern matching, …).
   These are *inbound* to Nelu, not speculative wishlist.
3. **Bug fixes** — anything found while driving real programs through the
   reimplementation, including regressions against the oracle `/usr/bin/nelua`.

When scoping a milestone, treat the 0.2.0-dev parity ceiling as a floor for
Nelu, not a boundary: a §11 item that is cheap and unambiguous while its
underlying milestone is being built is fair game to fold in — but only with the
user's say-so for anything beyond the current milestone, and never at the cost of
racing another agent's file or the regression gate.

### 11.0b Nelu design docs and design discipline

The parked oracle-behavior specs in `plan/` are **Nelu design inputs**, not just probe
outputs. They are labelled as such in the filename (`-design` suffix) and referenced
here so they are not lost when `plan/` is eventually reviewed and pruned:

- `plan/auto_oracle-behavior-design.md` — what `auto` means (monomorphization to a
  concrete type, *not* `any`).
- `plan/auto_widening-behavior-design.md` — where `auto` flows and where it is rejected
  (e.g. `local x: auto; print(x)` is rejected; `print(id(5))` is accepted).
- `plan/table_oracle-behavior-design.md` — table semantics, and that the C backend
  rejects tables outright (so C table support is beyond-oracle, not parity).
- `plan/exceptions_oracle-behavior-design.md` — the oracle has **no** structured
  exception handling at all (`try`/`catch`/`throw`/`finally`/`raise`/`except`/
  `recover`/`perror` are all rejected). What exists is fatal panic primitives only:
  `error(msg?)`, `panic(msg?)` (C-backend only), `assert(v, msg?)`,
  `check(cond, msg?)` (C-backend only) — all terminate the process (C: SIGABRT
  exit 255; Lua: exit 1), none catchable. `defer` runs at scope end on C but
  **not** on `error()`/`panic()`, and the Lua backend cannot compile `defer`.
  The doc's own "parity = panic builtins + defer; beyond = try/catch" split is
  **superseded by §11.0c below** — see that policy note before scoping work.
- `plan/pattern_matching_oracle-behavior-design.md` — the oracle's only matching
  construct is the C-like `switch`/`case`/`else` **statement** (not an
  expression). No `match`, no `case` outside `switch`, no `if`-expression, no
  guards, no destructuring; `record`/`union`/`enum` are not even keywords.
  Comma-separated case values and duplicate-case handling diverge between the
  C backend (real C `switch`, rejects duplicates) and the Lua backend
  (`if`/`elseif` chain, cannot parse commas, silently takes first duplicate).
  `break`/`continue` bind to the enclosing loop. The doc's own "parity =
  switch/case/else; beyond = match/cond/patterns" split is **superseded by
  §11.0c below** — see that policy note before scoping work.
- `plan/oracle-any-behavior-design.md` — **the two backends disagree fundamentally
  about `any`, and neither backend's type-value equality is a spec.** C backend
  **rejects `any` as a variable/parameter/return type** (`compiler deduced type
  'any' here, but it's not supported yet`); `any` *as a value* is a compile-time
  constant of metatype `type` (like `number`), but type values cannot be
  printed. Lua backend treats `any` as a fully **erased annotation** (`local
  x: any = 5` → `local x = 5`), but the type-value globals `any`/`number`/
  `boolean` are **undefined (nil)** in the emitted Lua (no preamble is injected),
  so `any == nil`/`any == number` → true are undefined behavior, not a spec.
  `any` is a plain identifier, not a keyword. **`any` cannot take a table
  literal** (`type 'any' cannot be initialized using an initializer list` on
  both backends) — a table *variable* works fine. Passing `nil` to an `any`
  param is a compile error, but that is general, not `any`-specific. **Our
  compiler's `any` handling has since changed twice:** Phase 1 (committed
  `ab25f532`) deletes the broken `void*` lowering and emits the oracle's exact
  rejection for deduced `any`, `any` table-literal initializers, `: any`
  params, untyped params, and explicit `: any` returns; Phase 2 (Nelu, committed
  `214102c`) implements the tagged runtime `any` described below. The
  "accepts `any` and lowers it to `void*`, producing broken C" line in this
  entry is superseded history — see `plan/any-implementation-design.md`.
- `plan/any-intended-design.md` — the **intended** `any`, per the docs
  (`language-review.md` §11.1.2: "efficient tagged-representation `any` value"
  enabling porting real Lua code). Two-phase: **Phase 1** (easy, non-interfering)
  emits the oracle's exact rejection for deduced `any` and deletes the broken
  `void*` lowering; **Phase 2** (Nelu, additive) implements the tagged
  representation with runtime dispatch. Both phases are now landed (Phase 1
  `ab25f532`, Phase 2 `214102c`), so this doc is a design record, not a to-do
  list. Tagged word + payload union, Lua coercion rules, implicit
  in-conversion / explicit out-conversion. Open questions on whether deduced
  `any` should flow into the dynamic type (recommended: yes) and the tag set.

### 11.0c Scoping policy for §11 features (2026-08-29, user directive)

Two priorities, in order:

1. **Compatibility first.** We must be able to run **existing** Nelua programs —
   including large ones, multi-file programs, and advanced usage. This is the
   hard bar. Nothing in flight may break it.
2. **Beyond-oracle is additive, not forbidden.** If we can support a
   previously-unsupported thing **without interfering with existing user
   programs**, it is fine to do more, to go beyond. We are **not** required to
   replicate the oracle's rejections — "if it crashed before because Nelua
   didn't do it yet, then we too need to crash the user program" is explicitly
   rejected. The oracle's `error: type 'table' is not supported yet` and
   `syntax error: unexpected syntax` on `try` were *limitations*, not specs.

**Consequence for the design docs above:** the docs correctly record what the
oracle *does* (ground truth for compatibility) and where it *fails* (informational).
But the "parity = X, beyond-oracle (Nelu) = Y, do not invent Y" framing in them is
too strict. The real bar is **non-interference with existing programs**, not
matching the oracle's gaps. So `try`/`catch`, `match`/`cond`, full C table
support, `any`, etc. are all fair game to implement additively — the constraint
is that existing programs must keep running identically, not that we must refuse
the constructs the oracle refused.

**Sequencing:** compatibility (run existing programs, then multi-file/large/
advanced) comes first; the additive-beyond work follows, and only once it can be
verified against a working build. See `plan/examples_parity.py` as the
existing-program execution gate.

**Design discipline.** Two principles govern how Nelu changes the compiler:

1. **Simplicity is structural, not accidental.** Nelua's toolchain is small because
   the language constrains it: one backend (C), no JIT, no multiple IRs, no heavy
   macro machinery, a type system regular enough that analysis is a straightforward
   walk. You cannot get the second without the first. When Nelu adds machinery, the
   question is always whether it buys a concrete language idea.

2. **Parity first, then invert.** While the reimplementation still has to *match* the
   oracle (the `regress.py` gate), the internals are a copy. Once parity is met the
   relationship inverts: the internals become a design we choose to fit the language,
   and the language design can then change with sugar and new ideas. The order matters
   — language idea → spec → internals change → language idea works. D1
   (monomorphization for `auto`) is already this pattern.

3. **Measure before tuning.** A compiler that compiles itself quickly and emits
   readable C is the product; feature count is not. Change internals only where it
   buys a concrete language idea, and keep the pipeline thin.

1. **Tables / hash maps as a first-class runtime type.** Nelua's roadmap lists
   tables as not-yet-implemented. A `table(K, V)` (or `anytable`) with the usual
   Lua semantics (array + hash parts, `#`, `next`, `pairs`) would close the gap
   with Lua and make the language usable without always reaching for
   `hashmap`.
2. **Full `any` type with runtime type dispatch.** Support dynamic typing in
   the way Lua does, with an efficient tagged-representation `any` value and
   minimal overhead. This enables porting real Lua code. **Status: DONE, both
   phases.** Phase 1 (oracle-parity rejection of deduced `any`, deletion of the
   broken `void*` lowering) committed `ab25f532`; Phase 2 (Nelu tagged runtime
   `any` with `nlany` + runtime dispatch) committed `214102c`. See
   `plan/any-implementation-design.md` and `NELU-2K.md` 1.2/1.4.
3. **Exceptions / `perror` with `try`/`catch`/`recover`.** A structured error
   handling mechanism (the FAQ says `error` may become an exception in the
   future). `recover` blocks, `try`, and guaranteed `__close` on error paths.
   **Status: parity half landed** (fatal panic primitives `error`/`panic`/
   `assert`/`check` + `defer` are parity with the oracle); the full
   `try`/`catch`/`finally`/`recover` surface is **queued** (see
   `NELU-2K.md` 2).
4. **Closures everywhere (not just top scope).** Currently only top-scope
   functions close over static storage. Real closures (capturing heap-allocated
   upvalues, or via a GC) would make anonymous/nested functions fully useful.
   **Status: partial.** Module-scope capture lowers to file-scope `static`s
   and function-local capture is rejected with the oracle's exact message
   (committed `75f315e` + `bab3eb3`); 7 of 15 closure probes MATCH the oracle.
   Full heap-allocated upvalues is **queued** (see `NELU-2K.md` 2).
5. **Generators / coroutines-as-first-class values.** A `yield`-based iterator
   protocol without the `coroutine` library's push/pop friction.
6. **`match` expressions and pattern matching** on records, unions, and
   `any` (Rust/Ocaml-flavored). **Status: parity half landed** (the oracle's
   `switch`/`case`/`else` statement is parity); `match`/`cond`/destructuring
   patterns are **queued** (see `NELU-2K.md` 2).
7. **Operator overloading via `__` metamethods for more operators** (e.g.
   indexing assignment `__newindex`, `__call`, `__unm` for more types).
   **Status: partial.** M1 (`__len` via `#`), M2 (`__tostring` via `print()`)
   and M4 (`__index` via `[]`, its array-field-init blocker fixed) are landed
   and MATCH the oracle (committed `f75601a`); M3 (`__call` codegen) is
   **queued**.
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

### 11.4 Vendored third-party libraries → tracked upstream

Several third-party libraries are currently **vendored** (copied) into `src/`.
For Nelu the plan is to convert the pullable ones into **git submodules** so
`git submodule update --remote` tracks upstream and we can diff our forks
against it. Mapping (verified against each source's own header):

| In `src/` | Origin | Upstream | Pullable |
|---|---|---|---|
| `lua/` (35 files) | **Lua 5.3**, Lua.org/PUC-Rio | `github.com/lua/lua` (official git mirror) | yes |
| `lfs.c` | **LuaFileSystem**, Kepler Project 2003–2020 | `github.com/keplerproject/luafilesystem` | yes |
| `rpmalloc/` | **rpmalloc**, Mattias Jansson, public domain | `github.com/mjansson/rpmalloc` | yes |
| `lpeglabel/` | lpeg (Lua.org/PUC-Rio) with **Nelua's "label" fork** | base lpeg has no canonical github | partial — pull the base, keep our fork on top |
| `sys.c` | no header; reads as Nelua's own sys Lua lib | — | no, ours |
| `luainit.c/.h/.lua` | Nelua's init layer | — | no, ours |
| `lualib/nelua/` (57 files) | **the reference 0.2.0-dev compiler source, in Lua** | — | no, ours |
| `nelua-decl/` | **nelua-decl**, edubart | `github.com/edubart/nelua-decl` | yes — but see blocker below |
| `nelua-decl/gcc-lua/` | **gcc-lua** (GCC Lua plugin), Peter Colberg 2012–2015 | `github.com/edubart/gcc-lua` | yes — but does not build on GCC 16 |

**`lib/` is inherited stdlib — a different category from everything above.**
The 44 `.nelua` files under `lib/` (allocators, arg, builtins, coroutine, filestream,
hashmap, hash, io, iterators, list, math, memory, os, sequence, span,
stringbuilder, string, table, traits, utf8, vector, plus the `lib/C` and
`lib/detail` subtrees) are the upstream 0.2.0-dev **standard library**. We
inherit them as *our* stdlib: they ship with the compiler, are MIT-licensed like
the rest of the repo, and `require 'math'` / `require 'string'` resolve against
them. `compile.nim`'s `resolveModule` searches `lib/` (after the requiring
file's own dir and the cwd). Unlike the vendored `src/` libs above, `lib/` has
no upstream to submodule-track — it is the stdlib we own and evolve as Nelu,
and it is the parity reference for the `require` system (a `require`d module
must behave like the oracle's).

**But the inheritance is gated on our compiler compiling it cleanly.** `lib/`
is shipped source, not a runtime dependency — it only becomes *usable* stdlib
when `nelua` can compile it. This makes the whole stdlib a **compiler
integration bar**: a harness that compiles every `lib/*.nelua` through our
compiler and reports which fail is the natural gate above `regress.py`, and
"all of `lib/` compiles and matches the oracle" is the honest end-of-parity
signal for the reimplementation — stronger than any feature-count checklist.

**Correction (2026-08-29):** that harness is the wrong shape. `lib/` is a
**require-dependency graph, not a set of standalone files** — the oracle itself
rejects `lib/math.nelua` compiled alone (`error: undeclared symbol 'Xoshiro256'`,
because `Xoshiro256` is defined in `lib/detail/xoshiro256.nelua`, which `math`
depends on). A program that `require "math"` compiles and runs fine (`m.pi` →
`3.1415926535898`, exit 0). So the gate is **require-based usage matching the
oracle**, not per-file compilation — which is exactly what the module system
(`require` parse → resolve → recursive compile → transitive flatten) exercises,
and what `regress.py` partly covers. This also means transitive `require`
resolution is not optional: it is how the stdlib is wired together.

**`lualib/nelua/` is not a small stdlib — it is the reference compiler's own
source.** 57 Lua files: `aster.lua` (parser), `analyzer.lua`,
`cgenerator.lua`/`luagenerator.lua`, `cemitter.lua`, `luacompiler.lua`,
`ccompiler.lua`, `preprocessor.lua`, `types.lua`, `scope.lua`, `symbol.lua`,
`configer.lua`, `runner.lua`, `astnode.lua`/`astdefs.lua`, `builtins.lua`/
`cbuiltins.lua`/`luabuiltins.lua`, plus `utils/` (sstream, errorer, platform,
console, tracker, traits, metamagic, pegger, iterators, stringer, fs, tabler,
...) and `thirdparty/` (argparse, bint, inspect, lester, lpegrex, tableshape).
`version.lua` declares `0.2.0-dev` — the exact baseline we match. `/usr/bin/nelua`
is a 610-byte shell launcher that does `require'nelua.runner'.run(arg)`; the
compiler it loads comes from here. So this tree is the authoritative
implementation of the semantics, type system, codegen, and preprocessor that
our clean-room Nim reimplementation is trying to match.

**⚠ Resolved (2026-08-29, user decision): look, but leave it alone, and have
our own.** `lualib/nelua/` is reference we may **read** to understand semantics
(it is the authoritative definition of the type system, AST shapes, preprocessor
and codegen we are matching) — but we do **not** modify it, and we do **not** port
it. Our compiler stays a clean-room Nim implementation: our own design, our own
structure, shaped to the language rather than a line-by-line translation of the
Lua. This is path (b) from the tension note below, with the "leave it alone"
guardrail — faster and more accurate than black-box probing, without sacrificing
that the reimplementation is genuinely ours. It also means agents may consult
`lualib/nelua/` when a semantic question is ambiguous, but must not edit it and
must not lift code from it into `src/`.

There is no "modern iteration" to follow here: Nelua-lang is dead, and this is
the 0.2.0-dev baseline, not a newer fork. **We are the modern iteration (Nelu)**
— this tree is what we evolve *from*, not a project we track *after*.

**The other inherited corpus dirs (`tests/`, `examples/`, `spec/`, `lualib/`)
are reference — but `tests/` doubles as the oracle's behavioral specification.**
They are the oracle's own test/example/spec trees (32 Nelua test files, plus the
Lua spec under `spec/` and the `-g lua` stdlib under `lualib/nelua/`). We
inherit them as reference and ship them; we do **not** run the oracle's test
suite as our gate. Our gates are separate and curated: `plan/cmp.py` (M1
AST-diff floor, 40 inline cases), `plan/regress.py` (M1 corpus + M2 typed-AST
over our own 14-file `tmp/m2_corpus/`, with `.ref` snapshots taken from the
live oracle and *not* derived from `tests/`).

But `tests/` should be used actively: **where the oracle has a test for a
feature, matching that test *is* the parity bar for that feature.** It is the
oracle's own behavioral specification, not inert reference. When scoping a
§11 feature, the first thing to read is the oracle's own test for it — e.g.
`tests/pattern_matching_test.nelua` is the canonical pattern-matching spec
(accepted syntax + expected outputs, both backends). Probe variations around it,
and treat matching `tests/<feature>_test.nelua` as the acceptance criterion.
Also note these tests exercise features *via `require`* (e.g.
`tests/math_test.nelua` requires `math`), so they exercise the module system
too. Do not let `tests/` sit as dead weight — it is the cheapest available
specification of what "match the oracle" means.

**`examples/` is the end-to-end execution gate, and it is the cleanest one we
have.** All 10 `examples/*.nelua` are *standalone programs* (unlike `lib/`,
which the oracle rejects compiled alone), so each is a compile+run parity
target with observable stdout and exit code — no `require` scaffolding needed.
The oracle runs 7 of them to deterministic output (brainfuck `Hello World!`,
fibonacci `55 55 55 55`, helloworld `hello world`, matmul `-18.8963499125`,
mersenne, gameoflife, record_inheretance); 2 are interactive loops killed by
timeout (condots, snakesdl); 1 is illustrative (overview, oracle exits 1). This
is the gate *above* `plan/regress.py` — regress.py checks parse/analyze *shape*
(M1/M2), `examples/` checks that a real program actually *runs* and matches.
Harness: `plan/examples_parity.py` (rebuilds the compiler from `src/` whenever
it is missing or stale, runs each example through the oracle and us, diffs
stdout+exit, SKIPs the 3 non-runnable ones; exit 0 only when all runnable
examples MATCH).

**nelua-decl blocker (2026-08-29).** nelua-decl is a C-binding *generator* for
Nelua that runs **through the gcc-lua plugin**. Vendored as a plain (de-nested)
checkout to match the other vendor dirs — our repo uses no submodules. The
plugin **will not build on this toolchain**: `gcc-lua/gcc/gcclua.c` hits
`#error unsupported DOUBLE_TYPE_SIZE` against GCC 16
(`/usr/lib/gcc/x86_64-pc-linux-gnu/16/plugin/include/system.h:999`). Upstream
edubart/gcc-lua last shipped a fix for GCC 11 (2021); there is no GCC 16 fix.
So the checkout is present and referenceable, but `nldecl.lua` cannot run until
either (a) gcc-lua is patched for modern GCC ABIs (a Nelu job — our fork), or
(b) the build is driven by an older GCC that has the plugin. The GCC plugin
mechanism *is* present on this box (`gcc -print-file-name=plugin` resolves, and
`gcc-plugin.h` exists), so (a) is the nearer path.

Three clean pulls (lua, lfs, rpmalloc), one partial (lpeg), three owned by us,
plus nelua-decl + gcc-lua (vendored, engine blocked on GCC 16).

### 11.5 Publish setup (Nelu → GitHub)

Remote configured for push via the deploy key: `git@github.com:godDLL/nelu.git`
(`git remote set-url origin git@github.com:godDLL/nelu.git` — SSH, because the
deploy key only authenticates over SSH).

Deploy key for pushing: `~/.ssh/id_ed25519_nelu` (no passphrase, comment
`nelua-nelu@cleanroom`). Uploaded to the repo on GitHub.

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