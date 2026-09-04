# Pointer printing: design to match the oracle

Status: investigation complete, minimal fix prototyped and verified in a copied tree.
Scope: how a non-null pointer is rendered by `print()` (and only `print()`).

## 1. Oracle behavior (captured evidence)

Reference compiler: `/usr/bin/nelua` (0.2.0-dev). All probes live in
`/home/user/Code/nelua-lang/tmp/probes/`. Captured with `cat -A` so tabs show
as `^I` and line ends as `$`.

### 1.1 The exact format

Non-null pointer: `0x` + lowercase hex, natural width, no leading zeros.
Null pointer (nilptr, or a `*T` holding nilptr): the literal `(null)`.

| Probe | Source | Oracle stdout (cat -A) | exit |
|---|---|---|---|
| p1_ptr_int | `local p: *integer = &x; print(p)` | `0x56306b437030$` | 0 |
| p2_addr_of | `local x: integer = 7; print(&x)` | `0x55dbdfdf5030$` | 0 |
| p3_nilptr | `print(nilptr)` | `(null)$` | 0 |
| p4_nil_ptr | `local p: *integer = nilptr; print(p)` | `(null)$` | 0 |
| p5_ptr_byte | `local p: *byte = &b; print(p)` | `0x564cf77a6030$` | 0 |
| p6_ptr_record | `local p: *R = &r; print(p)` | `0x5584928d6040$` | 0 |
| p7_null_record_ptr | `local p: *R = nilptr; print(p)` | `(null)$` | 0 |
| p8_ptr_byte_nil | `local p: *byte = nilptr; print(p)` | `(null)$` | 0 |
| p9_multi | `print(p, q, &x, nilptr)` | `0x559e815dd030^I(null)^I0x559e815dd030^I(null)$` | 0 |
| p11_fieldptr | `local p: *byte = &r.b; print(p); print(&r.a)` | `0x55ce5a795048$` / `0x55ce5a795040$` | 0 |
| p15_mix2 | `print(1, p, 2.5, "hi", true, p, nilptr)` | `1^I0xADDR^I2.5^Ihi^Itrue^I0xADDR^I(null)$` | 0 |

### 1.2 Format properties (all verified)

- Prefix `0x`, lowercase hex digits, no leading-zero padding. A 48-bit
  address renders as 12 hex digits (`0x555555558030`), never as
  `0x0000555555558030`.
- Not signed. It is an address, printed as unsigned hex.
- Independent of pointee type. `*integer`, `*byte`, `*Record`, interior
  pointers (`&r.b`, `&r.a`) and `nilptr` all render identically. p1, p5, p6
  and p11 all produced `0x...` with the same shape.
- Multi-argument print uses tab separators (`^I`), exactly like every other
  typed argument; the pointer arg slots into that sequence unchanged.
- Null is special-cased to `(null)`, NOT to glibc `%p`'s `(nil)`. This is the
  decisive evidence that the oracle has an explicit null check: a raw
  `printf("%p", (void*)0)` on this glibc prints `(nil)` (verified with
  `/tmp/fmttest.c`), but the oracle prints `(null)`.

### 1.3 Deterministic byte comparison (ASLR disabled, `setarch -R`)

With ASLR off the oracle renders a stack address as `0x555555558030`. The
fixedours binary renders the same variable as `0x5555555580d0`. The two
differ only in the address value (the two compilers lay the stack out at
different offsets); every other byte is identical, including the relative
offsets in p11 (`0x...048` / `0x...040` oracle vs `0x...0d8` / `0x...0d0`
fixed, same +8 delta). Conclusion: the format string reproduces the oracle
byte-for-byte modulo the unavoidable address value.

### 1.4 Which printf reproduces it

Captured from `/tmp/fmttest.c` / `/tmp/fmtdet` on this glibc:

```
%p    non-null -> 0x555555559010     null -> (nil)
%#p   non-null -> 0x555555559010     null -> (nil)
0x%lx (uintptr_t cast) -> 0x555555559010
```

`0x%p` is WRONG: glibc `%p` already emits the `0x` prefix, so `0x%p` would
double it to `0x0x...`. The oracle's non-null output matches `%p`, `%#p` and
`0x%lx` indistinguishably on this platform. Because the oracle prints
`(null)` for null (where bare `%p` prints `(nil)`), the runtime helper must
special-case NULL rather than trusting `%p`.

