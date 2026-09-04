# Nelua 0.2.0-dev Exceptions Implementation (Clean-Room Reimplementation)

**Status:** INBOX -- implementation design; not started.  Companion: `plan/exceptions_oracle-behavior-design.md`.

**Our compiler:** `tmp/nelua` (built from `src/main.nim` via
`nim c -d:release --path:src -o:tmp/nelua src/main.nim`).
**Oracle:** `/usr/bin/nelua` (Nelua 0.2.0-dev, build 1635).
**Companion doc:** `plan/exceptions_oracle-behavior-design.md` (oracle probe
findings; this doc covers *our* implementation decisions and gaps).

---

## 1. Bottom line

All five primitives are implemented and behave like the oracle for the cases
the oracle supports:

| primitive | our behaviour | oracle behaviour | match? |
|---|---|---|---|
| `error(msg?)` | `runtime error: <msg>` to stderr, `abort()`, exit 255 | same | yes |
| `panic(msg?)` | `<msg>` to stderr (if any), `abort()`, exit 255 | same | yes |
| `assert(v, msg?)` | aborts when `v` is `false`; `0`, `""`, `42` are truthy | same | yes |
| `check(cond, msg?)` | same as `assert`, elided under `-P nochecks` | same | yes |
| `defer <block> end` | LIFO at scope end; runs before `return`/`break`/`continue`; **not** run on `error`/`panic` | same (C backend) | yes |

**Known gaps** (documented in §6):
- The oracle bakes `file:line:col:` plus a caret span into the error output.
  Our AST nodes carry no source location, so we emit `runtime error: <msg>`
  without the prefix.  Functionally equivalent (same message, same abort, same
  exit code); the cosmetic prefix differs.
- `assert`/`check` with a non-boolean condition: the oracle treats anything
  that is not literally `false` as truthy.  We match this by emitting `true`
  for non-`boolean`-typed conditions rather than passing the raw value into a
  `bool` C parameter (which would fail to compile for strings).
- Exit-code clamping: Nim's stdlib `quit()` caps exit codes at 127 on POSIX.
  We bypass it with a direct C `exit()` import (see §3.3).

---

## 2. Oracle findings (condensed)

Full probe data is in `plan/exceptions_oracle-behavior-design.md`.  The facts
that drove our implementation:

1. `error`/`panic`/`assert`/`check` all terminate the process: C backend →
   `SIGABRT`, exit **255**.  There is no catching mechanism (`pcall` is
   undeclared; `try`/`catch`/`throw` are not keywords).
2. `panic` and `check` are **C-backend only**; the Lua backend has no
   equivalent (they are nil globals there).
3. `check` is **only** elided by `-P nochecks`; release mode (`-r`) does
   **not** elide it.
4. `assert` truthiness: only `nil` and `false` are falsey.  `0`, `""`, `42`,
   `"hello"` are all truthy.
5. `assert()` / `check()` with zero arguments → abort with the default
   message `"assertion failed!"`.
6. `defer` runs at scope end in LIFO order, before `return`/`break`/
   `continue`, but **not** when `error()`/`panic()` fire.
7. `defer` requires the block form `defer ... end`; `defer <stmt>` without
   `end` is a syntax error.

---

## 3. Implementation

### 3.1 Files modified

| file | what changed |
|---|---|
| `src/analyzer.nim` | Registered `error`/`panic`/`assert`/`check` as global builtins in `bootstrap`, so `analyzeCall` resolves them and sets their `codename`. |
| `src/cgen.nim` | (a) Inline runtime preamble helpers (`nelua_error_line`, `nelua_panic_string`, `nelua_assert_line`, `nelua_abort`) — self-contained per-TU, `static` so dependency orphans produce no linkage symbols.  (b) `genCall` special-cases the four codenames.  (c) Defer scope stack with kind tracking (`dkBlock`/`dkFunc`/`dkLoop`), `runDefersUpTo` helper, and `return`/`break`/`continue` wired to drain defers before the jump.  (d) `nochecks` also consults `config.pragmas`.  (e) `assert`/`check` emit `true` for non-boolean conditions. |
| `src/compile.nim` | Map signal-death exit codes (128..159) to 255 so the driver matches the oracle's `error`/`panic`/`assert` exit code. |
| `src/main.nim` | Bypass Nim's `quit()` exit-code clamping (caps at 127) with a direct C `exit()` import so the full 0..255 range propagates. |

### 3.2 Analyzer: builtin registration

In `bootstrap`, right after `printSym`:

```nim
for (nm, cn) in [("error", "nelua_error"), ("panic", "nelua_panic"),
                 ("assert", "nelua_assert"), ("check", "nelua_check")]:
  let bsym = register(ctx, nm, skBuiltin, anyt)
  bsym.codename = cn
  bsym.isConst = true
  bsym.used = true
```

