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
import config

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
    specials*: seq[Node]                 ## D1: monomorphized auto-param FuncDefs
    loopDepth*: int                     ## nesting depth of loops (for break/continue validation)
    specTable*: Table[string, Node]      ## D1: dedup key -> specialized FuncDef
    specCounter*: Table[string, int]     ## D1: per-function specialization counter
    specInFlight*: Table[string, bool]   ## D1: re-entrancy guard (recursion)

  AnalyzerResult* = object
    root*: Node
    ctx*: AnalyzerContext
    specials*: seq[Node]                 ## D1: monomorphized auto-param FuncDefs
    deps*: seq[AnalyzerResult]          ## D2: recursively analyzed `require` dependencies

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

proc getUpFunctionScope(scope: Scope): Scope =
  ## Walk the scope chain until a function body scope is found. Returns nil if
  ## the referencing code is not inside any function (e.g. module scope). Used by
  ## the upvalue check to tell "same function" access from closure capture.
  var s = scope
  while s != nil:
    if s.isFunction: return s
    s = s.parent
  return nil

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
  # Exception/panic primitives.  `error`/`panic`/`assert`/`check` are noreturn
  # runtime helpers; `check` is elided by the code generator when the `nochecks`
  # pragma / release mode is active.  They are global builtins like `print`, so
  # a local with the same name shadows them (lookup walks the scope chain).
  for (nm, cn) in [("error", "nelua_error"), ("panic", "nelua_panic"),
                   ("assert", "nelua_assert"), ("check", "nelua_check")]:
    let bsym = register(ctx, nm, skBuiltin, anyt)
    bsym.codename = cn
    bsym.isConst = true
    bsym.used = true
  ctx.specTable = initTable[string, Node]()
  ctx.specCounter = initTable[string, int]()
  ctx.specInFlight = initTable[string, bool]()

# ---- literal typing ------------------------------------------------------------

const NumberSuffixTable = {
  "_u": "uint64", "_i": "int64",
  "_u8": "uint8", "_u16": "uint16", "_u32": "uint32", "_u64": "uint64",
  "_i8": "int8", "_i16": "int16", "_i32": "int32", "_i64": "int64",
  "_f32": "float32", "_f64": "float64", "_f128": "float128",
  "_usize": "usize", "_isize": "isize",
  "_cchar": "cchar", "_cshort": "cshort", "_cint": "cint",
  "_clong": "clong", "_clonglong": "clonglong",
  "_cfloat": "cfloat", "_cdouble": "cdouble", "_clongdouble": "clongdouble"
}.toTable

proc splitNumberSuffix(text: string): (string, string) =
  ## Split a numeric literal into (numericPart, suffix). The suffix is the
  ## trailing `_<ident>` (e.g. `_u32`); it is "" when absent. Nelua numeric
  ## literals never contain `_` outside a suffix, so the first `_` delimits it.
  let u = text.find('_')
  if u < 0: return (text, "")
  return (text[0 ..< u], text[u ..< text.len])

proc numberTypeAndValue(text: string): (Type, string, int) =
  let (num, suffix) = splitNumberSuffix(text)
  var base = 10
  # `inf` / `nan` arrive here from compile-time splices (e.g. `#[math.huge]#`
  # -> Number "inf"); they are not decimal/hex integers and would make
  # `parseInt` raise, so accept them as float values first.
  if num == "inf" or num == "-inf" or num == "nan" or num == "-nan":
    return (BuiltinTypes["number"], num, base)
  var iv: int
  var fv: float
  var isFloat = false
  if num.len >= 2 and num[0] == '0' and (num[1] == 'x' or num[1] == 'X'):
    let hex = num[2 ..< num.len]
    iv = 0
    for c in hex:
      let d = if c >= '0' and c <= '9': ord(c) - ord('0')
             elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
             elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
             else: 0
      iv = iv * 16 + d
    base = 16
  elif num.contains('.') or num.contains('e') or num.contains('E'):
    fv = parseFloat(num)
    isFloat = true
  else:
    iv = parseInt(num)
  if suffix != "":
    let tname = NumberSuffixTable.getOrDefault(suffix, "")
    if tname == "":
      raise newException(ValueError, "literal suffix '" & suffix & "' is undefined for numbers")
    let t = if BuiltinTypes.hasKey(tname): BuiltinTypes[tname]
            elif PrimitiveTypes.hasKey(tname): PrimitiveTypes[tname]
            else: nil
    if t == nil:
      raise newException(ValueError, "literal suffix '" & suffix & "' is undefined for numbers")
    if t.isFloat:
      let v = if isFloat: $fv
              elif num.len >= 2 and num[0] == '0' and (num[1] == 'x' or num[1] == 'X'):
                $(parseFloat("0x" & num[2 ..< num.len]))
              else:
                $(parseFloat(num))
      return (t, v, base)
    return (t, $iv, base)
  if isFloat:
    return (BuiltinTypes["number"], $fv, base)
  return (BuiltinTypes["integer"], $iv, base)

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
proc analyzeFuncDef(ctx: var AnalyzerContext, node: Node, specCodename: string = "")
proc isPolymorphic(ftype: Type): bool
proc allConcrete(argTypes: seq[Type]): bool
proc specializeCall(ctx: var AnalyzerContext, calleeSym: Symbol,
                    argTypes: seq[Type]): (string, Type, string)

proc analyzeNominalType*(ctx: var AnalyzerContext, node: Node, usedType = true): Type
proc analyzeInitList(ctx: var AnalyzerContext, node: Node, parentType: Type = nil): Type
proc analyzeDotIndex(ctx: var AnalyzerContext, node: Node): Type
proc foldIntValue(ctx: var AnalyzerContext, node: Node): int
proc typeValueKey(node: Node, ct: Type): string
proc resolveTypeValue(ctx: var AnalyzerContext, key: string): Type

