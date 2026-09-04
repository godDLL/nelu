# C lowering spec: pointer / array / record type combinations

**Status:** INBOX -- read-only spec for the pointer-to-array C-emission blocker; not fixed in `src/`.

Read-only research spec for the pointer-to-array C-emission blocker. Oracle is
`/usr/bin/nelua` (0.2.0-dev, build 1635); ours is `tmp/nelua`.

Every C spelling below was captured from an actual `--print-code` run. Oracle
captures live in `tmp/PA_oracle/`, ours in `tmp/PA_ours/`; the probe sources are
`tmp/PA_*.nelua`. The probe harness is `tmp/PA_probe.nelua` (a single file
exercising every form); each captured `.c` is the `--print-code` output of one
variant.

---

## 0. Headline

Our emitter emits **invalid C** for every pointer-to-array type. `*[0]byte`
param spells `(uint8_t[])* data`; `*[8]byte` param spells `(uint8_t[8])* data`;
the record field `ptr: *[0]byte` spells `(uint8_t[])* ptr`; the cast
`(@*[0]byte)(e)` spells `((uint8_t[])*)(e)`; the nil-init spells
`((uint8_t[])*)(NULL)`. All five are C syntax errors (verified with `gcc -std=c99
-Wall -Werror`). The oracle emits none of these. **hash.nelua never reaches this
bug**: it dies first at `require 'span'` (transitively `lib/iterators.nelua`),
which our parser cannot read because it uses the `@#[...]#` splice syntax that is
still in flight (NOTE_backlog).

---

## 1. The two architectures (this is the whole story)

The divergence is not one bug; it is a fork in how arrays and pointers reach C.

**Oracle (referee).** Every pointer and array composite gets a **typedef**, and
every fixed array is **wrapped in a struct**:

| Nelua type | Oracle typedef(s) | Oracle C spelling in declaration position |
|---|---|---|
| `*integer` | `typedef int64_t* nlint64_ptr;` | `nlint64_ptr data` |
| `*byte` | `typedef uint8_t* nluint8_ptr;` | `nluint8_ptr d` |
| `*[0]byte` | `typedef uint8_t* nluint8_arr0_ptr;` | `nluint8_arr0_ptr data` |
| `*[8]byte` | `typedef struct NELUA_MAYALIAS nluint8_arr8 {uint8_t v[8];} nluint8_arr8;` + `typedef nluint8_arr8* nluint8_arr8_ptr;` | `nluint8_arr8_ptr data` |
| `*[0]Pt` (record) | `typedef <struct Pt>* <...>_Pt_arr0_ptr;` | `<...>_Pt_arr0_ptr a` |
| `*Point` | `typedef <struct Point>* <...>_Point_ptr;` | `<...>_Point_ptr p` |
| `span(byte)` | `struct <...>_span_uint8_ { nluint8_arr0_ptr data; uintptr_t size; }` | `<...>_span_uint8_ s` |

Two details drive everything else:

- **Incomplete arrays are downgraded to element pointers.** `*[0]byte` is
  `typedef uint8_t* nluint8_arr0_ptr;`, i.e. the oracle represents
  `pointer(array(uint8, 0))` as `uint8_t*`. This is what makes `data[i]` (the
  actual usage in `lib/hash.nelua:20`) compile to a plain byte index. A "proper"
  C pointer-to-array `uint8_t (*)[]` would make `data[i]` yield the i-th
  *array*, which is the wrong value.
- **Fixed arrays are wrapped in a struct** with a single `v[N]` field, plus a
  cast union `{ arr a; elem p[N]; }` for type-punning. Indexing a pointer to a
  fixed array becomes `ptr->v[i]`, not `ptr[i]` (verified: `form: *[8]byte`,
  `form[0]=1` -> `form->v[0] = 1U;`, `form[2]` -> `form->v[2];`).

