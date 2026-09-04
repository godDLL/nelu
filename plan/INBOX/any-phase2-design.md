# Nelua `any` phase 2  -  tagged-representation design (Nelu, beyond-oracle)

**Status:** design spec for the implementer. Phase 1 (rejection) is integrated and
green; this doc specifies phase 2 (a real, runtime `any` on the C backend).

**Oracle:** `/usr/bin/nelua` (0.2.0-dev). It does **not** support `any` as a
variable / parameter / return type; it rejects with
`compiler deduced type 'any' here, but it's not supported yet, please fix this
variable type`. See `plan/oracle-any-behavior-design.md`.

**Our compiler:** `tmp/nelua` (built `nim c -d:release --path:src -o:tmp/nelua
src/main.nim`).

**Scope rule:** this is a Nelu extension, not oracle parity. The acceptance bar
is: **our compiler accepts `any` programs and emits correct C that runs with
the right output.** No probe is expected to match the oracle on `any`; the
oracle rejects every `any` construct.

**Read-only on `src/`.** This doc is the deliverable; the implementer edits
`src/` per §5. Every line target below was verified against the sources at HEAD
(c137f8e) by reading, and every behavioral claim below was verified by running
`tmp/nelua` on a probe.

---

## 1. Survey  -  what our compiler does with `any` today

All runs are `./tmp/nelua tmp/any2/<file>` (our compiler) vs
`/usr/bin/nelua tmp/any2/<file>` (oracle). Exit codes captured.

### 1.1 The five task probes

| probe | source | oracle (C) | ours (today) | rejects at |
|---|---|---|---|---|
| `p_store` | `local x: any = 5; print(x)` | E, exit 1 | E, exit 1 | analyzer `analyzeVarDecl` |
| `p_pass` | `local function f(a: any) return a end; print(f(7))` | E, exit 1 | E, exit 1 | analyzer `analyzeFuncDef` (param) |
| `p_return` | `local function f(): any return 5 end; print(f())` | E, exit 1 | E, exit 1 | analyzer `analyzeFuncDef` (return) |
| `p_assign` | `local x = 5; local y: any = x; print(y)` | E, exit 1 | E, exit 1 | analyzer `analyzeVarDecl` |
| `p_untyped` | `local function f(a) return a end; print(f(3))` | E, exit 1 | E, exit 1 | analyzer `analyzeFuncDef` (untyped param deduces to `any`) |

Verbatim ours output for each (all five are identical in shape):

```
nelua: unable to analyze tmp/any2/p_store.nelua:
/* nelua: tmp/any2/p_store.nelua: error: compiler deduced type 'any' here, but it's
not supported yet, please fix this variable type */
exit=1
```

The message text is byte-identical to the oracle's. The wrapping
(`nelua: unable to analyze ...` / `/* nelua: ... */`) is our compiler's standard
analyzer-diagnostic channel, shared by every analyzer diagnostic (preprocessor
`#error`, `require` failures, etc.); it is not `any`-specific.

### 1.2 Variant probes (what must be preserved / what is out of scope)

| probe | source | ours today | verdict for phase 2 |
|---|---|---|---|
| `v_initlist` | `local x: any = {}` | E: `type 'any' cannot be initialized using an initializer list` (exit 1) | **preserve.** The oracle rejects this on both backends. Phase 2 keeps this rejection. |
| `v_initbool` | `local x: any = true` | E: `compiler deduced type 'any' here...` (exit 1) | phase 2 accepts (BOOL store). |
| `v_initstr` | `local x: any = "s"` | E: `compiler deduced type 'any' here...` (exit 1) | phase 2 accepts (STRING store). |
| `v_tablvar` | `local t = {}; local x: any = t` | E: `compiler deduced type 'any' here...` (exit 1) | phase 2 accepts (TABLE/POINTER store). |
| `v_typeval` | `local x = any; print(x)` | E at parse: `unexpected keyword 'any'` (exit 1) | **out of scope.** `any` as a *type value* is a lexer/parser gap (our lexer always treats `any` as a keyword). Not a phase-2 target; the five probes never use `any` as a value. |

