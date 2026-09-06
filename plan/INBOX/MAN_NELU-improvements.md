# MAN_NELU-improvements: Structured improvement proposals for Nelu 0.2.1

Written after walking the whole language surface, stdlib, and CLI end-to-end to produce
`MAN_NELU.html`. Ordered by **value-to-effort**. Each proposal has a concrete "What",
a "Where it hurts now" with a Nelu user's example, a "Nelu vs oracle framing", a
"Suggested shape", and an "Effort/complexity" signal.

**Grounding legend:**
- *Grounded* = I verified it by reading the tree source or by compiling/running a probe
  in `tmp/` on a fresh build of committed HEAD `cbd542d`.
- *Speculative* = my opinion from walking the surface, not verified against a probe.

**The two elephants in the room (read first).**
Proposals 1 and 2 are not "nice-to-haves". On the current tree **no non-trivial program
compiles**. Everything below assumes those are being fixed; proposals 3+ are ordered on
the assumption that the compiler is healthy.

---

## 1. Fix record-literal lowering (cgen) — *DONE 2026-09-06*

- **What.** Every record-literal form emits C using an empty `struct nlrec0` instead of
  the record's own type tag. `(@Vec2){ x = 3.0, y = 4.0 }` becomes
  `(struct nlrec0){.x = 3.0, .y = 4.0}`, and gcc rejects it:
  `'struct nlrec0' has no member named 'x'`. This is systematic — named-field literals,
  ordered-field literals, and the bare `record{...}` form all mis-lower (the bare form
  produces a different but equally broken `declared void` error).
- **Where it hurts now.** It is the single largest blocker. Records are the fundamental
  composite type; `@record` is how you build structs, the C `FILE` opaque record,
  `os.timedesc`, the allocator types, and every stdlib container. Nothing that touches a
  record literal compiles. Verified probes: `tmp/probe_core.nelua`,
  `tmp/probe_rec2.nelua`, `tmp/probe_rec3.nelua`, `tmp/probe_rec4.nelua` — all fail at
  the C compile step with the `nlrec0` error.
- **Nelu vs oracle framing.** This is **parity** (the oracle 0.2.0-dev emits correct C
  for these), and it is a Nelu *regression*, not a deliberate divergence. The commit that
  claims "record/union/enum types" landed (`cbd542d`) does not actually produce working
  record literals.
- **Status.** **CLOSED.** The bare constructor form `T{...}` was already routed through
  the A5 constructor path. The remaining gap was the cast form `(@T){...}`: analyzer.nim
  now analyzes the initlist against the cast target and flags the call as a constructor
  (so cgen emits `((struct <tag>){ ... })`), and cgen.nim emits the `union` keyword for
  union targets instead of always `struct`. Verified: named, mixed-order, union, and bare
  forms all MATCH the oracle. See `plan/DONE/typed-record-literal-cast.md`.
- **Suggested shape.** In `src/cgen.nim`, the record-literal emitter must use the same
  type-tag name the record declaration emits (the `typedef struct <name> { ... } <name>;`
  at the top of the generated C), not a fresh `nlrec0`. One probe per literal shape
  (named, ordered, bare `record`) should be added to the corpus and must MATCH the oracle
  byte-for-byte.
- **Effort/complexity.** **Medium.** It is one emitter site, but it is on the critical
  path — everything waits on it. Triage first.

## 2. Make the stdlib analyze end-to-end — *Grounded*

- **What.** The runtime stdlib in `lib/` does not analyze under the current compiler.
  Four independent root causes, all verified:
  1. `lib/hash.nelua:73:51: error: unexpected token` — affects most modules
     transitively (hash is required by hashmap, which is required by most containers).
  2. `lib/iterators.nelua` — preprocessor error: `global 'impl_ipairs_next' is not
     callable (a nil value)`. A Nelua `function` is referenced from a `##` block before
     the preprocessor can see it.
  3. Parse errors in `lib/traits.nelua`, `lib/builtins.nelua`,
     `lib/errorhandling.nelua`, `lib/detail/xoshiro256.nelua`.
  4. Consequence: `require 'C.stdio'` and every `require 'X'` fail; `require 'coroutine'`
     cascades through the same broken chain.
