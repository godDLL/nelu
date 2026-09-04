# Integration Devil — Collegium Mine

Date: 2026-08-30
Scope: constructs mined from `plan/INBOX/our-improvements.md` (stages 1-4),
`plan/INBOX/oracle-improvements.md` (stage 3-4 cross-read), and the two stage-1
specs (`plan/oracle-language-spec.md`, `plan/observed-language-spec.md`).

Method: one isolated Nelua program per flagged construct, deposited in
`examples/nelu/`. Each was run through the oracle (`/usr/bin/nelua -b -o`)
and our compiler (`tmp/devil/nelua-devil`, built once at the start of the
session from the live `src/` tree, `nim c -d:release --path:src`). Binaries
were removed before every comparison. stdout AND exit code were compared.

**Routing per the coordinator's split.** Findings are routed by class:
- **EXTENSION** (oracle REJECTS, Nelu ACCEPTS) — my class, deposited in
  `examples/nelu/`. Section 1 below.
- **PARITY** (oracle RUNS, we diverge) — the www devil's class, deposited in
  `examples/www/`. I probed these for empirical grounding and report them in
  Section 2 for awareness only; the www devil owns the takeover fix and the
  probe duplication (e.g. `nelu_selffield_binary_rhs` vs
  `www_recmethod_mutate`, `nelu_lua_block_preprocess` vs
  `www_splice_embed`, `nelu_uint8_wrap` vs `www_uint8_wrap`).
- **SHARED** (both reject or both fail) — neither class, Section 3.

**Live-tree caveat.** Many items the collegium marks STILL OPEN are in fact
already fixed in the live working tree (the uncommitted concurrent edits the
stage-4 revision warns about). Those are recorded as MATCH / DONE in
Section 5 so the plan is not re-ranked against landed work.

---

## 1. EXTENSION — oracle rejects, we accept (MY CLASS)

These are not parity targets (the oracle never runs them), but our acceptance
producing broken behaviour is a real bug worth recording. Probes deposited in
`examples/nelu/`.

### 1.1 closures / upvalues — oracle rejects, our codegen crashes
- Program: `examples/nelu/nelu_closures.nelua`
- Oracle: `error: attempt to access upvalue 'n', but closures are not
  supported`, exit 1 (P3.2, `analyzer.lua:672`)
- Ours: accepts the parse but SIGSEGVs at codegen (exit 139); a simpler
  closure emits `static void tmp_oc_f;` — "variable or field declared void"
  — and gcc rejects it (exit 1).
- Root cause: closures are a Nelu extension (the machinery is landed) but the
  C emission path for captured upvalues is not implemented.
- Severity: **MEDIUM** — our acceptance is silent and the result is a crash
  or invalid C, which is worse than a clean rejection.

### 1.2 `facultative(string)` type-function-call — oracle crashes, we accept
- Program: `examples/nelu/nelu_facultative_typecall.nelua`
- Oracle: `attempt to get length of a nil value (field 'rettypes')` in
  `cgenerator.lua:192`, exit 1
- Ours: compiles and prints `ok`, exit 0
- Root cause: `facultative(string)` is a Nelu extension; the oracle's C
  generator has not seen it and crashes. Our parser accepts it (1.4 is marked
  COMPLETE in the live tree).
- Severity: **LOW** — our behaviour is correct; the oracle's is the broken
  one. Not a takeover blocker, but confirms `lib/builtins.nelua` cannot run
  on the oracle as written.

### 1.3 dotted `global X.Y` — oracle rejects, we accept and emit invalid C
- Program: `examples/nelu/nelu_dotted_global.nelua`
- Oracle: rejects the bare form (exit 1)
- Ours: accepts the parse, emits
  `static int64_t examples_nelu_nelu_dotted_global_Rect.field;` — gcc rejects
  the literal `.`, exit 1
- Root cause: the global-declaration codename path does not sanitize `.` (and
  other non-identifier characters) to `_`, unlike `cemitter.cIdent`.
- Severity: **MEDIUM** — ours accepts what the oracle rejects AND emits
  invalid C. The parity-consistent behaviour is to reject `global X.Y`.

---

## 2. PARITY — oracle runs the program, we diverge (WWW DEVIL'S CLASS)

These are takeover blockers. The oracle compiles and runs the snippet; our
compiler either rejects it, crashes, or produces different output. **Owned
by the www devil** (`examples/www/`); reported here for empirical grounding
only. I did not deposit these in `examples/nelu/` to avoid duplicating probes
the www devil is already writing.

### 2.1 `goto` + `::label:` cannot be a statement — CRASH / REJECTED-BY-US
- Program: `examples/nelu/nelu_goto_label.nelua`
- Oracle: prints `5`, exit 0
- Ours: `error: unexpected token after end of program`, exit 1
- Root cause: `parseBlock`/`parseSwitchBlock` both `break` on `tkColonColon`
  (`src/parser.nim:603,631`), so a label is never reachable as a statement.
  The `nkLabel`/`nkGoto` node kinds and the `goto` keyword already exist.