### 1.3 Where each construct currently fails

All five probes fail at **analysis**, never at codegen. There is no `any` value
in flight to lower. The three rejection sites (verified by reading
`src/analyzer.nim`) are:

1. **Variable declarations**  -  `src/analyzer.nim:942`. The block at 938-947
   rejects any `vtype.kind == tkAny` from `analyzeVarDecl`. The
   `nkInitList` sub-case at 944-945 emits the distinct initializer-list message
   and must be preserved.
2. **Function parameters**  -  `src/analyzer.nim:1271`. Rejects any param whose
   type is `any`, covering both explicit `a: any` and the untyped `a` (which
   the code above at 1268 defaults to `BuiltinTypes["any"]`).
3. **Explicit return annotations**  -  `src/analyzer.nim:1280`. Rejects
   `function f(): any`. Does **not** touch the *deduced* return path at
   1342-1356, which is relevant to `p_pass`/`p_untyped` (see §6).

There is no `any` handling in `src/cemitter.nim` (grep finds zero hits) and the
only `any` case in `src/cgen_types.nim` is `of tkAny: "void"` at line 127 (the
phase-1 deletion target). `src/cgen.nim` has no `tkAny` case anywhere.

---

## 2. What phase 1 already integrated (recap, for context)

Phase 1 (`ab25f53204e590c7`, marked DONE in `NOTE_backlog.md:124`) is the
**parity floor**: it makes our compiler reject deduced `any` with the oracle's
exact message, instead of emitting broken C. Concretely, today:

- `src/cgen_types.nim:127`  -  `of tkAny: "void"` (was `"void*"`). This is the
  deliberate "no broken lowering" spelling; a variable of type `any` never
  reaches codegen because the analyzer rejects it first.
- `src/cgen.nim:59`  -  `typedef void* nlany;` in the embedded preamble. This is
  the leftover placeholder; phase 2 replaces it with the real struct.
- `src/analyzer.nim:942`, `:1271`, `:1280`  -  the three rejection blocks.
- `src/cgen_types.nim:279`  -  `doAssert cType(anyT) == "void"`.

Phase 2 is additive: it turns the rejections into support. No existing program
uses `any` on the C backend (the oracle rejects it), so phase 2 breaks nothing
that currently runs. `plan/examples_parity.py` and `plan/regress.py` must stay
green by construction.

---

## 3. Tagged representation design

### 3.1 The C type

One word of tag + one word of payload for scalars. Strings live inline as the
existing `{data, size}` pair (already a 16-byte heap-owning handle), so no new
heap scheme is needed.

```c
typedef enum {
  NLANY_NIL = 0,   /* must be zero: an all-zeroes `any` is `nil` */
  NLANY_BOOL,
  NLANY_INT,       /* int64_t  (all signed integrals widen here) */
  NLANY_UINT,      /* uint64_t (all unsigned integrals widen here) */
  NLANY_NUM,       /* double   (all floats widen here) */
  NLANY_STRING,    /* nlstring */
  NLANY_POINTER,   /* void* (nilptr, pointer values, function pointers) */
  NLANY_TABLE,     /* table handle */
  NLANY_FUNC,      /* function pointer */
  NLANY_TYPE       /* type descriptor (const nltype*) */
} nlany_tag;

typedef struct {
  nlany_tag tag;
  union {
    uint8_t  b;   /* bool */
    int64_t  i;   /* int */
    uint64_t u;   /* uint */
    double   n;   /* num */
    nlstring s;   /* string */
    void*    p;   /* pointer / table / func / type */
  } as;
} nlany;
```

`sizeof(nlany)` is 24 bytes (tag 4 + 4 pad + 16-byte union), aligned to 8.

### 3.2 Design decisions and why

- **Two integer tags (INT + UINT), not one.** A single `int64_t` slot cannot
  round-trip a `uint64` value above `INT64_MAX` without silent sign flip.
  Separating them is lossless and makes `print` dispatch honest (an unsigned
  value prints via `nelua_print_uint64`, not as a negative integer).
