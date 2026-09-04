# Nelua 0.2.0-dev Exceptions Oracle Behavior

**Oracle:** `/usr/bin/nelua` (Nelua 0.2.0-dev, build 1635, git a5845056, dated 2025-06-24).
**Method:** every probe below was written to a distinct file under
`tmp/oracle_probe/` and run with `/usr/bin/nelua <file>` (C backend) and
`/usr/bin/nelua -g lua <file>` (Lua backend). File runs are authoritative.
Stdout, stderr, and exit code are captured verbatim. The Lua backend runs
stock **Lua 5.4** (`/usr/bin/nelua -g lua -` with `print(_VERSION)` → `Lua
5.4`).

> **Bottom line:** the oracle has **no structured exception handling at all** —
> `try`/`catch`/`throw`/`finally`/`raise`/`except`/`recover`/`perror` are all
> rejected (syntax errors or undeclared symbols). What exists is a small set of
> **fatal panic primitives**: `error(msg: string)`, `panic(msg: string)`
> (C-backend only), `assert(v, msg?)`, and `check(cond, msg?)` (C-backend
> only). All of them terminate the process: C backend → `SIGABRT`, exit 255;
> Lua backend → Lua `error()`, exit 1. There is **no way to catch** any of
> them. `defer` blocks exist and run at scope end (C backend), but **do not
> run** when `error()`/`panic()` fire, and the **Lua backend cannot compile
> `defer` at all** (emitter bug). The C backend lowers each panic to a
> per-call `nelua_error_line_N` / `nelua_assert_line_N` runtime helper that
> bakes the source line + caret span into the error output.

---


**Status:** INBOX -- companion to `plan/INBOX/exceptions-implementation.md`; oracle behavior reference.

## 1. Does the oracle compile and run exception programs?

| construct | C backend | Lua backend |
|---|---|---|
| `try`/`catch`/`throw`/`finally`/`raise`/`except`/`recover`/`perror` | **rejected** (see §2) | **rejected** (same) |
| `error(msg)` | compiles + runs → SIGABRT, exit 255 | compiles + runs → Lua error, exit 1 |
| `panic(msg)` | compiles + runs → SIGABRT, exit 255 | **`panic` is a nil global** → `attempt to call a nil value` |
| `assert(v, msg?)` | compiles + runs | compiles + runs |
| `check(cond, msg?)` | compiles + runs; **omitted** with `-P nochecks` | **`check` is a nil global** → runtime error |
| `defer <block> end` | compiles + runs (reverse order at scope end) | **fails to compile** (emitter bug, `visit` is nil) |

The only constructs that actually execute on both backends are `error`,
`assert`, and `defer` — and `defer` is broken on Lua. `panic` and `check`
are **C-backend-only** builtins (they are emitted as calls to globals that
the Lua backend does not define).

### Probe E1 (verbatim) — `try`/`catch`

File `tmp/oracle_probe/x01.nelua`:
```nelua
try
  print("in try")
catch e
  print("caught", e)
end
```

```
########## C backend ##########
x01.nelua:1:1: syntax error: unexpected syntax
try
^
exit=1

########## Lua backend ##########
x01.nelua:1:1: syntax error: unexpected syntax
try
^
exit=1
```

`try` is not a keyword. The parser rejects it as "unexpected syntax".

### Probe E2 (verbatim) — `throw`

File `tmp/oracle_probe/x02.nelua`:
```nelua
throw "boom"
```

```
########## C backend ##########
x02.nelua:1:1: from: AST node Block
throw "boom"
^~~~~~~~~~~~
x02.nelua:1:1: error: undeclared symbol 'throw'
throw "boom"
^~~~~
exit=1

########## Lua backend ##########
(identical)
```

`throw` parses as an identifier (it is not a keyword) and is then rejected as
an undeclared symbol.

---

## 2. Findings table

Legend: **A** = accepted, **E** = error, **R** = rejected, **C-only** = C
backend only, **L-broken** = Lua backend broken.