- Severity: **CRITICAL** — blocks `lib/stringbuilder.nelua` (7 `goto next`),
  `lib/string.nelua`, `lib/allocators/heap.nelua`, `examples/brainfuck.nelua`,
  `examples/overview.nelua`. The #1 ranked item in the collegium and it is
  still open.

### 2.2 byte literal `'A'_b` suffix — C-COMPILE-FAIL
- Program: `examples/nelu/nelu_byte_literal_suffix.nelua`
- Oracle: prints `112`, exit 0
- Ours: gcc rejects `tmp_bl_b = (uint8_t)(nlstr("p"))` — "aggregate value
  used where an integer was expected", exit 1
- Root cause: `lexer.nim`'s `lexString` treats a single-quoted char literal
  identically to a double-quoted string and returns at the closing quote; the
  numeric-suffix scanner only runs inside `lexNumber`, so `_b` is lexed as a
  separate identifier and the char literal is wrapped in `nlstr(...)`.
- Severity: **HIGH** — used in `lib/string.nelua` (`case 'X'_b then`) and
  `lib/allocators/heap.nelua`.

### 2.3 `self.x = self.x * s` (binary-op RHS on a self-field lvalue) — CRASH
- Program: `examples/nelu/nelu_selffield_binary_rhs.nelua`
- Oracle: prints `6 8`, exit 0
- Ours: SIGSEGV (exit 139), "Illegal storage access. (Attempt to read from nil?)"
- Root cause: `analyzeAssign` (`src/analyzer.nim:1844`) sends `nkDotIndex`
  targets to the generic `analyzeExpr` path; when the RHS is a binary op, type
  inference for the indexed LHS returns nil and a later deref segfaults.
  (The nil-guard landed in `analyzeCall` covers a different path.)
- Severity: **HIGH** — the exact pattern in `examples/www/recmethod_mutate.nelua`.

### 2.4 `##` Lua splice block not run by the compile driver — WRONG-OUTPUT
- Program: `examples/nelu/nelu_lua_block_preprocess.nelua`
  (`## x = 7` then `print(#[x]#)`)
- Oracle: prints `7`, exit 0
- Ours: prints `(null)`, exit 0
- Program: `examples/nelu/nelu_longbracket_lua_block.nelua`
  (`##[[ x = 7 ]]` then `print(#[x]#)`)
- Oracle: prints `7`, exit 0
- Ours: prints `(null)`, exit 0
- Root cause: `compile.nim:10-16` — the preprocessor is built and tested via
  `runM6Pipeline` but is not invoked by the default compile path, so `##`
  blocks never execute and `#[x]#` splices nil.
- Severity: **HIGH** — blocks `examples/brainfuck.nelua` (which uses
  `##[=[ ... ]=]` for its source string), `examples/splice_embed.nelua`.

### 2.5 anonymous functions — CRASH at codegen
- Program: `examples/nelu/nelu_anon_function.nelua`
- Oracle: prints `42`, exit 0
- Ours: SIGSEGV (exit 139) at codegen
- Root cause: `genC` segfaults on anonymous functions in expression position.
  `main.nim:82-88` still sets `needsCompile = false` for the print-AST paths
  with the comment "the emitter segfaults on valid constructs".
- Severity: **HIGH** — a large fraction of the corpus cannot be compiled.

### 2.6 `likely()` / `unlikely()` not lowered to C — C-COMPILE-FAIL
- Program: `examples/nelu/nelu_likely_unlikely.nelua`
- Oracle: prints `yes`, exit 0
- Ours: gcc error "implicit declaration of function 'unlikely'", exit 1
- Root cause: the analyzer recognizes `likely`/`unlikely` but the C emitter
  maps them to bare calls instead of `__builtin_expect(arg, 1/0)` or the
  `NELUA_LIKELY`/`NELUA_UNLIKELY` macros from `runtime.c`.
- Severity: **MEDIUM** — used in `lib/allocators/heap.nelua`.

### 2.7 `check(false, msg)` omits the source location — WRONG-OUTPUT
- Program: `examples/nelu/nelu_check_source_loc.nelua`
- Oracle: `nelu_check_source_loc.nelua:2:7: runtime error: should fail` plus
  a source line and caret, exit 134
- Ours: `runtime error: should fail` only, exit 134
- Root cause: the runtime error path in our driver does not prepend the
  source location the way the oracle's does.
- Severity: **LOW** (cosmetic) — both abort with the same exit code.