- **Where it hurts now.** A Nelu user cannot `require` anything. The entire documented
  stdlib surface (section 10 of the manual) is unreachable. The C-interop payoff
  (section 9) is unreachable. The `coroutine` module — the flagship Nelu extension — is
  unreachable.
- **Nelu vs oracle framing.** **Parity** for the analyzer/parser bugs (the oracle's stdlib
  compiles); the `coroutine` module is **Nelu ext** and its lowering is separately not
  wired (NELU-2K section 1.1), so fixing #1-3 is a prerequisite for it, not the whole story.
- **Suggested shape.** Fix the four root causes in `src/parser.nim`/`src/preprocessor.nim`/
  `src/sema.nim`, then add a smoke test: `require` each of the 21 runtime modules and a
  trivial `C.stdio` call, all must compile and run. This is the gate that decides whether
  the language is usable at all.
- **Effort/complexity.** **Medium.** Four discrete bugs; the preprocessor one
  (`impl_ipairs_next`) is the interesting one — it is a real ordering/visibility gap in
  how `##` blocks resolve Nelua symbols.

## 3. Tables (C backend) — *Grounded design, queued implementation*

- **What.** The oracle rejects tables; Nelu supports them (NELU-2K section 2, queued).
  `lib/table.nelua` is a stub that `static_error`s "tables are not implement yet", with the
  Lua `table.*` API listed as comments.
- **Where it hurts now.** Any Nelu user coming from Lua hits a wall: there is no dynamic
  map type. `hashmap` is the replacement but it is a typed container with a heavy
  constructor signature (`hashmap(K, V, HashFunc, Allocator)`) and no Lua-flavored sugar.
  Porting Lua code that uses `t[k] = v` is awkward at best.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle rejects; Nelu designs
  support). Not parity.
- **Suggested shape.** A `table` type that is a thin wrapper over `hashmap` with Lua
  semantics: 1-indexed-or-string-keyed, auto-growing, `#`, `pairs`, `ipairs`,
  `table.insert/remove/sort/concat/move`. Could reuse `hashmap`'s backing store. The
  queued spec (`plan/table_oracle-behavior-design.md`) already pins the oracle's rejection
  behaviour, so this is "diverge from a known baseline".
- **Effort/complexity.** **Medium-Large** if built on `hashmap`; **Small** if it is a
  new simple open-addressing map. Depends on #1 (records) landing first.

## 4. Full exceptions: `try`/`catch`/`finally` — *Grounded design, queued*

- **What.** Queued (NELU-2K section 2). The parity-level primitives already exist:
  `panic`/`error` (runtime abort), `defer` (Go-style scope-exit), `<close>`
  (`__close` metamethod, Rust-`Drop`-style). What is missing is structured handling.
- **Where it hurts now.** The only error signal is abort. There is no `pcall`-free way to
  recover from a failure in a library call; `errorhandling` provides `pcall`/`xpcall`
  (Nelu ext — the oracle rejects `pcall`), but they are the Lua model, not the
  `try/catch/finally` model, and they require `alwayspoly` specialisation. The
  `except_spec.lua` in `spec/` suggests the test suite already anticipates this.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle has no `try`/`catch`;
  its `except_spec` is about the C generator, not a try/catch surface). The
  `plan/exceptions_oracle-behavior-design.md` spec frames parity as "panic builtins +
  `defer`" and beyond as "`try`/`catch`".
- **Suggested shape.** `try ... catch [as e] ... [finally ...] end`, lowering to C via
  `setjmp`/`longjmp` or a status-flag convention, with the existing `panic` as the
  throw. Must interoperate with `<close>` (a `__close` in a `try` body runs on both
  normal exit and `catch`).
