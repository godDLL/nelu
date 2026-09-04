# Record / Enum / Method Design — Nelua Clean-Room Reimplementation

Status: design-pass output. Single source of truth for the follow-up implementation
agent. `plan/` is gitignored scratch — do not commit this file, do not copy it into `src/`.

---

## 0. Correction to the task premise

The task brief describes `@record{}`, `@enum(integer){}`, `@enum(uint32){}`,
record literals, and colon-methods as *new Nelu extensions*. That premise is wrong.

**These are ORACLE PARITY features.** `/usr/bin/nelua` (0.2.0-dev) compiles and runs
all four target examples correctly:

| example | oracle exit | oracle output |
|---|---|---|
| `examples/fibonacci.nelua` | 0 | `55 55 55 55` |
| `examples/matmul.nelua` | 0 | `-18.8963499125` |
| `examples/record_inheretance.nelua` | 0 | `rectangle area 4.0 / circle area 3.14 x2 sections` |
| `examples/mersenne.nelua` | 0 | `0.8780107 / 0.2555161 / 0.4640734 / 0.94218546979306 / 0.79106567887208 / 0.0079998746971573` |

So this is a **parity gap**, not an extension. The clean-room reimplementation is
missing the type-system seams that the oracle already has. This doc specifies how
to close that gap. Nothing here invents new language surface.

---

## 1. Scope

### 1.1 In scope

- `@record{ field: type, ... }` — nominal record type definition.
- `@enum(integer){ F0=v0, F1, ... }` and `@enum(uint32){ ... }` — nominal enum
  type definition with an explicit underlying primitive in parens.
- Record literals / constructors: `local P = @record{x: number, y: number};
  p = P{x = 2, y = 3}`.
- Colon methods: `function R:m(args): ret ... end`, `recv:m(args)`,
  `R.m(args)` (static / dot-index call).
- Enum field access: `E.FIELD` (DotIndex), constant-folded to the field integer
  value.
- Record field access: `r.field` (DotIndex), `rp->field` (pointer-to-record).
- The underlying primitive of `@enum(primitive){...}` parsed from the
  parenthesized expression.

### 1.2 Explicitly out of scope (do not implement here)

- Bare `record {...}` / `union {...}` / `enum {...}` keywords — already in the
  clean-room; `@` is the only new surface.
- Generics, `@sequence`, `@array` — `matmul` uses these; out of the minimum
  viable subset.
- Preprocessor `#[ ... ]#` and `##[[ ... ]]` — `record_inheretance` and
  `fibonacci` (via `math.nelua`) use these; out of minimum viable.
- `switch / case / else` — `record_inheretance` uses this; out of minimum viable.
- C-keyword field-name mangling (§9.2 of language-review.md: a record field
  named `int`/`char`/`...` breaks C codegen because `cIdent` does not mangle C
  reserved words). Out of minimum viable; note as a follow-up.
- Auto-incrementing enum fields whose *first* field has no value — the oracle
  rejects this ("first enum field requires an initial value"). Keep that reject.

---

## 2. Acceptance criterion

### 2.1 Primary (P2-free, verifiable immediately after the type-system work)

A synthetic program `tmp/record_enum_check.nelua` (throwaway, in `$PROJECT/tmp/`,
gitignored) that exercises every in-scope feature with a `<literal>` for-loop
bound so it does not hit the exclusive-for parser bug P2:

```
local MASK = @enum(uint32){ LOWER = 0x7fffffff, UPPER = 0x80000000 }
local Rect = @record{ w: number, h: number, kind: MASK }

function Rect:area(): number
  return self.w * self.h
end

local r: Rect = Rect{ w = 4, h = 3, kind = MASK.UPPER }
local a: number = r:area()
local k: MASK = r.kind

for i = 0, <3 do
  print(a, integer(k), integer(MASK.LOWER), integer(MASK.UPPER))
end
```

Expected output (exit 0):

