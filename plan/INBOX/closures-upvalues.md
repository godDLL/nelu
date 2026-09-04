# Closure / upvalue scoping for Nelu (beyond 0.2.0)

**Status:** INBOX -- design doc for the implementation agent; read-only research, nothing implemented.

Design doc for the implementation agent. **Read-only research** - no source edited, no
git run.

- Oracle: `/usr/bin/nelua` (Nelua 0.2.0-dev, build 1635). It is the referee.
- Ours: `tmp/nelua` (`nim c -d:release --path:src -o:tmp/nelua src/main.nim`).
- Companion: `plan/splice-stage4-design.md` (voice reference),
 `plan/INBOX/record-enum-design.md` (voice reference), `NOTE_backlog.md` (queue),
 `language-review.md` section 4 (spec), `lualib/nelua/` (oracle source, read-only).

This doc is written **incrementally** - a probe batch is appended as it lands, so a
kill cannot lose the whole thing. The final ordered change list and difficulty
assessment are at the end.

---

## 0. Headline

> **Status (2026-09-03).** The "15 probes: 0 MATCH, 4 DIFF, 11 FAIL" line below is
> the survey's original measurement and is **stale**. Module-scope capture and
> the upvalue-rejection check have since landed across `75f315e` and
> `bab3eb3`; the current count is **7 MATCH / 8 DIFF**. Of the 8 DIFFs, 4 are
> honest diagnostic-channel differences (our upvalue message has no
> line:col) and 4 are deliberate permissive divergences (forward references,
> `## local`, bare top-level `function`, `global` in fn). The four root causes
> numbered below are all addressed except root cause 1's *ordering* (fixed) and
> root cause 2's *message* (landed, missing location). See `NELU-2K.md` 1.5.

**15 probes: 0 MATCH, 4 DIFF, 11 FAIL on our current `tmp/nelua`.** Every failure
shares one of a handful of small, localized root causes: a cgen
declaration-ordering bug, a missing analyzer upvalue check, and two
pre-existing function-value cgen bugs. All four are characterized below;

1. **cgen emits file-scope `static` declarations after the function definitions
 that reference them** - so every module-scope capture fails at C compile
 (`'x' undeclared`). Verified fix: move the declaration loop before the
 function definitions; hand-reordering the generated C and recompiling
 reproduces the oracle's output exactly (section 5 Step 1).
2. **The analyzer has no upvalue check** - so function-local capture is not
 rejected with the oracle's message and instead falls through to the C
 backend (section 5 Step 3).

The oracle's entire closure mechanism is "lower module-scope variables to
file-scope `static`s and reject function-local capture"; there is no upvalue
struct, no GC, no closure object to replicate. The implementation is ~25 lines
across three files, and it is **low**.

**Top 3 blockers** (for the impl agent, in priority order):
1. `src/cgen.nim` - move the file-scope static declaration loop
 (`:1441-1446`) to before the function-definition loop (`:1436-1439`).
 Unblocks 5 of the 7 oracle-succeeds probes; the other two
   (`as_return`, `as_arg`) need the separate cgen bugs in section 7 #6-#7.
2. `src/analyzer.nim` - add the upvalue check in `analyzeExpr`'s `of nkId`
 branch (`:757`), restricted to `skVar`/`skParam`, with the `skFunc`
 exemption that keeps recursion legal. Unblocks the 4 oracle-rejects probes.
3. `src/types.nim` + `src/analyzer.nim` - add `Scope.isFunction` and
 `getUpFunctionScope` so the check can tell "same function" from "enclosing
 function".

None of the three touch `src/parser.nim`, `src/preprocessor.nim`,
`src/luaengine.nim`, or `src/cemitter.nim`, so they compose with the four
in-flight agents.

---

## 1. Oracle architecture (what we are mirroring)

The oracle's upvalue check lives in `lualib/nelua/analyzer.lua:670-673` inside
`visitors.Id`:

