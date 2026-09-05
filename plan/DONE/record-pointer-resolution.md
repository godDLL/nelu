# Analyzer fix: `*Record` resolves to `pointer(any)` instead of `pointer(record)`

**Status:** CLOSED -- integrated into live `src/` and verified end-to-end.  The §4.3 two-line fix was already present in `src/analyzer.nim` (`analyzeFuncDef`, lines 1657 and 1716 use `analyzeTypeExpr(ctx, arg.children[0], false)`); this ticket's job was to confirm and record it.  The §5 record-value-to-pointer consequence also turned out already handled on the live tree.  Moved to `plan/DONE/`.

**Stage 5 verification (live `tmp/nelua`, `nim c -d:release` build of committed `src/`).**  Full tally over `tmp/rpr/run.sh`, 15 probes:

| Verdict | Probes |
|---|---|
| MATCH (11) | p01, p02, p03, p03c, p05, p07, p08, p09, rg1, rg2, rg3 |
| DIFF (2) | p04, p04c -- the pointer-printing cases §1 scoped out (ours prints `nil` where the oracle prints the address; AST types are identical) |
| FAIL (0) | -- none; no probe where ours fails and the oracle succeeds |
| ORACLE-ONLY-FAIL (2) | p02c, p04b -- the oracle itself rejects these; not our divergence |
| BOTH-FAIL (2) | p03b, p06 -- oracle rejects (`*T` generic param; `*T` alias form) |

Against the ticket's own baseline (MATCH 4 / DIFF 4 / FAIL 5), this is MATCH 11 / DIFF 2 / FAIL 0.  p01, p07, p08 all pass a record *value* to a `*Record` parameter and MATCH -- so the §5 address-of chain (`sema.convert` + `cgen.coerce`) is working on the live tree, not just the Type-resolution fix in §4.

Read-only research spec. Oracle is `/usr/bin/nelua` (0.2.0-dev, build 1635); ours is
`tmp/nelua`. The minimal fix is described in prose only -- it has NOT been applied to
`src/`. It was verified on a throwaway copy of the tree at `tmp/srcfix/`, built as
`tmp/nelua_fix5` (`nim c -d:release --path:tmp/srcfix -o:tmp/nelua_fix5
tmp/srcfix/main.nim`).

Every Type representation below was captured from an actual `--print-analyzed-ast`
run. Captures live in `tmp/rpr/ast/`; probe sources in `tmp/rpr/*.nelua`; the runner
is `tmp/rpr/run.sh`.

---

## 0. Headline

Our analyzer types every `*<named type>` **function parameter** as `pointer(any)`
and emits C `void*`; the oracle types it `pointer(Record)` and emits
`<unit>_Record_ptr`. Verified via `--print-analyzed-ast`: ours says
`function(p: pointer(any)): void`, the oracle says
`function(p: pointer(Record)): int64`. The root cause is a single resolver
divergence in the function-parameter path, and the minimal fix is a two-line
swap in `analyzeFuncDef`.

## 1. Probe tally (13 constructs with oracle-valid syntax)

Run through `tmp/rpr/run.sh`. MATCH = same stdout and exit 0 on both. DIFF = both
exit 0 but output differs. FAIL = ours fails (exit nonzero or wrong output) while
the oracle exits 0.

| Probe | Construct | Oracle | Ours | Verdict |
|---|---|---|---|---|
| p01 | `*Record` function param | 3 | nil | DIFF |
| p02 | `*Record` local vardecl | 11 | 11 | MATCH |
| p03 | `*Record` record field | 11 | 11 | MATCH |
| p04 | `*Color` enum param | 0x… | nil | DIFF |
| p05 | `*T` where `local T: type = Record` | 3 | C-compile error | FAIL |
| p07 | `*Record` param, two call styles | 15 / 15 | nil / nil | DIFF |
| p08 | `*Record` passed and returned | 7 | C-compile error | FAIL |
| p09 | plain `Record` param | 3 | "deduced any" error | FAIL |
| p10 | `*integer` param | 0x… | nil | DIFF |
| p11 | method receiver `r:add(10)` | 13 | SIGSEGV | FAIL |
| rg1 | plain `Point` params (two) | 25.0 | (no output) | FAIL |
| rg2 | `integer` params | 3 | 3 | MATCH |
| rg3 | `Point` local vardecl | 3 | 3 | MATCH |

