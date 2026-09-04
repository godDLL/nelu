# Driver SIGSEGV fix: cast `(@*[0]byte)(e)` (Nelua clean room)

Scope: ONE remaining driver SIGSEGV in the clean-room Nelua compiler
(`/home/user/Code/nelua-lang`, HEAD `c137f8e`).

## 0. Scope note (read first)

- Crash 2 (indexing a `*[0]byte` parameter, `data[i]`) is ALREADY FIXED by
  commit `3823b0f` ("pointer-to-array C emission (Tier 1)"). Verified:
  `tmp/idx_param.nelua` MATCHes the oracle (exit 0, prints 7) on both the
  unmodified `tmp/nelua` and the fixed `tmp/nelua_fix`. This doc covers ONE
  crash, not two.
- All source edits below were made ONLY in the copied tree `tmp/srcfix/` and
  built as `tmp/nelua_fix`. Nothing under `src/` was touched.
- The task brief named the crash `cemitter.cCast`. That name is imprecise.
  The segfault does not land in `cemitter.nim` at all (see section 1). It
  lands in the analyzer. The cast expression is a `Call` node in the AST, so
  `analyzeCall` is what actually crashes.

## 1. Exact proc and line (gdb backtrace)

Build used for the backtrace (debug info, no `-d:release`):

```
nim c --debugger:native --path:src -o:tmp/nelua_dbg src/main.nim
```

Probe: `tmp/pc1.nelua` -> `local p = (@*[0]byte)(nilptr); print(p)`.

```
Program received signal SIGSEGV, Segmentation fault.
#0  analyzeCall (...) at src/analyzer.nim:601
#1  analyzeExpr  (...) at src/analyzer.nim:829
#2  analyzeVarDecl (...) at src/analyzer.nim:924
#3  analyzeStmt   (...) at src/analyzer.nim:1763
#4  analyzeBlock (...) at src/analyzer.nim:1787
#5  analyzeModule(...) at src/analyzer.nim:2258
#6  analyze       (...) at src/analyzer.nim:2271
#7  genC          (...) at src/cgen.nim:1370
#8  compileUnit  (...) at src/compile.nim:138
#9  compile      (...) at src/compile.nim:170
#10 main         (...) at src/main.nim:82
```

Line 601 is:

```
598  else:
599    d.calleeSymStr = caller.str & ": " & ftypeStr
600    d.calleeTypeStr = ftypeStr
601    if calleeType.returns.len >= 1:      <- SIGSEGV here
602      a.typ = calleeType.returns[0]
603    else:
604      a.typ = BuiltinTypes["void"]
```

Local `calleeType_1 = 0x0` at the frame. The instruction at 601 reads
`calleeType->returns` through a nil pointer.

## 2. Root cause

A Nelua cast `(@T)(e)` is parsed as a `Call` node whose LAST child (the
"caller") is the type `T`, wrapped in a `Paren` node:

```
Call {
  { <arg e> },
  Paren { Type { <T> } }
}
```

(Verified with `nelua --print-ast` and `--print-analyzed-ast` on
`tmp/probe_cast_simple.nelua`.)

`analyzeCall` (src/analyzer.nim:456) resolves a callee only when
`caller.kind == nkId` (line 484). For a cast the caller is `nkParen`, so that
whole block is skipped and the local `calleeType` stays `nil` (its initial
value, line 483). Nothing else in the proc sets it for a cast.

Execution then falls through to the `else` branch at line 598 (reached because
`calleeSym` is also nil), and line 601 dereferences the nil `calleeType` ->
SIGSEGV.

So: a cast expression was left entirely unanalyzed. There was no code path
that resolved the target type `T`, bound it on the call node, or told codegen
to emit a C cast. The crash is a missing case, not a bad pointer.

Note: this is not specific to `*[0]byte`. ANY cast crashes the analyzer today
(e.g. `(@byte)(x)`). `*[0]byte` is just the case the task probe uses.

## 3. Minimal fix design

Three edits, all in `tmp/srcfix/`, built as `tmp/nelua_fix`:

```
nim c -d:release --path:tmp/srcfix -o:tmp/nelua_fix tmp/srcfix/main.nim
```

### 3a. Analyzer: resolve the cast target type (tmp/srcfix/analyzer.nim)

Inserted in `analyzeCall` right after `var calleeType: Type = nil` (line 483),
before the `if caller.kind == nkId` block:

```nim
  # C1: a type cast `(T)(e)` has a type node (or a paren wrapping one) as the
  # caller.  Resolve the target type T, bind it as the call's calleeType and
  # return type, and flag the node so codegen emits `(cType(T))(e)` instead of
  # a function call.  Without this the `else` branch below dereferences a nil
  # calleeType and SIGSEGVs -- a cast was previously left entirely unanalyzed.
  var castTarget: Type = nil
  if caller.kind == nkParen and caller.children.len > 0 and
     caller.children[0].kind == nkType:
    castTarget = analyzeTypeExpr(ctx, caller.children[0].children[0])
  elif caller.kind == nkType:
    castTarget = analyzeTypeExpr(ctx, caller.children[0])
  if castTarget != nil:
    calleeType = Type(kind: tkFunction, name: "function", codename: "function")
    calleeType.name = "function"; calleeType.codename = "function"
    for at in argTypes:
      calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
    calleeType.returns.add castTarget
    ca.calleeType = castTarget
    a.calleeType = castTarget
```

- `analyzeTypeExpr` already resolves `nkId` / `nkPointerType` / `nkArrayType`
  (and record/enum/func types), so `@byte`, `@*[0]byte`, `@*byte`, etc. all
  resolve. The `nkType` wrapper is unwrapped one level before calling it.
- `ca` is the caller (`Paren`) attr; `a` is the call node attr. Setting
  `ca.calleeType` is what codegen reads. `calleeType` is built as a synthetic
  one-arg function whose return type is `T`, which makes the existing
  `calleeType.returns[0]` logic at line 601-604 set `a.typ = T` and the
  existing `ctx.callRetTypes[node]` line 607 work without changes.

### 3b. Codegen: emit the C cast (tmp/srcfix/cgen.nim)

Inserted in `genCall` after the record/constructor check and before
`case caller.kind` (line 606):

```nim
  # C1: type cast `(T)(e)` -> `(cType(T))(e)`.  The caller attr carries the
  # target type (bound by the analyzer); there is no callee symbol to call, so
  # emit an explicit C cast of the single argument instead of a call expression.
  if ca != nil and ca.calleeType != nil and caller.kind in {nkParen, nkType}:
    let ct = cType(ca.calleeType)
    let argstr = if args.len > 0: argstrs[0] else: "void"
    return "(" & ct & ")(" & argstr & ")"
```

- Guarded by `ca.calleeType != nil`, so ordinary parenthesized calls
  `(f)(x)` and record constructors are untouched. `caller.kind in
  {nkParen, nkType}` restricts it to cast callers.
- `argstrs[0]` is the already-coerced single argument; wrapping it in
  `(cType(T))(...)` matches the oracle's output, e.g.
  `(uint8_t)(tmp_probe_cast_simple_x)` and
  `(uint8_t*)(NULL)` for the `*[0]byte` case (the oracle spells the same type
  as `uint8_t*` under its `nluint8_arr0_ptr` typedef).

### 3c. Runtime: nil/pointer print spelling (tmp/srcfix/runtime.c)

```c
void nelua_print_nil(void) {
-  fputs("nil", nl_out);
+  fputs("(null)", nl_out);
}
```

This is a COMPANION fix, not part of the crash. It exists only so the probe's
STDOUT matches the oracle. `pc1` prints the (null) cast result, and the oracle
spells a null pointer/nilptr as `(null)`; our `nelua_print_nil` spelled it
`nil`. Without this line `pc1` would exit 0 (crash gone) but still DIFF on
stdout. It is a one-line, oracle-aligned change; it also makes the existing
`examples/www/nilptr_print.nelua` MATCH (it DIFFed before).

## 4. Verification

Harness: `tmp/rpr/run_fix.sh <probe.nelua>` runs the probe through the oracle
(`/usr/bin/nelua`) and through `./tmp/nelua_fix`, printing stdout/stderr/exit
for each and a MATCH/DIFF/FAIL verdict. (The unmodified harness
`tmp/rpr/run.sh` compares against `./tmp/nelua`.)

### 4a. The task probes

| probe | oracle | tmp/nelua (before) | tmp/nelua_fix (after) | verdict |
|-------|--------|--------------------|-----------------------|---------|
| `tmp/pc1.nelua` (`local p = (@*[0]byte)(nilptr); print(p)`) | exit 0, `(null)` | SIGSEGV exit 139 | exit 0, `(null)` | **MATCH** |
| `tmp/probe_cast_min.nelua` (`local p: *byte = nil; ...`) | exit 1 (error) | SIGSEGV exit 139 | exit 0, `0` | no crash; DIFF (see 5) |
| `tmp/idx_param.nelua` (crash 2) | exit 0, `7` | exit 0, `7` | exit 0, `7` | MATCH (unchanged) |
| `tmp/probe_cast_simple.nelua` (`(@byte)(x)`) | exit 0, `1` | SIGSEGV exit 139 | exit 0, `1` | **MATCH** |