## 2. Current ours behavior (exact locations)

### 2.1 The print row in `src/cgen.nim`

`genCall`, the `nelua_print` branch. The row picks a typed helper per
argument type and decides whether to pass the argument expression.

- `src/cgen.nim:690` `var helper = "nelua_print_nil"`
- `src/cgen.nim:691` `var passArg = false`
- `src/cgen.nim:717` `of tkNilptr, tkPointer: helper = "nelua_print_nil"; passArg = false`
- `src/cgen.nim:718` `of tkAny: helper = "nelua_print_any"; passArg = true`
- `src/cgen.nim:719` `else: helper = "nelua_print_nil"; passArg = false`
- `src/cgen.nim:720` `let call = if passArg: helper & "(" & aes & ")" else: helper & "()"`

`aes` is the generated C for the argument (line 688: `let aes = s.genExpr(arg)`).
For pointers `passArg = false`, so the expression is discarded and the call is
emitted as `nelua_print_nil()` with no argument.

### 2.2 The runtime helper in `src/runtime.c`

- `src/runtime.c:170` `void nelua_print_nil(void) {`
- `src/runtime.c:171` `fputs("(null)", nl_out);`
- `src/runtime.c:172` `}`

It takes no value, so it cannot distinguish null from non-null.

### 2.3 The preamble declaration

- `src/cgen.nim:100` `void nelua_print_nil(void);`
- `src/cgen.nim:103` `extern FILE* nl_out;` (the output stream the helpers write)

### 2.4 Proof that no pointer value reaches a printer

Generated C for p1_ptr_int (`local x: integer = 42; local p: *integer = &x; print(p)`),
emitted by the current `tmp/nelua`:

```c
141:  p1_ptr_int_x = 42;
142:  p1_ptr_int_p = (&p1_ptr_int_x);
143:  nelua_print_nil();
144:nelua_print_newline();
```

The pointer IS computed (`(&p1_ptr_int_x)` is assigned to `p1_ptr_int_p`) but
the print call on line 143 is `nelua_print_nil()` with no argument. The value
is thrown away. Same pattern for every probe: `&x` -> `(&...)`, nilptr ->
`NULL`, a `*T` variable -> the variable name. All are valid C pointer
expressions that would convert cleanly to `void*`.

### 2.5 Confirmed current ours outputs (before fix)

`cat -A`, exit codes in parens:

| Probe | Ours-before stdout |
|---|---|
| p1_ptr_int | `(null)` (0) |
| p2_addr_of | `(null)` (0) |
| p3_nilptr | `(null)` (0) |
| p4_nil_ptr | `(null)` (0) |
| p5_ptr_byte | `(null)` (0) |
| p6_ptr_record | `(null)` (0) |
| p7_null_record_ptr | `(null)` (0) |
| p8_ptr_byte_nil | `(null)` (0) |
| p9_multi | `(null)^I(null)^I(null)^I(null)` (0) |
| p11_fieldptr | `(null)` / `(null)` (0) |

Every pointer, null or not, prints `(null)`. Null cases already MATCH the
oracle; non-null cases DIFF.

## 3. The minimal fix

Three edits, two files. Prototyped in `/tmp/srcfix_ptr` (a copy of `src/`,
never the real tree) and built to `tmp/nelua_fix_ptr`.

### 3.1 cgen.nim: route pointers to a value-taking helper

`src/cgen.nim:717` before:
```nim
          of tkNilptr, tkPointer: helper = "nelua_print_nil"; passArg = false
```
after:
```nim
          of tkNilptr, tkPointer: helper = "nelua_print_ptr"; passArg = true
```

Line 720 then emits `nelua_print_ptr(<aes>)` because `passArg` is true. `<aes>`
is already a C pointer expression (`(&x)`, `NULL`, a `int64_t*` variable, a
`struct ...*`, a `uint8_t*`); all convert implicitly to `void*`, so no cast is
needed. The pointee type is irrelevant, which matches the oracle.

### 3.2 cgen.nim: declare the new helper in the preamble

After `src/cgen.nim:100`, add:
```c
void nelua_print_ptr(void* v);
```
so every emitted translation unit links the symbol.

### 3.3 runtime.c: define the helper

