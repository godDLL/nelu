# Task 1 — locals-in-functions bug: characterisation

**Status:** CLOSED -- integrated into live `src/` and verified end-to-end.  The §5 recommended fix is present in `src/cgen.nim` `genVarDecl` (lines 1788-1812): a declaration pass for function-body locals gated on `isGlobal or not alreadyDeclared`, zero-initialised to match the oracle, with no `static` qualifier.  The `global`-in-function top-scope rejection the oracle enforces is also landed (`cgen.nim:1745-1748`).  Moved to `plan/DONE/`.

**Stage 5 verification (live `tmp/nelua`, `nim c -d:release` build of committed `src/`).**  All three probes MATCH the oracle exactly, exit 0:

| Probe | Oracle | Ours | Verdict |
|---|---|---|---|
| `tmp/probe1.nelua` (`local x = a + b`) | `5` | `5` | MATCH |
| `tmp/probe2.nelua` (8 forms: vardecl, no-init+assign, `do`, `for`, `while`, `repeat`, `switch`/`case`, bare local) | `11 12 13 6 6 6 100 200 900 18` | identical | MATCH |
| `tmp/probe6.nelua` (typed no-init + bare local) | `11 12` | identical | MATCH |

Every scope that funnels through `genScope` (function, `do`, `for`/`while`/`repeat`, `switch`/`case`) is covered by the single insertion at `cgen.nim:1788`, and the top-level path is untouched (`alreadyDeclared=true` avoids the duplicate-declaration regression the ticket warned about).

---

## 1. Scope — which forms of `local` are dropped

Every `local` (and `global`) variable declaration whose declaration *statement*
is emitted while `s.inFunc == true` is missing its C declaration. Only the
initializer *assignment* survives (and only when an initializer exists). With no
initializer the local vanishes entirely.

| Form | Declared? | Evidence |
|------|-----------|----------|
| `local x = expr` inside a function | **dropped** — `tmp_x = expr;` emitted, no `int64_t tmp_x;` | `tmp/probe1.nelua`, `tmp/probe2.nelua::f1` |
| `local x: T` (no init) inside a function | **dropped entirely** — nothing emitted | `tmp/probe2.nelua::f2`, `tmp/probe6.nelua` |
| `local x: T` then `x = expr` inside a function | decl dropped, assignment references undeclared `tmp_x` | `tmp/probe6.nelua` |
| `local` inside a nested `do ... end` block | **dropped** | `tmp/probe2.nelua::f3` |
| `local` inside a `for`/`while`/`repeat` body | **dropped** (loop var itself is OK — see note) | `tmp/probe2.nelua::f4` (`sum` dropped) |
| `local` inside a `switch`/`case` body | **dropped** (both the function-level and the case-level local) | `tmp/probe7b.nelua` |
| `global g` inside a function | **dropped** (same path); additionally our compiler does **not** enforce the oracle's top-scope rule | `tmp/probe3.nelua` |
| function parameters | **OK** — declared in the function signature by `genFuncDef` | `tmp/probe1.nelua` |
| `for i = a, b do` loop variable | **OK** — declared in the `for (...)` init by `genForNum` | `tmp/probe2.nelua::f4` (only `sum` failed) |
| `local` at module / top level | **OK** — separate declaration pass at `src/cgen.nim:1309-1311` | `tmp/probe4.nelua` (ours: `5 10 15`, exit 0) |

Note on the loop variable: `genForNum` (src/cgen.nim:976) declares the loop var
inline as `for (int64_t i = ...; ...)`, so it is not affected. Only ordinary
`local` declarations hit the bug.

### Oracle behaviour (the target)

The oracle declares every local and combines the declaration with the
initialiser. Examples from `/usr/bin/nelua --print-code`:

```
tmp/probe1.nelua  ->  int64_t x = (a + b);          (local x = a+b)
tmp/probe6.nelua  ->  int64_t x = 0;  x = (a + 1);  int64_t y = (a + 2);
```

So the oracle: (a) always emits a declaration for each local; (b) a local with no
initialiser is zero-initialised (`int64_t x = 0;`); (c) function locals are
`auto` (no `static`); (d) `global` inside a function is rejected at analysis with
`error: global variables can only be declared in top scope`.

---

## 2. Exact location of the root cause

**Root cause is in `cgen.nim`, not the analyzer.** The analyzer is correct: it
types every local, registers a symbol with codename `<unit>_<name>`
(`src/analyzer.nim:932`), and analyses the function body
(`src/analyzer.nim:1236` `analyzeBlock(ctx, body)`). `--print-analyzed-ast
tmp/probe1.nelua` shows the `VarDecl` for `x` fully annotated:

```
VarDecl { "local", { IdDecl { attr = { codename = "tmp_probe1_x", type = "int64",
  vardecl = true, ... }, "x" } }, ... }
```

So the analyzer is not dropping anything. The emitter is.

### The split that breaks

`genVarDecl` (src/cgen.nim:824) has two passes separated by `emitInits`:

- `emitInits = false` branch, src/cgen.nim:831-842 — emits the bare declaration
  `cDecl(vtype, cn) & ";"` (plus `static` when `isGlobal`). This branch is **only
  ever called from the top-level declaration pass**, src/cgen.nim:1309-1311:
  `s.genVarDecl(c, emitInits=false, isGlobal=true)`.
- `emitInits = true` branch, src/cgen.nim:844-873 — emits **only assignments**
  (`cn & " = " & ...`), never a declaration.