```lua
if not symbol.staticstorage and symbol.scope ~= context.rootscope and
 context.generator ~= 'lua' and
 not symbol:is_directly_accesible_from_scope(context.scope) then
 node:raisef("attempt to access upvalue '%s', but closures are not supported", name)
end
```

`Symbol:is_directly_accesible_from_scope` (`lualib/nelua/symbol.lua:187-197`) returns
true when the symbol is reachable without a closure:

- `self.staticstorage` - declared in program static storage (top scope, always
 accessible);
- `self.comptime or (self.type and self.type.is_comptime)` - compile-time symbols;
- `self.scope:get_up_function_scope() == scope:get_up_function_scope()` - the symbol's
 scope and the referencing scope are inside the **same** function (sibling access;
 `get_up_function_scope` walks `self.parent` until a scope whose `is_function` is set,
 `lualib/nelua/scope.lua:128-135`).

Three consequences that drive the whole design:

1. **Module-scope locals/globals are accessible from inner functions.** A
 `local x` at module level gets `symbol.scope = context.rootscope`
 (`analyzer.lua:724`, via `IdDecl`), so `symbol.scope ~= context.rootscope` is false
 and the upvalue check short-circuits. They are also `staticstorage` in practice
 (VarDecl sets `varnode.attr.staticstorage = true`, `analyzer.lua:2222/2564`). The
 Nelu design note is correct: capture them as file-scope `static`s.
2. **Function-local capture is rejected** with the exact message
 `attempt to access upvalue '<name>', but closures are not supported`. A local
 declared inside function `f` has `symbol.scope` = `f`'s body scope; an inner
 function `g` reading it has `context.scope` = `g`'s body scope;
 `f`'s funcscope != `g`'s funcscope, and neither is `staticstorage`, so the check fires.
3. **Same-function access is fine.** A local declared in `f`'s body and read later in
 `f`'s body (not in a nested function) shares `get_up_function_scope()` = `f`'s
 funcscope, so it is allowed. This is ordinary local access, not closure capture.

The spec (`language-review.md:385-392`) is consistent: anonymous functions and nested
functions are **not** closures; only top-scope functions are closures, and only because
top-scope variables live in static storage (no upvalue reference, no GC).

**No GC, no upvalue struct, no closure object.** The oracle lowers every accessible
captured variable to a file-scope `static` C variable. That is the entire mechanism.

---

## 2. Probe methodology

Every probe is a standalone nelua program written to `tmp/probe_<construct>.nelua`
with an absolute path. One construct per probe. Each is run through `/usr/bin/nelua`
(oracle) and through `tmp/nelua` (ours); stdout and exit code are recorded verbatim.

Oracle invocation:
```
/usr/bin/nelua <probe> ; echo "exit=$?"
```
Ours invocation:
```
./tmp/nelua <probe> ; echo "exit=$?"
```
Note: `tmp/nelua` is the compiled binary. If `src/` has been edited since the last
build it is stale - that is reported as a FAIL with a rebuild note, never silently
excused.

Verdicts:
- **MATCH** - identical stdout and exit code.
- **DIFF** - same exit code but different stdout, or vice versa. Distinguished as our
 bug or a deliberate Nelu divergence from the oracle's output.
- **FAIL** - our compiler errors/crashes where the oracle succeeds (or vice versa),
 or our exit code differs.

---

## 3. Probe results

### Batch 1 - basic capture (oracle first)

Probes: `tmp/probe_closure_read.nelua` (inner fn reads enclosing local),
`tmp/probe_closure_write.nelua` (inner fn writes enclosing local),
`tmp/probe_closure_param.nelua` (inner fn reads enclosing param).

**Oracle** (all three, exit 1):
```
probe_closure_read.nelua:5:12: error: attempt to access upvalue 'x', but closures are not supported
probe_closure_write.nelua:5:5: error: attempt to access upvalue 'x', but closures are not supported
probe_closure_param.nelua:4:12: error: attempt to access upvalue 'a', but closures are not supported
```