**Ours.** We deliberately emit **inline** spellings and no typedefs for pointers
(`cgen_types.nim` header: "this module only produces the spellings and leaves the
definitions to them"). `*integer` is `int64_t*`, `*byte` is `uint8_t*`. That
inline choice is sound for plain pointers and is a deliberate divergence, not a
bug. It breaks only when the subtype is an **array**, because the inline spelling
`(uint8_t[])* name` is not a valid C declarator.

---

## 2. Oracle spellings (referee), per form and position

Captured to `tmp/PA_oracle/`. Probe sources `tmp/PA_*.nelua`.

### 2.1 Plain pointer (baseline, MATCHES ours semantically)

| Form | Position | Oracle C | Ours C | Verdict |
|---|---|---|---|---|
| `*integer` | param | `nlint64_ptr data` | `int64_t* data` | DIVERGE (typedef vs inline; both valid) |
| `*integer` | vardecl | `static nlint64_ptr p;` | `static int64_t* p;` | DIVERGE |
| `*byte` | param | `nluint8_ptr d` | `uint8_t* d` | DIVERGE |
| `*Point` (record) | param | `<...>_Point_ptr p` | `void* p` | **BUG** (ours loses the record; see §5) |

### 2.2 Pointer to incomplete array `*[0]T`

| Form | Position | Oracle C | Ours C | Verdict |
|---|---|---|---|---|
| `*[0]byte` | param | `nluint8_arr0_ptr data` | `(uint8_t[])* data` | **BUG (invalid C)** |
| `*[0]byte` | vardecl | `static nluint8_arr0_ptr d;` | `static (uint8_t[])* d;` | **BUG (invalid C)** |
| `*[0]byte` | record field | `nluint8_arr0_ptr ptr;` | `(uint8_t[])* ptr;` | **BUG (invalid C)** |
| `*[0]byte` | cast `(@*[0]byte)(e)` | `((nluint8_arr0_ptr)(e))` | `((uint8_t[])*)(e)` | **BUG (invalid C)** |
| `*[0]byte` | nil-init | (oracle rejects nil -> ptr) | `((uint8_t[])*)(NULL)` | **BUG (invalid C)** |
| `*[0]byte` | index `data[i]` | `data[(i)]` (direct) | `(i)[data]` (operands swapped) | DIVERGE (valid C; `a[b]==b[a]`; semantically a byte either way) |
| `*[0]Pt` (record) | param | `<...>_Pt_arr0_ptr a` | `(void[])* a` | **BUG (invalid C + record subtype lost)** |

### 2.3 Pointer to fixed array `*[N]T`, N>0

| Form | Position | Oracle C | Ours C | Verdict |
|---|---|---|---|---|
| `*[8]byte` | param | `nluint8_arr8_ptr data` | `(uint8_t[8])* data` | **BUG (invalid C)** |
| `*[8]byte` | record field | `nluint8_arr8_ptr buf;` | `(uint8_t[8])* buf;` | **BUG (invalid C)** |
| `*[8]byte` | index/assign `form[i]=b` | `form->v[i] = ...` | (not reachable; emitter crashes on the cast first) | n/a |

### 2.4 Records, spans, casts

| Form | Position | Oracle C | Ours C | Verdict |
|---|---|---|---|---|
| `@record{x:int,y:int}` value | init | `static <tag> r = {.x = 1, .y = 2};` | `r = ((struct <tag>){ .x = 1, .y = 2, });` | DIVERGE (both valid compound literals) |
| `*Record` | param | `<...>_Record_ptr p` | `void* p` | **BUG** (analyzer emits `pointer(any)`) |
| `span(byte)` | param | `<...>_span_uint8_ s` | not reached | n/a (requires `require 'span'`) |
| `span` literal `{data=&x,size=1}` | init | `(<...>_span_uint8_){.data=((nluint8_arr0_ptr)(&x)), .size=1U}` | not reached | n/a |

---

## 3. Per-case diff summary

**BUG (invalid C emitted by ours):** 8 cases: every pointer-to-array in
declaration, field, cast and nil-init position, for both N=0 and N>0, plus
`*[0]@record{...}`.

**DIVERGE (both valid C, different spelling):** plain pointers (`int64_t*` vs
`nlint64_ptr`), index operand order for `*[0]byte` (`data[i]` vs `(i)[data]`),
record compound-literal formatting. These are deliberate or cosmetic; they do
not block compilation.

**BUG (valid C, wrong type):** `*Record` param. Ours emits `void*`; the oracle
emits `<...>_Record_ptr`. Verified via `--print-analyzed-ast`: ours types the
param `pointer(any)`, the oracle types it `pointer(record)`. This is an
*analyzer* bug, not the emitter's C-spelling bug, and it is a different root
cause.

---

## 4. Root cause: the exact proc and the minimal change

Three procs build the bad strings; one of them is the root.

| File | Proc | Lines | Role | Produces |
|---|---|---|---|---|
| `src/cgen_types.nim` | `cType` | 131-137 | type spelling | `*(tkPointer)` + `isArray` -> `"(" & cType(subtype) & ")*"` => `(uint8_t[])*` |
| `src/cgen.nim` | `cDecl` | 859-892 | declaration spelling | `else` branch (891-892): `cType(t) & " " & name` => `(uint8_t[])* data` |
| `src/cemitter.nim` | `cCast` | 125-129 | cast spelling | line 129: `"(" & cType(t) & ")(" & expr & ")"` => `((uint8_t[])*)(e)` |

`cDecl` already special-cases `tkArray` (870-873) and `tkFunction` (874-885) to
put the bound / identifier in the right place; it has **no case for
`tkPointer` whose subtype is an array**, so it falls through to the plain
`cType(t) & " " & name`. `cCast` and the nil-init path both go through `cType`,
so they inherit the same wrong spelling.

### Minimal patch (prose; not applied)

Two-tier fix, matching what the oracle actually does.

**Tier 1: incomplete arrays (`*[0]T`, `arraySize <= 0`): downgrade to element
pointer.** In `cType`, in the `tkPointer` branch, split the `isArray` case on
`t.subtype.arraySize <= 0` and, for the incomplete case, return
`cType(t.subtype.subtype) & "*"` (element type plus `*`). One-line change.

Consequence, all at once:
- `cType` -> `uint8_t*`
- `cDecl` -> `uint8_t* data` (valid)
- `cCast` -> `(uint8_t*)(e)` (valid)
- nil-init -> `(uint8_t*)(NULL)` (valid)
- `data[i]` -> byte (correct; matches the oracle's `data[(i)]` semantics)

This is a 1-line change, it makes all five invalid spellings valid, and it
matches the oracle's *actual* incomplete-array behaviour exactly. It is the fix
for `lib/hash.nelua`'s `lhash` (the only `*[0]byte` consumer that matters here).

**Tier 2: fixed arrays (`*[N]T`, `arraySize > 0`): two options.**
- (a) Match the oracle: wrap `tkArray` in a struct and rewrite pointer-to-array
  indexing to `ptr->v[i]`. Correct and oracle-matching, but a multi-file change
  across `cgen_types`, `cgen` (typedef emission, field emission, `genKeyIndex`,
  `genLvalue`).
- (b) Downgrade to element pointer as in Tier 1. One line, valid C, correct
  byte indexing, but diverges from the oracle's struct representation and loses
  the bound.

The task brief's suggested spelling `elem (*name)[]` is valid C (verified:
`uint8_t (*data)[] = (uint8_t (*)[])(&x);` compiles) but is **not what the
oracle emits**, and it is only semantically correct if `genKeyIndex` is
*also* changed to emit `(*name)[i]` for pointer-to-array bases, because
`name[i]` on a `uint8_t (*)[]` yields the i-th array, not the i-th byte. Two
changes, and still not the oracle's spelling. Recommended only if Tier 2(a) is
not affordable and the fixed-array consumers can tolerate losing the bound.

**Pointer-to-record is out of scope for this patch.** It is the analyzer
resolving `*Record` to `pointer(any)` (see §5); fixing it belongs in the
type-name resolution path, not in `cType`/`cDecl`.

---

## 5. Does fixing pointer-to-array unblock `lib/hash.nelua`?

**No.** `hash.nelua` hits another blocker first.

`tmp/nelua lib/hash.nelua` does not reach codegen. Reported first failure:

```
lib/hash.nelua:19:31: error: expected ')' after function parameters
```

(exit 1, "unable to analyze ... (parse error)"). The root cause is `require
'span'` on line 11. Our compiler loads `lib/span.nelua`, which our parser cannot
read:

```
lib/span.nelua:21:  local T: type = @#[T]#
lib/iterators.nelua:35:  local container_reference_concept: type = #[concept(function(x)
```

Both use the `@#[...]#` / `#[...]#` splice syntax, which is **not yet parsed by
ours**; splice Stages 0-3 are in flight per `NOTE_backlog`. `require 'span'`
transitively requires `iterators`, so the whole `span` dependency tree is
unreachable. Isolated `require 'span'` additionally segfaults the driver.

Verified ordering:
- Oracle compiles `lib/hash.nelua` cleanly (exit 0).
- If the splice/require blockers were cleared, the **next** blocker is exactly
  this spec's bug: `tmp/nelua` on the `lhash` function alone emits
  `uintptr_t tmp_..._lhash((uint8_t[])* data, ...)` and fails C compile.

So: pointer-to-array is necessary but not sufficient for `hash.nelua`. The
splices must land first. `lib/string.nelua` and `lib/stringbuilder.nelua` have
the same `require 'span'`/splice blocker.

---

## 6. "Done when" checklist

Every row must hold for `tmp/nelua` against the oracle's captured spellings in
`tmp/PA_oracle/`.

- [ ] `*[0]byte` param spells `uint8_t* data` (not `(uint8_t[])* data`)
- [ ] `*[0]byte` vardecl spells `static uint8_t* d;`
- [ ] `*[0]byte` record field spells `uint8_t* ptr;`
- [ ] cast `(@*[0]byte)(e)` spells `(uint8_t*)(e)`
- [ ] nil-init of `*[0]byte` spells `(uint8_t*)(NULL)`
- [ ] `data[i]` on a `*[0]byte` yields a byte (index order does not matter for correctness here)
- [ ] `*[0]@record{...}` param spells a pointer-to-record-element, not `(void[])*`
- [ ] `*[8]byte` param is at least valid C (Tier 1 downgrade `uint8_t*`, or Tier 2(a) struct `ptr->v[i]`, or Tier 2(b) `elem (*name)[]` with `(*name)[i]` indexing)
- [ ] `*[8]byte` record field is valid C
- [ ] `*integer` / `*byte` remain valid inline spellings (`int64_t*`, `uint8_t*`)
- [ ] `*Record` param is not silently `void*` (separate analyzer fix; tracked apart)
- [ ] `lib/hash.nelua` advances past `lhash`'s C emission once the splice blocker clears (regression probe: `tmp/PA_l19.nelua` compiles)

---

## 7. Captured artefacts

| Dir | Contents |
|---|---|
| `tmp/PA_oracle/*.c` | `/usr/bin/nelua --print-code` for every form (the referee) |
| `tmp/PA_ours/*.c`, `*.err` | `tmp/nelua --print-code` for the same forms, plus the hash.nelua failure trace |
| `tmp/PA_*.nelua` | probe sources, one construct per file |
| `tmp/PA_probe.nelua` | consolidated probe |

Key oracle captures: `p0_param_star0.c` (`*[0]byte` param), `p0_param_star8.c`
(`*[8]byte` param), `p0_param_ptr.c` (`*integer` param), `p0_param_ptrrec.c`
(`*Point` param), `p0_param_star0rec.c` (`*[0]Pt` param), `p0_field_star0.c`
(record fields), `p0_index_star0.c` (`data[i]`), `p0_index_star8.c`
(`form->v[i]`), `p0_span.c` (`span(byte)`), `p0_ptrvar.c` (vardecl + `$p` deref).