```
12.0	2147483648	2147483647	2147483648
12.0	2147483648	2147483647	2147483648
12.0	2147483648	2147483647	2147483648
```

This must compile and run after P0, P1, and the type-system work in §5–§7 land.
It does not require P2, generics, preprocessor, or switch.

### 2.2 Secondary (full example, requires P2 as well)

`examples/mersenne.nelua` compiled by the patched compiler must produce EXACTLY:

```
0.8780107
0.2555161
0.4640734
0.94218546979306
0.79106567887208
0.0079998746971573
```

with exit code 0. `mersenne` is the cleanest of the four real examples: it uses
`@record`, `@enum(uint32)`, record literals, colon methods, method calls, enum
field access, record field access, array indexing, bitwise ops, and for-loops.
It uses **none** of generics, preprocessor, or switch. Its only extra dependency
beyond §2.1 is the exclusive-for parser bug P2 (line 16:
`for i=1_u32,<MT19937_N do` with a `~`/`>>` body).

---

## 3. Prerequisites — parser bugs owned by the pattern-matching agent

These three are *blocking* and live in `src/parser.nim`. They are not part of the
type-system design but must land (or be coordinated) for any of the examples to
compile. Each is stated with an exact location and a one-line fix.

### P0 — `@` is not consumed (blocks everything)

`src/parser.nim` lines 325–329, `of tkAt:` in `parsePrimary`:

```nim
of tkAt:
  let ty = p.parseType()      # current token is still '@'; parseType returns nil
  if ty != nil:
    return newType(ty)
  raise ParseError(loc: t.loc, msg: "expected type after '@'")
```

Fix: add `p.advance()` as the first statement in this branch, before
`p.parseType()`. Without it every `@record`, `@enum`, and `@*T` cast raises
"expected type after '@'", which is the single transitive blocker for all four
examples.

### P1 — `@enum(primitive){...}` underlying type is not parsed

`src/parser.nim` lines 139–152, `of "enum":` in `parseType`:

```nim
of "enum":
  p.advance()
  p.expect(tkLBrace, "expected '{' after enum")   # fails on '@enum(integer){'
  ...
  base = newEnumType(fields)
```

Fix: after `p.advance()`, if `p.check(tkLParen)`, parse a parenthesized type
expression and pass it as the `primtype` first child to `newEnumType(fields,
primtype)`. `newEnumType` already accepts a `primtype` first child (see
`src/ast.nim` ~line 94); `src/sema.nim` `resolveTypeExpr` for `nkEnumType`
already handles a non-EnumField first child as the underlying type. The only gap
is the parser not producing that first child.

### P2 — exclusive-for with an identifier bound misparses a `~`/`>>` body

Pre-existing, unrelated to records/enums. Symptom: `for i=1_u32,<IDENT do
... ~ (... >> ...) end` raises "unexpected token", while the same body with a
literal bound `<4` or an expression bound `<N-M>` parses fine. Verified by
probing bound × body combinations. `mersenne` line 16 hits exactly this
(`<MT19937_N` identifier bound with a `~`/`>>` body). Owned by the parser agent;
flag for coordination.

---

## 4. Syntax grammar (the new surface)

```
typedef      := '@' ( record_def | enum_def )
record_def   := 'record' '{' [ field_decl { ',' field_decl } ] '}'
field_decl   := IDENT ':' type_expr
enum_def     := 'enum' '(' primitive_type ')' '{' enum_field { ',' enum_field } '}'
enum_field   := IDENT [ '=' expr ]
primitive_type := 'integer' | 'uint32' | 'int32' | 'float' | 'float32' | 'float64' | 'uintptr' | 'usize' | ...

record_literal := IDENT '{' [ pair { ',' pair } ] '}'
pair          := IDENT '=' expr

method_decl   := 'function' record_name ':' IDENT [ '(' params ')' ] [ ':' rets ] block
method_call   := expr ':' IDENT '(' [ args ] ')'        # colon call
              |  record_name '.' IDENT '(' [ args ] ')'  # static / dot-index call
record_name   := IDENT | qualified_path
```

