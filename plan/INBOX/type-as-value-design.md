# Type-as-Value and Type-Alias Design

Status: draft. Minimal slice implemented and verified; full doc to be completed
as further forms are probed.

## 1. Purpose

Nelua treats a type name as a first-class value: a type has a runtime
representation (the `nltype` object) and a type-typed variable can hold one.
The clean-room compiler at `src/` did not yet model this correctly for the
common case of a type alias -- a `local` declared with `: type` whose init is
a named user type. That case is broken end-to-end and is the subject of this
document.

This document records the oracle's (`/usr/bin/nelua` 0.2.0-dev) exact
behaviour, records ours, bounds the scope, and designs the fix.

## 2. Oracle survey

All claims below come from an actual `/usr/bin/nelua` run captured with
`--print-ast`, `--print-analyzed-ast`, and `-c -o <file>.c`.

### 2.1 The minimal slice: `local T: type = Record`

Probe `tmp/rpr/p05_alias.nelua`:

```nelua
global Record = @record{x: integer, y: integer}
local T: type = Record
local function f(p: *T)
  return p.x + p.y
end
local r = Record{x=1, y=2}
print(f(r))
```

Oracle output: `3`, exit 0.

Oracle `--print-ast` for the `T` declaration:

```
VarDecl {
  "local",
  { IdDecl { "T", Id { "type" } } },
  { Id { "Record" } }
}
```

The `: type` annotation is an `IdDecl` child whose value is the `type` id; the
init is the plain `Id` "Record". There is no `Type` wrapper around the init --
the init is an ordinary identifier, not a type literal.

Oracle emitted C (excerpt):

```c
typedef struct p05_alias_Record p05_alias_Record;
typedef p05_alias_Record* p05_alias_Record_ptr;
struct p05_alias_Record { int64_t x; int64_t y; };
static int64_t p05_alias_f(p05_alias_Record_ptr p) { ... }
```

Three things to note:

1. The pointer parameter type is `p05_alias_Record_ptr`, the derived pointer
   typedef for the aliased record. `*T` resolved to `pointer(Record)`.
2. There is no storage and no assignment for `T`. The alias is fully erased at
   codegen -- the oracle emits nothing for it.
3. The record value `r` is passed to `f` by taking its address
   (`(&p05_alias_r)`). The call site converts a record value to a record
   pointer.

### 2.2 Type-typed variable attributes

On the analyzed tree, the oracle models a type alias as a variable
declaration whose attribute set is:

- `type` = the metatype `type` (i.e. the builtin `type` type object), and
- `value` = a lookup key naming the aliased type.

For a builtin alias (`local T: type = integer`) the key is the canonical C
name `int64`. For a named user type (`local T: type = Record`) the key is the
source identifier `Record`. This key is what the dump printer renders as
`value=` and what a later type-position lookup dereferences.

### 2.3 Forms the oracle supports

Captured and confirmed working on the oracle:

- `local T: type = Record` then `*T` in a parameter/field/return type position:
  resolves to `pointer(Record)`.
- `local T: type = (Record)` -- a parenthesized type-value init: the oracle
  accepts the parens and behaves identically to the unparenthesized form.
- `local T: type = Color` where `Color` is an enum: `*T` resolves to
  `pointer(Color)`.
- A named user type used directly as a value (`local x = Record`): binds `x`
  to the type object. The oracle accepts this but `print` rejects a `type`
  value ("cannot handle type \"type\""), so there is no observable print
  form for a bare type value.

### 2.4 Forms out of scope

- `local T: type = integer` -- the oracle accepts `integer` as an identifier
  in value position. Ours' lexer treats `integer` as a keyword and rejects it
  in expression position (a lexer/parser divergence, separate from alias
  lowering).
- `local T: type = byte` -- `byte` is registered inconsistently in ours and
  segfaults. A pre-existing builtin-registration gap.
- Splice-based aliases (`local T: type = <splice>`) -- requires Stage 4
  scope-symbol machinery, explicitly excluded.