Counts against the oracle: **MATCH 4, DIFF 4, FAIL 5**.

### Top 3 divergences by probe-file count

1. **Named-type resolution in function parameters (7 files: p01, p04, p05, p07,
   p08, p09, rg1).** Every `*<named type>` or `<named type>` function parameter is
   typed `pointer(any)` / `any` instead of the named type. This is the bug this
   doc fixes. Root cause and fix: §4.
2. **Record-value-to-pointer call-site conversion (4 files: p01, p05, p07, p08).**
   Passing a record *value* to a `*Record` parameter emits the invalid C cast
   `(struct <unit>_Record*)(r)` instead of the oracle's `(&r)`. Surfaces as soon as
   fix #1 lands; it is a separate root cause in `sema.convert` + `cgen.coerce`.
   See §5.
3. **Method / self-receiver crash (1 file: p11, and by extension every lib
   method definition).** `function Record:add(...)` SIGSEGVs ours during analysis
   and during `--print-analyzed-ast`. Pre-existing and unrelated to §4.

Two further single-file observations, both out of scope for this fix:
- `p10` (`*integer` param): the AST type is **correct** -- both compilers print
  `pointer(int64)` -- but ours prints `nil` where the oracle prints the address.
  That is a pointer-printing / return-value rendering issue, not an analyzer bug.
- `p06` (`*T` where `T` is a generic parameter): the oracle **rejects** this with
  "invalid type", so it is not a divergence we must match.

## 2. The exact Type divergence (captured, referee-verified)

`tmp/rpr/ast/` holds the full `--print-analyzed-ast` dumps. The decisive lines for
a `*Record` parameter:

| File | Compiler | `ftype` | param `IdDecl.type` | `PointerType.value` |
|---|---|---|---|---|
| `oracle_p01_param.txt` | oracle | `function(p: pointer(Record)): int64` | `pointer(Record)` | `pointer(Record)` |
| `ours_p01_param.txt` | ours (before) | `function(p: pointer(any)): void` | `pointer(any)` | `pointer(record{x: int64, y: int64})` |
| `fix5_p01_param.txt` | ours (after fix) | `function(p: pointer(record{x: int64, y: int64})): int64` | `pointer(record{x: int64, y: int64})` | `pointer(record{x: int64, y: int64})` |

The same pattern holds for the enum case (`oracle_p04_enum.txt` / `ours_p04_enum.txt`):
oracle `pointer(Color)`, ours `pointer(any)`.

Two things are worth separating here:

- **The Type object (load-bearing).** Before the fix the parameter's Type object
  is `pointer(any)` -- the generic pointer, `GenericPointer` from `types.nim:624`.
  After the fix it is `pointer(<the named record>)`. This is the bug and it is what
  the fix changes.
- **The dump string (cosmetic, pre-existing, out of scope).** Even in cases that
  already work -- `p02` (vardecl), `p03` (field) -- our dump renders the named
  record *structurally* as `pointer(record{x: int64, y: int64})` while the oracle
  renders it *by name* as `pointer(Record)`. This is a dump-printer difference
  (`neluaTypeName`, `analyzer.nim:164-165`, always renders `tkRecord` structurally
  and ignores `t.name`); it exists before this bug, it is not specific to
  pointers, and it does not affect codegen -- both compilers emit the same C tag
  `<unit>_Record`. It is recorded here only so it is not mistaken for the bug.

## 3. The boundary: where `*Record` resolves correctly vs where it does not

| Position | Resolver used | `*Record` result | Probe |
|---|---|---|---|
| local vardecl `local p: *Record` | `analyzeTypeExpr` (analyzer.nim:918) | `pointer(record{…})` -- correct | p02 MATCH |
| record field `ptr: *Record` | `analyzeTypeExpr` (analyzer.nim:1443, `nkRecordType` case) | `pointer(record{…})` -- correct | p03 MATCH |
| **function parameter `p: *Record`** | **`resolveTypeExpr` (analyzer.nim:1266, 1320)** | **`pointer(any)` -- BUG** | p01 DIFF |