Notes:

- `@record{}` (empty) is legal; the oracle emits an empty struct.
- The first enum field **must** carry an explicit value; subsequent fields
  auto-increment by 1. The oracle rejects `@enum(integer){ RED, GREEN, BLUE }`
  with "first enum field requires an initial value". Preserve that check.
- Enum fields are **not** bare names — they are always accessed as
  `E.FIELD` (DotIndex). `RED` alone is not a reference to `C.RED`.
- `@*T` (pointer-to-type cast) and `@T` (type reference) reuse the same `@`
  path through `parseType` once P0 lands; no new grammar is needed.

---

## 5. AST shapes

No new AST shapes are required. The existing shapes in Appendix A of
`language-review.md` carry everything:

| surface | AST node | key children |
|---|---|---|
| `@record{...}` | `nkRecordType` | `[RecordField...]` where `RecordField = (name, typeexpr)` |
| `@enum(p){...}` | `nkEnumType` | `[primtype-Node, EnumField...]` where `EnumField = (name, value:Node?)` |
| `Record{ x = 1, y = 2 }` | `nkCall` with `nkInitList` arg | caller = type symbol; children = `[InitList]` |
| `r.x` / `E.FIELD` | `nkDotIndex` | `(name, expr)` |
| `r:m()` | `nkColonIndex` inside `nkCall` | `(name, expr)`; calleeSym set by analyzer |
| `function R:m()` | `nkColonIndex` as FuncDef name | `nameNode.children[0]` = record name node; `nameNode.str` = method name |

The only AST-level care needed:

- `nkEnumType`'s first child must be allowed to be a non-`nkEnumField` node (the
  primitive type expression). `src/sema.nim` already tolerates this; the parser
  must produce it (P1).
- `nkColonIndex` already carries `nameNode.children[0]` (the receiver/record
  name) and `.str` (the method name). The analyzer must use both.

---

## 6. Type representation (`src/types.nim`)

### 6.1 Nominal identity for `@record` / `@enum`

This is the central design decision. **`@record{...}` and `@enum{...}` are
NOMINAL, not structural.** Each definition site produces a distinct `Type`
object, even when two definitions are structurally identical.

Verified empirically:

```
local A = @record{ x: number }
local B = @record{ x: number }
local a: A = A{x = 1}
local b: B = B{x = 2}
a = b          -- ERROR: no viable type conversion from 'B' to 'A'
```

The oracle emits `typedef struct prov16_A prov16_A;` and `typedef struct
prov16_B prov16_B;` — two separate C tags, no sharing. Cross-assignment is a
type error.

This is a **departure from the existing clean-room behavior**. The current
`recordType(fields)` / `enumType(fields)` constructors in `types.nim` canonicalize
via `TypeCache` keyed by structural `typeKey`, so structurally-equal records
share one `Type`. That is correct for *bare* `record {...}` type expressions but
wrong for `@record`/`@enum`.

Changes to `types.nim`:

1. Add two nominal constructors that bypass `TypeCache`:

```nim
proc nominalRecordType*(name: string, fields: seq[Field]): Type =
  var t = Type(kind: tkRecord, name: name)
  t.fields = fields
  t.typeid = newTypeId()
  t

proc nominalEnumType*(name: string, underlying: Type, enumFields: seq[EnumField]): Type =
  var t = Type(kind: tkEnum, name: name, subtype: underlying)
  t.enumFields = enumFields
  t.typeid = newTypeId()
  t
```

2. The analyzer sets `t.name` at the binding site. For `@record`/`@enum` the C
   tag must be `<unit>_<alias>` (e.g. `examples_mersenne_mt19937`,
   `prov16_A`). Set:

```
t.name = unitname & "_" & aliasName
```

   so that the existing `cTag(t)` (which returns `t.name` verbatim when it is a
   valid C identifier) produces the oracle's tag without further change. Do **not**
   also run these through `TypeCache`.