proc analyzeCall(ctx: var AnalyzerContext, node: Node): Type =
  let caller = node.children[^1]
  let args = node.children[0 ..< node.children.len - 1]
  var a = ctx.getAttr(node)
  var d = ctx.getDump(node)
  var ca = ctx.getAttr(caller)
  # A5: record/enum constructor `Rect{ x = 1 }` -> Call(InitList, Rect id).
  # The single arg is an nkInitList; analyze it against the callee's type and
  # mark the call as a constructor so codegen emits a compound literal.
  if caller.kind == nkId and args.len == 1 and args[0].kind == nkInitList:
    let csym = ctx.lookup(caller.str)
    if csym != nil and csym.typ != nil and csym.typ.kind in {tkRecord, tkUnion, tkEnum}:
      discard analyzeInitList(ctx, args[0], csym.typ)
      ctx.symOf[caller] = csym
      csym.used = true
      ca.typ = BuiltinTypes["type"]
      ca.calleeType = csym.typ
      ca.name = caller.str
      a.calleeType = csym.typ
      a.isConstructor = true
      a.typ = csym.typ
      return csym.typ
  var argTypes: seq[Type] = @[]
  for arg in args:
    let t = analyzeExpr(ctx, arg)
    if t != nil: argTypes.add t
  var calleeSym: Symbol = nil
  var calleeType: Type = nil
  # C1: a type cast `(T)(e)` has a type node (or a paren wrapping one) as the
  # caller.  Resolve the target type T, bind it as the call's calleeType and
  # return type, and flag the node so codegen emits `(cType(T))(e)` instead of
  # a function call.  Without this the `else` branch below dereferences a nil
  # calleeType and SIGSEGVs -- a cast was previously left unanalyzed.
  var castTarget: Type = nil
  if caller.kind == nkParen and caller.children.len > 0 and
     caller.children[0].kind == nkType:
    castTarget = analyzeTypeExpr(ctx, caller.children[0].children[0])
  elif caller.kind == nkType:
    castTarget = analyzeTypeExpr(ctx, caller.children[0])
  if castTarget != nil:
    calleeType = Type(kind: tkFunction, name: "function", codename: "function")
    calleeType.name = "function"; calleeType.codename = "function"
    for at in argTypes:
      calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
    calleeType.returns.add castTarget
    ca.calleeType = castTarget
    a.calleeType = castTarget
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
    elif sym != nil and sym.kind != skBuiltin and sym.kind != skFunc and sym.typ != nil and sym.typ.kind == tkFunction:
      # Indirect call through a function-typed value (a param/variable/closure
      # holding a function pointer).  The callee has no `skFunc` symbol, so it
      # falls through to the generic branch below unless we bind its type here.
      # Bind its codename too: codegen emits `<codename>(args)` for the caller,
      # and without it a function-typed local/param call lowers to the bare
      # nelua name (e.g. `h()` instead of `<unit>_h()`), which C rejects as an
      # implicit declaration.
      calleeType = sym.typ
      ctx.symOf[caller] = sym
      sym.used = true
      ca.typ = calleeType
      ca.codename = sym.codename
      ca.used = true
    elif sym != nil and sym.kind == skFunc:
      calleeSym = sym
      calleeType = sym.typ
    elif sym != nil and sym.typ != nil and sym.typ.kind == tkRecord and
         sym.typ.methods.hasKey("__call"):
      # M3: calling a record value `r(...)` dispatches through its `__call`
      # metamethod.  The callee is a data value (a local/param of record type,
      # not an skFunc symbol), so it fell through to the generic branch above.
      # Bind the caller attr to the record type so codegen's M3 branch fires
      # genMetaCall instead of emitting `<var>(args)` (which C rejects -- a
      # struct is not a function).  This is the fourth metamethod-dispatch
      # path; M1/M2/M4 dispatch on the ARGUMENT or the base of an index/unary
      # op, where the attr IS populated by analyzeExpr.  A record-value callee
      # is never passed through analyzeExpr, so its attr was left empty.
      let md = sym.typ.methods["__call"]
      ca.typ = sym.typ
      ca.codename = sym.codename
      ca.name = nm
      ca.lvalue = true
      ca.used = true
      ctx.symOf[caller] = sym
      sym.used = true
      calleeType = md.ftype
      if md.ftype != nil and md.ftype.returns.len >= 1:
        a.typ = md.ftype.returns[0]
      else:
        a.typ = BuiltinTypes["void"]
    else:
      # unknown: build a generic function type
      calleeType = Type(kind: tkFunction, name: "function", codename: "function")
      calleeType.name = "function"; calleeType.codename = "function"
      for i, at in argTypes:
        calleeType.args.add if at != nil: at else: BuiltinTypes["any"]
      calleeType.returns.add BuiltinTypes["void"]
  elif caller.kind == nkDotIndex:
    # Static method call `Type.method(args)` (e.g. `Rect.area(r)`) or an
    # indirect call through a function-typed field `obj.field(args)`.  Analyze
    # the DotIndex to populate the caller attr (analyzeDotIndex resolves the
    # method on the base type's method table and flags isMethodCall), then bind
    # calleeType the same way an nkId callee is bound.  Without this branch
    # calleeType stays nil and the `calleeType.returns` deref below SIGSEGVs.
    discard analyzeDotIndex(ctx, caller)
    if ca.isMethodCall and ca.calleeSym != nil:
      # Fold the method reference into a comptime value (its C codename) so the
      # codegen's DotIndex caller branch emits `<codename>(args)` -- a static
      # method is not a function-pointer field access.
      let m = ca.calleeSym
      ca.value = m.codename
      ca.comptime = true
      calleeType = ca.typ
    elif ca.typ != nil and ca.typ.kind == tkFunction:
      # Indirect call through a function-typed field `obj.field(args)`.
      calleeType = ca.typ
    else:
      # Calling something that is neither a method nor a function-typed value.
      # Emit a diagnostic instead of leaving calleeType nil, which would
      # SIGSEGV the `calleeType.returns` deref below.
      ctx.diags.add ctx.path & ": error: cannot call non-function '" &
        caller.str & "'"
      calleeType = Type(kind: tkFunction, name: "function", codename: "function")
      calleeType.returns.add BuiltinTypes["void"]
  # caller Id attr
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
    # D1: monomorphize a polymorphic (`auto`-param) callee at the call site.
    # Only specialize when every argument type is concrete -- a call inside
    # another polymorphic function's body (e.g. `id(x)` inside `twice`) has an
    # `auto` argument at definition time and must wait until the outer function
    # is itself specialized, or we'd emit a bogus `id(auto)` specialization.
    if calleeSym.kind == skFunc and isPolymorphic(calleeSym.typ) and
       allConcrete(argTypes):
      let (specCodename, specFtype, specFtypeStr) =
        specializeCall(ctx, calleeSym, argTypes)
      ca.codename = specCodename
      ca.typ = specFtype
      d.calleeTypeStr = specFtypeStr
      d.calleeSymStr = calleeSym.name & ": " & specFtypeStr
      if specFtype.returns.len >= 1:
        a.typ = specFtype.returns[0]
      else:
        a.typ = BuiltinTypes["void"]
    else:
      # Polymorphic `skFunc` callee but with an `auto` argument: defer; the
      # call's type is the callee's (still-auto) return type, fixed when the
      # outer function is specialized.  Non-skFunc callees (builtins, unknown)
      # already have their type set above and are left untouched.
      if calleeSym.kind == skFunc and calleeSym.typ.returns.len >= 1:
        a.typ = calleeSym.typ.returns[0]
      elif calleeSym.kind == skFunc:
        a.typ = BuiltinTypes["void"]
  else:
    d.calleeSymStr = caller.str & ": " & ftypeStr
    d.calleeTypeStr = ftypeStr
    if calleeType != nil and calleeType.returns.len >= 1:
      a.typ = calleeType.returns[0]
    else:
      a.typ = BuiltinTypes["void"]
  if node == ctx.multiRetCall:
    d.usemultirets = true
    ctx.callRetTypes[node] = if calleeType != nil: calleeType.returns else: @[]
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
  # A3: resolve the receiver type, dereferencing pointer-to-record (`self.w`
  # where self is `*Record`) so the field table is the record, not the ptr.
  var rt: Type = nil
  if bt != nil and bt.kind == tkRecord:
    rt = bt
  elif bt != nil and bt.kind == tkUnion:
    rt = bt
  elif bt != nil and bt.kind == tkPointer and bt.subtype != nil and
       bt.subtype.kind in {tkRecord, tkUnion}:
    rt = bt.subtype
  elif bt != nil and bt.kind == tkEnum:
    rt = bt
  if rt != nil:
    if rt.kind == tkRecord:
      for f in rt.fields:
        if f.name == node.str:
          a.typ = f.typ
          break
      # A3: record method access `R.m` (type as caller in `R.m(args)`).
      if a.typ == nil and rt.methods.hasKey(node.str):
        let m = rt.methods[node.str]
        a.isMethodCall = true
        a.calleeSym = m.sym
        a.codename = m.codename
        a.typ = m.ftype
    elif rt.kind == tkUnion:
      # C3: a `@union` field access `u.a` was falling through to `any` (the
      # analyzer only handled tkRecord here), so the RHS of `u.a = 5` was
      # wrapped as `nlany_from_int(5)` and assigned to an `int64_t` field --
      # invalid C.  Resolve the field type like a record field.
      for f in rt.fields:
        if f.name == node.str:
          a.typ = f.typ
          break
    elif rt.kind == tkEnum:
      for ef in rt.enumFields:
        if ef.name == node.str:
          a.typ = rt.subtype
          a.comptime = true
          a.value = $ef.value
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
      # A nested initializer list (`v = { ... }`) inherits the type of the
      # field it is filling, so a `[N]uint32` field lowers to
      # `(uint32_t[N]){ ... }` rather than an empty `struct` wrapper.
      var ft: Type = nil
      for f in fieldsOf(t):
        if f.name == c.str: ft = f.typ; break
      if ft != nil and c.children.len > 0 and c.children[0].kind == nkInitList:
        discard analyzeInitList(ctx, c.children[0], ft)
      else:
        discard analyzeExpr(ctx, c.children[0])
  return t

proc analyzePair(ctx: var AnalyzerContext, node: Node): Type =
  discard analyzeExpr(ctx, node.children[0])
  return BuiltinTypes["any"]