- Generic-parameter types as alias targets -- not yet probed; deferred.

## 3. Ours: divergences

All line numbers refer to `src/analyzer.nim` at the time of writing; the fix
copy lives at `tmp/srcfix/analyzer.nim`.

### 3.1 Root cause: the alias never records its value

`analyzeVarDecl` (Stage 0 block, around the `isTypeBinding` guard) only
resolved the aliased type when the init was a type *literal* (`nkType`):

```nim
if isTypeBinding and vtype == BuiltinTypes["type"] and i < inits.len:
  let ct = analyzeTypeExpr(ctx, inits[i])
  if ct != nil:
    let tv = neluaTypeName(ct)
    sym.value = tv
    a.value = tv
```

For `local T: type = Record` the init is `nkId`, so `isTypeBinding` is false
and the block never fires. `T` is registered as an ordinary variable with no
`value`, and its init is later analyzed as an ordinary expression (a record
value), which is what produces the broken C.

### 3.2 Root cause: `*T` deref is gated on the wrong symbol kind

`analyzeTypeExpr`'s `nkId` case resolves named user types only when
`sym.kind == skType`:

```nim
if sym != nil and sym.typ != nil and sym.kind == skType:
  ...
  return sym.typ
return nil
```

A type alias `T` is registered as `skVar`, so `*T` falls through to `nil`, the
pointer case builds `pointer(void)`, and the parameter collapses to `void*`.
This is the same family as the pre-existing `*Record` parameter bug.

### 3.3 Divergence table

| Form | Oracle | Ours | Fix target |
|------|--------|------|------------|
| `local T: type = Record`, `*T` | `pointer(Record)` | `void*` | analyzer.nim Stage 0 block + analyzeTypeExpr nkId A2 block |
| `T` erased at codegen | no storage emitted | storage + init emitted | set `a.isTypeBinding` so `genVarDecl` skips it |
| `(Record)` paren init | accepted | not handled | add `nkParen` case to `analyzeTypeExpr` |
| type-as-value key | `Record` (source name) | structural `record{...}` | `typeValueKey` helper |
| `*Color` enum alias | `pointer(Color)` | `void*` then null print | same fix; remaining diff is value-to-pointer conversion, out of scope |
| `integer`/`byte` as alias target | accepted | rejected / segfault | lexer/parser and builtin registration, out of scope |

## 4. Design

### 4.1 Representation of a type alias

A type alias is a `local` variable declaration whose annotation is `: type`
and whose init is a type-as-value expression. It is represented exactly as
the oracle does:

- `attr.type` = the metatype `type` (from `BuiltinTypes["type"]`).
- `attr.value` = the lookup key (source name for user types, canonical C name
  for builtins).
- `attr.isTypeBinding` = true, so codegen emits no storage and no init.
- The symbol's `kind` stays `skVar` (it is a variable, not a type literal
  binding); the `value` field carries the deref key.

### 4.2 The lookup key

Two helpers, both added before `analyzeTypeExpr`:

`typeValueKey(node, ct)` -- produces the key. For a builtin or primitive type
it returns the canonical C name (`int64`, `uint8`). For a named user type it
unwraps any surrounding parens and returns the source identifier (`Record`,
`Color`). This is the value the oracle stores and the value `resolveTypeValue`
consumes.

`resolveTypeValue(ctx, key)` -- the inverse. Builtins and primitives are
looked up in `BuiltinTypes`/`PrimitiveTypes`. Named user types are looked up
in scope as `skType` symbols. A key that is itself a type alias (its symbol
has `typ == BuiltinTypes["type"]` and a non-empty `value`) is dereferenced
transitively. Returns `nil` when the key names no type.

### 4.3 Where the fix lands

1. `analyzeVarDecl` Stage 0 block: drop the `isTypeBinding` gate so the block
   fires for `: type` annotations whose init is a type-as-value expression.
   Compute the key with `typeValueKey`, record it on the symbol and the
   attribute, and set `a.isTypeBinding = true` so codegen erases it.