- **`NLANY_NIL = 0`.** Lets an all-zeroes `nlany` (e.g. `nlany x = {0};`, the
  default for an uninitialized `local x: any`) be `nil` with no runtime work.
  This matches the oracle's Lua-backend rule that an uninitialized `any` is
  `nil`.
- **Scalars inline, no heap allocation.** `any` is a value type, not a box.
  Storing `5` into an `any` is one 24-byte struct copy, no malloc.
- **`nlstring` inline in the union.** Strings are already `{data, size}`
  handles; an `any` holding a string holds that handle. No new string ownership
  rules: the string's lifetime is whatever the source string had.
- **Function pointers share the `void*` slot (`NLANY_POINTER`).** Calling an
  `any` that holds a function needs the signature, which is not statically
  known; `any(...)` is therefore deferred to phase 2b (see §7). Storing a
  function value into `any` (e.g. `local x: any = print`) is supported via
  `nlany_from_ptr`.
- **`any` is passed and returned by value.** 24 bytes is above the x86-64
  register-return cutoff (2 eightbytes), so `any` values move in memory. This
  is correct and acceptable for a dynamic type; nobody writes hot loops over
  `any`.
- **No `any` metamethods, no `any`-typed record/union fields, no iterating an
  `any`.** All deferred behind `record`/`union`/`table` (see
  `plan/INBOX/any-intended-design.md` §3).

### 3.3 What phase 2 explicitly does NOT do

- Does **not** make `any` the default deduction target (forbidden by
  `language-review.md` §11.0c; would silently change every program).
- Does **not** accept `local x: any = {}` (table *literal*). The oracle rejects
  it on both backends and no running program needs it. A table *variable*
  assigned to `any` is fine (`v_tablvar`).
- Does **not** replicate the oracle's Lua-backend type-value globals (they are
  `nil` there; that is undefined behavior, see `oracle-any-behavior-design.md`
  §Surprise 1).
- Does **not** implement `any` arithmetic (`any + any`, `any .. any`) in the
  minimal slice. It is designed (§4.3) but not emitted until phase 2b.

---

## 4. Runtime dispatch  -  C helpers to add to `src/runtime.c`

All helpers are `extern` (non-static), declared in the `cgen.nim` preamble, and
defined here. Signatures and semantics:

### 4.1 Construction (typed value -> any). Used by the `T -> any` store path.

```c
nlany nlany_from_nil(void);
nlany nlany_from_bool(uint8_t v);
nlany nlany_from_int(int64_t v);
nlany nlany_from_uint(uint64_t v);
nlany nlany_from_num(double v);
nlany nlany_from_string(nlstring v);
nlany nlany_from_ptr(void* v);
```

Each sets `tag` to the matching `NLANY_*` and writes the payload into `as`,
then returns the struct by value. `nlany_from_nil()` returns
`{ NLANY_NIL, {0} }`. `nlany_from_ptr(NULL)` is a valid nil-pointer any.

### 4.2 Print dispatch. Used by `print(x)` when `x` is `any`-typed.

```c
void nelua_print_any(nlany v);
```

Dispatches on `v.tag` and calls the existing typed helper, mirroring the
`print` table in `src/cgen.nim:629-649`:

| tag | emits |
|---|---|
| `NLANY_NIL` | `nelua_print_nil()` |
| `NLANY_BOOL` | `nelua_print_bool(v.as.b)` |
| `NLANY_INT` | `nelua_print_int64(v.as.i)` |
| `NLANY_UINT` | `nelua_print_uint64(v.as.u)` |
| `NLANY_NUM` | `nelua_print_double(v.as.n)` |
| `NLANY_STRING` | `nelua_print_string(v.as.s)` |
| `NLANY_POINTER` | `nelua_print_nil()` (pointers print as `nil`, matching the oracle) |
| `NLANY_TABLE` | `nelua_print_nil()` (placeholder; real table printing lands with the table impl) |
| `NLANY_FUNC` | `nelua_print_nil()` |
| `NLANY_TYPE` | `nelua_print_nil()` |