- **Effort/complexity.** **Large** if using `setjmp`/`longjmp` (interacts with the GC
  conservative stack scan and with coroutine suspension); **Medium** if using a
  return-status convention (no unwinding, but no `finally`-on-exception semantics either).
  The status convention is the pragmatic first cut.

## 5. `match`/`cond` pattern matching — *Grounded design, queued*

- **What.** Queued (NELU-2K section 2). Parity-level building blocks that *do* exist:
  `switch`/`case`/`else` (the `fallthrough` keyword landed in `584f0c2` as a node, not a
  value). `match`/`cond`/destructuring are the beyond-oracle sugar on top.
- **Where it hurts now.** Multi-way dispatch on a value or type is verbose: nested
  `if/elseif`, or `switch` with C-style fallthrough semantics that do not compose with
  Nelua's value semantics. Pattern matching against record shapes, optionals, and
  variants is not expressible at all.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle**. `plan/pattern_matching_oracle-behavior-design.md`
  pins the oracle's `switch`/`case`/`else` behaviour as the parity floor.
- **Suggested shape.** `match x do case { a, b } then ... case [1, 2, 3] then ... else ...
  end`, plus `cond` for boolean conditions. Destructuring binds new `local`s. Type
  patterns reuse the `concept`/`facultative` machinery from the preprocessor.
- **Effort/complexity.** **Medium.** The parser work is moderate; the hard part is
  making pattern expressions evaluate at compile time via the preprocessor (which is the
  right place for them, since patterns are a compile-time concern in a statically-typed
  language).

## 6. Generators / `yield`-based iterators — *Grounded design, queued*

- **What.** Queued (NELU-2K section 2). The oracle has no `yield`; the Nelu `coroutine`
  module (section 1.1) is the suspension primitive, but its C lowering is not yet wired
  into `cgen.nim`, and `for ... in` over a generator is not implemented.
- **Where it hurts now.** `iterators.nelua` provides `next`/`pairs`/`ipairs` and the
  `__next`/`__pairs` metamethod protocol, so container iteration works — but you cannot
  write a *custom* lazy sequence (e.g. `for x in range(0, 1000000) do`). Every lazy
  computation is materialised into a `sequence`/`vector` first. The `luagenerator_spec.lua`
  in `spec/` anticipates this.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle has no `yield` and no
  generator type).
- **Suggested shape.** A `generator(T)` handle (built on the `coroutine`/minicoro
  primitive) plus `for x in gen do` syntax sugar. Lower to a C state machine. The
  `coroutine` module's `push`/`pop` (compile-time-known types) are the value-passing
  mechanism to build on.
- **Effort/complexity.** **Large.** Depends on #1 (records) and on the `coroutine`
  lowering being wired. This is the furthest-out item in the queue.

## 7. Stdlib richness gaps — *Grounded*

These come from comparing `lib/` against what a real Nelu program needs.

### 7a. `string` has no `split`, and `find`/`match` are not Lua-shaped — *Grounded*

- **What.** `string.find` returns `(isize, isize)` — `(0, 0)` on no match, not `nil`.
  `string.match` returns `(boolean, sequence(string))`. There is no `string.split`.
  A Nelu user writing `for w in string.split(s, " ") do` cannot; they build it from
  `find`+`sub` with the non-Lua `(0, 0)` idiom.
- **Nelu vs oracle framing.** **Parity** (the oracle behaves exactly this way; it is a
  deliberate divergence from Lua, documented in the manual section 7.1). Not a Nelu
  extension — a documentation/ergonomics gap.
- **Suggested shape.** `string.split(s, sep, maxn)` returning `sequence(string)`, as a
  thin layer over the existing `find`/`sub`. Small, high-value. Could also offer a
  `string.find_first`/`find_last` that return `facultative((isize,isize))` so callers
  can write `if find(...) then`.

### 7b. No `path` / filesystem-path module — *Grounded*

- **What.** `lib/` has `os` (with `tmpname`, `remove`, `rename`, `setlocale`) and
  `filestream`, but no path-manipulation helpers: join, split, basename, dirname,
  extension, exists/isdir/isfile. `os` is a thin wrapper over C `<stdlib.h>`/`<time.h>`.