proc analyzeExpr*(ctx: var AnalyzerContext, node: Node): Type =
  if node == nil: return nil
  case node.kind
  of nkNumber:
    try:
      let (t, val, base) = numberTypeAndValue(node.str)
      var a = ctx.getAttr(node)
      a.base = base
      a.comptime = true
      a.typ = t
      a.value = val
      return t
    except ValueError as e:
      ctx.diags.add ctx.path & ": error: " & e.msg
      return BuiltinTypes["integer"]
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
    let sym = ctx.lookup(nm)
    if sym != nil:
      ctx.symOf[node] = sym
      sym.used = true
      # Mirror the oracle's upvalue check (analyzer.lua:670-673). A variable
      # that is not module-scope and not in the same function as the referencing
      # code is an upvalue, which Nelua does not support. Function symbols are
      # exempt: the oracle marks every function staticstorage, which is what
      # makes recursion through an inner function legal. Comptime vars are
      # exempt too (the oracle exempts them via is_directly_accesible_from_scope).
      if sym.kind in {skVar, skParam} and not sym.comptime:
        if sym.scope != ctx.globals:
          let symUp = getUpFunctionScope(sym.scope)
          let refUp = getUpFunctionScope(ctx.scope)
          if symUp != refUp:
            ctx.diags.add ctx.path & ": error: attempt to access upvalue '" &
              nm & "', but closures are not supported"
            return nil
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
        if sym.comptime:
          a.comptime = true
          a.value = sym.value
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
  of nkType:
    # `@record{...}` / `@enum(integer){...}` in value position: build a nominal
    # Type (fresh typeid, distinct C tag) and bind it as a type value.
    let ty = analyzeNominalType(ctx, node.children[0])
    if ty != nil:
      var a = ctx.getAttr(node)
      a.typ = BuiltinTypes["type"]
      a.value = neluaTypeName(ty)
      a.vardecl = true
      return ty
    return nil
  of nkBinaryOp: return analyzeBinaryOp(ctx, node)
  of nkUnaryOp: return analyzeUnaryOp(ctx, node)
  of nkCall: return analyzeCall(ctx, node)
  of nkCallMethod:
    # A4: colon-method call `recv:m(args)`. node.str is the method name,
    # node.children[^1] is the receiver expression; the rest are args.
    let recv = node.children[^1]
    let rt = analyzeExpr(ctx, recv)
    var mtype: Type = nil
    var msym: Symbol = nil
    var mcodename = ""
    var mname = node.str
    if rt != nil:
      var rt2 = rt
      if rt2.kind == tkPointer and rt2.subtype != nil and rt2.subtype.kind == tkRecord:
        rt2 = rt2.subtype
      if rt2.kind == tkRecord and rt2.methods.hasKey(mname):
        let m = rt2.methods[mname]
        msym = m.sym
        mtype = m.ftype
        mcodename = m.codename
    var a = ctx.getAttr(node)
    a.isMethod = true
    a.isMethodCall = false
    if msym != nil:
      ctx.symOf[recv] = msym
      msym.used = true
      a.calleeSym = msym
      a.calleeType = mtype
      a.codename = mcodename
      a.name = mname
      if mtype != nil and mtype.returns.len >= 1:
        a.typ = mtype.returns[0]
      else:
        a.typ = BuiltinTypes["void"]
    else:
      a.name = mname
      a.typ = BuiltinTypes["any"]
    return a.typ
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
    var a = ctx.getAttr(node)
    a.lvalue = true
    a.typ = BuiltinTypes["any"]
    # children[0] is the index/key, children[1] is the base expression.
    if node.children.len > 1:
      let bt = analyzeExpr(ctx, node.children[1])
      # A base that is itself an array yields its element type; a base that is
      # a pointer TO an array (e.g. a `*[0]byte` parameter, which the C backend
      # lowers to an element pointer) yields the array's element type too.
      # Without the pointer case the element silently resolves to `any`, which
      # then mis-drives the `any` load path in codegen.
      if bt != nil and bt.subtype != nil and bt.subtype.kind == tkArray and
         bt.subtype.subtype != nil:
        a.typ = bt.subtype.subtype
      elif bt != nil and bt.kind == tkArray and bt.subtype != nil:
        a.typ = bt.subtype
      discard analyzeExpr(ctx, node.children[0])
    return a.typ
  of nkVarargs:
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["varanys"]
    return a.typ
  else:
    return nil

# ---- statement analysis -------------------------------------------------------

proc hasAnnotation(iddecl: Node, name: string): bool =
  for c in iddecl.children:
    if c.kind == nkAnnotation and c.str == name:
      return true
  return false

proc applyFuncAnnotations(a, na: var Attr, node: Node) =
  ## Read the `<cimport>/<cinclude>/<cexport>/<inline>/...` annotations that
  ## sit as direct children of an `nkFuncDef` node and stamp them onto the
  ## funcdef attr `a` and its name/iddecl attr `na` (the oracle sets both).
  ## Without this a cimport like `function printf(...) <cimport,cinclude
  ## '<stdio.h>'> end` is lowered to an empty-bodied definition that shadows
  ## the real libc symbol, so `printf(...)` returns garbage.
  for c in node.children:
    if c.kind != nkAnnotation: continue
    case c.str
    of "cimport": a.cimport = true; na.cimport = true
    of "cexport": a.cexport = true; na.cexport = true
    of "inline": a.isInline = true; na.isInline = true
    of "const": a.isConst = true; na.isConst = true
    of "nodecl": a.nodecl = true; na.nodecl = true
    of "noinit": a.noinit = true; na.noinit = true
    of "close": a.isClose = true; na.isClose = true
    of "volatile": a.isVolatile = true; na.isVolatile = true
    of "cinclude":
      if c.children.len > 0 and c.children[0].kind == nkId:
        a.cinclude = c.children[0].str
        na.cinclude = c.children[0].str
    else: discard

proc analyzeVarDecl(ctx: var AnalyzerContext, node: Node) =
  var iddecls: seq[Node] = @[]
  var inits: seq[Node] = @[]
  var vtypes: seq[Type] = @[]
  var syms: seq[Symbol] = @[]
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
    # A6-naming: nominal @record/@enum types get the C tag <unit>_<binding>
    # (matches the oracle's `typedef ... tmp_unit_Rect;` shape).
    let nameSrc = if i < inits.len and inits[i].kind == nkType: inits[i]
                  elif iddecl.children.len > 0 and iddecl.children[0].kind == nkType:
                    iddecl.children[0]
                  else: nil
    if nameSrc != nil and vtype != nil and vtype.kind in {tkRecord, tkEnum} and vtype.name == "":
      vtype.name = ctx.unitname & "_" & iddecl.str
    # A6: `local X = @record{...}` / `local X = @enum(...){...}` bind a TYPE,
    # not a variable -- the oracle emits no storage for X, only the typedef.
    let isTypeBinding = (i < inits.len and inits[i].kind == nkType)
    vtypes.add vtype
    let initNode = if i < inits.len: inits[i] else: nil
    if initNode != nil and initNode.kind == nkInitList and vtype != nil and vtype.kind == tkAny:
      ctx.diags.add ctx.path & ": error: type 'any' cannot be initialized using an initializer list"
    if vtype.kind == tkFunction and iddecl.children.len > 0:
      let ts = ctx.funcTypeStrOf.getOrDefault(iddecl.children[0])
      if ts.len > 0: ctx.funcTypeStrOf[iddecl] = ts
    # Block-scoped shadow folding.  The C generator only emits storage for
    # top-level and function-body locals, so a local declared inside a `do`
    # block (or any other block at unit scope) cannot be given its own C
    # variable -- it would collapse onto the outer name and corrupt the outer
    # value once the block pops.  When such a local has a literal initializer
    # and shadows an outer binding, fold it to its value instead: observably
    # identical, and the only way to preserve the outer value with the current
    # code generator.  `finalize` un-folds any that turn out to be reassigned.
    let shadowsOuter = ctx.scope != ctx.globals and
                       not ctx.scope.symbols.hasKey(iddecl.str) and
                       lookup(ctx, iddecl.str) != nil and
                       initNode != nil and
                       initNode.kind in {nkNumber, nkString, nkBoolean, nkNil}
    let sym = register(ctx, iddecl.str, if isTypeBinding: skType else: skVar, vtype, iddecl)
    sym.codename = ctx.unitname & "_" & iddecl.str
    sym.used = true
    if not isTypeBinding:
      sym.staticstorage = true
      sym.vardecl = true
    sym.comptime = hasAnnotation(iddecl, "comptime")
    if sym.comptime: sym.isConst = true
    if shadowsOuter and not sym.comptime:
      sym.comptime = true
      sym.isConst = true
    ctx.symOf[iddecl] = sym
    syms.add sym
    var a = ctx.getAttr(iddecl)
    a.codename = sym.codename
    a.name = iddecl.str
    a.typ = vtype
    a.used = true
    a.isTypeBinding = isTypeBinding
    # Stage 0 (`: type` annotation binding): `local T: type = <typevalue>`
    # binds a *type-typed* variable, exactly as the oracle does -- its `typ`
    # is `primtypes.type` and its *value* is the concrete type
    # (attr={type="type", value="int64"}).  The `: type` annotation forces
    # `vtype` to primtypes.type, so the init's concrete type would otherwise be
    # dropped; resolve it here and record it on the symbol so a later `x: T`
    # in a type position dereferences it.  Without this `local x: T = 0`
    # resolves T to `type` and prints `nil` instead of `0`.
    if vtype == BuiltinTypes["type"] and i < inits.len and not isTypeBinding:
      let ct = analyzeTypeExpr(ctx, inits[i])
      if ct != nil:
        let tv = typeValueKey(inits[i], ct)
        sym.value = tv
        a.value = tv
        a.isTypeBinding = true
    if not isTypeBinding:
      a.lvalue = true
      a.staticstorage = true
      a.vardecl = true
    if sym.comptime: a.comptime = true
  ctx.multiRetCall = nil
  for i, init in inits:
    if init.kind == nkType:
      continue   # type binding: no runtime initializer
    let pt = if i < vtypes.len: vtypes[i] else: nil
    if init.kind == nkInitList:
      discard analyzeInitList(ctx, init, pt)
    else:
      discard analyzeExpr(ctx, init)
    if i < syms.len and syms[i].comptime:
      let ia = ctx.attrOf.getOrDefault(init)
      if ia != nil and ia.comptime and ia.value != "":
        syms[i].value = ia.value
        ctx.attrOf[iddecls[i]].value = ia.value

