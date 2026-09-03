## C code generator (M3-B): the analyzed-AST -> C visitor.
##
## Walks M2's `AnalyzerResult` and emits one translation unit per Nelua source
## file in the M3_design.md §3 order:
##
##   1. includes / pragmas + embedded runtime preamble
##   2. type descriptors + composite typedefs (records, unions, enums,
##      optionals, variants, multi-return structs)
##   3. forward declarations of every Nelua function
##   4. <cimport> externs
##   5. function definitions (one C function per FuncDef)
##   6. nelua_main(void) running top-level statements, then main()
##
## Consumes `analyze` (AnalyzerResult), `attrOf` (Attr), the types.nim query
## surface (neluaTypeName / returnsOf / argsOf / size / codename / ...), and the
## M3-A modules `cgen_types` (cType / cConstType / cFuncType / multiRetTag) and
## `cemitter` (cBoolLit / cNilptrLit / cNumberLit / cStringLit / cIdent / cCast
## / cQualifiers).
##
## NOTE on the analyzer contract: M2's `Attr.conv` is declared but never
## populated by the current analyzer (binary-op conversions are computed and
## discarded), and `AnalyzerResult` has no `specials` field (polymorphic `auto`
## params lower to `any`/`void*` rather than being monomorphized).  The visitor
## therefore recomputes conversions via `sema.convert` at use sites and emits
## `auto` params as `void*`.  These two §10.4 lowerings are reported as gaps.

import types
import sema
import analyzer
import cgen_types
import cemitter
import ast
import os
import strutils
import tables
import config

# ---------------------------------------------------------------------------
# Embedded runtime preamble.
#
# `src/runtime.c` is a later milestone; this inline preamble makes every
# emitted translation unit self-contained and shape-checkable.  It defines the
# `nl*` typedefs the visitor names, the builtin forward declarations, and the
# `nlcheck_*` narrow-check macros.  It is prepended verbatim to the output.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Runtime preamble.
#
# Every emitted translation unit used to prepend a fixed `RUNTIME_C` block of
# *declarations* (extern prototypes for nelua_print_*, nlany_*, nlstr, ...) and
# linked `src/runtime.c` + `-lm` to resolve them.  This task inlines the runtime
# per-TU instead: `genPreamble(refs)` emits a `static` DEFINITION of only the
# helpers the TU actually calls (tracked in `Gen.refs` during codegen), so each
# TU is self-contained and links against nothing outside itself.  `-lm` goes
# with the runtime link: the only math symbol is `pow`, wrapped by `nlpow`.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Generator state
# ---------------------------------------------------------------------------

type
  DeferScopeKind = enum
    dkBlock
    dkFunc
    dkLoop
  # Runtime helpers the generated translation unit actually calls.  The
  # preamble emits a `static` DEFINITION (not a declaration) for each member
  # present in this set, so every TU is self-contained and links against
  # nothing outside itself.  Members not present are omitted entirely.
  RuntimeHelper = enum
    rhPrintInt, rhPrintUint, rhPrintDouble, rhPrintString, rhPrintBool,
    rhPrintNil, rhPrintPtr, rhPrintSep, rhPrintNewline, rhPrintAny, rhPrintFloat,
    rhAnyFromNil, rhAnyFromBool, rhAnyFromInt, rhAnyFromUint, rhAnyFromNum,
    rhAnyFromString, rhAnyFromPtr,
    rhAnyLoadInt, rhAnyLoadUint, rhAnyLoadNum, rhAnyLoadBool, rhAnyLoadString,
    rhAnyLoadPtr, rhAnyEq,
    rhStr, rhStrConcat, rhStrFree, rhIdiv, rhMod, rhPow, rhLen, rhClose,
    rhNltypeInt, rhNltypeDouble, rhNltypeBool, rhNltypeString,
    rhMath, rhCheckInt, rhCheckUint, rhCheckFloat
  Gen = object
    ctx: AnalyzerContext
    release*: bool
    nochecks*: bool
    buf: string
    indent: int
    inFunc: bool               ## true while emitting a function body (locals)
    currentReturns: seq[Type]  ## return types of the function being emitted
    mrCounter: int             ## unique temp name counter for multi-returns
    refs: set[RuntimeHelper]   ## runtime helpers this TU actually calls
    unsupported: bool
    unsupportedMsg: string
    typeSeen: Table[int, bool]
    typesSeq: seq[Type]
    multiRetSeen: Table[string, bool]
    multiRetList: seq[seq[Type]]
    deferStack: seq[(DeferScopeKind, seq[Node])]
    funcDefs: seq[Node]

proc g(s: var Gen, text: string) =
  s.buf.add text

proc use(s: var Gen, h: RuntimeHelper) =
  ## Record that the generated TU calls runtime helper `h`.  The preamble is
  ## built from this set (see genPreamble), so only helpers actually used are
  ## emitted as `static` definitions -- a TU that references nothing emits no
  ## helper definitions at all and still links.
  s.refs.incl h

proc notePrintHelper(s: var Gen, helper: string) =
  ## Resolve a `nelua_print_*` codename to its RuntimeHelper and record it.
  case helper
  of "nelua_print_int64": s.use rhPrintInt
  of "nelua_print_uint64": s.use rhPrintUint
  of "nelua_print_double": s.use rhPrintDouble
  of "nelua_print_string": s.use rhPrintString
  of "nelua_print_bool": s.use rhPrintBool
  of "nelua_print_nil": s.use rhPrintNil
  of "nelua_print_ptr": s.use rhPrintPtr
  of "nelua_print_sep": s.use rhPrintSep
  of "nelua_print_newline": s.use rhPrintNewline
  of "nelua_print_any": s.use rhPrintAny
  of "nelua_print_float": s.use rhPrintFloat
  else: discard