| # | Behavior | Syntax | Oracle result (C backend / Lua backend) | Note |
|---|---|---|---|---|
| 1 | `try/catch` | `try ... catch e ... end` | E: `syntax error: unexpected syntax` / E same | Not a keyword. |
| 2 | `throw` | `throw "x"` | E: `undeclared symbol 'throw'` / E same | Parses as ident, then undeclared. |
| 3 | `perror` | `perror "x"` | E: `undeclared symbol 'perror'` / E same | Not the C `perror`; no builtin. |
| 4 | `raise` | `raise x` | E / E | Not a keyword. |
| 5 | `recover` | `recover x` | E / E | Not a keyword. |
| 6 | `except` | `except x` | E / E | Not a keyword. |
| 7 | `finally` | not tested as keyword | (not a keyword) | `try` already rejected, so `finally` unreachable. |
| 8 | `error(msg)` | `error "boom"` | A → `runtime error: boom` + source span + SIGABRT, exit 255 / A → Lua traceback, exit 1 | The panic primitive. Never returns. |
| 9 | `error()` no arg | `error()` | A → `runtime error: error!` / A → `(error object is a nil value)` | 0 args tolerated at compile time; runtime error object is nil on Lua. |
| 10 | `error(var)` | `error(e)` where `e: string` | A → `runtime error: <value>` / A | Runtime string value works. |
| 11 | `error(42)` | `error(42)` | E: `no viable type conversion from 'int64' to 'string'` / E | arg must be `string`. |
| 12 | `error(true, "x")` | 2 args | E: `expected at most 0 arguments but got 2` / E | 0 or 1 arg only. |
| 13 | `panic(msg)` | `panic "x"` | A → prints `x` to stderr + SIGABRT, exit 255 / **nil global** → runtime error | C-backend-only. No source span in output. |
| 14 | `panic()` | `panic()` | A → SIGABRT, no message / — | C-backend-only. |
| 15 | `panic(42)` | `panic(42)` | E: int64 → string conversion / — | C-backend-only. |
| 16 | `panic("a","b")` | 2 args | E: too many args / — | C-backend-only. |
| 17 | `assert(true)` | `assert(true)` | A, no-op / A | Returns the value. |
| 18 | `assert(false)` | `assert(false)` | A → `runtime error: assertion failed!` + SIGABRT / A → Lua error | Default message `"assertion failed!"`. |
| 19 | `assert(false, "msg")` | `assert(false, "bad")` | A → `runtime error: bad` / A | Custom message. |
| 20 | `assert(v, msg)` returns v | `local x = assert(2+2, "m"); print(x)` | A → prints `4` / A → `4` | Returns the tested value (Lua `assert` semantics). |
| 21 | `assert(nil, "m")` | `assert(nil, "bad")` | A → `runtime error: bad` / A | nil is falsey. |
| 22 | `assert(0, "m")` | `assert(0, "bad")` | A → returns `0` (truthy!) / A | Nelua truthiness: only `nil` and `false` are falsey; `0` is truthy. |
| 23 | `check(true, "m")` | `check(true, "ok")` | A, no-op / **nil global** → runtime error | C-backend-only. |
| 24 | `check(false, "m")` | `check(false, "bad")` | A → `runtime error: bad` + SIGABRT / — | C-backend-only. |
| 25 | `check` omitted | `check(false,"x")` with `-P nochecks` | A → call removed, program survives / — | `-P nochecks` strips `check` entirely in C. |
| 26 | `defer` block | `defer print(1) end` | E: syntax error / — | `defer` requires a **block** (`defer ... end`), not a single statement. |
| 27 | `defer` runs at scope end | `print(1); defer print(2) end; print(3)` | A → `1 3 2` / **L-broken**: emitter crash (`visit` is nil) | C backend works. Lua backend cannot compile any `defer`. |
| 28 | multi-`defer` order | two defers in one scope | A → reverse (LIFO) order / L-broken | Go/Rust semantics. |
| 29 | `defer` + `return` | defer inside a function that returns | A → defer runs before the return value is returned / L-broken | |
| 30 | `defer` + `error` | `defer ... end; error "x"` | A → **defer does NOT run**; `runtime error` + SIGABRT / L-broken | **Fatal panics skip defers.** No cleanup guarantee on error path. |
| 31 | `error` inside a function | `local function f() error "x" end; f()` | A → error reported at the `error` call site, propagates up / A | No exception object is passed up; the C runtime just aborts. |
| 32 | `error` through call stack | f() → g() → error | A → aborts, message points at the `error` site / A | |
| 33 | `error` in `if`/`repeat` | `if c then error "x" end` | A → aborts / A | |
| 34 | `error` + `require` | `require 'io'; error(msg)` | A → works / A | |
| 35 | `error` with typed param | `local function f(s: string); if s=="" then error "empty" end` | A → works / A | |
| 36 | `error("a" .. "b")` | literal concat as arg | A → `runtime error: ab` / A | See #42. |
| 37 | `error("a" .. v)` | variable in concat | E: `invalid operation between types 'string' and 'string'` / E | See #42. |
| 38 | `pcall` | `pcall(function() error "x" end)` | E: `undeclared symbol 'pcall'` / E | **No catching mechanism whatsoever.** |
| 39 | `<close>` variable | `local x <close> = 5` | E: syntax error / — | `<close>` attribute not supported in 0.2.0-dev. |
| 40 | `#error` / `__close` metamethod | (needs `record`, which does not exist) | n/a | `record`/`union`/`enum`/`macro` are **not keywords in 0.2.0-dev** — they are Nelu features. |