# ---- D1: polymorphic (`auto`-param) function monomorphization ----------------
##
## The reference oracle monomorphizes: one `<file>_<func>_<N>` C function is
## emitted per distinct argument-type signature at each call site.  This pass
## builds those specializations during `analyze` (one per distinct call signature,
## deduplicated, in first-call order) and records them on `AnalyzerResult.specials`
## for `cgen` to emit.  Uncalled `auto` functions emit nothing (dead-code elim).
##
## Out of scope (oracle rejects / crashes on all of these, so we do not handle
## them): recursion through `auto`, the `any` type, `*auto`, variadic `auto`,
## `auto` defaults, `function(x: auto): auto` value types, and the `## if`
## compile-time type-query meta-programming used by the reference corpus.

proc copyNode(n: Node): Node =
  ## Structural deep copy.  Attr/dump payloads live in `ctx.attrOf`/`ctx.dumpOf`
  ## keyed by node identity, so a specialized body must be a fresh tree.
  if n == nil: return nil
  let c = Node(kind: n.kind, str: n.str, litType: n.litType, boolVal: n.boolVal,
               isFunction: n.isFunction, isCall: n.isCall,
               isUnpackable: n.isUnpackable, isIndex: n.isIndex,
               isOperator: n.isOperator)
  for child in n.children:
    c.children.add copyNode(child)
  return c

proc typeToExpr(t: Type): Node =
  ## Render a concrete `Type` back into a type-expression node that
  ## `resolveTypeExpr`/`analyzeTypeExpr` will resolve to the same Type object
  ## (canonicalization dedups structurally-equal composites, so this round-trips).
  if t == nil: return newId("any")
  case t.kind:
    of tkRecord:
      var fields: seq[Node] = @[]
      for f in t.fields:
        fields.add newRecordField(if f.name.len > 0: f.name else: "f", typeToExpr(f.typ))
      return newRecordType(fields)
    of tkUnion:
      var fields: seq[Node] = @[]
      for f in t.fields:
        fields.add newUnionField(if f.name.len > 0: f.name else: "x", typeToExpr(f.typ))
      return newUnionType(fields)
    of tkEnum:
      var fields: seq[Node] = @[]
      for ef in t.enumFields:
        fields.add newEnumField(ef.name)
      return newEnumType(fields)
    of tkFunction:
      var args: seq[Node] = @[]
      for i, a in t.args:
        args.add newIdDecl("a" & $(i + 1), typeToExpr(a))
      var rets: seq[Node] = @[]
      for r in t.returns:
        rets.add typeToExpr(r)
      return newFuncType(args, rets)
    of tkOptional:
      return newOptionalType(typeToExpr(t.subtype))
    of tkPointer:
      return newPointerType(typeToExpr(t.subtype))
    of tkArray:
      return newArrayType(typeToExpr(t.subtype))
    else:
      return newId(if t.name != "": t.name else: "any")

proc isPolymorphic(ftype: Type): bool =
  ## A function type is polymorphic if any param or return is the `auto` kind.
  if ftype == nil or ftype.kind != tkFunction: return false
  for a in ftype.args:
    if a != nil and a.kind == tkAuto: return true
  for r in ftype.returns:
    if r != nil and r.kind == tkAuto: return true
  return false

proc allConcrete(argTypes: seq[Type]): bool =
  ## True when no argument type is the `auto` placeholder -- i.e. the call is
  ## ready to be monomorphized now rather than deferred to an outer
  ## specialization pass.
  for t in argTypes:
    if t != nil and t.kind == tkAuto: return false
  return true

proc specKey(funcName: string, argTypes: seq[Type]): string =
  ## Dedup key: function name + the concrete argument-type signature.
  var parts: seq[string] = @[]
  for t in argTypes:
    parts.add if t == nil: "nil" else: neluaTypeName(t)
  return funcName & "|" & parts.join(",")

proc findFirstReturn(node: Node): Node =
  ## First `nkReturn` in source order (textual, control-flow independent -- the
  ## oracle fixes the `auto` return from the first textual return).
  if node == nil: return nil
  if node.kind == nkReturn: return node
  for c in node.children:
    let r = findFirstReturn(c)
    if r != nil: return r
  return nil

proc deduceAutoReturns(ctx: var AnalyzerContext, node: Node, ftype: Type,
                       isSpecialization: bool) =
  ## Replace every `auto` return with the concrete type of the first textual
  ## return in the body.  A specialization (an instantiated `auto` function)
  ## whose body never returns is rejected, matching the oracle; the polymorphic
  ## original is left alone so uncalled `auto` functions are dead-code-eliminated
  ## instead of erroring.
  let body = node.children[^1]
  for i in 0 ..< ftype.returns.len:
    let rt = ftype.returns[i]
    if rt != nil and rt.kind == tkAuto:
      let ret = findFirstReturn(body)
      if ret != nil and ret.children.len == 1:
        let ct = ctx.attrOf.getOrDefault(ret.children[0]).typ
        ftype.returns[i] = if ct != nil: ct else: BuiltinTypes["void"]
      else:
        # No return, or a multi-value return -- both are rejected for an
        # instantiated `auto` function (the oracle: "never returns" /
        # "invalid return expression at index 2").
        if isSpecialization:
          ctx.diags.add(if ret == nil or ret.children.len < 2:
                          "a function return is set to 'auto', but the function never returns"
                        else: "invalid return expression at index 2")
        ftype.returns[i] = BuiltinTypes["void"]

proc collectReturns(node: Node, acc: var seq[Node]) =
  ## Collect every `nkReturn` reachable in `node`, recursing into control-flow
  ## blocks (if/elseif/else, while, repeat, for, do) but NOT into nested
  ## `nkFuncDef` -- a nested function has its own return type.  This is the
  ## multi-branch generalization of `findFirstReturn` (which only takes the
  ## first textual return).
  if node == nil: return
  if node.kind == nkReturn:
    acc.add node
    return
  if node.kind == nkFuncDef:
    return
  for c in node.children:
    collectReturns(c, acc)