### 4.3 Load (any -> typed). Used by the `any -> T` load path. Phase 2b, emitted
only when a load conversion is requested.

```c
int64_t  nlany_load_int(nlany v);   /* tag must be INT or UINT; runtime error otherwise */
uint64_t nlany_load_uint(nlany v);  /* tag must be INT or UINT */
double   nlany_load_num(nlany v);   /* tag must be NUM, INT, or UINT */
uint8_t  nlany_load_bool(nlany v);  /* tag must be BOOL */
nlstring nlany_load_string(nlany v);/* tag must be STRING */
```

The integral loaders cross-accept `INT`/`UINT` so any integral `any` can be read
as either signed or unsigned (the value is reinterpreted into the target
width). On a tag mismatch they call `nelua_error_line(nlstr("runtime error: ..."))`
with the target type name and abort. This is the "explicit conversion or
runtime check" rule from `any-intended-design.md` §2.3: `any` is a sink for
dynamic input, and flowing *out* of it into a typed variable is a checked
conversion, never a silent erase.

### 4.4 Equality. Phase 2b.

```c
bool nlany_eq(nlany a, nlany b);
```

Value equality by tag+payload. Cross-tag returns `false` (except `NIL == NIL`).
Numeric cross-type (`INT`/`UINT`/`NUM`) compares as doubles so `5 == 5.0` is
`true`, matching Lua. `STRING` compares `data`/`size`; `POINTER`/`TABLE`/
`FUNC`/`TYPE` compare pointer identity.

### 4.5 Where they live

The construction helpers (`nlany_from_*`) are small and could be `static inline`
in the preamble instead of `runtime.c`. For consistency with the existing
`nelua_print_*`/`nlstr`/`nlidiv` pattern (defined in `runtime.c`, declared in
the preamble) this spec puts them in `runtime.c`. The implementer may move the
`nlany_from_*` set to the preamble as `static inline` if profiling shows the
by-value copy matters; the call sites in `cgen.nim` do not change.

---

## 5. Codegen changes per file (ordered)

Each entry names the proc, the anchor line, the change, and why. Line numbers
are against HEAD (c137f8e). Re-read the surrounding block before editing; the
comments in these procs are load-bearing for the other agents.

### 5.0 Pre-flight: `src/sema.nim`  -  the conversion matrix

`src/sema.nim:52` `proc convert(fromT, toT, explicit: bool): Conversion`.
The matrix currently has no `any` row, so `convert(integer, any)` falls
through to `ckNone` and `coerce` emits `(nlany)(5)` (broken). Add two rows
immediately before the final `return Conversion(kind: ckNone)` at line 101:

```nim
# T -> any: implicit tagged store (any value can hold any scalar/string/nil)
if toT.isAny and (fromT.isScalar or fromT.isStringy or
                  fromT.isNiltype or fromT.isNilptr):
  return Conversion(kind: ckAnyStore, check: false)
# any -> T: explicit load with a runtime tag check
if fromT.isAny and (toT.isScalar or toT.isStringy):
  return Conversion(kind: ckAnyLoad, check: true)
```

This requires a **new `ConversionKind` value**. `src/types.nim:62-63`:

```nim
ConversionKind* = enum
  ckNone, ckIdentity, ckImplicit, ckExplicit, ckNarrow,
  ckAnyStore, ckAnyLoad
```

Add `ckAnyStore, ckAnyLoad` after `ckNarrow`. `coerce` in `cgen.nim` will
branch on them (5.1.3). `ckAnyLoad` carries `check: true` so debug builds emit
the runtime tag-check abort; release builds still need the check (a wrong-tag
load is a real bug, not a debug-only concern), so the `coerce` branch must
ignore `check` and always emit the loader.

### 5.1 `src/cgen.nim`  -  the central chokepoint

#### 5.1.1 Preamble: replace the `nlany` placeholder (line 59)