3. `Type.methods` — a per-type method table for record types:

```nim
methods: Table[string, MethodDesc]
```

where `MethodDesc` carries the resolved method symbol, its codename, and its
function type:

```nim
type MethodDesc* = object
  sym: Sym
  codename: string
  ftype: Type
```

Populated by `analyzeFuncDef` for colon methods; consulted by `analyzeDotIndex`
and the method-call path. Dispatch is by receiver type — because each record
type is nominal and distinct, a method table per `Type` gives exactly the
oracle's receiver-type dispatch (verified: `A.foo` and `B.foo` are different
functions even when `A` and `B` are structurally equal).

### 6.2 Enum value representation

An `@enum` type carries:

- `subtype` = the underlying primitive `Type` (`integer` → `int64_t`,
  `uint32` → `uint32_t`, etc.).
- `enumFields` = ordered `seq[EnumField]` with `name` and resolved integer
  `value`.

Enum fields are **compile-time constants**, not runtime values and not C enum
members. The analyzer constant-folds `E.FIELD` into the integer literal at the
field's `value`, so `cgen` never emits enum field access as code — it emits a
number. (The oracle's `MASK.UPPER` / `MASK.LOWER` vanish from the lowered C,
replaced by `0x7fffffff` / `0x80000000`.)

Auto-increment: field `i`'s value = field `i-1`'s value + 1, when field `i`
has no explicit `= expr`. The first field without an explicit value is a
semantic error (reject, matching the oracle).

---

## 7. Lowering to C (the oracle's exact shape)

Verified by `nelua --print-code` on `prov16` and `mersenne`:

### 7.1 Record

```
typedef struct <unit>_<Alias> <unit>_<Alias>;
struct <unit>_<Alias> {
  <cType(field0.type)> <cIdent(field0.name)>;
  <cType(field1.type)> <cIdent(field1.name)>;
  ...
  NELUA_STATIC_ASSERT(sizeof(<unit>_<Alias>) == <size> &&
      NELUA_ALIGNOF(<unit>_<Alias>) == <align>, "...");
};
```

- `cIdent(field.name)` already sanitizes; the §9.2 C-keyword issue is out of
  scope for the minimum viable subset.
- The `NELUA_STATIC_ASSERT` line is already emitted by the existing record
  path; verify it is preserved when switching to the nominal constructor.

### 7.2 Enum

```
typedef <cType(underlying)> <unit>_<Alias>;
```

**No C `enum` body.** The current `emitTypedef` for `tkEnum` emits a real
`typedef enum <tag> { name = value, ... } <tag>;` — this must change. The enum
fields are *not* emitted as C enum members; they are compile-time constants
folded away by the analyzer.

`cType(underlying)` for the primitives: `integer` → `int64_t`, `uint32` →
`uint32_t`, `float` → `float`, `float64` → `double`, etc. (use the existing
`cType` / primitive C-name table).

### 7.3 Record constructor / literal

`P{ x = 2, y = 3 }` lowers to a C compound literal:

```
((struct <tag>){ .x = 2.0, .y = 3.0 })
```

Designated initializers in declaration order. Nested arrays/records recurse:
`{ i = 0, v = { ... } }` → `((struct <tag>){ .i = 0U, .v = ((...array...)){ ... } })`.
The existing `genInitList` already handles designated initializers for record
fields; the constructor case wires the outer `(...){...}` wrapper.

### 7.4 Method definition

```
static <ret-c-type> <unit>_<Record>_<method>(<record-tag>* self, <params>)
```

- Codename: `<unit>_<RecordAlias>_<methodName>`. Since `RecordType.name` is
  already `<unit>_<RecordAlias>`, the codename is
  `recordType.name & "_" & methodName`.
- `self` is injected as the **first parameter**, type `*<record-tag>` (pointer
  to the record). It is implicit — it does not appear in the source parameter
  list.
- `static` linkage, matching the oracle.