**Ours** (all three, exit 1, but via the wrong channel - C compile, not analysis):
```
OURS probe_closure_read: 'tmp_probe_closure_read_x' undeclared (first use in this function)
OURS probe_closure_write: 'tmp_probe_closure_read_x' undeclared (first use in this function)
OURS probe_closure_param: 'a' undeclared (first use in this function)
```

**Verdict: 3 FAIL.** Our analyzer does **not** emit the oracle's upvalue rejection.
Instead it emits `g` as a separate top-level C function that references the enclosing
variable by its file-scope-mangled name, and gcc then refuses to link it because that
name is declared *inside* `f`. Two distinct gaps:

1. **Analyzer gap** - no upvalue check at `visitors.Id`-equivalent point.
2. **cgen gap** - the emitted C declares `tmp_probe_closure_read_x` inside `f`
 (`tmp/tmp_probe_closure_read.c:108`) but `g` (`:113`) references it as a free
 identifier. This is the same root as `plan/WIP/locals-in-functions-bug.md`: our
 `genVarDecl` declares a function-body local before its init with no `static`, so
 nested functions cannot see it. It is a pre-existing bug, not introduced by this
 feature, and it must be fixed regardless (it is what makes the oracle's *allowed*
 cases - module-scope capture as `static` - actually work).

Recorded the generated C for `probe_closure_read` verbatim (`tmp/tmp_probe_closure_read.c`):
`g` is a free function (`:112-114`), `x` is `f`'s local (`:108`), `main` calls `f`
(`:116`). Nothing in this output is a closure - it is a broken hoist.

### Batch 2 - module-level capture (the allowed case)

Probes: `tmp/probe_closure_module_read.nelua`,
`tmp/probe_closure_module_write.nelua`, `tmp/probe_closure_multilevel.nelua`,
`tmp/probe_closure_sourceorder.nelua`.

**Oracle:**
```
module_read: 10 exit=0
module_write: 99 exit=0
multilevel: 5 exit=0
sourceorder: undeclared symbol 'x' exit=1
```

**Ours:**
```
module_read: C compile: 'tmp_probe_closure_module_read_x' undeclared in g exit=1
module_write: C compile: 'tmp_probe_closure_module_write_x' undeclared in g exit=1
multilevel: C compile: 'tmp_probe_closure_multilevel_x' undeclared in h exit=1
sourceorder: nil exit=0
```

**Verdict: 3 FAIL + 1 DIFF.**

- `module_read` / `module_write` / `multilevel`: **FAIL** - not an analyzer miss but a
 **cgen ordering bug**. Verified verbatim in `tmp/tmp_probe_closure_module_read.c`:
 our generator emits `g`'s *definition* (`:106-108`) **before** the `static` it
 references (`static int64_t tmp_probe_closure_module_read_x` at `:109`). C requires
 the declaration first; gcc rejects it. The NOTE_backlog's "reorder output into a
 DECLARATIONS section" is exactly this fix and it is the **central cgen change** for
 this feature. Same shape in `probe_closure_read.c`: `g`'s definition (`:112-114`)
 precedes `x`'s declaration (`:108`, inside `f`).
- `sourceorder`: **DIFF - deliberate Nelu divergence (permissive).** The oracle errors
 `undeclared symbol 'x'` because `x` is declared at line 3, after `g`'s body is
 analyzed at line 1. Ours prints `nil`, exit 0 - our analyzer does not enforce
 source order on module-scope locals and resolves a forward reference to `nil`.
 This is the same permissive divergence the splice Stage 4 doc flags for `## local`;
 it must be listed in the honest out-of-scope list. It is a separate concern from
 closure capture and is arguably a pre-existing analyzer weakness.

### Batch 3 - view-vs-copy, `global` in fn, closures as values

Probes: `tmp/probe_closure_viewvscopy.nelua`,
`tmp/probe_closure_global_in_fn.nelua`, `tmp/probe_closure_as_return.nelua`,
`tmp/probe_closure_as_arg.nelua`.

