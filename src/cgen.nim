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

const RUNTIME_C = """
/* === nelua runtime (embedded by cgen.nim; src/runtime.c is a later milestone) === */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { const char* data; size_t size; } nlstring;
typedef void* nilptr;
typedef enum {
  NLANY_NIL = 0,
  NLANY_BOOL, NLANY_INT, NLANY_UINT, NLANY_NUM,
  NLANY_STRING, NLANY_POINTER, NLANY_TABLE, NLANY_FUNC, NLANY_TYPE
} nlany_tag;

typedef struct {
  nlany_tag tag;
  union {
    uint8_t b; int64_t i; uint64_t u; double n;
    nlstring s; void* p;
  } as;
} nlany;
struct nltype;
typedef struct nltype nltype;

/* Narrow-check macros.  Debug builds call runtime panic helpers; release
   builds (NLNOCHECK defined) elide them entirely.  Each macro returns the
   checked value so it can be used inline in an expression. */
#ifndef NLNOCHECK
void nlcheck_int_overflow(int64_t x, const char* what);
void nlcheck_uint_overflow(uint64_t x, const char* what);
void nlcheck_float_overflow(double x, const char* what);
#define nlcheck_int(x)   (nlcheck_int_overflow((int64_t)(x), "int"), (int64_t)(x))
#define nlcheck_uint(x)  (nlcheck_uint_overflow((uint64_t)(x), "uint"), (uint64_t)(x))
#define nlcheck_float(x) (nlcheck_float_overflow((double)(x), "float"), (double)(x))
#else
#define nlcheck_int(x)   ((int64_t)(x))
#define nlcheck_uint(x)  ((uint64_t)(x))
#define nlcheck_float(x) ((double)(x))
#endif

/* Builtin / runtime helpers.  Definitions live in src/runtime.c; here only the
   declarations so the emitted translation unit links.  C7: nelua_print is gone;
   each typed helper takes exactly one argument, so the C generator can emit one
   call per argument and the argument order is guaranteed correct. */
void nelua_print_int64(int64_t v);
void nelua_print_uint64(uint64_t v);
void nelua_print_double(double d);
void nelua_print_string(nlstring s);
void nelua_print_bool(int b);
void nelua_print_nil(void);
void nelua_print_ptr(void* v);
void nelua_print_sep(void);
void nelua_print_newline(void);
extern FILE* nl_out;
nlstring nlstr(const char* s);
nlstring nlstring_concat(nlstring a, nlstring b);
void nlstring_free(nlstring* s);
int64_t nlidiv(int64_t a, int64_t b);
int64_t nlmod(int64_t a, int64_t b);
double nlpow(double a, double b);
int64_t nllen(nlstring s);
void nlclose(void* p);
extern const nltype nltype_of_int64;
extern const nltype nltype_of_double;
extern const nltype nltype_of_bool;
extern const nltype nltype_of_string;

/* `any` runtime helpers.  Definitions live in src/runtime.c; here only the
   declarations so the emitted translation unit links.  The construction set
   wraps a typed value into a tagged `nlany`; nelua_print_any dispatches print
   by tag; the load/eq helpers are phase 2b plumbing, declared now so the
   preamble stays stable when they are wired in. */
nlany nlany_from_nil(void);
nlany nlany_from_bool(uint8_t v);
nlany nlany_from_int(int64_t v);
nlany nlany_from_uint(uint64_t v);
nlany nlany_from_num(double v);
nlany nlany_from_string(nlstring v);
nlany nlany_from_ptr(void* v);
void nelua_print_any(nlany v);
int64_t  nlany_load_int(nlany v);
uint64_t nlany_load_uint(nlany v);
double   nlany_load_num(nlany v);
uint8_t  nlany_load_bool(nlany v);
nlstring nlany_load_string(nlany v);
void*    nlany_load_ptr(nlany v);
bool nlany_eq(nlany a, nlany b);

/* Exception / panic primitives.  Definitions are inline here (rather than in
   src/runtime.c) so every emitted translation unit is self-contained; they are
   `static` so dependency `.c` files that never use them produce no linkage
   symbols and no unused-function warnings.  `error`/`assert`/`check` raise a
   fatal "runtime error:" and abort; `panic` prints its message and aborts. */

static inline void nelua_abort(void) {
  abort();
}

static inline void nelua_error_line(nlstring msg) {
  fwrite("runtime error: ", 1, sizeof("runtime error: ") - 1, stderr);
  if (msg.size > 0 && msg.data) {
    fwrite(msg.data, 1, msg.size, stderr);
  }
  fwrite("\n", 1, 1, stderr);
  fflush(stderr);
  nelua_abort();
}

static inline void nelua_panic_string(nlstring s) {
  if (s.size > 0 && s.data) {
    fwrite(s.data, 1, s.size, stderr);
  }
  fwrite("\n", 1, 1, stderr);
  fflush(stderr);
  nelua_abort();
}

static inline void nelua_assert_line(bool cond, nlstring msg) {
  if (!cond) {
    nelua_error_line(msg);
  }
}

/* Float32 print.  The oracle formats a `float` with %.7g (its runtime's
   print_float) and a `double` with %.14g (print_double, defined in
   src/runtime.c).  A float32 value shown at double precision gains digits that
   are not in the oracle's output, so route `float` through this inline helper
   rather than through nelua_print_double.  Self-contained (static) so a TU
   that never prints a float carries no linkage symbol. */
static inline void nelua_print_float(float v) {
  char buf[64];
  snprintf(buf, sizeof buf, "%.7g", (double)v);
  /* Mirror the suffix logic in nelua_print_double (src/runtime.c): %.7g drops
     the trailing ".0" for integral values, so the oracle's print_float would
     render `75.0` as `75`.  Re-append ".0" when the buffer has no decimal
     point and no exponent -- except for the bare inf/nan words, which the
     oracle prints as-is. */
  if (strcmp(buf, "inf") != 0 && strcmp(buf, "-inf") != 0 &&
      strcmp(buf, "nan") != 0 && strcmp(buf, "-nan") != 0 &&
      strchr(buf, '.') == NULL && strchr(buf, 'e') == NULL &&
      strchr(buf, 'E') == NULL) {
    strcat(buf, ".0");
  }
  fputs(buf, nl_out);
}
"""