### 7.5 Method call

`recv:m(args)` → `<method-codename>(&recv, args)`.

The `(&recv)` is mandatory: the method's first parameter is a pointer, so the
receiver is passed by address. This is what the oracle emits
(`examples_mersenne_mt19937_random_float32((&examples_mersenne_default_mt19937))`)
and what `genCallMethod` already attempts; it just needs `calleeSym` wired by
the analyzer.

`R.m(args)` (dot-index / static call) → `<method-codename>(args)` — no receiver,
no `&`.

---

## 8. Analyzer changes (`src/analyzer.nim`)

These are the type-system seams. Each is a localized change; none requires a new
pass.

### A1 — Resolve user-defined type aliases in annotation position

`analyzeTypeExpr` `of nkId:` (line ~1132–1148) currently consults only
`BuiltinTypes` and `PrimitiveTypes`, returning `nil` for a user type alias like
`Point` or `mt19937`. This breaks `local p: Point`, `local q: *Point`,
`local mt: mt19937`, and the record-constructor callee.

Fix: after the builtin/primitive lookup fails, consult the scope chain:

```nim
let sym = ctx.lookup(node.str)
if sym != nil and sym.typ != nil:
  var a = ctx.getAttr(node)
  a.name = node.str
  a.typ = BuiltinTypes["type"]
  a.value = node.str
  a.vardecl = true
  return sym.typ
return nil
```

### A2 — `nkEnumType` uses the parsed underlying type

`of nkEnumType:` (line ~1202–1215) always builds `enumType(BuiltinTypes["integer"], ef)`.
Fix: scan `node.children` for the first non-`nkEnumField` child and use it as the
underlying type; fall back to `BuiltinTypes["integer"]` when absent. This is the
analytic counterpart of parser fix P1.

### A3 — `analyzeDotIndex` resolves enum fields and record methods

Current (line ~628–640): only resolves record **fields**; unresolved DotIndex
falls back to `BuiltinTypes["any"]`.

Extend:

```nim
if bt != nil and bt.kind == tkEnum:
  for ef in bt.enumFields:
    if ef.name == node.str:
      a.typ = bt.subtype          # the field's value has the underlying type
      a.isComptimeValue = true
      a.comptimeValue = ef.value   # integer literal, for constant folding
      break
if bt != nil and bt.kind == tkRecord:
  for f in bt.fields:            # fields win over methods
    if f.name == node.str:
      a.typ = f.typ; break
  if a.typ == nil and bt.methods.hasKey(node.str):
    let m = bt.methods[node.str]
    a.isMethodCall = true
    a.calleeSym = m.sym
    a.methodCodename = m.codename
    a.typ = m.ftype
```

Enum field access is constant-folded: when `a.isComptimeValue`, the emitter
emits the integer literal directly (no runtime load). Record method access sets
`isMethodCall` so the call path emits the mangled codename instead of a generic
`base.field` load.

### A4 — `analyzeExpr` `nkColonIndex` resolves method calls

`of nkColonIndex:` (line ~772–782) currently sets `typ = any` and does not
resolve the method. Fix: treat `recv:m` as a method-call expression — resolve
`recv`'s type, look up `m` in that type's `methods`, set `calleeSym` /
`methodCodename` / `typ` exactly as in A3's method branch, so the enclosing
`nkCall` emits a method call rather than a generic call.

### A5 — `analyzeCall` constructor case

`analyzeCall` (line ~447–583) treats `P{ x = 1 }` as an unknown function call
and falls through to "build a generic function type". Add a constructor case at
the top of the callee-resolution logic:

```nim
# constructor: callee is a type symbol whose type is tkRecord/tkUnion/tkEnum,
# and the single argument is an InitList
let calleeSym = ...
if calleeSym != nil and calleeSym.typ != nil and
   calleeSym.typ.kind in {tkRecord, tkUnion, tkEnum} and
   node.children.len == 1 and node.children[0].kind == nkInitList:
  let ct = calleeSym.typ
  discard analyzeInitList(ctx, node.children[0], ct)
  a.typ = ct
  a.isConstructor = true
  return ct
```

