# Nelua Language Understanding

A reference-style summary of the Nelua language as read from `exam/`,
`examples/`, `tests/`, `lib/`, `lualib/`, `docs/`, and `plan/` in this
repository, cross-checked against the oracle `/usr/bin/nelua`
(Nelua 0.2.0-dev, build 1635).

This is a *reading* document, not a spec. It records what the corpus shows
the language to be. Where the clean-room reimplementation (`src/`, Nelu)
diverges from the oracle, that is noted; the oracle is the ground truth
here, because the task is to write a program that verifies against
`/usr/bin/nelua`.

Sections are ordered like a reader encountering the language for the first
time: literals, types, variables, expressions, control flow, functions,
composite types, metamethods, macros/preprocessor, C interop, the standard
library, then known gaps.

Sections 1-17 are the oracle-side description, verified by running
`plan/everything.nelua` (now `exam/everything.nelua`) against `/usr/bin/nelua`
and by spot-checking the oracle's own source in `lualib/nelua/`.  Where an
earlier draft of this doc was wrong, the correction is marked
"Correction from this run."

---

## 1. What Nelua is

Nelua is a statically-typed, ahead-of-compiled language that transpiles to
C (and can also transpile to Lua). It looks like Lua in surface syntax but
is a strict, typed language: every variable has a type that is either
inferred at compile time or written explicitly. Types are structural with
nominal islands. The compiler pipeline is:

```
tokenize -> parse -> preprocess (compile-time Lua) -> analyze (type inference)
         -> codegen (C) -> gcc -> native binary
```

The preprocessor is a compile-time Lua code-generation system. `##` blocks
emit Lua source; `#[expr]#` evaluates a compile-time expression and injects
the resulting AST node; `#|expr|#` evaluates and injects the result as an
identifier name. This is the mechanism behind generics, concepts,
polymorphic functions, and macros.

A program is a sequence of statements. There is no top-level expression
statement; `print 'hi'` works because a call is a statement. The `do ... end`
block is the scope unit. `require 'modname'` loads a standard library module
at compile time.

---

## 2. Lexing and tokens

### 2.1 Reserved keywords

`and break do else elseif end false for function goto if in local nil
nilptr not or repeat return then true until while switch cond defer continue
global require import macro record union enum varargs varautos varanys
cvarargs any auto integer number string boolean isize usize cchar cshort
cint clong cfloat cdouble void type`

Most are reserved. A handful of type/annotation keywords may be used as
ordinary identifiers in the oracle (the coverage table lists 26 such
keywords that the oracle permits as identifiers; Nelu over-reserved them).
Control-flow keywords, literals (`true`/`false`/`nil`/`nilptr`), and
operators stay reserved.

### 2.2 Token kinds

Identifiers, numbers, strings (short and long), `nil`, `nilptr`, `true`,
`false`, keywords, `##` (double hash, preprocessor splice), `#[`
(hash-l-bracket, splice expression), annotations (`<...>`), and punctuation.
`<` is only an annotation when followed by an identifier and then one of
`> , ( { ' " #`; otherwise it is the less-than operator.

### 2.3 Comments

- `--` line comment.
- `--[[ ... ]]` block comment, long-bracket aware.
- `[=[ ... ]=]` and longer `=`-padded long brackets, which match their own
  closing delimiter. This is how you comment out code containing `[[`.

---

## 3. Literals

### 3.1 Numbers

Decimal integers and floats, `0x` hex, `0b` binary. Hex floats use `0x1.9p+1`
style (hex mantissa with binary exponent). Scientific notation `1.2e-100`.

A trailing `_<suffix>` pins the literal's type. Suffixes include `_u`, `_i`,
`_u8`, `_i8`, `_u16` ... `_u128`, `_f32`, `_f64`, `_f128`, `_cchar`, etc.
So `1234_u32` is a uint32, `1_f32` is a float32, `-1_isize` is an isize.

`inf`, `-inf`, `nan`, `-nan` are accepted (they come from splices like
`#[math.huge]#` and lower to `(1.0/0.0)` in C).

A character literal is `'A'_u8` (a byte value from an ASCII character).

### 3.2 Strings

Short strings in `'...'` or `"..."`. Escape set: `\a \b \f \n \r \t \v \\ \" \'`
plus `\z` (skips following whitespace, Lua-style), `\xHH` (hex byte), `\ddd`
(decimal byte), `\u{XXXX}` (UTF-8 codepoint), and `\` at end of line (line
continuation, becomes `\n`).

Long strings `[[ ... ]]`, `[=[ ... ]=]`, etc. Long strings strip their
delimiters and a leading newline. Long strings are the way to write multi-line
string literals and are also the body of `##[[ ... ]]` preprocessor blocks.

A `string` is an immutable, reference-counted, heap-allocated, zero-terminated
buffer viewed as `{data: *[0]byte, size: usize}`. String literals point into
static storage and must never be `:destroy()`d. Operations are 1-indexed like
Lua.

### 3.3 Booleans, nil, nilptr

