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

typedef struct { const char* data; size_t size; } nlstring;
typedef void* nilptr;
typedef void* nlany;
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
void nelua_print_sep(void);
void nelua_print_newline(void);
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
"""

# ---------------------------------------------------------------------------
# Generator state
# ---------------------------------------------------------------------------

type
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
    deferStack: seq[seq[Node]]
    funcDefs: seq[Node]

proc g(s: var Gen, text: string) =
  s.buf.add text

proc line(s: var Gen, text: string) =
  s.buf.add "  ".repeat(s.indent) & text & "\n"

proc push(s: var Gen) = inc s.indent
proc pop(s: var Gen) = dec s.indent

# Forward declarations for the mutually-recursive expression/statement visitors.
proc genExpr(s: var Gen, node: Node): string
proc genBinaryOp(s: var Gen, node: Node): string
proc genUnaryOp(s: var Gen, node: Node): string
proc genCall(s: var Gen, node: Node): string
proc genCallMethod(s: var Gen, node: Node): string
proc genDotIndex(s: var Gen, node: Node): string
proc genKeyIndex(s: var Gen, node: Node): string
proc genInitList(s: var Gen, node: Node): string
proc genLvalue(s: var Gen, node: Node): string
proc genStmt(s: var Gen, node: Node)
proc genStmts(s: var Gen, node: Node)
proc genScope(s: var Gen, node: Node)
proc genBody(s: var Gen, node: Node)
proc coerce(s: var Gen, expr: string, fromT: Type, toT: Type): string
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
      s.line cType(f.typ) & " " & cIdent(f.name) & ";"
    s.pop
    s.line "} " & tag & ";"
  of tkUnion:
    let tag = cTag(t)
    s.line "typedef union " & tag & " {"
    s.push
    for f in t.fields:
      s.line cType(f.typ) & " " & cIdent(f.name) & ";"
    s.pop
    s.line "} " & tag & ";"
  of tkEnum:
    let tag = cTag(t)
    s.line "typedef enum " & tag & " {"
    s.push
    for i, ef in t.enumFields:
      let comma = if i < t.enumFields.len - 1: "," else: ""
      s.line ef.name & " = " & $ef.value & comma
    s.pop
    s.line "} " & tag & ";"
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
  s.line "typedef struct {"
  s.push
  for i, r in rets:
    s.line cType(r) & " field" & $i & ";"
  s.pop
  s.line "} " & tag & ";"

proc fieldOf(t: Type, name: string): Type =
  for f in t.fields:
    if f.name == name: return f.typ
  return nil

# ---------------------------------------------------------------------------
# Conversion / narrow-check lowering (M3_design §4)
# ---------------------------------------------------------------------------

proc coerce(s: var Gen, expr: string, fromT: Type, toT: Type): string =
  if fromT == nil or toT == nil: return expr
  if fromT == toT: return expr
  let conv = convert(fromT, toT, false)
  case conv.kind
  of ckIdentity:
    return expr
  of ckNone:
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
      return expr   # widening: C's own promotion applies
  of ckNarrow:
    return cCast(toT, expr)

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
  let rtype = s.ctx.attrOf.getOrDefault(node).typ
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
    return "nllen(" & rstr & ")"
  of "not": return "(!" & rstr & ")"
  of "~": return "(~" & rstr & ")"     ## bnot
  of "$": return "(*" & rstr & ")"     ## deref
  of "&": return "(&" & rstr & ")"     ## ref
  else: return "/*uop " & node.str & "*/"

proc genCall(s: var Gen, node: Node): string =
  let caller = node.children[^1]
  let args = node.children[0 ..< node.children.len - 1]
  let ca = s.ctx.attrOf.getOrDefault(caller)
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
    argstrs.add s.coerce(aes, at, pt)
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
        if at != nil:
          case at.kind
          of tkInteger: helper = "nelua_print_int64"; passArg = true
          of tkUinteger: helper = "nelua_print_uint64"; passArg = true
          of tkNumber, tkFloat32, tkFloat64: helper = "nelua_print_double"; passArg = true
          of tkString: helper = "nelua_print_string"; passArg = true
          of tkBoolean: helper = "nelua_print_bool"; passArg = true
          of tkNilptr, tkPointer: helper = "nelua_print_nil"; passArg = false
          else: helper = "nelua_print_nil"; passArg = false
        let call = if passArg: helper & "(" & aes & ")" else: helper & "()"
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

proc genDotIndex(s: var Gen, node: Node): string =
  let base = node.children[0]
  let ba = s.ctx.attrOf.getOrDefault(base)
  let bt = if ba != nil: ba.typ else: nil
  let baseStr = s.genExpr(base)
  let field = cIdent(node.str)
  if bt != nil and bt.kind == tkPointer and bt.subtype != nil and
     bt.subtype.kind in {tkRecord, tkUnion}:
    return baseStr & "->" & field
  return baseStr & "." & field

proc genKeyIndex(s: var Gen, node: Node): string =
  let base = node.children[0]
  let ba = s.ctx.attrOf.getOrDefault(base)
  let bt = if ba != nil: ba.typ else: nil
  if bt != nil and bt.kind == tkTable:
    s.unsupported = true
    s.unsupportedMsg = "table indexing is not implemented"
    return "/*table*/"
  let baseStr = s.genExpr(base)
  let keyStr = s.genExpr(node.children[1])
  return baseStr & "[" & keyStr & "]"

proc genInitList(s: var Gen, node: Node): string =
  let a = s.ctx.attrOf.getOrDefault(node)
  let ptype = if a != nil: a.typ else: nil
  if ptype != nil and ptype.kind == tkRecord:
    let tag = cTag(ptype)
    var parts: seq[string] = @[]
    for c in node.children:
      if c.kind == nkPair:
        let ft = fieldOf(ptype, c.str)
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
        let val = s.genExpr(c.children[0])
        let vt = s.ctx.attrOf.getOrDefault(c.children[0]).typ
        parts.add "." & cIdent(c.str) & " = " & s.coerce(val, vt, ft)
      else:
        parts.add s.genExpr(c)
    return "(union " & tag & "){" & parts.join(", ") & "}"
  if ptype != nil and ptype.kind == tkArray:
    let et = ptype.subtype
    var parts: seq[string] = @[]
    for c in node.children:
      let valc = if c.kind == nkPair: c.children[0] else: c
      let val = s.genExpr(valc)
      let va = s.ctx.attrOf.getOrDefault(valc)
      let vt = if va != nil: va.typ else: nil
      parts.add s.coerce(val, vt, et)
    return "(" & cType(ptype) & "){" & parts.join(", ") & "}"
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

proc genScope(s: var Gen, node: Node) =
  ## Emit the statements of `node` and its defers, with no surrounding braces.
  s.deferStack.add @[]
  if node != nil:
    s.genStmts(node)
  let defers = s.deferStack[^1]
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

proc genVarDecl(s: var Gen, node: Node, emitInits: bool, isGlobal: bool) =
  var iddecls: seq[Node] = @[]
  var inits: seq[Node] = @[]
  for c in node.children:
    if c.kind == nkIdDecl: iddecls.add c
    else: inits.add c

  if not emitInits:
    for iddecl in iddecls:
      let a = s.ctx.attrOf.getOrDefault(iddecl)
      let vtype = if a != nil: a.typ else: nil
      if vtype == nil: continue
      let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
      var qual = ""
      if isGlobal: qual &= "static "
      if a != nil and a.isConst: qual &= "const "
      if a != nil and a.isVolatile: qual &= "volatile "
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
        let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
        s.line cn & " = " & tmp & ".field" & $i & ";"
      return
  for i in 0 ..< min(iddecls.len, inits.len):
    let iddecl = iddecls[i]
    let init = inits[i]
    let a = s.ctx.attrOf.getOrDefault(iddecl)
    let cn = if a != nil and a.codename != "": a.codename else: cIdent(iddecl.str)
    let vt = if a != nil: a.typ else: nil
    let it = s.ctx.attrOf.getOrDefault(init).typ
    if vt != nil and vt.kind == tkArray and init.kind == nkInitList:
      ## C does not allow assigning to an array variable, so an array
      ## init-list is lowered to a memcpy from the compound literal (which
      ## also zero-fills any trailing elements, matching C initializer
      ## semantics).  See `genInitList` for the compound-literal rendering.
      let cl = s.genExpr(init)
      s.line "memcpy(" & cn & ", " & cl & ", sizeof(" & cn & "));"
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
  let cmp = if compop == "ge": ">=" else: "<="
  let stepStr = if step != nil: s.genExpr(step) else: "1"
  s.line "for (" & cType(vtype) & " " & cn & " = " & s.genExpr(beginv) & "; " &
          cn & " " & cmp & " " & s.genExpr(endv) & "; " & cn & " += " & stepStr & ") {"
  s.push
  s.genScope(body)
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
    s.genScope(body)
    s.pop
    s.line "}"
  else:
    s.line "/* for-in iterator lowering not implemented in this slice */"
    s.genBody(body)

proc genReturn(s: var Gen, node: Node) =
  let rets = s.currentReturns
  if rets.len == 0 or (rets.len == 1 and rets[0].isVoid):
    for c in node.children:
      let e = s.genExpr(c)
      if e.len > 0: s.line e & ";"
    s.line "return;"
    return
  if node.children.len == 0:
    s.line "return;"
    return
  if rets.len == 1:
    let c = node.children[0]
    let expr = s.genExpr(c)
    let et = s.ctx.attrOf.getOrDefault(c).typ
    s.line "return " & s.coerce(expr, et, rets[0]) & ";"
  else:
    let tag = multiRetTag(rets)
    var parts: seq[string] = @[]
    for i, c in node.children:
      let expr = s.genExpr(c)
      let et = s.ctx.attrOf.getOrDefault(c).typ
      let rt = if i < rets.len: rets[i] else: nil
      parts.add ".field" & $i & " = " & s.coerce(expr, et, rt)
    s.line "return (struct " & tag & "){" & parts.join(", ") & "};"

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
    s.genScope(node.children[1])
    s.pop
    s.line "}"
  of nkRepeat:
    s.line "do {"
    s.push
    s.genScope(node.children[0])
    s.pop
    s.line "} while(!(" & s.genExpr(node.children[1]) & "));"
  of nkForNum:
    s.genForNum(node)
  of nkForIn:
    s.genForIn(node)
  of nkDefer:
    s.deferStack[^1].add node
  of nkDo:
    s.genBody(node.children[0])
  of nkAssign:
    s.genAssign(node)
  of nkReturn:
    s.genReturn(node)
  of nkBreak:
    s.line "break;"
  of nkContinue:
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
    s.line "#include \"" & cinclude & "\""
  let args = funcArgList(node)
  var params: seq[string] = @[]
  for j, arg in args:
    let at = if j < ftype.args.len: ftype.args[j] else: BuiltinTypes["any"]
    params.add cDecl(at, cIdent(arg.str))
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
  s.genScope(node.children[^1])
  s.inFunc = oldInFunc
  s.currentReturns = oldReturns
  s.pop
  s.line "}"

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc genC*(source: string, path: string, release = false, nochecks = false): string =
  ## Analyze `source` (at `path`) and emit a single self-contained `.c` file.
  ## On analysis failure returns a diagnostic comment.
  let res = analyze(source, path)
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
  s.nochecks = nochecks
  s.typeSeen = initTable[int, bool]()
  s.multiRetSeen = initTable[string, bool]()
  s.collectNode(res.root)
  collectFuncDefs(res.root, s.funcDefs)

  # D1: a polymorphic (`auto`-param) FuncDef has no direct C form -- it is
  # replaced by its monomorphized specializations.  Drop the originals and append
  # the specializations the analyzer produced (uncalled auto functions have no
  # specialization, so they emit nothing: dead-code elimination).
  proc hasAutoParam(t: Type): bool =
    if t == nil or t.kind != tkFunction: return false
    for a in t.args:
      if a != nil and a.kind == tkAuto: return true
    for r in t.returns:
      if r != nil and r.kind == tkAuto: return true
    return false
  var filtered: seq[Node] = @[]
  for fd in s.funcDefs:
    let fa = res.ctx.attrOf.getOrDefault(fd)
    if hasAutoParam(if fa != nil: fa.typ else: nil): discard
    else: filtered.add fd
  s.funcDefs = filtered
  for spec in res.specials:
    s.collectNode(spec)
    s.funcDefs.add spec

  # 1. includes / runtime preamble
  s.g(RUNTIME_C)
  s.line ""

  # 2. type descriptors + composite typedefs
  for t in s.typesSeq:
    s.emitTypedef(t)
  for rets in s.multiRetList:
    s.emitMultiRet(rets)

  # 3. forward declarations
  for fd in s.funcDefs:
    s.genForwardDecl(fd)

  # 4. cimports are emitted as externs inside genForwardDecl; no separate pass.

  # 5. function definitions
  for fd in s.funcDefs:
    s.genFuncDef(fd)

  # 6. globals (file-scope declarations) + nelua_main
  var globals: seq[Node] = @[]
  var topstmts: seq[Node] = @[]
  for c in res.root.children:
    if c.kind == nkFuncDef: discard
    elif c.kind == nkVarDecl: globals.add c
    else: topstmts.add c

  for g in globals:
    s.genVarDecl(g, emitInits=false, isGlobal=true)

  s.line "int nelua_main(void) {"
  s.push
  s.inFunc = false
  s.currentReturns = @[]
  s.deferStack.add @[]
  for g in globals:
    s.genVarDecl(g, emitInits=true, isGlobal=false)
  for st in topstmts:
    s.genStmt(st)
  let defers = s.deferStack[^1]
  for i in countdown(defers.len - 1, 0):
    s.genBody(defers[i].children[0])
  s.line "return 0;"
  s.pop
  s.line "}"
  s.line "int main(int argc, char** argv) { (void)argc; (void)argv; return nelua_main(); }"
  discard s.deferStack.pop()

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