`isConstructor` flags the node for `genCall` to emit a compound literal.

### A6 — `analyzeFuncDef` colon-method handling

`analyzeFuncDef` (line ~1037+) already extracts `nameStr` from a colon-method
`nkColonIndex` name node and builds a codename. What it lacks is the implicit
`self` parameter and the method registration.

Extend:

```nim
let nameNode = node.children[0]
let nameStr = nameNode.str
var recordType: Type = nil
var isMethod = false
if nameNode.kind == nkColonIndex:
  let recNameNode = nameNode.children[0]
  let rsym = ctx.lookup(recNameNode.str)
  if rsym != nil and rsym.typ != nil and rsym.typ.kind == tkRecord:
    recordType = rsym.typ
    isMethod = true

# inject implicit self as the first parameter
if isMethod:
  let selfDecl = newIdDecl("self", newPointerType(recordType))
  # insert at the front of the parameter list
  node.children.insert(selfDecl, 1)

let codename = if isMethod:
                 recordType.name & "_" & nameStr
               else:
                 ctx.unitname & "_" & nameStr
```

Then, after the function type is built, register the method:

```nim
if isMethod:
  recordType.methods[nameStr] = MethodDesc(
    sym: sym, codename: codename, ftype: ftype)
  a.metafunc = true
```

`self` is typed `*RecordType` (pointer to the record). The `unitname` prefix is
already part of `recordType.name` (set per §6.1.3), so the codename
`recordType.name & "_" & nameStr` yields exactly `<unit>_<Record>_<method>`.

---

## 9. Cgen changes (`src/cgen.nim`)

### C1 — Enum lowering stops emitting a C `enum`

`emitTypedef` `of tkEnum:` (line ~306–315) currently emits:

```
typedef enum <tag> { name = value, ... } <tag>;
```

Replace with the oracle shape — a typedef of the underlying type, no enum body:

```nim
of tkEnum:
  let tag = cTag(t)
  let ut = if t.subtype != nil: t.subtype else: BuiltinTypes["integer"]
  s.line "typedef " & cType(ut) & " " & tag & ";"
```

Do not emit the enum field names. They are compile-time constants folded by the
analyzer (A3) and never reach `cgen` as runtime code.

### C2 — `genCall` `nkDotIndex` emits method calls

`genCall` `of nkDotIndex:` (line ~598–600) currently emits `(cexpr)(args)`,
which is invalid when the callee is a method. Add a method branch:

```nim
of nkDotIndex:
  let ca = attrOf[node]
  if ca.isMethodCall:
    s.line ca.methodCodename & "(&" & genExpr(node.children[0]) & genArgs(node) & ")"
  else:
    s.line "(" & genExpr(node.children[0]) & genArgs(node) & ")"
```

### C3 — `genCallMethod` wiring

`genCallMethod` (line ~610–632) already prepends `(&recv)` when the first
parameter is a pointer and reads `calleeSym` from `attrOf[node].calleeSym`. It
works once A3/A4 set that attribute. No change needed beyond verifying the
attribute name matches.

### C4 — Record constructor compound literal (new)

Add a constructor emission path, triggered by `attrOf[node].isConstructor`:

```nim
if ca.isConstructor:
  let tag = cTag(calleeType)
  s.line "((struct " & tag & "){"
  s.push
  for pair in initList.children:
    s.line "." & cIdent(pair.name) & " = " & genExpr(pair.children[1]) & ","
  s.pop
  s.line "})"
```

For the top-level `local r: Rect = Rect{...}` case the assignment initializer
form `static Rect r = {.x = ...}` is also acceptable and matches the oracle's
file-scope designated-initializer output.

### C5 — `cIdent` C-keyword mangling (out of minimum viable)

