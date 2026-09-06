## Pure helpers shared by the analysis pass: type rendering, builtin tables,
## bootstrap, literal typing, and constant folding.

## These procs are leaf-ish: they touch only the `types.nim` type system, the
## `analyzer_ctx.nim` context accessors, and the AST.  None of them call into
## the expression/statement analysis core, so this module has no dependency on
## `analyzer.nim` and can be imported freely by it (and re-exported from it so
## `cgen.nim` keeps finding `neluaTypeName` where it always has).

import ast
import types
import sema
import tables
import sequtils
import strutils
import math
import os
import config
import analyzer_ctx

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

# ---- builtin / recognized-name tables ----------------------------------------
##
## The set of names the oracle treats as *not* "undeclared symbols": the Lua
## builtins it exposes as globals (`print`, `tonumber`, ...), the type keywords
## it accepts as first-class type values (`any`, `integer`, ...), and the
## `likely`/`unlikely` branch hints it accepts as call-only builtins.  An
## identifier that is out of scope but is one of these is NOT an "undeclared
## symbol" -- the oracle either resolves it or (for the ones we do not fully
## implement) leaves it to a generic lowering -- so the undeclared-symbol
## diagnostic must exempt them all.

const BuiltinNames* = ["print", "tonumber", "tostring", "type", "error", "assert",
                       "select", "pcall", "setmetatable", "getmetatable", "rawget",
                       "rawset", "rawlen", "rawequal", "unpack", "require",
                       "collectgarbage", "next", "pairs", "ipairs", "len"]

const HintNames* = ["likely", "unlikely"]

proc isBuiltinName*(s: string): bool = s in BuiltinNames
proc isHintName*(s: string): bool = s in HintNames
proc isTypeKeywordName*(s: string): bool =
  ## Type keywords the oracle accepts as first-class type values in value
  ## position (`any == integer` is a legal comparison).  `parser.isTypeKeyword`
  ## covers exactly this set; mirror it here so the analyzer's name resolution
  ## does not reject a type value as an undeclared symbol.
  case s
  of "integer", "number", "string", "boolean", "isize", "usize",
      "cchar", "cshort", "cint", "clong", "cfloat", "cdouble",
      "auto", "void", "type", "any":
    result = true

proc isRecognizedName*(s: string): bool =
  ## A name the oracle does NOT report as an "undeclared symbol" when it is out
  ## of scope: a builtin, a type keyword, or a hint.  Used by the call-callee
  ## check, which has no builtin fallback of its own.
  result = isBuiltinName(s) or isTypeKeywordName(s) or isHintName(s)

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

proc splitNumberSuffix*(text: string): (string, string) =
  ## Split a numeric literal into (numericPart, suffix). The suffix is the
  ## trailing `_<ident>` (e.g. `_u32`); it is "" when absent. Nelua numeric
  ## literals never contain `_` outside a suffix, so the first `_` delimits it.
  let u = text.find('_')
  if u < 0: return (text, "")
  return (text[0 ..< u], text[u ..< text.len])

proc numberTypeAndValue*(text: string): (Type, string, int) =
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
  elif num.len >= 2 and num[0] == '0' and (num[1] == 'b' or num[1] == 'B'):
    # Binary literal `0b1010`.  The oracle accepts this (Lua 5.4 tonumber);
    # without this branch it falls through to parseInt, which rejects the `0b`
    # prefix with "invalid integer".
    let bin = num[2 ..< num.len]
    iv = 0
    for c in bin:
      let d = if c == '0': 0 elif c == '1': 1 else: 0
      iv = iv * 2 + d
    base = 2
  elif num.contains('.') or num.contains('e') or num.contains('E'):
    fv = parseFloat(num)
    isFloat = true
  else:
    # Integer literal.  The oracle (Lua 5.4 tonumber) treats any magnitude
    # >= 2^63 as a float -- including -2^63 itself, whose magnitude is exactly
    # 2^63 -- so `#[primtypes.isize.min]#` splices to a float literal and
    # `print(-9223372036854775808)` yields `-9.2233720368548e+18`.  Parse the
    # unsigned magnitude: 19 digits and greater than 2^63-1, or 20+, is a
    # float; everything else is a signed int64.
    let neg = num.len > 0 and num[0] == '-'
    let absStr = if neg: num[1 ..< num.len] else: num
    if absStr.len > 19 or (absStr.len == 19 and absStr > "9223372036854775807"):
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