# ---------------------------------------------------------------------------
# Generator state
# ---------------------------------------------------------------------------

type
  DeferScopeKind = enum
    dkBlock
    dkFunc
    dkLoop
  Gen = object
    ctx: AnalyzerContext
    release*: bool
    nochecks*: bool
    buf: string
    indent: int
    inFunc: bool               ## true while emitting a function body (locals)
    currentReturns: seq[Type]  ## return types of the function being emitted
    mrCounter: int             ## unique temp name counter for multi-returns
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
          return "nlcheck_int(" & cCast(toT, expr) & ")"
        elif fromT.isFloat or toT.isFloat:
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
      return "nlany_from_nil()"
    if fromT.isBoolean:
      return "nlany_from_bool(" & expr & ")"
    if fromT.isStringy:
      return "nlany_from_string(" & expr & ")"
    if fromT.isIntegral:
      return (if fromT.isUnsigned: "nlany_from_uint(" else: "nlany_from_int(") & expr & ")"
    if fromT.isFloat:
      return "nlany_from_num(" & expr & ")"
    if fromT.isPointer or fromT.isFunction:
      return "nlany_from_ptr(" & expr & ")"
    # record / table value -> any: store its address (a record value has no
    # single address until it is on the stack; the sources here are lvalues --
    # a variable, a field, or a compound literal -- so address-of is valid).
    return "nlany_from_ptr((void*)(&(" & expr & ")))"
  of ckAnyLoad:
    # any -> T: extract the payload with a runtime tag check.
    if toT.isStringy:
      return "nlany_load_string(" & expr & ")"
    if toT.isBoolean:
      return "nlany_load_bool(" & expr & ")"
    if toT.isIntegral:
      return (if toT.isUnsigned: "nlany_load_uint(" else: "nlany_load_int(") & expr & ")"
    if toT.isFloat:
      return "nlany_load_num(" & expr & ")"
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
    if stringy: return "nlstring_concat(" & lstr & ", " & rstr & ")"
    return "(" & lstr & " + " & rstr & ")"
  of "-": return "(" & lstr & " - " & rstr & ")"
  of "*": return "(" & lstr & " * " & rstr & ")"
  of "/": return "(" & lstr & " / " & rstr & ")"
  of "//": return "nlidiv(" & lstr & ", " & rstr & ")"
  of "%": return "nlmod(" & lstr & ", " & rstr & ")"
  of "^": return "nlpow(" & lstr & ", " & rstr & ")"
  of "..": return "nlstring_concat(" & lstr & ", " & rstr & ")"
  of "<<": return "(" & lstr & " << " & rstr & ")"
  of ">>": return "(" & lstr & " >> " & rstr & ")"
  of "&": return "(" & lstr & " & " & rstr & ")"    ## band
  of "|": return "(" & lstr & " | " & rstr & ")"
  of "~": return "(" & lstr & " ^ " & rstr & ")"    ## bxor (C ^ is free: Nelua ^ is power)
  of "<": return "(" & lstr & " < " & rstr & ")"
  of ">": return "(" & lstr & " > " & rstr & ")"
  of "<=": return "(" & lstr & " <= " & rstr & ")"
  of ">=": return "(" & lstr & " >= " & rstr & ")"
  of "==": return "(" & lstr & " == " & rstr & ")"
  of "~=": return "(" & lstr & " != " & rstr & ")"
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
    if rt != nil and rt.kind == tkArray: return "nlarrlen(" & rstr & ")"
    # M1: a record with a `__len` metamethod dispatches through it instead of
    # the string-length helper (which expects nlstring and rejects records).
    if rt != nil and rt.kind == tkRecord and rt.methods.hasKey("__len"):
      return s.genMetaCall(rhs, "__len", @[])
    return "nllen(" & rstr & ")"
  of "not": return "(!" & rstr & ")"
  of "~": return "(~" & rstr & ")"     ## bnot
  of "$": return "(*" & rstr & ")"     ## deref
  of "&": return "(&" & rstr & ")"     ## ref
  else: return "/*uop " & node.str & "*/"

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
      # The oracle only treats the boolean `false` as a failing assertion
      # condition; any other type (integer 0, empty string, ...) is truthy.
      # Emit a literal `true` for non-bool conditions rather than passing the
      # value straight into a `bool` C parameter (which fails to compile for
      # strings and does the wrong thing for integers).
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
  var calleeType: Type = nil
  if ca != nil and ca.typ != nil and ca.typ.kind == tkFunction:
    calleeType = ca.typ
  elif ca != nil and ca.calleeType != nil:
    calleeType = ca.calleeType
  var argstrs: seq[string] = @[]
  for i, arg in args:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let pt = if calleeType != nil and i < calleeType.args.len: calleeType.args[i] else: at
    # C8: a `...: cvarargs` slot is a C variadic tail; varargs arguments are
    # passed through uncoerced (C applies its own promotion rules).  Coercing
    # to the cvarargs type itself would emit `(...)(42)`, which is invalid C.
    if pt != nil and pt.kind == tkCvarargs:
      argstrs.add aes
    else:
      argstrs.add s.coerce(aes, at, pt)
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
        parts.add "." & cIdent(pair.str) & " = " & s.genExpr(pair.children[0]) & ","
    return "((struct " & tag & "){ " & parts.join(" ") & " })"
  # C1: type cast `(T)(e)` -> `(cType(T))(e)`.  The caller attr carries the
  # target type (bound by the analyzer); there is no callee symbol to call, so
  # emit an explicit C cast of the single argument instead of a call expression.
  if ca != nil and ca.calleeType != nil and caller.kind in {nkParen, nkType}:
    let ct = cType(ca.calleeType)
    let argstr = if args.len > 0: argstrs[0] else: "void"
    return "(" & ct & ")(" & argstr & ")"
  case caller.kind
  of nkId:
    let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
    if cn == "nelua_print":
      ## C7: emit one typed call per argument instead of a single variadic
      ## call.  Coercion is ignored -- each argument is passed to its typed
      ## helper unchanged, so mixed-type argument order is preserved exactly.
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
        let call = if passArg: helper & "(" & argStr & ")" else: helper & "()"
        if i > 0: lines.add "nelua_print_sep(); " & call & ";"
        else: lines.add call & ";"
      if lines.len == 0:
        return "nelua_print_newline()"
      lines.add "nelua_print_newline()"
      return lines.join("\n")
    return cn & "(" & argstrs.join(", ") & ")"
  of nkDotIndex:
    let cexpr = s.genExpr(caller)
    return "(" & cexpr & ")(" & argstrs.join(", ") & ")"
  of nkColonIndex:
    let recv = s.genExpr(caller.children[0])
    let cn = if ca != nil and ca.codename != "": ca.codename else: cIdent(caller.str)
    let pre = if argstrs.len > 0: ", " else: ""
    return cn & "(" & recv & pre & argstrs.join(", ") & ")"
  else:
    let cexpr = s.genExpr(caller)
    return "(" & cexpr & ")(" & argstrs.join(", ") & ")"