`pc1` under gdb on the fixed binary: `[Inferior 1 exited normally]` -- no
SIGSEGV.

### 4b. Regression sweep (examples/www, oracle vs fix)

`tmp/cmp_baseline.py` over `examples/www/*.nelua`:

- baseline (`./tmp/nelua`, current `src/`): PASS=16 DIFF=6 FAIL=0
- fixed (`./tmp/nelua_fix`): PASS=17 DIFF=5 FAIL=0

The fix adds exactly one PASS (`nilptr_print`) and introduces zero new DIFFs
and zero FAILs. The 5 remaining DIFFs (`escapes`, `floor_div`, `lshift`,
`scope_shadow`, `stepped_for`) are byte-identical between baseline and fixed,
i.e. pre-existing divergences unrelated to this change. (The broader
`examples/` and `tests/` corpus currently fails to compile even on the
unmodified `tmp/nelua` -- e.g. `fibonacci.nelua` hits a parse error in
`lib/math.nelua` -- because `src/` is mid-edit by another agent; that is a
baseline condition, not a regression from this fix.)

### 4c. Cast variants (all MATCH where the oracle accepts them)

- `(@byte)(300)` -> 44, `(@integer)(44)` -> 44: MATCH
- `(@byte)(500)` -> 244: MATCH (no range-check divergence)
- `(@*[0]byte)(p)` with `p: *byte` non-null: numeric part MATCHes; pointer
  printing DIFFs (see 5, pre-existing).

## 5. Honest notes (out of scope, pre-existing)

1. `probe_cast_min.nelua` does not fully MATCH after the fix. The SIGSEGV is
   gone (exit 0), but the oracle exits 1. The oracle rejects
   `local p: *byte = nil` ("no viable type conversion from 'niltype' to
   'pointer(uint8)'"); our `sema.convert` treats `nilptr -> pointer` as a
   valid implicit conversion (see `sema.nim` doAssert at the `convert(nilptr,
   p1)` line). That is a separate semantic-check divergence, not the cast
   crash, and not addressed here.
2. Non-null pointer printing DIFFs: the oracle prints a hex address
   (`0x...`) for a non-null pointer; our `nelua_print_nil` receives no value
   (codegen sets `passArg=false` for `tkPointer`) so it cannot distinguish.
   The companion fix 3c makes null pointers and `nilptr` print `(null)` (which
   is what the task probe needs), but non-null pointer printing is a larger,
   separate divergence.
3. `(@nilptr)(p)` is rejected by the oracle as a syntax error
   ("expected a type expression"); our fix accepts it. Out of scope.

## 6. Done-when checklist

- [x] Exact crash proc/line identified by gdb on a rebuilt debug binary
      (`analyzeCall`, `src/analyzer.nim:601`, `calleeType` nil).
- [x] Root cause characterized (cast caller is `nkParen`/`nkType`, not `nkId`;
      no code path resolved the target type; line 601 nil deref).
- [x] Fix designed and applied ONLY to `tmp/srcfix/` (analyzer.nim, cgen.nim,
      runtime.c), never to `src/`.
- [x] `tmp/nelua_fix` built (`nim c -d:release --path:tmp/srcfix`).
- [x] `tmp/pc1.nelua` MATCHes the oracle (exit 0, stdout `(null)`); no SIGSEGV
      under gdb.
- [x] `tmp/probe_cast_simple.nelua` MATCHes (confirms casts generally work,
      not just the `*[0]byte` case).
- [x] `tmp/idx_param.nelua` still MATCHes (crash 2 untouched, no regression).
- [x] Regression sweep over `examples/www`: no new DIFF/FAIL vs baseline.
- [x] Companion print fix documented and isolated.
- [x] Out-of-scope divergences (`probe_cast_min` nil-to-pointer, non-null
      pointer print, `@nilptr` cast) stated explicitly and honestly.

## 7. Files

- `plan/DONE/driver-segv-fixes.md` -- this doc.
- `tmp/srcfix/analyzer.nim` -- cast target-type resolution (fix 3a).
- `tmp/srcfix/cgen.nim` -- cast C emission (fix 3b).
- `tmp/srcfix/runtime.c` -- `nelua_print_nil` spelling (fix 3c).
- `tmp/nelua_fix` -- built fixed compiler.
- `tmp/rpr/run_fix.sh` -- oracle-vs-fix harness.
- `tmp/cmp_baseline.py` -- corpus regression harness.
- `tmp/nelua_dbg` -- debug-info build used for the backtrace.