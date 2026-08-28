## Nelua-in-Nim semantic analyzer (M2 part C, Task 3).
##
## Consumes the M1 AST from `parser.nim`, attaches an `Attr` payload to every node
## (in place, via `AnalyzerContext.attrOf`) using the real `types.nim`/`sema.nim`
## interface, then renders the analyzed tree with `dumpAnaled` in the exact format
## the reference compiler emits under `--print-analyzed-ast` (the acceptance bar).
##
## Pipeline: P0 bootstrap builtins -> P3 register declarations -> P4 analyze
## bodies (with constant folding) -> finalize used/mutate -> dump.
##
## The reference `Attr` payload (src/types.nim) is the M4 codegen contract; several
## oracle dump fields it does not carry (ftype, funcdeclared, funcdefined, compop,
## fixedend, fixedstep, builtinType, calleesym/calleetype strings, sideeffect,
## usemultirets, builtin, const) live in the per-node `DumpInfo` side table, which
## the dump printer merges with `Attr`, in alphabetical oracle order.

import ast
import astshapes
import types
import sema
import parser
import span
import preprocessor
import strutils
import tables
import hashes
import sequtils
import os
import math

# Node is a ref object; Table[Node, ..] needs a hash. Key by object identity
# (pointer address), which is stable across the analysis pass.
proc hash(n: Node): Hash =
  Hash(cast[uint](n))

# ---- DumpInfo: per-node fields the oracle dump needs that Attr does not carry --

type
  DumpInfo* = ref object
    builtin*: bool            ## Id: refers to a builtin symbol
    isConst*: bool            ## Id: `const` flag (rendered as oracle `const`)
    builtinType*: string      ## Call: builtin callee type string
    calleeSymStr*: string     ## Call: oracle `calleesym`
    calleeTypeStr*: string    ## Call: oracle `calleetype`
    sideeffect*: bool         ## Call: builtin call has side effects
    usemultirets*: bool       ## Call: multi-return call
    ftype*: string            ## FuncDef/name-IdDecl/func-ref-Id: function type str
    funcdeclared*: bool       ## FuncDef/name-IdDecl/func-ref-Id
    funcdefined*: bool        ## FuncDef/name-IdDecl/func-ref-Id
    compop*: string           ## ForNum: "le" / "ge"
    fixedend*: bool           ## ForNum
    fixedstep*: string        ## ForNum

  AnalyzerContext* = object
    source*: string
    path*: string
    unitname*: string
    attrOf*: Table[Node, Attr]
    symOf*: Table[Node, Symbol]
    dumpOf*: Table[Node, DumpInfo]
    funcTypeStrOf*: Table[Node, string]  ## nameNode -> rendered function type string
    scope*: Scope
    globals*: Scope
    assignTargets*: Table[Node, int]
    ifBranchCount*: Table[Node, int]
    ifHasElse*: Table[Node, bool]
    callRetTypes*: Table[Node, seq[Type]]
    multiRetCall*: Node
    diags*: seq[string]                  ## preprocessor diagnostics

  AnalyzerResult* = object
    root*: Node
    ctx*: AnalyzerContext

# ---- unitname -----------------------------------------------------------------

proc computeUnitname*(path: string): string =
  let name = path.splitFile().name
  var dir = path.splitFile().dir
  var parts: seq[string] = @[]
  for seg in dir.split('/'):
    if seg != "": parts.add seg.replace('-', '_')
  parts.add name.replace('-', '_')
  return parts.join("_")

# ---- scope / symbol helpers ---------------------------------------------------

proc newScope*(parent: Scope, name: string = ""): Scope =
  Scope(name: name, symbols: initTable[string, Symbol](), parent: parent)

proc register*(ctx: var AnalyzerContext, name: string, kind: SymbolKind,
               typ: Type, node: Node = nil): Symbol =
  let sym = Symbol(name: name, kind: kind, typ: typ, node: node,
                   scope: ctx.scope, codename: "")
  ctx.scope.symbols[name] = sym
  return sym

proc lookup*(ctx: var AnalyzerContext, name: string): Symbol =
  var s = ctx.scope
  while s != nil:
    if s.symbols.hasKey(name): return s.symbols[name]
    s = s.parent
  return nil

# ---- attr / dump access ------------------------------------------------------

proc getAttr*(ctx: var AnalyzerContext, node: Node): var Attr =
  if not ctx.attrOf.hasKey(node):
    ctx.attrOf[node] = Attr()
  return ctx.attrOf[node]

proc getDump*(ctx: var AnalyzerContext, node: Node): var DumpInfo =
  if not ctx.dumpOf.hasKey(node):
    ctx.dumpOf[node] = DumpInfo()
  return ctx.dumpOf[node]

# ---- Nelua-level type string renderer ----------------------------------------
##
## The reference oracle's `type=` strings use Nelua nicknames (int64/float64/
## string/boolean), NOT the C `codename` from types.nim (int64/double/nlstring/
## bool).  This is the renderer the dump printer consumes.

proc neluaTypeName*(t: Type): string =
  if t == nil: return "nil"
  case t.kind
  of tkInteger: "int64"
  of tkUinteger: "uint64"
  of tkIsize: "isize"
  of tkUsize: "usize"
  of tkInt8: "int8"
  of tkUint8: "uint8"
  of tkInt16: "int16"
  of tkUint16: "uint16"
  of tkInt32: "int32"
  of tkUint32: "uint32"
  of tkInt64: "int64"
  of tkUint64: "uint64"
  of tkInt128: "int128"
  of tkUint128: "uint128"
  of tkNumber: "float64"
  of tkFloat32: "float32"
  of tkFloat64: "float64"
  of tkFloat128: "float128"
  of tkBoolean: "boolean"
  of tkString: "string"
  of tkByte: "uint8"
  of tkVoid: "void"
  of tkNiltype: "niltype"
  of tkNilptr: "nilptr"
  of tkPointer:
    if t.subtype == nil or t.subtype.kind == tkVoid: "pointer"
    else: "pointer(" & neluaTypeName(t.subtype) & ")"
  of tkArray:
    let sz = if t.arraySize > 0: $t.arraySize else: "0"
    "array(" & neluaTypeName(t.subtype) & ", " & sz & ")"
  of tkRecord:
    "record{" & t.fields.mapIt(it.name & ": " & neluaTypeName(it.typ)).join(", ") & "}"
  of tkUnion:
    "union{" & t.fields.mapIt(it.name & ": " & neluaTypeName(it.typ)).join(", ") & "}"
  of tkEnum:
    let prim = if t.subtype != nil: neluaTypeName(t.subtype) else: "int64"
    "enum(" & prim & "){" & t.enumFields.mapIt(it.name & "=" & $it.value).join(", ") & "}"
  of tkFunction:
    var parts: seq[string] = @[]
    for i in 0 ..< t.args.len:
      parts.add "a" & $(i + 1) & ": " & neluaTypeName(t.args[i])
    var rparts: seq[string] = @[]
    for r in t.returns: rparts.add neluaTypeName(r)
    let rs = if rparts.len == 0: "void"
             elif rparts.len == 1: rparts[0]
             else: "(" & rparts.join(", ") & ")"
    "function(" & parts.join(", ") & "): " & rs
  of tkOptional:
    neluaTypeName(t.subtype) & "?"
  of tkVariant:
    t.args.mapIt(neluaTypeName(it)).join(" | ")
  of tkAuto: "auto"
  of tkAny: "any"
  of tkVarargs, tkVaranys: "varanys"
  of tkTable: "table"
  of tkCstring: "cstring"
  of tkCvarargs: "cvarargs"
  of tkCvalist: "cvalist"
  of tkMetatype, tkTypeof: "type"
  of tkGeneric:
    if t.name != "": return t.name
    else: return "generic"
  else:
    if t.name != "": return t.name
    else: return ""

proc returnsStr*(t: Type): string =
  let rparts = t.returns.mapIt(neluaTypeName(it))
  if rparts.len == 0: "void"
  elif rparts.len == 1: rparts[0]
  else: "(" & rparts.join(", ") & ")"