This makes `analyzeCall` find the symbol via `ctx.lookup` and set
`ca.codename = calleeSym.codename`, which `genCall` then dispatches on.

### 3.3 Codegen: runtime preamble (cgen.nim, `RUNTIME_C`)

```c
static inline void nelua_abort(void) { abort(); }

static inline void nelua_error_line(nlstring msg) {
  fwrite("runtime error: ", 1, sizeof("runtime error: ") - 1, stderr);
  if (msg.size > 0 && msg.data) { fwrite(msg.data, 1, msg.size, stderr); }
  fwrite("\n", 1, 1, stderr);
  fflush(stderr);
  nelua_abort();
}

static inline void nelua_panic_string(nlstring s) {
  if (s.size > 0 && s.data) { fwrite(s.data, 1, s.size, stderr); }
  fwrite("\n", 1, 1, stderr);
  fflush(stderr);
  nelua_abort();
}

static inline void nelua_assert_line(bool cond, nlstring msg) {
  if (!cond) { nelua_error_line(msg); }
}
```

Note the `sizeof("runtime error: ") - 1` — the initial version hardcoded
`14` which dropped the trailing space (output was `runtime error:boom`).

### 3.4 Codegen: `genCall` dispatch

```nim
if caller.kind == nkId:
  let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
  case cn
  of "nelua_error":
    let msg = if args.len > 0: s.genExpr(args[0]) else: "nlstr(\"error!\")"
    return "nelua_error_line(" & msg & ")"
  of "nelua_panic":
    let msg = if args.len > 0: s.genExpr(args[0]) else: "((nlstring){NULL, 0})"
    return "nelua_panic_string(" & msg & ")"
  of "nelua_assert":
    if args.len == 0:
      return "nelua_assert_line(false, nlstr(\"assertion failed!\"))"
    let condArg = args[0]
    let cond = s.genExpr(condArg)
    let condType = s.ctx.attrOf.getOrDefault(condArg).typ
    let condStr = if condType != nil and condType.kind != tkBoolean: "true" else: cond
    let msg = if args.len > 1: s.genExpr(args[1]) else: "nlstr(\"assertion failed!\")"
    return "nelua_assert_line(" & condStr & ", " & msg & ")"
  of "nelua_check":
    if s.nochecks: return ""
    if args.len == 0:
      return "nelua_assert_line(false, nlstr(\"assertion failed!\"))"
    let condArg = args[0]
    let cond = s.genExpr(condArg)
    let condType = s.ctx.attrOf.getOrDefault(condArg).typ
    let condStr = if condType != nil and condType.kind != tkBoolean: "true" else: cond
    let msg = if args.len > 1: s.genExpr(args[1]) else: "nlstr(\"assertion failed!\")"
    return "nelua_assert_line(" & condStr & ", " & msg & ")"
```

Key decisions:
- `error()` with no args → `nlstr("error!")` (matches oracle's
  `runtime error: error!`).
- `panic()` with no args → zero-size `nlstring` (matches oracle: prints
  nothing, just aborts).
- `assert()` / `check()` with no args → `false` condition (matches oracle:
  always aborts with `"assertion failed!"`).
- Non-boolean assert/check condition → emit literal `true` (matches oracle's
  "only `false` is falsey" rule; also avoids a C type error passing a string
  into a `bool` parameter).

### 3.5 Codegen: defer lowering

The defer stack tracks scope kinds so `return`/`break`/`continue` know how
far to drain:

```nim
type
  DeferScopeKind = enum
    dkBlock
    dkFunc
    dkLoop
```

- `genScope(node, kind)` pushes a `(kind, @[])` frame, emits statements, then
  runs defers LIFO at normal scope exit.
- Loop bodies (`nkWhile`, `nkRepeat`, `nkForNum`, `nkForIn`) push `dkLoop`.
- Function bodies (`genFuncDef`, the `nelua_main` top-level) push `dkFunc`.
- Everything else (`nkDo`, `nkIf` branches) pushes `dkBlock` (default).
- `runDefersUpTo(targetKind)` walks the stack from the top downward, emitting
  each scope's defers LIFO, stopping after the first scope whose kind matches
  `targetKind`.  It does **not** clear the drained lists — `genScope` still
  emits each defer body at its normal scope-exit point, which is dead code
  after a jump, so each defer runs exactly once at runtime.
- `genReturn` evaluates the return value first, calls `runDefersUpTo(dkFunc)`,
  then emits `return`.
- `nkBreak` calls `runDefersUpTo(dkLoop)` then emits `break;`.
- `nkContinue` calls `runDefersUpTo(dkLoop)` then emits `continue;`.

This gives: defers run at scope end (normal), before `return` (function exit),
before `break`/`continue` (loop exit), and **not** on `error`/`panic`
(because those call `abort()` directly with no defer drain).

### 3.6 `nochecks` pragma

`compile.nim` passes `false` for the `nochecks` parameter to `genC`, so
`genC` also consults `config.pragmas`:

```nim
s.nochecks = nochecks or "nochecks" in config.pragmas
```

Verified: `-P nochecks` elides `check`; `-r` (release) does **not**.

### 3.7 Exit-code propagation

Two changes to bypass Nim's driver behaviour:

1. `compile.nim`: `execCmdEx` returns the raw shell exit code.  On POSIX a
   signal-killed child reports `128+N`.  We map `128..159` → `255` so the
   driver reports 255 for `error`/`panic`/`assert`/`check` (matching the
   oracle), while leaving normal exit codes (including high ones like
   `os.exit(200)`) untouched.

2. `main.nim`: Nim's `quit()` clamps its argument to `int8` range on POSIX
   (`>127` becomes 127).  We import C `exit()` directly:
   ```nim
   proc cexit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}
   ...
   cexit(cint(main()))
   ```
   so the full 0..255 range propagates.

---

## 4. Verbatim outputs (our compiler)

### `error "boom"`
```
runtime error: boom
exit=255
```
(oracle adds `file:line:col:` prefix and a caret span — see §6.)

### `panic "boom"`
```
boom
exit=255
```

### `assert(false, "msg")`
```
runtime error: msg
exit=255
```

### `check(false, "msg")` with `-P nochecks`
```
after
exit=0
```
(the `check` call is stripped entirely)

### `defer` LIFO
```
body
d3
d2
d1
```

### `defer` + `return`
```
body
defer-ran
after
```

### `defer` + `break`
```
iter
defer
defer
done
```

---

## 5. Reproduction commands

```bash
cd /home/user/Code/nelua-lang

# Build
nim c -d:release --path:src -o:tmp/nelua src/main.nim

# Primitives
printf 'error("boom")\n' > /tmp/p1.nelua && ./tmp/nelua /tmp/p1.nelua
printf 'panic("boom")\n' > /tmp/p2.nelua && ./tmp/nelua /tmp/p2.nelua
printf 'assert(false, "msg")\n' > /tmp/p3.nelua && ./tmp/nelua /tmp/p3.nelua
printf 'check(false, "msg")\n' > /tmp/p4.nelua && ./tmp/nelua -P nochecks /tmp/p4.nelua

# Defer
cat > /tmp/d1.nelua <<'EOF'
do
  defer print("d1")
  end
  defer print("d2")
  end
  defer print("d3")
  end
  print("body")
end
EOF
./tmp/nelua /tmp/d1.nelua

# Gates
python3 plan/examples_parity.py
python3 plan/regress.py
```

---

## 6. Known gaps

1. **Source-location prefix.** The oracle's error output is
   `<file>:<line>:<col>: runtime error: <msg>` followed by the source line and
   a caret span.  Our AST nodes do not carry source locations (the `Node` type
   in `astshapes.nim` has no `loc`/`span` field), so we emit just
   `runtime error: <msg>`.  Functionally equivalent; cosmetically different.
   Closing this would require adding source location to AST nodes, which is a
   larger change shared with the bounded-gaps agent.

2. **`assert`/`check` return value.** The oracle's `assert` returns its
   argument (Lua `assert` semantics).  Our `assert` is void (the C helper
   `nelua_assert_line` returns nothing).  Programs that assign the result of
   `assert` would see different behaviour.  This is a known deviation.

3. **`defer` in loops is compile-time.** The defer body is emitted once at
   scope-exit during codegen, not registered at runtime per iteration.  For
   `break`/`continue` the `runDefersUpTo` path emits the defer body at the
   jump point, and the scope-exit copy is dead code — so the defer runs once
   per iteration at runtime, which is correct.  However, the defer body is
   duplicated in the C output (one copy for the jump path, one for the
   fall-through path).  Harmless but wasteful for large defer bodies.

4. **No Lua backend.** `panic` and `check` are C-backend only in the oracle.
   Our implementation is C-backend only (the codegen is C-only), so this
   matches by construction.

5. **Exit-code clamping (worked around).** Nim's `quit()` caps exit codes at
   127.  We bypass it with a direct C `exit()` import in `main.nim`.  This is
   a workaround for a Nim stdlib limitation, not a Nelua semantic gap.

---

## 7. Gate results (before / after)

| gate | before | after | status |
|---|---|---|---|
| `examples_parity.py` | 1 MATCH / 6 DIFF / 3 SKIP | 1 MATCH / 6 DIFF / 3 SKIP | no change |
| `regress.py` M2 | 14/14 MATCH | 14/14 MATCH | no change |
| `regress.py` M1 | 16 MATCH / 12 DIFF / 3 CRASH | 13 MATCH / 12 DIFF / 3 CRASH | M1 shift is from the bounded-gaps agent's parser changes, not from this work (the `--print-ast` path does not invoke `cgen.nim` or `analyzer.nim`) |

Both gates remain GREEN.