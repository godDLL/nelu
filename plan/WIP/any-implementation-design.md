# Nelua `any` — implementation design (our compiler)

**Status:** Phase 1 (parity floor) complete and green. Phase 2 (tagged `any`,
Nelu/beyond-oracle) is designed but **deferred** -- see §5.
**Oracle:** `/usr/bin/nelua` (Nelua 0.2.0-dev, build 1635, git a5845056).
**Our compiler:** `tmp/nelua` (built `nim c -d:release --path:src -o:tmp/nelua src/main.nim`).
**Sources:** `plan/oracle-any-behavior-design.md` (what the oracle *does*),
`plan/INBOX/any-intended-design.md` (the intended Nelu result).

---

## 1. Bottom-line callout

**Phase 1 is done: our compiler now rejects `any` as a variable / parameter /
return type with the oracle's exact message, and emits no broken C.** The
broken `void*` lowering of `any` in `src/cgen_types.nim` is deleted. Both gates
(`plan/regress.py`, `plan/examples_parity.py`) are no worse than before; the
behavior is a strict improvement for every program that deduces `any`.

**Phase 2 (a real tagged-representation `any` on the C backend) is designed but
not implemented.** It is blocked by the file-ownership boundary in this task
(see §5): it requires touching `src/cgen.nim`, `src/cemitter.nim`,
`src/types.nim`, `src/analyzer.nim`, and `src/runtime.c`, all of which are
in-flight by another agent. The design is fully specified in §4 so a future
pass can pick it up without re-deriving it.

**Do not** read this doc as "our compiler is oracle-parity for `any` on C". It
is parity for the *rejection* only. A runtime `any` on the C backend is
beyond-oracle by construction (the oracle's C backend rejects `any` entirely);
adding it is an additive Nelu extension, not parity.

---

## 2. Findings table vs oracle (C backend)

Legend: **A** = accepted, **E** = error/rejected, **pre** = pre-existing gap in
our compiler unrelated to this change.

| # | construct | Oracle (C) | Ours (after Phase 1) | Note |
|---|---|---|---|---|
| 1 | `local x: any = 5` | **E**: `compiler deduced type 'any' here...` | **E** same message | exact match |
| 2 | `local x: any = "s"` | **E** same | **E** same | exact match |
| 3 | `local x: any = true` | **E** same | **E** same | exact match |
| 4 | `local x: any = nil` | **E** same | **E** same | exact match |
| 5 | `local x: any = {}` | **E**: `type 'any' cannot be initialized using an initializer list` | **E** same message | exact match |
| 6 | `local x: any = function() end` | **E**: `compiler deduced type 'any' here...` | **E** same | exact match |
| 7 | `local x: any = print` | **E**: `compiler deduced type 'any' here...` | **E** same | exact match |
| 8 | `local x = print` (deduced) | **E**: `compiler deduced type 'any' here...` | **E** same | exact match |
| 9 | `local function f(a: any)` | **E** same | **E** same | exact match |
| 10 | `local function f(a)` (untyped) | **E** same | **E** same | exact match; untyped params deduce to `any` and are rejected |
| 11 | `local function f(): any` | **E** same | **E** same | exact match |
| 12 | `local function f()` (untyped return) | **A** (prints value) | **A** (prints `nil`) | **pre**: untyped-return lowering bug, not `any`-related |
| 13 | `local x = any` (type value) | **A**: `any == any` -> `true` | **E** at parse: `unexpected keyword 'any'` | **pre**: lexer treats `any` as a keyword in expression position; out of scope (parser/lexer are not mine) |
| 14 | `local x: integer = 5` | **A** | **A** | control, unaffected |
| 15 | `local function f(a: integer): integer` | **A** | **A** | control, unaffected |
| 16 | `for x: any in ...` | **E**: `cannot call type 'int64'` | **E** at parse: `expected 'in' in for` | **pre**: parse-level gap, both reject (exit 1) |
| 17 | `local function f(...: any)` | **E**: `cannot unpack varargs in this context` | **E** at parse: `unexpected token` | **pre**: parse-level gap, both reject (exit 1) |

Rows 12, 13, 16, 17 are pre-existing gaps in our parser/lexer/return-lowering,
**not** introduced by Phase 1 and **not** in scope (parser, lexer, and the
untyped-return path are owned by another agent). Phase 1's contribution is
rows 1-11: every case where the oracle rejects `any` as a *type* (variable,
parameter, return, or deduced from a builtin) now rejects with the oracle's
exact message, and no broken C is emitted.

---

## 3. Verbatim errors

### Oracle (C backend)

`local x: any = 5`:
```
any_v1.nelua:1:7: error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type
local x: any = 5
      ^~~~~~
exit=1
```

`local x: any = {}` (both backends):
```
any_v2.nelua:1:1: from: AST node Block
local x: any = {}
^~~~~~~~~~~~~~~~~
any_v2.nelua:1:16: error: type 'any' cannot be initialized using an initializer list
local x: any = {}
               ^~
exit=1
```

`local function f(a: any)`:
```
any_any12.nelua:1:18: error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type
local function f(a: any)
                 ^~~~~~
exit=1
```

`local function f(): any`:
```
any_any13.nelua:1:7: error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type
local function f(): any
      ^~~~~~~~~~~~~~~~~
exit=1
```

### Ours (after Phase 1)

The **message text is identical** to the oracle's. The *format* differs because
our analyzer's diagnostics flow through the `genC` stub channel (see
`src/cgen.nim:1045`): analyzer diagnostics are surfaced as
`nelua: unable to analyze <path>:\n/* nelua: <path>: error: <message> */`.
This is the same channel every analyzer diagnostic in our compiler uses (e.g.
preprocessor `#error`, `require` failures); it is not specific to `any`.