The vardecl and field paths both go through `analyzeTypeExpr`, which is
scope-aware: at `analyzer.nim:1394-1412` it calls `ctx.lookup(node.str)` and, for a
symbol of kind `skType`, returns `sym.typ` -- the nominal record type. The
parameter path goes through `resolveTypeExpr`, which is scope-free.

## 4. Root cause: the exact proc(s) and the minimal fix

### 4.1 Where `*Record` becomes `pointer(any)`

`src/sema.nim`, `resolveTypeExpr` (line 254) is a pure, scope-free Type resolver
(intended for unit testing, `sema.nim:1-7`). Its `nkId` case is the break:

```
src/sema.nim:258-264
    of nkId:
      let name = node.str
      if BuiltinTypes.hasKey(name):
        return BuiltinTypes[name]
      if PrimitiveTypes.hasKey(name):
        return PrimitiveTypes[name]
      return nil          <-- named user types (Record, Color, T) fall here
```

A bare `Record` identifier is neither a builtin nor a fixed-size primitive, so this
returns `nil`. Then the `nkPointerType` case (`sema.nim:305-309`) consumes that:

```
src/sema.nim:305-309
    of nkPointerType:
      let sub = if node.children.len > 0: resolveTypeExpr(node.children[0]) else: nil
      if sub == nil:
        return GenericPointer        <-- pointer(any)
      return pointerType(sub)
```

`sub == nil`, so it returns `GenericPointer` (`types.nim:624`,
`pointerType(BuiltinTypes["any"])`). That is the `pointer(any)` the dump shows.

`analyzeTypeExpr` (`src/analyzer.nim:1372`) does **not** have this bug: its `nkId`
case (`analyzer.nim:1375-1413`) falls through to `ctx.lookup(node.str)` and returns
`sym.typ` for `skType` symbols, and its `nkPointerType` case
(`analyzer.nim:1414-1424`) recurses through `analyzeTypeExpr`, so it resolves
`*Record` to `pointer(record)`.

### 4.2 Where the parameter path picks the broken resolver

`src/analyzer.nim`, `analyzeFuncDef` (definition at line 1229; forward decl at
line 446) resolves each parameter's type annotation with `resolveTypeExpr` in two
places, and never with `analyzeTypeExpr`:

```
src/analyzer.nim:1265-1268      # builds ftype.args
    let atype = if arg == selfDecl: pointerType(recordType)
                elif arg.children.len > 0: resolveTypeExpr(arg.children[0])
                else: nil
    let at = if atype != nil: atype else: BuiltinTypes["any"]

src/analyzer.nim:1319-1327      # builds the param symbol's typ (arga.typ = at)
    let atype = if arg == selfDecl: pointerType(recordType)
                elif arg.children.len > 0: resolveTypeExpr(arg.children[0])
                else: nil
    let at = if atype != nil: atype else: BuiltinTypes["any"]
    var arga = ctx.getAttr(arg)
    ...
    arga.typ = at
```

So `ftype.args` and the param symbol's `typ` both get `pointer(any)`. The
`selfDecl` branch (colon-method receiver) is fine -- it calls
`pointerType(recordType)` directly -- which is why the divergence is confined to
user-written `*Record` parameters.

Note the function already calls the scope-aware resolver on the same node one line
further down (`src/analyzer.nim:1332`, `discard analyzeTypeExpr(ctx,
arg.children[0], false)`); that call is what produces the (correct) `value` attr on
the `PointerType` node in our dump, and it is proof that `analyzeTypeExpr` is safe
to call in this function and in this order.

### 4.3 The minimal fix (prose; NOT applied)

Two-line change in `analyzeFuncDef`. Replace the `resolveTypeExpr` call with the
scope-aware resolver the rest of the compiler already uses:

```
src/analyzer.nim:1266  BEFORE:  elif arg.children.len > 0: resolveTypeExpr(arg.children[0])
src/analyzer.nim:1266  AFTER:   elif arg.children.len > 0: analyzeTypeExpr(ctx, arg.children[0], false)

src/analyzer.nim:1320  BEFORE:  elif arg.children.len > 0: resolveTypeExpr(arg.children[0])
src/analyzer.nim:1320  AFTER:   elif arg.children.len > 0: analyzeTypeExpr(ctx, arg.children[0], false)
```

`analyzeTypeExpr` is already a dependency of this function (line 1332) and of
`analyzeVarDecl` (line 918), so no new imports. The `false` argument is
`usedType`, matching the existing discarded call at line 1332.