2. `analyzeTypeExpr` `nkId` case, after the existing `skType` resolution: add
   a block (A2) for a type-typed *variable* alias. When the looked-up symbol
   has `typ == BuiltinTypes["type"]` and a non-empty `value`, copy the alias
   key onto the attribute and dereference it with `resolveTypeValue`.
3. `analyzeTypeExpr`: add an `nkParen` case that unwraps to the inner type
   expression, so `local T: type = (Record)` works.
4. `analyzeExpr` `nkId` case: a type alias used as a value already resolves to
   the metatype through the existing value-position path; no change needed
   there for the minimal slice.

### 4.4 Codegen

No codegen change is needed for the minimal slice. `genVarDecl` already
erases `isTypeBinding` declarations (both the globals pass and the local init
pass `continue` on it), and the pointer type is built from the resolved
subtype, which is now correct.

## 5. Minimal first slice

Implemented in `tmp/srcfix/analyzer.nim`, verified with `tmp/nelua_fix`
through `tmp/rpr/run_fix.sh`:

- `p05_alias.nelua`: MATCH (was FAIL).
- `t_alias.nelua` (`local T = Record`, inferred): MATCH (was FAIL).
- `b_alias_splice.nelua` (`(Record)` paren init): MATCH (was FAIL).
- `b_alias_enum.nelua`: DIFF, but the type now resolves to `pointer(Color)`;
  the remaining diff is the pre-existing value-to-pointer conversion and
  pointer printing, out of scope.

No regressions: `p01_param`, `p03_field`, `p07_deref`, `p08_passreturn`,
`p09_plainrec`, `rg1`, `rg2`, `rg3` still MATCH; `p04_enum`, `p10_ptrint`
still DIFF (pointer printing, out of scope); `p06_generic` BOTH-FAIL and
`p11_method` FAIL are unchanged pre-existing defects.

## 6. Done-when checklist

- [x] `tmp/rpr/p05_alias.nelua` MATCHes the oracle.
- [x] `tmp/rpr/t_alias.nelua` MATCHes the oracle.
- [x] `local T: type = <enum alias>` then `*T`: the type resolves to
      `pointer(Color)` in ours (confirmed on `tmp/tv/t_alias_enum2.nelua`
      via `--print-analyzed-ast`: `ftype = function(p:
      pointer(enum(int64){Red=0, Green=1, Blue=2})): ...`). The remaining
      divergence -- ours prints `(null)`, oracle errors "no viable type
      conversion from 'Color' to 'pointer(Color)'" at the `f(r)` call site --
      is the pre-existing value-to-pointer conversion, out of scope.
- [ ] `local T: type = integer` no longer segfaults (out of scope: lexer
      keyword treatment).
- [x] Run `plan/examples_parity.py` through `tmp/nelua_fix`
      (via `tmp/examples_parity_fix.py`): 2 MATCH / 5 DIFF / 3 SKIP, identical
      to the pre-fix baseline. All DIFFs are pre-existing lexer/parser errors
      (`lib/math.nelua:17`, `matmul.nelua:3`, `record_inheretance.nelua:74`,
      `brainfuck.nelua:8`, `fibonacci.nelua`) -- none touch the analyzer and
      none are type-as-value forms.
- [x] Run `plan/regress.py` through `tmp/nelua_fix`
      (via `tmp/regress_fix.py`): M2 analyzed-AST 14/14 MATCH, M1 parse-AST
      12 MATCH / 13 DIFF / 3 CRASH. M1 is parser output and is byte-identical
      to the pre-fix run because the fix is confined to `analyzer.nim`; the
      M1 diffs and SIGSEGVs are pre-existing.
- [x] Confirm no `isTypeBinding` erasure regression on existing
      `@record`/`@enum` literal bindings: `p01_param`, `p03_field`,
      `p07_deref`, `p08_passreturn`, `p09_plainrec`, `rg1`, `rg2`, `rg3` all
      still MATCH through `tmp/nelua_fix`.