proc genCallMethod(s: var Gen, node: Node): string =
  let args = node.children[0 ..< node.children.len - 1]
  let recv = node.children[^1]
  let ra = s.ctx.attrOf.getOrDefault(recv)
  let calleeSym = s.ctx.attrOf.getOrDefault(node).calleeSym
  let cn = if calleeSym != nil: calleeSym.codename else: cIdent(node.str)
  var allargs: seq[string] = @[]
  let recvStr = s.genExpr(recv)
  if calleeSym != nil and calleeSym.typ != nil and calleeSym.typ.args.len > 0:
    let p0 = calleeSym.typ.args[0]
    if p0 != nil and p0.kind == tkPointer:
      # The implicit `self` param is `*Record`.  When the receiver expression
      # is already that pointer (a colon-method called on `self`, which is the
      # method's own first param) it is passed unchanged; a value receiver
      # (`r:area()` where `r` is a `Rect` value) is passed by address.
      if ra != nil and ra.typ != nil and ra.typ == p0:
        allargs.add recvStr
      else:
        allargs.add "(&" & recvStr & ")"
    else:
      allargs.add recvStr
  else:
    allargs.add recvStr
  let calleeType = s.ctx.attrOf.getOrDefault(node).calleeType
  for i, arg in args:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let pt = if calleeType != nil and i < calleeType.args.len: calleeType.args[i] else: at
    allargs.add s.coerce(aes, at, pt)
  return cn & "(" & allargs.join(", ") & ")"

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
  var allargs: seq[string] = @[]
  if md.ftype != nil and md.ftype.args.len > 0:
    let p0 = md.ftype.args[0]
    if p0 != nil and p0.kind == tkPointer:
      # The implicit `self` param is `*Record`.  A value receiver is passed
      # by address; a receiver that is already that pointer is unchanged.
      if rt != nil and rt.kind == tkPointer and rt == p0:
        allargs.add recvStr
      else:
        allargs.add "(&" & recvStr & ")"
    else:
      allargs.add recvStr
  else:
    allargs.add recvStr
  for i, arg in argNodes:
    let aes = s.genExpr(arg)
    let at = s.ctx.attrOf.getOrDefault(arg).typ
    let pt = if md.ftype != nil and i + 1 < md.ftype.args.len: md.ftype.args[i+1] else: at
    allargs.add s.coerce(aes, at, pt)
  return cn & "(" & allargs.join(", ") & ")"

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
      if ft != nil and ft.kind == tkArray and child.kind == nkInitList:
        parts.add "." & cIdent(c.str) & " = " &
          s.genInitListBraces(child, ft.subtype)
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