proc promoteType(a, b: Type): Type =
  ## The oracle's `Type:promote_type`: the resulting type when folding a's type
  ## with b's type over a candidate set (see `unifyReturnTypes`).  Returns nil
  ## when the two are incompatible -- the caller then emits the 'any' error.
  if a == nil or b == nil: return nil
  case a.kind:
    of tkInteger, tkUinteger, tkByte, tkIsize, tkUsize,
        tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
        tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
        tkCchar, tkCschar, tkCuchar, tkCshort, tkCushort, tkCint, tkCuint,
        tkClong, tkCulong, tkClonglong, tkCulonglong, tkCptrdiff, tkCsize:
      if a == b: return a
      if b.isFloat: return b
      if not b.isIntegral: return nil
      if a.isSigned == b.isSigned:
        return if b.size >= a.size: b else: a
      else:
        let maxbits = max(a.size, b.size) * 8
        return PrimitiveTypes["int" & $maxbits]
    of tkNumber, tkFloat32, tkFloat64, tkFloat128, tkCfloat, tkCdouble, tkClongdouble:
      if a == b or b.isIntegral: return a
      if not b.isFloat: return nil
      return if b.size > a.size: b else: a
    of tkPointer:
      if b.isNilptr: return a
      # else: fall through to the base case (identical only)
    else: discard
  # base: identical only
  if a == b: a else: nil

proc unifyReturnTypes(candidates: seq[Type]): Type =
  ## Fold `promoteType` over the collected return-expression types (the oracle's
  ## `find_common_type`).  Returns nil when the set is incompatible, in which
  ## case the caller emits the "compiler deduced type 'any'" diagnostic.
  if candidates.len == 0: return BuiltinTypes["void"]
  var acc = candidates[0]
  for i in 1 ..< candidates.len:
    acc = promoteType(acc, candidates[i])
    if acc == nil: return nil
  return acc

proc specializeCall(ctx: var AnalyzerContext, calleeSym: Symbol,
                    argTypes: seq[Type]): (string, Type, string) =
  ## Build (or reuse) the monomorphized specialization of `calleeSym` for the
  ## given concrete argument types.  Returns (specCodename, specFtype,
  ## specFtypeStr) so the call site can point at the specialized C function.
  let origNode = calleeSym.node            ## the FuncDef (set by analyzeFuncDef)
  let origFtype = calleeSym.typ
  let funcName = origNode.children[0].str
  let key = specKey(funcName, argTypes)
  if ctx.specTable.hasKey(key):
    let sp = ctx.specTable[key]
    let sa = ctx.attrOf.getOrDefault(sp)
    return (sa.codename, sa.typ, ctx.funcTypeStrOf.getOrDefault(sp))
  # Recursion through `auto` is unsupported (the oracle crashes on it); bail out
  # rather than specializing infinitely, leaving the call pointing at the
  # polymorphic original (which cgen drops, so the program is broken either way).
  if ctx.specInFlight.hasKey(funcName):
    return (calleeSym.codename, calleeSym.typ, ctx.funcTypeStrOf.getOrDefault(origNode))
  ctx.specInFlight[funcName] = true
  # Build the concrete argument types, inferring each `auto` param independently.
  var concrete: seq[Type] = @[]
  for i, p in origFtype.args:
    if p != nil and p.kind == tkAuto and i < argTypes.len and argTypes[i] != nil:
      concrete.add argTypes[i]
    else:
      concrete.add if p != nil: p else: BuiltinTypes["any"]
  # Per-function counter, assigned in first-call order, starting at 1.
  let n = ctx.specCounter.getOrDefault(funcName) + 1
  ctx.specCounter[funcName] = n
  let specName = ctx.unitname & "_" & funcName & "_" & $n
  let specNode = copyNode(origNode)
  specNode.children[0].str = specName
  # Patch each `auto` param's type expression to its concrete type.
  var ai = 1
  while ai < specNode.children.len and specNode.children[ai].kind == nkIdDecl:
    let idx = ai - 1
    if idx < concrete.len and idx < origFtype.args.len and
       origFtype.args[idx].kind == tkAuto and concrete[idx].kind != tkAuto:
      if specNode.children[ai].children.len > 0:
        specNode.children[ai].children[0] = typeToExpr(concrete[idx])
    inc ai
  # `auto` return type expressions are left as `auto`; analyzeFuncDef deduces
  # the concrete return from the body after analysis.
  analyzeFuncDef(ctx, specNode, specName)
  ctx.specInFlight.del(funcName)
  ctx.specTable[key] = specNode
  ctx.specials.add specNode
  let sa = ctx.attrOf.getOrDefault(specNode)
  return (sa.codename, sa.typ, ctx.funcTypeStrOf.getOrDefault(specNode))

proc analyzeFuncDef(ctx: var AnalyzerContext, node: Node, specCodename: string = "") =
  let nameNode = node.children[0]
  let nameStr = nameNode.str
  # A6: colon-method `Record:method(args)`. nameNode is an nkColonIndex whose
  # children[0] is the record type name; inject an implicit `self: *Record`
  # first parameter and tag the C function <Record>_<method>.
  var isMethod = false
  var recordType: Type = nil
  var methodName = nameStr
  if nameNode.kind == nkColonIndex:
    let recNameNode = nameNode.children[0]
    let rsym = ctx.lookup(recNameNode.str)
    if rsym != nil and rsym.typ != nil and rsym.typ.kind == tkRecord:
      recordType = rsym.typ
      isMethod = true
      methodName = nameNode.str
  var selfDecl: Node = nil
  if isMethod:
    selfDecl = newIdDecl("self", nil)
    node.children = @[nameNode, selfDecl] & node.children[1 ..< node.children.len]
  # A `<cimport>` funcdef binds to an external C symbol by its raw name (the
  # oracle emits `printf(...)` not `tmp_unit_printf(...)`), so its codename is
  # just the function's nelua name, not the mangled unit prefix.
  var isCimport = false
  for c in node.children:
    if c.kind == nkAnnotation and c.str == "cimport":
      isCimport = true; break
  let codename = if specCodename != "": specCodename
                 elif isCimport: nameStr
                 elif isMethod: recordType.name & "_" & methodName
                 else: ctx.unitname & "_" & nameStr
  let symName = if specCodename != "": specCodename else: methodName
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
    let atype = if arg == selfDecl: pointerType(recordType)
                elif arg.children.len > 0: analyzeTypeExpr(ctx, arg.children[0], false)
                else: nil
    let at = if atype != nil: atype else: BuiltinTypes["any"]
    ftype.args.add at
    aparts.add arg.str & ": " & neluaTypeName(at)
  # C8: a trailing `...: cvarargs` / `...: cvalist` param is a C variadic slot
  # (an nkVarargsType node, not an nkIdDecl).  Record it on the ftype so the C
  # declaration emits `...`; without this the param is silently dropped and a
  # cimport like `printf(format, ...)` is declared with one parameter.
  var vaNode: Node = nil
  for c in node.children:
    if c.kind == nkVarargsType:
      vaNode = c; break
  if vaNode != nil:
    let vt = if vaNode.str == "cvalist": BuiltinTypes["cvalist"] else: BuiltinTypes["cvarargs"]
    ftype.args.add vt
  for r in returns:
    let rt = analyzeTypeExpr(ctx, r, false)
    if rt != nil:
      ftype.returns.add rt
  # No explicit return annotation: the type is inferred from the first textual
  # `return` in the body (the oracle does this; `function f() return 5 end`
  # is int64).  The default `void` is applied below, after the body is analyzed.
  var a = ctx.getAttr(node)
  a.codename = codename
  a.comptime = true
  a.lvalue = true
  a.name = nameStr
  a.staticstorage = true
  a.typ = ftype
  a.used = true
  var na = ctx.getAttr(nameNode)
  na.codename = codename
  na.comptime = true
  na.lvalue = true
  na.name = nameStr
  na.staticstorage = true
  na.typ = ftype
  na.used = true
  applyFuncAnnotations(a, na, node)
  var nd = ctx.getDump(node)
  nd.funcdeclared = true
  nd.funcdefined = true
  var nd2 = ctx.getDump(nameNode)
  nd2.funcdeclared = true
  nd2.funcdefined = true
  let sym = register(ctx, symName, skFunc, ftype, node)
  sym.codename = codename
  sym.used = true
  ctx.symOf[nameNode] = sym
  ctx.symOf[node] = sym
  # A6: register the method on the record type so DotIndex/CallMethod resolve.
  if isMethod and recordType != nil:
    recordType.methods[methodName] = MethodDesc(sym: sym, codename: codename, ftype: ftype)
  let saved = ctx.scope
  ctx.scope = newScope(saved, nameStr)
  ctx.scope.isFunction = true
  for arg in args:
    let atype = if arg == selfDecl: pointerType(recordType)
                elif arg.children.len > 0: analyzeTypeExpr(ctx, arg.children[0], false)
                else: nil
    let at = if atype != nil: atype else: BuiltinTypes["any"]
    var arga = ctx.getAttr(arg)
    arga.codename = arg.str
    arga.lvalue = true
    arga.name = arg.str
    arga.typ = at
    let asym = register(ctx, arg.str, skParam, at, arg)
    asym.codename = arg.str
    ctx.symOf[arg] = asym
    if arg.children.len > 0:
      discard analyzeTypeExpr(ctx, arg.children[0], false)
  analyzeBlock(ctx, body)
  ctx.scope = saved
  # An untyped function (no `: T` on the return) has its return type deduced
  # from the return expressions in its body, matching the oracle: collect every
  # reachable return (all control-flow branches, but not nested functions),
  # take the first value of each multi-value return, and unify the candidate
  # set.  Bare `return` and multi-value returns whose first value has no
  # attr contribute nothing; an empty set (or all-bare) is `void`; an
  # incompatible set emits the "compiler deduced type 'any'" diagnostic.
  if ftype.returns.len == 0:
    var rets: seq[Node] = @[]
    collectReturns(body, rets)
    var candidates: seq[Type] = @[]
    for ret in rets:
      if ret.children.len > 0:
        let a = ctx.attrOf.getOrDefault(ret.children[0])
        if a != nil and a.typ != nil:
          candidates.add a.typ
    let unified = unifyReturnTypes(candidates)
    if unified != nil:
      ftype.returns.add unified
    else:
      ctx.diags.add ctx.path & ": error: compiler deduced type 'any' here, but it's not supported yet, please fix this variable type"
      ftype.returns.add BuiltinTypes["void"]
  # D1: an `auto` return is fixed by the first textual return in the body.
  deduceAutoReturns(ctx, node, ftype, specCodename != "")
  var rparts: seq[string] = @[]
  for r in ftype.returns: rparts.add neluaTypeName(r)
  let rs = if rparts.len == 0: "void"
           elif rparts.len == 1: rparts[0]
           else: "(" & rparts.join(", ") & ")"
  let ftypeStr = "function(" & aparts.join(", ") & "): " & rs
  ctx.funcTypeStrOf[nameNode] = ftypeStr
  ctx.funcTypeStrOf[node] = ftypeStr
  a.value = nameStr & ": " & ftypeStr
  na.value = a.value
  nd.ftype = ftypeStr
  nd2.ftype = ftypeStr