### 2.8 multi-return unpacking drops the second return value — WRONG-OUTPUT
- Program: `examples/nelu/nelu_multiret_function.nelua`
  (`local function divmod(a,b) return a/b, a%b end; local q,r = divmod(17,5)`)
- Oracle: prints `3.4 2`, exit 0
- Ours: prints `3.4 (null)`, exit 0
- Root cause (verified in the emitted C): the second multi-return variable
  is declared `static nilptr tmp_mr3_b;` (type inference defaults to nilptr)
  and is never assigned — only the first return value is unpacked. The
  `__mrN` multi-return lowering is incomplete for the second-and-later values.
- Severity: **HIGH** — this is a core idiom (error handling via multiple
  returns) and was NOT flagged in the collegium (which only addressed
  multiple-returns-in-main, which the oracle rejects). The oracle runs this
  fine, so it is a genuine PARITY gap.

---

## 3. SHARED LIMITATIONS — both reject or both fail

These are not divergences; neither compiler handles the construct, so there
is no behavioural difference to reproduce.

### 3.1 table literals — neither compiler supports them in C
- Programs: `examples/nelu/nelu_table_literal_sideeffect.nelua`,
  `examples/nelu/nelu_keyindex_initlist.nelua`
- Oracle: `error: type 'table' is not supported yet in the C backend`, exit 1
- Ours: emits a struct literal `{1, 2, 3}` then
  `error: subscripted value is neither array nor pointer nor vector`, exit 1
- Root cause: the oracle's C backend has no table type; ours emits a bare
  record struct with no array backing. Both are incomplete.
- Severity: **INFO** — not a divergence. The oracle's stdlib is all `.lua`;
  the Nelua `lib/` files that use tables must target the Lua backend or do
  not compile to C on either compiler.

### 3.2 multi-value `for k, v in array` — neither supports it
- Program: `examples/nelu/nelu_forin_multi.nelua`
- Oracle: `attempt to call a nil value (method 'get_return_type')` in
  `analyzer.lua:1227`, exit 1
- Ours: SIGSEGV at codegen, exit 139
- Root cause: `genForIn` supports only a single array iterable (2.6). The
  oracle's analyzer also has no handling for multi-value iterables.
- Severity: **INFO** — shared gap, not a divergence.

### 3.3 `@enum{...}` — neither handles it cleanly
- Program: `examples/nelu/nelu_enum_no_cenum.nelua`
- Oracle: `from: AST node Block` (incomplete diagnostic), exit 1
- Ours: SIGSEGV, exit 139
- Root cause: the oracle's enum syntax is `@enum(cint){...}` (per
  `lib/coroutine.nelua`), not the bare `@enum{...}` form; our parser has no
  matching production and crashes. The collegium's 3.8 (no C `enum` typedef
  emitted) is a separate concern — even when the enum parses, our `cgen_types`
  returns only `cTag(t)` with no enum constants.
- Severity: **INFO** — both reject the bare form; the C-enum-emission half
  of 3.8 remains open but was not exercisable in a form both compilers accept.

### 3.4 undeclared symbol — oracle gives a clean diagnostic, we crash
- Program: `examples/nelu/nelu_undeclared_symbol.nelua`
- Oracle: `error: undeclared symbol 'undefned_typo'` with source location,
  exit 1
- Ours: SIGSEGV (exit 139)
- Root cause: the analyzer has no undeclared-symbol diagnostic (2.7); when
  it hits an unknown identifier in an expression context it falls through to
  a path that segfaults instead of emitting a clean error.
- Severity: **MEDIUM** — not a parity divergence (the oracle rejects), but
  our crash where the oracle gives a clean diagnostic is a robustness bug.
  This is the 2.7 gap manifesting as a crash rather than a silent `any`
  extern (the silent-extern behaviour was the documented form; the live tree
  appears to have changed the path so it now crashes instead).

### 3.5 `cond` keyword — both reject
- Program: `examples/nelu/nelu_cond_keyword.nelua`
- Oracle: `syntax error: unexpected syntax`, exit 1
- Ours: `error: unexpected keyword 'cond'`, exit 1
- Root cause: the oracle has no `cond` at all (no `Cond` node in its AST
  table). The live tree has removed the `cond` parse production, so ours now
  rejects it too — matching the oracle. (6.1 is therefore resolved as "drop",
  not as a divergence.)
- Severity: **INFO** — matching rejection.

### 3.6 `T?` optional-type syntax — both reject
- Program: `examples/nelu/nelu_optional_type_syntax.nelua`
- Oracle: `syntax error: unexpected syntax`, exit 1
- Ours: `error: unexpected token`, exit 1
- Root cause: the oracle never accepted `T?`. The live tree has changed
  `parseOptionalType` from "accept-and-discard" to "reject", so ours now
  matches the oracle. (3.9 is resolved as matching rejection, not a
  divergence.)
- Severity: **INFO** — matching rejection.