- **Where it hurts now.** Any program doing file I/O hand-rolls path joining with `..`
  and string slicing, and hand-rolls `stat` calls via `C` interop to test existence.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (the oracle's `os` is the same
  thin wrapper; neither has a `path` module). Pure Nelu addition.
- **Suggested shape.** `require 'path'` exposing `path.join`, `path.split`,
  `path.basename`, `path/dirname`, `path/extension`, `path/exists`, `path/isfile`,
  `path/isdir`, `path/ismark`. Backed by `<stat.h>` via `C` interop. **Small** effort.

### 7c. `io` has no `lines`-over-string and no `read-all-into-stringbuilder` shortcut — *Grounded*

- **What.** `io.lines` iterates a file; there is no `string.lines(s)` for iterating the
  lines of an in-memory string. `stringbuilder` exists but `io` does not expose a
  "read whole file into a stringbuilder" one-liner (`filestream` has `read` but you must
  size it yourself).
- **Where it hurts now.** Common scripting ergonomics is missing; users reach for `C`
  interop (`fread`) instead.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle `io` is the same).
  Pure Nelu addition, **Small** effort.

### 7d. `math` is complete but `random` has no integer-range overload — *Grounded*

- **What.** `math.random()` (no args) returns `[0,1)` float; `math.randomseed` exists.
  There is no `math.random(min: integer, max: integer): integer`. Users write
  `math.random() * (b-a) + a` and cast.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle `math` is the same C99
  wrapper). **Trivial** effort; high daily value.

### 7e. Allocators: no `free`-on-scope helper, and `gc_allocator` finalizers are awkward — *Grounded*

- **What.** `allocators/default` exports `new`/`delete` but there is no RAII-style
  "allocate and auto-free at scope exit" beyond `<close>` on a record. The GC path is
  the default; the `nogc` path requires manual `free` everywhere. `gc_allocator`'s
  `__gc` metamethod is the only finalization hook and it is not documented in the manual.
- **Where it hurts now.** The manual's section 8.3 mentions `<close>` but not `__gc`, and
  the "Zero Is Initialization" idiom means you cannot rely on destructors for anything
  but `<close>`-marked vars.
- **Nelu vs oracle framing.** **Parity** (oracle has the same allocator set). Docs gap
  plus a small Nelu-ext ergonomic helper. **Trivial-Small**.

### 7f. `C` interop: no `C.errno`-checking helper and no `C.strerror` ergonomics — *Grounded*

- **What.** `C.errno` and `C.strerror` exist, but there is no `require 'C.errno'`
  helper that turns `C.errno` into a Nelua string with a Nelu-idiomatic message. The
  manual lists `C.errno`/`EDOM`/`ERANGE`/`EILSEQ` but no user-facing wrapper.
- **Nelu vs oracle framing.** **Nelu ext beyond oracle** (oracle `C.errno` is the same
  raw constants). **Trivial** effort.

## 8. The manual itself — *Grounded*

- **8a. No example program beyond "Hello world".** The manual's section 2 is a one-liner.
  A reference manual should carry at least one end-to-end program per major feature
  (a record + operator overload + `## linklib 'm'`; a `cvalist` varargs wrapper; a
  `span` over a stack array; a `hashmap` word-count). Currently those live only in
  `NELUA-200.md` (oracle) and in `tmp/` probes. **Trivial** effort once the compiler
  works; high value for a "reference" manual.
- **8b. The type-vocabulary table is split across two sections.** Section 4.3 (primitive
  type keywords) and section 6.2 (composite types) and section 6.1 (declarations) are
  separate; a reader cannot see the whole type system in one place. Merge them into one
  "Type vocabulary" table under a single section. **Trivial**.
- **8c. Attributes are listed but not explained per-attribute.** Section 4.7 and 14.2 list
  `<cimport>`, `<cexport, codename ...>`, etc., but only section 9.2 gives a one-line
  effect each. Consolidate. **Trivial**.