`src/cemitter.nim` `cIdent` sanitizes non-alphanumeric chars but does not
mangle C reserved words, so a field named `int` emits `int`, breaking the C
compile. §9.2 of `language-review.md`. Out of the minimum viable subset because
none of the four examples use a C-keyword field name. Follow-up: mangle reserved
names with a `nl_` prefix or reject them at analysis time.

---

## 10. Minimum viable subset (what the implementation agent actually touches)

To unblock the acceptance criterion §2.1 (and, with P2, §2.2), implement exactly:

| file | change | depends on |
|---|---|---|
| `src/parser.nim` | P0 (`@` advance), P1 (`enum(primitive)` parse) | pattern-matching agent's files — coordinate |
| `src/parser.nim` | P2 (exclusive-for identifier-bound bug) | pattern-matching agent — coordinate |
| `src/types.nim` | `nominalRecordType`, `nominalEnumType`, `Type.methods` + `MethodDesc` | — |
| `src/analyzer.nim` | A1 type-alias resolution, A2 enum underlying, A3 DotIndex, A4 ColonIndex, A5 constructor, A6 colon-method | exceptions agent's files — coordinate |
| `src/cgen.nim` | C1 enum typedef, C2 method call, C4 constructor compound literal | pattern-matching/exceptions agents — coordinate |

Do **not** touch: generics, preprocessor, switch, C-keyword mangling, the
exclusive-for bug beyond P2, or any file outside the list above.

---

## 11. Open items / risks

1. **Agent ownership.** `parser.nim` is being edited by the pattern-matching
   agent; `analyzer.nim` and `cgen.nim` by the exceptions agent. The changes in
   §3 and §8–§9 are additive and low-conflict, but the implementation agent must
   sequence them so the three agents' edits land on the same `main` without
   clobbering each other's hunks. P0/P1/P2 are pre-requisites for *any* of the
   examples to parse; A1–A6 and C1–C4 are the type-system work.
2. **Nominal vs. structural interaction.** The bare `record {...}` / `union {...}`
   type expressions in the existing clean-room still use structural
   canonicalization. `@record`/`@enum` use nominal. These two paths must not
   share a `Type` object: a bare `record{x:number}` used as a function parameter
   type must remain structurally deduplicated, while `@record{x:number}` bound
   to a name must be a fresh nominal type. Keep the two constructors separate.
3. **`@*T` casts.** `(@*Rectangle)(self)` in `record_inheretance` reuses the `@`
   path. Once P0 lands, `@*T` parses as `@` → `parseType` → pointer type. No
   new work; just confirm the tkAt/nkPointerType path survives P0.
4. **Comptime constants as loop bounds.** `mersenne` uses `MT19937_N` and
   `MT19937_M` (declared `<comptime>`) as exclusive-for bounds. The for-loop
   bound evaluation must resolve these through the same scope lookup as A1.
5. **Out-of-scope examples.** `fibonacci` (needs `require 'math'` which uses
   `#[concept(...)]#` macros) and `record_inheretance` (needs switch + preprocessor)
   will not pass parity until those features land. Do not count them in the
   acceptance criterion; `mersenne` is the chosen target precisely because it
   avoids them.
6. **§9.2 C-keyword field names.** Deferred. If any future example uses a
   C-keyword field name, `cIdent` must mangle it. Tracked separately.

---

## 12. Verification recipe

After the implementation lands, from `$PROJECT`:

```bash
# 1. synthetic P2-free acceptance target
/usr/bin/nelua tmp/record_enum_check.nelua
# expect 3 identical lines, exit 0

# 2. mersenne (requires P2 as well)
/usr/bin/nelua examples/mersenne.nelua
# expect exactly:
#   0.8780107
#   0.2555161
#   0.4640734
#   0.94218546979306
#   0.79106567887208
#   0.0079998746971573
# exit 0

# 3. regression: confirm the @ fix does not break existing bare record/enum usage
/usr/bin/nelua examples/record_inheretance.nelua   # partial -- switch/preprocessor out of scope
```