---

## 4. MATCH / DONE — verified working identically

These collegium items were probed and both compilers agree. Several items
marked STILL OPEN in the collegium are in fact fixed in the live working tree.

| Item | Program | Result |
|------|---------|--------|
| 1.3 colon method on type-keyword receiver | `nelu_colon_method_typekeyword` | MATCH (`ok`) |
| 1.4 `facultative(string)` parsing | `nelu_facultative_typecall` | ours accepts (EXTENSION, 1.2) |
| 1.5 typed `for i: T = 0, <N do` | `nelu_typed_for_exclusive` | MATCH (`45`) |
| 2.2 small-uint arithmetic wraps | `nelu_uint8_wrap` | MATCH (`44`) |
| 2.3 `float32` print keeps `.0` | `nelu_float32_print_dot0` | MATCH (`75.0`) |
| 2.5 method calls | `nelu_method_call` | MATCH (`0.0`) |
| 2.5 if/elseif chains | `nelu_if_elseif_chain` | MATCH (`two`) |
| 3.1 `cstring` literal assignment | `nelu_cstring_literal` | MATCH (`hello`) |
| 3.2 `@union` field access | `nelu_union_field_access` | MATCH (`5`) |
| 3.3 `<comptime>` on a string | `nelu_comptime_string` | MATCH (`1.0`) |
| 3.5 `...: cvarargs` C emission | `nelu_cvarargs_param` | MATCH (`declared`) |

---

## 5. Could not turn into a runnable snippet

- **P1.3 table-literal side effects (VERIFY).** The oracle's C backend rejects
  table literals outright (`type 'table' is not supported yet in the C
  backend`), so there is no oracle-runnable program that exercises
  side-effect ordering in a table constructor. The VERIFY item cannot be
  settled by a two-compiler comparison; it needs a corpus run on the Lua
  backend or a construct the oracle's C backend accepts.
- **P2.4 emit_nelua_main heuristic (VERIFY).** No isolated snippet exercises
  the "did the emitter add statements" detection; it is a property of the
  whole emitted translation unit, not a single construct.
- **P3.1 KeyIndex/InitList node mapping (VERIFY).** Same problem — the oracle
  rejects the table-constructor forms that would map to those nodes, so there
  is no oracle-runnable probe.
- **3.8 enum C-emission.** Neither compiler accepts a bare `@enum{...}` in a
  form that both can compile, so the "no C enum typedef emitted" claim could
  not be isolated to a runnable divergence. The oracle's form is
  `@enum(cint){...}` and even that fails on the oracle (`unknown type name
  'Color'`), so the enum path is broken on both sides.
- **`defer` stack.** The construct is real and works in both compilers when
  given the correct syntax (`defer print('d2') end`, per
  `examples/www/defer.nelua`). My first attempt used `defer function() ...`
  which both reject; that was a syntax error in the probe, not a finding.