---

## 3. Verbatim runtime outputs

### `error "boom"` (C backend)
```
x_error.nelua:1:7: runtime error: boom_error
error "boom_error"
      ^~~~~~~~~~~~

Aborted (SIGABRT)
exit=255
```
Message format: `<file>:<line>:<col>: runtime error: <msg>` followed by the
source line and a caret spanning the error argument. Then `SIGABRT`.

### `error "boom"` (Lua backend)
```
/usr/bin/nelua-lua: /home/user/.cache/nelua/x_error.lua:4: boom_error
stack traceback:
	[C]: in function 'error'
	/home/user/.cache/nelua/x_error.lua:4: in main chunk
	[C]: in ?
exit=1
```
Plain Lua `error()` propagation — a traceback and exit 1.

### `panic "boom"` (C backend)
```
boom_panic
Aborted (SIGABRT)
exit=255
```
Bare message, **no** source span, no "runtime error:" prefix.

### `panic` (Lua backend)
```
/usr/bin/nelua-lua: .../x_panic.lua:4: attempt to call a nil value (global 'panic')
stack traceback:
	...
exit=1
```
`panic` is simply not defined in the Lua backend.

### `defer` (Lua backend) — compiler crash
```
/usr/bin/nelua-lua: /usr/lib/nelua/lualib/nelua/visitorcontext.lua:171:
  attempt to call a nil value (local 'visit')
stack traceback:
	.../visitorcontext.lua:171: in function 'nelua.visitorcontext.traverse_node'
	.../emitter.lua:160: in function 'nelua.emitter.add_value'
	...
	.../luagenerator.lua:388: in function 'nelua.luagenerator.generate'
	.../runner.lua:206: in upvalue 'run'
	.../runner.lua:262: in function </.../runner.lua:261>
	[C]: in function 'xpcall'
	.../except.lua:135: in function 'nelua.utils.except.try'
	.../runner.lua:261: in function 'nelua.runner.run'
	.../nelua.lua:4: in main chunk
	[C]: in function 'require'
	[C]: in ?
exit=1
```
The Lua emitter's visitor cannot handle `nkDefer` nodes. This is a compiler
bug, not a runtime one — the program never reaches execution.

---

## 4. Compiler lowering (C backend)

Captured with `/usr/bin/nelua --print-code`.

`error "boom"` →
```c
static NELUA_NORETURN void nelua_error_line_1(nlstring msg);
...
void nelua_error_line_1(nlstring msg) {
  nelua_write_stderr("x_error.nelua:1:7: runtime error: ", 34, false);
  nelua_write_stderr((const char*)msg.data, msg.size, false);
  nelua_write_stderr("\nerror \"boom_error\"\n      ^~~~~~~~~~~~\n", 39, true);
  nelua_abort();
}
...
nelua_error_line_1(((nlstring){(uint8_t*)"boom_error", 10}));
```
Each `error` call site gets its own `nelua_error_line_N` with the source span
baked in as a string literal.

`panic "boom"` →
```c
static NELUA_NORETURN void nelua_panic_string(nlstring s);
...
void nelua_panic_string(nlstring s) {
  if(s.size > 0) {
    nelua_write_stderr((const char*)s.data, s.size, true);
  }
  nelua_abort();
}
```
No source span. `panic()` (no arg) emits `nelua_panic_string` with a zero-size
string, so nothing is printed.