proc resolveTypeValue(ctx: var AnalyzerContext, key: string): Type =
  ## Resolve a type-as-value lookup key to its concrete Type.  Builtins use
  ## their canonical C name (int64, uint8); named user types are looked up in
  ## scope as type symbols; a key that is itself a type alias dereferences
  ## transitively.  Returns nil when the key names no type.
  if key.len == 0: return nil
  if BuiltinTypes.hasKey(key): return BuiltinTypes[key]
  if PrimitiveTypes.hasKey(key): return PrimitiveTypes[key]
  let sym = ctx.lookup(key)
  if sym != nil and sym.typ != nil:
    if sym.kind == skType:
      return sym.typ
    if sym.typ == BuiltinTypes["type"] and sym.value.len > 0:
      return resolveTypeValue(ctx, sym.value)
  return nil

proc typeValueKey(node: Node, ct: Type): string =
  ## The lookup key for a type-as-value: the canonical C name for builtins
  ## (int64, uint8) and the source identifier for named user types (Record,
  ## Color), unwrapping any surrounding parens.  This is what the oracle stores
  ## as a type alias's `value` and what `resolveTypeValue` consumes.
  if ct == nil: return ""
  let cn = neluaTypeName(ct)
  if BuiltinTypes.hasKey(cn) or PrimitiveTypes.hasKey(cn):
    return cn
  var n = node
  while n != nil and n.kind == nkParen and n.children.len > 0:
    n = n.children[0]
  if n != nil and n.kind == nkId:
    return n.str
  return cn

proc analyzeTypeExpr*(ctx: var AnalyzerContext, node: Node, usedType = true): Type =
  if node == nil: return nil
  case node.kind
  of nkParen:
    # A parenthesized type-value, `local T: type = (Record)`, unwraps to its
    # inner type expression -- matching the oracle, which accepts the parens.
    if node.children.len > 0:
      return analyzeTypeExpr(ctx, node.children[0], usedType)
    return nil
  of nkId:
    let t = if BuiltinTypes.hasKey(node.str): BuiltinTypes[node.str]
            elif PrimitiveTypes.hasKey(node.str): PrimitiveTypes[node.str]
            else: nil
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
    # A1: named user types (@record/@enum) are registered as type symbols in
    # scope; resolve them here so type expressions like `MASK` and `Rect`
    # bind to the nominal Type rather than falling through to nil.
    let sym = ctx.lookup(node.str)
    if sym != nil and sym.typ != nil and sym.kind == skType:
      var a = ctx.getAttr(node)
      a.name = node.str
      a.typ = BuiltinTypes["type"]
      a.value = node.str
      a.vardecl = true
      a.used = usedType
      # Stage 0: a type-typed variable holding a concrete type value (e.g.
      # `local T: type = integer`) dereferences to that type when it appears in
      # a type position, matching the oracle's `x: T` resolving to `int64`.
      if sym.value.len > 0 and sym.value != node.str:
        let rt = if BuiltinTypes.hasKey(sym.value): BuiltinTypes[sym.value]
                 elif PrimitiveTypes.hasKey(sym.value): PrimitiveTypes[sym.value]
                 else: nil
        if rt != nil:
          a.value = neluaTypeName(rt)
          return rt
      return sym.typ
    # A2: a type-typed *variable* (a type alias, `local T: type = Record`)
    # has `typ` = primtypes.type and carries the aliased type's lookup key in
    # `value`.  In a type position it dereferences to the aliased type,
    # matching the oracle's `*T` resolving to `pointer(Record)` -- without this
    # `*T` collapses to `void*` exactly like the old `*Record` parameter bug.
    if sym != nil and sym.typ != nil and sym.typ == BuiltinTypes["type"] and sym.value.len > 0:
      var a = ctx.getAttr(node)
      a.name = node.str
      a.typ = BuiltinTypes["type"]
      a.value = sym.value
      a.vardecl = true
      a.used = usedType
      let rt = resolveTypeValue(ctx, sym.value)
      if rt != nil:
        return rt
      return nil
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
    if node.children.len > 1:
      discard analyzeExpr(ctx, node.children[1])
      let sa = ctx.attrOf.getOrDefault(node.children[1])
      if sa != nil and sa.comptime and sa.value != "":
        try: size = parseInt(sa.value)
        except ValueError: discard
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
  of nkType:
    let ty = analyzeNominalType(ctx, node.children[0], usedType)
    if ty != nil:
      var a = ctx.getAttr(node)
      a.typ = BuiltinTypes["type"]
      a.value = neluaTypeName(ty)
      a.vardecl = usedType
    return ty
  else:
    return nil

proc analyzeNominalType*(ctx: var AnalyzerContext, node: Node, usedType = true): Type =
  ## Build a nominal Type from a `@record`/`@enum` type-expression node.
  ## Nominal types get a fresh typeid and C tag; they bypass structural
  ## canonicalization so each definition site is distinct from its structural
  ## twin and from every other nominal type.
  if node == nil:
    return nil
  case node.kind
  of nkRecordType:
    var fields: seq[Field] = @[]
    for c in node.children:
      if c.kind == nkRecordField:
        let ft = if c.children.len > 0: analyzeTypeExpr(ctx, c.children[0], usedType)
                 else: BuiltinTypes["any"]
        let ftt = if ft != nil: ft else: BuiltinTypes["any"]
        fields.add Field(name: c.str, typ: ftt)
    let t = nominalRecordType("", fields)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  of nkEnumType:
    var primtype: Type = BuiltinTypes["integer"]
    var ef: seq[EnumField] = @[]
    var firstField = true
    var current = 0
    var i = 0
    if node.children.len > 0 and node.children[0].kind != nkEnumField:
      let pt = analyzeTypeExpr(ctx, node.children[0], usedType)
      if pt != nil: primtype = pt
      i = 1
    while i < node.children.len:
      let c = node.children[i]
      if c.kind != nkEnumField:
        inc i; continue
      if firstField and c.children.len == 0:
        ctx.diags.add ctx.path & ": error: first enum field requires an initial value"
        return nil
      if c.children.len > 0:
        discard analyzeExpr(ctx, c.children[0])
        let ival = ctx.foldIntValue(c.children[0])
        current = ival
        ef.add EnumField(name: c.str, value: current)
      else:
        inc current
        ef.add EnumField(name: c.str, value: current)
      firstField = false
      inc i
    let t = nominalEnumType("", primtype, ef)
    var a = ctx.getAttr(node)
    a.typ = BuiltinTypes["type"]
    a.value = neluaTypeName(t)
    return t
  else:
    return analyzeTypeExpr(ctx, node, usedType)

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
  inc ctx.loopDepth
  analyzeBlock(ctx, node.children[1])
  dec ctx.loopDepth

