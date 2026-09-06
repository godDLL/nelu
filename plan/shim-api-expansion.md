# Expanding the Nim-provided C-ABI shim for the pp Lua environment

Status: **implemented + verified, awaiting review** (do not commit).
Scope: the `pragmas` builtin only.  See §5 for what is deliberately *not* done.

## 1. The decision that led here

The user settled (plan/embedded-lua-pp-investigation.md §7): we expand the
small Nim-provided C-ABI shim that the preprocessor's embedded Lua runs
against — *not* by exposing the whole Nim compiler to Lua, and *not* by
shimming our compiler back in on the other side.  The question was whether
there was real demand.  This doc is the grounding for what got done.

## 2. What the shim already exposes (no change needed)

`registerPreprocessorBuiltins` (src/preprocessor.nim:1316) already registers
these globals for `##` blocks, and the stdlib already uses them:

| builtin | stdlib users | status |
|---|---|---|
| `hygienize` | `lib/allocators/gc.nelua` (`after_analyze(hygienize(...))`) | works |
| `static_assert` | `lib/errorhandling.nelua` | works |
| `inject` / `inject_astnode` | `lib/allocators/heap.nelua` (`cemit`) | works |
| `cinclude` / `cdefine` / `cemit` / `cflags` | `lib/os.nelua`, `lib/allocators/heap.nelua` | works |
| `concept` / `generic` / `generalize` / `static_error` | — | works |
| `primtypes` / `typedefs` + type-name globals | splice env (`#[...]#`) | works |
| `ppregistry` | — | works |

So the "expand the API" question was *not* about these — they were already
there.  The gap had to be found by running the stdlib and reading the first
error.

## 3. The gap: `pragmas`

Compiling `lib/detail/strprintf.nelua` (a `require` of `lib/math.nelua`)
failed at:

```
lib/detail/strprintf.nelua:13: attempt to index a nil value (global 'pragmas')
```

`strprintf.nelua:13` is `## if pragmas.usestbsprintf then`.  The stdlib
reads `pragmas` in many places:

- `lib/errorhandling.nelua` — `pragmas.noexceptions`, `pragmas.noerror`,
  `pragmas.noreturn`, `pragmas.abort` (compared to `'exit'`/`'trap'`)
- `lib/coroutine.nelua`, `lib/allocators/gc.nelua`, `lib/allocators/default.nelua`,
  `lib/C/threads.nelua`, `lib/allocators/allocator.nelua` — `pragmas.nogc`,
  `pragmas.nogcentry`
- `lib/detail/strprintf.nelua` — `pragmas.usestbsprintf`

`pragmas` was simply not registered as a pp global.  That is the concrete,
grounded expansion.

## 4. Implementation — matched to the oracle's exact model

This is the part worth reading carefully.  The reference's `pragmas` is *not*
a plain table built by splitting `-P` strings.  `configer.lua` does:

```lua
local function convert_param(param)
  if param:match('^%a[_%w]*$') then      -- bare name
    param = param .. ' = true'           --   -> "name = true"
  end
  local _, err = load(param, '@define', "t")   -- must parse
  ...
end
...
for _,code in ipairs(conf.pragma) do
  local f = load(code, '@pragma', "t", pragmas)  -- env = the pragmas table
  pcall(f)
end
tabler.update(conf.pragmas, pragmas)
```

So:
- `-P fooobar` → rewritten `fooobar = true` → `pragmas.fooobar = true`
- `-P abort=exit` → loaded verbatim `abort=exit` with `pragmas` as env →
  `pragmas.abort = exit`, and `exit` is not in scope there → **`nil`**
  (this is why `pragmas.abort` is `nil` in the pp phase unless `pragmapush`
  sets it — the shaped `abort` pragma is a compiler-level concern, not a
  pp-read)
- `-P 'usestbsprintf = true'` → `pragmas.usestbsprintf = true`

Nelu replicates this **in Lua**, so the environment semantics are identical
rather than approximated in Nim:

- `setPragmasGlobal` (src/preprocessor.nim) pushes the `-P` strings as a
  `__nelua_raw_pragmas` table, runs `PRAGMAS_INIT_CHUNK` (the `convert_param`
  logic + `load(code, '@pragma', 't', pragmas)`), then clears the scratch
  global.  Returns an error string; a pragma that does not load or run raises,
  like the reference.
- `pragmas` is created as an empty table even when there are no `-P` pragmas,
  so `## if pragmas.nogc then` reads `nil` rather than indexing a nil global.
- Threaded from `config.pragmas`: `newPreprocessContext` gained a
  `pragmas` param; `analyzeModule` (src/analyzer.nim:2322) passes
  `config.pragmas`, which propagates to `require`d dependencies because
  `analyzeModule` recurses with the same `config`.
- Hooked into `runPreprocessChunk` right after `registerPreprocessorBuiltins`,
  before the user's `##` chunk runs, so `pragmas` is visible to every `##`
  line in the module.

### Verification (Nelu vs oracle, byte-for-byte)

```
-P fooobar -P usestbsprintf -P abort=exit:
  fooobar=true  usestbsprintf=true  abort=nil  nogc=nil   (both)
no -P:
  fooobar=nil   usestbsprintf=nil   abort=nil  nogc=nil    (both)
-P 'usestbsprintf = true':
  usestbsprintf=true                                   (both)
```

And the actual stdlib blocker: `nelua -P usestbsprintf -c lib/detail/
strprintf.nelua` now emits `stb_sprintf` (the tbs branch); without `-P` it
does not.  The pragma switches the branch correctly.

## 5. What is deliberately NOT done

- **`pragmapush` / `pragmapop` stacking.** The reference's `pragmas` is a
  stacked object (`ppcontext.lua` push/pop).  No stdlib file *needs* the
  stacking to get past the first error; `errorhandling.nelua`'s
  `## pragmapush{noerror=true}` / `## pragmapop()` is a separate mechanism.
  Follow-up if a stdlib file demands it.
- **Compiler-level pragma semantics.** Setting `## pragmas.nogc = true`
  (tests/libmylib.nelua:4, tests/threads_test.nelua:1) now works at the pp
  table level, but Nelu's compiler does not yet *honour* `nogc`/`unitname`
  etc. for codegen.  That is a compiler feature gap, not a shim gap — out of
  scope here.
- **Exposing the whole compiler to Lua (path b).** Rejected by the user; not
  revisited.

## 6. Files changed

- `src/preprocessor.nim` — `PreprocessContext.pragmas` field;
  `newPreprocessContext(source, path, pragmas)`; `PRAGMAS_INIT_CHUNK` const;
  `setPragmasGlobal(L, pragmas): string`; wired into `runPreprocessChunk`.
- `src/analyzer.nim` — `analyzeModule` passes `config.pragmas`.
- `src/luaengine.nim` — declared `lua_pushnil` (was missing from the FFI).
- `src/config.nim`, `src/cli.nim`, `src/main.nim`, `src/luaengine.nim` — the
  `--lua` REPL and `--script` wiring from the earlier pass (already reviewed).

## 7. Regression status

`python3 plan/harness.py`: **TOTAL 9 BOTH_FAIL 2 DIFF 223 MATCH 4
NELU_ACCEPT 12 NELU_CRASH 40 NELU_REJECT 14 ORACLE_FAIL 1 SKIP — regressions:
0, improvements: 4, new: 1.**  The 4 improvements and 1 new are pre-existing
(likely/unlikely branch hints, `fn_multi`) and unrelated to this change.

Pre-existing failures confirmed *not* caused by this change (both compile
cleanly under the oracle):
- `tests/string_test.nelua:546` — hex-float `0x3.3p3` parse error (parser
  limitation; the parse happens before pp runs, so the `pragmas` table is not
  in play).
- `tests/threads_test.nelua` — `lib/C/threads.nelua` `static_error`:
  multithreading+GC; Nelu does not yet honour the `nogc` pragma at the
  compiler level.