Insert after `src/runtime.c:172` (i.e. before `nelua_print_sep` at line 174):

```c
void nelua_print_ptr(void* v) {
  /* A pointer prints as its raw address (glibc `%p`: `0x` + lowercase hex,
     no leading zeros).  The oracle prints the literal `(null)` for a null
     pointer, so NULL is special-cased here rather than relying on `%p`'s
     platform-specific `(nil)`.  Pointee type is irrelevant -- *integer,
     *byte, *Record and nilptr all render identically. */
  if (v == NULL) {
    fputs("(null)", nl_out);
  } else {
    fprintf(nl_out, "%p", v);
  }
}
```

`nl_out` is `FILE* nl_out;` at `src/runtime.c:81`, already used by every other
print helper, so no new state is needed. `%p` reproduces the oracle's
`0x...` exactly on this glibc; the NULL branch is what produces `(null)`.

### 3.4 Why this is minimal

- One case-line change in the existing type dispatch; no new control flow, no
  new argument handling.
- One declaration and one ~6-line definition.
- It does not touch the `else` fallback (line 719), the `tkAny` path, string
  coercion, or any other printer. A pointer argument always has a type, so it
  never reaches the `else` branch.

## 4. Probe table (oracle vs ours-before vs ours-after)

Format-normalized comparison (addresses collapsed to `0xADDR`). "Match" means
the normalized strings and exit codes are equal.

| Probe | Oracle (normalized) | Ours-before (normalized) | Ours-after (normalized) | Verdict |
|---|---|---|---|---|
| p1_ptr_int (`*integer`) | `0xADDR` | `(null)` | `0xADDR` | DIFF -> MATCH |
| p2_addr_of (`&x`) | `0xADDR` | `(null)` | `0xADDR` | DIFF -> MATCH |
| p3_nilptr (`nilptr`) | `(null)` | `(null)` | `(null)` | MATCH (unchanged) |
| p4_nil_ptr (`*integer = nilptr`) | `(null)` | `(null)` | `(null)` | MATCH (unchanged) |
| p5_ptr_byte (`*byte`) | `0xADDR` | `(null)` | `0xADDR` | DIFF -> MATCH |
| p6_ptr_record (`*R`) | `0xADDR` | `(null)` | `0xADDR` | DIFF -> MATCH |
| p7_null_record_ptr (`*R = nilptr`) | `(null)` | `(null)` | `(null)` | MATCH (unchanged) |
| p8_ptr_byte_nil (`*byte = nilptr`) | `(null)` | `(null)` | `(null)` | MATCH (unchanged) |
| p9_multi (`p, q, &x, nilptr`) | `0xADDR\t(null)\t0xADDR\t(null)` | `(null)\t(null)\t(null)\t(null)` | `0xADDR\t(null)\t0xADDR\t(null)` | DIFF -> MATCH |
| p11_fieldptr (`&r.b`, `&r.a`) | `0xADDR` / `0xADDR` | `(null)` / `(null)` | `0xADDR` / `0xADDR` | DIFF -> MATCH |
| p13_ret (function returns `*integer`) | `(null)` | `(null)` | `(null)` | MATCH (unchanged) |
| p14_param (`*integer` parameter) | `0xADDR` | `(null)` | `0xADDR` | DIFF -> MATCH |
| p15_mix2 (`1, p, 2.5, "hi", true, p, nilptr`) | `1\t0xADDR\t2.5\thi\ttrue\t0xADDR\t(null)` | all `(null)` | same as oracle | DIFF -> MATCH |
| p16_addr_twice (`p, &x, &y`) | `0xADDR\t0xADDR\t0xADDR` | `(null)\t(null)\t(null)` | same as oracle | DIFF -> MATCH |

After the fix: 6 non-null probes move from DIFF to MATCH; 8 null probes stay
MATCH; no probe regresses.

## 5. Blast radius / regression check

Method: `tmp/cmp_ptr.sh` (a corrected copy of the repo's `tmp/cmp_baseline.sh`,
which had a quoting bug `$(cat "$u)"`). It runs oracle and the target binary,
compares exit codes and stdout/stderr byte-for-byte, and counts PASS / DIFF /
FAIL. A "FAIL" is a case where ours errors and the oracle does not; an
"ORACLE-ONLY-FAIL" is the reverse. Both-fail is skipped (not a regression).