proc parseNeluaInt(num: string): int =
  ## Parse a Nelua integer literal (decimal or `0x` hex) to a Nim int.
  if num.len >= 2 and num[0] == '0' and (num[1] == 'x' or num[1] == 'X'):
    let hex = num[2 ..< num.len]
    for c in hex:
      let d = if c >= '0' and c <= '9': ord(c) - ord('0')
             elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
             elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
             else: 0
      result = result * 16 + d
  else:
    result = parseInt(num)

proc foldIntValue(ctx: var AnalyzerContext, node: Node): int =
  if node.kind == nkNumber:
    let (num, _) = splitNumberSuffix(node.str)
    result = parseNeluaInt(num)
  elif node.kind == nkBinaryOp:
    let a = ctx.attrOf.getOrDefault(node)
    if a != nil and a.comptime and a.value.len > 0:
      let (num, _) = splitNumberSuffix(a.value)
      result = parseNeluaInt(num)

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
  if node.str != "":
    ctx.getDump(node).compop = node.str
  elif hasStep:
    # A negative step flips the loop direction: the bound test becomes `>=`.
    # The parser only records `lt` for the `<N` exclusive form, so the
    # descending case has to be derived here from the step's sign.
    let sa = ctx.attrOf.getOrDefault(step)
    if sa != nil and sa.comptime and sa.value.len > 0:
      try:
        ctx.getDump(node).compop = if parseFloat(sa.value) < 0.0: "ge" else: "le"
      except ValueError:
        ctx.getDump(node).compop = "le"
    else:
      ctx.getDump(node).compop = "le"
  else:
    ctx.getDump(node).compop = "le"
  ctx.getDump(node).fixedend = isComptime(endv, ctx)
  if hasStep:
    ctx.getDump(node).fixedstep = dumpExprString(ctx, step)
  else:
    ctx.getDump(node).fixedstep = "1"
  let saved = ctx.scope
  ctx.scope = newScope(saved, iddecl.str)
  inc ctx.loopDepth
  analyzeBlock(ctx, body)
  dec ctx.loopDepth
  ctx.scope = saved

proc analyzeForIn(ctx: var AnalyzerContext, node: Node) =
  let body = node.children[^1]
  for i in 0 ..< node.children.len - 1:
    discard analyzeExpr(ctx, node.children[i])
  inc ctx.loopDepth
  analyzeBlock(ctx, body)
  dec ctx.loopDepth

proc analyzeDefer(ctx: var AnalyzerContext, node: Node) =
  analyzeBlock(ctx, node.children[0])

proc analyzeDo(ctx: var AnalyzerContext, node: Node) =
  let saved = ctx.scope
  ctx.scope = newScope(saved, "do")
  analyzeBlock(ctx, node.children[0])
  ctx.scope = saved

proc analyzeRepeat(ctx: var AnalyzerContext, node: Node) =
  inc ctx.loopDepth
  analyzeBlock(ctx, node.children[0])
  discard analyzeExpr(ctx, node.children[1])
  dec ctx.loopDepth

proc analyzeAssign(ctx: var AnalyzerContext, node: Node) =
  let ntargets = ctx.assignTargets.getOrDefault(node, 1)
  # Analyze the right-hand side first so that an untyped local target (`local y`
  # with no annotation and no initializer) can inherit the type of its first
  # assignment.  The oracle does exactly this flow-sensitive inference; without
  # it `y` stays `nil` and the emitted C is `(void)(...)`.
  var rtypes: seq[Type] = @[]
  for i in ntargets ..< node.children.len:
    rtypes.add analyzeExpr(ctx, node.children[i])
  for i in 0 ..< ntargets:
    let t = node.children[i]
    if t.kind == nkId:
      let sym = ctx.lookup(t.str)
      if sym != nil:
        sym.mutate = true
        ctx.symOf[t] = sym
        var ta = ctx.getAttr(t)
        ta.mutate = true
        if sym.kind == skVar and i < rtypes.len and rtypes[i] != nil and
           not rtypes[i].isNiltype and not rtypes[i].isAny and
           (sym.typ == nil or sym.typ.kind == tkNiltype):
          sym.typ = rtypes[i]
          ta.typ = rtypes[i]
          let iddecl = sym.node
          if iddecl != nil:
            let da = ctx.getAttr(iddecl)
            da.typ = rtypes[i]
        elif sym.kind == skType and i < rtypes.len and rtypes[i] != nil and
             rtypes[i].kind in {tkRecord, tkUnion} and sym.typ != nil and
             sym.typ.kind == rtypes[i].kind:
          # C5: forwarddecl type redefinition `R = @record{...}`.  Adopt the
          # new definition's fields/methods into the existing type object so
          # earlier references (e.g. `S`'s field `r: R`) see the completed type
          # and cgen emits one typedef with the real fields -- instead of an
          # empty struct plus a bogus runtime `R = (struct R)();` assignment
          # to a typedef name.
          sym.typ.fields = rtypes[i].fields
          sym.typ.methods = rtypes[i].methods
          ta.typ = rtypes[i]
      discard analyzeExpr(ctx, t)
    else:
      discard analyzeExpr(ctx, t)

proc analyzeReturn(ctx: var AnalyzerContext, node: Node) =
  for c in node.children:
    discard analyzeExpr(ctx, c)

proc analyzeSwitch(ctx: var AnalyzerContext, node: Node) =
  ## Validate and analyze an `nkSwitch`:
  ##  * the subject expression must be convertible to an integral type;
  ##  * every case value must be a compile-time foldable integral constant;
  ##  * the subject is analyzed once (C evaluates it once inside the `switch`
  ##    condition; the Lua backend would hoist it to a temp, which this
  ##    compiler does not emit -- it has no Lua code generator).
  ##
  ## The flat `newSwitch` layout is `[subject, vals..., body, vals..., body,
  ## ..., [else-body]]`; case bodies are always `nkBlock` and case values are
  ## never blocks, so scanning on `nkBlock` boundaries recovers the clauses.
  let subj = node.children[0]
  let stype = analyzeExpr(ctx, subj)
  if stype == nil or not stype.isIntegral:
    let tn = if stype != nil: neluaTypeName(stype) else: "nil"
    ctx.diags.add ctx.path & ": error: `switch` statement must be convertible to an integral type, but got type " & tn & " (non integral)"
    return
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
      ## the optional `else` block: a bare Block with no preceding value list
      analyzeBlock(ctx, body)
    else:
      for v in vals:
        discard analyzeExpr(ctx, v)
        var va = ctx.attrOf.getOrDefault(v)
        if va == nil or not va.comptime or va.typ == nil or not va.typ.isIntegral:
          ctx.diags.add ctx.path & ": error: `case` statement must evaluate to a compile time integral value"
          return
      analyzeBlock(ctx, body)

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
  of nkSwitch: analyzeSwitch(ctx, node)
  of nkBreak, nkContinue:
    if ctx.loopDepth == 0:
      let what = if node.kind == nkBreak: "`break`" else: "`continue`"
      ctx.diags.add ctx.path & ": error: " & what & " statement is not inside a loop"
    discard
  of nkLabel, nkGoto: discard
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
      # Un-fold a block-scoped shadow that turned out to be reassigned.  Folding
      # it would route its assignment through the outer name (they share a
      # codename), corrupting the outer value; revert to the ordinary behaviour.
      # Such a local cannot be given its own C variable regardless, so this is
      # the least-bad outcome for an unsupported case.
      if sym.comptime and sym.mutate and sym.scope != nil and sym.scope != ctx.globals:
        sym.comptime = false
        sym.value = ""
        a.comptime = false
        a.value = ""
    elif node.kind == nkId:
      var a = ctx.getAttr(node)
      if sym.mutate: a.mutate = true

