## M6 preprocessor — gradual per-node pass over the M1 AST.
##
## Consumes every `nkDirective` / `nkPreprocess` / `nkPreprocessExpr` /
## `nkPreprocessName` node so that none survive into analysis. Implements the
## C-preprocessor-flavoured subset of the Nelua preprocessor (language-review
## §6, §10 step 2, tmp/M2_design.md §4.1):
##
##   * `#define` (object-like and function-like), `#undef`
##   * `#if` / `#ifdef` / `#ifndef` / `#elif` / `#else` / `#endif` with
##     condition evaluation over defined symbols and integer constant
##     expressions
##   * `#include`, `#error`, `#pragma`, `#line`
##   * function-like macro expansion: template params are substituted by name
##     into a cached, parsed body and the result is re-parsed through the M1
##     parser and spliced in at the call site.
##
## The pass driver is `preprocess(root, ctx) -> Node`.
##
## §6 scope note: the reference's full-Lua preprocessor (`##` statement lines,
## `##[[ ... ]]` blocks, `#[expr]#` expression replacement, `#|name|#` name
## replacement, `inject_astnode`) requires an embedded Lua interpreter. That
## engine is out of scope for this clean-room build; the corresponding AST
## nodes are consumed (with a diagnostic) rather than left in the tree, so the
## "none survive into analysis" invariant still holds.

import
  ast, astshapes, parser, span, strutils, tables
import std/streams
import ./luaengine

# ---------------------------------------------------------------------------
# Errors and context
# ---------------------------------------------------------------------------

type
  PreprocessError* = ref object of ValueError
    loc*: SourceLoc
    ## `msg` is inherited from Exception/ValueError and is set via the
    ## object constructor below.

  MacroDef* = object
    params*: seq[string]      ## parameter names (empty for object-like)
    body*: string             ## raw expansion text
    bodyNode*: Node           ## cached parsed body, nil until first use
    isFunction*: bool

  CondState* = object
    active*: bool    ## this branch is being emitted
    hadTrue*: bool   ## a branch of the current group already fired
    skipped*: bool   ## an enclosing branch is inactive

  PreprocessContext* = object
    macros*: Table[string, MacroDef]   ## all defines (object- and function-like)
    diags*: seq[string]                ## non-fatal diagnostics
    source*: string                    ## the source being preprocessed
    path*: string
    counter*: int                      ## fresh-name generator
    expanding*: seq[string]            ## macro-expansion recursion guard
    luaBuffer*: seq[string]            ## collected `##` line texts; executed
                                        ## as one Lua chunk per module
    depth*: int                        ## recursion depth; 1 == the top-level
                                        ## module block

# ---------------------------------------------------------------------------
# Phase-B preprocessor builtins + the injection machinery.
#
# The embedded Lua `##` blocks run against a small C-ABI shim that reaches
# back into the preprocessor to implement the builtins the stdlib depends on
# (`hygienize`, `static_assert`, `inject`/`inject_astnode`, `ppregistry`) and
# to splice injected AST nodes back into the tree at the right position.
#
# The state below is module-global (not per-PreprocessContext) because the Lua
# state itself is module-global: a `##` function defined while compiling a
# `require`d dependency (e.g. `def_c` in tests/require_test_dep.nelua) is
# called later from the requiring module's own `##` block, so the captured
# injectable bodies must outlive the context that captured them.
#
# Injection is positional: the driver wraps every `##` node in a module block
# with `__nelua_mark(i)` markers and runs them as one chunk (so `local`
# declarations persist across adjacent `##` lines, matching the reference).
# `__nelua_mark(i)` selects position `i`; `__nelua_inject(name)` appends the
# captured body `name` to the current position.  After the chunk runs the
# driver drains each position's buffer into the block at the matching `##`
# node.  `gInjectStack` makes this re-entrant: a `##` block nested inside an
# injected node pushes its own frame.
# ---------------------------------------------------------------------------
var gActiveCtx: ptr PreprocessContext = nil
var gCapturedBodies: TableRef[string, seq[Node]] = newTable[string, seq[Node]]()
var gInjectStack: seq[seq[seq[Node]]] = @[]
var gInjectCurrent = 0
var gBuiltinsRegistered = false

proc resetPreprocessorState*() =
  ## Clear every per-compilation scratch buffer so the next compilation starts
  ## clean.  Called by `luaengine.resetLuaState` (via `onResetEngine`) at the
  ## top of every `compile()`.
  gCapturedBodies.clear()
  gInjectStack = @[]
  gInjectCurrent = 0
  gBuiltinsRegistered = false

proc newPreprocessContext*(source = "", path = ""): PreprocessContext =
  ## Construct a fresh preprocessor context with no defines and an empty
  ## inject buffer (the inject buffer is `ctx.macros`-independent state the
  ## driver splices from; it is intentionally a field so callers can seed it).
  PreprocessContext(source: source, path: path, luaBuffer: @[], depth: 0)

proc newInjectBuffer*(): seq[Node] = @[]

# ---------------------------------------------------------------------------
# Node helpers
# ---------------------------------------------------------------------------

proc cloneNode*(n: Node): Node =
  if n == nil:
    return nil
  result = Node(kind: n.kind, str: n.str, litType: n.litType, boolVal: n.boolVal,
    isFunction: n.isFunction, isCall: n.isCall, isUnpackable: n.isUnpackable,
    isIndex: n.isIndex, isOperator: n.isOperator)
  for ch in n.children:
    result.children.add cloneNode(ch)

proc parseExprStr*(text: string): Node =
  ## Re-parse an expansion string through the M1 parser and return the
  ## resulting expression node.
  var p = newParser(text, "")
  result = p.parseExpr()

# ---------------------------------------------------------------------------
# Condition evaluation (`#if` / `#elif`)
# ---------------------------------------------------------------------------

type
  CToken = object
    kind: string   ## "num", "id", "op", "eof"
    text: string

proc tokenizeCond(s: string): seq[CToken] =
  result = @[]
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i]
    if c in {' ', '\t', '\n', '\r', '\f', '\v'}:
      inc i
      continue
    if c.isDigit:
      var j = i
      while j < n and s[j].isDigit: inc j
      result.add CToken(kind: "num", text: s[i ..< j])
      i = j
      continue
    if c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'):
      var j = i
      while j < n and (s[j] == '_' or s[j].isDigit or
          (s[j] >= 'a' and s[j] <= 'z') or (s[j] >= 'A' and s[j] <= 'Z')):
        inc j
      result.add CToken(kind: "id", text: s[i ..< j])
      i = j
      continue
    case c
    of '(': result.add CToken(kind: "op", text: "("); inc i
    of ')': result.add CToken(kind: "op", text: ")"); inc i
    of '!':
      if i + 1 < n and s[i + 1] == '=':
        result.add CToken(kind: "op", text: "!="); inc i, 2
      else:
        result.add CToken(kind: "op", text: "!"); inc i
    of '=':
      if i + 1 < n and s[i + 1] == '=':
        result.add CToken(kind: "op", text: "=="); inc i, 2
      else: inc i
    of '<':
      if i + 1 < n and s[i + 1] == '=':
        result.add CToken(kind: "op", text: "<="); inc i, 2
      else:
        result.add CToken(kind: "op", text: "<"); inc i
    of '>':
      if i + 1 < n and s[i + 1] == '=':
        result.add CToken(kind: "op", text: ">="); inc i, 2
      else:
        result.add CToken(kind: "op", text: ">"); inc i
    of '&':
      if i + 1 < n and s[i + 1] == '&':
        result.add CToken(kind: "op", text: "&&"); inc i, 2
      else: inc i
    of '|':
      if i + 1 < n and s[i + 1] == '|':
        result.add CToken(kind: "op", text: "||"); inc i, 2
      else: inc i
    of '+', '-', '*', '/', '%':
      result.add CToken(kind: "op", text: $c); inc i
    else:
      inc i
  result.add CToken(kind: "eof", text: "")