# ---------------------------------------------------------------------------
# Per-TU runtime preamble.
#
# Builds the C header block prepended to every emitted translation unit.  Only
# the helpers in `refs` get a `static` DEFINITION here; everything else is
# omitted, so a TU that references no runtime helper emits no helper
# definitions at all and still links.  The exception/panic inline block
# (nelua_abort, nelua_error_line, nelua_panic_string, nelua_assert_line) is
# always emitted: it is fully self-contained (stdio/stdlib, always included).
# Bodies are copied verbatim from src/runtime.c; only the linkage changed from
# extern-linked to static-per-TU.
# ---------------------------------------------------------------------------
proc genPreamble(refs: set[RuntimeHelper]): string =
  var s: string
  s.add "/* === nelua runtime (per-TU inlined; no separate runtime.c link) === */\n"
  s.add "#include <stdint.h>\n"
  s.add "#include <stdbool.h>\n"
  s.add "#include <stddef.h>\n"
  s.add "#include <stdarg.h>\n"
  s.add "#include <string.h>\n"
  s.add "#include <stdio.h>\n"
  s.add "#include <stdlib.h>\n"
  if rhMath in refs:
    s.add "#include <math.h>\n"
  s.add "\n"
  s.add "typedef struct { const char* data; size_t size; } nlstring;\n"
  s.add "typedef void* nilptr;\n"
  s.add "typedef enum {\n"
  s.add "  NLANY_NIL = 0,\n"
  s.add "  NLANY_BOOL, NLANY_INT, NLANY_UINT, NLANY_NUM,\n"
  s.add "  NLANY_STRING, NLANY_POINTER, NLANY_TABLE, NLANY_FUNC, NLANY_TYPE\n"
  s.add "} nlany_tag;\n"
  s.add "typedef struct {\n"
  s.add "  nlany_tag tag;\n"
  s.add "  union {\n"
  s.add "    uint8_t b; int64_t i; uint64_t u; double n;\n"
  s.add "    nlstring s; void* p;\n"
  s.add "  } as;\n"
  s.add "} nlany;\n"
  s.add "struct nltype;\n"
  s.add "typedef struct nltype nltype;\n"
  s.add "#ifndef NELUA_INLINE\n"
  s.add "#define NELUA_INLINE inline\n"
  s.add "#endif\n"
  s.add "\n"
  # Exception / panic primitives: always emitted, fully self-contained.
  s.add "static inline void nelua_abort(void) {\n"
  s.add "  abort();\n"
  s.add "}\n"
  s.add "\n"
  s.add "static inline void nelua_error_line(nlstring msg) {\n"
  s.add "  fwrite(\"runtime error: \", 1, sizeof(\"runtime error: \") - 1, stderr);\n"
  s.add "  if (msg.size > 0 && msg.data) {\n"
  s.add "    fwrite(msg.data, 1, msg.size, stderr);\n"
  s.add "  }\n"
  s.add "  fwrite(\"\\n\", 1, 1, stderr);\n"
  s.add "  fflush(stderr);\n"
  s.add "  nelua_abort();\n"
  s.add "}\n"
  s.add "\n"
  s.add "static inline void nelua_panic_string(nlstring s) {\n"
  s.add "  if (s.size > 0 && s.data) {\n"
  s.add "    fwrite(s.data, 1, s.size, stderr);\n"
  s.add "  }\n"
  s.add "  fwrite(\"\\n\", 1, 1, stderr);\n"
  s.add "  fflush(stderr);\n"
  s.add "  nelua_abort();\n"
  s.add "}\n"
  s.add "\n"
  s.add "static inline void nelua_assert_line(bool cond, nlstring msg) {\n"
  s.add "  if (!cond) {\n"
  s.add "    nelua_error_line(msg);\n"
  s.add "  }\n"
  s.add "}\n"
  s.add "\n"
  # Print family: emitted only when at least one print helper is referenced.
  # nl_out is per-TU static (stdout is not a compile-time constant, so it is
  # wired up by a constructor rather than a static initializer).
  if {rhPrintInt, rhPrintUint, rhPrintDouble, rhPrintString, rhPrintBool,
      rhPrintNil, rhPrintPtr, rhPrintSep, rhPrintNewline, rhPrintAny,
      rhPrintFloat} * refs != {}:
    s.add "static FILE* nl_out;\n"
    s.add "static void nl_init_out(void) __attribute__((constructor));\n"
    s.add "static void nl_init_out(void) { nl_out = stdout; }\n"
    s.add "\n"
    if rhPrintFloat in refs:
      s.add "static inline void nelua_print_float(float v) {\n"
      s.add "  char buf[64];\n"
      s.add "  snprintf(buf, sizeof buf, \"%.7g\", (double)v);\n"
      s.add "  if (strcmp(buf, \"inf\") != 0 && strcmp(buf, \"-inf\") != 0 &&\n"
      s.add "      strcmp(buf, \"nan\") != 0 && strcmp(buf, \"-nan\") != 0 &&\n"
      s.add "      strchr(buf, '.') == NULL && strchr(buf, 'e') == NULL &&\n"
      s.add "      strchr(buf, 'E') == NULL) {\n"
      s.add "    strcat(buf, \".0\");\n"
      s.add "  }\n"
      s.add "  fputs(buf, nl_out);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintInt in refs or rhPrintAny in refs:
      s.add "static void nelua_print_int64(int64_t v) {\n"
      s.add "  fprintf(nl_out, \"%lld\", (long long)v);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintUint in refs or rhPrintAny in refs:
      s.add "static void nelua_print_uint64(uint64_t v) {\n"
      s.add "  fprintf(nl_out, \"%llu\", (long long)v);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintDouble in refs or rhPrintAny in refs:
      s.add "static void nelua_print_double(double d) {\n"
      s.add "  char buf[64];\n"
      s.add "  snprintf(buf, sizeof buf, \"%.14g\", d);\n"
      s.add "  if (strcmp(buf, \"inf\") != 0 && strcmp(buf, \"-inf\") != 0 &&\n"
      s.add "      strcmp(buf, \"nan\") != 0 && strcmp(buf, \"-nan\") != 0 &&\n"
      s.add "      strchr(buf, '.') == NULL && strchr(buf, 'e') == NULL &&\n"
      s.add "      strchr(buf, 'E') == NULL) {\n"
      s.add "    strcat(buf, \".0\");\n"
      s.add "  }\n"
      s.add "  fputs(buf, nl_out);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintString in refs or rhPrintAny in refs:
      s.add "static void nelua_print_string(nlstring s) {\n"
      s.add "  if (s.data != NULL && s.size > 0) {\n"
      s.add "    fwrite(s.data, 1, s.size, nl_out);\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintBool in refs or rhPrintAny in refs:
      s.add "static void nelua_print_bool(int b) {\n"
      s.add "  fputs(b ? \"true\" : \"false\", nl_out);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintNil in refs or rhPrintAny in refs:
      s.add "static void nelua_print_nil(void) {\n"
      s.add "  fputs(\"(null)\", nl_out);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintPtr in refs:
      s.add "static void nelua_print_ptr(void* v) {\n"
      s.add "  if (v == NULL) {\n"
      s.add "    fputs(\"(null)\", nl_out);\n"
      s.add "  } else {\n"
      s.add "    fprintf(nl_out, \"%p\", v);\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintSep in refs:
      s.add "static void nelua_print_sep(void) {\n"
      s.add "  fputc('\\t', nl_out);\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintNewline in refs:
      s.add "static void nelua_print_newline(void) {\n"
      s.add "  fputc('\\n', nl_out);\n"
      s.add "  fflush(nl_out);\n"
      s.add "}\n"
      s.add "\n"
  # `any` helpers.
  if {rhAnyFromNil, rhAnyFromBool, rhAnyFromInt, rhAnyFromUint, rhAnyFromNum,
      rhAnyFromString, rhAnyFromPtr, rhAnyLoadInt, rhAnyLoadUint, rhAnyLoadNum,
      rhAnyLoadBool, rhAnyLoadString, rhAnyLoadPtr, rhAnyEq, rhPrintAny} * refs != {}:
    if rhAnyFromNil in refs:
      s.add "static nlany nlany_from_nil(void) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_NIL;\n"
      s.add "  r.as.i = 0;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromBool in refs:
      s.add "static nlany nlany_from_bool(uint8_t v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_BOOL;\n"
      s.add "  r.as.b = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromInt in refs:
      s.add "static nlany nlany_from_int(int64_t v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_INT;\n"
      s.add "  r.as.i = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromUint in refs:
      s.add "static nlany nlany_from_uint(uint64_t v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_UINT;\n"
      s.add "  r.as.u = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromNum in refs:
      s.add "static nlany nlany_from_num(double v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_NUM;\n"
      s.add "  r.as.n = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromString in refs:
      s.add "static nlany nlany_from_string(nlstring v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = NLANY_STRING;\n"
      s.add "  r.as.s = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyFromPtr in refs:
      s.add "static nlany nlany_from_ptr(void* v) {\n"
      s.add "  nlany r;\n"
      s.add "  r.tag = (v == NULL) ? NLANY_NIL : NLANY_POINTER;\n"
      s.add "  r.as.p = v;\n"
      s.add "  return r;\n"
      s.add "}\n"
      s.add "\n"
    if rhPrintAny in refs:
      s.add "static void nelua_print_any(nlany v) {\n"
      s.add "  switch (v.tag) {\n"
      s.add "    case NLANY_NIL:    nelua_print_nil(); break;\n"
      s.add "    case NLANY_BOOL:   nelua_print_bool(v.as.b); break;\n"
      s.add "    case NLANY_INT:    nelua_print_int64(v.as.i); break;\n"
      s.add "    case NLANY_UINT:   nelua_print_uint64(v.as.u); break;\n"
      s.add "    case NLANY_NUM:    nelua_print_double(v.as.n); break;\n"
      s.add "    case NLANY_STRING: nelua_print_string(v.as.s); break;\n"
      s.add "    default:           nelua_print_nil(); break;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadInt in refs:
      s.add "static int64_t nlany_load_int(nlany v) {\n"
      s.add "  switch (v.tag) {\n"
      s.add "    case NLANY_INT:  return v.as.i;\n"
      s.add "    case NLANY_UINT: return (int64_t)v.as.u;\n"
      s.add "    case NLANY_BOOL: return v.as.b;\n"
      s.add "    case NLANY_NUM:  return (int64_t)v.as.n;\n"
      s.add "    default:         return 0;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadUint in refs:
      s.add "static uint64_t nlany_load_uint(nlany v) {\n"
      s.add "  switch (v.tag) {\n"
      s.add "    case NLANY_UINT: return v.as.u;\n"
      s.add "    case NLANY_INT:  return (uint64_t)v.as.i;\n"
      s.add "    case NLANY_BOOL: return v.as.b;\n"
      s.add "    case NLANY_NUM:  return (uint64_t)v.as.n;\n"
      s.add "    default:         return 0;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadNum in refs:
      s.add "static double nlany_load_num(nlany v) {\n"
      s.add "  switch (v.tag) {\n"
      s.add "    case NLANY_NUM:  return v.as.n;\n"
      s.add "    case NLANY_INT:  return (double)v.as.i;\n"
      s.add "    case NLANY_UINT: return (double)v.as.u;\n"
      s.add "    case NLANY_BOOL: return (double)v.as.b;\n"
      s.add "    default:         return 0.0;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadBool in refs:
      s.add "static uint8_t nlany_load_bool(nlany v) {\n"
      s.add "  switch (v.tag) {\n"
      s.add "    case NLANY_BOOL: return v.as.b;\n"
      s.add "    case NLANY_INT:  return v.as.i != 0;\n"
      s.add "    case NLANY_UINT: return v.as.u != 0;\n"
      s.add "    case NLANY_NUM:  return v.as.n != 0.0;\n"
      s.add "    default:         return 0;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadString in refs:
      s.add "static nlstring nlany_load_string(nlany v) {\n"
      s.add "  if (v.tag == NLANY_STRING) return v.as.s;\n"
      s.add "  nlstring empty; empty.data = NULL; empty.size = 0; return empty;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyLoadPtr in refs:
      s.add "static void* nlany_load_ptr(nlany v) {\n"
      s.add "  if (v.tag == NLANY_POINTER) return v.as.p;\n"
      s.add "  return NULL;\n"
      s.add "}\n"
      s.add "\n"
    if rhAnyEq in refs:
      s.add "static bool nlany_eq(nlany a, nlany b) {\n"
      s.add "  if (a.tag != b.tag) return false;\n"
      s.add "  switch (a.tag) {\n"
      s.add "    case NLANY_NIL:    return true;\n"
      s.add "    case NLANY_BOOL:   return a.as.b == b.as.b;\n"
      s.add "    case NLANY_INT:    return a.as.i == b.as.i;\n"
      s.add "    case NLANY_UINT:   return a.as.u == b.as.u;\n"
      s.add "    case NLANY_NUM:    return a.as.n == b.as.n;\n"
      s.add "    case NLANY_STRING: return a.as.s.data == b.as.s.data &&\n"
      s.add "                         a.as.s.size == b.as.s.size;\n"
      s.add "    case NLANY_POINTER: return a.as.p == b.as.p;\n"
      s.add "    default:           return false;\n"
      s.add "  }\n"
      s.add "}\n"
      s.add "\n"
  # String helpers.
  if rhStr in refs:
    s.add "static nlstring nlstr(const char* s) {\n"
    s.add "  nlstring r;\n"
    s.add "  r.data = s;\n"
    s.add "  r.size = s ? strlen(s) : 0;\n"
    s.add "  return r;\n"
    s.add "}\n"
    s.add "\n"
  if rhStrConcat in refs:
    s.add "static nlstring nlstring_concat(nlstring a, nlstring b) {\n"
    s.add "  nlstring r;\n"
    s.add "  r.size = a.size + b.size;\n"
    s.add "  r.data = (const char*)malloc(r.size ? r.size : 1);\n"
    s.add "  if (r.data) {\n"
    s.add "    if (a.size) memcpy((void*)r.data, a.data, a.size);\n"
    s.add "    if (b.size) memcpy((void*)r.data + a.size, b.data, b.size);\n"
    s.add "  } else {\n"
    s.add "    r.data = NULL;\n"
    s.add "    r.size = 0;\n"
    s.add "  }\n"
    s.add "  return r;\n"
    s.add "}\n"
    s.add "\n"
  if rhStrFree in refs:
    s.add "static void nlstring_free(nlstring* s) {\n"
    s.add "  if (s) {\n"
    s.add "    free((void*)s->data);\n"
    s.add "    s->data = NULL;\n"
    s.add "    s->size = 0;\n"
    s.add "  }\n"
    s.add "}\n"
    s.add "\n"
  if rhLen in refs:
    s.add "static int64_t nllen(nlstring s) {\n"
    s.add "  return (int64_t)s.size;\n"
    s.add "}\n"
    s.add "\n"
  if rhIdiv in refs:
    s.add "static int64_t nlidiv(int64_t a, int64_t b) {\n"
    s.add "  if (b == 0) return 0;\n"
    s.add "  int64_t q = a / b;\n"
    s.add "  int64_t r = a % b;\n"
    s.add "  if (r != 0 && ((a < 0) != (b < 0))) q -= 1;\n"
    s.add "  return q;\n"
    s.add "}\n"
    s.add "\n"
  if rhMod in refs:
    s.add "static int64_t nlmod(int64_t a, int64_t b) {\n"
    s.add "  if (b == 0) return 0;\n"
    s.add "  int64_t r = a % b;\n"
    s.add "  if (r != 0 && ((a < 0) != (b < 0))) r += b;\n"
    s.add "  return r;\n"
    s.add "}\n"
    s.add "\n"
  if rhPow in refs:
    s.add "static NELUA_INLINE double nlpow(double a, double b) {\n"
    s.add "  return pow(a, b);\n"
    s.add "}\n"
    s.add "\n"
  if rhClose in refs:
    s.add "static void nlclose(void* p) {\n"
    s.add "  free(p);\n"
    s.add "}\n"
    s.add "\n"
  # Builtin type descriptors (vestigial; nothing references them today, so this
  # block is never emitted -- kept for completeness if a future codegen path
  # takes a value of type `type`).
  if {rhNltypeInt, rhNltypeDouble, rhNltypeBool, rhNltypeString} * refs != {}:
    if rhNltypeInt in refs:
      s.add "static const struct nltype nltype_of_int64 = { \"int64\", sizeof(int64_t), _Alignof(int64_t), NULL };\n"
    if rhNltypeDouble in refs:
      s.add "static const struct nltype nltype_of_double = { \"double\", sizeof(double), _Alignof(double), NULL };\n"
    if rhNltypeBool in refs:
      s.add "static const struct nltype nltype_of_bool = { \"bool\", sizeof(uint8_t), _Alignof(uint8_t), NULL };\n"
    if rhNltypeString in refs:
      s.add "static const struct nltype nltype_of_string = { \"string\", sizeof(nlstring), _Alignof(nlstring), NULL };\n"
    s.add "\n"
  # Narrow-check macros + overflow helpers.  When a check helper is referenced
  # the macros call the (static, per-TU) overflow helpers; otherwise the
  # macros elide to a bare cast and reference no helper at all.
  if {rhCheckInt, rhCheckUint, rhCheckFloat} * refs != {}:
    s.add "static void nlcheck_int_overflow(int64_t x, const char* what) {\n"
    s.add "  (void)x; (void)what;\n"
    s.add "}\n"
    s.add "static void nlcheck_uint_overflow(uint64_t x, const char* what) {\n"
    s.add "  (void)x; (void)what;\n"
    s.add "}\n"
    s.add "static void nlcheck_float_overflow(double x, const char* what) {\n"
    s.add "  (void)x; (void)what;\n"
    s.add "}\n"
    s.add "#define nlcheck_int(x)   (nlcheck_int_overflow((int64_t)(x), \"int\"), (int64_t)(x))\n"
    s.add "#define nlcheck_uint(x)  (nlcheck_uint_overflow((uint64_t)(x), \"uint\"), (uint64_t)(x))\n"
    s.add "#define nlcheck_float(x) (nlcheck_float_overflow((double)(x), \"float\"), (double)(x))\n"
  else:
    s.add "#define nlcheck_int(x)   ((int64_t)(x))\n"
    s.add "#define nlcheck_uint(x)  ((uint64_t)(x))\n"
    s.add "#define nlcheck_float(x) ((double)(x))\n"
  s.add "\n"
  return s

proc line(s: var Gen, text: string) =
  s.buf.add "  ".repeat(s.indent) & text & "\n"

proc push(s: var Gen) = inc s.indent
proc pop(s: var Gen) = dec s.indent

proc pushDefer(s: var Gen, kind: DeferScopeKind) =
  ## Push a new defer scope onto the stack.  `kind` records whether this scope
  ## is a function body (defers run on `return`), a loop body (defers run on
  ## `break`/`continue`) or an ordinary block (defers run only at normal scope
  ## termination), so that `return`/`break`/`continue` know how far to drain.
  s.deferStack.add (kind, @[])

proc popDefer(s: var Gen) =
  discard s.deferStack.pop()

# Forward declarations for the mutually-recursive expression/statement visitors.
proc genExpr(s: var Gen, node: Node): string
proc genBinaryOp(s: var Gen, node: Node): string
proc genUnaryOp(s: var Gen, node: Node): string
proc genCall(s: var Gen, node: Node): string
proc genCallMethod(s: var Gen, node: Node): string
proc genDotIndex(s: var Gen, node: Node): string
proc genMetaCall(s: var Gen, recv: Node, methodName: string,
                 argNodes: seq[Node] = @[]): string
proc cDecl(t: Type, name: string): string
proc genKeyIndex(s: var Gen, node: Node): string
proc genInitList(s: var Gen, node: Node): string
proc genInitListBraces(s: var Gen, node: Node, et: Type): string
proc genArrayInitFromExpr(s: var Gen, src: string, at: Type): string
proc genLvalue(s: var Gen, node: Node): string
proc genStmt(s: var Gen, node: Node)
proc genStmts(s: var Gen, node: Node)
proc genScope(s: var Gen, node: Node, kind: DeferScopeKind = dkBlock)
proc genBody(s: var Gen, node: Node)
proc coerce(s: var Gen, expr: string, fromT: Type, toT: Type): string

proc runDefersUpTo(s: var Gen, targetKind: DeferScopeKind) =
  ## Run every pending defer from the innermost scope outward, stopping after
  ## the first scope whose kind equals `targetKind` (that scope is included).
  ##
  ## The drained scopes' defer lists are *not* cleared: `genScope` still emits
  ## each defer body at its normal scope-exit point.  After a `return`/`break`/
  ## `continue` those exit points are unreachable dead code, so the defer body
  ## runs exactly once at runtime -- emitted here for the jump path, and again
  ## (harmlessly) for the fall-through path that is never taken.
  var i = s.deferStack.len - 1
  while i >= 0:
    for j in countdown(s.deferStack[i][1].len - 1, 0):
      s.genBody(s.deferStack[i][1][j].children[0])
    if s.deferStack[i][0] == targetKind:
      break
    dec i
proc arithCast(s: var Gen, expr: string, fromT: Type, toT: Type): string