`src/cgen.nim:59` currently reads `typedef void* nlany;`. Replace that single
line with the enum + struct from §3.1, verbatim:

```c
typedef enum {
  NLANY_NIL = 0,
  NLANY_BOOL, NLANY_INT, NLANY_UINT, NLANY_NUM,
  NLANY_STRING, NLANY_POINTER, NLANY_TABLE, NLANY_FUNC, NLANY_TYPE
} nlany_tag;

typedef struct {
  nlany_tag tag;
  union {
    uint8_t b; int64_t i; uint64_t u; double n;
    nlstring s; void* p;
  } as;
} nlany;
```

Then, in the helper declaration block (lines 83-103), add:

```c
nlany nlany_from_nil(void);
nlany nlany_from_bool(uint8_t v);
nlany nlany_from_int(int64_t v);
nlany nlany_from_uint(uint64_t v);
nlany nlany_from_num(double v);
nlany nlany_from_string(nlstring v);
nlany nlany_from_ptr(void* v);
void nelua_print_any(nlany v);
int64_t  nlany_load_int(nlany v);
uint64_t nlany_load_uint(nlany v);
double   nlany_load_num(nlany v);
uint8_t  nlany_load_bool(nlany v);
nlstring nlany_load_string(nlany v);
bool nlany_eq(nlany a, nlany b);
```

The load/equality declarations are phase 2b plumbing; declaring them now keeps
the preamble stable when they are wired in.

#### 5.1.2 `src/types.nim`  -  one new predicate

Add next to `isIntegral` at `src/types.nim:134`:

```nim
proc isUnsigned*(t: Type): bool =
  t != nil and t.kind in {tkUinteger, tkUint8, tkUint16, tkUint32, tkUint64,
    tkUint128, tkUsize, tkCuchar, tkCushort, tkCuint, tkCulong,
    tkCulonglong, tkCsize}
```

Needed by the store-helper picker in `coerce` (5.1.3) to choose `nlany_from_int`
vs `nlany_from_uint`. Also useful for any future unsigned-aware code.

#### 5.1.3 `src/cgen.nim` `coerce`  -  the single dispatch point

`proc coerce(s: var Gen, expr: string, fromT: Type, toT: Type): string` at
`src/cgen.nim:368`. Add a `ckAnyStore` / `ckAnyLoad` arm to the `case conv.kind`
at line 372, immediately after the `ckNarrow` arm at line 399 (before the
closing of the case). This is the ONLY place `any` conversion is emitted; every
call site (var-decl init at 1023, call args at 593, return at 1212, field
assignment at 753/763/785/806) routes through it.

```nim
of ckAnyStore:
  # T -> any: wrap the typed expression in the matching tagged-store helper.
  if fromT.isNiltype or fromT.isNilptr:
    return "nlany_from_nil()"
  if fromT.isBoolean:
    return "nlany_from_bool(" & expr & ")"
  if fromT.isStringy:
    return "nlany_from_string(" & expr & ")"
  if fromT.isIntegral:
    return (if fromT.isUnsigned: "nlany_from_uint(" else: "nlany_from_int(") & expr & ")"
  if fromT.isFloat:
    return "nlany_from_num(" & expr & ")"
  if fromT.isPointer or fromT.isFunction:
    return "nlany_from_ptr(" & expr & ")"
  # record value / enum / table var -> any: store the address
  return "nlany_from_ptr((void*)(" & expr & "))"
of ckAnyLoad:
  # any -> T: extract the payload with a runtime tag check.
  if toT.isStringy:
    return "nlany_load_string(" & expr & ")"
  if toT.isBoolean:
    return "nlany_load_bool(" & expr & ")"
  if toT.isIntegral:
    return (if toT.isUnsigned: "nlany_load_uint(" else: "nlany_load_int(") & expr & ")"
  if toT.isFloat:
    return "nlany_load_num(" & expr & ")"
  return "nlany_load_ptr(" & expr & ")"   # phase 2b placeholder
```