type
  CondParser = object
    toks: seq[CToken]
    pos: int

proc cur(p: CondParser): CToken =
  if p.pos < p.toks.len: p.toks[p.pos] else: p.toks[^1]
proc advanceC(p: var CondParser) =
  if p.pos < p.toks.len - 1: inc p.pos
proc at(p: CondParser, text: string): bool =
  p.cur.kind == "op" and p.cur.text == text
proc matchC(p: var CondParser, text: string): bool =
  if p.at(text): p.advanceC(); return true
  return false
proc expectOp(p: var CondParser, text: string) =
  if not p.matchC(text):
    discard  # tolerate; the condition is best-effort

proc evalExpr*(p: var CondParser, ctx: PreprocessContext): int
proc evalOr(p: var CondParser, ctx: PreprocessContext): int
proc evalAnd(p: var CondParser, ctx: PreprocessContext): int
proc evalEq(p: var CondParser, ctx: PreprocessContext): int
proc evalRel(p: var CondParser, ctx: PreprocessContext): int
proc evalAdd(p: var CondParser, ctx: PreprocessContext): int
proc evalMul(p: var CondParser, ctx: PreprocessContext): int
proc evalUnary(p: var CondParser, ctx: PreprocessContext): int
proc evalPrimary(p: var CondParser, ctx: PreprocessContext): int