proc binaryOpName(op: string): string =
  case op
  of "+": "add"
  of "-": "sub"
  of "*": "mul"
  of "/": "div"
  of "//": "idiv"
  of "%": "mod"
  of "^": "pow"
  of "..": "concat"
  of "<": "lt"
  of ">": "gt"
  of "<=": "le"
  of ">=": "ge"
  of "==": "eq"
  of "~=": "ne"
  of "and": "and"
  of "or": "or"
  of "<<": "shl"
  of ">>": "shr"
  of "&": "band"
  of "|": "bor"
  of "~": "bxor"
  else: op

proc unaryOpName(op: string): string =
  case op
  of "-": "unm"
  of "#": "len"
  of "~": "bnot"
  of "$": "deref"
  of "&": "ref"
  else: op

# ---- bootstrap ----------------------------------------------------------------

proc bootstrap*(ctx: var AnalyzerContext) =
  ctx.globals = newScope(nil, "global")
  ctx.scope = ctx.globals
  let anyt = BuiltinTypes["any"]
  let printSym = register(ctx, "print", skBuiltin, anyt)
  printSym.codename = "nelua_print"
  printSym.isConst = true
  printSym.used = true

# ---- literal typing ------------------------------------------------------------

proc numberTypeAndValue(text: string): (Type, string, int) =
  if text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X'):
    let hex = text[2 ..< text.len]
    var iv = 0
    for c in hex:
      let d = if c >= '0' and c <= '9': ord(c) - ord('0')
             elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
             elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
             else: 0
      iv = iv * 16 + d
    return (BuiltinTypes["integer"], $iv, 16)
  if text.contains('.') or text.contains('e') or text.contains('E'):
    let fv = parseFloat(text)
    return (BuiltinTypes["number"], $fv, 10)
  var iv: int
  iv = parseInt(text)
  return (BuiltinTypes["integer"], $iv, 10)