- **`#|name|#` and `##[[...]]`.** Both compilers reject these forms (the
  oracle with a clear "cannot convert preprocess value of lua type nil to a
  name", ours with a generic analyze failure). No runnable divergence.

---

## 6. Most valuable to fix (ranked)

Things that block real programs in the corpus, not contrived ones. Items 1-3
below are the www devil's PARITY territory; 4-6 are my EXTENSION territory.

1. **`goto` + `::label:` as a statement (2.1).** Two-line fix (remove the two
   `break` on `tkColonColon` in `parseBlock`/`parseSwitchBlock`). Unblocks
   `lib/stringbuilder.nelua`, `lib/string.nelua`, `lib/allocators/heap.nelua`,
   `examples/brainfuck.nelua`, `examples/overview.nelua`. The single highest-value
   change in the mine. [PARITY — www devil]

2. **Multi-return unpacking drops the second+ values (2.8).** NEW finding,
   not in the collegium. `local a, b = f()` where `f` returns two values
   prints `(null)` for `b`. This is a core idiom and the oracle runs it
   correctly. Likely a bounded fix in the `__mrN` unpacking path in `cgen.nim`.
   [PARITY — www devil]

3. **`self.x = self.x * s` SIGSEGV (2.3).** One-line nil-guard in
   `analyzeAssign` mirroring the guard just landed in `analyzeCall`. Unblocks
   `examples/www/recmethod_mutate.nelua` and any mutate-a-field-with-computed-value
   idiom. [PARITY — www devil]

4. **`##` Lua splice blocks not run by the driver (2.4).** Wire the existing
   preprocessor into the `analyze` entry point in `compile.nim`. Unblocks
   `examples/brainfuck.nelua` and any splice-using program. [PARITY — www devil]

5. **Byte literal `'A'_b` suffix (2.2).** Bounded lexer change: scan an
   optional `_<suffix>` after a single-quoted char literal, with `_b` -> byte.
   Unblocks `lib/string.nelua` and `lib/allocators/heap.nelua`. [PARITY — www devil]

6. **Anonymous-function codegen crash (2.5).** `genC` segfaults on anonymous
   functions in expression position. Blocks a large fraction of the corpus.
   [PARITY — www devil]

7. **`likely`/`unlikely` not lowered (2.6).** One dispatch entry mapping to
   `__builtin_expect`. Unblocks `lib/allocators/heap.nelua`. [PARITY — www devil]

8. **Dotted `global X.Y` emits invalid C (1.3).** MY CLASS. Sanitize `.` in the
   global-decl codename path, or emit a diagnostic to match the oracle's
   rejection. Currently ours accepts and emits code gcc rejects. [EXTENSION]

9. **Closures/upvalues codegen crash (1.1).** MY CLASS. The C emission path for
   captured upvalues is not implemented; our silent acceptance produces a crash
   or invalid C. Either implement it or reject cleanly like the oracle.
   [EXTENSION]

10. **Undeclared-symbol crash (3.4).** The oracle gives a clean
    "undeclared symbol" diagnostic; ours SIGSEGVs. Not parity, but a
    robustness bug — the 2.7 gap should produce a diagnostic, not a crash.
    [SHARED]

11. **`check()` source location (2.7).** Cosmetic; prepend
    `path:line:col:` in the driver's runtime-error path. Both already abort
    with exit 134. [PARITY — www devil]

---

## 7. Caveats

- **Did I actually run both compilers for each finding?** Yes. Every finding
  above was verified by compiling with `/usr/bin/nelua -b -o` and
  `tmp/devil/nelua-devil -b -o`, running both binaries, and comparing stdout
  and exit code. The harness in `/tmp/run_one.sh` removed the binaries before
  each comparison. Findings 2.8 (multi-return) and the byte-literal case were
  additionally verified by inspecting the emitted C.
- **Which collegium items could not be turned into a runnable snippet and
  why?** The three VERIFY items (P1.3 table side effects, P2.4
  emit_nelua_main heuristic, P3.1 KeyIndex/InitList mapping) cannot be
  settled by a two-compiler comparison because the oracle's C backend rejects
  the table-construct forms they depend on. The enum C-emission item (3.8)
  could not be isolated because neither compiler accepts a bare `@enum{...}`
  in a form both can compile. These are listed in Section 5.
- **Was `src/` compiling during the run?** Yes. Our compiler was built once
  at the start of the session (`nim c -d:release --path:src -o:tmp/devil/nelua-devil
  src/main.nim`, success) and reused for every comparison. No `src/` file was
  edited during the run. The live working tree's uncommitted concurrent edits
  are what fixed the items recorded as MATCH/DONE in Section 4 — those edits
  were already on disk before this session started.
- **Classification rule applied.** EXTENSION = oracle rejects and we accept
  (Section 1). PARITY = oracle runs the program and we diverge (Section 2,
  owned by the www devil). Shared limitations and matching rejections are
  recorded as such (Section 3), not counted as takeovers.

---

# Run 4 (2026-09-04) — SPECIAL FORCE DEVIL: corpus-growth probes

Date: 2026-09-04
Scope: **grow the `examples/*/**` corpus** with new oracle-verified probes,
especially `-ddx` (oracle accepts, ours fails). Two sources: (a) the
internet (github API + raw fetches), (b) invention grounded in real Nelua
idioms mined from `lib/`, `lualib/`, and the upstream `edubart/nelua-lang`
tree. Method: each probe compiled with `/usr/bin/nelua -b -o` and our stable
build (`nim c -d:release --path:src -o:$WD/nelua src/main.nim`, built once at
session start), both binaries run, stdout AND exit code compared. Worked in an
isolation copy at `tmp/2026-09-04-DEVIL-SF/<ts>/`; no `src/`, `lualib/`, or
live `examples/` file was modified; no git command was run.

**STATUS (updated 2026-09-04, same day): ALL FOUR FINDINGS ARE FIXED and
integrated into the live tree** (commit `b1f1ed4` carries the probes; the
multi-dim C-emission fix is in `src/cgen.nim`, `src/cgen_types.nim`,
`src/analyzer.nim`). All four probes now MATCH the oracle; the www sweep went
from 91 PASS to 97 PASS; `cmp.py` (1 diff/40), `regress.py` (M2 14/14, M1
25/3/0 GREEN), and `examples_parity.py` (2/5/3) are all unchanged from
baseline. The fix is four pieces: (1) array dimension ordering
outermost-to-innermost in `cType`/`cDecl` (`[2][3]integer` ->
`int64_t a[2][3]`, was transposed `[3][2]`); (2) nested-index read/write in
`genAssign`/`genReturn` use `realType` (concrete element type) instead of the
analyzer's `any`, so the RHS is not boxed through `nlany_from_int` /
`nlany_load_int`; (3) comptime-sized arrays are emitted with an explicit bound
(`bool a[101]`, was `bool a[]`), and comptime globals are skipped in the
`genVarDecl` globals pass; (4) `isComptime` gains an `nkId` branch returning
`a.comptime`, so a `<comptime>`-variable reference (e.g. `N` in `[N+1]boolean`)
folds instead of falling through to `else: false`. This is an ADDITION, not a
removal -- without it comptime array sizes never folded.

**Routing.** All four findings below are PARITY (oracle accepts, ours
diverges) and are deposited in `examples/www/` as `-ddx` probes, per the
corpus provenance doc (`examples/README.md`): the www tier is the curated
one-probe-per-construct comparison corpus where a feature is proven before it
is claimed. None of the four duplicates an existing probe (verified by grepping
the live www/ tree for `[i][j]` / nested-index patterns — only
`tetrix_rotation` touches nested init lists, and that is a different defect,
see `plan/tetrix-rotation-gaps.md`).

## Web recon (source (a))

Network WAS available and WAS used. Hits:
- `edubart/nelua-lang` master tree (github API + raw): the upstream examples
  (`dsl1.nelua`, `dsl2.nelua`, `snakesdl_nldecl.nelua`) and the full
  `tests/*.nelua` suite (34 files) were downloaded. The local `tests/` already
  mirrors most of them; the upstream `tests/` are real Nelua programs but the
  vast majority fail to compile through OURS because of the pre-existing
  `## local function NAME ... ## end` macro-definition / splice cascade
  (`lib/hash.nelua:73:51: error: unexpected token`), already documented as the
  single largest stdlib blocker. Not re-litigated.
- `edubart/nelua-samples` (`sokol-nuklear-calculator.nelua`,
  `nene-microui.nelua` + libs): real sample apps, but they `require` sokol
  bindings and do not compile standalone. Mined for idioms only.
- `Andre-LA/raylib-nelua` (22 example files): real Nelua programs, but every
  one `require`s the raylib binding; not runnable in isolation.
- `edubart/tetrix`, `edubart/seqtoy`: the RIV fantasy-console programs; already
  present in `examples/www/` as `tetrix`/`seqtoy` (external, need the RIV SDK).
- GitHub code search (`api.github.com/search/code`) and repository search for
  `nelua`/`riv`/`callek`: returned only forks of the upstream repo and the
  already-known tetrix/seqtoy. **No third-party Nelua user programs were found
  beyond the project's own samples.** The community writing real Nelua code is
  small and mostly on the RIV console, whose programs need the SDK to run.
- The oracle's own `lualib/` and `lib/` were mined exhaustively for idioms
  (static method calls `Type.method(args)`, `@record{}` namespaces,
  `@enum(byte){...}`, `switch`/`fallthrough`, `defer ... end`, `cstring`,
  pointer deref, `global` decls). Most idioms that do not `require` a stdlib
  module MATCH; the ones that do are masked by the cascade.

## 1. NEW PROBES — PARITY (oracle accepts, ours diverges)

Four probes deposited in `examples/www/`, all `-ddx`, all verified by running
both compilers.

### 1.1 `www_multidim_index-ddx.nelua` — multi-dim array dimension reversal
- Program:
  ```lua
  local a: [2][3]integer = {{1, 2, 3}, {4, 5, 6}}
  print(a[0][0], a[1][0], a[0][1], a[1][1], a[0][2], a[1][2])
  ```
- Oracle: `1 4 2 5 3 6`, exit 0
- Ours: `1 4 2 5 4 0`, exit 0 — **WRONG-OUTPUT**
- Root cause: the C emitter declares `[2][3]integer` as `int64_t a[3][2]` —
  the dimensions are **reversed**. The reads and the initializer are then
  applied to the transposed array, so `a[0][2]` (valid on a `[2][3]`) falls
  off the end of the `[3][2]` and reads `a[1][0]` (=4), and `a[1][2]` reads
  zero. Square arrays (`[4][4]byte` in tetrix) hide it. Fix target:
  `cgen_types.nim` array-type emission must preserve dimension order.
- Severity: **HIGH** — blocks every non-square 2D array program:
  `examples/matmul.nelua`, `examples/gameoflife.nelua`,
  `examples/www/tetrix_rotation-ddx.nelua`. Not previously documented
  (`plan/tetrix-rotation-gaps.md` Gap 2 is about nested init-list
  placeholders, not dimension order).

### 1.2 `www_multidim_assign-ddx.nelua` — nested array-element assignment
- Program:
  ```lua
  local a: [2][3]integer
  a[0][0] = 5; a[0][1] = 6; a[1][2] = 9
  print(a[0][0], a[0][1], a[1][2])
  ```
- Oracle: `5 6 9`, exit 0
- Ours: gcc rejects `a[0][0] = nlany_from_int(5)` — "incompatible types when
  assigning to type 'int64_t' from type 'nlany'", exit 1 — **C-COMPILE-FAIL**
- Root cause: the assignment emitter wraps the RHS of a **nested** index
  target in `nlany_from_int(...)` even when the element type is concrete
  (`int64_t`, `uint8_t`, …). Single-index assignment (`a[0] = 5`) is emitted
  correctly and MATCHes; only the `[i][j]` (two-level) form wraps. Fix target:
  `cgen.nim` `genIndex`/assignment path — do not round-trip a concrete-typed
  array element through `nlany`.
- Severity: **HIGH** — blocks `self.layout[i][j] = ...` in
  `examples/www/tetrix_rotation-ddx.nelua`, `examples/matmul.nelua`,
  `examples/gameoflife.nelua`, i.e. every 2D-array write.

### 1.3 `www_multidim_ret-ddx.nelua` — nested array-element read in return
- Program:
  ```lua
  local Grid = @record{ cells: [2][2]integer }
  function Grid:get(i: integer, j: integer): integer
    return self.cells[i][j]
  end
  local g: Grid
  g.cells[0][0] = 5; g.cells[1][1] = 8
  print(g:get(0,0), g:get(1,1))
  ```
- Oracle: `5 8`, exit 0
- Ours: gcc rejects `return nlany_load_int(self->cells[i][j])` — "incompatible
  type for argument 1 of 'nlany_load_int' … expected 'nlany' but argument is
  of type 'int64_t'", exit 1 — **C-COMPILE-FAIL**
- Root cause: same family as 1.2 but on the **read** path. A nested index in
  return position is wrapped in `nlany_load_int(...)` (the `nlany`-to-int
  unwrap), but the element is already a plain `int64_t`, so the unwrap is
  backwards. (A nested index in `print(...)` position uses `nlany_from_int`,
  which takes `int64_t` and therefore compiles — that is why 1.1's reads
  compiled, only the values were wrong.) Fix target: same `cgen.nim` path.
- Severity: **HIGH** — blocks getter-style methods on 2D grids, and transitively
  any record with a multi-dimensional array field that is read or written.

### 1.4 `www_comptime_array_size-ddx.nelua` — comptime-sized array omits the size
- Program: prime sieve on a `[N+1]boolean` with `N <comptime> = 100`.
- Oracle: `25`, exit 0
- Ours: `24`, exit 0 — **WRONG-OUTPUT**
- Root cause: the C emitter declares a comptime-sized array as `T name[];`
  with **no size and no initializer**. GCC's tentative-definition rule then
  warns "array 'is_prime' assumed to have one element", so almost every
  indexed access is out of bounds and the sieve undercounts by one. The
  identical emitted form for an `integer` array happens to survive (GCC gives
  the `int64_t[]` tentative definition more room), which is why an
  integer-typed sieve MATCHes but the `boolean`-typed one does not — the bug
  is the missing size, not the element type. Reproduced in isolation:
  `static bool a[];` → gcc "assumed to have one element" → wrong count;
  `static bool a[101];` → correct. Fix target: emit the explicit comptime
  size `T name[N];` for arrays whose size is a comptime integral.
- Severity: **HIGH** — blocks any program with a `boolean` (or other
  non-`integer`) array whose size is a comptime expression; the exact pattern
  in `examples/fuzz/fuzz_prime_sieve-ddx.nelua` (which DIFFs 24 vs 25).

## 2. Root-cause grouping

All four findings are **C-emission defects in `cgen.nim` / `cgen_types.nim`**,
not parser/type/analyzer defects. They form a single family: **multi-
dimensional / comptime-sized arrays are not lowered to correct C**.
- 1.1: dimension order reversed at type emission.
- 1.2: nested-index write round-trips the RHS through `nlany`.
- 1.3: nested-index read round-trips through `nlany_load_int`.
- 1.4: comptime array size dropped from the declaration.

Per the mission context in DEVIL.md, these rank **below** a genuine
parser/type/analyzer defect but **above** a cosmetic backend quirk: they
block real upstream programs (matmul, gameoflife, tetrix_rotation) that use
2D arrays, and each is a bounded, localised fix in the array-index /
array-type emission path.

## 3. Probes verified but NOT added (already covered, or not a clean finding)

- `string.copy('hello')` / `string.upper('hello')` with `require 'string'`:
  oracle accepts, ours fails — but only because `require 'string'` cascades
  into the `lib/hash.nelua:73` preprocessor failure. The static-method-call
  pattern itself (`Type.method(args)`) MATCHes when the type is a user record
  (`ddx_static_method` → `12.0` both). Masked by the stdlib cascade; not a
  clean isolated probe.
- `##[[ ... ]]` multi-line Lua block: now MATCHes in the live tree (was the
  brainfuck/record_inheretance blocker). Re-verified `ok`/`ok`.
- `defer print('d2') end`: MATCH. `defer do ... end` and `defer function() ...`
  are rejected by BOTH compilers (correct syntax is `defer <stmt> end`).
- `switch`/`case`/`else` with `@enum(byte){...}`: MATCH.
- `global g: [3]integer` + element assign: MATCH.
- `cstring` literal, `*integer = &a[0]` + `$p`: MATCH.
- Queue/stack record-with-methods (`fuzz_queue-ddx`, `fuzz_stack-ddx`):
  oracle and ours disagree on dequeue/pop order (`3 2 1` vs `1 2 3`) even
  with explicit `head=0, tail=0` initialisers. This is uninitialised-record /
  tentative-C-memory behaviour, not a clean semantic divergence; **not added**
  as a probe.
- `in (expr) do ... end` DoExpr as a standalone statement: the oracle rejects
  every standalone attempt ("no do expression block found to use `in`
  statement"); it only appears as the body of a `## local function ... ## end`
  macro def, which is covered by `examples/cover/macro-def.nelua` (MATCH).

## 4. Counts

- New probes added to the corpus: **4** (all `-ddx`, all in `examples/www/`)
- By severity: C-COMPILE-FAIL **2** (1.2, 1.3), WRONG-OUTPUT **2** (1.1, 1.4)
- All four are PARITY (oracle accepts, ours diverges); none is an EXTENSION or
  a SHARED limitation.

## 5. Most valuable to fix (ranked)

1. **`www_multidim_assign-ddx` (1.2) + `www_multidim_ret-ddx` (1.3).** The
   nested-index `nlany` round-trip. Together they block every read AND write
   of a 2D array element, including `self.layout[i][j] = ...` in
   `tetrix_rotation`, the `a[i][j]` accesses in `matmul`/`gameoflife`, and any
   getter method on a grid. One shared fix in the `cgen.nim` index path.
2. **`www_multidim_index-ddx` (1.1).** Dimension reversal. Blocks non-square
   2D array reads; the same programs as above where the array is not square.
   One-line-ish fix in `cgen_types.nim`.
3. **`www_comptime_array_size-ddx` (1.4).** Missing array size. Blocks
   `boolean`/non-`integer` arrays with comptime size, incl.
   `fuzz_prime_sieve-ddx`. One-line fix (emit the size).
4. **`www_multidim_assign-ddx` alone** if the fix must be smallest: the
   write path is the one that breaks `tetrix_rotation`'s rotation methods,
   which is the highest-profile real program in the corpus.

## 6. Caveats

- **Did I actually run both compilers for each probe?** Yes. Every probe was
  compiled with `/usr/bin/nelua -b -o <out>` and our stable build
  (`$WD/nelua -b -o <out>`), both binaries run, stdout and exit compared via
  `/tmp/run_one.sh`. The C-compile-fail findings (1.2, 1.3) were additionally
  verified by reading the gcc error in the emitted C; 1.1 and 1.4 by reading
  the emitted C declaration (the `[3][2]` reversal and the `bool a[];`
  omission respectively).
- **Web recon: done, network available.** GitHub API + raw fetches were used
  (see "Web recon" above). No third-party Nelua user programs were found
  beyond the project's own samples; this is stated plainly rather than
  pretended. The richest real source was the upstream `edubart/nelua-lang`
  tree itself (`tests/`, `examples/`, `lib/`) plus our own `lib/`/`lualib/`,
  which is where the idioms for these probes were mined.
- **Was `src/` compiling during the run?** Yes. Our compiler was built once at
  session start (`nim c -d:release --path:src -o:$WD/nelua src/main.nim`,
  success) and reused for every comparison. No `src/` file was edited during
  the run; no snapshot was needed.
- **Which probes came from the web vs from invention?** None of the four
  probes is a verbatim copy of a web program. The *idioms* are real (2D array
  indexing and comptime arrays appear in `matmul`, `gameoflife`,
  `tetrix_rotation`, `fuzz_prime_sieve`, and the oracle stdlib); the probes
  themselves are minimal isolations written for this run (invention, grounded
  in real source). The web recon's yield was the upstream `tests/` suite and
  the samples repos, which confirmed what real Nelua looks like and confirmed
  that the preprocessor cascade is the dominant stdlib blocker — but did not
  itself produce a clean isolated probe.
- **Live-tree caveat.** The four probes and this section live in the isolation
  copy `tmp/2026-09-04-DEVIL-SF/<ts>/examples/www/`. The live
  `examples/www/` tree and its `README.md` were **not** modified (read-only
  scope); the verdicts are recorded here and in the copy's `www/README.md`.