`true`/`false` (C `bool`), `nil` (the `niltype`, used as a sentinel value),
`nilptr` (a nil pointer, prints as `(null)`, is falsy).

---

## 4. Types

### 4.1 Primitive types

`boolean`, `integer` (= int64), `uinteger` (= uint64), `number` (= double),
`string`, `byte` (= uint8), `isize`, `usize`, `auto`, `any`, `type`, `void`,
`niltype`, `nilptr`, `pointer` (= void*), `cstring` (= const char*).

Fixed-width integers: `int8/16/32/64/128`, `uint8/16/32/64/128`.
Fixed-width floats: `float32`, `float64`, `float128`.
C types: `cchar`, `cschar`, `cuchar`, `cshort`, `cushort`, `cint`, `cuint`,
`clong`, `culong`, `clonglong`, `culonglong`, `cptrdiff`, `csize`,
`cfloat`, `cdouble`, `clongdouble`, `cvalist`, `cvarargs`, `cstring`.

`any` is a by-value tagged union (`nlany`): a tag plus a union of
`b/i/u/n/s/p` (bool/int/uint/num/string/pointer). It is not a pointer.

### 4.2 Composite type forms

- `@record{ field: type, ... }` -- struct. Fields may have default values
  via `field: type = expr`. Records are structural: two records with the same
  field list are the same type.
- `@union{ field: type, ... }` -- union.
- `@enum{ A = 0, B, C }` -- enum; fields auto-increment from the previous
  value. An optional underlying type: `@enum(integer){...}`.
- `[N]T` -- fixed-size array of T with N elements. `[]T` infers N from the
  initializer. `*[0]T` is an unbounded array (only meaningful next to a
  pointer).
- `*T` or `pointer(T)` -- pointer to T. `pointer` alone is void*.
- `span(T)` -- a `{data: *T, size: usize}` view over a contiguous region.
- `function(args...): rets` -- function type. Multiple returns are written
  as `(T1, T2)`.
- `@sequence(T)` -- a generic sequence type; `@sequence(sequence(number))`
  is a 2-D dynamic array. This is a compile-time generic instantiation.
- `T?` optional type -- parsed but semantically inert in the oracle.

### 4.3 Type annotations on types

`<nodecl>`, `<nodce>`, `<cimport>`, `<cincomplete>`, `<ctypedef>`,
`<cinclude 'header'>`, `<aligned N>`, `<packed>`, `<noprivate>`, `<private>`,
`<nomangle>`, `<mangle>`, `<noinfer>`, `<noundce>`, `<forwarddecl>`.

`<cimport,nodecl,cinclude '<stdio.h>'>` on a record makes the record a
transparent alias for the C struct and includes the header. `<forwarddecl>`
marks an incomplete C type (e.g. `C.FILE`).

### 4.4 Type-as-value and sizeof

`@integer`, `@record{...}` etc. produce a value of the `type` type.
`#Type` is the sizeof operator (e.g. `#integer` == 8, `#@record{x:int32,y:int32}` == 8).

---

## 5. Variables

### 5.1 Declaration

`local name: type = expr`. The type may be omitted (inferred from the
initializer or from later assignments over the scope). `local name` with no
initializer zero-initializes (boolean->false, integer->0, number->0.0,
string->"", pointer->nilptr).

`local a: auto = 1` pins the type to the literal's type (integer) and rejects
a later fractional assignment.

`local a <comptime> = 1 + 2` is a compile-time constant, folded at compile
time and usable in type positions (e.g. array sizes).

`local x <const> = 1` is a read-only constant; assigning it is an error.

### 5.2 Multiple assignment

`local a, b = 1, 2` declares two variables. `b, a = a, b` swaps. A function
returning multiple values can be destructured: `local x, y = f()`. The RHS
is evaluated fully before the assignment, so swaps work.

### 5.3 Globals

`global name: type = expr` declares a file-scope symbol visible to every
function. `global function f()` declares a global function. Globals are
heap-allocated (they survive closures). `global Globals = @record{}` makes a
namespace record; `global Globals.AppName: string` adds a field to it.

**Correction from this run:** `global` declarations are only valid at the
true top level -- not inside `do` blocks.

### 5.4 Scoping

`do ... end` opens a new scope; locals declared inside are invisible
outside and may shadow outer names. The top-level (module) scope is special:
locals there live on the heap and are captured by closures.

### 5.5 Annotations on variables

`<comptime>`, `<nocomptime>`, `<noshadow>`, `<static>`, `<dynamic>`,
`<const>`, `<noinit>` (do not zero-initialize), `<noinfer>`, `<noundce>`,
`<nodecl>`, `<cimport>`, `<cexport>`, `<cdefine>`, `<cinclude 'h'>`,
`<cflags ...>`, `<ldflags ...>`, `<linklib ...>`, `<cfile ...>`,
`<pragmapush>`, `<pragmapop>`, `<nopragma>`, `<aligned N>`, `<packed>`,
`<noprivate>`, `<private>`, `<volatile>`.

`<noinit>` leaves the variable uninitialized (must assign before use).
`<volatile>` marks the variable C-volatile.