proc stripQuotes(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    return s[1 ..< s.len - 1]
  if s.len >= 2 and s[0] == '\'' and s[^1] == '\'':
    return s[1 ..< s.len - 1]
  return s

proc valueQuoteKind(t: Type): int =
  ## 0 = quote the value, 1 = bare float, 2 = bare bool
  if t == nil: return 0
  if t.kind == tkBoolean: return 2
  if t.isFloat: return 1
  return 0

# ---- constant folding ---------------------------------------------------------

proc tryFoldBinary(op: string, lt: Type, lv: string, rt: Type, rv: string): (Type, string) =
  if op == "..":
    return (BuiltinTypes["string"], lv & rv)
  let li = lt.isIntegral; let ri = rt.isIntegral
  let lf = lt.isFloat; let rf = rt.isFloat
  if li and ri:
    var a: int; a = parseInt(lv)
    var b: int; b = parseInt(rv)
    case op
    of "+": return (lt, $(a + b))
    of "-": return (lt, $(a - b))
    of "*": return (lt, $(a * b))
    of "/": return (BuiltinTypes["number"], $(parseFloat(lv) / parseFloat(rv)))
    of "^": return (BuiltinTypes["number"], $(pow(parseFloat(lv), parseFloat(rv))))
    of "//": return (lt, $(a div b))
    of "%": return (lt, $(a mod b))
    of "<<": return (lt, $(a shl b))
    of ">>": return (lt, $(a shr b))
    of "&": return (lt, $(a and b))
    of "|": return (lt, $(a or b))
    of "~": return (lt, $(a xor b))
    of "<": return (BuiltinTypes["boolean"], $(a < b))
    of ">": return (BuiltinTypes["boolean"], $(a > b))
    of "<=": return (BuiltinTypes["boolean"], $(a <= b))
    of ">=": return (BuiltinTypes["boolean"], $(a >= b))
    of "==": return (BuiltinTypes["boolean"], $(a == b))
    of "~=": return (BuiltinTypes["boolean"], $(a != b))
    of "and": return (BuiltinTypes["boolean"], $(a != 0 and b != 0))
    of "or": return (BuiltinTypes["boolean"], $(a != 0 or b != 0))
  if (lf or rf) and (op in @["+", "-", "*", "/", "//", "%", "^", "<", ">", "<=", ">=", "==", "~="]):
    let a = parseFloat(lv); let b = parseFloat(rv)
    case op
    of "+": return (BuiltinTypes["number"], $(a + b))
    of "-": return (BuiltinTypes["number"], $(a - b))
    of "*": return (BuiltinTypes["number"], $(a * b))
    of "/": return (BuiltinTypes["number"], $(a / b))
    of "//": return (BuiltinTypes["number"], $(a / b))
    of "%": return (BuiltinTypes["number"], $(a mod b))
    of "^": return (BuiltinTypes["number"], $(pow(a, b)))
    of "<": return (BuiltinTypes["boolean"], $(a < b))
    of ">": return (BuiltinTypes["boolean"], $(a > b))
    of "<=": return (BuiltinTypes["boolean"], $(a <= b))
    of ">=": return (BuiltinTypes["boolean"], $(a >= b))
    of "==": return (BuiltinTypes["boolean"], $(a == b))
    of "~=": return (BuiltinTypes["boolean"], $(a != b))
  if op in @["<", ">", "<=", ">=", "==", "~="] and lt.kind == tkBoolean and rt.kind == tkBoolean:
    let a = lv == "true"; let b = rv == "true"
    case op
    of "==": return (BuiltinTypes["boolean"], $(a == b))
    of "~=": return (BuiltinTypes["boolean"], $(a != b))
    of "<": return (BuiltinTypes["boolean"], $(a < b))
    of ">": return (BuiltinTypes["boolean"], $(a > b))
    of "<=": return (BuiltinTypes["boolean"], $(a <= b))
    of ">=": return (BuiltinTypes["boolean"], $(a >= b))
  if op in @["and", "or"]:
    var truthy: bool
    if lt.kind == tkBoolean: truthy = lv == "true"
    else: truthy = lv != "0" and lv != ""
    var truthy2: bool
    if rt.kind == tkBoolean: truthy2 = rv == "true"
    else: truthy2 = rv != "0" and rv != ""
    if op == "and": return (BuiltinTypes["boolean"], $(truthy and truthy2))
    else: return (BuiltinTypes["boolean"], $(truthy or truthy2))
  return (nil, "")

proc tryFoldUnary(op: string, rt: Type, rv: string): (Type, string) =
  case op
  of "unm":
    if rt.isIntegral:
      var a: int; a = parseInt(rv)
      return (rt, $(-a))
    if rt.isFloat:
      return (BuiltinTypes["number"], $(-parseFloat(rv)))
  of "not":
    return (BuiltinTypes["boolean"], $(rv != "true"))
  of "bnot":
    var a: int; a = parseInt(rv)
    return (rt, $((-a - 1)))
  of "len":
    return (BuiltinTypes["usize"], $rv.len)
  return (nil, "")

proc isComptime(node: Node, ctx: AnalyzerContext): bool =
  if node == nil: return false
  case node.kind
  of nkNumber, nkString, nkBoolean, nkNil, nkNilptr: true
  of nkBinaryOp, nkUnaryOp:
    let a = ctx.attrOf.getOrDefault(node)
    a != nil and a.comptime
  else: false

# ---- expression analysis ------------------------------------------------------

proc analyzeExpr*(ctx: var AnalyzerContext, node: Node): Type
proc analyzeTypeExpr*(ctx: var AnalyzerContext, node: Node, usedType = true): Type
proc analyzeBlock(ctx: var AnalyzerContext, node: Node)
proc dumpAnaled*(ctx: var AnalyzerContext, node: Node, indent = 0): string
proc dumpExprString(ctx: var AnalyzerContext, node: Node): string

proc analyzeCall(ctx: var AnalyzerContext, node: Node): Type =
  let caller = node.children[^1]
  let args = node.children[0 ..< node.children.len - 1]
  var a = ctx.getAttr(node)
  var d = ctx.getDump(node)
  var argTypes: seq[Type] = @[]
  for arg in args:
    let t = analyzeExpr(ctx, arg)
    if t != nil: argTypes.add t
  var calleeSym: Symbol = nil
  var calleeType: Type = nil
  if caller.kind == nkId:
    let nm = caller.str
    let sym = ctx.lookup(nm)
    if sym != nil and sym.kind == skBuiltin:
      calleeSym = sym
      calleeType = Type(kind: tkFunction, name: "function", codename: "function")
      calleeType.name = "function"; calleeType.codename = "function"
      for i, at in argTypes:
        calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
      calleeType.returns.add BuiltinTypes["void"]
    elif sym != nil and sym.kind == skFunc:
      calleeSym = sym
      calleeType = sym.typ
    else:
      # unknown: build a generic function type
      calleeType = Type(kind: tkFunction, name: "function", codename: "function")
      calleeType.name = "function"; calleeType.codename = "function"
      for i, at in argTypes:
        calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
      calleeType.returns.add BuiltinTypes["void"]
  # caller Id attr
  var ca = ctx.getAttr(caller)
  if calleeSym != nil and calleeSym.kind == skBuiltin:
    ctx.symOf[caller] = calleeSym
    calleeSym.used = true
    ca.codename = calleeSym.codename
    ca.isConst = true
    ca.name = calleeSym.name
    ca.staticstorage = true
    ca.typ = BuiltinTypes["any"]
    ca.used = true
    var cd = ctx.getDump(caller)
    cd.builtin = true
    cd.isConst = true
  elif calleeSym != nil:
    ctx.symOf[caller] = calleeSym
    calleeSym.used = true
    ca.codename = calleeSym.codename
    ca.comptime = true
    ca.lvalue = true
    ca.name = calleeSym.name
    ca.staticstorage = true
    ca.typ = calleeSym.typ
    ca.used = true
    if calleeSym.kind == skFunc:
      let fs = ctx.funcTypeStrOf.getOrDefault(calleeSym.node)
      ca.value = calleeSym.name & ": " & fs
      var cd = ctx.getDump(caller)
      cd.ftype = fs
      cd.funcdeclared = true
      cd.funcdefined = true
  let ftypeStr = if calleeSym != nil and calleeSym.kind == skBuiltin:
    var parts: seq[string] = @[]
    for i, arg in args:
      let at = if i < argTypes.len: argTypes[i] else: nil
      let ts = if at != nil and at.kind == tkFunction:
        let asym = if arg.kind == nkId: ctx.lookup(arg.str) else: nil
        let fs = if asym != nil and asym.node != nil: ctx.funcTypeStrOf.getOrDefault(asym.node) else: ""
        if fs.len > 0: fs else: neluaTypeName(at)
      else:
        neluaTypeName(if at != nil: at else: BuiltinTypes["any"])
      parts.add "a" & $(i+1) & ": " & ts
    "function(" & parts.join(", ") & "): void"
  elif calleeSym != nil and calleeSym.kind == skFunc:
    ctx.funcTypeStrOf.getOrDefault(calleeSym.node)
  else:
    neluaTypeName(calleeType)
  if calleeSym != nil and calleeSym.kind == skBuiltin:
    d.builtinType = ftypeStr
    d.calleeSymStr = calleeSym.name & ": any"
    d.calleeTypeStr = ftypeStr
    d.sideeffect = true
    a.typ = BuiltinTypes["void"]
  elif calleeSym != nil:
    d.calleeSymStr = calleeSym.name & ": " & ftypeStr
    d.calleeTypeStr = ftypeStr
    if calleeType.returns.len >= 1:
      a.typ = calleeType.returns[0]
    else:
      a.typ = BuiltinTypes["void"]
  else:
    d.calleeSymStr = caller.str & ": " & ftypeStr
    d.calleeTypeStr = ftypeStr
    if calleeType.returns.len >= 1:
      a.typ = calleeType.returns[0]
    else:
      a.typ = BuiltinTypes["void"]
  if node == ctx.multiRetCall:
    d.usemultirets = true
    ctx.callRetTypes[node] = calleeType.returns
  return a.typ

proc analyzeBinaryOp(ctx: var AnalyzerContext, node: Node): Type =
  let lhs = node.children[0]
  let rhs = node.children[1]
  let lt = analyzeExpr(ctx, lhs)
  let rt = analyzeExpr(ctx, rhs)
  let (rtype, lconv, rconv) = inferBinary(node.str, lt, rt)
  var a = ctx.getAttr(node)
  a.typ = rtype
  let lf = isComptime(lhs, ctx); let rf = isComptime(rhs, ctx)
  if lf and rf:
    let lv = ctx.attrOf[lhs].value
    let rv = ctx.attrOf[rhs].value
    let (ft, fv) = tryFoldBinary(node.str, lt, lv, rt, rv)
    if ft != nil:
      a.comptime = true
      a.typ = ft
      a.value = fv
  return rtype

proc analyzeUnaryOp(ctx: var AnalyzerContext, node: Node): Type =
  let rhs = node.children[0]
  let rt = analyzeExpr(ctx, rhs)
  var (rtype, conv) = inferUnary(node.str, rt)
  let nop = case node.str
    of "-": "unm"
    of "#": "len"
    of "~": "bnot"
    of "$": "deref"
    of "&": "ref"
    else: node.str
  if nop == "len" and rtype != nil and rtype.kind == tkInteger:
    rtype = BuiltinTypes["isize"]
  var a = ctx.getAttr(node)
  a.typ = rtype
  if isComptime(rhs, ctx):
    let rv = ctx.attrOf[rhs].value
    let (ft, fv) = tryFoldUnary(nop, rt, rv)
    if ft != nil:
      a.comptime = true
      a.typ = ft
      a.value = fv
  return rtype

proc analyzeDotIndex(ctx: var AnalyzerContext, node: Node): Type =
  let base = node.children[0]
  let bt = analyzeExpr(ctx, base)
  var a = ctx.getAttr(node)
  a.dotFieldName = node.str
  a.lvalue = true
  if bt != nil and bt.kind == tkRecord:
    for f in bt.fields:
      if f.name == node.str:
        a.typ = f.typ
        break
  if a.typ == nil: a.typ = BuiltinTypes["any"]
  return a.typ

proc analyzeInitList(ctx: var AnalyzerContext, node: Node, parentType: Type = nil): Type =
  var a = ctx.getAttr(node)
  a.comptime = true
  let t = if parentType != nil: parentType else: Type(kind: tkRecord)
  a.typ = t
  for c in node.children:
    if c.kind == nkPair:
      var pa = ctx.getAttr(c)
      pa.parentType = t
      discard analyzeExpr(ctx, c.children[0])
  return t

proc analyzePair(ctx: var AnalyzerContext, node: Node): Type =
  discard analyzeExpr(ctx, node.children[0])
  return BuiltinTypes["any"]

proc analyzeExpr*(ctx: var AnalyzerContext, node: Node): Type =
  if node == nil: return nil
  case node.kind
  of nkNumber:
    let (t, val, base) = numberTypeAndValue(node.str)
    var a = ctx.getAttr(node)
    a.base = base
    a.comptime = true
    a.typ = t
    a.value = val
    return t
  of nkString:
    var a = ctx.getAttr(node)
    a.comptime = true
    a.typ = BuiltinTypes["string"]
    a.value = stripQuotes(node.str)
    return a.typ
  of nkBoolean:
    var a = ctx.getAttr(node)
    a.comptime = true
    a.typ = BuiltinTypes["boolean"]
    a.value = $node.boolVal
    return a.typ
  of nkNil:
    var a = ctx.getAttr(node)
    a.comptime = true
    a.typ = BuiltinTypes["nil"]
    return a.typ
  of nkNilptr:
    var a = ctx.getAttr(node)
    a.comptime = true
    a.typ = BuiltinTypes["nilptr"]
    return pointerType(nil)
  of nkId:
    let nm = node.str
    if nm == "nilptr":
      var a = ctx.getAttr(node)
      a.comptime = true
      a.typ = BuiltinTypes["nilptr"]
      return pointerType(nil)
    let sym = ctx.lookup(nm)
    if sym != nil:
      ctx.symOf[node] = sym
      sym.used = true
      var a = ctx.getAttr(node)
      if sym.kind == skBuiltin:
        a.codename = sym.codename
        a.isConst = true
        a.name = nm
        a.staticstorage = true
        a.typ = BuiltinTypes["any"]
        a.used = true
        var d = ctx.getDump(node)
        d.builtin = true
        d.isConst = true
        return a.typ
      else:
        a.codename = sym.codename
        a.lvalue = true
        a.name = nm
        a.typ = sym.typ
        if sym.kind != skParam:
          a.staticstorage = sym.staticstorage
          a.used = true
          if sym.kind == skVar: a.vardecl = sym.vardecl
        if sym.kind == skFunc:
          a.comptime = true
          let fs = if sym.node != nil: ctx.funcTypeStrOf.getOrDefault(sym.node) else: neluaTypeName(sym.typ)
          a.value = nm & ": " & fs
          var d = ctx.getDump(node)
          d.ftype = fs
          d.funcdeclared = true
          d.funcdefined = true
        return sym.typ
    # not in scope: treat as builtin name fallback
    let builtinNames = ["print", "tonumber", "tostring", "type", "error", "assert",
                        "select", "pcall", "setmetatable", "getmetatable", "rawget",
                        "rawset", "rawlen", "rawequal", "unpack", "require",
                        "collectgarbage", "next", "pairs", "ipairs", "len"]
    if nm in builtinNames:
      let bsym = Symbol(name: nm, kind: skBuiltin, typ: BuiltinTypes["any"])
      bsym.codename = "nelua_" & nm
      bsym.isConst = true
      bsym.used = true
      ctx.symOf[node] = bsym
      var a = ctx.getAttr(node)
      a.codename = bsym.codename
      a.isConst = true
      a.name = nm
      a.staticstorage = true
      a.typ = BuiltinTypes["any"]
      a.used = true
      var d = ctx.getDump(node)
      d.builtin = true
      d.isConst = true
      return a.typ
    return nil
  of nkBinaryOp: return analyzeBinaryOp(ctx, node)
  of nkUnaryOp: return analyzeUnaryOp(ctx, node)
  of nkCall: return analyzeCall(ctx, node)
  of nkDotIndex: return analyzeDotIndex(ctx, node)
  of nkInitList: return analyzeInitList(ctx, node)
  of nkPair: return analyzePair(ctx, node)
  of nkParen:
    if node.children.len > 0:
      let inner = analyzeExpr(ctx, node.children[0])
      # The paren node is itself an expression: register its type so codegen
      # can look it up (cgen reads attrOf for parenthesized initializers).
      var a = ctx.getAttr(node)
      a.typ = inner
      return inner
    return nil
  of nkColonIndex, nkKeyIndex:
    if node.children.len > 0: discard analyzeExpr(ctx, node.children[0])
    if node.children.len > 1: discard analyzeExpr(ctx, node.children[1])
    var a = ctx.getAttr(node)
    a.lvalue = true
    a.typ = BuiltinTypes["any"]
    return a.typ
  of nkVarargs:
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["varanys"]
    return a.typ
  else:
    return nil

# ---- statement analysis -------------------------------------------------------

proc analyzeVarDecl(ctx: var AnalyzerContext, node: Node) =
  var iddecls: seq[Node] = @[]
  var inits: seq[Node] = @[]
  var vtypes: seq[Type] = @[]
  for c in node.children:
    if c.kind == nkIdDecl: iddecls.add c
    else: inits.add c
  let isMultiRet = iddecls.len > 1 and inits.len == 1 and inits[0].kind == nkCall
  if isMultiRet:
    ctx.multiRetCall = inits[0]
  for i, iddecl in iddecls:
    var vtype: Type
    if iddecl.children.len > 0:
      vtype = analyzeTypeExpr(ctx, iddecl.children[0])
    if vtype == nil:
      if isMultiRet:
        let rets = ctx.callRetTypes.getOrDefault(inits[0])
        if i < rets.len: vtype = rets[i]
      if vtype == nil and i < inits.len:
        vtype = analyzeExpr(ctx, inits[i])
    if vtype == nil: vtype = BuiltinTypes["nil"]
    vtypes.add vtype
    if vtype.kind == tkFunction and iddecl.children.len > 0:
      let ts = ctx.funcTypeStrOf.getOrDefault(iddecl.children[0])
      if ts.len > 0: ctx.funcTypeStrOf[iddecl] = ts
    let sym = register(ctx, iddecl.str, skVar, vtype, iddecl)
    sym.codename = ctx.unitname & "_" & iddecl.str
    sym.used = true
    sym.staticstorage = true
    sym.vardecl = true
    ctx.symOf[iddecl] = sym
    var a = ctx.getAttr(iddecl)
    a.codename = sym.codename
    a.lvalue = true
    a.name = iddecl.str
    a.staticstorage = true
    a.typ = vtype
    a.used = true
    a.vardecl = true
  ctx.multiRetCall = nil
  for i, init in inits:
    let pt = if i < vtypes.len: vtypes[i] else: nil
    if init.kind == nkInitList:
      discard analyzeInitList(ctx, init, pt)
    else:
      discard analyzeExpr(ctx, init)

proc analyzeFuncDef(ctx: var AnalyzerContext, node: Node) =
  let nameNode = node.children[0]
  let nameStr = nameNode.str
  var args: seq[Node] = @[]
  var returns: seq[Node] = @[]
  var i = 1
  while i < node.children.len and node.children[i].kind == nkIdDecl:
    args.add node.children[i]; inc i
  let body = node.children[^1]
  while i < node.children.len - 1:
    returns.add node.children[i]; inc i
  let ftype = Type(kind: tkFunction, name: "function", codename: "function")
  ftype.name = "function"; ftype.codename = "function"
  var aparts: seq[string] = @[]
  for arg in args:
    let atype = if arg.children.len > 0: resolveTypeExpr(arg.children[0]) else: BuiltinTypes["any"]
    let at = if atype != nil: atype else: BuiltinTypes["any"]
    ftype.args.add at
    aparts.add arg.str & ": " & neluaTypeName(at)
  for r in returns:
    let rt = analyzeTypeExpr(ctx, r, false)
    if rt != nil: ftype.returns.add rt
  if ftype.returns.len == 0: ftype.returns.add BuiltinTypes["void"]
  var rparts: seq[string] = @[]
  for r in ftype.returns: rparts.add neluaTypeName(r)
  let rs = if rparts.len == 0: "void"
           elif rparts.len == 1: rparts[0]
           else: "(" & rparts.join(", ") & ")"
  let ftypeStr = "function(" & aparts.join(", ") & "): " & rs
  ctx.funcTypeStrOf[nameNode] = ftypeStr
  ctx.funcTypeStrOf[node] = ftypeStr
  var a = ctx.getAttr(node)
  a.codename = ctx.unitname & "_" & nameStr
  a.comptime = true
  a.lvalue = true
  a.name = nameStr
  a.staticstorage = true
  a.typ = ftype
  a.used = true
  a.value = nameStr & ": " & ftypeStr
  var na = ctx.getAttr(nameNode)
  na.codename = a.codename
  na.comptime = true
  na.lvalue = true
  na.name = nameStr
  na.staticstorage = true
  na.typ = ftype
  na.used = true
  na.value = a.value
  var nd = ctx.getDump(node)
  nd.ftype = ftypeStr
  nd.funcdeclared = true
  nd.funcdefined = true
  var nd2 = ctx.getDump(nameNode)
  nd2.ftype = ftypeStr
  nd2.funcdeclared = true
  nd2.funcdefined = true
  let sym = register(ctx, nameStr, skFunc, ftype, nameNode)
  sym.codename = ctx.unitname & "_" & nameStr
  sym.used = true
  ctx.symOf[nameNode] = sym
  ctx.symOf[node] = sym
  let saved = ctx.scope
  ctx.scope = newScope(saved, nameStr)
  for arg in args:
    let atype = if arg.children.len > 0: resolveTypeExpr(arg.children[0]) else: BuiltinTypes["any"]
    var arga = ctx.getAttr(arg)
    arga.codename = arg.str
    arga.lvalue = true
    arga.name = arg.str
    arga.typ = if atype != nil: atype else: BuiltinTypes["any"]
    let asym = register(ctx, arg.str, skParam, if atype != nil: atype else: BuiltinTypes["any"], arg)
    asym.codename = arg.str
    ctx.symOf[arg] = asym
    if arg.children.len > 0:
      discard analyzeTypeExpr(ctx, arg.children[0], false)
  analyzeBlock(ctx, body)
  ctx.scope = saved

proc analyzeTypeExpr*(ctx: var AnalyzerContext, node: Node, usedType = true): Type =
  if node == nil: return nil
  case node.kind
  of nkId:
    let t = if BuiltinTypes.hasKey(node.str): BuiltinTypes[node.str] else: nil
    if t != nil:
      var a = ctx.getAttr(node)
      a.codename = "nl" & neluaTypeName(t)
      a.global = true
      a.lvalue = true
      a.name = node.str
      a.staticstorage = true
      a.typ = BuiltinTypes["type"]
      a.value = neluaTypeName(t)
      a.vardecl = true
      a.used = usedType
      return t
    return nil
  of nkPointerType:
    let sub = if node.children.len > 0: analyzeTypeExpr(ctx, node.children[0], usedType) else: nil
    let t = Type(kind: tkPointer)
    if sub == nil or sub.kind == tkVoid:
      t.subtype = BuiltinTypes["void"]
    else:
      t.subtype = sub
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return pointerType(if t.subtype != nil: t.subtype else: BuiltinTypes["any"])
  of nkArrayType:
    let sub = if node.children.len > 0: analyzeTypeExpr(ctx, node.children[0], usedType) else: BuiltinTypes["integer"]
    var size = 0
    if node.children.len > 1 and node.children[1].kind == nkNumber:
      size = parseInt(node.children[1].str)
      discard analyzeExpr(ctx, node.children[1])
    let t = arrayType(if sub != nil: sub else: BuiltinTypes["integer"], size)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  of nkRecordType:
    var fields: seq[Field] = @[]
    for c in node.children:
      if c.kind == nkRecordField:
        let ft = if c.children.len > 0: analyzeTypeExpr(ctx, c.children[0], usedType) else: BuiltinTypes["any"]
        var ca = ctx.getAttr(c)
        ca.typ = BuiltinTypes["type"]
        ca.value = if ft != nil: neluaTypeName(ft) else: "any"
        fields.add Field(name: c.str, typ: if ft != nil: ft else: BuiltinTypes["any"])
    let t = recordType(fields)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  of nkUnionType:
    var fields: seq[Field] = @[]
    for c in node.children:
      if c.kind == nkUnionField:
        let ft = if c.children.len > 0: analyzeTypeExpr(ctx, c.children[0], usedType) else: BuiltinTypes["any"]
        var ca = ctx.getAttr(c)
        ca.typ = BuiltinTypes["type"]
        ca.value = if ft != nil: neluaTypeName(ft) else: "any"
        fields.add Field(name: c.str, typ: if ft != nil: ft else: BuiltinTypes["any"])
    let t = unionType(fields)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  of nkEnumType:
    var ef: seq[EnumField] = @[]
    for c in node.children:
      if c.kind == nkEnumField:
        var v = 0
        if c.children.len > 0 and c.children[0].kind == nkNumber:
          v = parseInt(c.children[0].str)
          discard analyzeExpr(ctx, c.children[0])
        ef.add EnumField(name: c.str, value: v)
    let t = enumType(BuiltinTypes["integer"], ef)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  of nkFuncType:
    var args: seq[Type] = @[]
    var rets: seq[Type] = @[]
    var aparts: seq[string] = @[]
    var i = 0
    while i < node.children.len and node.children[i].kind == nkIdDecl:
      let idc = node.children[i]
      let at = if idc.children.len > 0: analyzeTypeExpr(ctx, idc.children[0], usedType) else: BuiltinTypes["any"]
      let at2 = if at != nil: at else: BuiltinTypes["any"]
      args.add at2
      aparts.add idc.str & ": " & neluaTypeName(at2)
      var ia = ctx.getAttr(idc)
      ia.codename = idc.str
      ia.lvalue = true
      ia.name = idc.str
      ia.typ = at2
      inc i
    while i < node.children.len:
      let rt = analyzeTypeExpr(ctx, node.children[i], usedType)
      if rt != nil: rets.add rt
      inc i
    let t = funcType(args, rets)
    var rparts: seq[string] = @[]
    for r in rets: rparts.add neluaTypeName(r)
    let rs = if rparts.len == 0: "void"
             elif rparts.len == 1: rparts[0]
             else: "(" & rparts.join(", ") & ")"
    let ftypeStr = "function(" & aparts.join(", ") & "): " & rs
    ctx.funcTypeStrOf[node] = ftypeStr
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = ftypeStr
    return t
  of nkOptionalType:
    let sub = if node.children.len > 0: analyzeTypeExpr(ctx, node.children[0], usedType) else: BuiltinTypes["any"]
    let t = optionalType(if sub != nil: sub else: BuiltinTypes["any"])
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  else:
    return nil

proc analyzeIf(ctx: var AnalyzerContext, node: Node) =
  let hasElse = (node.children.len and 1) == 1
  let npairs = node.children.len div 2
  for pi in 0 ..< npairs:
    let cond = node.children[pi * 2]
    discard analyzeExpr(ctx, cond)
    analyzeBlock(ctx, node.children[pi * 2 + 1])
  if hasElse:
    analyzeBlock(ctx, node.children[^1])
  ctx.ifBranchCount[node] = npairs
  ctx.ifHasElse[node] = hasElse

proc analyzeWhile(ctx: var AnalyzerContext, node: Node) =
  discard analyzeExpr(ctx, node.children[0])
  analyzeBlock(ctx, node.children[1])

proc foldIntValue(ctx: var AnalyzerContext, node: Node): int =
  if node.kind == nkNumber:
    result = parseInt(node.str)
  elif node.kind == nkBinaryOp:
    let a = ctx.attrOf.getOrDefault(node)
    if a != nil and a.comptime and a.value.len > 0:
      result = parseInt(a.value)

proc analyzeForNum(ctx: var AnalyzerContext, node: Node) =
  let iddecl = node.children[0]
  let begin = node.children[1]
  let endv = node.children[2]
  let hasStep = node.children.len == 5
  let step = if hasStep: node.children[3] else: nil
  let body = node.children[^1]
  let btype = analyzeExpr(ctx, begin)
  let etype = analyzeExpr(ctx, endv)
  if hasStep: discard analyzeExpr(ctx, step)
  let vtype = if btype != nil: btype else: BuiltinTypes["integer"]
  let sym = register(ctx, iddecl.str, skVar, vtype, iddecl)
  sym.codename = iddecl.str
  sym.used = true
  ctx.symOf[iddecl] = sym
  var a = ctx.getAttr(iddecl)
  a.codename = iddecl.str
  a.lvalue = true
  a.name = iddecl.str
  a.typ = vtype
  a.used = true
  let bv = foldIntValue(ctx, begin); let ev = foldIntValue(ctx, endv)
  if bv != 0 or ev != 0:
    ctx.getDump(node).compop = if bv <= ev: "le" else: "ge"
  else:
    ctx.getDump(node).compop = "le"
  ctx.getDump(node).fixedend = isComptime(endv, ctx)
  if hasStep:
    ctx.getDump(node).fixedstep = dumpExprString(ctx, step)
  else:
    ctx.getDump(node).fixedstep = "1"
  let saved = ctx.scope
  ctx.scope = newScope(saved, iddecl.str)
  analyzeBlock(ctx, body)
  ctx.scope = saved

proc analyzeForIn(ctx: var AnalyzerContext, node: Node) =
  let body = node.children[^1]
  for i in 0 ..< node.children.len - 1:
    discard analyzeExpr(ctx, node.children[i])
  analyzeBlock(ctx, body)

proc analyzeDefer(ctx: var AnalyzerContext, node: Node) =
  analyzeBlock(ctx, node.children[0])

proc analyzeDo(ctx: var AnalyzerContext, node: Node) =
  analyzeBlock(ctx, node.children[0])

proc analyzeRepeat(ctx: var AnalyzerContext, node: Node) =
  analyzeBlock(ctx, node.children[0])

proc analyzeAssign(ctx: var AnalyzerContext, node: Node) =
  let ntargets = ctx.assignTargets.getOrDefault(node, 1)
  for i in 0 ..< ntargets:
    let t = node.children[i]
    if t.kind == nkId:
      let sym = ctx.lookup(t.str)
      if sym != nil:
        sym.mutate = true
        ctx.symOf[t] = sym
        var ta = ctx.getAttr(t)
        ta.mutate = true
    discard analyzeExpr(ctx, t)
  for i in ntargets ..< node.children.len:
    discard analyzeExpr(ctx, node.children[i])

proc analyzeReturn(ctx: var AnalyzerContext, node: Node) =
  for c in node.children:
    discard analyzeExpr(ctx, c)

proc analyzeStmt(ctx: var AnalyzerContext, node: Node) =
  if node == nil: return
  case node.kind
  of nkBlock: analyzeBlock(ctx, node)
  of nkVarDecl: analyzeVarDecl(ctx, node)
  of nkFuncDef: analyzeFuncDef(ctx, node)
  of nkIf: analyzeIf(ctx, node)
  of nkWhile: analyzeWhile(ctx, node)
  of nkForNum: analyzeForNum(ctx, node)
  of nkForIn: analyzeForIn(ctx, node)
  of nkDefer: analyzeDefer(ctx, node)
  of nkDo: analyzeDo(ctx, node)
  of nkRepeat: analyzeRepeat(ctx, node)
  of nkAssign: analyzeAssign(ctx, node)
  of nkReturn: analyzeReturn(ctx, node)
  of nkBreak, nkContinue, nkLabel, nkGoto: discard
  of nkCall: discard analyzeCall(ctx, node)
  else: discard analyzeExpr(ctx, node)

proc analyzeBlock(ctx: var AnalyzerContext, node: Node) =
  if node == nil: return
  for c in node.children:
    analyzeStmt(ctx, c)

# ---- finalize: propagate used/mutate from symbols to attrs --------------------

proc finalize*(ctx: var AnalyzerContext) =
  for node, sym in ctx.symOf:
    if node.kind == nkIdDecl:
      var a = ctx.getAttr(node)
      if sym.kind == skVar or sym.kind == skFunc:
        a.used = sym.used
      if sym.mutate: a.mutate = true
    elif node.kind == nkId:
      var a = ctx.getAttr(node)
      if sym.mutate: a.mutate = true

# ---- dumpAnaled ---------------------------------------------------------------
##
## Renders the analyzed tree in the exact `--print-analyzed-ast` format.

proc quoteStr(s: string): string = "\"" & s & "\""

proc kindName(node: Node): string =
  if node.kind == nkId and node.str == "nilptr":
    return "Nilptr"
  let s = $node.kind
  if s.len > 2 and s[0] == 'n' and s[1] == 'k': s[2 ..< s.len]
  else: s

proc typeStrFor(ctx: AnalyzerContext, node: Node, t: Type): string =
  if t == nil: return ""
  if t.kind == tkFunction:
    let fs = ctx.funcTypeStrOf.getOrDefault(node)
    if fs != "": return fs
    if node.kind == nkIdDecl and node.children.len > 0:
      let fs2 = ctx.funcTypeStrOf.getOrDefault(node.children[0])
      if fs2 != "": return fs2
    let sym = ctx.symOf.getOrDefault(node)
    if sym != nil and sym.node != nil:
      let fs3 = ctx.funcTypeStrOf.getOrDefault(sym.node)
      if fs3 != "": return fs3
  return neluaTypeName(t)

proc renderAttr(ctx: AnalyzerContext, node: Node): string =
  let a = ctx.attrOf.getOrDefault(node)
  var d = ctx.dumpOf.getOrDefault(node)
  if d == nil: d = DumpInfo()
  var lines: seq[string] = @[]
  proc addb(name: string, b: bool) =
    if b: lines.add(name & " = true")
  proc adds(name: string, s: string) =
    if s != "": lines.add(name & " = " & quoteStr(s))
  proc addt(name: string, t: Type) =
    if t != nil: adds(name, neluaTypeName(t))
  proc addv(name: string, s: string, kind: int) =
    if s == "": return
    if kind == 0: lines.add(name & " = " & quoteStr(s))
    else: lines.add(name & " = " & s)
  if a != nil and a.base != 0: lines.add("base = " & $a.base)
  if d.builtin: lines.add("builtin = true")
  if d.builtinType != "": adds("builtintype", d.builtinType)
  if d.calleeSymStr != "": adds("calleesym", d.calleeSymStr)
  if d.calleeTypeStr != "": adds("calleetype", d.calleeTypeStr)
  if node.kind == nkCall: lines.add("pseudoargattrs = <ptr>")
  if node.kind == nkCall: lines.add("pseudoargtypes = <ptr>")
  if a != nil: adds("codename", a.codename)
  if d.compop != "": adds("compop", d.compop)
  if a != nil: addb("comptime", a.comptime)
  if d.isConst: lines.add("const = true")
  if a != nil: adds("dotfieldname", a.dotFieldName)
  if a != nil: adds("filename", a.filename)
  if d.fixedend: lines.add("fixedend = true")
  if d.fixedstep != "": adds("fixedstep", d.fixedstep)
  if d.ftype != "": adds("ftype", d.ftype)
  if d.funcdeclared: lines.add("funcdeclared = true")
  if d.funcdefined: lines.add("funcdefined = true")
  if a != nil: addb("global", a.global)
  if a != nil: addb("lvalue", a.lvalue)
  if a != nil: addb("mutate", a.mutate)
  if a != nil: adds("name", a.name)
  if a != nil and a.parentType != nil: adds("parenttype", neluaTypeName(a.parentType))
  if d.sideeffect: lines.add("sideeffect = true")
  if a != nil: addb("staticstorage", a.staticstorage)
  if a != nil and a.typ != nil:
    let ts = typeStrFor(ctx, node, a.typ)
    if ts != "": adds("type", ts)
  if a != nil: addb("used", a.used)
  if d.usemultirets: lines.add("usemultirets = true")
  if a != nil: addv("value", a.value, valueQuoteKind(a.typ))
  if a != nil: addb("vardecl", a.vardecl)
  if lines.len == 0: return ""
  result = "attr = {\n"
  for ln in lines: result.add "  " & ln & ",\n"
  result.add "}"

proc dumpExprString(ctx: var AnalyzerContext, node: Node): string =
  return dumpAnaled(ctx, node, 0)

proc dumpIdDecl2(ctx: var AnalyzerContext, node: Node, indent: int): string =
  let ind = "  ".repeat(indent)
  let fldInd = "  ".repeat(indent + 1)
  let attrStr = renderAttr(ctx, node)
  let strField = quoteStr(node.str)
  if attrStr == "":
    return ind & "IdDecl {\n" & fldInd & strField & "\n" & ind & "}"
  var outp = ind & "IdDecl {\n"
  let alines = attrStr.split("\n")
  for li in 0 ..< alines.len:
    let comma = if li == alines.len - 1: "," else: ""
    outp.add fldInd & alines[li] & comma & "\n"
  outp.add fldInd & strField & "\n"
  outp.add ind & "}"
  return outp

proc blockOf(ctx: var AnalyzerContext, items: seq[Node], indent: int): string =
  let blkInd = "  ".repeat(indent + 1)
  result = blkInd & "{\n"
  for i, x in items:
    result.add dumpAnaled(ctx, x, indent + 2)
    if i < items.len - 1: result.add ",\n"
    else: result.add "\n"
  result.add blkInd & "}"

proc dumpAnaled*(ctx: var AnalyzerContext, node: Node, indent = 0): string =
  if node == nil: return ""
  let ind = "  ".repeat(indent)
  let fldInd = "  ".repeat(indent + 1)
  let attrStr = renderAttr(ctx, node)
  var allFields: seq[tuple[isNode: bool, text: string]] = @[]
  if attrStr != "": allFields.add((false, attrStr))
  case node.kind
  of nkBlock:
    for c in node.children:
      allFields.add((true, dumpAnaled(ctx, c, indent + 1)))
  of nkVarDecl:
    allFields.add((false, quoteStr(node.str)))
    var iddecls: seq[Node] = @[]
    var inits: seq[Node] = @[]
    for c in node.children:
      if c.kind == nkIdDecl: iddecls.add c else: inits.add c
    allFields.add((true, blockOf(ctx, iddecls, indent)))
    if inits.len > 0:
      allFields.add((true, blockOf(ctx, inits, indent)))
  of nkFuncDef:
    let nameNode = node.children[0]
    allFields.add((false, "funcdecl = true"))
    allFields.add((false, "funcdefn = true"))
    allFields.add((false, quoteStr(node.str)))
    allFields.add((true, dumpIdDecl2(ctx, nameNode, indent + 1)))
    var args: seq[Node] = @[]
    var returns: seq[Node] = @[]
    var i = 1
    while i < node.children.len and node.children[i].kind == nkIdDecl:
      args.add node.children[i]; inc i
    let body = node.children[^1]
    while i < node.children.len - 1: returns.add node.children[i]; inc i
    allFields.add((true, blockOf(ctx, args, indent)))
    allFields.add((true, blockOf(ctx, returns, indent)))
    allFields.add((false, "false"))
    allFields.add((true, dumpAnaled(ctx, body, indent + 1)))
  of nkIdDecl:
    allFields.add((false, quoteStr(node.str)))
    if node.children.len > 0:
      allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    else:
      allFields.add((false, "false"))
  of nkId:
    if node.str != "nilptr":
      allFields.add((false, quoteStr(node.str)))
  of nkNumber:
    allFields.add((false, quoteStr(node.str)))
  of nkString:
    allFields.add((false, node.str))
  of nkBoolean:
    allFields.add((false, $node.boolVal))
  of nkNil, nkNilptr:
    discard
  of nkCall:
    let caller = node.children[^1]
    let args = node.children[0 ..< node.children.len - 1]
    allFields.add((true, blockOf(ctx, args, indent)))
    allFields.add((true, dumpAnaled(ctx, caller, indent + 1)))
  of nkBinaryOp:
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((false, quoteStr(binaryOpName(node.str))))
    allFields.add((true, dumpAnaled(ctx, node.children[1], indent + 1)))
  of nkUnaryOp:
    allFields.add((false, quoteStr(unaryOpName(node.str))))
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  of nkAssign:
    let ntargets = ctx.assignTargets.getOrDefault(node, 1)
    allFields.add((true, blockOf(ctx, node.children[0 ..< ntargets], indent)))
    allFields.add((true, blockOf(ctx, node.children[ntargets ..< node.children.len], indent)))
  of nkReturn:
    for c in node.children:
      allFields.add((true, dumpAnaled(ctx, c, indent + 1)))
  of nkIf:
    let nbranches = ctx.ifBranchCount.getOrDefault(node, 0)
    let hasElse = ctx.ifHasElse.getOrDefault(node, false)
    var ibItems: seq[Node] = @[]
    var i = 0
    var bi = 0
    while i < node.children.len and bi < nbranches:
      ibItems.add node.children[i]; inc i
      if i < node.children.len:
        ibItems.add node.children[i]; inc i
        inc bi
    allFields.add((true, blockOf(ctx, ibItems, indent)))
    if hasElse:
      allFields.add((true, dumpAnaled(ctx, node.children[^1], indent + 1)))
  of nkWhile:
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((true, dumpAnaled(ctx, node.children[1], indent + 1)))
  of nkForNum:
    let hasStep = node.children.len == 5
    let step = if hasStep: node.children[3] else: nil
    let body = node.children[^1]
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((true, dumpAnaled(ctx, node.children[1], indent + 1)))
    allFields.add((false, "false"))
    allFields.add((true, dumpAnaled(ctx, node.children[2], indent + 1)))
    if hasStep:
      allFields.add((true, dumpAnaled(ctx, step, indent + 1)))
    else:
      allFields.add((false, "false"))
    allFields.add((true, dumpAnaled(ctx, body, indent + 1)))
  of nkDefer, nkDo:
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  of nkRepeat:
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((true, dumpAnaled(ctx, node.children[1], indent + 1)))
  of nkDotIndex:
    allFields.add((false, quoteStr(node.str)))
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  of nkInitList:
    for c in node.children:
      allFields.add((true, dumpAnaled(ctx, c, indent + 1)))
  of nkPair:
    allFields.add((false, quoteStr(node.str)))
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  of nkEnumField:
    allFields.add((false, quoteStr(node.str)))
    if node.children.len > 0:
      allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  of nkEnumType:
    allFields.add((false, "false"))
    allFields.add((true, blockOf(ctx, node.children, indent)))
  of nkFuncType:
    var args: seq[Node] = @[]
    var returns: seq[Node] = @[]
    var i = 0
    while i < node.children.len and node.children[i].kind == nkIdDecl:
      args.add node.children[i]; inc i
    while i < node.children.len:
      returns.add node.children[i]; inc i
    allFields.add((true, blockOf(ctx, args, indent)))
    allFields.add((true, blockOf(ctx, returns, indent)))
  of nkRecordField, nkUnionField:
    allFields.add((false, quoteStr(node.str)))
    if node.children.len > 0:
      allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
  else:
    for c in node.children:
      allFields.add((true, dumpAnaled(ctx, c, indent + 1)))

  result = ind & kindName(node) & " {\n"
  let lastIdx = allFields.len - 1
  for i in 0 .. lastIdx:
    let (isNode, ftext) = allFields[i]
    let flines = ftext.split("\n")
    let isAttrField = (not isNode) and ftext.startsWith("attr = ")
    for li in 0 ..< flines.len:
      let line = if isNode: flines[li] else: fldInd & flines[li]
      let comma = if (isAttrField and li == flines.len - 1) or (li == flines.len - 1 and i < lastIdx): "," else: ""
      result.add line & comma & "\n"
  result.add ind & "}"

proc dumpAnaled(ctx: AnalyzerContext, node: Node): string =
  var c = ctx
  return dumpAnaled(c, node, 0)

# ---- entry point --------------------------------------------------------------

proc countAssignTargets(ctx: var AnalyzerContext, node: Node) =
  if node == nil: return
  if node.kind == nkAssign:
    ctx.assignTargets[node] = 1
  for c in node.children:
    countAssignTargets(ctx, c)

proc runM6Pipeline(ast: Node, source = "", path = "t.nelua"): tuple[ctx: AnalyzerContext, root: Node] =
  ## Replicate `analyze`'s M6 integration path (bootstrap -> preprocess ->
  ## analyzeBlock -> finalize) so the directive self-test can drive a tree the
  ## M1 parser cannot emit (it treats `#` as the length operator only).  The
  ## PreprocessError -> diag fallback mirrors what `analyze` applies.
  var ast = ast
  var ctx: AnalyzerContext
  ctx.source = source
  ctx.path = path
  ctx.unitname = computeUnitname(path)
  bootstrap(ctx)
  var pctx = newPreprocessContext(source, path)
  try:
    ast = preprocess(ast, pctx)
  except PreprocessError as e:
    ctx.diags.add e.msg
  ctx.diags &= pctx.diags
  countAssignTargets(ctx, ast)
  let ra = ctx.getAttr(ast)
  ra.filename = path
  analyzeBlock(ctx, ast)
  finalize(ctx)
  return (ctx, ast)

proc analyze*(source: string, path: string): AnalyzerResult =
  var ctx: AnalyzerContext
  ctx.source = source
  ctx.path = path
  ctx.unitname = computeUnitname(path)
  bootstrap(ctx)
  var ast = parse(source, path)
  if ast == nil:
    result.root = nil; result.ctx = ctx
    return
  # P3: run the M6 preprocessor over the parse tree (identity on directive-free
  # source) so every pipeline inherits preprocessing with no signature change.
  var pctx = newPreprocessContext(source, path)
  try:
    ast = preprocess(ast, pctx)
  except PreprocessError as e:
    ctx.diags.add e.msg
  ctx.diags &= pctx.diags
  countAssignTargets(ctx, ast)
  let ra = ctx.getAttr(ast)
  ra.filename = path
  # P4: analyze
  analyzeBlock(ctx, ast)
  finalize(ctx)
  result.root = ast; result.ctx = ctx

when isMainModule:
  if paramCount() >= 1 and paramStr(1).endsWith(".nelua"):
    let f = paramStr(1)
    let src = readFile(f)
    let res = analyze(src, f)
    echo dumpAnaled(res.ctx, res.root)
    quit(0)
  let dir = "/home/user/Code/nelua-lang/tmp/m2_corpus"
  var total = 0; var matches = 0
  for f in walkFiles(dir & "/*.nelua"):
    let base = f.splitFile().name
    let refpath = dir / base & ".ref"
    if not fileExists(refpath):
      echo base, ": NO REF (skipped)"
      continue
    inc total
    let src = readFile(f)
    let res = analyze(src, f)
    if res.root == nil:
      echo base, ": PARSE FAILED"
      continue
    let outp = dumpAnaled(res.ctx, res.root)
    let expected = readFile(refpath)
    if (outp & "\n") == expected:
      inc matches
      echo base, ": MATCH"
    else:
      echo base, ": DIFF"
      let ol = (outp & "\n").split("\n"); let rl = (expected & "\n").split("\n")
      var shown = false
      for i in 0 ..< min(ol.len, rl.len):
        if ol[i] != rl[i]:
          echo "  line ", i+1, " out: ", ol[i]
          echo "  line ", i+1, " ref: ", rl[i]
          shown = true
          break
      if not shown and ol.len != rl.len:
        echo "  length differs: out=", ol.len, " ref=", rl.len
  echo "----"
  echo matches, "/", total, " matched"

  # ---- M6 preprocessor integration self-test -------------------------------
  # The M1 parser emits no nkDirective nodes from source text (it treats `#` as
  # the length operator only), so directive-bearing trees are assembled with the
  # ast.nim constructors and driven through the same pipeline `analyze` uses.
  echo "=== M6 preprocessor integration self-test ==="

  proc treeHasId(node: Node, name: string): bool =
    if node == nil: return false
    if node.kind == nkId and node.str == name: return true
    for c in node.children:
      if treeHasId(c, name): return true
    return false

  proc treeHasIdDecl(node: Node, name: string): bool =
    if node == nil: return false
    if node.kind == nkIdDecl and node.str == name: return true
    for c in node.children:
      if treeHasIdDecl(c, name): return true
    return false

  proc treeHasNumber(node: Node, value: string): bool =
    if node == nil: return false
    if node.kind == nkNumber and node.str == value: return true
    for c in node.children:
      if treeHasNumber(c, value): return true
    return false

  # Case 1: function-like macro expansion is reflected in the analyzed AST.
  block:
    let defineNode = newDirective("define", @[
      newId("ADD"), newId("a"), newId("b"),
      newString("((a)+(b))", "macrobody")])
    let call = newCall(@[newNumber("1"), newNumber("2")], newId("ADD"))
    let root = newBlock(@[defineNode,
      newVarDecl("local", @[newIdDecl("x")], @[call])])
    let (ctx, ast) = runM6Pipeline(root)
    let outp = dumpAnaled(ctx, ast)
    echo "CASE1 dump:\n", outp
    doAssert not treeHasId(ast, "ADD"), "macro name ADD must be consumed by expansion"
    doAssert treeHasIdDecl(ast, "x"), "local x must survive preprocessing"
    doAssert treeHasNumber(ast, "1") and treeHasNumber(ast, "2"),
      "expansion must carry the argument literals"
    doAssert outp.contains("BinaryOp"), "value expr must lower to a binary op, not an nkId"
    echo "CASE1 PASS: ADD(1,2) expanded in the analyzed AST"

  # Case 2: #ifdef / #else / #endif, FOO defined and undefined.
  block:
    let branchA = newVarDecl("local", @[newIdDecl("a")], @[newNumber("1")])
    let branchB = newVarDecl("local", @[newIdDecl("b")], @[newNumber("2")])
    # 2a: FOO defined via #define FOO -> first branch survives.
    let rootDef = newBlock(@[
      newDirective("define", @[newId("FOO"), newString("1")]),
      newDirective("ifdef", @[newId("FOO")]), branchA,
      newDirective("else"), branchB,
      newDirective("endif")])
    let (_, astDef) = runM6Pipeline(rootDef)
    doAssert treeHasIdDecl(astDef, "a") and not treeHasIdDecl(astDef, "b"),
      "FOO defined: first branch must survive"
    doAssert treeHasNumber(astDef, "1") and not treeHasNumber(astDef, "2"),
      "FOO defined: first branch value must survive"
    echo "CASE2a PASS: #ifdef FOO with FOO defined keeps the first branch"

    # 2b: FOO undefined -> second branch survives.
    let rootUndef = newBlock(@[
      newDirective("ifdef", @[newId("FOO")]), branchA,
      newDirective("else"), branchB,
      newDirective("endif")])
    let (_, astUndef) = runM6Pipeline(rootUndef)
    doAssert treeHasIdDecl(astUndef, "b") and not treeHasIdDecl(astUndef, "a"),
      "FOO undefined: second branch must survive"
    doAssert treeHasNumber(astUndef, "2") and not treeHasNumber(astUndef, "1"),
      "FOO undefined: second branch value must survive"
    echo "CASE2b PASS: #ifdef FOO with FOO undefined keeps the else branch"

  # Case 3: #error surfaces as a diagnostic, not a crash.
  block:
    let root = newBlock(@[newDirective("error", @[newString("boom")])])
    let (ctx, ast) = runM6Pipeline(root)
    echo "CASE3 diags=", ctx.diags
    doAssert ctx.diags.len > 0, "#error must surface as a diagnostic"
    doAssert ctx.diags[0].contains("boom"), "#error message must be preserved"
    echo "CASE3 PASS: #error boom surfaced as a diagnostic without crashing"

  # Case 4: directive-free source is byte-identical after preprocessing.
  block:
    let src = "local x = 1 + 2\nprint(x)\n"
    let ast1 = parse(src, "t.nelua")
    let d1 = dump(ast1)
    var pctx = newPreprocessContext(src, "t.nelua")
    let ast2 = preprocess(ast1, pctx)
    let d2 = dump(ast2)
    doAssert d1 == d2, "directive-free source must be byte-identical after preprocess"
    doAssert pctx.diags.len == 0, "directive-free source must produce no diags"
    # Full analyze pipeline: with-preprocess vs a manually constructed
    # no-preprocess baseline must also be byte-identical.
    let resWith = analyze(src, "t.nelua")
    let outWith = dumpAnaled(resWith.ctx, resWith.root)
    var ctx2: AnalyzerContext
    ctx2.source = src; ctx2.path = "t.nelua"
    ctx2.unitname = computeUnitname("t.nelua")
    bootstrap(ctx2)
    let astB = parse(src, "t.nelua")
    countAssignTargets(ctx2, astB)
    let ra = ctx2.getAttr(astB); ra.filename = "t.nelua"
    analyzeBlock(ctx2, astB)
    finalize(ctx2)
    let outWithout = dumpAnaled(ctx2, astB)
    doAssert outWith == outWithout,
      "preprocessing must not change the analyzed AST for directive-free source"
    echo "CASE4 PASS: directive-free program byte-identical after preprocessing"

  echo "M6 PREPROCESSOR INTEGRATION SELF-TEST PASS"