`assert(v, msg)` → `nelua_assert_line_N(cond, msg)` returning the value;
`check(cond, msg)` → the same helper with `void` return. Both:
```c
static int64_t nelua_assert_line_1(int64_t cond, nlstring msg) {
  if(NELUA_UNLIKELY(!true)) {   /* condition folded at compile time when constant */
    nelua_write_stderr("as02.nelua:1:19: runtime error: ", 32, false);
    nelua_write_stderr((const char*)msg.data, msg.size, false);
    nelua_write_stderr("\nlocal x = assert(2+2, \"bad math\")\n                  ^~\n", 56, true);
    nelua_abort();
  }
  return cond;
}
```
With `-P nochecks`, the entire `check(...)` call is stripped from the output.

---

## 5. What is out of scope in 0.2.0-dev

The following do not exist and should **not** be targets for an exceptions
module in a 0.2.0-parity reimplementation:

- **`try`/`catch`/`finally`/`recover`** — not keywords, not parseable.
- **`throw`/`raise`/`perror`** — undeclared symbols.
- **Any exception object or catching mechanism** — `pcall` is undeclared too.
  There is no `xpcall`, no `error` object, no label/type taxonomy.
- **`panic` and `check`** — C-backend-only; the Lua backend has no equivalent.
  Cross-backend parity for these two is impossible by construction.
- **`<close>` variables / `__close` metamethods** — the attribute and the
  `record` type it would attach to do not exist in this build.
- **Guaranteed cleanup on the error path** — `defer` does **not** run when
  `error()`/`panic()` fire. This is a real semantic gap vs. Go/Rust.
- **Dynamic error-message construction** — see §6.

### §6. Surprise: string concatenation is literal-only

`"a" .. "b"` works (two string **literals**), but `local a="a"; local b="b";
a .. b` fails with `in binary operation 'concat': invalid operation between
types 'string' and 'string'`. Same for `a + b`, and for `cstring .. cstring`.
The `..` operator only folds **compile-time string constants**; it is not a
runtime concatenation operator on the `string` type. Consequence for error
messages: you can write `error("x too big: " .. n)` only if `n` is a literal;
building a message from a runtime `string` variable requires the
`stringbuilder` module — which itself is written using Nelu `@record`
syntax that **0.2.0-dev cannot parse**. So in practice, dynamic error
messages in 0.2.0-dev are severely constrained.

Verified:
```
op08.nelua: print("hello " .. "world")   -> "hello world"  (works)
op01.nelua: local a="foo"; local b="bar"; local c = a .. b
            -> error: in binary operation `concat`: invalid operation
               between types 'string' and 'string'
```

---

## 7. What IS supported (the realistic surface)

If a reimplementation targets 0.2.0-dev parity, the safe target is:

**Parse:**
- `defer <block> end` statement (block form only).
- `goto <name>` and `::<name>::` labels.
- The `error`/`panic`/`assert`/`check`/`likely`/`unlikely` builtin names must
  be recognized as globals (they currently parse as plain identifiers and
  are only caught by the analyzer's fallback builtin list).

**Analyze:**
- `error(msg: string): void` — exactly one `string` arg, or zero args.
- `panic(msg: string): void` — C-backend only.
- `assert(v: auto, message: facultative(string))` — returns `v`; falsey
  means `nil` or `false` only.
- `check(cond: boolean, message: facultative(string)): void` — C-backend
  only; omit with `-P nochecks`.
- `defer` block: analyze the body, mark it for reverse-order emission at the
  enclosing scope exit.

**Runtime (C backend):**
- `error` → print `<file>:<line>:<col>: runtime error: <msg>` + source line +
  caret span to stderr, then `abort()`.
- `panic` → print `<msg>` to stderr (if non-empty), then `abort()`.
- `assert`/`check` → same as `error` with the given message (or
  `"assertion failed!"`), `abort()`; `assert` returns its argument.
- `defer` → emit the deferred block in reverse order just before the
  enclosing scope's closing brace / before a `return`.

**Runtime (Lua backend):**
- `error(msg)` → emit a call to Lua's built-in `error()`.
- `assert(v, msg)` → emit Lua's `assert()`.
- `panic`/`check` → **must not be emitted** (they do not exist in the Lua
  runtime); a parity reimplementation should either define them as globals
  in the emitted preamble or reject them with a clear message.
- `defer` → the oracle's Lua emitter is broken here; a reimplementation
  should lower `defer` correctly (e.g. with an `__defer` table and a
  scope-exit hook, or by wrapping the body).

---

## 8. Our compiler's current state (survey of `src/`)

| component | status | note |
|---|---|---|
| `defer` | **implemented** | `src/parser.nim:782` parses `defer <block> end`; `src/analyzer.nim:1220` `analyzeDefer`; `src/cgen.nim:917` pushes onto `deferStack`, emitted in reverse at scope exit (`src/cgen.nim:623-630`). Full pipeline. |
| `error` builtin | **stub** | `src/analyzer.nim:674` lists `"error"` in `builtinNames`, typed as `any`. `src/cgen.nim` has **no** special handling → emits `nelua_error(...)` which does not exist in `src/runtime.c` (only `nelua_print_*` helpers are defined). **Link would fail.** No arg-count or string-arg checking (would accept `error(42)`). |
| `panic` builtin | **missing** | Not in `builtinNames`. Not parseable as a builtin. Not in `src/runtime.c`. |
| `assert` builtin | **stub** | In `builtinNames` as `any`. No codegen, no truthiness semantics. |
| `check` builtin | **missing** | Not in `builtinNames`. No `-P nochecks` handling. |
| `try`/`catch`/`throw`/`finally` | **missing** | No AST node, no parser rule, no keyword. |
| `pcall` | **listed but unimplemented** | In `builtinNames` but no codegen/runtime. |

**Gap summary for exceptions:** `defer` is done. The panic builtins are
recognized as symbols but have no real implementation — no arg validation,
no codegen, no runtime helpers, no `-P nochecks` omission, no
backend-specificity. A real implementation needs: (a) analyzer typing for
`error(string?)`, `panic(string?)`, `assert(any, string?)`,
`check(boolean, string?)`; (b) C codegen emitting the source-span-baking
`nelua_error_line_N` / `nelua_panic_string` / `nelua_assert_line_N`
helpers plus `abort()`; (c) Lua codegen emitting Lua `error()`/`assert()`
and either defining or rejecting `panic`/`check`; (d) `-P nochecks` stripping
of `check`.

---

## 9. Spec for a 0.2.0-parity exceptions implementation

**Parity bar:** match the oracle's behavior exactly for the constructs it
supports (`error`, `panic`, `assert`, `check`, `defer`). Do **not** invent
`try`/`catch`/`throw` — those are §11 "beyond" features and the oracle
rejects them, so adding them would be a **beyond-oracle** extension (mark it
as such in the design doc; do not claim parity).

1. `error(msg: string): void` — zero or one `string` arg. Never returns.
   C: write `<loc>: runtime error: <msg>` + source line + caret to stderr,
   `abort()`. Lua: call Lua `error(msg)`.
2. `panic(msg: string): void` — C-backend only. Write `<msg>` (if any) to
   stderr, `abort()`. **Not available on the Lua backend** — either reject
   with a diagnostic or provide a Lua-side definition.
3. `assert(v: auto, message: facultative(string))` — if `v` is falsey
   (`nil` or `false` only — `0` is truthy), error with `message` or
   `"assertion failed!"`; otherwise return `v`.
4. `check(cond: boolean, message: facultative(string)): void` — C-backend
   only, same error behavior as `assert` but void; **omitted entirely when
   `-P nochecks` is set**.
5. `defer <block> end` — run the block in reverse order at the enclosing
   scope exit, before any `return`. **Do not run on `error()`/`panic()`**
   (match the oracle's gap, or flag as a known deviation).
6. `goto`/`::label::` — already supported by our parser? (verify; not the
   focus of this doc).

**Beyond-oracle (do not claim parity):** `try`/`catch`/`finally`/`recover`,
exception objects with labels, catching, `__close` on error paths. The oracle
explicitly documents that `error` "may be changed to an exception being
thrown" in the future (`docs/pages/libraries.md:69-71`).

---

## 10. Reproducing

Probe files live in `tmp/oracle_probe/` (throwaway). Run with:

```
/usr/bin/nelua <file>                 # C backend
/usr/bin/nelua -g lua <file>         # Lua backend
/usr/bin/nelua --print-code <file>   # see the C lowering
/usr/bin/nelua -P nochecks <file>    # strip `check`
```