# ---------------------------------------------------------------------------
# Type collection: walk the analyzed tree, register every composite type that
# needs a typedef so it can be emitted before the functions that use it.
# ---------------------------------------------------------------------------

proc collectType(s: var Gen, t: Type) =
  if t == nil: return
  case t.kind
  of tkRecord, tkUnion:
    if s.typeSeen.hasKey(t.typeid): return
    s.typeSeen[t.typeid] = true
    for f in t.fields:
      s.collectType(f.typ)
    s.typesSeq.add t
  of tkEnum:
    if s.typeSeen.hasKey(t.typeid): return
    s.typeSeen[t.typeid] = true
    s.collectType(t.subtype)
    s.typesSeq.add t
  of tkArray:
    s.collectType(t.subtype)
  of tkOptional:
    s.collectType(t.subtype)
  of tkVariant:
    for a in t.args:
      s.collectType(a)
    if s.typeSeen.hasKey(t.typeid): return
    s.typeSeen[t.typeid] = true
    s.typesSeq.add t
  of tkTypeof:
    s.collectType(t.subtype)
  of tkFunction:
    for a in t.args:
      s.collectType(a)
    for r in t.returns:
      s.collectType(r)
    if t.returns.len > 1:
      let tag = multiRetTag(t.returns)
      if not s.multiRetSeen.hasKey(tag):
        s.multiRetSeen[tag] = true
        s.multiRetList.add t.returns
  else:
    discard

proc collectNode(s: var Gen, node: Node) =
  if node == nil: return
  let a = s.ctx.attrOf.getOrDefault(node)
  if a != nil:
    s.collectType(a.typ)
    if a.calleeType != nil: s.collectType(a.calleeType)
    if a.parentType != nil: s.collectType(a.parentType)
    if a.conv != nil and a.conv.via != nil: s.collectType(a.conv.via)
  for c in node.children:
    s.collectNode(c)

proc collectFuncDefs(node: Node, outSeq: var seq[Node]) =
  if node == nil: return
  if node.kind == nkFuncDef:
    outSeq.add node
  for c in node.children:
    collectFuncDefs(c, outSeq)

# ---------------------------------------------------------------------------
# Composite typedef emission
# ---------------------------------------------------------------------------

proc emitTypedef(s: var Gen, t: Type) =
  case t.kind
  of tkRecord:
    let tag = cTag(t)
    s.line "typedef struct " & tag & " {"
    s.push
    for f in t.fields:
      s.line cDecl(f.typ, cIdent(f.name)) & ";"
    s.pop
    s.line "} " & tag & ";"
  of tkUnion:
    let tag = cTag(t)
    s.line "typedef union " & tag & " {"
    s.push
    for f in t.fields:
      s.line cDecl(f.typ, cIdent(f.name)) & ";"
    s.pop
    s.line "} " & tag & ";"
  of tkEnum:
    # C1: nominal/bare `@enum` lowers to a plain typedef of the underlying
    # primitive with NO C enum body -- the enum fields are compile-time
    # constants folded by the analyzer (matches the oracle's
    # `typedef uint32_t tmp_probe_tag_MASK;` shape).
    let tag = cTag(t)
    let ut = if t.subtype != nil: t.subtype else: BuiltinTypes["integer"]
    s.line "typedef " & cType(ut) & " " & tag & ";"
  of tkOptional:
    let sub = if t.subtype != nil: t.subtype else: BuiltinTypes["void"]
    let tag = "nlopt_" & cIdent(cType(sub))
    s.line "typedef struct {"
    s.push
    s.line cType(sub) & " value;"
    s.line "bool has;"
    s.pop
    s.line "} " & tag & ";"
  of tkVariant:
    let tag = "nlvariant" & $t.typeid
    s.line "typedef struct { void* data; int tag; } " & tag & ";"
  else:
    discard

proc emitMultiRet(s: var Gen, rets: seq[Type]) =
  let tag = multiRetTag(rets)
  s.line "typedef struct " & tag & " {"
  s.push
  for i, r in rets:
    s.line cType(r) & " field" & $i & ";"
  s.pop
  s.line "} " & tag & ";"

proc fieldOf(t: Type, name: string): Type =
  for f in t.fields:
    if f.name == name: return f.typ
  return nil

proc hasArrayField(t: Type): bool =
  ## True if `t` (a record/union) declares any field whose type is an array.
  ## Such a literal cannot be assigned as a whole in C, so genVarDecl lowers
  ## it to a memcpy instead.
  for f in fieldsOf(t):
    if f.typ != nil and f.typ.kind == tkArray:
      return true
  return false

# ---------------------------------------------------------------------------
# Conversion / narrow-check lowering (M3_design §4)
# ---------------------------------------------------------------------------

proc coerce(s: var Gen, expr: string, fromT: Type, toT: Type): string =
  if fromT == nil or toT == nil: return expr
  if fromT == toT: return expr
  # A nelua string literal assigned to a `cstring` (const char*) lowers to the
  # bare C string literal.  The literal is emitted as `nlstr("...")` by genExpr
  # and `convert` reports no conversion (ckNone), so the generic path cast it
  # to `(const char*)(nlstr("..."))` -- invalid C, since nlstring is a struct.
  # Unwrap the nlstr(...) wrapper and hand back the inner literal.
  if toT.isCstring and fromT.kind == tkString and
     expr.startsWith("nlstr(") and expr.endsWith(")"):
    return expr["nlstr(".len ..< expr.len - 1]
  let conv = convert(fromT, toT, false)
  case conv.kind
  of ckIdentity:
    return expr
  of ckNone:
    # record value -> pointer-to-record: emit address-of instead of a cast
    if fromT.isRecord and toT.isPointer and fromT == toT.subtype:
      return "&" & expr
    # incompatible scalar pair: emit an explicit cast so the C stays valid
    return cCast(toT, expr)
  of ckExplicit:
    return cCast(toT, expr)
  of ckImplicit:
    if conv.check:
      if not s.nochecks:
        if fromT.isIntegral and toT.isIntegral:
          s.use rhCheckInt
          return "nlcheck_int(" & cCast(toT, expr) & ")"
        elif fromT.isFloat or toT.isFloat:
          s.use rhCheckFloat
          return "nlcheck_float(" & cCast(toT, expr) & ")"
        else:
          return cCast(toT, expr)
      return cCast(toT, expr)
    else:
      # record value -> pointer-to-record: implicit address-taking
      if fromT.isRecord and toT.isPointer and fromT == toT.subtype:
        return "&" & expr
      return expr   # widening: C's own promotion applies
  of ckNarrow:
    return cCast(toT, expr)
  of ckAnyStore:
    # T -> any: wrap the typed expression in the matching tagged-store helper.
    if fromT.isNiltype or fromT.isNilptr:
      s.use rhAnyFromNil
      return "nlany_from_nil()"
    if fromT.isBoolean:
      s.use rhAnyFromBool
      return "nlany_from_bool(" & expr & ")"
    if fromT.isStringy:
      s.use rhAnyFromString
      return "nlany_from_string(" & expr & ")"
    if fromT.isIntegral:
      s.use (if fromT.isUnsigned: rhAnyFromUint else: rhAnyFromInt)
      return (if fromT.isUnsigned: "nlany_from_uint(" else: "nlany_from_int(") & expr & ")"
    if fromT.isFloat:
      s.use rhAnyFromNum
      return "nlany_from_num(" & expr & ")"
    if fromT.isPointer or fromT.isFunction:
      s.use rhAnyFromPtr
      return "nlany_from_ptr(" & expr & ")"
    # record / table value -> any: store its address (a record value has no
    # single address until it is on the stack; the sources here are lvalues --
    # a variable, a field, or a compound literal -- so address-of is valid).
    s.use rhAnyFromPtr
    return "nlany_from_ptr((void*)(&(" & expr & ")))"
  of ckAnyLoad:
    # any -> T: extract the payload with a runtime tag check.
    if toT.isStringy:
      s.use rhAnyLoadString
      return "nlany_load_string(" & expr & ")"
    if toT.isBoolean:
      s.use rhAnyLoadBool
      return "nlany_load_bool(" & expr & ")"
    if toT.isIntegral:
      s.use (if toT.isUnsigned: rhAnyLoadUint else: rhAnyLoadInt)
      return (if toT.isUnsigned: "nlany_load_uint(" else: "nlany_load_int(") & expr & ")"
    if toT.isFloat:
      s.use rhAnyLoadNum
      return "nlany_load_num(" & expr & ")"
    s.use rhAnyLoadPtr
    return "nlany_load_ptr(" & expr & ")"   # phase 2b placeholder

proc realType(s: var Gen, node: Node): Type =
  ## Resolve the concrete (C-level) type of `node`, walking index/field
  ## accesses down to their element/field type.
  ##
  ## The analyzer types a nested array index `x[i][j]` (e.g. on a
  ## `[4][4]byte`) as `any`, but the C expression is still the element value.
  ## Codegen that needs the real type -- notably the `any` print arm, which
  ## must wrap the value in a tagged-store helper before passing it to
  ## `nelua_print_any` -- re-derives it here.  A genuine `any` value (already
  ## `nlany` in C) resolves to `any` and coerces to itself unchanged.
  if node == nil: return nil
  case node.kind:
  of nkId:
    let a = s.ctx.attrOf.getOrDefault(node)
    if a != nil and a.typ != nil: return a.typ
    let sym = s.ctx.symOf.getOrDefault(node)
    if sym != nil and sym.typ != nil: return sym.typ
    return nil
  of nkDotIndex:
    let a = s.ctx.attrOf.getOrDefault(node)
    if a != nil and a.typ != nil: return a.typ
    return nil
  of nkKeyIndex, nkColonIndex:
    # newKeyIndex/newColonIndex store (key, base) -> children[0]=key,
    # children[1]=base.
    if node.children.len < 2: return BuiltinTypes["any"]
    let bt = s.realType(node.children[1])
    if bt != nil and bt.kind == tkPointer and bt.subtype != nil and
       bt.subtype.kind == tkArray and bt.subtype.subtype != nil:
      return bt.subtype.subtype
    if bt != nil and bt.kind == tkArray and bt.subtype != nil:
      return bt.subtype
    # M4: a record with an `__index` metamethod resolves to that method's
    # return type (the analyzer types the index as `any`, but the emitted C
    # expression is the metamethod call, so the print/any arm must know the
    # real type to wrap it correctly).
    if bt != nil and bt.kind == tkRecord and bt.methods.hasKey("__index"):
      let md = bt.methods["__index"]
      if md.ftype != nil and md.ftype.returns.len > 0:
        return md.ftype.returns[0]
    return BuiltinTypes["any"]
  of nkParen:
    if node.children.len > 0: return s.realType(node.children[0])
    return nil
  of nkCall, nkCallMethod:
    let a = s.ctx.attrOf.getOrDefault(node)
    if a != nil and a.typ != nil and a.typ.kind != tkVoid:
      return a.typ
    return BuiltinTypes["any"]
  else:
    let a = s.ctx.attrOf.getOrDefault(node)
    if a != nil: return a.typ
    return nil

# ---------------------------------------------------------------------------
# Expression lowering
# ---------------------------------------------------------------------------

