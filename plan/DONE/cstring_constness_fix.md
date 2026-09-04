# cstring const-ness gap — characterization and minimal fix

Status: RESEARCH (read-only on `src/`). No `src/` file was edited.

## 1. The divergence (exact)

For any `cstring` (variable, record field, function parameter, function
return), the emitted C differs in exactly one way:

| | declaration | init / literal |
|---|---|---|
| **oracle** | `char*` (non-const) | `(char*)"hi"` (bare C literal) |
| **ours** | `const char*` | `nlstr("hi")` (an `nlstring` struct) |

Concrete evidence (probe `local s: cstring = "hi"`, `-c`):

```
ORACLE  line 84:  static char* tmp_probe_cstring_min_s = (char*)"hi";
OURS   line 150: static const char* tmp_probe_cstring_min_s;
OURS   nelua_main: tmp_probe_cstring_min_s = "hi";
```

Multi-context probe (`local g`, function param/return, function-body local):

```
ORACLE: static char* g = (char*)"global";
        static char* take(char* s);
        char* take(char* s) { char* l = (char*)"local"; }
OURS:   static const char* g;
        const char* take(const char* s);
        const char* take(const char* s) { const char* l; }
```

The oracle is uniformly `char*`. Ours is uniformly `const char*`. There is no
context in which ours emits a bare `char*` for a cstring, and no context in
which the oracle emits `const char*`.

Grounding in the project's own docs: `plan/oracle-language-spec.md:279`
documents `cstring -- C string (char*)`; `plan/scratch-stage34-notes.md:53`
says "cstring as char* (section 6.2) vs our nlstr wrap"; and
`plan/INBOX/our-improvements.md:448` recommends matching "the oracle, which treats
`cstring` as `char*`".

## 2. Full path map (type def -> C repr -> emitted C)

There is exactly **one** place that decides the spelling:

- `src/types.nim:763` — `PrimitiveTypes["cstring"] = makePrimitive("cstring", "cstring", tkCstring)`
- `src/types.nim:237` — `isCstring(t) = t.kind == tkCstring`
- **`src/cgen_types.nim:119-120`** — `of tkCstring: "const char*"` ← the single source of truth for the C spelling
- `src/cgen.nim:1227` `cDecl` → `cType(t) & " "` — renders var / field / param declarators
- `src/cgen.nim:1227` `cFuncDecl` → `cType` — renders function return and param types
- `src/cgen.nim:1653,1692` `genForwardDecl`/`genFuncDef` → `cDecl` → `cType` — cimport/user function signatures
- `src/cgen.nim:1138` — init-list cast uses `cType(ptype)`
- `src/cgen.nim:1490,1537` — for-loop / destructuring decls use `cType`

Everything downstream goes through `cType`, so the tkCstring arm at
`cgen_types.nim:120` is the single point of control.

`cConstType` (`cgen_types.nim:177`) is **not used in code generation** — it
appears only in the `when isMainModule` doAsserts. The `#` operator
(`cgen.nim:707`), the print dispatch (`cgen.nim:872-878`), and `coerce`
(`cgen.nim:425`) all key off `tkCstring`/`isCstring` but none of them override
the spelling.

**Conclusion: the const-ness is NOT lost upstream and is not missing anywhere.
It is applied uniformly and intentionally.** The gap is not a bug in
propagation; it is that the uniform value we chose (`const char*`) is the wrong
value for oracle parity (the oracle uses `char*`).

## 3. The doAsserts at cgen_types.nim:315 / 321

```nim
315:  doAssert cType(cstring)    == "const char*",   cType(cstring)
321:  doAssert cConstType(cstring) == "const char*",  cConstType(cstring)
```

- They assert the *current* spelling. They **pass** (the `nim c` build
  succeeds, and `cType(cstring)` returns `"const char*"` by construction).
- They do **not** detect a bug. They *lock in* the divergent value. They are
  part of the problem, not a diagnostic for it.

## 4. Failing probes

Run against oracle vs ours (rc / stdout / stderr):

- **All cstring probes MATCH at the runtime level.** `examples/www/cstring_type.nelua`,
  `examples/www/www_cstring_type.nelua`, `examples/www/www_cstring_assign.nelua`,
  `examples/nelu/nelu_cstring_literal.nelua`, `examples/nelu/nelu_cvarargs_param.nelua`,
  `examples/nelu/nelu_union_field_access.nelua`, `tmp/probe_cstring_min.nelua`,
  `tmp/probe_cstring_ctx.nelua` — identical stdout and rc.