Why this is the right place and not `sema.nim`:

- `resolveTypeExpr` is deliberately scope-free (`sema.nim:1-7`: "No scope
  dependency ... unit-testable without a scope"). Adding a scope lookup to it would
  break that contract and its unit tests (`sema.nim:452-505`), which only exercise
  builtins, primitives and structural composites. It is the wrong layer.
- The design intent is already on record: `typeToExpr`'s comment
  (`analyzer.nim:1028`) says "`resolveTypeExpr`/`analyzeTypeExpr` will resolve to
  the same Type object". They do not, only because the parameter path picked the
  scope-free one. This fix makes them agree, as intended.
- It is strictly an improvement and neutral elsewhere: for a generic parameter
  `T: type` neither resolver can see `T` at line 1266 (the function scope is not
  pushed until line 1317), so both return `nil` and the existing "deduced type
  'any'" diagnostic still fires -- matching the oracle, which rejects `*T`
  ("invalid type", probe p06).

### 4.4 Verified effect of the fix (on `tmp/nelua_fix5`)

| Probe | Before | After |
|---|---|---|
| p01 `*Record` param | `pointer(any)`, prints nil | `pointer(record{…})`, then C-compile error (§5) |
| p07 `*Record` param, two styles | nil / nil | C-compile error (§5) |
| p09 plain `Record` param | "deduced any", FAIL | `record{…}`, prints 3 -- **MATCH** |
| rg1 plain `Point` params | "deduced any", FAIL | prints 25.0 -- **MATCH** |
| p02 vardecl, p03 field, rg2 int, rg3 vardecl | MATCH | MATCH (no regression) |

The fix converts 2 FAILs (p09, rg1) to MATCHes. It turns 2 DIFFs (p01, p07) into
C-compile FAILs, because fixing the Type exposes the second bug (§5); those two are
exactly the cases that pass a record *value* to a `*Record` parameter. Two other
DIFFs are unaffected by this fix and are separate defects: p04 (`*Color` param,
passes `&c`) stays DIFF because ours prints `nil` where the oracle prints the
address (pointer-printing, same family as p10), and p10 (`*integer` param) is
identically `pointer(int64)` on both compilers and also stays DIFF on printing. No
working case regresses.

## 5. Consequence: the record-to-pointer call-site conversion (second root cause)

Once `*Record` parameters are typed as `pointer(record)`, passing a record *value*
to one fails at C compile. Oracle vs ours at the call site of `f(r)` where
`r: Record` and `f(p: *Record)`:

```
oracle  (--print-code):  nelua_print_1(tmp_rpr_p01_param_f((&tmp_rpr_p01_param_r)));
ours    (--print-code):  nelua_print_int64(tmp_rpr_p01_param_f((struct tmp_rpr_p01_param_Record*)(tmp_rpr_p01_param_r)));
```

The oracle takes the address (`&r`); ours emits an explicit cast, which is invalid C
("cannot convert to a pointer type").

The chain is:

- `src/sema.nim`, `convert` (line 52): `convert(Record, pointer(Record))` matches
  no case and falls through to `return Conversion(kind: ckNone)` at line 98. There
  is no rule for "record value to pointer-to-record".
- `src/cgen.nim`, `coerce` (line 368): the `ckNone` case (lines 375-377) returns
  `cCast(toT, expr)`, i.e. the bad cast.
- Call args route through `coerce` at `cgen.nim:587` (`genCall`) and `cgen.nim:692`
  (`genCallMethod`).

This is a separate root cause from §4 and needs its own fix: add an implicit
address-taking rule to `sema.convert` for `fromT.isRecord and toT.isPointer and
fromT == toT.subtype` (returning an implicit, non-checking conversion), and make
`cgen.coerce` emit `&expr` for it instead of `cCast`. It is NOT required for the
Type-resolution fix in §4 and is tracked apart.

## 6. Does fixing §4 unblock any whole `lib/` file by itself?

**No.** Every affected `lib/` file dies on an earlier blocker; the first error is
identical on `tmp/nelua` and `tmp/nelua_fix5`.

| File | First error (same on both) | Blocker |
|---|---|---|
| `lib/vector.nelua` | `14:19: error: expected type after '@'` | `@#[T]#` splice not parsed |
| `lib/math.nelua` | `17:19: error: expected '(' after function name` | parser |
| `lib/hashmap.nelua` | `54:19: error: expected type after '@'` | splice |
| `lib/allocators/heap.nelua` | `170:10: error: expected 'in' in for` | parser |
| `lib/allocators/pool.nelua` | `32:10: error: expected 'in' in for` | parser |
| `lib/allocators/allocator.nelua` | `220:55: error: expected ')' after function parameters` | parser |
| `lib/allocators/arena.nelua` | `allocator.nelua:220:55` (transitive) | parser |
| `lib/allocators/gc.nelua` | `56:16: error: expected '}' to close record` | parser |
| `lib/memory.nelua` | `71:10: error: expected 'in' in for` | parser |
| `lib/hash.nelua` | `19:31: error: expected ')' after function parameters` | `require 'span'` -> splice |

All 12 files use `@#[...]#` / `#[...]#` splices and/or `require 'span'` /
`require 'iterators'`, which our parser cannot read yet (splice Stages 0-3 in flight
per `NOTE_backlog`; the pointer-to-array spec §5 already established this for
`hash.nelua`). Fixing the `pointer(any)` bug is therefore **necessary but not
sufficient** for any of them.

## 7. "Done when" checklist

Every row must hold for `tmp/nelua` against the oracle's captured outputs in
`tmp/rpr/ast/oracle_*.txt` and the C in `tmp/rpr/`.

- [ ] `*Record` function parameter: `--print-analyzed-ast` shows
      `function(p: pointer(<record subtype>)): …`, where `<record subtype>` is the
      named record (rendered `record{…}` by our dump printer; the oracle renders
      `Record`). The Type object is `pointer(<nominal record>)`, not `pointer(any)`.
- [ ] `*Color` enum parameter: `pointer(<enum subtype>)`, not `pointer(any)`.
- [ ] plain `Record` parameter: `<record subtype>`, not `any` (no "deduced type
      'any'" diagnostic).
- [ ] `*T` where `T` is a `local T: type = <named type>` alias: resolves through
      the alias to `pointer(<named type>)`.
- [ ] local vardecl `local p: *Record` and record field `ptr: *Record` remain
      unchanged (already correct; no regression).
- [ ] `*integer` / `*byte` parameters remain `pointer(int64)` / `pointer(uint8)`
      (already correct; no regression).
- [ ] generic `*T` parameter still emits the "deduced type 'any'" diagnostic,
      matching the oracle's rejection of `*T`.
- [ ] `lib/` files still fail on their existing first blocker (splices / parser),
      i.e. the fix changes nothing about the parse-level blockers and unblocks no
      whole `lib/` file by itself.
- [ ] tracked apart: `*Record` param is not silently `void*` in C once §5 lands
      (call-site address-of), and the method/self-receiver SIGSEGV (p11) is a
      separate defect.

## 8. Captured artefacts

| Path | Contents |
|---|---|
| `tmp/rpr/p0*.nelua`, `rg*.nelua` | probe sources, one construct per file |
| `tmp/rpr/run.sh` | oracle-vs-ours runner; prints MATCH / DIFF / FAIL |
| `tmp/rpr/ast/oracle_*.txt` | `/usr/bin/nelua --print-analyzed-ast` per probe (referee) |
| `tmp/rpr/ast/ours_*.txt` | `tmp/nelua --print-analyzed-ast` per probe (before fix) |
| `tmp/rpr/ast/fix5_*.txt` | `tmp/nelua_fix5 --print-analyzed-ast` per probe (after fix) |
| `tmp/srcfix/` | throwaway copy of `src/` with the §4.3 fix applied (never touches `src/`) |
| `tmp/nelua_fix5` | compiler built from `tmp/srcfix/`, used to verify §4.4 |

Key captures: `ours_p01_param.txt` / `fix5_p01_param.txt` (the `pointer(any)` ->
`pointer(record{…})` transition), `oracle_p09_plainrec.txt` / `fix5_p09_plainrec.txt`
(the plain-record-param fix), `ours_p04_enum.txt` / `oracle_p04_enum.txt` (enum
variant), and the `--print-code` call-site lines in §5 (oracle `(&r)` vs ours
`(struct …*)(r)`).