# Nelua `any` — intended (Nelu) design

**Status:** design spec, not implemented. Awaiting a working build to land on.
**Sources:** `NELUA-200.md` §3.5, §9.2; `language-review.md` §11.1.2, §10.5;
`plan/oracle-any-behavior-design.md` (what the oracle *does*).

---

## 1. The intended result (what the docs say)

- **`language-review.md` §11.1.2:** "Full `any` type with runtime type
  dispatch. Support dynamic typing **in the way Lua does**, with an **efficient
  tagged-representation `any` value** and minimal overhead. This enables porting
  real Lua code."
- **`NELUA-200.md` §3.5 / §9.2:** `any` is the *union type deduced* when a value
  could be one of several types (`string | number | boolean | table | nil`).
  The oracle rejects that deduction. `niltype` is the type of `nil`; `nilptr` is
  the pointer-sized nil literal, distinct from `nil`.
- **`language-review.md` §10.5:** `any`, `niltype`, `void`, `auto`, `varargs`,
  `varanys` are the type kinds.

So `any` is not a loophole for "the compiler gave up" — it is a first-class
**dynamic type**: a value that carries both a concrete type tag and a payload,
with runtime dispatch on every operation. It is the thing that lets you port
Lua code (where everything is dynamic) into statically-typed Nelua without
giving up the static type system elsewhere.

---

## 2. Two phases

### Phase 1 — parity floor (easy, non-interfering)

"Work as it does for existing programs." Since the oracle's **C backend rejects
deduced `any`**, no existing C program uses it — so the floor is just: don't
make existing programs worse, and don't emit broken code.

1. **Emit the oracle's exact rejection** for a deduced `any` (variable,
   parameter, or return type):
   `compiler deduced type 'any' here, but it's not supported yet, please fix
   this variable type`.
2. **Delete the current broken `void*` lowering** (`cgen_types.nim:127`). Today
   a deduced `any` reaches codegen and produces broken C — `5` stored as
   `(void*)(5)`, `print(x)` → `nelua_print_nil()`, `x + 1` dropped,
   `= {}` → an initlist C error. Phase 1 makes it fail at analysis instead, with
   the documented message.

**Interference check:** this changes behavior only for programs that *already
deduce `any`* — and those already fail on the oracle. Zero running programs are
affected. `plan/examples_parity.py` stays green.

### Phase 2 — the intended `any` (Nelu, additive)

Implement the tagged representation. Making `any` a real type is additive: no
existing program runs with `any` on C today (they are all rejected), so turning
the rejection into full support breaks nothing that currently works.

#### 2.1 Representation (C)

A tagged word plus a payload union. Scalars live inline — no heap allocation,
minimal overhead:

```c
typedef enum {
  NLANY_NIL, NLANY_BOOL, NLANY_INT, NLANY_UINT, NLANY_NUM,
  NLANY_STRING, NLANY_POINTER, NLANY_TABLE, NLANY_FUNC, NLANY_TYPE
} nlany_tag;

typedef struct {
  nlany_tag tag;
  union {
    uint8_t  b;
    int64_t  i;
    uint64_t u;
    double   n;
    nlstring s;    /* {data, size} */
    void*    p;
    nltable* t;
    /* func, type pointers */
  } as;
} any;
```

This is the "efficient tagged-representation" the docs ask for: one word of tag +
one word of payload for scalars, heap only for string/table contents (which are
already heap objects).

#### 2.2 Runtime dispatch

Operations read the tag and dispatch. Coercion follows Lua rather than C:

- **`any + any`** — int+int→int; any `num` involvement→num; otherwise a runtime
  error (no implicit string coercion).
- **`any .. any`** — string..string only; number..number coerces to string; else
  runtime error.
- **`any == any`** — value equality by tag+payload; cross-tag → false.
- **`#any`** — string length / table size; else runtime error.
- **`any[k]` / `any[k] = v`** — table indexing if table; else runtime error.
- **`any(...)`** — call if func/type; else runtime error.
- **`print(any)`** — dispatch on tag (mirrors `print`'s typed helpers).
- **Truthiness** — `nil` and `false` are falsey; `0` is truthy (Nelua rule).

#### 2.3 Conversion (the "porting Lua" path)

- Literals and typed values convert to `any` **implicitly** at assignment and
  call boundaries — this is what makes `local x: any = 5` and
  `function f(a: any) ... end` work.
- A value flowing *out* of an `any` into a typed variable needs an explicit
  conversion or a runtime check; otherwise it is a compile error. This keeps
  the static type system honest: `any` is a sink for dynamic input, not a way
  to silently erase types everywhere.

#### 2.4 Opt-in

`any` is a real type you annotate: `local x: any`, `function f(a: any)`,
`function f(): any`. It is *not* silently adopted as the default deduction
target — that would silently change every program, which §11.0c forbids.

---

## 3. Non-goals (out of scope even as Nelu)

- **`any` as a type-value global** like the Lua backend's (where `any == nil` is
  undefined behavior). We do not replicate undefined behavior.
- **`any` holding a table literal** (`local x: any = {}` — the oracle rejects
  this on both backends). A table *variable* assigned to `any` is fine.
- **Making `any` the default deduction target.**
- **`any` metamethods, `any`-typed fields in `record`/`union`, iteration over an
  `any`.** (These wait on `record`/`union`/`table`, which are themselves beyond
  the current milestone.)

---

## 4. Verification

- **Existing-program gate:** `plan/examples_parity.py` must stay green. Phase 1
  keeps it green by construction; Phase 2 adds capability only, never changes an
  existing program's behavior.
- **New corpus:** `tmp/m2_corpus/` probes for `any` round-tripping and dispatch
  (added when Phase 2 is implemented).
- **Oracle cross-check:** where the oracle *does* define `any` behavior (type-value
  equality folds at compile time; `any` is a plain identifier), match it. Where
  the oracle is silent or undefined, design to the §11.1.2 intent.

---

## 5. Open questions for the user

1. **Should deduced `any` flow into the dynamic type?** The docs frame `any` as
   *the union type deduced when a value could be several types*. Making a
   deduced `any` a valid `any`-returning function is the natural reading and is
   additive (breaks no running program). **Recommended: yes.** The alternative —
   keeping the oracle's hard rejection forever — leaves `any` as a compile error
   forever, which is not "extending it to be more like the intended result."
2. **Which types get a tag?** Start with nil/bool/int/uint/num/string/pointer/
   table/func/type. Add `cstring`, `nilptr`, `function`-pointers as needed.
   Recommend the minimal set first, expand by demand.
3. **`any` in `print`/`string.format`-style stdlib entry points** — the stdlib
   (`lib/`) is inherited and gated on require-compilation. Any `any`-accepting
   stdlib surface must be reconciled with the inherited code; flag before
   touching `lib/`.