# ---- dumpAnaled ---------------------------------------------------------------
##
## Renders the analyzed tree in the exact `--print-analyzed-ast` format.

proc quoteStr(s: string): string = "\"" & s & "\""

proc kindName(node: Node): string =
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

proc buildSwitchCases(ctx: var AnalyzerContext, node: Node, indent: int): string =
  ## Render the `nkSwitch` cases container (a bare `{ }`) in the reference's
  ## nested shape, with each case's value list as a bare `{ }` and each body as
  ## a `Block`.  The flat `newSwitch` layout is scanned on `nkBlock` boundaries.
  let fldInd = "  ".repeat(indent + 1)      ## cases-container indent
  let valInd = "  ".repeat(indent + 2)      ## value-list / body indent
  var s = fldInd & "{\n"
  var i = 1
  let nc = node.children.len
  var first = true
  while i < nc:
    var vals: seq[Node] = @[]
    while i < nc and node.children[i].kind != nkBlock:
      vals.add node.children[i]
      inc i
    if i >= nc: break
    let body = node.children[i]
    inc i
    if not first: s.add ",\n"
    first = false
    if vals.len > 0:
      s.add valInd & "{\n"
      for vi, v in vals:
        s.add dumpAnaled(ctx, v, indent + 3)
        if vi < vals.len - 1: s.add ",\n"
        else: s.add "\n"
      s.add valInd & "},\n"
      s.add dumpAnaled(ctx, body, indent + 2)
    else:
      s.add dumpAnaled(ctx, body, indent + 2)
  s.add fldInd & "}\n"
  return s

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
  of nkSwitch:
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((true, buildSwitchCases(ctx, node, indent)))
  of nkForNum:
    let hasStep = node.children.len == 5
    let step = if hasStep: node.children[3] else: nil
    let body = node.children[^1]
    allFields.add((true, dumpAnaled(ctx, node.children[0], indent + 1)))
    allFields.add((true, dumpAnaled(ctx, node.children[1], indent + 1)))
    allFields.add((false, if node.str != "": quoteStr(node.str) else: "false"))
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

# ---- D2: `require` resolution -------------------------------------------------
#
# A top-level `require 'name'` statement is a call on the builtin `require`
# (see parser.nim).  At analysis time we resolve it to a `.nelua` file, analyze
# that module through the same pipeline, and import its exported symbols into
# this unit's scope so references to them type-check and resolve to the
# dependency's mangled codenames.  `compile.nim` still compiles each dependency
# to a cached `.c` file (phase 1a); the analyzed trees returned here let `cgen`
# emit the dependency's code inline in the parent's translation unit.

proc findRequires*(ast: Node): seq[string] =
  ## Collect the module names of every top-level `require 'name'` statement.
  if ast == nil:
    return
  for c in ast.children:
    if c.kind == nkCall and c.children.len == 2 and
       c.children[1].kind == nkId and c.children[1].str == "require" and
       c.children[0].kind == nkString:
      result.add c.children[0].str

proc resolveModule*(name: string, config: Config, requiringPath: string): string =
  ## Resolve a required module name to an absolute `.nelua` file path.
  ##
  ## Module names use `.` as a path separator (`require 'allocators.general'`
  ## -> `lib/allocators/general.nelua`).  A leading `.` segment means "the
  ## directory of the file doing the requiring".  Search order: the requiring
  ## file's own directory, then the current working directory, then the project
  ## `lib/` dir, then any `--path` entries.  Returns "" when no candidate exists.
  ##
  ## The lexer keeps a string literal's delimiters in its token value, so a
  ## `require 'foo'` name arrives as `'foo'`; strip the surrounding quotes here.
  var name = name
  if name.len >= 2 and ((name[0] == '"' and name[^1] == '"') or
                        (name[0] == '\'' and name[^1] == '\'')):
    name = name[1 ..< name.len - 1]
  let segments = name.split('.')
  var candidates: seq[string] = @[]
  if segments.len > 0 and segments[0] == "":
    let base = requiringPath.splitFile().dir
    candidates.add base / segments[1 ..< segments.len].join("/") & ".nelua"
  let reqDir = requiringPath.splitFile().dir
  if reqDir.len > 0:
    candidates.add reqDir / segments.join("/") & ".nelua"
  candidates.add getCurrentDir() / segments.join("/") & ".nelua"
  candidates.add getCurrentDir() / "lib" / segments.join("/") & ".nelua"
  for p in config.paths:
    candidates.add p / segments.join("/") & ".nelua"
  for c in candidates:
    if fileExists(c):
      return c
  return ""

proc importSymbols(ctx: var AnalyzerContext, depCtx: AnalyzerContext) =
  ## Copy a dependency's exported top-level symbols into the parent's global
  ## scope.  Only symbols whose `scope` is the dependency's global scope are
  ## exported; params and locals are invisible outside the module.  The copied
  ## symbols keep the dependency's mangled `codename` (e.g. `tmp_dep1_answer`),
  ## so a reference in the parent lowers to the same C identifier the dependency
  ## defines.  A parent symbol of the same name registered later (during
  ## `analyzeBlock`) shadows the imported one, matching Nelua scoping.
  for node, sym in depCtx.symOf:
    if sym == nil or sym.scope != depCtx.globals:
      continue
    let newSym = Symbol(name: sym.name, kind: sym.kind, typ: sym.typ,
                        node: sym.node, scope: ctx.globals,
                        used: sym.used, comptime: sym.comptime,
                        isConst: sym.isConst, global: sym.global,
                        staticstorage: sym.staticstorage, codename: sym.codename,
                        mutate: sym.mutate, refed: sym.refed, vardecl: sym.vardecl)
    ctx.globals.symbols[sym.name] = newSym
    # The function-type render string is keyed by the declaring FuncDef node;
    # carry it over so the parent's dump/codename lookup finds it.
    if depCtx.funcTypeStrOf.hasKey(node):
      ctx.funcTypeStrOf[node] = depCtx.funcTypeStrOf[node]

proc analyzeModule(source: string, path: string, config: Config,
                   visited: var Table[string, bool]): AnalyzerResult =
  ## Recursive workhorse for `analyze`: parse, preprocess, resolve + analyze
  ## every `require` dependency (importing its exported symbols), then analyze
  ## this unit's own body.  `visited` breaks circular `require` chains.
  var ctx: AnalyzerContext
  ctx.source = source
  ctx.path = path
  ctx.unitname = computeUnitname(path)
  bootstrap(ctx)
  visited[path] = true
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

  # P3-require: resolve each required module and recursively analyze it before
  # this unit's body is analyzed, so the imported symbols are in scope.
  for modname in findRequires(ast):
    let depPath = resolveModule(modname, config, path)
    if depPath == "":
      ctx.diags.add "require '" & modname & "': module not found"
      continue
    if visited.hasKey(depPath):
      continue
    var depSrc = ""
    try:
      depSrc = readFile(depPath)
    except OSError, IOError:
      ctx.diags.add "require '" & modname & "': cannot read '" & depPath & "'"
      continue
    let depRes = analyzeModule(depSrc, depPath, config, visited)
    result.deps.add depRes
    if depRes.root != nil:
      importSymbols(ctx, depRes.ctx)
    for d in depRes.ctx.diags:
      ctx.diags.add d

  countAssignTargets(ctx, ast)
  let ra = ctx.getAttr(ast)
  ra.filename = path
  # P4: analyze
  analyzeBlock(ctx, ast)
  finalize(ctx)
  result.root = ast; result.ctx = ctx; result.specials = ctx.specials

proc analyze*(source: string, path: string,
              config: Config = defaultConfig()): AnalyzerResult =
  ## Analyze a Nelua `source` (at `path`), recursively resolving and importing
  ## every `require` dependency.  The dependency analyzed trees are returned in
  ## `AnalyzerResult.deps` (in require order) so the code generator can emit
  ## their code inline.  `config` defaults to `defaultConfig()`, which is
  ## sufficient for cwd-/lib-relative `require`s; callers with `--path` entries
  ## should pass their real config.
  var visited = initTable[string, bool]()
  result = analyzeModule(source, path, config, visited)

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