`<close>` marks a value for automatic `__close` invocation at scope exit.
A record type with a `__close` metamethod is only called on a variable
declared with `<close>`; without it, `__close` is not emitted for that
local (verified).

---

## 6. Expressions and operators

### 6.1 Precedence (low to high)

```
or -> and -> comparison -> bor -> bxor -> band -> shift -> concat
   -> add -> mul -> unary -> power -> postfix -> primary
```

Operators: `or`, `and`, `not`; comparisons `< <= > >= == ~= =`; bitwise
`|` (bor), `~` (bxor), `&` (band); shifts `<< >>`; arithmetic shift-right
`>>>`; concat `..`; `+ -`; `* / // % ^`; truncate `///` and `%%%`; unary
`- # ~ $ &`; postfix `^` (power, right-associative).

`#x` is length (array size, string length, record sizeof). `$p` dereferences
a pointer. `&x` takes the address. `~` is bitwise-not when unary.

### 6.2 Arithmetic semantics

`//` is floor division (Lua semantics, floors toward negative infinity,
implemented as `nlidiv`). `%` is modulo with the sign of the divisor
(`nlmod`). `///` is truncate division, `%%%` is truncate modulo. `^` is
power and produces a float when either operand is a float.

### 6.3 Bitwise operators

`bit_and` (&), `bit_or` (|), `bit_xor` (~), `bit_shl` (<<), `bit_shr` (>>),
`bit_asr` (>>>), `bit_bnot` (~ unary). Operands are promoted to a common
integral type first.

### 6.4 Conversions

Implicit conversion happens for integral widening, nilptr->pointer,
record->pointer-to-record, and storing into `any`. Integer<->float,
integer<->pointer, and narrowing are explicit only. An explicit cast is
`(@number)(i)` or via a `type`-typed symbol: `MyNumber(i)`. Narrow casts
`(@uinteger)(ni)` do no checking.

---

## 7. Control flow

### 7.1 Conditionals

`if cond then ... elseif cond then ... else ... end`. Chained comparisons
are not a single construct; `a < b and b < c` is the idiom.

`switch expr case v1, v2 then ... case v3 then ... else ... end`. A case's
value list is a set of *discrete* values (`case 80, 89` matches 80 or 89,
NOT a range); use repeated values or separate cases for ranges. Cases do not
fall through to the next case on match (verified: `switch 1 case 1,2 then
print "one" case 3 then print "three" end` prints only `one`). `switch` is a
statement, not an expression.

`cond` is a keyword and is parsed but largely unimplemented downstream.

### 7.2 Loops

- `while cond do ... end`.
- `repeat ... until cond` (condition is checked at the end; the loop body
  runs at least once).
- `for i = start, limit do ... end` (inclusive). `for i = start, <limit do ...`
  is exclusive. `for i = start, limit, step do ...` with a step. The loop
  variable is an integer by default; `for i: integer = 0, <N do` pins the type.
- `for i, v in ipairs(x) do ... end` iterates a container. `pairs(x)`,
  `next, x, -1` (reverse), and `mpairs`/`mipairs`/`mnext` (modifiable
  variants that yield references via `$v`) are also available. The oracle
  supports iterating arrays, spans, sequences, vectors, lists, hashmaps,
  strings (via `pairs`/`next` over bytes), and filestreams (lines).
- `continue` skips to the next iteration. `break` exits the loop.

### 7.3 Other statements