proc stripQuotes*(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    return s[1 ..< s.len - 1]
  if s.len >= 2 and s[0] == '\'' and s[^1] == '\'':
    return s[1 ..< s.len - 1]
  return s

proc valueQuoteKind*(t: Type): int =
  ## 0 = quote the value, 1 = bare float, 2 = bare bool
  if t == nil: return 0
  if t.kind == tkBoolean: return 2
  if t.isFloat: return 1
  return 0

# ---- constant folding ---------------------------------------------------------

proc floorDiv*(a, b: int): int =
  ## Integer division rounding toward negative infinity (Lua `//`, and the
  ## arithmetic shift `>>>`).  Nim `div` truncates toward zero, so step the
  ## quotient down by one when the signs differ and the remainder is non-zero.
  let q = a div b
  let r = a mod b
  if r != 0 and ((a < 0) != (b < 0)): q - 1 else: q

proc arithShr*(a, b: int): int =
  ## Arithmetic (sign-preserving) right shift, saturated at the bit width.
  ## `>>>` is not C's `>>` (UB for shift >= width): a non-negative value
  ## shifted by >= 64 becomes 0, a negative one becomes -1.
  if b <= 0: return a
  if b >= 63: return if a < 0: -1 else: 0
  return floorDiv(a, 1 shl b)

proc tryFoldBinary*(op: string, lt: Type, lv: string, rt: Type, rv: string): (Type, string) =
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
    of "tdiv":
      if b == 0: return (nil, "")
      return (lt, $(a div b))
    of "tmod":
      if b == 0: return (nil, "")
      return (lt, $(a mod b))
    of "asr": return (lt, $(arithShr(a, b)))
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

proc tryFoldUnary*(op: string, rt: Type, rv: string): (Type, string) =
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

proc isComptime*(node: Node, ctx: AnalyzerContext): bool =
  if node == nil: return false
  case node.kind
  of nkNumber, nkString, nkBoolean, nkNil, nkNilptr: true
  of nkBinaryOp, nkUnaryOp:
    let a = ctx.attrOf.getOrDefault(node)
    a != nil and a.comptime
  of nkId:
    ## A reference to a `<comptime>` variable (e.g. `local N <comptime> = 100`)
    ## is a compile-time constant; without this, `N + 1` in an array size
    ## never folded and the array was emitted with no bound.
    let a = ctx.attrOf.getOrDefault(node)
    a != nil and a.comptime
  else: false

# ---- D2: `require` resolution (pure helpers) --------------------------------
#
# The module-name scan, path resolution, and symbol import for
# `require 'name'` statements.  These are leaf-ish: they touch only the AST,
# `Config`, the file system, and `AnalyzerContext`/`Symbol` -- they do NOT call
# into the analysis core, so they are safe to import from `analyzer.nim` (which
# is why they live here rather than in the mutually-recursive core).  The actual
# recursive parse+analyze+import workhorse (`analyzeModule`) stays in
# `analyzer.nim` because it calls `analyzeBlock`/`finalize`/`bootstrap`.

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
  ## directory of the file doing the requiring".  Search order: `-L`/`--add-path`
  ## dirs (first match wins), then `--path` entries (last-wins; any `--path`
  ## replaces the default entirely), then the default templates (`./?.nelua`,
  ## `./?/init.nelua`, the system lib dir, and its `init.nelua`), then OUR
  ## extensions (project `lib/`, the requiring file's dir, cwd).  Returns ""
  ## when no candidate exists.
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
  for p in config.addPath:
    candidates.add p / segments.join("/") & ".nelua"
    candidates.add p / segments.join("/") / "init.nelua"
  for p in config.paths:
    candidates.add p / segments.join("/") & ".nelua"
  if config.paths.len == 0:
    candidates.add getCurrentDir() / segments.join("/") & ".nelua"
    candidates.add getCurrentDir() / segments.join("/") / "init.nelua"
    # OUR project `lib/` is this compiler's stdlib -- the mirror of the oracle's
    # own system-lib default.  It is the terminal default; we do NOT default to
    # the oracle's system lib (`LibPath`), which our compiler cannot compile.
    candidates.add getCurrentDir() / "lib" / segments.join("/") & ".nelua"
    candidates.add getCurrentDir() / "lib" / segments.join("/") / "init.nelua"
  let reqDir = requiringPath.splitFile().dir
  if reqDir.len > 0:
    candidates.add reqDir / segments.join("/") & ".nelua"
  candidates.add getCurrentDir() / segments.join("/") & ".nelua"
  for c in candidates:
    if fileExists(c):
      return c
  return ""

proc importSymbols*(ctx: var AnalyzerContext, depCtx: AnalyzerContext) =
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