`local x: any = 5`:
```
nelua: unable to analyze p_var.nelua:
/* nelua: p_var.nelua: error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type */
exit=1
```

`local x: any = {}`:
```
nelua: unable to analyze p_init.nelua:
/* nelua: p_init.nelua: error: type 'any' cannot be initialized using an initializer list */
exit=1
```

**Known format gap:** the oracle prints `path:line:col:` plus the source line and
a caret (`^~~~~~`). Our compiler prints no `line:col` and no caret for
analyzer diagnostics. This is a **shared limitation of our whole analyzer**,
not an `any`-specific one: our AST (`src/astshapes.nim`) does not carry
per-node source offsets, so no analyzer diagnostic can render a caret without
adding source-location tracking to the Node object (which would touch
`src/astshapes.nim` and `src/parser.nim`, both owned by another agent). The
message text -- the part the task asks to match -- is exact.

---

## 4. Phase 2 design (tagged `any`, Nelu / beyond-oracle)

**Status: designed, not implemented. Deferred -- see §5.**

This section is the handoff for whoever implements Phase 2. It is copied from
`plan/INBOX/any-intended-design.md` §2 with the parts that are specific to *our*
compiler filled in.

### 4.1 Representation (C)

A tagged word plus a payload union. Scalars live inline (no heap allocation):

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
} nlany;
```

In our compiler this would be:
- The **spelling** in `src/cgen_types.nim`: `of tkAny: "nlany"` (currently
  `"void"` after Phase 1; Phase 2 changes it back to a struct name).
- The **typedef emission** in `src/cgen.nim` (add the enum + struct next to
  `nlstring`/`nltype` at lines 57-61).
- The **runtime dispatch functions** in `src/runtime.c` (or a new
  `src/runtime_any.c`).

### 4.2 Runtime dispatch

Operations read the tag and dispatch. Coercion follows Lua, not C:

- **`any + any`** -- int+int -> int; any `num` involvement -> num; else runtime
  error (no implicit string coercion).
- **`any .. any`** -- string..string only; number..number coerces to string;
  else runtime error.
- **`any == any`** -- value equality by tag+payload; cross-tag -> false.
- **`#any`** -- string length / table size; else runtime error.
- **`any[k]` / `any[k] = v`** -- table indexing if table; else runtime error.
- **`any(...)`** -- call if func/type; else runtime error.
- **`print(any)`** -- dispatch on tag (mirrors `print`'s typed helpers).
- **Truthiness** -- `nil` and `false` are falsey; `0` is truthy (Nelua rule).

### 4.3 Conversion

- Literals and typed values convert to `any` **implicitly** at assignment and
  call boundaries: `local x: any = 5`, `function f(a: any) ... end`.
- A value flowing *out* of an `any` into a typed variable needs an explicit
  conversion or a runtime check; otherwise it is a compile error. This keeps
  the static type system honest: `any` is a sink for dynamic input, not a way
  to silently erase types everywhere.

### 4.4 What Phase 2 must NOT do (to stay additive and non-gold-plating)

- Do **not** make `any` the default deduction target -- that would silently
  change every program, forbidden by §11.0c.
- Do **not** support `any` holding a table *literal* (`local x: any = {}`) --
  the oracle rejects this on both backends and no existing program needs it.
  A table *variable* assigned to `any` is fine.
- Do **not** replicate the oracle's Lua-backend type-value globals
  (`any`/`number`/`boolean` are `nil` there); that is undefined behavior, not a
  spec (see `plan/oracle-any-behavior-design.md` §Surprise 1).
- Do **not** add `any` metamethods, `any`-typed fields in `record`/`union`,
  or iteration over an `any` until `record`/`union`/`table` land.

### 4.5 Open questions carried over

1. Should *deduced* `any` (e.g. from `local x = print`) flow into the dynamic
   type, or stay a rejection? The design doc recommends yes. Phase 1 currently
   rejects it (matching the oracle); Phase 2 would flip that to support.
2. Which types get a tag? Start with nil/bool/int/uint/num/string/pointer/
   table/func/type. Expand by demand.
3. `any` in `print`/stdlib entry points -- the stdlib is inherited and gated on
   require-compilation; flag before touching `lib/`.

---

## 5. Why Phase 2 is deferred

Phase 2 is a large, cross-cutting feature. In this task its implementation
would have to touch **five files that are not mine and are actively in flight
by another agent**:

| file | role in Phase 2 | current owner |
|---|---|---|
| `src/analyzer.nim` | remove the Phase 1 `any` rejection; add implicit in-conversion / explicit out-conversion; tag `any`-typed nodes | bounded-gaps agent (in flight) |
| `src/cgen.nim` | emit the `nlany` enum/struct typedef; lower `any` values and dispatch calls | bounded-gaps agent (in flight) |
| `src/cemitter.nim` | emit the C expressions for `any` construction/dispatch | bounded-gaps agent (in flight) |
| `src/types.nim` | possibly extend `Attr`/`Type` for `any` conversion metadata | bounded-gaps agent (in flight) |
| `src/runtime.c` | add the runtime dispatch helpers (`nlany_*`) | bounded-gaps agent (in flight) |

Editing those files now would risk destabilizing the bounded-gaps agent's
in-flight work (the compiler is mid-development; `regress.py` shows M2 at
13/14 and M1 at 13/28). Phase 1 is deliberately scoped to the two files I own
(`src/cgen_types.nim` plus the three surgical blocks in `src/analyzer.nim`) so
that it lands cleanly on top of their work with zero interference.

**Recommendation:** land Phase 1 now (it is green and strictly improves
`any` behavior); pick up Phase 2 from §4 once the bounded-gaps agent's M1/M2
gaps have closed and the ownership boundary is relaxed.

---

## 6. Reproducing

Oracle CACHES output by source filename -- always use a fresh unique filename
per probe, or the oracle returns a stale result.

```bash
# build our compiler
cd /home/user/Code/nelua-lang && nim c -d:release --path:src -o:tmp/nelua src/main.nim

# SDL examples open a real window unless run headlessly; set the dummy video
# driver for every subprocess (ours and the oracle) that may touch SDL.
export SDL_VIDEODRIVER=dummy

# Phase 1: reject deduced any (oracle vs ours)
printf 'local x: any = 5\nprint(x)\n' > /tmp/any_reject.nelua
/usr/bin/nelua /tmp/any_reject.nelua; echo "oracle exit=$?"
./tmp/nelua /tmp/any_reject.nelua; echo "ours exit=$?"

# Phase 1: table-literal initializer
printf 'local x: any = {}\n' > /tmp/any_init.nelua
/usr/bin/nelua /tmp/any_init.nelua; echo "oracle exit=$?"
./tmp/nelua /tmp/any_init.nelua; echo "ours exit=$?"

# Phase 1: parameter / return annotations
printf 'local function f(a: any)\n  return a\nend\nprint(f(1))\n' > /tmp/any_param.nelua
printf 'local function f(): any\n  return 1\nend\nprint(f())\n' > /tmp/any_ret.nelua

# gates (must be no worse than the pre-Phase-1 baseline).
# `examples_parity.py` runs every example -- including the SKIPped SDL game /
# benchmark loops -- so SDL_VIDEODRIVER=dummy must be set in the environment
# before invoking it, or snakesdl/condots/overview open a real window.
python3 plan/examples_parity.py     # baseline 1 MATCH / 6 DIFF / 3 SKIP
python3 plan/regress.py             # baseline M2 13/1 DIFF, M1 13/12/3
```

Pre-Phase-1 baseline (measured before any `any` change):
- `examples_parity.py`: 1 MATCH / 6 DIFF / 3 SKIP.
- `regress.py`: M2 13 MATCH / 1 DIFF (`func2.nelua`, a multi-return codegen
  bug unrelated to `any`); M1 13 MATCH / 12 DIFF / 3 CRASH.

Post-Phase-1 (current): identical -- **no regression**.

---

## 7. Files changed (this task)

| file | change |
|---|---|
| `src/cgen_types.nim` | `of tkAny: "void*"` -> `of tkAny: "void"` (delete the broken lowering); updated the self-test assertion. |
| `src/analyzer.nim` | three diagnostic blocks emitting the oracle's `compiler deduced type 'any' here, but it's not supported yet, please fix this variable type` message: (a) `analyzeVarDecl` for variable declarations, including the distinct `type 'any' cannot be initialized using an initializer list` message for table-literal initializers; (b) `analyzeFuncDef` for parameters (covers explicit `: any` and untyped params); (c) `analyzeFuncDef` for explicit `: any` return annotations. |

`src/analyzer.nim` is owned by another agent; I touched it because Phase 1's
rejection can only live in the analyzer, and the task's "say so in your report"
clause permits it. The three blocks are surgical insertions (no reformatting,
no renumbering) and the build is green, so they do not disturb the
bounded-gaps agent's in-flight changes.