**Oracle:**
```
viewvscopy: 42 exit=0 (view semantics: g reads x at call time, sees 42)
global_in_fn: global variables can only be declared in top scope exit=1
as_return: 11 exit=0
as_arg: 3 exit=0 (typed param `fn: function(): integer`)
```

Note on `as_arg`: the first version of this probe used an untyped `fn` param and
**killed the oracle** (exit 137, SIGKILL - an analyzer-loop bug on the `any`-param
path, `lualib/nelua/analyzer.lua`). That is an oracle bug, not a closure behavior;
the typed-param version is the valid probe and it works.

**Ours:**
```
viewvscopy: C compile: 'tmp_probe_closure_viewvscopy_x' undeclared in g exit=1
global_in_fn: 7 exit=0
as_return: C compile: implicit declaration of function 'h' in nelua_main exit=1
as_arg: C compile: expected ')' before ':' token at (g: function(): int64) exit=1
```

**Verdict: 3 FAIL + 1 DIFF.**

- `viewvscopy`: **FAIL** - same cgen ordering bug. Oracle proves **view semantics**
 (reassign `x` after the closure forms and `g()` returns the new value, 42). Nelu
 will match this for free once module-scope capture lowers to a single `static`
 that both the closure and the reassignment touch - no per-closure cell needed.
- `global_in_fn`: **DIFF - deliberate Nelu divergence (permissive).** Oracle rejects
 `global y` inside a function with `global variables can only be declared in top
 scope`. Ours prints 7, exit 0. Must be listed as a divergence; unrelated to
 closure capture but in the same `global`-handling code path.
- `as_return`: **FAIL** - cgen ordering again. `h` is assigned in `nelua_main` but
 its definition is emitted after `nelua_main`, so C reports an implicit
 declaration. The DECLARATIONS-section reorder fixes this too: every function
 needs a forward declaration before `nelua_main`.
- `as_arg`: **FAIL** - a *different*, pre-existing cgen bug. Our generator emits
 `(int64_t (*)(void))(g: function(): int64)` when coercing a function value to a
 typed function parameter - nelua annotation text leaks into the C output
 (`tmp/tmp_probe_closure_as_arg.c:116`). This is a function-type-coercion bug, not
 a closure bug, but it blocks "closures as arguments" until fixed.

### Batch 4 - recursion, `function` vs `local function`, `##` local, siblings

Probes: `tmp/probe_closure_recursion.nelua`,
`tmp/probe_closure_function_vs_localfn.nelua`, `tmp/probe_closure_ddlocal.nelua`,
`tmp/probe_closure_sibling.nelua`.

**Oracle:**
```
recursion: 15 exit=0 (inner fn self-recursion + module capture)
function_vs_localfn: undeclared symbol 'g', maybe you forgot to declare it as 'global' or 'local'? exit=1
ddlocal: undeclared symbol 'x' exit=1 (## local is Lua-only)
sibling: attempt to access upvalue 'x', but closures are not supported exit=1
```

**Ours:**
```
recursion: C compile: 'tmp_probe_closure_recursion_rec' undeclared in rec (self-ref) exit=1
function_vs_localfn: C compile: 'tmp_probe_closure_function_vs_localfn_x' undeclared in g exit=1
ddlocal: nil exit=0
sibling: C compile: 'tmp_probe_closure_sibling_x' undeclared in h exit=1
```

**Verdict: 3 FAIL + 1 DIFF.**

- `recursion`: **FAIL** - cgen ordering again. Self-recursion through an inner
 function works on the oracle (`rec` calls `rec(m-1)` and captures module-level
 `acc`, prints 15). Ours fails because `rec` is not forward-declared before its own
 body. The DECLARATIONS-section reorder fixes this: every function (including
 nested ones emitted as free functions) needs a forward declaration first.