### 5.1 `examples/www/*.nelua` (21 examples)

- before-fix (`tmp/nelua`): PASS=16 DIFF=5 FAIL=1
- after-fix (`tmp/nelua_fix_ptr`): PASS=16 DIFF=5 FAIL=1
- Identical. The 5 pre-existing DIFFs (escapes, floor_div, lshift,
  scope_shadow, stepped_for) and the 1 pre-existing FAIL (tetrix_rotation)
  are untouched. `nilptr_print.nelua` (`print(nilptr)`) is a PASS.

### 5.2 `tests/*.nelua` (21 tests)

- before: PASS=2 DIFF=0 FAIL=19
- after: PASS=2 DIFF=0 FAIL=19
- Identical. The 19 FAILs are pre-existing (segfaults / compile failures in
  the pre-alpha test corpus) and are not touched by this change.

### 5.3 All `tmp/probes/*.nelua` (52 probes from earlier sessions)

- before: PASS=19 DIFF=7 FAIL=35 (summary line excluded from the diff)
- after: PASS=19 DIFF=7 FAIL=35
- The verdict lists are byte-identical between before and after. The 6 new
  pointer probes I added (p1, p2, p5, p6, p9, p11) still show as DIFF in the
  raw harness only because it compares raw bytes and ASLR changes the address;
  under format normalization they are MATCH (section 4).

Net: zero regressions anywhere in the corpus. The only behavioural change is
the pointer-print probes moving toward MATCH.

## 6. Out of scope (explicit)

- **Function pointers.** The type `*function(): integer` cannot be given a
  non-null value in the oracle either: `local p: *function() = &f` is rejected
  ("no viable type conversion from 'function()' to 'pointer(function())'").
  A null one (`= nilptr`) prints `(null)` in the oracle. Our compiler has a
  separate, pre-existing defect here: it mis-emits the C type for a
  function-pointer-typed local
  (`static int64_t (*)(void)* p;` -> C compile error). That is a cgen
  type-emission bug, not a print-path bug, and is NOT addressed by this
  change. Probe p12_null_funcptr FAILs identically before and after the fix.
- **`tostring` / string coercion of pointers.** There is no `tostring`
  builtin for pointers in cgen; the string paths (concatenation, literals)
  never take a pointer. `print()` is the only route, so this fix covers it.
- **Pointer arithmetic results as print arguments** are covered: p11 prints
  interior pointers (`&r.b`, `&r.a`) correctly.
- **Cross-platform `0x` guarantee.** `%p` is used because the oracle's output
  IS glibc `%p` output and the target is this glibc. If a non-glibc backend
  is ever added, the `0x` prefix should be made explicit (e.g. `0x%lx` with a
  `uintptr_t` cast) at that point; that is a separate concern.

## 7. Done-when checklist

- [x] Oracle pointer format captured with exact stdout/exit for 7 base probes
      plus 6 edge cases, with `cat -A` and ASLR-off byte comparison.
- [x] Ours-before behavior captured with exact stdout/exit and the generated
      C proving the pointer value is computed then discarded.
- [x] Exact cgen locations identified (lines 690-720, preamble 100) and
      runtime.c locations (lines 170-172, 81).
- [x] Minimal fix prototyped in `/tmp/srcfix_ptr` and built to
      `tmp/nelua_fix_ptr` (real `src/` untouched).
- [x] All 6 non-null probes move DIFF -> MATCH under format normalization;
      8 null probes stay MATCH.
- [x] Deterministic byte comparison confirms only the address value differs.
- [x] `examples/www` before/after identical (PASS=16 DIFF=5 FAIL=1).
- [x] `tests/` before/after identical (PASS=2 DIFF=0 FAIL=19).
- [x] `tmp/probes` before/after verdict lists identical.
- [x] Out-of-scope cases listed explicitly (function pointers, tostring,
      cross-platform).

## 8. Files changed by the prototype (in `/tmp/srcfix_ptr` only)

- `/tmp/srcfix_ptr/cgen.nim` -- line 717 case routing; preamble declaration after
  line 100.
- `/tmp/srcfix_ptr/runtime.c` -- `nelua_print_ptr` definition after line 172.

No file under the real `src/` was modified.