proc stripStr(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    return s[1 ..< s.len - 1]
  if s.len >= 2 and s[0] == '\'' and s[^1] == '\'':
    return s[1 ..< s.len - 1]
  return s

proc genExpr(s: var Gen, node: Node): string =
  if node == nil: return ""
  let a = s.ctx.attrOf.getOrDefault(node)
  case node.kind
  of nkNumber:
    let t = if a != nil: a.typ else: nil
    return cNumberLit(t, node.str)
  of nkString:
    s.use rhStr
    return "nlstr(" & cStringLit(stripStr(node.str)) & ")"
  of nkBoolean:
    return cBoolLit(node.boolVal)
  of nkNil:
    return "NULL"
  of nkNilptr:
    return cNilptrLit()
  of nkVarargs:
    return "/*...*/"
  of nkId:
    let cn = if a != nil and a.codename != "": a.codename else: cIdent(node.str)
    if a != nil and a.typ != nil and a.typ.kind == tkMetatype:
      return "/*type " & node.str & "*/"
    # A comptime constant reference is folded to its literal value by the
    # analyzer (see analyzeExpr nkId / analyzeVarDecl); inline it here so
    # top-level `local N <comptime> = 624` needs no `static` storage and no
    # forward-reference.  The oracle emits the value directly, e.g. `624U`.
    # A function symbol reference is also flagged comptime, but its `value` is
    # the nelua type annotation (e.g. "g: function(): int64") -- dump metadata,
    # not a foldable C literal.  Skip the fold for those so a function value
    # used as a value (RHS of an assignment, a call argument) lowers to its
    # mangled codename instead of leaking annotation text into the C output.
    if a != nil and a.comptime and a.value != "" and
       (a.typ == nil or a.typ.kind != tkFunction):
      # A comptime string/cstring value is stored as the raw stripped content
      # (e.g. "1.0" -> `1.0`); re-wrap it as a C `nlstr(...)` literal so it
      # lowers to `nlstr("1.0")` instead of leaking the bare text into the C
      # output (which turned `print(_VERSION)` into `nelua_print_string(1.0)`).
      if a.typ != nil and a.typ.kind in {tkString, tkCstring}:
        s.use rhStr
        return "nlstr(" & cStringLit(a.value) & ")"
      return a.value
    return cn
  of nkParen:
    if node.children.len > 0:
      return "(" & s.genExpr(node.children[0]) & ")"
    return ""
  of nkBinaryOp:
    return s.genBinaryOp(node)
  of nkUnaryOp:
    return s.genUnaryOp(node)
  of nkCall:
    return s.genCall(node)
  of nkCallMethod:
    return s.genCallMethod(node)
  of nkDotIndex:
    return s.genDotIndex(node)
  of nkKeyIndex:
    return s.genKeyIndex(node)
  of nkColonIndex:
    return s.genExpr(node.children[0])
  of nkInitList:
    return s.genInitList(node)
  of nkPair:
    return s.genExpr(node.children[0])
  of nkDoExpr:
    return "/*do-expr*/"
  of nkType:
    # `@record`/`@enum` in expression position has no runtime value (it is a
    # type binding, emitted -- if at all -- as a typedef by emitTypedef).
    return ""
  else:
    return "/*?" & $node.kind & "*/"

proc arithCast(s: var Gen, expr: string, fromT: Type, toT: Type): string =
  ## Cast an arithmetic operand to the result type.  Integral -> float is a
  ## benign widening (needed so C does float division), emitted without the
  ## conservative narrow-check that `sema.convert` would attach.
  if fromT == nil or toT == nil: return expr
  if fromT == toT: return expr
  if toT.isFloat and fromT.isIntegral:
    return cCast(toT, expr)
  return s.coerce(expr, fromT, toT)

proc genBinaryOp(s: var Gen, node: Node): string =
  let lhs = node.children[0]
  let rhs = node.children[1]
  let la = s.ctx.attrOf.getOrDefault(lhs)
  let ra = s.ctx.attrOf.getOrDefault(rhs)
  let lt = if la != nil: la.typ else: nil
  let rt = if ra != nil: ra.typ else: nil
  let na = s.ctx.attrOf.getOrDefault(node)
  let rtype = if na != nil: na.typ else: nil
  if na != nil and na.comptime and na.value != "" and not (node.str in @["//", "%"]):
    let nt = na.typ
    if nt != nil and nt.isStringy:
      s.use rhStr
      return "nlstr(" & cStringLit(na.value) & ")"
    return na.value
  let lstr0 = s.genExpr(lhs)
  let rstr0 = s.genExpr(rhs)
  let arithmetic = node.str in @["+","-","*","/","//","%","^","<<",">>","&","|","~"]
  let lstr = if arithmetic: s.arithCast(lstr0, lt, rtype) else: lstr0
  let rstr = if arithmetic: s.arithCast(rstr0, rt, rtype) else: rstr0
  let stringy = (lt != nil and lt.isStringy) and (rt != nil and rt.isStringy)
  case node.str
  of "+":
    if stringy:
      s.use rhStrConcat
      return "nlstring_concat(" & lstr & ", " & rstr & ")"
    return "(" & lstr & " + " & rstr & ")"
  of "-": return "(" & lstr & " - " & rstr & ")"
  of "*": return "(" & lstr & " * " & rstr & ")"
  of "/": return "(" & lstr & " / " & rstr & ")"
  of "//":
    s.use rhIdiv
    return "nlidiv(" & lstr & ", " & rstr & ")"
  of "%":
    s.use rhMod
    return "nlmod(" & lstr & ", " & rstr & ")"
  of "^":
    s.use rhPow
    s.use rhMath
    return "nlpow(" & lstr & ", " & rstr & ")"
  of "..":
    s.use rhStrConcat
    return "nlstring_concat(" & lstr & ", " & rstr & ")"
  of "<<": return "(" & lstr & " << " & rstr & ")"
  of ">>": return "(" & lstr & " >> " & rstr & ")"
  of "&": return "(" & lstr & " & " & rstr & ")"    ## band
  of "|": return "(" & lstr & " | " & rstr & ")"
  of "~": return "(" & lstr & " ^ " & rstr & ")"    ## bxor (C ^ is free: Nelua ^ is power)
  of "<": return "(" & lstr & " < " & rstr & ")"
  of ">": return "(" & lstr & " > " & rstr & ")"
  of "<=": return "(" & lstr & " <= " & rstr & ")"
  of ">=": return "(" & lstr & " >= " & rstr & ")"
  of "==":
    ## Array `==` is element-wise (C compares array names as pointers, which
    ## is always false).  For a bounded array emit a short-circuiting chain of
    ## element comparisons; the oracle does the same.
    if lt != nil and lt.kind == tkArray and lt.arraySize > 0 and
       rt != nil and rt.kind == tkArray and rt.arraySize > 0:
      let n = min(lt.arraySize, rt.arraySize)
      var els: seq[string] = @[]
      for i in 0 ..< n:
        els.add "(" & lstr & "[" & $i & "] == " & rstr & "[" & $i & "])"
      return "(" & els.join(" && ") & ")"
    return "(" & lstr & " == " & rstr & ")"
  of "~=":
    if lt != nil and lt.kind == tkArray and lt.arraySize > 0 and
       rt != nil and rt.kind == tkArray and rt.arraySize > 0:
      let n = min(lt.arraySize, rt.arraySize)
      var els: seq[string] = @[]
      for i in 0 ..< n:
        els.add "(" & lstr & "[" & $i & "] != " & rstr & "[" & $i & "])"
      return "(" & els.join(" || ") & ")"
    return "(" & lstr & " != " & rstr & ")"
  of "and": return "(" & lstr & " && " & rstr & ")"
  of "or": return "(" & lstr & " || " & rstr & ")"
  else: return "/*op " & node.str & "*/"

proc genUnaryOp(s: var Gen, node: Node): string =
  let rhs = node.children[0]
  let ra = s.ctx.attrOf.getOrDefault(rhs)
  let rt = if ra != nil: ra.typ else: nil
  let rstr = s.genExpr(rhs)
  case node.str
  of "-": return "(-" & rstr & ")"
  of "#":
    if rt != nil and rt.kind == tkString: return "(" & rstr & ".size)"
    if rt != nil and rt.kind == tkCstring:
      s.use rhLen
      s.use rhStr
      return "nllen(nlstr(" & rstr & "))"
    if rt != nil and rt.kind == tkArray:
      ## `#array` on a bounded array is a compile-time constant (the declared
      ## element count); there is no runtime `nlarrlen` symbol, so fold it.
      if rt.arraySize > 0: return $rt.arraySize
      return "0"
    # M1: a record with a `__len` metamethod dispatches through it instead of
    # the string-length helper (which expects nlstring and rejects records).
    if rt != nil and rt.kind == tkRecord and rt.methods.hasKey("__len"):
      return s.genMetaCall(rhs, "__len", @[])
    s.use rhLen
    return "nllen(" & rstr & ")"
  of "not": return "(!" & rstr & ")"
  of "~": return "(~" & rstr & ")"     ## bnot
  of "deref": return "(*" & rstr & ")"
  of "&": return "(&" & rstr & ")"     ## ref
  else: return "/*uop " & node.str & "*/"

proc genSpilledCall(s: var Gen, callee: string,
                    spills: seq[tuple[expr: string, pt: Type, direct: bool]]): string =
  ## Emit `<callee>(<args>)`, evaluating every argument LEFT-TO-RIGHT by
  ## assigning each to a named temp inside a GNU statement-expression.  C
  ## leaves function-argument evaluation order unspecified (in practice
  ## right-to-left on the x86-64 SysV ABI), so without the spill a
  ## side-effecting argument could run after the call.  The oracle evaluates
  ## call arguments left-to-right, so the spill makes the order match.
  ##
  ## `direct` args (C `...` varargs) are passed through uncoerced and without
  ## a temp: a typed temp would impose a promotion C does not apply to variadic
  ## arguments, and varargs are the tail where ordering is least observable.
  if spills.len == 0:
    return callee & "()"
  var decls: seq[string] = @[]
  var names: seq[string] = @[]
  for (expr, pt, direct) in spills:
    if direct:
      names.add expr
    else:
      inc s.mrCounter
      let tn = "__ca" & $s.mrCounter
      let ct = if pt != nil: cType(pt) else: "nlany"
      decls.add ct & " " & tn & " = " & expr & ";"
      names.add tn
  return "({" & decls.join(" ") & " " & callee & "(" & names.join(", ") & "); })"

proc genCall(s: var Gen, node: Node): string =
  let caller = node.children[^1]
  # `require 'name'` is a compile-time directive: the analyzer resolves and
  # analyzes the dependency, importing its symbols into scope.  There is no
  # runtime `require` call to emit, so the statement lowers to nothing.
  if caller.kind == nkId and caller.str == "require":
    return ""
  let args = node.children[0 ..< node.children.len - 1]
  let ca = s.ctx.attrOf.getOrDefault(caller)
  # Exception / panic primitives.  These are noreturn runtime helpers; `check`
  # is elided entirely when the `nochecks` pragma / release mode is active.
  if caller.kind == nkId:
    let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
    case cn
    of "nelua_error":
      let msg = if args.len > 0: s.genExpr(args[0]) else:
        s.use rhStr; "nlstr(\"error!\")"
      return "nelua_error_line(" & msg & ")"
    of "nelua_panic":
      let msg = if args.len > 0: s.genExpr(args[0]) else: "((nlstring){NULL, 0})"
      return "nelua_panic_string(" & msg & ")"
    of "nelua_assert":
      if args.len == 0:
        s.use rhStr
        return "nelua_assert_line(false, nlstr(\"assertion failed!\"))"
      let condArg = args[0]
      let cond = s.genExpr(condArg)
      # The oracle only treats the boolean `false` as a failing assertion
      # condition; any other type (integer 0, empty string, ...) is truthy.
      # Emit a literal `true` for non-bool conditions rather than passing the
      # value straight into a `bool` C parameter (which fails to compile for
      # strings and does the wrong thing for integers).
      let condType = s.ctx.attrOf.getOrDefault(condArg).typ
      let condStr = if condType != nil and condType.kind != tkBoolean: "true" else: cond
      let msg = if args.len > 1: s.genExpr(args[1]) else:
        s.use rhStr; "nlstr(\"assertion failed!\")"
      return "nelua_assert_line(" & condStr & ", " & msg & ")"
    of "nelua_check":
      if s.nochecks: return ""
      if args.len == 0:
        s.use rhStr
        return "nelua_assert_line(false, nlstr(\"assertion failed!\"))"
      let condArg = args[0]
      let cond = s.genExpr(condArg)
      let condType = s.ctx.attrOf.getOrDefault(condArg).typ
      let condStr = if condType != nil and condType.kind != tkBoolean: "true" else: cond
      let msg = if args.len > 1: s.genExpr(args[1]) else:
        s.use rhStr; "nlstr(\"assertion failed!\")"
      return "nelua_assert_line(" & condStr & ", " & msg & ")"
  var calleeType: Type = nil
  if ca != nil and ca.typ != nil and ca.typ.kind == tkFunction:
    calleeType = ca.typ
  elif ca != nil and ca.calleeType != nil:
    calleeType = ca.calleeType
  # Every argument is spilled to a named temp LEFT-TO-RIGHT inside a GNU
  # statement-expression (see genSpilledCall).  C leaves function-argument
  # evaluation order unspecified, so without the spill a side-effecting
  # argument could run after the call; the oracle evaluates call arguments
  # left-to-right, so the spill makes the order match.
  var spills: seq[tuple[expr: string, pt: Type, direct: bool]] = @[]
  for i, arg in args:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let pt = if calleeType != nil and i < calleeType.args.len: calleeType.args[i] else: at
    # C8: a `...: cvarargs` slot is a C variadic tail; varargs arguments are
    # passed through uncoerced (C applies its own promotion rules).  Coercing
    # to the cvarargs type itself would emit `(...)(42)`, which is invalid C.
    # They are also passed DIRECTLY (no temp): a typed temp would impose a
    # promotion that C does not apply to variadic args.
    if pt != nil and pt.kind == tkCvarargs:
      spills.add (aes, pt, true)
    else:
      spills.add (s.coerce(aes, at, pt), pt, false)
  # C4: record/enum constructor `Rect{ x = 1 }` -> compound literal
  # `((struct <tag>){ .x = 1, .y = 2 })`.
  let na = s.ctx.attrOf.getOrDefault(node)
  if na != nil and na.isConstructor:
    let ct = if calleeType != nil: calleeType else: na.calleeType
    let tag = cTag(ct)
    let initList = args[0]
    var parts: seq[string] = @[]
    for pair in initList.children:
      if pair.kind == nkPair:
        let ft = fieldOf(ct, pair.str)
        let child = pair.children[0]
        if ft != nil and ft.kind == tkArray and child.kind == nkInitList:
          ## An array field inside a record constructor must be given a bare
          ## brace-enclosed initializer (`.v = { ... }`); a cast compound literal
          ## (`.v = (uint32_t[N]){ ... }`) is ill-formed in C.
          parts.add "." & cIdent(pair.str) & " = " &
            s.genInitListBraces(child, ft.subtype) & ","
        elif ft != nil and ft.kind == tkArray:
          parts.add "." & cIdent(pair.str) & " = " &
            s.genArrayInitFromExpr(s.genExpr(child), ft) & ","
        else:
          parts.add "." & cIdent(pair.str) & " = " & s.genExpr(child) & ","
    return "((struct " & tag & "){ " & parts.join(" ") & " })"
  # C1: type cast `(T)(e)` -> `(cType(T))(e)`.  The caller attr carries the
  # target type (bound by the analyzer); there is no callee symbol to call, so
  # emit an explicit C cast of the single argument instead of a call expression.
  if ca != nil and ca.calleeType != nil and caller.kind in {nkParen, nkType}:
    let ct = cType(ca.calleeType)
    # A type cast has exactly one argument, so left-to-right ordering is
    # trivial; use its (already coerced) spill expression directly.
    let argstr = if args.len > 0: spills[0].expr else: "void"
    return "(" & ct & ")(" & argstr & ")"
  # M3: calling a record value `r(...)` dispatches through its `__call`
  # metamethod instead of emitting `<var>(args)` (which C rejects -- a struct
  # is not a function).  Constructors (`Rect{...}`) are typed tkMetatype here,
  # so they are unaffected; builtins like `print` are tkAny/tkFunction.
  if ca != nil and ca.typ != nil and ca.typ.kind == tkRecord and
     ca.typ.methods.hasKey("__call"):
    return s.genMetaCall(caller, "__call", args)
  case caller.kind
  of nkId:
    let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
    if cn == "nelua_print":
      ## C7: emit one typed call per argument instead of a single variadic
      ## call.  Coercion is ignored -- each argument is passed to its typed
      ## helper unchanged, so mixed-type argument order is preserved exactly.
      ##
      ## Arguments are evaluated LEFT-TO-RIGHT (each `inc()` is its own
      ## statement, separated by `;`), matching the oracle, which also evaluates
      ## print args left-to-right.  (A right-to-left spill would print `3 2 1`
      ## for `print(inc(), inc(), inc())`; the oracle prints `1 2 3`.)
      ##
      ## Every emitted line carries its own trailing semicolon except the final
      ## `nelua_print_newline()`, which has none: genStmt appends exactly one `;`
      ## to the whole returned string, so the newline helper receives it.
      var lines: seq[string] = @[]
      for i, arg in args:
        let aes = s.genExpr(arg)
        let at = s.ctx.attrOf.getOrDefault(arg).typ
        var helper = "nelua_print_nil"
        var passArg = false
        var argStr = aes
        if at != nil:
          var ht = at
          # An enum value prints as its underlying integral type (the oracle
          # prints `MASK.UPPER` -> `2147483648`, not `nil`).
          if ht.kind == tkEnum:
            ht = if ht.subtype != nil: ht.subtype else: BuiltinTypes["integer"]
          # W2: C promotes integers smaller than `int` inside arithmetic, so
          # `200u8 + 100u8` computes as the `int` 300 and prints 300.  The
          # oracle's typed print helper takes the small type and wraps
          # implicitly (44); cast the argument to its own small type so the
          # value wraps before it reaches the wide print helper.
          if ht != nil and ht.isIntegral and size(ht) > 0 and size(ht) < 4:
            argStr = "(" & cType(ht) & ")(" & argStr & ")"
          case ht.kind
          of tkInteger, tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
             tkIsize, tkByte, tkCchar, tkCschar, tkCshort, tkCint,
             tkClong, tkClonglong, tkCptrdiff:
            helper = "nelua_print_int64"; passArg = true
          of tkUinteger, tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
             tkUsize, tkCuchar, tkCushort, tkCuint, tkCulong, tkCulonglong,
             tkCsize:
            helper = "nelua_print_uint64"; passArg = true
          of tkFloat32, tkCfloat:
            # A 32-bit float is printed with %.7g (the oracle's print_float);
            # routing it through nelua_print_double (%.14g) exposes bits that
            # are not in the oracle's output.
            helper = "nelua_print_float"; passArg = true
          of tkNumber, tkFloat64, tkFloat128, tkCdouble, tkClongdouble:
            helper = "nelua_print_double"; passArg = true
          of tkString:
            helper = "nelua_print_string"; passArg = true
          of tkCstring:
            # A cstring is a `const char*`; nelua_print_string takes an
            # `nlstring`, so wrap it via nlstr (which measures the length at
            # runtime).  The oracle prints cstrings through a dedicated
            # char*-taking helper; the observable output is the same.
            helper = "nelua_print_string"; passArg = true
            argStr = "nlstr(" & aes & ")"
          of tkBoolean: helper = "nelua_print_bool"; passArg = true
          of tkNilptr, tkPointer: helper = "nelua_print_ptr"; passArg = true
          of tkAny:
            # nelua_print_any takes an `nlany`.  The analyzer sometimes leaves an
            # index/field access typed as `any` even though its C type is the
            # element/field type (e.g. `x[i][j]` on a `[4][4]byte`); wrap the
            # real typed value in the matching tagged-store helper.  A genuine
            # `any` value (already `nlany`) coerces to itself and is unchanged.
            helper = "nelua_print_any"; passArg = true
            argStr = s.coerce(aes, s.realType(arg), BuiltinTypes["any"])
          of tkRecord:
            # M2: a record with a `__tostring` metamethod is printed by calling
            # it and printing the resulting string; a record without one falls
            # back to the default `(null)` print, matching the oracle.
            if ht.methods.hasKey("__tostring"):
              helper = "nelua_print_string"; passArg = true
              argStr = s.genMetaCall(arg, "__tostring", @[])
            else:
              helper = "nelua_print_nil"; passArg = false
          else: helper = "nelua_print_nil"; passArg = false
          if ht.kind == tkCstring:
            s.use rhStr
        s.notePrintHelper(helper)
        let call = if passArg: helper & "(" & argStr & ")" else: helper & "()"
        if i > 0:
          s.use rhPrintSep
          lines.add "nelua_print_sep(); " & call & ";"
        else: lines.add call & ";"
      s.use rhPrintNewline
      if lines.len == 0:
        return "nelua_print_newline()"
      lines.add "nelua_print_newline()"
      return lines.join("\n")
    return s.genSpilledCall(cn, spills)
  of nkDotIndex:
    let cexpr = s.genExpr(caller)
    return s.genSpilledCall("(" & cexpr & ")", spills)
  of nkColonIndex:
    let recv = s.genExpr(caller.children[0])
    let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
    # The receiver is the C call's first positional argument; evaluate it
    # BEFORE the trailing args (left-to-right), so spill it first.
    let ra = s.ctx.attrOf.getOrDefault(caller.children[0])
    let rt = if ra != nil: ra.typ else: nil
    var allSpills: seq[tuple[expr: string, pt: Type, direct: bool]] = @[]
    allSpills.add (recv, rt, false)
    allSpills &= spills
    return s.genSpilledCall(cn, allSpills)
  else:
    let cexpr = s.genExpr(caller)
    return s.genSpilledCall("(" & cexpr & ")", spills)

proc genCallMethod(s: var Gen, node: Node): string =
  let args = node.children[0 ..< node.children.len - 1]
  let recv = node.children[^1]
  let ra = s.ctx.attrOf.getOrDefault(recv)
  let calleeSym = s.ctx.attrOf.getOrDefault(node).calleeSym
  let cn = if calleeSym != nil: calleeSym.codename else: cIdent(node.str)
  let calleeType = s.ctx.attrOf.getOrDefault(node).calleeType
  # Spill the implicit `self` first, then the explicit args, all evaluated
  # LEFT-TO-RIGHT inside genSpilledCall's statement-expression.  C leaves
  # function-argument evaluation order unspecified; the oracle evaluates the
  # receiver and then the arguments left-to-right.
  var spills: seq[tuple[expr: string, pt: Type, direct: bool]] = @[]
  let recvStr = s.genExpr(recv)
  if calleeSym != nil and calleeSym.typ != nil and calleeSym.typ.args.len > 0:
    let p0 = calleeSym.typ.args[0]
    if p0 != nil and p0.kind == tkPointer:
      # The implicit `self` param is `*Record`.  When the receiver expression
      # is already that pointer (a colon-method called on `self`, which is the
      # method's own first param) it is passed unchanged; a value receiver
      # (`r:area()` where `r` is a `Rect` value) is passed by address.
      if ra != nil and ra.typ != nil and ra.typ == p0:
        spills.add (recvStr, p0, false)
      else:
        spills.add ("(&" & recvStr & ")", p0, false)
    else:
      spills.add (recvStr, p0, false)
  else:
    spills.add (recvStr, nil, false)
  # calleeType.args[0] is the implicit `self`; the explicit args start at [1].
  for i, arg in args:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let ai = if calleeType != nil and i + 1 < calleeType.args.len: i + 1 else: i
    let pt = if calleeType != nil and ai < calleeType.args.len: calleeType.args[ai] else: at
    if pt != nil and pt.kind == tkCvarargs:
      spills.add (aes, pt, true)
    else:
      spills.add (s.coerce(aes, at, pt), pt, false)
  return s.genSpilledCall(cn, spills)

proc genMetaCall(s: var Gen, recv: Node, methodName: string,
                 argNodes: seq[Node] = @[]): string =
  ## Emit a colon-method call `recv:methodName(args)` resolved through the
  ## receiver record's `methods` table.  This is the shared helper for the
  ## metamethod-dispatch paths (`#`, `[]`, `print`, `(...)`) where the oracle
  ## consults the record's metafield instead of the default operator/builtin
  ## behaviour.  Direct `recv:methodName()` calls go through genCallMethod;
  ## this helper is for cases where the call site is an operator/builtin, not
  ## an nkCallMethod node, so it re-derives the receiver type and coerces the
  ## arguments against the method's own ftype (args[0] is the implicit self).
  let ra = s.ctx.attrOf.getOrDefault(recv)
  let rt = if ra != nil: ra.typ else: nil
  let md = if rt != nil: rt.methods.getOrDefault(methodName) else: MethodDesc()
  let cn = if md.sym != nil: md.codename
            elif rt != nil and rt.name != "": rt.name & "_" & methodName
            else: "nil"
  let recvStr = s.genExpr(recv)
  # Spill the implicit `self` first, then the explicit args, all evaluated
  # LEFT-TO-RIGHT inside genSpilledCall's statement-expression (C leaves
  # function-argument evaluation order unspecified; the oracle evaluates the
  # receiver and then the arguments left-to-right).
  var spills: seq[tuple[expr: string, pt: Type, direct: bool]] = @[]
  if md.ftype != nil and md.ftype.args.len > 0:
    let p0 = md.ftype.args[0]
    if p0 != nil and p0.kind == tkPointer:
      # The implicit `self` param is `*Record`.  A value receiver is passed
      # by address; a receiver that is already that pointer is unchanged.
      if rt != nil and rt.kind == tkPointer and rt == p0:
        spills.add (recvStr, p0, false)
      else:
        spills.add ("(&" & recvStr & ")", p0, false)
    else:
      spills.add (recvStr, p0, false)
  else:
    spills.add (recvStr, nil, false)
  for i, arg in argNodes:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let pt = if md.ftype != nil and i + 1 < md.ftype.args.len: md.ftype.args[i+1] else: at
    if pt != nil and pt.kind == tkCvarargs:
      spills.add (aes, pt, true)
    else:
      spills.add (s.coerce(aes, at, pt), pt, false)
  return s.genSpilledCall(cn, spills)

proc genDotIndex(s: var Gen, node: Node): string =
  let base = node.children[0]
  let ba = s.ctx.attrOf.getOrDefault(base)
  let bt = if ba != nil: ba.typ else: nil
  let a = s.ctx.attrOf.getOrDefault(node)
  # A3: enum field access `MASK.UPPER` is a compile-time constant folded by
  # the analyzer; emit the literal value instead of `base.field`.
  if a != nil and a.comptime and a.value != "":
    return a.value
  let baseStr = s.genExpr(base)
  let field = cIdent(node.str)
  if bt != nil and bt.kind == tkPointer and bt.subtype != nil and
     bt.subtype.kind in {tkRecord, tkUnion}:
    return baseStr & "->" & field
  return baseStr & "." & field

proc genKeyIndex(s: var Gen, node: Node): string =
  # newKeyIndex stores (key, base): children[0] is the index expression,
  # children[1] is the base expression.  (The old code read them swapped, which
  # happened to compile for arrays because C's `a[i]` == `i[a]`, but it emitted
  # the unintuitive reversed form and broke record subscripting.)
  let key = node.children[0]
  let base = node.children[1]
  let ba = s.ctx.attrOf.getOrDefault(base)
  let bt = if ba != nil: ba.typ else: nil
  if bt != nil and bt.kind == tkTable:
    s.unsupported = true
    s.unsupportedMsg = "table indexing is not implemented"
    return "/*table*/"
  let baseStr = s.genExpr(base)
  let keyStr = s.genExpr(key)
  # M4: a record with an `__index` metamethod dispatches through it instead of
  # a direct subscript (which is invalid on a struct).
  if bt != nil and bt.kind == tkRecord and bt.methods.hasKey("__index"):
    return s.genMetaCall(base, "__index", @[key])
  return baseStr & "[" & keyStr & "]"

proc genInitListBraces(s: var Gen, node: Node, et: Type): string =
  ## Render an init list as a bare brace-enclosed initializer `{ v0, v1, ... }`
  ## (no type cast), for use as an array sub-initializer inside a record or
  ## union compound literal, or as the element list of an array compound
  ## literal. `et` is the element type this list initializes.
  ##
  ## Nested init lists (array-of-record, array-of-array) are the common case:
  ## each element is itself an init list, and rendering it via `genExpr` used
  ## to fall through to `/*initlist*/` because the analyzer does not set a type
  ## attribute on those nested nodes.  Handle them here by recursing, and
  ## render record elements with designated field initializers (`.f = ...`),
  ## which C accepts inside nested braces without a cast.
  var parts: seq[string] = @[]
  for c in node.children:
    if et != nil and et.kind in {tkRecord, tkUnion} and c.kind == nkPair:
      let ft = fieldOf(et, c.str)
      let child = c.children[0]
      if ft != nil and ft.kind == tkArray:
        if child.kind == nkInitList:
          parts.add "." & cIdent(c.str) & " = " &
            s.genInitListBraces(child, ft.subtype)
        else:
          parts.add "." & cIdent(c.str) & " = " &
            s.genArrayInitFromExpr(s.genExpr(child), ft)
      else:
        let val = s.genExpr(child)
        let vt = s.ctx.attrOf.getOrDefault(child)
        parts.add "." & cIdent(c.str) & " = " &
          s.coerce(val, if vt != nil: vt.typ else: nil, ft)
    else:
      let valc = if c.kind == nkPair: c.children[0] else: c
      if valc.kind == nkInitList:
        let elt = if et != nil and et.kind == tkArray: et.subtype else: et
        parts.add s.genInitListBraces(valc, elt)
      else:
        let val = s.genExpr(valc)
        let va = s.ctx.attrOf.getOrDefault(valc)
        let vt = if va != nil: va.typ else: nil
        parts.add s.coerce(val, vt, et)
  return "{" & parts.join(", ") & "}"

proc genArrayInitFromExpr(s: var Gen, src: string, at: Type): string =
  ## Emit a brace-enclosed element-by-element initializer for an array field
  ## being initialized from an array-typed expression (a variable, a field, a
  ## call result).  C cannot copy arrays -- `.data = a` where `a` is an array
  ## is ill-formed in a compound literal -- so each element is read individually
  ## (`{ a[0], a[1], ... }`).  The source is expected to be an lvalue that
  ## decays to an element pointer (the common case); a non-lvalue source is
  ## evaluated once per element, which is correct but may repeat side effects.
  let n = if at.arraySize > 0: at.arraySize else: 1
  var els: seq[string] = @[]
  for i in 0 ..< n:
    els.add src & "[" & $i & "]"
  return "{" & els.join(", ") & "}"

proc genInitList(s: var Gen, node: Node): string =
  let a = s.ctx.attrOf.getOrDefault(node)
  let ptype = if a != nil: a.typ else: nil
  if ptype != nil and ptype.kind == tkRecord:
    let tag = cTag(ptype)
    var parts: seq[string] = @[]
    for c in node.children:
      if c.kind == nkPair:
        let ft = fieldOf(ptype, c.str)
        if ft != nil and ft.kind == tkArray and c.children.len > 0:
          if c.children[0].kind == nkInitList:
            ## An array field inside a record compound literal must be given a
            ## bare brace-enclosed initializer (`.v = { ... }`); a cast compound
            ## literal (`.v = (uint32_t[N]){ ... }`) is ill-formed in C.
            parts.add "." & cIdent(c.str) & " = " &
              s.genInitListBraces(c.children[0], ft.subtype)
          else:
            ## An array field initialized from an array-typed expression (a
            ## variable, a field, a call result): C cannot copy arrays, so emit
            ## a brace-enclosed element-by-element copy.
            let val = s.genExpr(c.children[0])
            parts.add "." & cIdent(c.str) & " = " &
              s.genArrayInitFromExpr(val, ft)
        else:
          let val = s.genExpr(c.children[0])
          let vt = s.ctx.attrOf.getOrDefault(c.children[0]).typ
          parts.add "." & cIdent(c.str) & " = " & s.coerce(val, vt, ft)
      else:
        parts.add s.genExpr(c)
    return "(struct " & tag & "){" & parts.join(", ") & "}"
  if ptype != nil and ptype.kind == tkEnum:
    if node.children.len > 0 and node.children[0].kind == nkPair:
      return cIdent(node.children[0].str)
    return "/*enum*/"
  if ptype != nil and ptype.kind == tkUnion:
    let tag = cTag(ptype)
    var parts: seq[string] = @[]
    for c in node.children:
      if c.kind == nkPair:
        let ft = fieldOf(ptype, c.str)
        if ft != nil and ft.kind == tkArray and c.children.len > 0:
          if c.children[0].kind == nkInitList:
            parts.add "." & cIdent(c.str) & " = " &
              s.genInitListBraces(c.children[0], ft.subtype)
          else:
            let val = s.genExpr(c.children[0])
            parts.add "." & cIdent(c.str) & " = " &
              s.genArrayInitFromExpr(val, ft)
        else:
          let val = s.genExpr(c.children[0])
          let vt = s.ctx.attrOf.getOrDefault(c.children[0]).typ
          parts.add "." & cIdent(c.str) & " = " & s.coerce(val, vt, ft)
      else:
        parts.add s.genExpr(c)
    return "(union " & tag & "){" & parts.join(", ") & "}"
  if ptype != nil and ptype.kind == tkArray:
    return "(" & cType(ptype) & ")" & s.genInitListBraces(node, ptype.subtype)
  return "/*initlist*/"

# ---------------------------------------------------------------------------
# Lvalue (assignment-target) lowering
# ---------------------------------------------------------------------------

proc genLvalue(s: var Gen, node: Node): string =
  case node.kind
  of nkId:
    let a = s.ctx.attrOf.getOrDefault(node)
    return if a != nil and a.codename != "": a.codename else: cIdent(node.str)
  of nkDotIndex:
    let base = node.children[0]
    let ba = s.ctx.attrOf.getOrDefault(base)
    let bt = if ba != nil: ba.typ else: nil
    let baseStr = s.genExpr(base)
    if bt != nil and bt.kind == tkPointer and bt.subtype != nil and
       bt.subtype.kind in {tkRecord, tkUnion}:
      return baseStr & "->" & cIdent(node.str)
    return baseStr & "." & cIdent(node.str)
  of nkKeyIndex:
    # children[0]=key, children[1]=base (see genKeyIndex).
    let baseStr = s.genExpr(node.children[1])
    let keyStr = s.genExpr(node.children[0])
    return baseStr & "[" & keyStr & "]"
  else:
    return s.genExpr(node)

# ---------------------------------------------------------------------------
# Statement lowering
# ---------------------------------------------------------------------------

proc genStmts(s: var Gen, node: Node) =
  if node == nil: return
  for c in node.children:
    s.genStmt(c)

proc genScope(s: var Gen, node: Node, kind: DeferScopeKind = dkBlock) =
  ## Emit the statements of `node` and its defers, with no surrounding braces.
  s.pushDefer(kind)
  if node != nil:
    s.genStmts(node)
  let defers = s.deferStack[^1][1]
  for i in countdown(defers.len - 1, 0):
    s.genBody(defers[i].children[0])
  discard s.deferStack.pop()

proc genBody(s: var Gen, node: Node) =
  ## Emit a braced, defer-aware block scope.
  s.line "{"
  s.push
  s.genScope(node)
  s.pop
  s.line "}"

proc cDecl(t: Type, name: string): string =
  ## Render a C *declaration* of `name` with type `t`.
  ## `cType` renders an array as `elemtype[size]`, which is right for compound
  ## literals and indexing but wrong for a declarator -- C requires the bound
  ## after the identifier (`int64_t x[3]`, never `int64_t[3] x`).  This helper
  ## re-renders array types in declaration position.
  if t == nil:
    return "void " & name
  if name == "":
    return cType(t)
  case t.kind
  of tkArray:
    let inner = cDecl(t.subtype, name)
    let sz = if t.arraySize <= 0: "[]" else: "[" & $t.arraySize & "]"
    return inner & sz
  of tkFunction:
    # Function-pointer declarator: the identifier nests INSIDE the parens,
    # `ret (*name)(params)` -- `cType` spells the value form `ret (*)(params)`
    # which is invalid in declaration position.
    let ret = if t.returns.len == 0: "void"
              elif t.returns.len == 1: cType(t.returns[0])
              else: multiRetTag(t.returns)
    var params: seq[string] = @[]
    for a in t.args:
      params.add if a == nil: "void" else: cType(a)
    let paramStr = if params.len == 0: "void" else: params.join(", ")
    return ret & " (*" & name & ")(" & paramStr & ")"
  of tkNiltype:
    # `void` is not a valid parameter/variable type in C (a void parameter must
    # be the sole, unnamed argument).  Render niltype as nilptr so it is
    # addressable and assignable; the nil literal is emitted as NULL (see nkNil).
    return "nilptr " & name
  else:
    return cType(t) & " " & name

proc cFuncDecl(retType: Type, name: string, paramStr: string): string =
  ## Render a C function declarator for a function whose return type is
  ## `retType`.  A plain return type spells `RET name(params)`; a function-pointer
  ## return type nests as `RET (*name(params))(RETPARAMS)` (the only valid C form).
  if retType != nil and retType.kind == tkFunction:
    let r = retType
    var rparams: seq[string] = @[]
    for a in r.args:
      rparams.add if a == nil: "void" else: cType(a)
    let rp = if rparams.len == 0: "void" else: rparams.join(", ")
    if r.returns.len == 0:
      return "void (*" & name & "(" & paramStr & "))(" & rp & ")"
    elif r.returns.len == 1 and r.returns[0].kind == tkFunction:
      return cType(r) & " (*" & name & "(" & paramStr & "))(" & rp & ")"
    else:
      return cType(r.returns[0]) & " (*" & name & "(" & paramStr & "))(" & rp & ")"
  let ret = if retType == nil: "void"
          elif retType.kind == tkNiltype: "nilptr"
          else: cType(retType)
  return ret & " " & name & "(" & paramStr & ")"

proc genVarDecl(s: var Gen, node: Node, emitInits: bool, isGlobal: bool,
                alreadyDeclared: bool = false) =
  # A `global` declaration is only valid at the module top scope; the oracle's
  # analyzer rejects it inside any function body (analyzer.lua:2217).  Ours
  # does not check it yet, so enforce it here rather than emit broken C for a
  # global that has no right to exist in that scope.
  if node.str == "global" and s.inFunc:
    s.unsupported = true
    s.unsupportedMsg = "global variables can only be declared in top scope"
    return
  var iddecls: seq[Node] = @[]
  var inits: seq[Node] = @[]
  for c in node.children:
    if c.kind == nkIdDecl: iddecls.add c
    else: inits.add c

  if not emitInits:
    for iddecl in iddecls:
      let a = s.ctx.attrOf.getOrDefault(iddecl)
      let vtype = if a != nil: a.typ else: nil
      if vtype != nil:
        s.collectType(vtype)
      if a != nil and a.isTypeBinding:
        continue
      if vtype == nil: continue
      let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
      var qual = ""
      if isGlobal: qual &= "static "
      if a != nil and a.isConst: qual &= "const "
      if a != nil and a.isVolatile: qual &= "volatile "
      if vtype.isAny:
        s.line qual & cDecl(vtype, cn) & " = {0};"
      else:
        s.line qual & cDecl(vtype, cn) & ";"
    return

  # initializers, emitted as assignments
  if inits.len == 1 and iddecls.len > 1 and isCall(inits[0]):
    let callNode = inits[0]
    let rets = s.ctx.callRetTypes.getOrDefault(callNode)
    if rets.len == iddecls.len and rets.len > 1:
      let tag = multiRetTag(rets)
      inc s.mrCounter
      let tmp = "__mr" & $s.mrCounter
      s.line tag & " " & tmp & " = " & s.genCall(callNode) & ";"
      for i, iddecl in iddecls:
        let a = s.ctx.attrOf.getOrDefault(iddecl)
        if a != nil and a.comptime: continue
        let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
        s.line cn & " = " & tmp & ".field" & $i & ";"
      return
  # Function-body locals and block-scoped locals at unit scope need a C
  # declaration emitted here; top-level variables were already declared as
  # `static` in the globals pass (genC step 3b) and their initialisers run here
  # at step 6, so they are passed `alreadyDeclared=true` to avoid a duplicate
  # `int64_t tmp_x;`.  The `isGlobal` flag is set from `s.inFunc`, so it is true
  # exactly for function-body locals.  A comptime local is folded away entirely
  # -- it has no storage and every reference is inlined -- so neither a
  # declaration nor an assignment emits.
  if isGlobal or not alreadyDeclared:
    for iddecl in iddecls:
      let a = s.ctx.attrOf.getOrDefault(iddecl)
      if a != nil and a.isTypeBinding:
        if a.typ != nil: s.collectType(a.typ)
        continue
      if a != nil and a.comptime:
        continue
      let vtype = if a != nil: a.typ else: nil
      if vtype == nil: continue
      s.collectType(vtype)
      let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
      if vtype.isAny:
        s.line cDecl(vtype, cn) & " = {0};"
      else:
        s.line cDecl(vtype, cn) & ";"
  for i in 0 ..< min(iddecls.len, inits.len):
    let iddecl = iddecls[i]
    let init = inits[i]
    let a = s.ctx.attrOf.getOrDefault(iddecl)
    if a != nil and a.isTypeBinding:
      if a.typ != nil: s.collectType(a.typ)
      continue
    if a != nil and a.comptime:
      continue
    let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
    let vt = if a != nil: a.typ else: nil
    let it = s.ctx.attrOf.getOrDefault(init).typ
    if vt != nil and init.kind == nkInitList and
     (vt.kind == tkArray or
      (vt.kind in {tkRecord, tkUnion} and hasArrayField(vt))):
      ## A record/union literal whose fields include an array cannot be
      ## assigned in C (`r = (struct T){ .v = (uint32_t[N]){...} }` is invalid:
      ## an array subobject may not be initialized from a compound literal in
      ## assignment position).  Lower the whole thing to a memcpy from the
      ## compound literal, which is valid for both records and arrays.
      let cl = s.genExpr(init)
      let dest = if vt.kind == tkArray: cn else: "(&" & cn & ")"
      let src = if vt.kind == tkArray: cl else: "(&" & cl & ")"
      s.line "memcpy(" & dest & ", " & src & ", sizeof(" & cn & "));"
    elif vt != nil and (vt.kind == tkArray or
                        (vt.kind in {tkRecord, tkUnion} and hasArrayField(vt))):
      ## An array-typed variable, or a record/union containing an array field,
      ## cannot be assigned in C (`a = b` is ill-formed for arrays, and a struct
      ## holding an array has no generated copy operator).  The source is an
      ## array lvalue too (a variable, a record field, a `$copy`), so it decays
      ## to a pointer and memcpy performs the elementwise copy.  A record-typed
      ## source does not decay, so take its address explicitly.
      let dest = if vt.kind == tkArray: cn else: "(&" & cn & ")"
      let src = if vt.kind == tkArray: s.genExpr(init) else: "(&" & s.genExpr(init) & ")"
      s.line "memcpy(" & dest & ", " & src & ", sizeof(" & cn & "));"
    else:
      s.line cn & " = " & s.coerce(s.genExpr(init), it, vt) & ";"

proc genAssign(s: var Gen, node: Node) =
  let ntargets = s.ctx.assignTargets.getOrDefault(node, 1)
  var targets: seq[string] = @[]
  var ttypes: seq[Type] = @[]
  var typeTargets: seq[bool] = @[]   ## C5: a reassignment to a type binding
                                    ## (`R = @record{...}`) is a compile-time
                                    ## type redefinition, not a runtime
                                    ## assignment -- the target is a C typedef
                                    ## name, so emitting `R = ...` is invalid C.
  for i in 0 ..< ntargets:
    let t = node.children[i]
    let sym = s.ctx.symOf.getOrDefault(t)
    typeTargets.add sym != nil and sym.kind == skType
    targets.add s.genLvalue(t)
    ttypes.add s.ctx.attrOf.getOrDefault(t).typ
  var values: seq[string] = @[]
  var vtypes: seq[Type] = @[]
  for i in ntargets ..< node.children.len:
    let v = node.children[i]
    values.add s.genExpr(v)
    vtypes.add s.ctx.attrOf.getOrDefault(v).typ
  if values.len == 1 and ntargets > 1 and node.children[ntargets].kind == nkCall:
    let callNode = node.children[ntargets]
    var rets = s.ctx.callRetTypes.getOrDefault(callNode)
    if rets.len == 0:
      # `callRetTypes` is only populated for a multi-return call that is the
      # initializer of a multi-decl VarDecl; an assignment `m, n = f()` to
      # pre-declared locals never sets it, so fall back to the callee's own
      # return type (its typedef is already collected via calleeType).
      let ca = s.ctx.attrOf.getOrDefault(callNode)
      if ca != nil and ca.calleeType != nil:
        rets = ca.calleeType.returns
    if rets.len == ntargets and rets.len > 1:
      let tag = multiRetTag(rets)
      inc s.mrCounter
      let tmp = "__mr" & $s.mrCounter
      s.line tag & " " & tmp & " = " & s.genCall(callNode) & ";"
      for i in 0 ..< ntargets:
        if typeTargets[i]: continue
        s.line targets[i] & " = " & tmp & ".field" & $i & ";"
      return
  # Multi-assignment semantics: the Oracle evaluates the ENTIRE right-hand
  # side first (every RHS expression reads the pre-assignment values) and only
  # then assigns the targets left-to-right.  Emitting `a = b; b = a % b;`
  # inline would let the second RHS expression read the already-updated `a`,
  # so `a, b = b, a % b` behaves as if `a` on the right were the NEW `a` (the
  # swap bug: fib(10) prints 1, gcd hangs).  Spill every RHS value into a
  # temporary BEFORE any target is updated, then assign left-to-right from the
  # temps.  Single-assignment (`a = e`) and the multi-return-call case above
  # are untouched; a nil value type (unresolved expression) falls back to the
  # inline path, which is the pre-existing behavior.
  var needsTemps = false
  if targets.len > 1 and values.len > 1:
    needsTemps = true
    for vt in vtypes:
      if vt == nil:
        needsTemps = false
        break
  if needsTemps:
    inc s.mrCounter
    let base = "__ma" & $s.mrCounter
    for i in 0 ..< values.len:
      if typeTargets[i]: continue
      s.line cDecl(vtypes[i], base & "_" & $i) & " = " & values[i] & ";"
    for i in 0 ..< min(targets.len, values.len):
      if typeTargets[i]: continue
      s.line targets[i] & " = " & s.coerce(base & "_" & $i, vtypes[i], ttypes[i]) & ";"
  else:
    for i in 0 ..< min(targets.len, values.len):
      if typeTargets[i]: continue
      s.line targets[i] & " = " & s.coerce(values[i], vtypes[i], ttypes[i]) & ";"

proc genIf(s: var Gen, node: Node) =
  let hasElse = (node.children.len and 1) == 1
  let npairs = node.children.len div 2
  for pi in 0 ..< npairs:
    let cond = node.children[pi * 2]
    let body = node.children[pi * 2 + 1]
    if pi == 0:
      s.line "if (" & s.genExpr(cond) & ") {"
    else:
      s.line "} else if (" & s.genExpr(cond) & ") {"
    s.push
    s.genScope(body)
    s.pop
  if hasElse:
    s.line "} else {"
    s.push
    s.genScope(node.children[^1])
    s.pop
  s.line "}"

proc bodyEndsInJump(node: Node): bool =
  ## True when `node` (a case/else body Block) ends in a statement that
  ## unconditionally transfers control -- `return`/`break`/`continue`/`goto`.
  ## A trailing `break;` after such a body would be unreachable dead code, so
  ## the reference omits it (it emits `break;` after every body that can fall
  ## through, including bodies ending in a `panic`/`error` call, which are
  ## calls rather than control-transfer statements).
  if node == nil: return false
  let stmts = if node.kind == nkBlock: node.children else: @[node]
  if stmts.len == 0: return false
  case stmts[^1].kind
  of nkReturn, nkBreak, nkContinue, nkGoto: true
  else: false

proc genSwitch(s: var Gen, node: Node) =
  ## Emit a C `switch`/`case`/`default`.  Case values are emitted from their
  ## folded comptime attr (`a.value`), so `case 1+1` lowers to `case 2:`; comma
  ## cases become consecutive `case` labels guarding one body; `else` becomes
  ## `default`.  Duplicate case values surface as a C-compile error, matching
  ## the reference's C backend.  The subject is evaluated directly inside the
  ## `switch()` condition (the reference does not hoist it on the C backend).
  s.line "switch (" & s.genExpr(node.children[0]) & ") {"
  s.push
  var i = 1
  let nc = node.children.len
  while i < nc:
    var vals: seq[Node] = @[]
    while i < nc and node.children[i].kind != nkBlock:
      vals.add node.children[i]
      inc i
    if i >= nc: break
    let body = node.children[i]
    inc i
    if vals.len == 0:
      s.line "default: {"
    else:
      for v in vals:
        let va = s.ctx.attrOf.getOrDefault(v)
        let val = if va != nil and va.comptime and va.value != "":
                    cNumberLit(if va.typ != nil: va.typ else: nil, va.value)
                  else:
                    s.genExpr(v)
        s.line "case " & val & ":"
      s.line "{"
    s.push
    s.genScope(body, dkBlock)
    s.pop
    s.line "}"
    if not bodyEndsInJump(body):
      s.line "break;"
  s.pop
  s.line "}"

proc genForNum(s: var Gen, node: Node) =
  let iddecl = node.children[0]
  let beginv = node.children[1]
  let endv = node.children[2]
  let hasStep = node.children.len == 5
  let step = if hasStep: node.children[3] else: nil
  let body = node.children[^1]
  let ia = s.ctx.attrOf.getOrDefault(iddecl)
  let cn = if ia != nil and ia.codename != "": ia.codename else: cIdent(iddecl.str)
  let vtype = if ia != nil: ia.typ else: nil
  let compop = s.ctx.dumpOf.getOrDefault(node).compop
  let cmp = case compop
    of "ge": ">="
    of "gt": ">"
    of "lt": "<"
    else: "<="
  let stepStr = if step != nil: s.genExpr(step) else: "1"
  s.line "for (" & cType(vtype) & " " & cn & " = " & s.genExpr(beginv) & "; " &
          cn & " " & cmp & " " & s.genExpr(endv) & "; " & cn & " += " & stepStr & ") {"
  s.push
  s.genScope(body, dkLoop)
  s.pop
  s.line "}"

proc registerLoopVar(s: var Gen, node: Node, name, cn: string, et: Type) =
  ## Walk `node` and attach an attr to every `nkId` reference of the loop
  ## variable `name` so the statement/expression lowers below do not dereference
  ## a nil attr.  The analyzer leaves `nkForIn` loop variables unannotated, so
  ## cgen has to patch the body itself (see `genForIn`).
  if node == nil: return
  if node.kind == nkId and node.str == name:
    var a = Attr()
    a.typ = et
    a.lvalue = true
    a.name = name
    a.codename = cn
    s.ctx.attrOf[node] = a
  for c in node.children:
    s.registerLoopVar(c, name, cn, et)

proc genForIn(s: var Gen, node: Node) =
  let body = node.children[^1]
  # Leading `nkIdDecl` children are the loop variables; everything after them
  # (up to the body) is the iterable list.  This slice only supports a single
  # loop variable over a single array iterable.
  var nIddecls = 0
  while nIddecls < node.children.len - 1 and node.children[nIddecls].kind == nkIdDecl:
    inc nIddecls
  if nIddecls != 1:
    s.line "/* for-in iterator lowering not implemented in this slice */"
    s.genBody(body)
    return
  let iddecl = node.children[0]
  let iterable = node.children[nIddecls]
  let ia = s.ctx.attrOf.getOrDefault(iddecl)
  let cn = if ia != nil and ia.codename != "": ia.codename else: cIdent(iddecl.str)
  let it = s.ctx.attrOf.getOrDefault(iterable).typ
  if it != nil and it.kind == tkArray:
    let et = it.subtype
    let arrStr = s.genExpr(iterable)
    let len = it.arraySize
    s.registerLoopVar(body, iddecl.str, cn, et)
    s.line "for (int64_t __i = 0; __i < " & $len & "; __i += 1) {"
    s.push
    s.line cType(et) & " " & cn & " = " & arrStr & "[__i];"
    s.genScope(body, dkLoop)
    s.pop
    s.line "}"
  else:
    s.line "/* for-in iterator lowering not implemented in this slice */"
    s.genBody(body)

proc genReturn(s: var Gen, node: Node) =
  ## Emit a `return` statement.  Every pending defer from the current scope
  ## outward, up to and including the nearest function-body scope, must run
  ## *before* the jump -- otherwise they become unreachable dead code.
  let rets = s.currentReturns
  # Evaluate the return value first (if any) into a temporary we can reference
  # after the defers have run, so defer bodies cannot observe a half-built
  # return value.
  var retPrefix = ""
  if rets.len > 0 and not (rets.len == 1 and rets[0].isVoid) and node.children.len > 0:
    if rets.len == 1:
      let c = node.children[0]
      let expr = s.genExpr(c)
      let et = s.ctx.attrOf.getOrDefault(c).typ
      retPrefix = " " & s.coerce(expr, et, rets[0])
    else:
      let tag = multiRetTag(rets)
      var parts: seq[string] = @[]
      for i, c in node.children:
        let expr = s.genExpr(c)
        let et = s.ctx.attrOf.getOrDefault(c).typ
        let rt = if i < rets.len: rets[i] else: nil
        parts.add ".field" & $i & " = " & s.coerce(expr, et, rt)
      retPrefix = " (struct " & tag & "){" & parts.join(", ") & "}"
  # Run defers up to and including the nearest function-body scope.
  s.runDefersUpTo(dkFunc)
  if retPrefix.len > 0:
    s.line "return" & retPrefix & ";"
  else:
    s.line "return;"

proc genStmt(s: var Gen, node: Node) =
  if node == nil: return
  case node.kind
  of nkBlock:
    s.genStmts(node)
  of nkVarDecl:
    s.genVarDecl(node, emitInits=true, isGlobal=s.inFunc)
  of nkFuncDef:
    # collected separately; emit nothing in place
    discard
  of nkIf:
    s.genIf(node)
  of nkWhile:
    s.line "while (" & s.genExpr(node.children[0]) & ") {"
    s.push
    s.genScope(node.children[1], dkLoop)
    s.pop
    s.line "}"
  of nkSwitch:
    s.genSwitch(node)
  of nkRepeat:
    s.line "do {"
    s.push
    s.genScope(node.children[0], dkLoop)
    s.pop
    s.line "} while(!(" & s.genExpr(node.children[1]) & "));"
  of nkForNum:
    s.genForNum(node)
  of nkForIn:
    s.genForIn(node)
  of nkDefer:
    s.deferStack[^1][1].add node
  of nkDo:
    s.genBody(node.children[0])
  of nkAssign:
    s.genAssign(node)
  of nkReturn:
    s.genReturn(node)
  of nkBreak:
    s.runDefersUpTo(dkLoop)
    s.line "break;"
  of nkContinue:
    s.runDefersUpTo(dkLoop)
    s.line "continue;"
  of nkCall:
    let e = s.genCall(node)
    if e.len > 0: s.line e & ";"
  of nkCallMethod:
    let e = s.genCallMethod(node)
    if e.len > 0: s.line e & ";"
  of nkDirective:
    discard
  else:
    let e = s.genExpr(node)
    if e.len > 0 and e != "/*...*/": s.line e & ";"

# ---------------------------------------------------------------------------
# Function lowering
# ---------------------------------------------------------------------------

proc funcArgList(node: Node): seq[Node] =
  var args: seq[Node] = @[]
  var i = 1
  while i < node.children.len and node.children[i].kind == nkIdDecl:
    args.add node.children[i]
    inc i
  return args

proc genForwardDecl(s: var Gen, node: Node) =
  let a = s.ctx.attrOf.getOrDefault(node)
  let ftype = if a != nil: a.typ else: nil
  if ftype == nil or ftype.kind != tkFunction: return
  let codename = if a != nil and a.codename != "": a.codename else: cIdent(node.children[0].str)
  let args = funcArgList(node)
  var params: seq[string] = @[]
  for j, arg in args:
    let at = if j < ftype.args.len: ftype.args[j] else: BuiltinTypes["any"]
    params.add cDecl(at, cIdent(arg.str))
  # C8: a C variadic `...: cvarargs` slot has no C declarator (it is not an
  # nkIdDecl, so funcArgList skips it); emit the bare `...` so a cimport like
  # `printf(format, ...)` declares its variadic tail.
  if ftype.args.len > args.len:
    params.add "..."
  let paramStr = params.join(", ")
  var decl: string
  if ftype.returns.len > 1:
    decl = multiRetTag(ftype.returns) & " " & codename & "(" & paramStr & ")"
  else:
    let retType = if ftype.returns.len == 1: ftype.returns[0] else: nil
    decl = cFuncDecl(retType, codename, paramStr)
  if a != nil and a.cimport:
    # When the same annotation set carries a `<cinclude>`, the system header
    # already declares the symbol; emitting our own `extern` here re-declares
    # it with our (possibly incompatible) parameter types and conflicts, e.g.
    # `const char*` vs the header's `char *__restrict`.  The oracle skips the
    # redundant declaration entirely and relies on the include, so do the same.
    if a.cinclude.len == 0:
      s.line "extern " & decl & ";"
    return
  s.line decl & ";"

proc genFuncDef(s: var Gen, node: Node) =
  let a = s.ctx.attrOf.getOrDefault(node)
  let ftype = if a != nil: a.typ else: nil
  if ftype == nil or ftype.kind != tkFunction: return
  let codename = if a != nil and a.codename != "": a.codename else: cIdent(node.children[0].str)
  let cinclude = if a != nil: a.cinclude else: ""
  if cinclude.len > 0:
    # The `<cinclude '<...>'>` value already carries its own delimiters (the
    # oracle stores `<stdio.h>` and emits `#include <stdio.h>`), so emit it
    # verbatim rather than wrapping it in extra quotes.
    s.line "#include " & cinclude
  let args = funcArgList(node)
  var params: seq[string] = @[]
  for j, arg in args:
    let at = if j < ftype.args.len: ftype.args[j] else: BuiltinTypes["any"]
    params.add cDecl(at, cIdent(arg.str))
  # C8: a C variadic `...: cvarargs` slot has no C declarator (it is not an
  # nkIdDecl, so funcArgList skips it); emit the bare `...` so a cimport like
  # `printf(format, ...)` declares its variadic tail.
  if ftype.args.len > args.len:
    params.add "..."
  let paramStr = params.join(", ")
  var decl: string
  if ftype.returns.len > 1:
    decl = multiRetTag(ftype.returns) & " " & codename & "(" & paramStr & ")"
  else:
    let retType = if ftype.returns.len == 1: ftype.returns[0] else: nil
    decl = cFuncDecl(retType, codename, paramStr)
  var attrs = ""
  if a != nil and a.isInline: attrs &= "__attribute__((always_inline)) inline "
  if a != nil and a.cexport: attrs &= "__attribute__((visibility(\"default\"))) "
  if a != nil and a.cimport:
    # See genForwardDecl: a `<cinclude>` in the same annotation set already
    # declares the symbol, so do not emit a conflicting `extern` re-declaration.
    if a.cinclude.len == 0:
      s.line "extern " & decl & ";"
    return
  s.line attrs & decl & " {"
  s.push
  let oldInFunc = s.inFunc
  let oldReturns = s.currentReturns
  s.inFunc = true
  s.currentReturns = ftype.returns
  s.genScope(node.children[^1], dkFunc)
  s.inFunc = oldInFunc
  s.currentReturns = oldReturns
  s.pop
  s.line "}"

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc genC*(source: string, path: string, release = false, nochecks = false,
           config: Config = defaultConfig()): string =
  ## Analyze `source` (at `path`) and emit a single self-contained `.c` file.
  ## On analysis failure returns a diagnostic comment.
  ##
  ## `config` is threaded through to `analyze` so that `require` resolution sees
  ## the same `--path` entries the driver does -- otherwise a `--path` module
  ## would compile (phase 1a) but its symbols would never be imported, since
  ## `analyze` would fall back to `defaultConfig()`.
  let res = analyze(source, path, config)
  if res.root == nil:
    return "/* nelua: unable to analyze " & path & " (parse error, see stderr) */"
  # Surface M6 preprocessor diagnostics through the existing nelua stub channel
  # (compile.nim detects `cSource.startsWith("/* nelua")`), so the driver and
  # `--print-analyzed-ast` inherit them with no signature change.
  if res.ctx.diags.len > 0:
    return "/* nelua: " & res.ctx.diags.join("; ") & " */"

  var s: Gen
  s.ctx = res.ctx
  s.release = release
  # `check` is elided when the `nochecks` pragma is active.  The driver passes
  # `nochecks=false` literally (see compile.nim), so we also consult
  # `config.pragmas` here -- `-P nochecks` lands there -- otherwise a program
  # compiled with `-P nochecks` would still emit `check` guards.
  s.nochecks = nochecks or "nochecks" in config.pragmas
  s.typeSeen = initTable[int, bool]()
  s.multiRetSeen = initTable[string, bool]()

  # D2: emit every `require` dependency's library code inline in this
  # translation unit, in dependency order, followed by this unit's own code.
  # Only the final (this) unit gets the nelua_main driver entry; the dependency
  # `.c` files `compile.nim` still writes to the cache are separate translation
  # units that `compile()` does not link, so they are harmless orphans.
  #
  # `res.deps` holds only the *direct* dependencies; flatten transitively so a
  # dependency of a dependency is emitted before the dependent that uses it.
  # `flattenDeps(res)` yields [..transitive deps in order.., res].
  proc flattenDeps(r: AnalyzerResult): seq[AnalyzerResult] =
    for d in r.deps:
      result &= flattenDeps(d)
    result.add r
  var results = flattenDeps(res)

  # Collect types and function definitions from every result.
  proc hasAutoParam(t: Type): bool =
    if t == nil or t.kind != tkFunction: return false
    for a in t.args:
      if a != nil and a.kind == tkAuto: return true
    for r in t.returns:
      if r != nil and r.kind == tkAuto: return true
    return false

  for r in results:
    s.ctx = r.ctx
    s.collectNode(r.root)
    for spec in r.specials:
      s.collectNode(spec)

  # Ordered (funcDef node, owning-result index) pairs, dependencies first.
  var funcEntries: seq[tuple[node: Node, ridx: int]] = @[]
  for i, r in pairs(results):
    var fds: seq[Node] = @[]
    collectFuncDefs(r.root, fds)
    for fd in fds:
      let fa = r.ctx.attrOf.getOrDefault(fd)
      if not hasAutoParam(if fa != nil: fa.typ else: nil):
        funcEntries.add (fd, i)
    for spec in r.specials:
      let sa = r.ctx.attrOf.getOrDefault(spec)
      if not hasAutoParam(if sa != nil: sa.typ else: nil):
        funcEntries.add (spec, i)

  # 1. includes / runtime preamble: emitted at the END from Gen.refs (see
  # genPreamble), after every helper-usage site has recorded what this TU calls.

  # 2. type descriptors + composite typedefs
  for t in s.typesSeq:
    s.emitTypedef(t)
  for rets in s.multiRetList:
    s.emitMultiRet(rets)

  # 3. forward declarations (all results, dependency order)
  for (fd, i) in funcEntries:
    s.ctx = results[i].ctx
    s.genForwardDecl(fd)

  # 3b. file-scope static declarations, BEFORE function definitions. Every
  # module-level VarDecl is lowered to `static <type> <name>;` here so that
  # nested functions emitted as free functions can reference it. This is what
  # makes module-scope capture (the only closure form Nelua supports) actually
  # compile. The initializers still run inside nelua_main, in source order, so
  # view semantics are preserved (the closure and the reassignment share one
  # static).
  for r in results:
    s.ctx = r.ctx
    for c in r.root.children:
      if c.kind == nkVarDecl:
        s.genVarDecl(c, emitInits=false, isGlobal=true)

  # 4. cimports are emitted as externs inside genForwardDecl; no separate pass.

  # 5. function definitions (all results, dependency order)
  for (fd, i) in funcEntries:
    s.ctx = results[i].ctx
    s.genFuncDef(fd)

  # 6. nelua_main: global initializers + top-level statements, then the driver.

  s.line "int nelua_main(void) {"
  s.push
  s.inFunc = false
  s.currentReturns = @[]
  # Run each result's top-level code (global initializers + statements) in
  # dependency order, so a required module's globals are initialized before the
  # requiring module references them.
  for r in results:
    s.ctx = r.ctx
    s.pushDefer(dkFunc)
    for c in r.root.children:
      if c.kind == nkVarDecl:
        # Step 3b already emitted the `static` declaration for every
        # module-level VarDecl; here we only run its initializer.  Pass
        # alreadyDeclared=true so the init branch does not re-declare it (a
        # block-scoped local nested in this scope is NOT a direct child and
        # still reaches genStmt with alreadyDeclared=false).
        s.genVarDecl(c, emitInits=true, isGlobal=false, alreadyDeclared=true)
      elif c.kind != nkFuncDef:
        s.genStmt(c)
    let defers = s.deferStack[^1][1]
    for i in countdown(defers.len - 1, 0):
      s.genBody(defers[i].children[0])
    discard s.deferStack.pop()
  s.line "return 0;"
  s.pop
  s.line "}"
  s.line "int main(int argc, char** argv) { (void)argc; (void)argv; return nelua_main(); }"

  if s.unsupported:
    return "/* nelua: " & s.unsupportedMsg & " */"
  return genPreamble(s.refs) & s.buf

# ---------------------------------------------------------------------------
# Self-test: assert the emitted C string's shape for small programs.
# ---------------------------------------------------------------------------

when isMainModule:
  let src1 = "local x: integer = 1 + 2\nlocal function add(a: integer, b: integer): integer\n  return a + b\nend\nprint(add(x, 3))\n"
  let out1 = genC(src1, "test.nelua")
  echo "=== generated C (prog1) ==="
  echo out1
  doAssert out1.contains("nelua_main"), "missing nelua_main"
  doAssert out1.contains("int64_t"), "missing int64_t"
  doAssert out1.contains("add"), "missing add"
  doAssert out1.contains("nelua_print"), "missing print"
  doAssert out1.contains("static int64_t"), "missing global decl"
  doAssert out1.contains("return (a + b)"), "missing function body"
  doAssert out1.contains("test_add"), "missing mangled function name"
  doAssert out1.contains("test_x"), "missing mangled global name"

  let src2 = "local function pair(a: integer, b: integer): (integer, integer)\n  return a, b\nend\nlocal x, y = pair(1, 2)\nprint(x, y)\n"
  let out2 = genC(src2, "test2.nelua")
  echo "=== generated C (prog2, multi-return) ==="
  echo out2
  doAssert out2.contains("nlmr_"), "missing multi-return struct"
  doAssert out2.contains("return (struct nlmr_"), "missing multi-return compound literal"

  let src3 = "local i = 42\nlocal f = 3.14\nlocal s = \"hello\"\nlocal b = true\nlocal r = 1 + 2 * 3\nprint(i, f, s, b, r)\n"
  let out3 = genC(src3, "test3.nelua")
  echo "=== generated C (prog3, literals) ==="
  echo out3
  doAssert out3.contains("nlstr("), "missing string literal wrapping"
  doAssert out3.contains("true"), "missing bool literal"
  doAssert out3.contains("3.14"), "missing number literal"

  # Corpus smoke test: genC must not crash and must emit a nelua_main for every
  # M2 conformance program.
  let corpusDir = "tmp/m2_corpus"
  if dirExists(corpusDir):
    var corpusTotal = 0
    var corpusOk = 0
    for f in walkFiles(corpusDir & "/*.nelua"):
      inc corpusTotal
      let src = readFile(f)
      let outp = genC(src, f)
      if outp.len > 0 and outp.contains("nelua_main"):
        inc corpusOk
        echo "CORPUS OK: " & f
      else:
        echo "CORPUS FAIL: " & f
        echo outp
    echo "corpus: ", corpusOk, "/", corpusTotal, " emitted nelua_main without crashing"

  # Regression: the folded analyze-failure stub channel (which the M6 preprocessor
  # diags also feed) still works end to end.
  let badSrc = "local x =\n"
  let badOut = genC(badSrc, "bad.nelua")
  doAssert badOut.startsWith("/* nelua"), "parse failure must surface as a nelua stub"
  echo "FAILPATH PASS: parse failure surfaces as a nelua stub"

  echo "cgen.nim SELF-TEST PASS"