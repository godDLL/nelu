# examples/www — curated comparison corpus

Permanent comparison library for the clean-room Nelua reimplementation.
Every program here was compiled and run through BOTH compilers and the
result recorded by hand (not inherited from the sweep):

- **oracle** = `/usr/bin/nelua` (upstream 0.2.0-dev)
- **ours**   = `tmp/nelua` (built from `src/main.nim`, `-d:release`)

Both were invoked with `-o <bin>`; the resulting binaries were run and
stdout + exit code captured. Our compiler's full compile stderr is quoted
where it matters. `tmp/nelua` was rebuilt from `src/main.nim` immediately
before this batch (mtime newer than every `src/*.nim`).

Verdicts below were all re-verified by this pass; **every one agrees with
the sweep in `tmp/corpus_candidates.md`** — no candidate's verdict changed.

## Table

| program | feature covered | verdict |
|---------|-----------------|---------|
| `hello_world` | minimal print anchor | MATCH |
| `fibonacci_rec` | recursive function, integer | MATCH |
| `builtins` | `print`, `check`, `assert`, `nilptr` | MATCH |
| `ackermann` | deep integer recursion, `assert`, `==` | MATCH |
| `arith` | `// % << >> ~ & \| ^`, integer overflow wrap | MATCH |
| `bitops` | hex literals, `& \| ~ << >>`, `-1 << 2` | MATCH |
| `switch` | `switch`/`case`/`else`, comma-separated cases | MATCH |
| `defer` | `defer` reverse order across `return`, nested `do` | MATCH |
| `floats` | `+ - * / ^` on `number`, `0.1+0.2` | MATCH |
| `flow` | `if/elseif/else`, `while`, numeric `for`, `break`/`continue` | MATCH |
| `forfunc` | `for` over computed sum, nested `for`, recursion | MATCH |
| `multiret` | multi-return `(a,b)`, multi-assignment, trailing arg | MATCH |
| `precedence` | `+ - * / ^`, parens, `and`/`or`/`not` | MATCH |
| `string_len` | `#` length of string literals | MATCH |
| `escapes` | string escape sequences `\t\n` | DIFF (us wrong) |
| `floor_div` | `//` semantics on negatives | DIFF (us wrong) |
| `lshift` | large left shift `1 << 60` | DIFF (us wrong) |
| `nilptr_print` | `print(nilptr)` format | DIFF (us wrong) |
| `scope_shadow` | `local` shadowing inside `do ... end` | DIFF (us wrong) |
| `stepped_for` | negative-step `for j = 4, 1, -1` | DIFF (us wrong) |
| `tetrix_rotation` | `@record{}`, `[4][4]byte`, colon methods, `$copy` | FAIL (us) |
| `tetrix` | RIV fantasy-console game (`require 'riv'`) | external — needs SDK |
| `seqtoy` | RIV step sequencer (`require 'riv'`) | external — needs SDK |
| `seqtoy_enum` | bare `@enum{}` (no primitive), `[12]string`, `@record{int8}`, record method, single-record literal init | MATCH |

**24 entries: 15 MATCH, 6 DIFF, 1 FAIL(us), 2 external.**