- `function_vs_localfn`: **DIFF - deliberate Nelu divergence (permissive).** The
 oracle rejects a bare top-level `function g()` (no `local`/`global`) with
 `undeclared symbol 'g', maybe you forgot to declare it as 'global' or 'local'?`.
 Ours accepts it and only fails later on the same C ordering bug. This is a
 separate declaration-rule divergence, not a closure issue.
- `ddlocal`: **DIFF - deliberate Nelu divergence (permissive).** Oracle:
 `## local x = 7` is Lua-only, so an inner nelua function reading `x` errors
 `undeclared symbol 'x'`. Ours prints `nil`, exit 0 - our analyzer does not know
 about `##` locals at all and silently resolves the bare identifier to nil. Same
 permissive family as `sourceorder`.
- `sibling`: **FAIL** - cgen ordering. Oracle rejects with the upvalue message
 (two sibling inner functions both reading `f`'s local `x`). Ours reaches the C
 backend and fails on the same ordering bug.

### Batch 5 - verification of the cgen fix (manual, no source edit)

To prove the cgen hypothesis without editing `src/`, the generated C for
`probe_closure_module_read` was reordered by hand: the file-scope static
declaration `static int64_t tmp_probe_closure_module_read_x;` was moved from
after `nelua_main` to immediately after the function forward declarations and
before the function definitions. Result:

```
$ gcc -o tmp/tmp_probe_reorder_test tmp/tmp_probe_reorder_test.c src/runtime.c -lm
$ ./tmp/tmp_probe_reorder_test
10
exit=0
```

This is exactly the oracle's output. **The cgen DECLARATIONS-section reorder is
the correct and sufficient fix for module-scope capture**, and it is the only
codegen change this feature requires. View semantics (reassign after the closure
forms, `probe_closure_viewvscopy` -> 42) fall out for free: both the closure and
the reassignment touch one shared `static`, and the closure reads it at call
time. No per-closure cell, no GC, no upvalue struct.

---

## 4. The two changes

The feature is two localized changes. Everything else in the probe matrix is a
pre-existing bug that these two changes do not touch (it is listed in section 6).

### Change A - analyzer: reject function-local upvalue capture

Mirror the oracle's `visitors.Id` check (`lualib/nelua/analyzer.lua:670-673`)
in our `analyzeExpr` `of nkId` branch.

**Oracle semantics, verified by probe:**

| Symbol kind | Declared in | Referenced from | Oracle result |
|---|---|---|---|
| `skVar` / `skParam` | module scope | any function | accessible (static) |
| `skVar` / `skParam` | function `f`'s body | `f`'s own body | accessible (same function) |
| `skVar` / `skParam` | function `f`'s body | nested function `g` | **upvalue error** |
| `skFunc` (any) | anywhere | anywhere | accessible (always staticstorage) |

The `skFunc` row is why recursion through an inner function works
(`probe_closure_recursion` -> 15): the oracle sets `symbol.staticstorage = true`
on every function symbol (`analyzer.lua:3001`), so the upvalue check
short-circuits for function references. Our check must therefore be restricted
to `skVar` / `skParam`.

**Our scope model.** `Scope` (`src/types.nim:89`) has `name`, `symbols`,
`parent`. `AnalyzerContext.scope` is the current scope; `ctx.globals` is the
module scope (`src/analyzer.nim:243-244`). Module-level symbols are registered
with `scope = ctx.globals` (`register` at `:102`); imported symbols are copied
with `scope = ctx.globals` (`importSymbols` at `:2197`). Function bodies push one
scope via `analyzeFuncDef` (`:1317`); `analyzeBlock` does **not** push a scope, so
all of a function's body locals share the function's scope. This is simpler than
the oracle's per-block scopes and is adequate for the check.

**New machinery:**
- Add `isFunction*: bool` to `Scope` (`src/types.nim:89`).
- Set it when `analyzeFuncDef` pushes the function scope
 (`src/analyzer.nim:1317`): `ctx.scope = newScope(saved, nameStr); ctx.scope.isFunction = true`.
- Add `getUpFunctionScope(scope: Scope): Scope` - walk `parent` until
 `isFunction`, else nil.

**The check**, inserted in `analyzeExpr`'s `of nkId:` branch after the symbol is
resolved (`src/analyzer.nim:757`), before the `skBuiltin` branch:

```nim
# Mirror the oracle's upvalue check (analyzer.lua:670-673). A variable that is
# not module-scope and not in the same function as the referencing code is an
# upvalue, which Nelua does not support. Function symbols are exempt: the
# oracle marks every function staticstorage (analyzer.lua:3001), which is what
# makes recursion through an inner function legal.
if sym != nil and sym.kind in {skVar, skParam} and not sym.comptime:
  if sym.scope != ctx.globals:
    let symUp = getUpFunctionScope(sym.scope)
    let refUp = getUpFunctionScope(ctx.scope)
    if symUp != refUp:
      ctx.diags.add ctx.path & ": error: attempt to access upvalue '" &
        nm & "', but closures are not supported"
      return nil
```

`ctx.lookup` already walks the scope chain, so lexical scoping is inherited for
free; `comptime` vars are exempt (the oracle exempts them via
`is_directly_accesible_from_scope`). `skFunc` / `skType` / `skField` /
`skEnumField` / `skBuiltin` are not checked, matching the oracle's
`staticstorage` short-circuit for functions.

**Error-channel note.** The oracle prints `probe_closure_read.nelua:5:12: error:
attempt to access upvalue 'x', but closures are not supported` (with line:col). Our
analyzer has no per-node source location (`Node` in `src/astshapes.nim` carries
no `loc`; `src/span.nim` `SourceLoc` exists but is not attached to nodes), so our
diagnostic is `ctx.path & ": error: attempt to access upvalue 'x', but closures
are not supported"` - same text, no line:col. This is a minor, honest DIFF in
location granularity, not in the rule.

### Change B - cgen: DECLARATIONS section before function definitions

In `genC` (`src/cgen.nim:1346`), the file-scope globals are emitted at **step 6**
(`:1441-1446`), *after* the function definitions at **step 5** (`:1436-1439`).
A module-level `local x` becomes `static int64_t <unit>_x;` but that declaration
lands after every function that references it, so gcc rejects the reference.

**Fix:** emit the file-scope static declarations **before** the function
definitions. Concretely, move the step-6 declaration loop to between step 3
(forward declarations) and step 5 (function definitions):

```nim
# 3. forward declarations (all results, dependency order) -- unchanged
for (fd, i) in funcEntries:
  s.ctx = results[i].ctx
  s.genForwardDecl(fd)

# 3b. NEW: file-scope static declarations, BEFORE function definitions.
# Every module-level VarDecl is lowered to `static <type> <name>;` here so
# that nested functions emitted as free functions can reference it. This is
# what makes module-scope capture (the only closure form Nelua supports)
# actually compile.
for r in results:
  s.ctx = r.ctx
  for c in r.root.children:
    if c.kind == nkVarDecl:
      s.genVarDecl(c, emitInits=false, isGlobal=true)

# 5. function definitions (all results, dependency order) -- unchanged
for (fd, i) in funcEntries:
  s.ctx = results[i].ctx
  s.genFuncDef(fd)

# 6. nelua_main: global initializers + top-level statements, then the driver.
# (the init-emitting half of the old step 6 stays here, unchanged)
```

The initializers (`<name> = <init>;`) still run inside `nelua_main`, in source
order, so a module-level `local x = 10` becomes `static int64_t x;` in the
DECLARATIONS section and `x = 10;` in `nelua_main`. View semantics are preserved
because `nelua_main` and the closures share the one `static`.

`genVarDecl` with `emitInits=false` calls `collectType` (`:927`), which appends
to `s.typesSeq`. Because the initial `collectNode` pass (`:1401`) already
recorded every type reachable from the module root, and step 2 (typedef
emission, `:1423-1427`) already ran, moving this loop earlier does not change
which typedefs are emitted; for the primitive types used by captured locals
there is no typedef to emit at all. The `nim c` self-test at `cgen.nim:1480`
asserts substrings, not ordering, so it is unaffected.

---

## 5. Ordered change list

Apply in this order. Each step is independently verifiable against the oracle.

### Step 1 - cgen DECLARATIONS section (`src/cgen.nim`)
- **`src/cgen.nim:1434`** - insert the file-scope static declaration loop
 (section 4 Change B) between the forward-declaration loop (`:1429-1432`) and the
 function-definition loop (`:1436-1439`).
- Verify: `probe_closure_module_read` -> `10`, exit 0; `probe_closure_write` ->
 `99`; `probe_closure_multilevel` -> `5`; `probe_closure_viewvscopy` -> `42`;
 `probe_closure_recursion` -> `15`. These five are what the reorder alone
 fixes. `probe_closure_as_return` (-> `11`) and `probe_closure_as_arg` (-> `3`)
 additionally need the function-typed-variable call bug and the
 function-argument coercion bug respectively (section 7 #2, #3); they are not
 claimed to be fixed by this step.

### Step 2 - scope `isFunction` flag + helper (`src/types.nim`, `src/analyzer.nim`)
- **`src/types.nim:89`** - add `isFunction*: bool` to `Scope`.
- **`src/analyzer.nim:1317`** - after `ctx.scope = newScope(saved, nameStr)`,
 set `ctx.scope.isFunction = true`.
- **`src/analyzer.nim`** - add `getUpFunctionScope(scope: Scope): Scope`.
- Verify: `--print-analyzed-ast` of a nested-function program still parses; no
 behaviour change yet (the flag is not read until Step 3).

### Step 3 - analyzer upvalue check (`src/analyzer.nim`)
- **`src/analyzer.nim:757`** - insert the section 4 Change A check in the `of nkId`
 branch, after `sym != nil` and before the `skBuiltin` branch.
- Verify: `probe_closure_read` -> `attempt to access upvalue 'x', but closures
 are not supported`, exit 1; `probe_closure_write`, `probe_closure_param`,
 `probe_closure_sibling` -> same message for their names; `probe_closure_read`
 now fails at **analysis** (the diagnostic channel), not at C compile.
- Verify the allowed cases still pass: `probe_closure_module_read` -> 10;
 `probe_closure_recursion` -> 15 (self-recursion must not be flagged).

### Step 4 - validate against the corpus (`lib/`, read-only)
- Grep `lib/` for every nested-function read/write of an enclosing local. With
 Steps 1-3 landed, none of these may exist (the oracle rejects them all); if
 any `lib/` file relies on function-local capture, it is a real Nelu
 regression and the divergence must be flagged rather than silently accepted.

---

## 6. Difficulty assessment

| Piece | Difficulty | Why |
|---|---|---|
| Step 1 (cgen DECLARATIONS reorder) | **very low** | one loop moved; verified by hand-reordering generated C and recompiling. The `collectType` interaction is benign (see section 4). |
| Step 2 (`isFunction` flag + helper) | **very low** | two one-line additions + a 4-line walker. No behaviour change until read. |
| Step 3 (analyzer upvalue check) | **low** | ~10 lines in one branch. The subtle part is the `skFunc` exemption - getting it wrong flags legitimate recursion as an upvalue (verified: `probe_closure_recursion` must stay `15`). The `comptime` exemption and the `ctx.globals` identity check are direct translations of the oracle. |
| Step 4 (corpus validation) | **low** | read-only grep; no code change. |

**Overall: low.** This is the rare queued feature whose implementation is
smaller than its design survey. The two changes together are ~25 lines across
three files, and both are mechanical translations of a 4-line oracle check plus
one verified cgen reorder. The probe matrix shows the remaining gaps are all
pre-existing bugs in other files, not anything this feature needs to build.

**No fundamental blocker.** The oracle's whole closure mechanism is "lower
module-scope variables to file-scope `static`s and reject everything else" -
there is no upvalue struct, no GC, no closure object to replicate. Our
architecture already has `ctx.scope`/`ctx.globals`, `lookup`, and a codegen that
lowers module-level locals to `static`s; Steps 1-3 just (a) declare them in the
right order and (b) enforce the oracle's rejection rule at the one point the
oracle enforces it.

---

## 7. What still won't work (honest list)

These are pre-existing bugs or deliberate Nelu divergences, **not** fixed by
Steps 1-4. Each was verified against the oracle.

1. **Function-body locals collide on C names.** Our analyzer gives *every*
 variable the codename `<unit>_<name>` (`analyzeVarDecl:952`), so two
 different functions each having a local `x` emit the same C symbol. This is
 the queued `plan/WIP/locals-in-functions-bug.md` (~10-line gated fix in
 `cgen.nim` `genVarDecl`: declare each function-body local before its init,
 no `static`). It is **independent of and not unblocked by** this feature -
 module-scope capture works without it, and function-local capture is
 rejected before it could ever be generated. It is listed here only so the
 impl agent does not mistake the cgen reorder for a complete local-variable
 fix.
2. **Calling a function-typed variable emits the bare nelua name, not the
   mangled codename.** In `probe_closure_as_return`, `h` is a function-typed
   local holding the closure; the generated C declares it correctly
   (`static int64_t (*tmp_probe_closure_as_return_h)(void);`) but the call site
   emits `h()` instead of `tmp_probe_closure_as_return_h()`, so gcc reports
   `implicit declaration of function 'h'`
   (`tmp/tmp_probe_closure_as_return.c:118`). The cgen DECLARATIONS reorder
   does **not** fix this - it is a separate call-emission bug for
   function-typed variables. It blocks "closures as return values" until
   the call path resolves the callee's codename.
3. **Function-type argument coercion emits garbage C.** Passing a function
 value to a typed function parameter emits
 `(int64_t (*)(void))(g: function(): int64)` - nelua annotation text leaks
 into the C output (`cgen.nim` function-arg coercion, `tmp/tmp_probe_closure_as_arg.c:116`). Blocks "closures as arguments" until that coercion path is fixed. Pre-existing; not a closure bug.
4. **Permissive divergences from the oracle** (ours accepts, oracle rejects):
 - forward reference to a module-level local -> we print `nil`, oracle errors
 `undeclared symbol` (`probe_closure_sourceorder`);
 - `## local` read by nelua code -> we print `nil`, oracle errors
 `undeclared symbol` (`probe_closure_ddlocal`);
 - bare top-level `function g()` (no `local`/`global`) -> we accept it, oracle
 errors `undeclared symbol 'g', maybe you forgot to declare it as 'global' or 'local'?`
 (`probe_closure_function_vs_localfn`);
 - `global` inside a function -> we accept it, oracle errors
 `global variables can only be declared in top scope`
 (`probe_closure_global_in_fn`).
 All four are in the same family: our analyzer is more permissive about
 declaration rules and source order than the oracle. They are unrelated to
 closure capture and none of them is exercised by `lib/`'s closure use, but
 they must be flagged rather than hidden.
5. **No line:col on the upvalue diagnostic** (section 4 Change A). Message text
 matches; location granularity is `path:` only.
6. **`##`-local capture is not a closure feature.** A `## local` is Lua-only in
 the oracle and is invisible to nelua functions (`probe_closure_ddlocal`).
 Making a `##`-local visible to splices is the splice Stage 4 problem
 (`plan/splice-stage4-design.md` section 4), not this one. Do not conflate them.
7. **Anonymous functions / `function`-expression values** are not first-class
 in 0.2.0-dev and are out of scope for this feature (the oracle rejects
 untyped params with `compiler deduced type 'any'`, and function values are
 not convertible to AST nodes).