Notes:
- The store arm covers `nil`/`nilptr` first: `local x: any = nil` and
  `f(nilptr)` both lower to `nlany_from_nil()`. `nilptr` (the pointer-sized nil
  literal, distinct from the `niltype` `nil`) is stored as a nil pointer any.
- A record *value* has no single address until it is on the stack; the
  `any`-holds-record case is deferred (records are beyond the current slice),
  hence the `(void*)(&expr)` fallback is only reached for pointer/function
  types in the minimal slice.
- The load arm is the "explicit conversion or runtime check" rule: a wrong tag
  aborts at runtime, never silently corrupts.

#### 5.1.4 `src/cgen.nim` print dispatch  -  add an `any` row

`src/cgen.nim:629-649` (the `case ht.kind` inside the `nelua_print` lowering,
itself inside `src/cgen.nim:617`). Add one arm before the `else` at line 648:

```nim
of tkAny:
  helper = "nelua_print_any"; passArg = true
```

so `print(x)` where `x` is `any`-typed emits `nelua_print_any(x);` and the
runtime dispatcher (§4.2) does the rest.

#### 5.1.5 `src/cgen.nim` variable declaration  -  default an uninitialized `any` to nil

Two spots, both emitting `cDecl(vtype, cn)`:
- The declaration pass, `src/cgen.nim:951` (`s.line qual & cDecl(vtype, cn) & ";"`).
- The local-declaration pass, `src/cgen.nim:986` (`s.line cDecl(vtype, cn) & ";"`).

For `vtype.isAny`, emit `= {0}` so the tag defaults to `NLANY_NIL` instead of
uninitialized garbage. Concretely, wrap: if `vtype.isAny`, the emitted line is
`qual cDecl(vtype, cn) & " = {0};"` (same qual logic). A plain `nlany x = {0};`
is valid C and zeroes tag + union, giving `nil`.

This is the only var-decl change; the init path at line 1023 already routes
through `coerce`, so `local x: any = 5` needs no special-casing there once
5.1.3 lands.

### 5.2 `src/analyzer.nim`  -  remove the three rejections

All three are phase-1 rejections that phase 2 turns into support. Edit each
block to delete the diagnostic and keep the rest.

1. **`analyzeVarDecl`, `src/analyzer.nim:942-947`.** Delete the
   `if vtype != nil and vtype.kind == tkAny:` block entirely, **except** the
   `nkInitList` sub-case, which stays:
   ```nim
   if initNode != nil and initNode.kind == nkInitList:
     ctx.diags.add ctx.path & ": error: type 'any' cannot be initialized using an initializer list"
   ```
   (This preserves the `v_initlist` oracle-parity rejection. Without it,
   `local x: any = {}` would reach codegen and break.)
2. **`analyzeFuncDef` params, `src/analyzer.nim:1271-1273.** Delete the
   `if at != nil and at.kind == tkAny:` diagnostic at 1271-1272. The `at` is
   still added to `ftype.args` and `aparts` unchanged, so `f(a: any)` and the
   untyped `f(a)` both register the param as `any` and lower through 5.1.3.
3. **`analyzeFuncDef` returns, `src/analyzer.nim:1280-1282.** Delete the
   `if rt.kind == tkAny:` diagnostic at 1280-1281. The explicit
   `function f(): any` now registers a real `any` return type.

**Do not touch** the deduced-return path at `src/analyzer.nim:1342-1356`. It
emits the "compiler deduced type 'any'" diagnostic only when
`unifyReturnTypes` returns `nil` (a genuinely *incompatible* set, e.g.
`return 5; return "s"`), which is correct oracle-parity behavior and is not a
phase-2 target. (Minor follow-up, not blocking: that message now slightly
mislabels an incompatible-set case as "not supported yet"; reword in a later
pass if desired.)

### 5.3 `src/runtime.c`  -  define the helpers

Add after the `nelua_print_newline` helper (line 161) and before the `nlstr`
section (line 163), or in a new §section at the end of the file. Order:

1. Construction set (§4.1): `nlany_from_nil`, `nlany_from_bool`,
   `nlany_from_int`, `nlany_from_uint`, `nlany_from_num`,
   `nlany_from_string`, `nlany_from_ptr`. Each is 3-4 lines.
2. `nelua_print_any` (§4.2): a `switch (v.tag)` calling the typed helpers.
3. (Phase 2b) `nlany_load_*` (§4.3) and `nlany_eq` (§4.4).

`runtime.c` already includes `<stdint.h>`, `<stdbool.h>` (via the preamble's
needs  -  verify; add `#include <stdbool.h>` if `bool` is used and not already
present), and defines `nlstring` and `nltype`. The `nlany` struct itself is
emitted by the preamble (5.1.1), so `runtime.c` only needs the helper bodies.

### 5.4 `src/cgen_types.nim`  -  update the self-test

`src/cgen_types.nim:279`: `doAssert cType(anyT) == "void"` becomes
`doAssert cType(anyT) == "nlany"`. And `src/cgen_types.nim:127`:
`of tkAny: "void"` becomes `of tkAny: "nlany"`. These two must move together.

---

## 6. Ordering and the minimal first slice

### 6.1 Dependency order (implement in this order)

1. **`src/types.nim`**  -  add `isUnsigned` (5.2), add `ckAnyStore`/`ckAnyLoad` to
   `ConversionKind` (5.0).
2. **`src/sema.nim`**  -  add the two `any` rows to `convert` (5.0).
3. **`src/cgen_types.nim`**  -  `of tkAny: "nlany"` + the doAssert (5.4).
4. **`src/cgen.nim`**  -  preamble typedef + declarations (5.1.1), `coerce` arms
   (5.1.3), print `tkAny` row (5.1.4), var-decl nil default (5.1.5).
5. **`src/runtime.c`**  -  the helper definitions (5.3).
6. **`src/analyzer.nim`**  -  delete the three rejections (5.2).
7. **Rebuild** (`nim c -d:release --path:src -o:tmp/nelua src/main.nim`) and run
   the probes.

Steps 1-3 are pure type-rule / spelling changes with no behavioral effect on
existing programs (no existing program has an `any` value in flight). Step 4 is
where `any` becomes a real type end-to-end. Step 6 is what flips the rejections
into accepts. Build after step 6, not before  -  before step 6 the probes still
reject, so an earlier build gives no signal.

### 6.2 Minimal first slice: make `p_store` work end-to-end

Target: `tmp/any2/p_store.nelua` (`local x: any = 5; print(x)`) compiles,
runs, and prints `5\n` with exit 0.

What it needs from the full change list:
- 5.0 (sema `convert` + `ConversionKind`)  -  so `coerce` returns `ckAnyStore`.
- 5.1.1 (preamble struct + `nlany_from_int` decl)  -  so `nlany` is a real type.
- 5.1.2 (`isUnsigned`)  -  picker in `coerce`.
- 5.1.3 (`coerce` `ckAnyStore` arm)  -  emits `x = nlany_from_int(5);`.
- 5.1.4 (print `tkAny` row)  -  emits `nelua_print_any(x);`.
- 5.3 (`nlany_from_int` + `nelua_print_any` definitions in `runtime.c`).
- 5.4 (`cType(any) == "nlany"`)  -  so the declaration `nlany x;` is valid.
- 5.2 #1 (delete the `analyzeVarDecl` rejection)  -  the only analyzer change
  p_store needs.

It does **not** need 5.2 #2/#3 (function param/return rejections) or 5.1.5
(p_store has an initializer, so the nil-default is not exercised)  -  but those
are cheap and land in the same diff, so implement them together with the
minimal slice rather than gating them. (If 5.1.5 ships in the same diff, the
declaration below becomes `static nlany x = {0};`.)

Expected emitted C for `p_store` after the slice:

```c
static nlany x;
...
x = nlany_from_int(5);
nelua_print_any(x);
nelua_print_newline();
```

### 6.3 Next probes after p_store (in order)

Each adds one surface; each is independently verifiable.