Function-body locals are emitted by `genStmt` at src/cgen.nim:1084-1085:

```nim
of nkVarDecl:
  s.genVarDecl(node, emitInits=true, isGlobal=s.inFunc)
```

`emitInits=true`, so only the assignment branch runs. There is **no second pass**
that emits the declaration for a function body — unlike the top level, which
gets its declaration from step 6 (src/cgen.nim:1309-1311) before
`nelua_main` runs the initialisers (src/cgen.nim:1323-1325).

The function body reaches `genStmt` via `genFuncDef`
(src/cgen.nim:1196-1205):

```nim
s.line attrs & decl & " {"
s.push
...
s.inFunc = true
s.genScope(node.children[^1], dkFunc)   # <- body statements
```

`genScope` -> `genStmts` -> `genStmt(nkVarDecl)` -> the broken path above.
Nested scopes (`do`, `for`/`while`/`repeat`, `switch`/`case`) all funnel through
`genScope` too (src/cgen.nim:914, 968, 996, 1041, 1102, 1112), which is why the
bug is uniform across all of them.

### Probes confirming the analyzer is clean

```
$ ./tmp/nelua --print-analyzed-ast tmp/probe1.nelua
  ... FuncDef ... Block { VarDecl { "local", { IdDecl { attr = {
    codename = "tmp_probe1_x", type = "int64", vardecl = true, used = true,
    ... }, "x" } } } ...
```

The `VarDecl` for `x` is present, typed, and codenamed. The generated C is:

```
int64_t tmp_probe1_add(int64_t a, int64_t b) {
  tmp_probe1_x = (a + b);     <- no declaration anywhere
  return tmp_probe1_x;
}
```

---

## 3. Analyzer or cgen?

**Cgen only.** The analyzer enters, types, registers, and analysies every
function-body local correctly (Section 2). The defect is purely in
`genVarDecl`'s two-pass split: the declaration pass exists for top-level globals
but has no equivalent for function-body locals.

Secondary observation (not the reported bug, but a related wart in the same
function): the `emitInits=false` branch applies `static` when `isGlobal`
(src/cgen.nim:838 `if isGlobal: qual &= "static "`). `isGlobal` is literally
`s.inFunc` (src/cgen.nim:1085), so this branch would stamp function locals
`static` — which would be a semantic error (locals must persist per call) versus
the oracle's `auto` locals. The init branch never applies `qual` at all, so the
`static` wart is currently latent; any fix that reuses the declaration branch
for function bodies must **not** inherit the `static` qualifier.

---

## 4. Minimal repro

`tmp/probe1.nelua`:

```nelua
local function add(a: integer, b: integer): integer
  local x = a + b
  return x
end
print(add(2, 3))
```

```
$ /usr/bin/nelua tmp/probe1.nelua        # oracle: 5, exit 0
$ ./tmp/nelua tmp/probe1.nelua           # ours:
tmp/tmp_probe1.c:94:3: error: 'tmp_probe1_x' undeclared ...
```

`tmp/probe2.nelua` extends it to `do`, `for`, and the no-initialiser form — all
five functions fail with the same undeclared-identifier error; the oracle prints
`11 12 13 6`, exit 0.

---

## 5. Recommended fix

Edit `genVarDecl` in `src/cgen.nim` (proc at line 824). In the `emitInits =
true` branch, emit a bare declaration for every iddecl **before** emitting the
initialisers, gated on `isGlobal` (i.e. only inside a function body — top-level
already has its declaration from the pass at src/cgen.nim:1309-1311, so adding
one here would produce a duplicate `int64_t tmp_x; int64_t tmp_x;` and break
top-level compilation). Do **not** inherit the `static` qualifier, so function
locals stay `auto` like the oracle.

Shape (insert immediately after the iddecls/inits split, before the
`if inits.len == 1 and iddecls.len > 1 and isCall(inits[0]):` multi-ret special
case):

```nim
# Function bodies have no separate declaration pass (the top-level one is at
# genC step 6), so declare each local here before its initialiser.  Gated on
# isGlobal (= s.inFunc) so top-level decls, already emitted at step 6, are not
# redeclared.  No `static`: the oracle lowers function locals as `auto`.
if isGlobal:
  for iddecl in iddecls:
    let a = s.ctx.attrOf.getOrDefault(iddecl)
    let vtype = if a != nil: a.typ else: nil
    if vtype == nil: continue
    let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
    s.line cDecl(vtype, cn) & ";"
```

This unblocks all five failing forms in `tmp/probe2.nelua` and `tmp/probe6.nelua`
(`int64_t tmp_x; tmp_x = ...;`). It does not touch top-level behaviour.

Refinement for oracle parity (optional, not required to unblock): emit
`cDecl(vtype, cn) & " = 0;"` for iddecls that have no initialiser, matching the
oracle's zero-initialisation (`tmp/probe6.nelua` -> `int64_t x = 0;`).

### Why this is the right place

- It is a ~10-line additive change in one proc, gated so it cannot regress the
  top-level path that already works.
- It fixes the declaration drop for every scope that funnels through `genScope`
  (function, `do`, `for`/`while`/`repeat`, `switch`/`case`) with one insertion,
  because they all share the `genStmt` -> `genVarDecl(emitInits=true)` path.
- It leaves the analyzer untouched, which is correct: the analyzer is already
  right.