The 5 FAIL(us) candidates are documented in [Rejected](#rejected) below; the
1 kept FAIL(us) program (`tetrix_rotation`) is documented in
[FAIL(us) — kept regression material](#failus-kept-regression-material)
above.

Running order matters for readability: MATCHes first (regression floor),
then DIFFs (known-broken, each a one-line fix target in `src/`).

---

## MATCH programs

### `hello_world`
```lua
print 'hello world'
```
Covers: minimal print anchor — always-MATCH sanity check for the harness.

- oracle: exit 0, stdout `hello world`
- ours: exit 0, stdout `hello world`
- **MATCH**

Pins down the trivial but load-bearing path: a program must compile, link,
and emit exactly one string literal with no surrounding whitespace.

### `fibonacci_rec`
```lua
do
  local function fibonacci(n: integer): integer
    if n <= 2 then return 1 end
    return fibonacci(n - 1) + fibonacci(n - 2)
  end
  print(fibonacci(10))
end
```
Covers: recursive `local function`, integer parameters, `if`/`return`,
`-` on integers.

- oracle: exit 0, stdout `55`
- ours: exit 0, stdout `55`
- **MATCH**

Pins down function-call ABI for integer arguments and return values, and
recursive call emission. `fibonacci(10)` = 55.

### `builtins`
```lua
do print('hello', 'world') end
do check(true); check(true, 'ok') end
do assert(true); assert(true, 'test') end
do assert(not nilptr) end
print 'builtins OK!'
```
Covers: `print` with multiple args, `check`, `assert`, `nilptr`, `not`.

- oracle: exit 0, stdout `hello\tworld\nbuiltins OK!`
- ours: exit 0, stdout `hello\tworld\nbuiltins OK!`
- **MATCH**

Pins down the builtin runtime functions and multi-argument `print` (tab
separation). Note `assert(not nilptr)` passing means `nilptr` is falsy in
both compilers — only its *printed* representation differs (see
`nilptr_print`).

### `ackermann`
```lua
local function ack(m: integer, n: integer): integer
  if m == 0 then return n + 1 end
  if n == 0 then return ack(m - 1, 1) end
  return ack(m - 1, ack(m, n - 1))
end
local res = ack(3,10)
print(res)
assert(res == 8189)
```
Covers: deep integer recursion, `==`, nested call as an argument.

- oracle: exit 0, stdout `8189`
- ours: exit 0, stdout `8189`
- **MATCH**

Genuine upstream benchmark (edubart/nelua-benchmarks). `ack(3,10)` = 8189
is a classic recursion stress test; the `assert` doubles as a runtime
integer-`==` check.

### `arith`
```lua
local a: integer = 7 // 2
local b: integer = 7 % 3
local c: integer = -7 % 3
local d: integer = 1 << 4
local e: integer = 256 >> 2
local f: integer = ~0
local g: integer = 3 & 7
local h: integer = 3 | 5
local i: integer = 3 ~ 7
local j: integer = 0 - 1
local big: integer = 1152921504606846976
local wrap: integer = big + big
print(a, b, c, d, e, f, g, h, i, j, wrap)
```
Covers: `// % << >> ~ & | ^`, integer overflow wrap.

- oracle: exit 0, stdout `3\t1\t2\t16\t64\t-1\t3\t7\t4\t-1\t2305843009213693952`
- ours: exit 0, stdout `3\t1\t2\t16\t64\t-1\t3\t7\t4\t-1\t2305843009213693952`
- **MATCH**

Pins down the full integer operator surface **except** the negative-`//`
case (see `floor_div`) and large left shifts (see `lshift`).
`7 // 2 = 3`, `~0 = -1`, `3 ~ 7 = 4` (bitwise XOR), `big + big` wraps to
`2^61`. Deliberately includes `1 << 4` (small shift, works) next to the
`1 << 60` probe in `lshift` so the boundary between working and broken
shifts is visible across two programs.

### `bitops`
```lua
local x: integer = 0xFF
local y: integer = 0x0F
print(x & y, x | y, x ~ y, ~x)
print(x << 4, x >> 4)
local neg: integer = -1
print(neg << 2)
```
Covers: hex literals, `& | ~ << >>`, negative shift amount.

- oracle: exit 0, stdout `15\t255\t240\t-256\n4080\t15\n-4`
- ours: exit 0, stdout `15\t255\t240\t-256\n4080\t15\n-4`
- **MATCH**

`0xFF & 0x0F = 15`, `0xFF | 0x0F = 255`, `~0xFF = -256`, `-1 << 2 = -4`.
Confirms hex literal parsing and that sign extension on shifts matches
the oracle.

### `switch`
```lua
local function classify(n: integer): integer
  switch n
  case 1 then return 10
  case 2, 3 then return 20
  case 4, 5, 6 then return 30
  else return 0
  end
end
print(classify(1), classify(2), classify(5), classify(9))
```
Covers: `switch`/`case`/`else`, comma-separated case values.

- oracle: exit 0, stdout `10\t20\t30\t0`
- ours: exit 0, stdout `10\t20\t30\t0`
- **MATCH**

Pins down switch dispatch including multi-value `case 2, 3 then` and the
`else` fallback.

### `defer`
```lua
local function f()
  print('body')
  defer print('d2') end
  defer print('d1') end
  return
end
f()

local function g()
  print('g-start')
  defer print('g-end') end
  do
    defer print('g-inner') end
    print('g-body')
  end
  return
end
g()
```
Covers: `defer` reverse-order execution across `return` and nested `do`.

- oracle: exit 0, stdout `body\nd1\nd2\ng-start\ng-body\ng-inner\ng-end`
- ours: exit 0, stdout `body\nd1\nd2\ng-start\ng-body\ng-inner\ng-end`
- **MATCH**

Pins down LIFO defer ordering: `d1` fires before `d2`, and the nested `do`
block's `g-inner` defer fires before the enclosing function's `g-end`
defer, even though `g-end` was registered first. The only defer coverage
in the corpus.

### `floats`
```lua
local x: number = 1.5 + 2.5
local y: number = 10.0 / 4.0
local z: number = 2.0 ^ 10.0
local w: number = -3.0
local u: number = x * y - z
local q: number = 1.0 / 3.0
local p: number = 0.1 + 0.2
print(x, y, z, w, u, q, p)
```
Covers: `+ - * / ^` on `number`, `0.1+0.2`.

- oracle: exit 0, stdout `4.0\t2.5\t1024.0\t-3.0\t-1014.0\t0.33333333333333\t0.3`
- ours: exit 0, stdout `4.0\t2.5\t1024.0\t-3.0\t-1014.0\t0.33333333333333\t0.3`
- **MATCH**

Pins down the `number` (double) arithmetic surface and the number formatter.
Both compilers print `0.1+0.2` as `0.3` and `1.0/3.0` as
`0.33333333333333` (14 digits) — matching formatting is itself a
regression point.

### `flow`
```lua
local x = 5
if x > 0 then print('pos')
elseif x == 0 then print('zero')
else print('neg')
end
local i = 0
while i < 3 do i = i + 1 end
print('while', i)
local s = 0
for j = 1, 5 do s = s + j end
print('for15', s)
for j = 0, <4 do print('ex', j) end
local sum = 0
for j = 1, 10 do
  if j == 4 then continue end
  if j > 8 then break end
  sum = sum + j
end
print('bc', sum)
```
Covers: `if/elseif/else`, `while`, numeric `for` (inclusive and exclusive
`<`), `break`/`continue`.

- oracle: exit 0, stdout `pos\nwhile\t3\nfor15\t15\nex\t0\nex\t1\nex\t2\nex\t3\nbc\t32`
- ours: exit 0, stdout `pos\nwhile\t3\nfor15\t15\nex\t0\nex\t1\nex\t2\nex\t3\nbc\t32`
- **MATCH**

Widest single-program control-flow coverage. `for j = 0, <4` is the
exclusive-upper-bound form; `bc 32` = 1+2+3+5+6+7+8 (4 skipped, 9/10
cut by break).

### `forfunc`
```lua
local function square(n: integer): integer
  return n * n
end
local s = 0
for i = 1, 10 do s = s + square(i) end
print(s)

local t = 0
for i = 1, 3 do
  for j = 1, 3 do t = t + i * j end
end
print(t)

local function fib(n: integer): integer
  if n <= 1 then return n end
  return fib(n - 1) + fib(n - 2)
end
print(fib(12))
```
Covers: `for` over a computed sum, nested `for`, recursion.

- oracle: exit 0, stdout `385\n36\n144`
- ours: exit 0, stdout `385\n36\n144`
- **MATCH**

`sum of squares 1..10 = 385`, `sum i*j for i,j in 1..3 = 36`, `fib(12) = 144`.
Confirms nested loop scoping and function calls inside loop bodies.

### `multiret`
```lua
local function pair(a: integer, b: integer): (integer, integer)
  return a, b
end
local x, y = pair(3, 4)
print(x, y)

local function first(a: integer, b: integer): integer
  return a
end
local p, q = first(7, 8), 9
print(p, q)
```
Covers: multi-return `(a,b)`, multi-assignment, trailing arg `9`.

- oracle: exit 0, stdout `3\t4\n7\t9`
- ours: exit 0, stdout `3\t4\n7\t9`
- **MATCH**

Pins down multiple-return-value ABI and destructuring assignment, plus
the mixed `func(...), literal` expression form.

### `precedence`
```lua
local a = 2 + 3 * 4
local b = (2 + 3) * 4
local c = 10 - 3 - 2
local d = 100 / 5 / 2
local e = 2 ^ 3 ^ 2
local f = true or false
local g = true and false
local h = not true
local i = (1 < 2) and (3 < 4)
local j = false and (5 < 6)
print(a, b, c, d, e, f, g, h, i, j)
```
Covers: `+ - * / ^`, parentheses, `and`/`or`/`not` on booleans.

- oracle: exit 0, stdout `14\t20\t5\t10.0\t512.0\ttrue\tfalse\tfalse\ttrue\tfalse`
- ours: exit 0, stdout `14\t20\t5\t10.0\t512.0\ttrue\tfalse\tfalse\ttrue\tfalse`
- **MATCH**

Pins down operator precedence and associativity: `2 + 3 * 4 = 14`,
`(2+3)*4 = 20`, `2 ^ 3 ^ 2 = 512` (right-associative exponentiation),
boolean short-circuit `false and (5 < 6) = false` without evaluating the
comparison.

### `string_len`
```lua
local a = 'hello'
local b = 'world'
print(#a, #b)
```
Covers: `#` length of string literals.

- oracle: exit 0, stdout `5\t5`
- ours: exit 0, stdout `5\t5`
- **MATCH**

Pins down the `#` length operator on string literals. Note that the
*escape-processing* half of this is what breaks in `escapes` — this program
only uses escape-free literals, so it passes while the escape probe fails.

### `seqtoy_enum`
```lua
local Notes: [12]string = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local EditState = @enum{
  NOTE_FOCUS = 0,
  NOTE_TOGGLE,
  NOTE_SLIDE,
  NOTE_SHIFT,
  NOTE_VOLUME,
  PAGE_FOCUS,
  TRACK_FOCUS,
}

local Note = @record{
  periods: int8,
  volume: int8,
  slide: int8,
}

function Note:describe(): string
  if self.periods == 0 then return 'silent' end
  if self.periods < 4 then return 'short'
  elseif self.periods < 8 then return 'medium'
  else return 'long'
  end
end

local n: Note = { periods=4, volume=5, slide=1 }
print(Notes[1], n:describe())

local toggle: EditState = EditState.NOTE_TOGGLE
print(toggle)
```
Covers: bare `@enum{}` with **no primitive** (the enum acceptance target),
`[12]string` fixed array, `@record` with typed `int8` fields, a record
method with `if`/`elseif`, a single-record literal init, enum value
assignment, and array indexing.

- oracle: exit 0, stdout `C#\tmedium\n1`
- ours: exit 0, stdout `C#\tmedium\n1`
- **MATCH**

Extracted from `examples/www/seqtoy/seqtoy.nelua`. This is the only corpus
entry that exercises a bare `@enum{}` — the oracle accepts `@enum{...}` with
no `(integer)`/`(uint32)` base, and so does ours. Note the array-of-record
form (`local notes: [4]Note = { {...}, {...}, ... }`) that seqtoy actually
uses does **not** match yet: ours emits malformed C for nested init lists,
the same defect filed in [tetrix-rotation-gaps](../plan/tetrix-rotation-gaps.md).
This program sidesteps that by using a single-record literal, so it isolates
the bare-enum feature cleanly.

---

## DIFF programs (our compiler wrong; oracle right)

Each of these pins a specific, already-known compiler gap. They are kept
as regression material: a fix to `src/` should flip the verdict to MATCH,
and until it does these are expected to DIFF.

### `escapes`
```lua
local e = 'a\tb\nc'
print(#e)
```
- oracle: exit 0, stdout `5`
- ours: exit 0, stdout `7`
- **DIFF — oracle is right**

What you see: the literal `'a\tb\nc'` is 5 characters — `a`, TAB, `b`,
newline, `c`. Our compiler prints `7`, i.e. it counted the backslashes
literally (`a`, `\`, `t`, `b`, `\`, `n`, `c`). Our lexer is not processing
`\t` / `\n` escape sequences inside string literals; it passes the
backslash and the following character through untouched. Fix target:
string-literal lexing in `src/lexer.nim`.

### `floor_div`
```lua
local d: integer = -7 // 2
print(d)
```
- oracle: exit 0, stdout `-4`
- ours: exit 0, stdout `-3`
- **DIFF — oracle is right**

What you see: `//` is floor division (rounds toward negative infinity), so
`-7 // 2 = -4`. Our compiler truncates toward zero, giving `-3`. This is
the classic floor-vs-trunc gap. Note `arith` passes because its only `//`
use is `7 // 2` (positive operands, where floor and trunc agree) — this
program is what isolates the negative case.

### `lshift`
```lua
local big: integer = 1 << 60
print(big, big >> 60)
```
- oracle: exit 0, stdout `1152921504606846976\t1`
- ours: exit 0, stdout `0\t0`
- **DIFF — oracle is right**

What you see: `1 << 60 = 1152921504606846976` (2^60) and `>> 60` brings it
back to `1`. Our compiler emits `0` for both — the large left shift
collapses to zero instead of producing the shifted value. Contrast with
`arith`, whose `1 << 4` (small shift) is correct; the break point between
working and collapsing shifts is somewhere between 4 and 60. Fix target:
left-shift codegen for wide operands in `src/cgen.nim`.

### `nilptr_print`
```lua
print(nilptr)
```
- oracle: exit 0, stdout `(null)`
- ours: exit 0, stdout `nil`
- **DIFF — oracle is right**

What you see: the oracle prints `nilptr` as `(null)`, matching the
upstream formatter. Our compiler prints the literal text `nil`. This is
a print-format gap, not a semantic one — `nilptr` is still falsy in both
compilers (see `builtins`, `assert(not nilptr)`). Fix target: nilptr
rendering in the print/runtime path.

### `scope_shadow`
```lua
local x = 1
do
  local x = 2
  print(x)
end
print(x)
```
- oracle: exit 0, stdout `2\n1`
- ours: exit 0, stdout `2\n2`
- **DIFF — oracle is right**

What you see: inside the `do` block the inner `local x = 2` shadows and
prints `2`. After the block, the oracle still sees the outer `x = 1` and
prints `1` — the block-scoped `local` does not leak. Our compiler prints
`2` again, meaning the inner `local x` overwrote / leaked into the outer
scope. Fix target: `do`-block scope handling and `local` declaration
emission in `src/`.

### `stepped_for`
```lua
for j = 4, 1, -1 do
  print('step', j)
end
```
- oracle: exit 0, stdout `step\t4\nstep\t3\nstep\t2\nstep\t1`
- ours: exit 0, stdout ``(empty)
- **DIFF — oracle is right**

What you see: a negative-step `for` should count down 4,3,2,1. Our
compiler emits no output at all — the loop body never executes. Notably
this is a runtime semantic gap, not a compile error: our stderr is empty,
the program compiles and exits 0, it simply produces no lines. Fix target:
step direction / loop-bound evaluation for `for` with a negative step in
`src/`.

---

## FAIL(us) — kept regression material

### `tetrix_rotation`
```lua
local Piece = @record{
  x: integer, y: integer, size: integer, layout: [4][4]byte,
}
local PIECES: [2]Piece = {
  { size=2, layout={{1,1,0,0},{1,1,0,0},{0,0,0,0},{0,0,0,0}} },
  { size=3, layout={{0,1,0,0},{1,1,1,0},{0,0,0,0},{0,0,0,0}} },
}
function Piece:rotate_left()
  local layout = self.layout
  for i=0,self.size-1 do for j=0,self.size-1 do
    self.layout[i][j] = layout[j][self.size-1-i] end end
end
function Piece:rotate_right()
  local layout = self.layout
  for i=0,self.size-1 do for j=0,self.size-1 do
    self.layout[j][self.size-1-i] = layout[i][j] end end
end
function Piece:dump()
  for i=0,self.size-1 do for j=0,self.size-1 do
    print(self.layout[i][j]) end end
  print('---') end
local p = PIECES[1]
p:dump(); p:rotate_left(); p:dump(); p:rotate_right(); p:dump()
```
Extracted from `tetrix/tetrix.nelua` — the piece-rotation core, stripped of
the RIV SDK so it runs standalone.

- oracle: exit 0, three rotation matrices (original / left / right)
- ours: **C compile fails**
- **FAIL — oracle is right**

What you see: our compiler now *parses* the whole thing (that is the
record/enum milestone landing), but the emitted C has two defects, both
in `src/cgen.nim`:

1. `local layout = self.layout` where `layout` is an array type emits
   `tmp_..._layout = self->layout;` — assignment to expression with array
   type. The oracle emits `memcpy`.
2. `local PIECES: [2]Piece = { {...}, {...} }` emits a malformed compound
   literal whose nested field initialisers are placeholder comments:
   `(struct Piece[2]){/*initlist*/, /*initlist*/}`.

Both are tracked in `plan/tetrix-rotation-gaps.md`. Until they land this is
expected to FAIL; a fix to array-copy / nested-init codegen flips it to MATCH.

## External RIV projects (not standalone-runnable)

These two live under `examples/www/<project>/` as whole upstream projects.
They are recorded here so future sweeps do not re-add them as standalone
corpus candidates: both `require 'riv'` (the RIV fantasy-console SDK), which
is not installed in this tree, so neither compiles under either compiler
without the SDK. They are source for *snippet extraction*, not corpus entries.

- **`tetrix`** — edubart/tetrix, a RIV Tetris. Features exercised:
  `## pragma{nogc,noerrorloc}`, `global NAME <comptime>`, `@record{}` with
  nested records/arrays (`layout: [4][4]byte`, `PIECES: [7]Piece`,
  `cells: [VERT_CELLS][HORZ_CELLS]Color`), `@byte` type alias, colon methods,
  `$copy`, `cstring`, `//` floor div, `repeat/until`, `mipairs`,
  `riv_*` external C functions. Source of `tetrix_rotation`.
- **`seqtoy`** — edubart/seqtoy, a RIV step sequencer (+ `instruments.nelua`).
  Features: `## pragma{nogc,noerrorloc}`, `require 'riv'/'math'/'instruments'/
  'iterators'`, `local NAME <comptime>`, **bare** `@enum{ NOTE_FOCUS=0,
  NOTE_TOGGLE, ... }` (no `(integer)` underlying), `[12]string` array,
  `global @record{}`, colon methods, `mipairs`, `continue`, `float32` fields,
  `elseif`. Notable: it is the only example using a bare `@enum{}`, so it is
  the acceptance target for the enum-without-primitive case.

## Rejected

These candidates are **not** in the library (no copy under
`examples/www/`), but are documented here so a future sweep does not
re-add them blindly. All five are FAIL(us): the oracle compiles and runs
them cleanly, our compiler does not. All verdicts re-verified this pass,
agreeing with the sweep.

| candidate | oracle stdout | our failure | root cause |
|-----------|---------------|-------------|------------|
| `gap_func_local` | `5` | C compile error: `x` undeclared | `local` inside a function body is not emitted in the C output |
| `gap_string_eq` | `true` | C compile error: invalid `==` on `nlstring` | runtime `string` `==` fails to typecheck in codegen |
| `gap_tdiv` | `3` | parse error: unexpected token | `///` truncation-division token is not lexed |
| `gap_repeat` | `3` | SIGSEGV (exit 139) in our compiler | `repeat ... until` segfaults the compiler |
| `repo_record_shapes` | naive example => ... | parse error: expected type after `@` | `@enum`/`@record`/`@pointer` not parsed (queued milestone) |

Details:

- **`gap_func_local`** — `local x: integer = a + 1` inside a function
  body. Our C output uses the variable but never declares it:
  `‘…_x’ undeclared (first use in this function)`. The oracle prints `5`.
- **`gap_string_eq`** — `print(p == q)` with two runtime `string` values.
  Our C output emits a bare `==` between two `nlstring` values:
  `invalid operands to binary == (have ‘nlstring’ and ‘nlstring’)`. The
  oracle prints `true`.
- **`gap_tdiv`** — `7 /// 2`. Our lexer hits `///` as an unexpected token
  at column 24 and aborts the parse. The oracle prints `3`.
- **`gap_repeat`** — `repeat ... until k >= 3`. Our compiler dies with
  `SIGSEGV: Illegal storage access` before producing any output. The
  oracle prints `3`.
- **`repo_record_shapes`** — the naive `@enum`/`@record` inheritance
  example from upstream `examples/record_inheretance.nelua`. Our parser
  rejects `@enum(integer)` with `expected type after ‘@’`. Records and
  enums are a queued milestone, so nothing record-shaped can land until
  then. Oracle output:
  `naive example =>\n      rectangle area is\t4.0\n         circle area is\t3.14\n   circle shape area is\t4.0\nrectangle shape area is\t3.14`.

## Deliberately not wired into any gate

These programs live only under `examples/www/`. The gate scripts
(`cmp.py`, `regress.py`, `examples_parity.py`) and the corpora they read
(`tmp/corpus_nelua/`, `tmp/m2_corpus/`) were **not** modified. If a kept
program should be wired into a gate, that is a separate decision to be
made by the owner of the gate scripts — this pass only curates the
library.