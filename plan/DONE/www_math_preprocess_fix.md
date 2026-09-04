# www_math SIGSEGV — root cause and minimal fix

**Status:** RESEARCH (read-only on `src/`).  A working prototype of the core fix
lives in `/tmp/ns` (a scratch copy of the repo) at `/tmp/nelua_p2`; it compiles
`lib/detail/xoshiro256.nelua` cleanly through analysis all the way to C codegen
(the remaining C-link error, `self` undeclared in `nextrand`, is a separate
codegen bug, not a preprocessor bug).

---

## 1. Symptom

```
$ tmp/nelua -b examples/www/www_math.nelua
nelua: unable to analyze lib/detail/xoshiro256.nelua:
/* nelua: error while preprocessing block: @.../xoshiro256.nelua:splice:
   attempt to perform arithmetic on a nil value (global 'FIGS') */
require ''detail.xoshiro256'': dependency '...' did not compile
require ''math'': dependency '...' did not compile
```

(With the earlier nil-check patches the crash was a SIGSEGV in `inferBinary`;
that is now a clean diagnostic.  Either way the compilation fails: `require
'math'` cannot resolve its dependency chain.)

The oracle compiles the same file to a binary and it runs:

```
$ /usr/bin/nelua -b examples/www/www_math.nelua ; /home/user/.cache/nelua/www_math
3
3
5
7
3
9
0.0
3.1415926535898
```

---

## 2. What actually fails (it is NOT the `##[[` block)

`www_math` → `require 'math'` → `lib/math.nelua` → `require 'detail.xoshiro256'`
→ `lib/detail/xoshiro256.nelua`.  The first failure is in xoshiro256:

```nelua
function Xoshiro256:random(): number
  ## local FIGS = math.min(primtypes.number.mantidigits, 64)
  return (self:nextrand() >> #[64 - FIGS]#) * (0.5 / (1_u64 << #[FIGS-1]#))
end
```

`## local FIGS = ...` is a `##` line directive; `#[64 - FIGS]#` / `#[FIGS-1]#` are
splice expressions.  The splice needs to *see* the `##` line's `local FIGS`.
The same pattern recurs all over `lib/math.nelua` (`## local x, y = ...` +
`#[x]# < #[y]#` in `math.min`; `## if x.type.is_float then` + `#[choose_float_type(x)]#`
in `math.deg`/`math.floor`; `## local ftype, fname, incname = ...` +
`#[ftype]#`/`#[fname]#` in `import_cmath_func1`).

The `##[[ ... ]]` block at the top of `math.nelua` (which defines
`choose_float_type` etc.) is *not* the direct cause: it is folded to
`nkPreprocess(str=body, boolVal=true)` exactly as the oracle does it, and it
runs as a standalone chunk.  The blocker is the `##` line / `#[expr]#` splice
interaction.

---

## 3. The oracle's mechanism (evidence: `--print-ppcode`)

```
$ /usr/bin/nelua --print-ppcode lib/detail/xoshiro256.nelua
ppregistry[2].preprocess=function(blocknode, ...)
  ppcontext:push_statnodes(blocknode)
 local FIGS = math.min(primtypes.number.mantidigits, 64)
  ppcontext:inject_value(64 - FIGS,ppregistry[5],3,ppregistry[6])
  ppcontext:inject_value(FIGS-1,ppregistry[7],3,ppregistry[8])
  ppcontext:inject_statement(ppregistry[4])
  ppcontext:pop_statnodes()
end
```

Three things the oracle does that our build does not:

1. **One chunk per block.**  The `##` line (`local FIGS = ...`) and every
   `#[expr]#` splice (`ppcontext:inject_value(64 - FIGS, ...)`) are compiled
   into the *same* Lua chunk — the body of `ppregistry[N].preprocess`.  Because
   `64 - FIGS` is a literal expression in that chunk, the chunk's own `local
   FIGS` is visible to it.  Our build runs `##` lines and splices as *separate*
   `luaL_loadbufferx` invocations, so a `local` in one chunk is invisible to the
   next (and the `##` lines are deferred to the end of the block, *after* the
   splices that reference them).

2. **Scope binding (`push_statnodes`).**  The block's nelua scope (function
   parameters, block locals) is exposed to the chunk as statnodes, so
   `x.type.is_float` in `## if x.type.is_float then` resolves `x` to the
   parameter's type.  Our build has no equivalent; `x` is a nil Lua global.

3. **`inject_value`.**  A splice evaluates its expression in the chunk scope and
   injects the resulting *value* as an AST node at the splice's source position.
   Our build's `evalSpliceExpr` runs `return (expr)` in its own chunk and
   converts the result — correct value, wrong scope.

`push_statnodes` / `inject_value` / statnodes are the "Stage 4 scope-aware
splice evaluator" that this build's `cConcept` comment (preprocessor.nim:877)
explicitly defers.  That is the real gap.

---

## 4. The minimal fix (validated on xoshiro256)

The prototype in `/tmp/ns` implements the "one chunk per block" half of Stage 4
with ~60 lines in `src/preprocessor.nim`.  It makes xoshiro256 preprocess and
analyze cleanly.  The pieces:

### 4a. Merge `#[expr]#` splices into the `##`-line chunk

A new C builtin `__nelua_capture(idx, value)`:

```nim
proc cCapture(L: PLuaState): int {.cdecl.} =
  ## `__nelua_capture(idx, value)` -- `expr` was compiled *literally* into the
  ## merged chunk, so it sees the chunk's `local`s.  Convert `value` to a Node
  ## and store it in the current block's splice-result slot `idx`.
  var isnum: cint
  let idx = int(lua_tointegerx(L, 1, addr(isnum)))
  if gSpliceResultStack.len > 0 and isnum != 0 and idx < gSpliceResultStack[^1].len:
    gSpliceResultStack[^1][idx] = luaValueToNode(L, 2)
  return 0
```

The block handler stops evaluating splices inline.  Instead it collects every
`nkPreprocessExpr` in the subtree (document order) into a per-block stack
(`gSpliceDefStack`/`gSpliceNodeStack`), leaves the nodes in the tree, and passes
them to `runPreprocessChunk`, which now appends them *after* the `##` lines as
`__nelua_capture(idx, expr)` where `expr` is the splice text compiled literally:

```
__nelua_mark(0)  local FIGS = math.min(primtypes.number.mantidigits, 64)
__nelua_capture(0, 64 - FIGS)
__nelua_capture(1, FIGS-1)
```

Running `local FIGS = ...` and `64 - FIGS` in one chunk is what makes `FIGS`
visible.  After the chunk runs, a pre-order walk replaces every registered splice
node with its captured result (the splice nodes and the results are both in
document order, so one advancing index lines them up).

`runPreprocessChunk` becomes `(seq[seq[Node]], seq[Node])` — the injected
`##`-line nodes *and* the splice results — and pops its own `gSpliceResultStack`
frame, so it stays re-entrant.

### 4b. `mantedigits` Type attribute

`primtypes.number.mantidigits` is read by the `## local FIGS` line.  The
`cTypeIndex` `__index` metamethod had no `mantedigits` case, so it returned
`lightuserdata(nil)` and `math.min(nil, 64)` errored ("attempt to compare
number with userdata").  One `of "mantedigits":` case (24 for float32, 113 for
float128, 53 otherwise) fixes it.

---

## 5. What is still needed (honest scope)

The prototype only covers splices that live in the **same block** as their `##`
line.  `lib/math.nelua` also uses the harder pattern — a `##` line *inside a
`## if/elseif/end` frame* whose body is captured and re-injected:

```nelua
function math.min(...: varargs): auto <inline,nosideeffect>
  ## local nargs = select('#', ...)
  ## if nargs == 1 then
    return #[select(1, ...)]#
  ## elseif nargs == 2 then
    ## local x, y = select(1, ...), select(2, ...)
    return #[x]# < #[y]# and #[x]# or #[y]#      -- splice sees ## local x,y
  ## else ...
```

The frame chunk (`constructFrameChunk`) emits the captured body as
`__nelua_inject("body_N")`, which is later preprocessed *recursively* — so the
splices inside it run in a different chunk from the `## local x, y` that defines
them.  Closing this gap is the same merge, applied to frame body parts instead of
block children: emit the body's splices as `__nelua_capture` calls inside the
frame chunk and replace them in the captured body.  Same shape as 4a, applied one
level deeper.

Beyond the merge, two more things are required for `www_math` to run like the
oracle:

- **Function-parameter binding** (`x.type.is_float`, `choose_float_type(x)`).
  The oracle's `push_statnodes` binds each parameter as a statnode so `x.type`
  resolves to the parameter's Type.  Our build would need a "symbol wrapper"
  Lua table whose `__index` maps `type` → `pushTypeWrapper(paramType)`, plus a
  `luaValueToNode` case that converts the wrapper to `newId(name)` when a splice
  returns it (`#[x]#`).  Bind them when entering a `FuncDef` during the walk.
- **`deduceAutoReturns` nil-safety.**  Once the frame case is fixed, `math.min`'s
  `#[x]# < #[y]# and #[x]# or #[y]#` return still crashes the analyzer
  (`deduceAutoReturns__analyzer_u20164`, SIGSEGV on a nil Type field) when a
  splice result is `nil`.  This is the same class of crash as the original
  `inferBinary` one and needs the same defensive treatment so a failed splice
  becomes a clean diagnostic instead of a segfault.

---

## 6. Bottom line

- **Crash/diagnostic location:** the preprocessor cannot evaluate `##` line /
  `#[expr]#` splice pairs that share a variable, so `require 'math'` fails; the
  secondary SIGSEGV is in `inferBinary`/`deduceAutoReturns` on nil Type fields
  once the raw parse tree reaches the analyzer.
- **Oracle:** wraps each block in `ppcontext:push_statnodes` and runs its `##`
  lines and `#[expr]#` splices as **one** Lua chunk, with scope variables bound
  as statnodes and splices emitted as `ppcontext:inject_value(expr)`.
- **Ours:** runs `##` lines and splices as separate chunks, defers `##` lines to
  the end of the block, and binds no scope variables.
- **Minimal fix (validated):** merge `#[expr]#` splices into the `##`-line chunk
  via `__nelua_capture` (~60 lines, `src/preprocessor.nim`) + `mantedigits`
  (a few lines).  This is literally the "one chunk per block" half of the
  deferred Stage 4 scope-aware evaluator.
- **Still open for `www_math` to run like the oracle:** the frame-body merge,
  function-parameter binding, and the `deduceAutoReturns` nil-safety fix.  These
  are the rest of Stage 4 plus one analyzer hardening — not "a few lines", but
  they are the correct minimal path; a smaller change is a fragile hack (e.g.
  promoting `## local` to globals collides across functions, as `x`/`y` in
  `math.min` vs. the `x` parameter of `math.deg` demonstrate).