- **The DIFFs in the sweep are unrelated to cstring const-ness:**
  - `examples/condots.nelua` — ours SIGSEGVs in the analyzer (big SDL example)
  - `examples/overview.nelua` — parse error "expected 'end' to close do"
  - `examples/snakesdl.nelua` — ours fails analyzing `lib/detail/xoshiro256.nelua`
  - `tmp/probe_io2.nelua`, `probe_io_mod.nelua`, `probe_io_tr.nelua` — `lib/filestream.nelua` "unexpected keyword 'string'"
  - `tmp/probe_os_tr.nelua` — ours SIGSEGVs
- **The const-ness gap is a pure C-text divergence.** By itself it causes no
  compile failure and no runtime difference in the current probe set.

### Related, but a SEPARATE issue (flagged, NOT fixed here)

A `cstring` record field initialized with a string literal fails to compile in
ours (oracle compiles it):

```
OURS:  struct R { const char* name; ... };
        r = ((struct R){ .name = nlstr("n"), ... });
        -> error: incompatible types when initializing 'const char *' using 'nlstring'

ORACLE: struct R { char* name; ... };
        r = (R){.name = (char*)"n", ...};   -> compiles
```

Root cause: `genExpr` always wraps string literals in `nlstr(...)`
(`cgen.nim:560`), producing an `nlstring` struct. The simple-local assignment
path unwraps it via `coerce` (`cgen.nim:425-427`), so
`local s: cstring = "hi"` works; the record-init-list path
(`genInitList`, `cgen.nim:1085-1111`) does not unwrap, so
`R{ name = "n" }` emits `.name = nlstr("n")` and fails against the
`const char*`/`char*` field. This is the same class as the already-fixed `#`
operator wrap and is out of scope for the const-ness fix.

## 5. Minimal fix

The fix is a one-line functional change in the single source of truth, plus one
doAssert update. It makes ours match the oracle's `char*`.

```diff
--- a/src/cgen_types.nim
+++ b/src/cgen_types.nim
@@ -117,7 +117,7 @@
     of tkClongdouble: "long double"
     of tkCptrdiff:   "ptrdiff_t"
     of tkCsize:      "size_t"
-    of tkCstring:    "const char*"
+    of tkCstring:    "char*"
     of tkCvalist:    "va_list"
     of tkCvarargs:   "..."
     of tkAuto:       "auto"
@@ -312,7 +312,7 @@
     doAssert cType(cvalist)  == "va_list",         cType(cvalist)
     doAssert cType(cvarargs) == "...",             cType(cvarargs)
-    doAssert cType(cstring)  == "const char*",     cType(cstring)
+    doAssert cType(cstring)  == "char*",           cType(cstring)
```

- `cgen_types.nim:120`: `"const char*"` -> `"char*"`.
- `cgen_types.nim:315`: update the doAssert to `"char*"`.
- `cgen_types.nim:321` needs **no** change: after the fix,
  `cConstType(cstring)` still computes `"const char*"` (it takes
  `cType(cstring)="char*"`, which does not start with `"const"`, and prepends
  `"const "`), so the assert still passes. (`cConstType` is not used in code
  generation, so this is invisible to emitted C.)

Why this is safe: every downstream consumer of `cType(cstring)` now gets
`char*`. The runtime helpers accept it without change — `nlstr(const char*)`,
`nllen`, and `nelua_print_string` all take `const char*`, and `char*` implicitly
converts to `const char*` in C. The `#` operator (`nllen(nlstr(...))`), the
print dispatch (`nlstr(...)`), and `coerce` (which unwraps `nlstr(...)` for
string->cstring) all remain valid.

Why this is minimal: there is exactly one spelling decision point
(`cgen_types.nim:120`). No type-system, analyzer, or upstream change is
required — the const-ness was never lost; only the chosen value was wrong for
parity.

## 6. Scope note (not part of this fix)

Full oracle parity also requires the string-literal->cstring emission fix so
that record-field and other initializers compile (emit a bare C literal /
`(char*)"..."` instead of `nlstr(...)`). That is a separate change touching
`cgen.nim:560` and the init-list paths, and is deliberately excluded from this
const-ness fix per the "no scope creep" constraint.