proc genInitList(s: var Gen, node: Node): string =
  let a = s.ctx.attrOf.getOrDefault(node)
  let ptype = if a != nil: a.typ else: nil
  if ptype != nil and ptype.kind == tkRecord:
    let tag = cTag(ptype)
    var parts: seq[string] = @[]
    for c in node.children:
      if c.kind == nkPair:
        let ft = fieldOf(ptype, c.str)
        if ft != nil and ft.kind == tkArray and c.children.len > 0 and
           c.children[0].kind == nkInitList:
          ## An array field inside a record compound literal must be given a
          ## bare brace-enclosed initializer (`.v = { ... }`); a cast compound
          ## literal (`.v = (uint32_t[N]){ ... }`) is ill-formed in C.
          parts.add "." & cIdent(c.str) & " = " &
            s.genInitListBraces(c.children[0], ft.subtype)
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
        if ft != nil and ft.kind == tkArray and c.children.len > 0 and
           c.children[0].kind == nkInitList:
          parts.add "." & cIdent(c.str) & " = " &
            s.genInitListBraces(c.children[0], ft.subtype)
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
    let baseStr = s.genExpr(node.children[0])
    let keyStr = s.genExpr(node.children[1])
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
  for i in 0 ..< ntargets:
    let t = node.children[i]
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
    let rets = s.ctx.callRetTypes.getOrDefault(callNode)
    if rets.len == ntargets and rets.len > 1:
      let tag = multiRetTag(rets)
      inc s.mrCounter
      let tmp = "__mr" & $s.mrCounter
      s.line tag & " " & tmp & " = " & s.genCall(callNode) & ";"
      for i in 0 ..< ntargets:
        s.line targets[i] & " = " & tmp & ".field" & $i & ";"
      return
  for i in 0 ..< min(targets.len, values.len):
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

  # 1. includes / runtime preamble
  s.g(RUNTIME_C)
  s.line ""

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
  return s.buf

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