1. **`p_assign`** (`local x = 5; local y: any = x; print(y)`). Same machinery as
   p_store; the source is a variable, not a literal. Verifies the store arm
   handles a non-literal integral expression.
2. **`p_return`** (`local function f(): any return 5 end; print(f())`).
   Adds the explicit-`any`-return path: 5.2 #3 + the `coerce` call in
   `genReturn` at `cgen.nim:1212` already routes through `coerce`, so no new
   codegen. Verifies `return` lowering and function-call return plumbing.
3. **`p_pass`** (`local function f(a: any) return a end; print(f(7))`).
   Adds the explicit-`any`-param path: 5.2 #2 + `genCall` arg coercion at
   `cgen.nim:593`. Verifies call-site store and that an `any` value round-
   trips through a parameter.
4. **`p_untyped`** (`local function f(a) return a end; print(f(3))`).
   Adds the untyped-param path (the param at `analyzer.nim:1268` already
   defaults to `BuiltinTypes["any"]`; 5.2 #2 unblocks it). Verifies the
   deduced-`any` param and the deduced-`any` return (the return type is
   unified from `return a`, a single `any` candidate, at `analyzer.nim:1351`).

p_pass and p_untyped both rely on the deduced-return path at
`analyzer.nim:1342-1356` producing `any` for a single `any` candidate. That
path already exists and needs no change (verified by reading: a single
candidate returns itself via `unifyReturnTypes`). No dependency on the other
agent's untyped-return-deduction work for these four probes.

### 6.4 Phase 2b (after the five probes all MATCH)

- Load path (§4.3) wired into `coerce`'s `ckAnyLoad` arm (5.1.3 already has the
  arm; the runtime defs are 5.3). Needed for `local y: integer = x`.
- `any` arithmetic (`+`, `..`, `<`, `#`, `[]`, `()`) via new runtime helpers.
- `any` as a `print`/stdlib entry-point type.
- Table/function/type tags fully wired (currently placeholder dispatch).

---

## 7. Done-when checklist

- [ ] `tmp/any2/p_store.nelua` runs end-to-end through `tmp/nelua`: stdout
      `5`, exit 0. (Minimal slice; do this first and stop to verify.)
- [ ] `tmp/any2/p_assign.nelua` MATCHes its expected output (`5`, exit 0).
- [ ] `tmp/any2/p_return.nelua` MATCHes its expected output (`5`, exit 0).
- [ ] `tmp/any2/p_pass.nelua` MATCHes its expected output (`7`, exit 0).
- [ ] `tmp/any2/p_untyped.nelua` MATCHes its expected output (`3`, exit 0).
- [ ] `tmp/any2/v_initlist.nelua` still rejects with
      `type 'any' cannot be initialized using an initializer list`, exit 1
      (oracle-parity for the table-literal case; deliberately preserved).
- [ ] `tmp/any2/v_typeval.nelua` still rejects at parse
      (`unexpected keyword 'any'`, exit 1)  -  out of scope, untouched.
- [ ] No existing program regresses: `python3 plan/examples_parity.py` and
      `python3 plan/regress.py` are no worse than their pre-phase-2 baselines
      (1 MATCH / 6 DIFF / 3 SKIP for examples_parity; M2 and M1 baselines in
      `plan/WIP/any-implementation-design.md` §6). Re-run only when `src/` is
      quiescent.
- [ ] `nim c -d:release --path:src -o:tmp/nelua src/main.nim` builds with no
      warnings-as-errors and no `doAssert` failures (the `cType(any)` assert at
      `cgen_types.nim:279` updated to `"nlany"`).
- [ ] The three phase-1 rejection blocks in `src/analyzer.nim` (942, 1271, 1280)
      are deleted and the init-list rejection at 944-945 is preserved.
- [ ] `src/runtime.c` builds and links: the emitted TU references
      `nlany_from_int`, `nelua_print_any`, and (later) the load/eq helpers, and
      the linker resolves them.
- [ ] This doc's §5 change list is fully landed and each entry ticked off.

---