- `do ... end` scope block. A `do` *expression* is `(do ... in value end)` — it
  yields a value via an `in` statement, NOT a `return`. `return` inside a
  do-expression is rejected ("a `in` statement is missing inside do
  expression block"); the block must syntactically end with an `in`. Verified:
  `(do if x then in "a" else in "b" end)` works.
- `goto label` / `::label::` -- arbitrary control flow; labels are
  scope-local.
- `defer ... end` -- the block runs when the enclosing scope exits, in
  reverse declaration order. Defers interact with `return`, `break`,
  `continue`, and nested blocks.
- `return exprs` (zero, one, or multiple values).
- `break`, `continue`.

---

## 8. Functions

### 8.1 Definitions

`local function f(a: T, b: U): R ... end`. The return type is optional and
inferred from the return statements. A function with no `return` is `void`.
Multiple returns: `function f(): (A, B) ... return a, b end`.

`global function f()` defines a file-scope function.

### 8.2 Methods

`function Rect:method(args) ... end` defines a method; inside, `self` is a
pointer to the receiver type (`*Rect`). Call syntax `v:method(...)` is
`Rect.method(v, ...)` with auto-referencing of `v`. `function
Rect.create(...)` is a "static" record function called as `Rect.create(...)`.
Colon-methods inject an explicit `self: *Record` parameter.

### 8.3 Properties

- Recursive functions work directly (the function name is in scope in its
  own body).
- Multiple return values: `local a, b = f()`. A call that returns multiple
  values used in a single-value position takes the first value.
- Anonymous functions: `function(x: integer): integer return 2*x end` as an
  expression, passed as an argument.
- Nested functions close over enclosing locals (closures). **Correction from
  this run:** the oracle's C generator does NOT support closures — accessing
  an enclosing-scope local from a nested function is the error
  "attempt to access upvalue '...', but closures are not supported". A nested
  function may use only its own parameters and globals. Verified.
- Varargs: `...: varargs` declares a varargs parameter. `select(i, ...)`
  picks the i-th argument (1-indexed); `select('#', ...)` is the count.
  `#[select(i, ...)]#` evaluates a splice at compile time.
- Polymorphic functions: a parameter typed `auto` is monomorphized per call
  site. `local function add(a: auto, b: auto) return a + b end` specializes
  to `add(integer,integer)` for `add(1,2)` and `add(number,number)` for
  `add(1.0,2.0)`.

### 8.4 Return-type inference and the preprocessor

Return types are inferred by collecting all `return` expressions and
unifying. The preprocessor can branch on argument types inside a function
body with `## if x.type.is_integral then ... ## elseif x.type.is_float then
... ## end`, which is how polymorphic functions get per-type bodies.

---

## 9. Composite types in detail

### 9.1 Records

`local Person = @record{ name: string, age: integer }`. Initialization
forms:

- Typed: `local p: Person = {name = "John", age = 20}`.
- Cast: `local p = (@Person){name = "John", age = 20}`.
- Ordered: `local p = (@Person){"John", 20}` (fields in declaration order).
- Late: `local p: Person; p.name = "John"; p.age = 20` (zero-init then set).
- Nested records: a field whose type is an inline `@record{...}`.

Records support methods, metamethods, and `__kind`-based manual inheritance
(see `examples/record_inheretance.nelua`).

### 9.2 Unions

`local IntOrFloat = @union{ i: int64, f: float64 }`. Accessing a field
other than the one written reads garbage. `@union` fields may be unnamed.

### 9.3 Enums

`local Weeks = @enum{ Sunday = 0, Monday, ... }`. Fields are compile-time
constants. Enum values are used in `switch` and compared with `==`. An enum
can have an explicit underlying type.

### 9.4 Arrays

`local a: [4]integer = {1,2,3,4}`. Indexing is 0-based. `#a` is the declared
length. `local b: []integer = {1,2,3,4}` infers length 4. Multidimensional:
`[2][2]number`. Unbounded arrays `*[0]integer` appear only as the target of
`&array` for pointer arithmetic.

### 9.5 Pointers

`local p: *integer`. `&x` takes the address; `$p` dereferences. Assignment
through a pointer uses `$p = v`. Auto-referencing: a `*T` parameter accepts
`&value` implicitly; a `T` parameter accepts `$pointer` implicitly. Methods
auto-reference the receiver.

### 9.6 Spans

`span(T)` is `{data: *T, size: usize}`. `local s: span(integer) = &arr`
views an array. `s:sub(start, end)` returns a sub-span. `#s` is the size.
Spans are the common interface for the memory/standard library.

---

## 10. Metamethods

Metamethods are functions on a record type that overload operators and
dispatch. Defined as `function Vec2.__add(a, b) ... end` (binary) or
`function Vec2:__len() ... end` (unary, via `self`).

Wired in the oracle: `__add __sub __mul __div __mod __pow __unm __bnot __len
__tostring __call __index __gc __close __eq __lt __le __concat __band __bor
__bxor __shl __shr __asr`. `__index` is the field-access fallback for
records without a direct field. `__call` lets a record value be called like
a function. `__gc` is a finalizer. `__close` is a scoped-resource
finalizer (used with `defer ... end` on a `__close` value).

---

## 11. Concepts, overloads, facultative, generics

### 11.1 Concepts

`#[concept(function(attr) return attr.type.is_scalar end)]#` produces a
concept type. A function parameter typed with a concept is only valid at a
call site where the concept function returns true (or a type). A concept
may return `false, 'error message'` for a diagnostic, or return a type to
force the argument's implementation type.

### 11.2 Overload

`overload(integer, string, niltype)` accepts any of those types at a call
site; the body branches on `x.type.is_integral` etc. via `## if`.

### 11.3 Facultative

`facultative(T)` accepts T or `nil` (niltype). The body branches on
`x.type.is_niltype`.

### 11.4 Generics

`generalize(function(T, maxsize) ... ## return FixedStackArrayT ## end)`
produces a generic type. `local FixedStackArray: type =
#[make_FixedStackArrayT]#` binds it; `FixedStackArray(integer, 3)` instantiates.
`@sequence(T)` is the built-in generic sequence type.

---

## 12. The preprocessor

The preprocessor runs at compile time and transforms the AST using Lua.

### 12.1 Splice forms

- `#[expr]#` -- evaluate `expr` in the preprocessor environment; inject the
  resulting value as an AST node at this position. `#[1 + 2]#` injects the
  number 3. `#[aster.Number{1}]#` injects an AST node directly.
- `#|expr|#` -- evaluate; inject the string result as an identifier name.
  Valid where an identifier is syntactically required: `global #|name|#.field`,
  `goto #|name|#`. **Correction:** `::#|name|#::` labels only work inside
  preprocessor-emitted text (the parser's `Label` rule is `::` @name `::` and
  does not accept a splice); a bare `::#|name|#::` in source is a syntax
  error. A computed name works: `## local p = "x"` then
  `global #|p .. "_v"|#: integer = 42`.
- `## code` (short form, to end of line) and `##[[ ... ]]` (long form) --
  emit the content verbatim as Lua code in the generated preprocessor chunk.

### 12.2 Preprocessor functions and directives

Inside `##` blocks: `static_assert(cond, msg...)`, `static_error(msg...)`,
`cinclude '<stdio.h>'`, `cemitdecl '...'`, `cemit '...'`, `cemitdefn '...'`
(NOT `cemitdef`), `cdefine 'NAME VALUE'` (the text *after* `#define`, so
`cdefine 'NELEVERYTHING_MAGIC 42'` emits `#define NELEVERYTHING_MAGIC 42`),
`cflags '-O2'`, `ldflags '...'`, `linklib 'm'`, `cfile 'foo.c'`,
`pragmapush`, `pragmapop`. Also `inject_astnode(node)`,
`inject_statement(node)`, `hygienize(func)`, `generic(func)`,
`concept(func)`, `generalize(func)`, `expr_macro(func)`,
`after_analyze(func)`, `after_inference(func)`, `require 'mod'`.

`ccinfo.is_gcc` / `is_clang` / `is_emscripten` / `is_wasm` / `is_linux` /
`is_unix` probe the host compiler. `config.output_dir`, `pragmas.nogc`,
`pragmas.nochecks` are available.

### 12.3 Macro patterns

- Function macros: `## function mul(res, a, b) #[res]# = #[a]# * #[b]# ## end`,
  invoked as `#[mul]#(res, a, b)`.
- Expression macros: `## local mul = expr_macro(function(a,b) return #[a]#*#[b]# ## end)`, used as `#[mul]#(a,b)`.
- Generic code: `## function Point(PointT, T) local #|PointT|# = @record{...} ... ## end` then `## Point('PointFloat','float64')`.

### 12.4 Gradual preprocessing

`##` blocks do not all run up front. A `##` block inside a function body
runs when the analyzer visits that function, so it can see the argument
types. This is what makes `## if x.type.is_integral then` work inside a
function that has not yet been fully analyzed.

---

## 13. C interop

### 13.1 Importing C declarations

A Nelua function with no body and the `<cimport>` annotation imports a C
function:

```
local function puts(s: cstring <const>): cint <cimport 'puts', nodecl, cinclude '<stdio.h>'> end
```

The string argument to `<cimport>` is the C name (defaults to the Nelua
name). `<nodecl>` suppresses the Nelua-side declaration (the header provides
it). `<cinclude '<stdio.h>'>` includes the header. `<cimport>` alone generates
a Nelua declaration plus an `extern` C definition.

Records can be imported too: `local FILE: type <cimport,cinclude'<stdio.h>',forwarddecl> = @record{}`. Constants: `local EOF: cint <const,cimport,cinclude'<stdio.h>'>`.

### 13.2 Emitting C

`## cemitdecl '...'` emits into the declarations section; `## cemit '...'`
emits inside the current function; `## cemitdefn '...'` emits a top-level
definition. `## cdefine 'X'` adds a C preprocessor macro. `## cflags '...'`
and `## ldflags '...'` add compiler/linker flags. `## linklib 'm'` links a
library. `## cfile 'foo.c'` compiles an extra C file.

### 13.3 C modules

`require 'C.stdio'` loads the bundled C standard library wrappers: `C.fopen`,
`C.fread`, `C.fwrite`, `C.fclose`, `C.printf`, `C.putchar`, `C.getchar`,
`C.scanf`, `C.memcpy`, `C.memcmp`, `C.strlen`, `C.malloc`, `C.free`, `C.exit`,
`C.atof`, `C.atoi`, `C.time`, `C.localtime`, `C.strftime`, `C.va_start`,
`C.va_arg`, `C.va_end`, `C.mtx_init`, `C.thrd_create`, `C.atomic_fetch_add`,
`C.isnan`, `C.isinf`, `C.NAN`, `C.INFINITY`, etc. These are grouped under
the `C` namespace record.

---

## 14. Annotations (function and variable)

`<inline>`, `<noinline>`, `<comptime>`, `<nocomptime>`, `<noinfer>`,
`<noinit>`, `<noshadow>`, `<static>`, `<dynamic>`, `<const>`, `<volatile>`,
`<noreturn>`, `<nosideeffect>`, `<sideeffect>`, `<nodecl>`, `<nodce>`,
`<cimport>`, `<cexport>`, `<cdefine>`, `<cinclude 'h'>`, `<ctypedef>`,
`<cincomplete>`, `<forwarddecl>`, `<cflags ...>`, `<ldflags ...>`,
`<linklib ...>`, `<cfile ...>`, `<pragmapush>`, `<pragmapop>`, `<nopragma>`,
`<aligned N>`, `<packed>`, `<noalias>`, `<alias>`, `<noundce>`, `<nomangle>`,
`<mangle>`, `<noprivate>`, `<private>`, `<nogc>` (pragma).

`<close>` (variable annotation) marks a value for automatic `__close`
invocation at scope exit. A record type with a `__close` metamethod is only
called on a variable declared with `<close>`; without it, `__close` is not
emitted for that local (verified).

`<noreturn>` marks a function that never returns (e.g. `error`, `panic`,
`os.exit`); the analyzer then does not require a return on the fall-through
path.

---

## 15. Builtins

`print(...)`, `error(msg)`, `panic(msg)`, `assert(cond, msg?)`,
`check(cond, msg?)`, `warn(...)`, `likely(x)`, `unlikely(x)`, `nilptr`,
`require(modname)`, `tostring(v)`, `tonumber(v)`,
`type(v)`, `pcall(f, ...)`, `collectgarbage(arg)`, `next(container, key?)`,
`pairs(container)`, `ipairs(container)`, `len(v)`, `unpack(v)`,
`setmetatable(t, mt)`, `getmetatable(v)`, `rawget(t, k)`, `rawset(t, k, v)`,
`rawlen(v)`, `rawequal(a, b)`, `_VERSION`.

`select` is **not** a builtin; it is provided by `require 'iterators'`
(`select(index <comptime>, ...: varargs)`). Note `select('#', ...)` (the
count) works, but `select(i, ...)` value-extraction over *untyped* varargs
hits a bug in the iterators module ("bad argument #1 to 'abs'") in this
oracle build, so it is avoided in the example.

`print` converts each argument via `__tostring` and separates with tabs,
ending with a newline. `assert` returns its first argument or terminates
with a message. `check` is like assert but flagged for the analyzer.
`error`/`panic` terminate the program. `warn` writes to stderr.

---

## 16. Standard library modules

All loaded with `require 'modname'`. Modules are files under `lib/`.
Sub-modules use dotted names: `require 'allocators.default'`, `require 'C.stdio'`.

### 16.1 Core modules

- **`math`**: `abs acos asin atan ceil cos cosh deg exp floor fmod frexp ldexp
  log log10 max min modf pow rad random randomseed sin sinh sqrt tan tanh
  huge maxinteger mininteger pi`. `math.random()` returns a float in [0,1);
  `math.random(a,b)` returns an integer in [a,b]. `math.huge` is inf.
- **`string`**: `create(size)`, `:destroy()`, `:sub(i,j)`, `:subview(i,j)`
  (zero-based view), `:find(pat, init)`, `:findview(...)`, `:matchview(pat,
  init) -> ok, captures`, `:format(...)`, `:upper()`, `:lower()`, `:rep(n)`,
  `:byte(init, end)`, `:len()`, `:reverse()`, `:pack(fmt, ...)`,
  `:unpack(fmt, s) -> i, ...`, `:packsize(fmt)`, `:match`, `:gmatch`,
  `:gsub`, `:dump()`. `string.format` is the printf-like formatter.
- **`io`**: `io.open(filename, mode) -> file, err, code`, `io.popen(cmd)`,
  `io.stdin/io.stdout/io.stderr`, `io.type(f)`, `io.close(f?)`, `io.lines(filename)`,
  `io.output(f?)`, `io.input(f?)`, `io.write(...)`, `io.writef(fmt, ...)`,
  `io.read(...)`, `io.flush()`. Filestreams support `:read(mode)`, `:write(...)`,
  `:seek(whence, offset)`, `:lines(...)`, `:setvbuf(mode)`, `:isopen()`,
  `:close()`, `:destroy()`.
- **`os`**: `os.clock()`, `os.difftime(t1,t0)`, `os.getenv(name)`,
  `os.date(spec?)`, `os.execute(cmd?)`, `os.tmpname()`, `os.rename(old,new)`,
  `os.remove(name)`, `os.setlocale(loc, category?)`, `os.time(t?)`,
  `os.now()`, `os.sleep(seconds)`, `os.exit(code?)`, `os.tmpname()`.
  `os.timedesc{year,month,day,hour,min,sec,isdst}` is the time spec.
- **`memory`**: `copy/move/set/zero/compare/equals/scan/find` on raw pointers;
  `spancopy/spanmove/spanset/spanzero/spancompare/spanequals/spanfind` on
  spans. `memory.copy(dest, src, n)` takes dest first (counter-intuitive;
  mirrors C `memcpy`).
- **`traits`**: `traits.typeidof(v) -> uint32`,
  `traits.typeinfoof(v) -> {id,name,nickname,codename}`. The type-name query
  is the *global* `type(v) -> string` (a builtin, not `traits.type`).
- **`iterators`**: `ipairs/pairs/next` and the modifiable `mpairs/mipairs/mnext`.
- **`hash`**: `hash.short(data: span(byte))`, `hash.long(...)`,
  `hash.combine(seed, value)`, `hash.hash(v)`.
- **`arg`**: the global `sequence(string)` of command-line arguments;
  `arg[0]` is the program name, `arg[1..#arg]` are the args.
- **`builtins`**: documentation only; do not require.
- **`table`**: not implemented (`static_error 'tables are not implement yet'`).
- **`errorhandling`**: experimental `pcall`/`xpcall`; requires a compiler
  plugin and emits `nelua_error_status` checks.

### 16.2 Containers

- **`span(T)`**: `{data, size}`, `:sub(i,j)`, `:valid()`, iterable.
- **`vector(T, Allocator?)`**: dynamic array, 0-indexed. `:push/pop/insert/
  remove/removevalue/removeif/resize/reserve/clear/copy/destroy`, `#vec`,
  `vec[i]`. Braces initializer `{1,2,3}`. `@vector(int64, *Allocator)` is a
  custom-allocator vector type.
- **`sequence(T, Allocator?)`**: 1-indexed dynamic array. `seq[0]` is a
  sentinel slot. `:push/pop/insert/remove/removevalue/removeif/resize/reserve/
  clear/copy/destroy`, `#seq`, `seq[i]`. `@sequence(T)` is the generic form.
- **`list(T, Allocator?)`**: doubly-linked list of nodes. `:pushback/pushfront/
  popback/popfront/insert/erase/clear/find/empty`, `l.front/l.back`, `#l`,
  `next(l, node)`, `pairs/mpairs`.
- **`hashmap(K, V, HashFn?, Allocator?)`**: `map[k] = v`, `map[k]`, `map:peek(k)`,
  `map:remove(k)`, `map:reserve(n)`, `map:rehash(n)`, `#map`, `map:capacity()`,
  `map:bucketcount()`, `map:loadfactor()`, `pairs/mpairs`. Strings are valid keys.
- **`stringbuilder`**: `:write(...)`, `:writebyte(b)`, `:writef(fmt,...)`,
  `:prepare(n)`, `:commit(n)`, `:resize(n)`, `:clear()`, `:view()`, `#sb`,
  `tostring(sb)`, `:destroy()`. `@stringbuilder(*Allocator).make(&alloc)`.

### 16.3 Allocators

`allocators.default` (GC or general), `allocators.general` (malloc/free),
`allocators.gc` (Boehm-style GC), `allocators.arena`, `allocators.stack`,
`allocators.pool`, `allocators.heap`, `allocators.aligned`. The `Allocator`
protocol: `:new(type, size?, flags?) -> *T`, `:delete(p)`, `:xalloc(size)`,
`:xalloc0(size)`, `:xrealloc(p, size, oldsize)`, `:xrealloc0(...)`,
`:spanalloc(type, n)`, `:spanalloc0(...)`, `:spanrealloc(...)`,
`:spanrealloc0(...)`, `:spandealloc(...)`. Global `new(...)`/`delete(p)` are
shorthands for the default allocator.

### 16.4 GC

There is **no `gc` module file** in this build (`require 'gc'` fails); GC
control is via the `collectgarbage(arg)` builtin:
`collectgarbage("isrunning")`, `collectgarbage("stop")`,
`collectgarbage("restart")`, `collectgarbage()`,
`collectgarbage("collect")`, `collectgarbage("count")`. A record may define
`:__gc()` as a finalizer. The pragma `nogc` disables the GC and requires
manual `:destroy()`.

### 16.5 Coroutines

`coroutine.create(f)`, `coroutine.spawn(f, args...)` (runs the first step
immediately and returns the suspended coroutine), `coroutine.resume(co, ...)`,
`coroutine.yield(...)`, `coroutine.status(co) -> 'running'/'suspended'/'dead'`,
`coroutine.running()`, `coroutine.isyieldable(co)`, `coroutine.pop(co, &vars...)`,
`coroutine.destroy(co)`. Values pass through `resume`->`yield` and `yield`->
`pop`/`resume`.

### 16.6 UTF-8

`utf8.char(...)`, `utf8.codes(s) -> pos, codepoint`, `utf8.codepoint(s, i)`,
`utf8.offset(s, i)`, `utf8.len(s) -> count or -1, realcount`. `utf8.charpattern`
is an LPeg pattern matching one UTF-8 character.

### 16.7 C submodules

`require 'C.stdio'`, `C.stdlib`, `C.math`, `C.string`, `C.ctype`, `C.errno`,
`C.signal`, `C.time`, `C.locale`, `C.stdarg`, `C.stdatomic`, `C.threads`,
`C.arg`. Each exposes the C standard library functions and types under the
`C` namespace.

---

## 17. Program structure and runtime

A compiled program defines `nelua_main()` (the entry) and `main()` calls it.
The runtime (linked from `src/runtime.c` in Nelu, or generated inline in the
oracle) provides `nlstring`, `nilptr`, `nlany`, the typed `nelua_print_*`
helpers, `nlstr`, `nlstring_concat/free`, `nlidiv`/`nlmod`/`nlpow`/`nllen`,
and the narrow-check helpers.

Exit codes: signal death (128-159) is mapped to 255. `error`/`panic` print a
message and exit non-zero.

---

## 18. Known gaps (oracle vs Nelu)

Recorded here because they affect what a "everything" program can do under
each compiler.  Re-measured 2026-09-06 against the live tree; items marked
FIXED were false alarms or already repaired, and are kept for the record.

1. ~~The Nelu compile driver does not run the preprocessor...~~ **FIXED.**
   `preprocess` now runs inside `analyze` (`src/analyzer.nim:2465-2477`), so
   every pipeline inherits it; `## x = 7` + `#[x]#` -> `7` MATCH.
2. **STILL OPEN.** `#|expr|#` computed-identifier splice: the parser is missing
   `.#|expr|#`, the preprocessor consumes the node instead of evaluating it,
   and the analyzer never resolves it. Blocks hash/math/utf8/sequence/
   coroutine/string (7 lib files). `##[[ ... ]]` long-form blocks work.
3. Nelu's `for ... in` iterator form is not supported; the oracle supports
   it over arrays, spans, sequences, vectors, lists, hashmaps, strings.
4. ~~Nelu has no "undeclared symbol" diagnostic...~~ **FIXED.**
   `print(undefned_symbol)` now emits `error: undeclared symbol 'undefned_symbol'`
   MATCH (was silently `any`-typed before).
5. ~~Nelu's typed-record-literal lowering is broken for the cast form
   `(@T){...}`...~~ **FIXED 2026-09-06.** The cast form now routes through the
   constructor path: analyzer.nim analyzes the initlist against the cast target
   and flags the call as a constructor, and cgen.nim emits the `union` keyword
   for union targets (previously always `struct`, which gcc rejected). Named,
   mixed-order, union, and bare forms all MATCH the oracle. See
   `plan/DONE/typed-record-literal-cast.md` and `exam/cast_record.nelua`.
   (The bare constructor `T{...}` already worked; the crash was a misreported
   symptom of the same C-gen bug.)
6. Nelu's `T?` optional-type syntax is parsed but inert.
7. Nelu's `cond` keyword is parsed but not implemented.
8. Nelu's `tkTable`/`tkVariant`/`tkGeneric`/`tkConcept` have spellings but no
   complete lowering path.
9. ~~Nelu's emitter segfaults on some method calls, anonymous functions, and
   if/elseif chains in the print-AST paths...~~ **FIXED.** Anonymous functions
   in expression position now land via the function-literal-as-value fix;
   method calls and if/elseif were already MATCH.
10. ~~`lib/*.nelua` standard modules do not all compile under Nelu because of
    the preprocessor gaps above...~~ **PARTIAL.** The driver-wiring gap (#1) is
    closed; the remaining blocker is the `#|name|#` splice (#2). Baseline
    0/21 compile; re-scan after #2 lands.
11. A do-expression yields via `in expr`, not `return`; `return` inside one
    is rejected.
12. Closures (nested functions reading enclosing locals) are not supported in
    the C generator; only the Lua generator supports them.
13. `select(i, ...)` value-extraction over untyped varargs crashes the
    iterators module; `select('#', ...)` count works.
14. `case v1, v2` in `switch` matches discrete values, not ranges.
15. `__close` on a record is only emitted for variables declared `<close>`.
16. `global` declarations are only valid at the true top level (not inside
    `do` blocks).
17. `::#|name|#::` labels only work inside preprocessor-emitted text.
18. `cdefine` takes the text *after* `#define`; the C-emit function is
    `cemitdefn`, not `cemitdef`.
19. There is no `gc` module; `traits.type` does not exist (use global
    `type()`); `select` comes from `require 'iterators'`.
20. `memory.copy(dest, src, n)` takes dest first (counter-intuitive).

---

## 19. Where the corpus lives

- **`exam/everything.nelua`** -- the single all-encompassing example program
  this document describes. Compiles and runs cleanly under the oracle
  `/usr/bin/nelua` (exit 0, 108 lines of output); each section prints a banner
  and its results.  It is the executable companion to this doc: every section
  here has a corresponding block there.  Under Nelu it currently fails at the
  `goto`/`::label::` block (see `plan/INBOX/our-improvements.md`), so it is a
  growing-edge probe, not yet a parity gate.
- `examples/overview.nelua` -- upstream's canonical "everything" example.
  The single best reference for the language.
- `examples/record_inheretance.nelua` -- compile-time inheritance via the
  preprocessor (`## class(...)`, `## override()`, `#|name|#`, `##[[...]]`).
- `examples/condots.nelua` -- heavy C interop (SDL2) and comptime arrays.
- `examples/brainfuck.nelua` -- `##[=[ ... ]=]` nested long brackets and
  `#|name|#` name injection.
- `tests/*.nelua` -- one probe per subsystem (io, libc, memory, span,
  stringbuilder, pack, pattern-matching, traits, coroutine, defer, gc,
  hashmap, hash, list, math, os, sequence, threads, utf8, vector,
  allocators, builtins, require).
- `exam/*.nelua` -- small one-construct probes for every keyword, operator,
  type, cast, and splice form.
- `lib/*.nelua` -- the standard library source, the best API reference.
- `lualib/nelua/` -- the oracle compiler's own implementation in Lua.