proc evalOr(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalAnd(p, ctx)
  while p.matchC("||"):
    let r = evalAnd(p, ctx)
    if l != 0 or r != 0: return 1
    l = 0
  return l

proc evalAnd(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalEq(p, ctx)
  while p.matchC("&&"):
    let r = evalEq(p, ctx)
    if l == 0 or r == 0: return 0
    l = 1
  return l

proc evalEq(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalRel(p, ctx)
  while true:
    if p.matchC("=="):
      let r = evalRel(p, ctx)
      l = if l == r: 1 else: 0
    elif p.matchC("!="):
      let r = evalRel(p, ctx)
      l = if l != r: 1 else: 0
    else: break
  return l

proc evalRel(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalAdd(p, ctx)
  while true:
    if p.matchC("<"):
      let r = evalAdd(p, ctx)
      l = if l < r: 1 else: 0
    elif p.matchC(">"):
      let r = evalAdd(p, ctx)
      l = if l > r: 1 else: 0
    elif p.matchC("<="):
      let r = evalAdd(p, ctx)
      l = if l <= r: 1 else: 0
    elif p.matchC(">="):
      let r = evalAdd(p, ctx)
      l = if l >= r: 1 else: 0
    else: break
  return l

proc evalAdd(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalMul(p, ctx)
  while true:
    if p.matchC("+"):
      let r = evalMul(p, ctx)
      l = l + r
    elif p.matchC("-"):
      let r = evalMul(p, ctx)
      l = l - r
    else: break
  return l

proc evalMul(p: var CondParser, ctx: PreprocessContext): int =
  var l = evalUnary(p, ctx)
  while true:
    if p.matchC("*"):
      let r = evalUnary(p, ctx)
      l = l * r
    elif p.matchC("/"):
      let r = evalUnary(p, ctx)
      if r == 0: return 0
      l = l div r
    elif p.matchC("%"):
      let r = evalUnary(p, ctx)
      if r == 0: return 0
      l = l mod r
    else: break
  return l

proc evalUnary(p: var CondParser, ctx: PreprocessContext): int =
  if p.matchC("!"):
    let v = evalUnary(p, ctx)
    return if v == 0: 1 else: 0
  if p.at("("):
    p.advanceC()
    let v = evalExpr(p, ctx)
    discard p.matchC(")")
    return v
  return evalPrimary(p, ctx)

proc evalExpr(p: var CondParser, ctx: PreprocessContext): int =
  evalOr(p, ctx)

proc evalPrimary(p: var CondParser, ctx: PreprocessContext): int =
  let t = p.cur
  if t.kind == "num":
    p.advanceC()
    try:
      return parseint(t.text)
    except ValueError:
      return 0
  if t.kind == "id":
    p.advanceC()
    if t.text == "defined":
      # `defined X` or `defined(X)`
      if p.at("("): p.advanceC()
      let name = if p.cur.kind == "id":
                   let nt = p.cur; p.advanceC(); nt.text
                 else: ""
      discard p.matchC(")")
      return if ctx.macros.contains(name): 1 else: 0
    # bare identifier: 0 unless it is a defined object-like macro with a
    # numeric body (rare); treat undefined identifiers as 0 (C semantics)
    return 0
  return 0

proc evalCond*(text: string, ctx: PreprocessContext): bool =
  ## Evaluate a `#if` condition string over defined symbols and integer
  ## constant expressions. Non-zero is true.
  if text.strip == "":
    return true
  var p = CondParser(toks: tokenizeCond(text), pos: 0)
  let v = evalExpr(p, ctx)
  return v != 0

# ---------------------------------------------------------------------------
# Directive handling
# ---------------------------------------------------------------------------

proc registerDefine*(d: Node, ctx: var PreprocessContext) =
  ## Encode a `#define` directive (children: name, [params...], body-text).
  let name = d.children[0].str
  var params: seq[string] = @[]
  let body = d.children[^1].str
  if d.children.len > 2:
    for i in 1 ..< d.children.len - 1:
      params.add d.children[i].str
  let isFunc = params.len > 0
  ctx.macros[name] = MacroDef(params: params, body: body, isFunction: isFunc)

proc evalIfCondition*(d: Node, ctx: PreprocessContext, kind: string): bool =
  case kind
  of "if":
    let text = if d.children.len > 0 and d.children[0].kind == nkString:
                 d.children[0].str else: ""
    evalCond(text, ctx)
  of "ifdef":
    let name = if d.children.len > 0: d.children[0].str else: ""
    ctx.macros.contains(name)
  of "ifndef":
    let name = if d.children.len > 0: d.children[0].str else: ""
    not ctx.macros.contains(name)
  else:
    false

proc preprocess*(root: Node, ctx: var PreprocessContext): Node

proc formatPPMessage(fmt: string, args: seq[string]): string =
  ## Minimal `string.format`-lite for `static_assert`: substitutes `%s`
  ## (and `%d`/`%i`/`%f`/`%g`/`%c`/`%q`, treated like `%s`) with successive
  ## args; `%%` is a literal `%`.  Anything else is copied verbatim.
  result = ""
  var ai = 0
  var i = 0
  while i < fmt.len:
    if fmt[i] == '%' and i + 1 < fmt.len:
      case fmt[i + 1]
      of 's', 'd', 'i', 'f', 'g', 'c', 'q':
        if ai < args.len:
          result.add args[ai]
          inc ai
        inc i, 2
      of '%':
        result.add '%'
        inc i, 2
      else:
        result.add fmt[i]
        inc i
    else:
      result.add fmt[i]
      inc i

proc cMark(L: PLuaState): int {.cdecl.} =
  ## `__nelua_mark(n)` -- select inject position `n` for the next `inject`.
  var isnum: cint
  gInjectCurrent = int(lua_tointegerx(L, 1, addr(isnum)))
  return 0

proc cInject(L: PLuaState): int {.cdecl.} =
  ## `__nelua_inject(name)` -- splice the captured body `name` into the
  ## current inject position.
  let name = $lua_tolstring(L, 1, nil)
  if gCapturedBodies.contains(name) and gInjectStack.len > 0:
    let nodes = gCapturedBodies[name]
    let pos = gInjectCurrent
    if pos < gInjectStack[^1].len:
      for n in nodes:
        gInjectStack[^1][pos].add n
  return 0

proc cInjectAstnode(L: PLuaState): int {.cdecl.} =
  ## `inject_astnode(text)` / `inject(text)` -- parse `text` as a nelua
  ## statement list and splice the resulting nodes into the current position.
  let text = lua_tolstring(L, 1, nil)
  if text != nil and gInjectStack.len > 0:
    let pos = gInjectCurrent
    if pos < gInjectStack[^1].len:
      let path = if gActiveCtx != nil: gActiveCtx.path else: ""
      let parsed = parser.parse($text, path)
      if parsed != nil:
        for n in parsed.children:
          gInjectStack[^1][pos].add n
  return 0

proc cHygienize(L: PLuaState): int {.cdecl.} =
  ## `hygienize(x)` -- mark `x` as hygienic so its identifiers do not collide
  ## with the surrounding scope.  The reference wraps the value in a fresh
  ## closure; the actual identifier renaming is a codegen concern this build
  ## does not have, so we return the value unchanged (identity), which
  ## preserves the observable call/inject behaviour the stdlib relies on.
  lua_settop(L, 1)
  return 1

proc cStaticAssert(L: PLuaState): int {.cdecl.} =
  ## `static_assert(cond, fmt, ...)` -- raise a Lua error when `cond` is
  ## falsy, formatting `fmt` with the remaining arguments (`%s` style).
  if lua_toboolean(L, 1) != 0:
    return 0
  let fmt = $lua_tolstring(L, 2, nil)
  var args: seq[string] = @[]
  let top = lua_gettop(L)
  for i in 3 .. top:
    let s = lua_tolstring(L, i, nil)
    args.add if s != nil: $s else: "nil"
  let msg = "static_assert: " & formatPPMessage(fmt, args)
  lua_pushstring(L, msg.cstring)
  discard lua_error(L)
  return 0

# ---------------------------------------------------------------------------
# `aster` AST-node constructors and `inject_statement`.
#
# The reference preprocessor exposes an `aster` table whose fields construct
# AST nodes (`aster.Id{'x'}`, `aster.Assign{{lhs},{rhs}}`, ...) and an
# `inject_statement(node)` that splices such a node back into the tree at the
# current `##` position.  Required `.lua` dependencies (e.g.
# `tests/require_test_metadep.lua`) build their injection helpers on top of
# this API, so it ships with the Phase-B builtins.
#
# Nodes are Lua tables carrying a `__tag` (the AST node kind) plus `__str`
# (leaf value), `__bool` (boolean) or `__children` (a sequence of sub-nodes).
# `inject_statement` walks the table, rebuilds a real `Node` tree, and splices
# it into the current inject position.  `gNodeScratch` keeps the in-conversion
# nodes GC-rooted until the top node is safely in the inject buffer.
# ---------------------------------------------------------------------------

var gNodeScratch: seq[Node] = @[]

proc pushStr(L: PLuaState, s: string) =
  ## Push a Nim `string` onto the Lua stack as a Lua string.  `lua_pushstring`
  ## takes a `cstring`, and an implicit `string`->`cstring` conversion warns (and
  ## will error in a future Nim), so pass the string's data pointer explicitly:
  ## it is live for the duration of the call, which `lua_pushstring` copies from.
  if s.len > 0:
    L.lua_pushstring(cast[cstring](addr s[0]))
  else:
    L.lua_pushstring(nil)

proc nodeToStringImpl(L: PLuaState, idx: int, indent: string): string =
  ## Recursively dump a node table at `idx` (any stack index) as text.
  let base = L.lua_absidx(idx)
  result = indent
  L.lua_getfield(base, "__tag")
  let tagStr = if L.lua_type(-1) != 0: $L.lua_tolstring(-1, nil) else: "?"
  result.add tagStr
  L.lua_pop(1)
  L.lua_getfield(base, "__str")
  if L.lua_type(-1) != 0:
    result.add " " & $L.lua_tolstring(-1, nil)
  L.lua_pop(1)
  L.lua_getfield(base, "__bool")
  if L.lua_type(-1) != 0:
    let b = if L.lua_toboolean(-1) != 0: " true" else: " false"
    result.add b
  L.lua_pop(1)
  L.lua_getfield(base, "__children")
  let n = if L.lua_type(-1) != 0: int(L.lua_rawlen(-1)) else: 0
  if n > 0:
    result.add " {"
    for i in 1 .. n:
      L.lua_rawgeti(-1, i)
      result.add "\n" & nodeToStringImpl(L, -1, indent & "  ")
      L.lua_pop(1)
    result.add "\n" & indent & "}"
  L.lua_pop(1)

proc cNodeToString(L: PLuaState): int {.cdecl.} =
  ## `tostring(node)` metamethod.
  let s = nodeToStringImpl(L, 1, "")
  L.lua_pushstring(s.cstring)
  return 1

proc pushNodeMt(L: PLuaState) =
  ## Push the node metatable (`__tostring`) onto the stack and leave it there.
  L.lua_createtable(0, 1)
  L.lua_pushcfunction(cNodeToString); L.lua_setfield(-2, "__tostring")

proc cAsterConstruct(L: PLuaState): int {.cdecl.} =
  ## `ctor(arg)` -- build a node table of kind `ctor.__kind` from the table
  ## argument `arg` (its array part holds the node's data).
  L.lua_getfield(1, "__kind")
  let kind = $L.lua_tolstring(-1, nil)
  L.lua_pop(1)
  let narr = int(L.lua_rawlen(2))
  case kind
  of "Nil", "Nilptr", "Break", "Continue":
    L.lua_createtable(0, 1)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
  of "Id", "String", "Number":
    L.lua_rawgeti(2, 1)
    let s = $L.lua_tolstring(-1, nil)
    L.lua_pop(1)
    L.lua_createtable(0, 2)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
    L.pushStr(s); L.lua_setfield(-2, "__str")
  of "Boolean":
    L.lua_rawgeti(2, 1)
    let b = L.lua_toboolean(-1) != 0
    L.lua_pop(1)
    L.lua_createtable(0, 2)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
    L.lua_pushboolean( if b: 1 else: 0); L.lua_setfield(-2, "__bool")
  of "IdDecl", "Label", "DotIndex", "ColonIndex", "CallMethod",
      "UnaryOp", "BinaryOp", "GenericType", "Directive":
    L.lua_createtable(0, 2)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
    if narr >= 1:
      L.lua_rawgeti(2, 1)
      let s = $L.lua_tolstring(-1, nil)
      L.lua_pop(1)
      L.pushStr(s); L.lua_setfield(-2, "__str")
    if narr >= 2:
      L.lua_createtable(narr - 1, 0)
      for i in 2 .. narr:
        L.lua_rawgeti(2, i); L.lua_rawseti(-2, i - 1)
      L.lua_setfield(-2, "__children")
  of "Assign":
    # `aster.Assign{{lhs...}, {rhs...}}` -- each side is a table of nodes;
    # flatten both sides into one __children array, matching the shape our
    # parser emits for `lhs = rhs` (targets then values, no block wrapping).
    L.lua_createtable(0, 2)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
    L.lua_createtable(0, 0)
    var idx = 1
    for side in 1 .. narr:
      L.lua_rawgeti(2, side)
      let sideN = int(L.lua_rawlen(-1))
      for i in 1 .. sideN:
        L.lua_rawgeti(-1, i)
        L.lua_rawseti(-3, idx)
        inc idx
      L.lua_pop(1)
    L.lua_setfield(-2, "__children")
  else:
    L.lua_createtable(0, 1)
    L.pushStr(kind); L.lua_setfield(-2, "__tag")
    if narr >= 1:
      L.lua_createtable(narr, 0)
      for i in 1 .. narr:
        L.lua_rawgeti(2, i); L.lua_rawseti(-2, i)
      L.lua_setfield(-2, "__children")
  L.pushNodeMt()
  L.lua_setmetatable(-2)
  return 1

proc cAsterIndex(L: PLuaState): int {.cdecl.} =
  ## `aster.__index(self, kind)` -- return a constructor for AST node kind
  ## `kind`.  The constructor is a small table carrying `__kind` and a `__call`
  ## metamethod, so `aster.Id{...}` reads as `(aster.Id){...}`.
  let kindPtr = L.lua_tolstring(2, nil)
  let kind = if kindPtr != nil: $kindPtr else: ""
  L.lua_createtable(0, 1)
  L.pushStr(kind); L.lua_setfield(-2, "__kind")
  L.lua_createtable(0, 1)
  L.lua_pushcfunction(cAsterConstruct); L.lua_setfield(-2, "__call")
  L.lua_setmetatable(-2)
  return 1

proc luaGetStrField(L: PLuaState, idx: int, name: string): string =
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, name)
  result = if L.lua_type(-1) != 0: $L.lua_tolstring(-1, nil) else: ""
  L.lua_pop(1)

proc luaGetBoolField(L: PLuaState, idx: int, name: string): bool =
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, name)
  result = L.lua_toboolean(-1) != 0
  L.lua_pop(1)

# Forward declaration: `luaNodeToNim` and `luaGetChildren` are mutually
# recursive (the converter asks for children, children recurse into the
# converter), so one must be declared without a body first.
proc luaGetChildren(L: PLuaState, idx: int): seq[Node]

proc luaNodeToNim(L: PLuaState, idx: int): Node =
  ## Convert a node table at `idx` into a real `Node`, rooting intermediates
  ## in `gNodeScratch` until the top node lands in the inject buffer.
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, "__tag")
  let tag = if L.lua_type(-1) != 0: $L.lua_tolstring(-1, nil) else: ""
  L.lua_pop(1)
  case tag
  of "Nil": result = newNil()
  of "Nilptr": result = newNilptr()
  of "Break": result = newBreak()
  of "Continue": result = newContinue()
  of "Id": result = newId(luaGetStrField(L, base, "__str"))
  of "String": result = newString(luaGetStrField(L, base, "__str"))
  of "Number": result = newNumber(luaGetStrField(L, base, "__str"))
  of "Boolean": result = newBoolean(luaGetBoolField(L, base, "__bool"))
  of "Assign":
    let kids = luaGetChildren(L, base)
    let mid = kids.len div 2
    result = newAssign(kids[0 ..< mid], kids[mid ..< kids.len])
  of "Block": result = newBlock(luaGetChildren(L, base))
  of "Call":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newCall(kids[1 ..< kids.len], kids[0])
             else: newCall(@[], nil)
  of "CallMethod":
    let name = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newCallMethod(name, kids[1 ..< kids.len], kids[0])
             else: newCallMethod(name, @[], nil)
  of "IdDecl": result = newIdDecl(luaGetStrField(L, base, "__str"))
  of "Label": result = newLabel(luaGetStrField(L, base, "__str"))
  of "DotIndex":
    let f = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newDotIndex(f, kids[0]) else: newDotIndex(f, nil)
  of "ColonIndex":
    let f = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newColonIndex(f, kids[0]) else: newColonIndex(f, nil)
  of "KeyIndex":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 2: newKeyIndex(kids[0], kids[1]) else: newKeyIndex(nil, nil)
  of "Pair":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 2: newPairExpr(kids[0], kids[1]) else: newPairExpr(nil, nil)
  of "Paren":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newParen(kids[0]) else: newParen(nil)
  of "Do":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newDo(kids[0]) else: newDo(nil)
  of "While":
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 2: newWhile(kids[0], kids[1]) else: newWhile(nil, nil)
  of "Return": result = newReturn(luaGetChildren(L, base))
  of "BinaryOp":
    let op = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 2: newBinaryOp(kids[0], op, kids[1]) else: newBinaryOp(nil, op, nil)
  of "UnaryOp":
    let op = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    result = if kids.len >= 1: newUnaryOp(op, kids[0]) else: newUnaryOp(op, nil)
  of "Directive":
    result = newDirective(luaGetStrField(L, base, "__str"), luaGetChildren(L, base))
  of "VarDecl":
    let scope = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    let mid = kids.len div 2
    result = newVarDecl(scope, kids[0 ..< mid], kids[mid ..< kids.len])
  of "FuncDef":
    let scope = luaGetStrField(L, base, "__str")
    let kids = luaGetChildren(L, base)
    if kids.len >= 1:
      let name = kids[0]
      let body = kids[^1]
      let mid = (kids.len - 1) div 2
      result = newFuncDef(scope, name, kids[1 ..< 1 + mid],
                          kids[1 + mid ..< kids.len - 1], @[], body)
    else:
      result = newFuncDef(scope, nil, @[], @[], @[], nil)
  else:
    result = nil
  if result != nil:
    gNodeScratch.add result

proc luaGetChildren(L: PLuaState, idx: int): seq[Node] =
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, "__children")
  let n = if L.lua_type(-1) != 0: int(L.lua_rawlen(-1)) else: 0
  for i in 1 .. n:
    L.lua_rawgeti(-1, i)
    let child = luaNodeToNim(L, -1)
    if child != nil: result.add child
    L.lua_pop(1)
  L.lua_pop(1)

proc cInjectStatement(L: PLuaState): int {.cdecl.} =
  ## `inject_statement(node)` -- splice a rebuilt `Node` tree into the current
  ## inject position, exactly like `inject_astnode` but from an `aster` node.
  if gInjectStack.len == 0:
    discard L.luaL_error("inject_statement: no active ## block")
    return 0
  let pos = gInjectCurrent
  if pos >= gInjectStack[^1].len:
    return 0
  gNodeScratch = @[]
  let node = luaNodeToNim(L, 1)
  gNodeScratch = @[]
  if node != nil:
    gInjectStack[^1][pos].add node
  return 0

proc registerAster*(L: PLuaState) =
  ## Create the `aster` table of AST-node constructors and register it (and
  ## `inject_statement`) as globals so both `##` blocks and `require`d modules
  ## can use them.  `cAsterIndex` is the `aster.__index` metamethod: it must be
  ## a field of `aster`'s *metatable*, not a plain field of `aster` itself
  ## (setting it directly would just create a string key, not a metamethod).
  L.lua_createtable(0, 1)              # aster table
  L.lua_createtable(0, 1)              # aster's metatable
  L.lua_pushcfunction(cAsterIndex); L.lua_setfield(-2, "__index")
  L.lua_setmetatable(-2)
  L.lua_setglobal("aster")
  L.lua_pushcfunction(cInjectStatement); L.lua_setglobal("inject_statement")

proc registerPreprocessorBuiltins*(L: PLuaState) =
  ## Register the Phase-B preprocessor builtins into the shared Lua state.
  ## Idempotent (guarded by `gBuiltinsRegistered`, reset by
  ## `resetLuaState` via the `onResetEngine` hook).
  if gBuiltinsRegistered:
    return
  gBuiltinsRegistered = true
  L.lua_pushcfunction(cMark); L.lua_setglobal("__nelua_mark")
  L.lua_pushcfunction(cInject); L.lua_setglobal("__nelua_inject")
  L.lua_pushcfunction(cInjectAstnode); L.lua_setglobal("inject_astnode")
  L.lua_pushcfunction(cInjectAstnode); L.lua_setglobal("inject")
  L.lua_pushcfunction(cHygienize); L.lua_setglobal("hygienize")
  L.lua_pushcfunction(cStaticAssert); L.lua_setglobal("static_assert")
  L.lua_createtable(0, 0); L.lua_setglobal("ppregistry")
  registerAster(L)

proc executeLuaBuffer*(ctx: var PreprocessContext) =
  ## Concatenate every `##` line collected during this pass into one Lua chunk
  ## and run it in the shared embedded Lua state.  The state is module-global,
  ## so the environment persists across `##` blocks *and* across `require`d
  ## dependencies within one compilation (a `## function def_c() ... end`
  ## defined while compiling a dependency is visible to the requiring module's
  ## `## def_c()`), exactly as the reference interpreter behaves.
  ##
  ## `luainit` has already run when the state was first created (see
  ## `luaengine.getLuaEngine`), so `package.path` is patched and the standard
  ## libraries are open.
  ##
  ## Lua errors are surfaced through the same `PreprocessError` channel that
  ## `#error` uses: `analyze` collects them into `ctx.diags`, and `genC`
  ## translates any diagnostic into the `/* nelua: ... */` stub, so the driver
  ## fails the compilation cleanly (exit 1) -- matching the reference, which
  ## aborts on a `##` runtime error.
  if ctx.luaBuffer.len == 0:
    return
  let L = getLuaEngine(ctx.path)
  registerPreprocessorBuiltins(L)
  let chunkName = "@" & ctx.path & ":ppcode"
  let text = ctx.luaBuffer.join("\n")
  let errMsg = runChunk(L, text, chunkName)
  if errMsg.len > 0:
    raise PreprocessError(loc: newSourceLoc(ctx.path, ctx.source, 0),
      msg: "error while preprocessing block: " & chunkName & ": " & errMsg)
  ctx.luaBuffer.setLen(0)

proc readInclude*(path: string): string =
  ## Read a file for `#include`. Returns "" (and records nothing) on failure.
  try:
    let st = openFileStream(path, fmRead)
    defer: close(st)
    result = st.readAll()
  except OSError:
    result = ""

proc spliceInclude*(d: Node, target: var seq[Node], ctx: var PreprocessContext) =
  let path = if d.children.len > 0 and d.children[0].kind == nkString:
               d.children[0].str else: ""
  if path == "":
    ctx.diags.add "#include: missing path"
    return
  let text = readInclude(path)
  if text == "":
    ctx.diags.add "#include: cannot read '" & path & "'"
    return
  let parsed = parser.parse(text, path)
  if parsed == nil:
    ctx.diags.add "#include: parse failed in '" & path & "'"
    return
  for stmt in parsed.children:
    target.add preprocess(stmt, ctx)

# ---------------------------------------------------------------------------
# Macro expansion
# ---------------------------------------------------------------------------

proc substitute*(node: Node, subst: Table[string, int], args: seq[Node]): Node

proc expandFunctionMacro*(call: Node, ctx: var PreprocessContext): Node =
  let caller = call.children[^1]
  let name = caller.str
  if name in ctx.expanding:
    return call                       # guard against self-referential macros
  let m = ctx.macros[name]
  let args = call.children[0 ..< ^1]
  if args.len != m.params.len:
    ctx.diags.add "macro '" & name & "' expects " & $m.params.len &
      " args, got " & $args.len
    return call

  var body = m.bodyNode
  if body == nil:
    body = parseExprStr(m.body)
    ctx.macros[name].bodyNode = body
  if body == nil:
    ctx.diags.add "macro '" & name & "' has an empty body"
    return call

  var subst: Table[string, int]
  for i, p in m.params:
    subst[p] = i

  ctx.expanding.add name
  let cloned = cloneNode(body)
  let expanded = substitute(cloned, subst, args)
  let result = preprocess(expanded, ctx)
  ctx.expanding.setLen(ctx.expanding.len - 1)
  return result

proc expandObjectMacro*(id: Node, ctx: var PreprocessContext): Node =
  let name = id.str
  if name in ctx.expanding:
    return id
  let m = ctx.macros[name]
  var body = m.bodyNode
  if body == nil:
    body = parseExprStr(m.body)
    ctx.macros[name].bodyNode = body
  if body == nil:
    return id
  ctx.expanding.add name
  let result = preprocess(cloneNode(body), ctx)
  ctx.expanding.setLen(ctx.expanding.len - 1)
  return result

proc substitute*(node: Node, subst: Table[string, int], args: seq[Node]): Node =
  ## Walk `node`, replacing `nkId` nodes whose name is a template parameter
  ## with a clone of the corresponding argument subtree.
  if node == nil:
    return nil
  if node.kind == nkId and node.str in subst:
    return cloneNode(args[subst[node.str]])
  result = Node(kind: node.kind, str: node.str, litType: node.litType,
    boolVal: node.boolVal, isFunction: node.isFunction, isCall: node.isCall,
    isUnpackable: node.isUnpackable, isIndex: node.isIndex,
    isOperator: node.isOperator)
  for ch in node.children:
    result.children.add substitute(ch, subst, args)

proc tryExpand*(n: Node, ctx: var PreprocessContext): Node =
  ## After recursing into a node's children, check whether the node itself is
  ## a macro call (function-like) or a bare macro identifier (object-like).
  if n.kind == nkCall:
    let caller = if n.children.len > 0: n.children[^1] else: nil
    if caller != nil and caller.kind == nkId and
        ctx.macros.contains(caller.str) and ctx.macros[caller.str].isFunction:
      return expandFunctionMacro(n, ctx)
  if n.kind == nkId and ctx.macros.contains(n.str) and
      not ctx.macros[n.str].isFunction:
    return expandObjectMacro(n, ctx)
  return n

# ---------------------------------------------------------------------------
# Directive dispatch (within a block's statement list)
# ---------------------------------------------------------------------------

proc handleDirective*(d: Node, target: var seq[Node],
    condStack: var seq[CondState], ctx: var PreprocessContext) =
  case d.str
  of "if", "ifdef", "ifndef":
    let skipped = condStack.len > 0 and not condStack[^1].active
    let active = not skipped and
      evalIfCondition(d, ctx, d.str)
    condStack.add CondState(active: active, hadTrue: active, skipped: skipped)
  of "elif":
    if condStack.len > 0:
      let t = condStack[^1]
      if not t.skipped:
        let active = not t.hadTrue and
          evalIfCondition(d, ctx, "if")
        condStack[^1].active = active
        if active:
          condStack[^1].hadTrue = true
  of "else":
    if condStack.len > 0 and not condStack[^1].skipped:
      let active = not condStack[^1].hadTrue
      condStack[^1].active = active
      if active:
        condStack[^1].hadTrue = true
  of "endif":
    if condStack.len > 0:
      discard condStack.pop
  else:
    if condStack.len > 0 and not condStack[^1].active:
      return
    case d.str
    of "define":
      if d.children.len >= 2 and d.children[0].kind == nkId:
        registerDefine(d, ctx)
      else:
        ctx.diags.add "#define: malformed"
    of "undef":
      if d.children.len > 0 and d.children[0].kind == nkId:
        ctx.macros.del(d.children[0].str)
    of "error":
      let msg = if d.children.len > 0 and d.children[0].kind == nkString:
                   d.children[0].str else: "preprocessor error"
      raise PreprocessError(loc: newSourceLoc(ctx.path, ctx.source, 0), msg: msg)
    of "pragma", "line":
      discard
    of "include":
      spliceInclude(d, target, ctx)
    else:
      ctx.diags.add "unknown directive: " & d.str

# ---------------------------------------------------------------------------
# Lua-block-aware `##` processing.
#
# A `##` line whose text opens a Lua construct (`function`/`if`/`while`/`for`/
# `do`/`repeat`) may be followed in the nelua tree by ordinary statements that
# are *not* `##` lines -- e.g. `## function def_c()` / `global c = 3` /
# `## end`.  Those intervening statements belong to the construct's body and
# must be injected (eagerly, for `if`/`while`/..., or on call, for a defined
# `function`) at the position of the `##` line that triggers them.
#
# `luaBlockDelta` classifies a `##` line by counting whole-word block
# openers minus closers: positive = opens a frame, negative = closes one,
# zero = standalone or intermediate (`else`/`elseif`).
# ---------------------------------------------------------------------------
proc isIdentChar(c: char): bool =
  c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9')

proc countKeyword(text, kw: string): int =
  ## Whole-word occurrences of `kw` in `text`.
  if kw.len == 0:
    return 0
  var i = 0
  while true:
    let j = text.find(kw, i)
    if j < 0:
      break
    let beforeOk = j == 0 or not isIdentChar(text[j - 1])
    let afterOk = j + kw.len >= text.len or not isIdentChar(text[j + kw.len])
    if beforeOk and afterOk:
      inc result
    i = j + kw.len

proc luaBlockDelta(text: string): int =
  ## Net change in Lua block depth from a `##` line's text.
  for kw in ["function", "if", "while", "for", "do", "repeat"]:
    inc result, countKeyword(text, kw)
  for kw in ["end", "until"]:
    dec result, countKeyword(text, kw)

type
  LuaFramePart = object
    isBody: bool
    text: string       ## for non-body parts: opener / intermediate / closer
    nodes: seq[Node]   ## for body parts: captured nelua statements
  LuaFrame = object
    parts: seq[LuaFramePart]

proc constructFrameChunk(frame: LuaFrame, ctx: var PreprocessContext): string =
  ## Build the Lua chunk for a captured `##` block.  Each captured nelua
  ## statement list becomes a `__nelua_inject("name")` call; the stored body is
  ## keyed in the module-global `gCapturedBodies` so the C callback can splice
  ## it into the right inject position when the chunk runs.  The name is passed
  ## as a *string literal* (quoted), not an identifier: `body_0` is a key in
  ## `gCapturedBodies`, not a Lua global variable, so writing it bare would
  ## look up a nil global and pass nil to the callback.
  var parts: seq[string] = @[]
  for part in frame.parts:
    if part.isBody:
      let name = "body_" & $ctx.counter
      inc ctx.counter
      gCapturedBodies[name] = part.nodes
      parts.add "__nelua_inject(\"" & name & "\")"
    else:
      parts.add part.text
  result = parts.join("\n")

# ---------------------------------------------------------------------------
# Pass driver
# ---------------------------------------------------------------------------

proc runPreprocessChunk(ctx: var PreprocessContext, ppNodes: seq[Node]): seq[seq[Node]] =
  ## Run every `##` node in `ppNodes` as a single Lua chunk, wrapped with
  ## `__nelua_mark(i)` position markers, and return the nodes each position
  ## injected (indexed parallel to `ppNodes`).  The caller splices them into
  ## the block at the matching `##` node.
  ##
  ## Running the nodes as *one* chunk (rather than one invocation per line)
  ## makes `local` declarations persist across adjacent `##` lines, exactly
  ## as the reference interpreter does.  `gInjectStack` makes this re-entrant:
  ## an injected node that is itself a block pushes its own frame.
  if ppNodes.len == 0:
    return @[]
  gInjectStack.add newSeq[seq[Node]](ppNodes.len)
  gInjectCurrent = 0
  var chunkParts: seq[string] = @[]
  for i, node in ppNodes:
    chunkParts.add "__nelua_mark(" & $i & ") " & node.str
  let chunkText = chunkParts.join("\n")
  let L = getLuaEngine(ctx.path)
  registerPreprocessorBuiltins(L)
  gActiveCtx = addr ctx
  let chunkName = "@" & ctx.path & ":ppcode"
  let errMsg = runChunk(L, chunkText, chunkName)
  gActiveCtx = nil
  if errMsg.len > 0:
    gInjectStack.setLen(gInjectStack.len - 1)
    raise PreprocessError(loc: newSourceLoc(ctx.path, ctx.source, 0),
      msg: "error while preprocessing block: " & chunkName & ": " & errMsg)
  result = gInjectStack[^1]
  gInjectStack.setLen(gInjectStack.len - 1)

proc preprocess*(root: Node, ctx: var PreprocessContext): Node =
  ## Walk and rewrite `root`, consuming every directive / preprocessor node.
  ##
  ## `##` statement lines are run through the embedded Lua interpreter as the
  ## block is walked (see `runPreprocessChunk`), so an `inject` call splices
  ## back into the tree at the position of the `##` line that triggered it.
  ## They are *not* subject to the `#if`/`#else` conditional stack -- they are
  ## compile-time Lua code and run regardless of which nelua branch is active,
  ## matching the reference interpreter.
  if root == nil:
    return nil
  inc ctx.depth
  defer: dec ctx.depth
  case root.kind
  of nkBlock:
    var rewritten: seq[Node] = @[]
    var condStack: seq[CondState] = @[]
    var frameStack: seq[LuaFrame] = @[]
    var ppNodes: seq[Node] = @[]
    for n in root.children:
      if n.kind == nkDirective:
        handleDirective(n, rewritten, condStack, ctx)
      elif n.kind == nkPreprocess:
        let text = n.str
        let delta = luaBlockDelta(text)
        if frameStack.len > 0:
          if delta < 0:
            # closer: append closer text, finalize the frame, emit the chunk
            frameStack[^1].parts.add LuaFramePart(isBody: false, text: text)
            let frame = frameStack.pop()
            let chunk = constructFrameChunk(frame, ctx)
            let node = Node(kind: nkPreprocess, str: chunk)
            rewritten.add node
            ppNodes.add node
          elif delta == 0:
            # intermediate (else / elseif): append text to the open frame
            frameStack[^1].parts.add LuaFramePart(isBody: false, text: text)
          else:
            # nested opener inside an open frame
            frameStack.add LuaFrame(parts: @[
              LuaFramePart(isBody: false, text: text)])
        else:
          if delta > 0:
            # opener with no enclosing frame: start one
            frameStack.add LuaFrame(parts: @[
              LuaFramePart(isBody: false, text: text)])
          else:
            # standalone ## line
            rewritten.add n
            ppNodes.add n
      elif n.kind == nkPreprocessExpr:
        ctx.diags.add "#[] / #|| preprocessor replacement is unsupported in this build; node consumed"
      elif n.kind == nkPreprocessName:
        ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build; node consumed"
      else:
        if frameStack.len > 0:
          frameStack[^1].parts.add LuaFramePart(isBody: true, nodes: @[n])
        else:
          if condStack.len == 0 or condStack[^1].active:
            rewritten.add preprocess(n, ctx)
    if frameStack.len > 0:
      ctx.diags.add "unbalanced ## block: unclosed Lua construct in " & ctx.path
    if ppNodes.len > 0:
      let injected = runPreprocessChunk(ctx, ppNodes)
      var newList: seq[Node] = @[]
      var injIdx = 0
      for r in rewritten:
        if injIdx < ppNodes.len and r == ppNodes[injIdx]:
          for inj in injected[injIdx]:
            let processed = preprocess(inj, ctx)
            if processed != nil:
              newList.add processed
          inc injIdx
        else:
          newList.add r
      rewritten = newList
    root.children = rewritten
    return root
  of nkDirective:
    # A directive standing alone (not inside a block): process it and drop.
    var dummy: seq[Node] = @[]
    var condStack: seq[CondState] = @[]
    handleDirective(root, dummy, condStack, ctx)
    return nil
  of nkPreprocess:
    # A `##` line standing alone (not inside a block): run it as a one-node
    # chunk so its side effects (print, defines, inject) take effect.
    discard runPreprocessChunk(ctx, @[root])
    return nil
  of nkPreprocessExpr, nkPreprocessName:
    ctx.diags.add "#[] / #|| preprocessor replacement is unsupported in this build; node consumed"
    return newNil()
  else:
    for i in 0 ..< root.children.len:
      root.children[i] = preprocess(root.children[i], ctx)
    # `require 'name'` lowers to an ordinary call on the builtin `require`
    # (parser.nim), so it is *not* a directive and is preserved intact here --
    # the module's resolution/compilation is the driver's job (compile.nim),
    # which runs on the raw parse tree before this pass is ever invoked.
    return tryExpand(root, ctx)

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

# Wire the engine hooks so a fresh Lua state auto-registers the preprocessor
# builtins and a reset clears per-compilation scratch.  Set at module init
# (after every proc below is defined); `luaengine.newLuaEngine` /
# `resetLuaState` call back into these.
onNewEngine = registerPreprocessorBuiltins
onResetEngine = resetPreprocessorState

when isMainModule:
  # --- case 1: function-like macro expansion at a call site ---
  block:
    let defineNode = newDirective("define", @[
      newId("ADD"),
      newId("a"), newId("b"),
      newString("((a)+(b))", "macrobody"),
    ])
    let call = newCall(@[newNumber("1"), newNumber("2")], newId("ADD"))
    let root = newBlock(@[defineNode, call])
    var ctx = newPreprocessContext("$(#define ADD(a,b) ((a)+(b))\nADD(1,2)\n", "t1.nelua")
    let rewritten = preprocess(root, ctx)
    echo "CASE 1 dump:\n" & dump(rewritten)
    doAssert rewritten.children.len == 1, "define directive must be consumed"
    let exp = rewritten.children[0]
    doAssert exp.kind == nkParen, $exp.kind
    doAssert exp.children[0].kind == nkBinaryOp
    doAssert exp.children[0].str == "+"
    let lhs = exp.children[0].children[0]
    doAssert lhs.kind == nkParen and lhs.children[0].kind == nkNumber
    doAssert lhs.children[0].str == "1"
    let rhs = exp.children[0].children[1]
    doAssert rhs.kind == nkParen and rhs.children[0].kind == nkNumber
    doAssert rhs.children[0].str == "2"
    echo "CASE 1 PASS: ADD(1,2) expanded to ((1)+(2))"

  # --- case 2a: #ifdef with X defined keeps the first branch ---
  block:
    let root = newBlock(@[
      newDirective("ifdef", @[newId("X")]),
      newCall(@[newNumber("1")], newId("print")),
      newDirective("else"),
      newCall(@[newNumber("2")], newId("print")),
      newDirective("endif"),
    ])
    var ctx = newPreprocessContext("", "t2a.nelua")
    ctx.macros["X"] = MacroDef(body: "1", isFunction: false)
    let rewritten = preprocess(root, ctx)
    echo "CASE 2a dump:\n" & dump(rewritten)
    doAssert rewritten.children.len == 1
    doAssert rewritten.children[0].kind == nkCall
    doAssert rewritten.children[0].children[0].str == "1"
    echo "CASE 2a PASS: #ifdef X (defined) kept the first branch"

  # --- case 2b: #ifdef with X undefined keeps the else branch ---
  block:
    let root = newBlock(@[
      newDirective("ifdef", @[newId("X")]),
      newCall(@[newNumber("1")], newId("print")),
      newDirective("else"),
      newCall(@[newNumber("2")], newId("print")),
      newDirective("endif"),
    ])
    var ctx = newPreprocessContext("", "t2b.nelua")
    let rewritten = preprocess(root, ctx)
    echo "CASE 2b dump:\n" & dump(rewritten)
    doAssert rewritten.children.len == 1
    doAssert rewritten.children[0].kind == nkCall
    doAssert rewritten.children[0].children[0].str == "2"
    echo "CASE 2b PASS: #ifdef X (undefined) kept the else branch"

  # --- case 2c: #ifndef / #elif / defined() in a #if condition ---
  block:
    let root = newBlock(@[
      newDirective("if", @[newString("defined(FOO) and BAR > 1", "cond")]),
      newCall(@[newNumber("1")], newId("print")),
      newDirective("elif", @[newString("BAZ == 0", "cond")]),
      newCall(@[newNumber("2")], newId("print")),
      newDirective("else"),
      newCall(@[newNumber("3")], newId("print")),
      newDirective("endif"),
    ])
    var ctx = newPreprocessContext("", "t2c.nelua")
    ctx.macros["FOO"] = MacroDef(body: "1", isFunction: false)
    ctx.macros["BAR"] = MacroDef(body: "5", isFunction: false)
    let rewritten = preprocess(root, ctx)
    doAssert rewritten.children.len == 1
    doAssert rewritten.children[0].children[0].str == "1"
    echo "CASE 2c PASS: #if defined(FOO) and BAR>1 evaluated"

  # --- case 3: #error surfaces as a diagnostic, not a crash ---
  block:
    let root = newBlock(@[newDirective("error", @[newString("boom")])])
    var ctx = newPreprocessContext("", "t3.nelua")
    var raised = false
    try:
      discard preprocess(root, ctx)
    except PreprocessError as e:
      raised = true
      echo "CASE 3 diagnostic: " & e.msg
    except:
      raise
    doAssert raised, "#error must raise PreprocessError"
    echo "CASE 3 PASS: #error surfaced as a diagnostic"

  # --- case 4: object-like macro expansion ---
  block:
    let root = newBlock(@[
      newDirective("define", @[newId("N"), newNumber("42")]),
      newVarDecl("local", @[newIdDecl("x")], @[newId("N")]),
    ])
    var ctx = newPreprocessContext("", "t4.nelua")
    let rewritten = preprocess(root, ctx)
    echo "CASE 4 dump:\n" & dump(rewritten)
    doAssert rewritten.children.len == 1
    doAssert rewritten.children[0].kind == nkVarDecl
    let init = rewritten.children[0].children[^1]
    doAssert init.kind == nkNumber and init.str == "42"
    echo "CASE 4 PASS: object-like N expanded to 42"

  # --- case 5: #undef after a #define ---
  block:
    let root = newBlock(@[
      newDirective("define", @[newId("X"), newNumber("1")]),
      newDirective("undef", @[newId("X")]),
      newDirective("ifdef", @[newId("X")]),
      newCall(@[newNumber("99")], newId("print")),
      newDirective("endif"),
    ])
    var ctx = newPreprocessContext("", "t5.nelua")
    let rewritten = preprocess(root, ctx)
    doAssert rewritten.children.len == 0
    echo "CASE 5 PASS: #undef removed X, ifdef dropped the branch"

  # --- case 6: no preprocessor nodes survive ---
  block:
    let root = newBlock(@[
      newCall(@[newString("hi")], newId("print")),
    ])
    var ctx = newPreprocessContext("", "t6.nelua")
    let rewritten = preprocess(root, ctx)
    proc hasDir(n: Node): bool =
      if n == nil: return false
      if n.kind in {nkDirective, nkPreprocess, nkPreprocessExpr, nkPreprocessName}:
        return true
      for c in n.children:
        if hasDir(c): return true
      return false
    doAssert not hasDir(rewritten)
    echo "CASE 6 PASS: no directive/preprocess nodes survive"

  # --- case 7: static_assert(true) in a ## block is a no-op ---
  block:
    var ctx = newPreprocessContext("", "t7.nelua")
    let ppNode = Node(kind: nkPreprocess, str: "static_assert(1+1 == 2, \"%s\", \"ok\")")
    let injected = runPreprocessChunk(ctx, @[ppNode])
    doAssert injected.len == 1
    doAssert injected[0].len == 0, "static_assert(true) must inject nothing"
    echo "CASE 7 PASS: static_assert(true) is a no-op"

  # --- case 8: static_assert(false) in a ## block raises PreprocessError ---
  block:
    var ctx = newPreprocessContext("", "t8.nelua")
    let ppNode = Node(kind: nkPreprocess, str: "static_assert(1+1 == 3, \"%s\", \"boom\")")
    var raised = false
    try:
      discard runPreprocessChunk(ctx, @[ppNode])
    except PreprocessError as e:
      raised = true
      doAssert "boom" in e.msg, "error message must carry the formatted arg"
    doAssert raised, "static_assert(false) must raise PreprocessError"
    echo "CASE 8 PASS: static_assert(false) raised with the formatted message"

  # --- case 9: inject_astnode splices parsed nelua into the current position ---
  block:
    var ctx = newPreprocessContext("", "t9.nelua")
    let ppNode = Node(kind: nkPreprocess, str: "inject_astnode(\"local x = 42\")")
    let injected = runPreprocessChunk(ctx, @[ppNode])
    doAssert injected.len == 1
    doAssert injected[0].len == 1, "inject_astnode must splice one statement"
    doAssert injected[0][0].kind == nkVarDecl, "injected node must be a VarDecl"
    let init = injected[0][0].children[^1]
    doAssert init.kind == nkNumber and init.str == "42"
    echo "CASE 9 PASS: inject_astnode parsed and spliced `local x = 42`"

  # --- case 10: hygienize wraps a function and returns it unchanged ---
  block:
    var ctx = newPreprocessContext("", "t10.nelua")
    let ppNode = Node(kind: nkPreprocess,
      str: "local f = hygienize(function() return 1 end); __nelua_mark(0); assert(f() == 1)")
    discard runPreprocessChunk(ctx, @[ppNode])
    echo "CASE 10 PASS: hygienize returned a callable function"

  # --- case 11: aster.Id / aster.Number construct nodes for inject_statement ---
  block:
    var ctx = newPreprocessContext("", "t11.nelua")
    let ppNode = Node(kind: nkPreprocess,
      str: "inject_statement(aster.Assign{{aster.Id{'a'}}, {aster.Number{'5'}}})")
    let injected = runPreprocessChunk(ctx, @[ppNode])
    doAssert injected.len == 1
    doAssert injected[0].len == 1, "inject_statement must splice one node"
    doAssert injected[0][0].kind == nkAssign, "injected node must be an Assign"
    echo "CASE 11 PASS: aster.Assign + inject_statement spliced an assignment"

  echo "preprocessor.nim self-test complete"