- **8d. The "queued" constructs have no migration path.** `match`/`try`/`yield`/`tables`
  are marked queued but the manual does not say what to write *today* that will port
  cleanly when they land. Add a short "today's idiom" note per queued feature. **Small**.

## 9. Embedded Lua / preprocessor — *Grounded + one speculative*

- **9a. The preprocessor Lua has no documented standard-library surface.** The manual
  says "standard Lua functions like `select`, `string`, `table`, `math`, `io` are
  available inside `##` blocks" but does not enumerate them.  (The old "vs.
  `nelua-lua`" distinction is moot: there is one binary, `nelu`, whose embedded
  engine provides `--script`/`--lua`; the pp Lua and the REPL Lua are the same
  engine.)  A user writing `##` code guesses. **Small** effort: add a one-paragraph
  "what the preprocessor Lua sees".
- **9b. `LUA_PATH` for preprocessor `require` is untested.** The manual asserts
  `require "foo"` from a standalone `.lua` works with `LUA_PATH` set. I did not verify
  this on the current tree (the preprocessor is not reachable because of #2).
  **Mark verify.** **Trivial** to add a probe once #2 lands.
- **9c. *Speculative*: a `nelu`-shipped `lualib/` vs. `lib/` confusion.** Users may
  mistake `lualib/nelua/` (59 compiler-build-time `.lua` files, read-only) for runtime
  stdlib. The manual already warns this in the appendix, but a one-line note in
  section 1 would help. **Trivial**.
- **9d. *Speculative*: `inject_astnode` and the AST API are the most powerful and least
  documented preprocessor features.** The manual lists them in the keyword table but
  gives no example of iterating/rewriting the AST (e.g. `for node in
  context.rootscope.symbols.X.value:match(...) do`). A worked example would unlock a lot.
  **Small**.

## 10. CLI / build — *Grounded*

- **10a. Two flags are documented as "hooks; none emitted yet".** `-w/--no-warning` and
  `--no-color` are hooks with no effect. Either implement them or mark them deprecated
  in `--help`. Leaving them as no-ops invites users to trust them. **Trivial**.
- **10b. `-g <generator>` has only one backend (`c`); `--print-assembly` implies a second
  that is not wired.** The manual documents `--print-assembly` but on the current tree it
  is a hook. Either wire it or mark it. **Trivial** to document honestly; **Large** to
  wire a real assembler backend (the NASM investigation in
  `plan/nasm-opportunities.md` concluded *against* it).
- **10c. No `-E`/`--preprocess-only` and no `--emit-ast-to-file`.** The `--print-*`
  family prints to stdout; there is no way to dump the preprocessed/AST output to a file
  for incremental tooling. **Small**; pure convenience.
- **10d. ~~`make test` depends on `nelu-lua` but `make nelu` does not.~~ RESOLVED.**
  There is no separate `nelua-lua` binary anymore; `make test` runs the spec suite
  through `tmp/nelua --script spec/init.lua`, so `make nelu` builds everything
  needed.  (Makefile rewritten 2026-09-06.)
- **10e. *Speculative*: no `nelu --run` (compile-and-execute in one step).** The
  `-R/--runner` flag executes *compiled output* with a runner, which is close but not
  the same as a one-shot compile+run. Many users would want `nelu --run hello.nelua`.
  **Small**, pure convenience; risk of masking the `-lm` gotcha.

---

## Appendix: what I could not verify

Because the current tree does not compile non-trivial programs (see proposals 1 and 2),
the following manual claims are **not verified** and should be treated as "specification,
verify against your own build": record/union/enum/span end-to-end compilation, all
`require`'d stdlib, `require 'C.stdio'`, the `coroutine` module's C lowering, metamethod
M3 (`__call`) and M4 (`__index`) parity, `LUA_PATH` for preprocessor `require`, and
`--print-assembly`. The verification bar is `NELU-2K.md` section 3 and `plan/GATES.md`.