## M6 preprocessor — gradual per-node pass over the M1 AST.
##
## Consumes every `nkDirective` / `nkPreprocess` / `nkPreprocessName` node so
## that none survive into analysis.  `nkPreprocessExpr` (`#[expr]#`) is
## **evaluated** at compile time through the embedded Lua engine and spliced
## in place (see `evalSpliceExpr`), so it does NOT survive either.  Implements the
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
## §6 scope note: the reference's full-Lua preprocessor needs an embedded Lua
## interpreter, which this build ships (`src/luaengine.nim`).  `##` statement
## lines and `#[expr]#` expression replacement are both evaluated through it;
## `#[expr]#` is spliced in place (see `evalSpliceExpr`).  What remains
## unsupported (consumed with a diagnostic rather than evaluated) is
## `#|name|#` name replacement and `##[[ ... ]]` multi-line Lua blocks, so the
## "none survive into analysis" invariant still holds.

import
  ast, astshapes, parser, span, strutils, tables, types, ./sema
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
    pragmas*: seq[string]              ## active `-P` pragmas, exposed to `##`
                                        ## blocks as the `pragmas` global table

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
## The live analyzer scope, set by `evaluateSplice` for the duration of one
## `#[expr]#` evaluation.  `cSpliceEnvIndex` walks it so a bare identifier in a
## splice resolves to the enclosing nelua scope's symbols (Stage 4).
var gActiveScope: Scope = nil
## The preprocess-time nelua scope, built incrementally as `preprocess` walks
## the tree.  `##` blocks resolve bare identifiers against it via the
## `__nelua_scope` builtin (which injects `<name> = __nelua_scope("<name>")`
## into the chunk at each declaration's textual position), so a `##` line sees
## only the locals/params declared above it -- matching the oracle.
var gPreprocessScope: Scope = nil
var gCapturedBodies: TableRef[string, seq[Node]] = newTable[string, seq[Node]]()
var gInjectStack: seq[seq[seq[Node]]] = @[]
var gInjectCurrent = 0
var gBuiltinsRegistered = false
## Deferred-splice machinery.  A block collects every `#[expr]#` that appears
## anywhere inside it (direct children *and* nested inside expressions, but
## not inside a nested block, which has its own set) into `gBlockSplices`,
## leaving a sentinel in the tree.  After the block's `##` chunk has run, the
## driver substitutes each sentinel with the splice's value.  `gInBlockSpliceDeferral`
## is the toggle; the block saves and restores it so nested blocks are
## self-contained (this is the `stopAtNestedBlock` boundary).
var gBlockSplices: seq[Node] = @[]
var gInBlockSpliceDeferral = false
## Hybrid splice results: the value each `#[expr]#` produced when it was run
## interleaved into its block's `##` chunk at preprocess time (keyed by the
## sentinel's node pointer).  `evaluateSplice` (analysis) prefers a non-nil
## entry here -- that is how a `##`-local such as `## local x = 7` is visible
## to `#[x]#` -- and falls back to the live scope for nelua-scope splices,
## whose preprocess value is `nil` (the scope does not exist yet at preprocess
## time).
var gSpliceResults: TableRef[uint, Node] = newTable[uint, Node]()

# ---------------------------------------------------------------------------
# `in (expr)` splice-function registry.
#
# A `## local function f(p, q) in (#[p]# .. #[q]#) ## end` block defines a
# *splice function*: `f` is a compile-time function whose body is an
# expression containing `#[param]#` splice points.  A call `#[f]#(a, b)`
# substitutes each argument for its parameter's splice point and uses the
# resulting expression as the value.  This mirrors the reference's
# `## local function rotl(x,n) in (#[x]# << #[n]#) | ... ## end` (see
# `lib/detail/xoshiro256.nelua`).
# ---------------------------------------------------------------------------
type
  SpliceFuncDef* = object
    params*: seq[string]
    body*: Node          ## the `in (expr)` expression, with `#[param]#` splices

var gSpliceFuncs*: TableRef[string, SpliceFuncDef] = newTable[string, SpliceFuncDef]()

proc resetPreprocessorState*() =
  ## Clear every per-compilation scratch buffer so the next compilation starts
  ## clean.  Called by `luaengine.resetLuaState` (via `onResetEngine`) at the
  ## top of every `compile()`.
  gCapturedBodies.clear()
  gInjectStack = @[]
  gInjectCurrent = 0
  gBuiltinsRegistered = false
  gBlockSplices = @[]
  gInBlockSpliceDeferral = false
  gSpliceResults.clear()
  gSpliceFuncs.clear()
  gPreprocessScope = Scope(name: "global", symbols: initTable[string, Symbol](),
                           parent: nil, isFunction: false)

proc parseSpliceFuncOpener(text: string): (bool, string, seq[string]) =
  ## Parse a `##` line's raw text.  Returns `(true, name, params)` when the
  ## line is a splice-function opener (`local function NAME(p, q)` or
  ## `function NAME(p, q)` with no body / `end` on the same line); otherwise
  ## `(false, "", @[])`.
  let t = text.strip()
  var prefix: string
  if t.startsWith("local function "):
    prefix = "local function "
  elif t.startsWith("function "):
    prefix = "function "
  else:
    return (false, "", @[])
  let rest = t[prefix.len .. ^1]
  let lp = rest.find('(')
  if lp < 0:
    return (false, "", @[])
  let name = rest[0 .. lp-1].strip()
  if name.len == 0:
    return (false, "", @[])
  let rp = rest.find(')', lp + 1)
  if rp < 0:
    return (false, "", @[])
  let paramsStr = rest[lp + 1 .. rp - 1]
  var params: seq[string] = @[]
  if paramsStr.strip().len > 0:
    for p in paramsStr.split(','):
      let ps = p.strip()
      if ps.len > 0:
        params.add ps
  return (true, name, params)

proc newPreprocessContext*(source = "", path = "",
                            pragmas: seq[string] = @[]): PreprocessContext =
  ## Construct a fresh preprocessor context with no defines and an empty
  ## inject buffer (the inject buffer is `ctx.macros`-independent state the
  ## driver splices from; it is intentionally a field so callers can seed it).
  ## `pragmas` is the list of `-P` pragmas from the compiler config, exposed to
  ## `##` blocks as the `pragmas` global table.
  PreprocessContext(source: source, path: path, pragmas: pragmas,
    luaBuffer: @[], depth: 0)

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

proc substituteSpliceArgs(body: Node, params: seq[string],
                          args: seq[Node]): Node =
  ## Walk a clone of `body` and replace every `#[param]#` splice point
  ## (`nkPreprocessExpr` whose `str` is a parameter name) with the
  ## corresponding argument node.  Splice points that name no parameter are
  ## left untouched (they are ordinary `#[expr]#` splices evaluated later).
  let node = cloneNode(body)
  result = node
  var stack: seq[Node] = @[]
  stack.add node
  while stack.len > 0:
    let n = stack.pop()
    if n.kind == nkPreprocessExpr:
      let idx = params.find(n.str)
      if idx >= 0 and idx < args.len:
        # Replace in place by copying the arg's children/scalars onto `n`.
        let a = args[idx]
        n.kind = if a != nil: a.kind else: nkNil
        n.str = if a != nil: a.str else: ""
        n.litType = if a != nil: a.litType else: ""
        n.boolVal = if a != nil: a.boolVal else: false
        n.intVal = if a != nil: a.intVal else: 0
        n.isFunction = if a != nil: a.isFunction else: false
        n.isCall = if a != nil: a.isCall else: false
        n.isUnpackable = if a != nil: a.isUnpackable else: false
        n.isIndex = if a != nil: a.isIndex else: false
        n.isOperator = if a != nil: a.isOperator else: false
        n.children = if a != nil: a.children else: @[]
      continue
    for i in 0 ..< n.children.len:
      stack.add n.children[i]

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

proc applySpliceFunction(call: Node, ctx: var PreprocessContext): Node =
  ## Handle `#[name]#(args)` where `name` is a registered splice function.
  ## Substitute each argument for its parameter's `#[param]#` splice point in
  ## a clone of the stored body, preprocess the arguments (so nested splices
  ## and nested splice-function calls compose), and return the resulting
  ## expression.
  let callee = call.children[^1]
  let name = callee.str
  let def = gSpliceFuncs.getOrDefault(name)
  let rawArgs = call.children[0 ..< ^1]
  var args: seq[Node] = @[]
  for a in rawArgs:
    args.add preprocess(a, ctx)
  let body = substituteSpliceArgs(def.body, def.params, args)
  return preprocess(body, ctx)

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

# ---------------------------------------------------------------------------
# Type / Symbol wrappers for the splice environment (§2 / Step 5).
#
# The reference exposes each scope Symbol and Type as a Lua value whose
# `__index` metamethod maps field names to the Nim object's attributes.  Our
# clean-room build pushes Types the same way: a table carrying the `Type` ref
# as a `__nelua_type` lightuserdata, with `cTypeIndex` as its `__index`.  This
# is what makes `#[atype.is_oneindexing and 1 or 0]#`,
# `#[values.type.subtype.is_sequence and 1 or 0]#` and
# `#[concept(function(x) return x.type.is_span end)]#` readable.
#
# `luaValueToNode` recognises a wrapper table by its `__nelua_type` field and
# re-derives the `nkType(@nkId(name))` node it would have built from the bare
# lightuserdata, so wrapping the primitive type-name globals is transparent.

proc getWrapperType(L: PLuaState, idx: int): Type =
  ## Read the `__nelua_type` lightuserdata off a wrapper table at `idx`.
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, "__nelua_type")
  let p = L.lua_touserdata(-1)
  L.lua_pop(1)
  if p != nil:
    result = cast[Type](p)


proc pushTypeWrapper(L: PLuaState, t: Type)

proc pushBool(L: PLuaState, b: bool) =
  L.lua_pushboolean(if b: 1 else: 0)

proc power2str(n: int): string =
  ## 2^n as a decimal string (n >= 0).  Small n only (<= 128), so the O(n^2)
  ## repeated doubling is fine and avoids any int64/uint64 overflow edge case
  ## for the 128-bit types' min/max.
  var digits = "1"
  for _ in 0..<n:
    var carry = 0
    var res = ""
    for i in countdown(digits.len - 1, 0):
      let d = (digits[i].ord - ord('0')) * 2 + carry
      res = $(d mod 10) & res
      carry = d div 10
    if carry > 0:
      res = $carry & res
    digits = res
  return digits

proc decSub1(s: string): string =
  ## s - 1 for a positive decimal string s >= "1".
  var res = s
  var i = res.len - 1
  while i >= 0 and res[i] == '0':
    res[i] = '9'
    dec i
  if i >= 0:
    res[i] = chr(ord(res[i]) - 1)
  var start = 0
  while start < res.len - 1 and res[start] == '0':
    inc start
  return res[start..^1]

proc integralMinMax(t: Type): (string, string) =
  ## (min, max) decimal strings for an integral type, computed as bigints so
  ## the 64-bit unsigned max (2^64-1) and the 128-bit extremes are exact.
  let bits = 8 * size(t)
  if t.isSigned:
    let mag = power2str(bits - 1)      # 2^(bits-1)
    return ("-" & mag, decSub1(mag))   # -2^(bits-1), 2^(bits-1)-1
  let mag = power2str(bits)            # 2^bits
  return ("0", decSub1(mag))           # 0, 2^bits-1

proc pushMinMax(L: PLuaState, dec: string) =
  ## Push a min/max value.  Magnitudes that fit int64 go out as Lua *integers*:
  ## arithmetic is then exact and Lua 5.4's integer-overflow-to-float conversion
  ## reproduces the oracle's `isize.max + 1 -> 9.2233720368548e+18` exactly.
  ## Larger magnitudes (uint64 max, the 128-bit extremes) go out as Lua floats,
  ## which is what the oracle splices them to as well.
  let neg = dec.len > 0 and dec[0] == '-'
  let absStr = if neg: dec[1 ..< dec.len] else: dec
  let fits = if neg:
      absStr.len < 19 or (absStr.len == 19 and absStr <= "9223372036854775808")
    else:
      absStr.len < 19 or (absStr.len == 19 and absStr <= "9223372036854775807")
  if fits:
    var mag: uint64 = 0
    for c in absStr:
      mag = mag * 10 + uint64(ord(c) - ord('0'))
    let val = if neg:
        if mag == 0x8000000000000000'u64: cast[int64](mag)   # -2^63 = INT64_MIN
        else: -(mag.int64)
      else:
        mag.int64
    L.lua_pushinteger(val)
  else:
    L.lua_pushnumber(parseFloat(dec))

proc cIsConvertibleFrom(L: PLuaState): int {.cdecl.} =
  ## `t:is_convertible_from(arg)` -- is the wrapper `arg` convertible to `t`?
  let self = getWrapperType(L, 1)
  let arg = getWrapperType(L, 2)
  if self == nil or arg == nil:
    discard L.luaL_error("is_convertible_from: argument is not a type")
    return 0
  let c = convert(arg, self, false)
  L.lua_pushboolean(if c.kind != ckNone: 1 else: 0)
  return 1

proc cTypeIndex(L: PLuaState): int {.cdecl.} =
  ## `Type.__index(self, key)` -- map a field name to its value.
  let t = getWrapperType(L, 1)
  if t == nil:
    discard L.luaL_error("nelua: attempt to index a non-type value")
    return 0
  let keyPtr = L.lua_tolstring(2, nil)
  let key = if keyPtr != nil: $keyPtr else: ""
  case key
  of "name":
    pushStr(L, t.name)
  of "codename":
    pushStr(L, if t.codename.len > 0: t.codename else: codename(t))
  of "nickname":
    if t.nickname.len > 0: pushStr(L, t.nickname)
    else: L.lua_pushlightuserdata(nil)
  of "id":
    if t.typeid != 0: L.lua_pushnumber(cdouble(t.typeid))
    else: L.lua_pushlightuserdata(nil)
  of "subtype":
    if t.subtype != nil: pushTypeWrapper(L, t.subtype)
    else: L.lua_pushlightuserdata(nil)
  of "is_type":         pushBool(L, t.is_type)
  of "is_signed":      pushBool(L, t.isSigned)
  of "is_oneindexing": pushBool(L, t.is_oneindexing)
  of "is_sequence":    pushBool(L, t.is_sequence)
  of "is_span":        pushBool(L, t.is_span)
  of "is_vector":      pushBool(L, t.is_vector)
  of "is_list":        pushBool(L, t.is_list)
  of "is_hashmap":     pushBool(L, t.is_hashmap)
  of "is_contiguous":  pushBool(L, t.is_contiguous)
  of "is_container":   pushBool(L, t.is_container)
  of "is_scalar":      pushBool(L, t.is_scalar)
  of "is_arithmetic":  pushBool(L, t.is_arithmetic)
  of "is_float":       pushBool(L, t.is_float)
  of "is_integral":    pushBool(L, t.is_integral)
  of "is_stringy":     pushBool(L, t.is_stringy)
  of "is_boolean":     pushBool(L, t.is_boolean)
  of "is_string":      pushBool(L, t.is_string)
  of "is_cstring":     pushBool(L, t.is_cstring)
  of "is_cfloat":      pushBool(L, t.is_cfloat)
  of "is_cdouble":     pushBool(L, t.is_cdouble)
  of "is_record":      pushBool(L, t.is_record)
  of "is_union":       pushBool(L, t.is_union)
  of "is_enum":        pushBool(L, t.is_enum)
  of "is_function":    pushBool(L, t.is_function)
  of "is_procedure":   pushBool(L, t.is_procedure)
  of "is_pointer":     pushBool(L, t.is_pointer)
  of "is_nilptr":      pushBool(L, t.is_nilptr)
  of "is_array":       pushBool(L, t.is_array)
  of "is_optional":    pushBool(L, t.is_optional)
  of "is_variant":     pushBool(L, t.is_variant)
  of "is_table":       pushBool(L, t.is_table)
  of "is_concept":     pushBool(L, t.is_concept)
  of "is_generic":     pushBool(L, t.is_generic)
  of "is_comptime":    pushBool(L, t.is_comptime)
  of "is_polymorphic": pushBool(L, t.is_polymorphic)
  of "is_nilable":     pushBool(L, t.is_nilable)
  of "is_unpointable": pushBool(L, t.is_unpointable)
  of "is_nameable":    pushBool(L, t.is_nameable)
  of "is_nolvalue":    pushBool(L, t.is_nolvalue)
  of "is_nodecl":      pushBool(L, t.is_nodecl)
  of "is_overload":    pushBool(L, t.is_overload)
  of "is_facultative": pushBool(L, t.is_facultative)
  of "is_composite":   pushBool(L, t.is_composite)
  of "is_aggregate":   pushBool(L, t.is_aggregate)
  of "is_empty":       pushBool(L, t.is_empty)
  of "is_multipleargs":pushBool(L, t.is_multipleargs)
  of "is_falseable":   pushBool(L, t.is_falseable)
  of "is_auto":        pushBool(L, t.is_auto)
  of "is_any":         pushBool(L, t.is_any)
  of "is_varargs":     pushBool(L, t.is_varargs)
  of "is_varanys":     pushBool(L, t.is_varanys)
  of "is_void":        pushBool(L, t.is_void)
  of "is_niltype":     pushBool(L, t.is_niltype)
  of "size":           L.lua_pushinteger(size(t))
  of "align":          L.lua_pushinteger(alignof(t))
  of "bitsize":        L.lua_pushinteger(size(t) * 8)
  of "min":
    if t.isIntegral:
      let (mn, _) = integralMinMax(t)
      pushMinMax(L, mn)
    else:
      L.lua_pushlightuserdata(nil)
  of "max":
    if t.isIntegral:
      let (_, mx) = integralMinMax(t)
      pushMinMax(L, mx)
    else:
      L.lua_pushlightuserdata(nil)
  of "mantdigits":
    if t.kind == tkFloat32: L.lua_pushinteger(24)
    elif t.kind == tkFloat64: L.lua_pushinteger(53)
    elif t.kind == tkFloat128: L.lua_pushinteger(113)
    elif t.kind == tkClongdouble: L.lua_pushinteger(64)
    else: L.lua_pushlightuserdata(nil)
  of "decimaldigits":
    if t.kind == tkFloat32: L.lua_pushinteger(9)
    elif t.kind == tkFloat64: L.lua_pushinteger(17)
    elif t.kind == tkFloat128: L.lua_pushinteger(34)
    elif t.kind == tkClongdouble: L.lua_pushinteger(19)
    else: L.lua_pushlightuserdata(nil)
  of "is_convertible_from":
    L.lua_pushcfunction(cIsConvertibleFrom)
  else:
    L.lua_pushlightuserdata(nil)
  return 1


proc pushTypeWrapper(L: PLuaState, t: Type) =
  ## Push `t` as a Type wrapper table (with `cTypeIndex` `__index`).
  L.lua_createtable(0, 4)
  if t != nil:
    L.lua_pushlightuserdata(cast[pointer](t))
    L.lua_setfield(-2, "__nelua_type")
  L.lua_createtable(0, 1)
  L.lua_pushcfunction(cTypeIndex); L.lua_setfield(-2, "__index")
  L.lua_setmetatable(-2)

# ---------------------------------------------------------------------------
# Symbol wrapper + per-evaluation splice environment (§2 / Step 4).
#
# A bare identifier in `#[...]#` resolves through the per-evaluation environment
# table's `__index` metamethod (`cSpliceEnvIndex`), which walks the live
# analyzer scope (`gActiveScope`) and pushes a Symbol wrapper for any symbol
# found, falling through to the standard globals (math, primtypes, typedefs,
# type names) otherwise.  Undefined bare identifier -> nil (silent), matching
# the oracle.  The Symbol wrapper (`cSymIndex`) exposes `.name`, `.type` (a
# Type wrapper), `.value`, `.is_type`, `.is_signed`, `.kind`, `.codename`,
# `.is_const`, `.is_comptime`.

proc lookup(scope: Scope, name: string): Symbol =
  ## Walk `scope` and its parents for `name`; nil if absent.
  var s = scope
  while s != nil:
    if s.symbols.hasKey(name): return s.symbols[name]
    s = s.parent
  return nil

proc resolveTypeKey(key: string): Type =
  ## Resolve a type-as-value lookup key ("integer", "Record", ...) to a Type,
  ## for the builtin/typedef surface only (user type bindings need the analyzer's
  ## `ctx.lookup`, which is not available here).
  if key.len == 0: return nil
  if BuiltinTypes.hasKey(key): return BuiltinTypes[key]
  if PrimitiveTypes.hasKey(key): return PrimitiveTypes[key]
  return nil

proc declaredTypeOf(idDecl: Node): Type =
  ## Resolve an IdDecl's declared type annotation to a Type for the preprocess
  ## scope.  Builtins/typedefs resolve directly; `auto` maps to its default
  ## (int64), matching the oracle's preprocess-time behaviour.  Anything the
  ## analyzer has not bound yet (user records, complex annotations) is nil.
  if idDecl == nil or idDecl.children.len == 0: return nil
  let typeNode = idDecl.children[0]
  if typeNode.kind != nkId: return nil
  let t = resolveTypeKey(typeNode.str)
  if t != nil and t.kind == tkAuto:
    return BuiltinTypes["integer"]
  return t

proc injectNeluaLocals(decl: Node, chunkParts: var seq[string]) =
  ## For a `local`/`var` declaration, register each typed local in the
  ## preprocess scope and inject `<name> = __nelua_scope("<name>")` into the
  ## block's `##` chunk at this statement's textual position, so a `##` line
  ## below sees it (and one above does not), matching the oracle.
  if decl.kind != nkVarDecl: return
  for child in decl.children:
    if child.kind != nkIdDecl: continue
    let t = declaredTypeOf(child)
    if t == nil: continue
    let sym = Symbol(name: child.str, kind: skVar, typ: t, scope: gPreprocessScope)
    gPreprocessScope.symbols[child.str] = sym
    chunkParts.add child.str & " = __nelua_scope(\"" & child.str & "\")"

proc getWrapperSymbol(L: PLuaState, idx: int): Symbol =
  ## Read the `__nelua_symbol` lightuserdata off a wrapper table at `idx`.
  let base = L.lua_absidx(idx)
  L.lua_getfield(base, "__nelua_symbol")
  let p = L.lua_touserdata(-1)
  L.lua_pop(1)
  if p != nil: result = cast[Symbol](p)

proc cSymIndex(L: PLuaState): int {.cdecl.}   # forward, see below

proc pushSymbolWrapper(L: PLuaState, sym: Symbol) =
  ## Push `sym` as a wrapper table (with `cSymIndex` `__index`).
  L.lua_createtable(0, 4)
  if sym != nil:
    L.lua_pushlightuserdata(cast[pointer](sym))
    L.lua_setfield(-2, "__nelua_symbol")
  L.lua_createtable(0, 1)
  L.lua_pushcfunction(cSymIndex); L.lua_setfield(-2, "__index")
  L.lua_setmetatable(-2)

proc cSymIndex(L: PLuaState): int {.cdecl.} =
  ## `Symbol.__index(self, key)` -- map a field name to its value.
  let sym = getWrapperSymbol(L, 1)
  if sym == nil:
    discard L.luaL_error("nelua: attempt to index a non-symbol value")
    return 0
  let keyPtr = L.lua_tolstring(2, nil)
  let key = if keyPtr != nil: $keyPtr else: ""
  case key
  of "name":      pushStr(L, sym.name)
  of "type":      pushTypeWrapper(L, sym.typ)
  of "value":
    if sym.typ != nil and sym.typ == BuiltinTypes["type"] and sym.value.len > 0:
      let rt = resolveTypeKey(sym.value)
      if rt != nil: pushTypeWrapper(L, rt)
      else: pushStr(L, sym.value)
    else:
      pushStr(L, sym.value)
  of "is_type":   pushBool(L, sym.typ != nil and sym.typ == BuiltinTypes["type"])
  of "is_signed": pushBool(L, sym.typ != nil and sym.typ.isSigned)
  of "is_const":  pushBool(L, sym.isConst)
  of "is_comptime": pushBool(L, sym.comptime)
  of "kind":      pushStr(L, $sym.kind)
  of "codename":  pushStr(L, sym.codename)
  else:           L.lua_pushlightuserdata(nil)
  return 1

proc cSpliceEnvIndex(L: PLuaState): int {.cdecl.} =
  ## `__index` metamethod for the per-evaluation splice environment: resolve a
  ## bare identifier to the live analyzer scope's Symbol, falling through to the
  ## standard globals when the name is not a scope symbol.  Undefined bare
  ## identifier -> nil (silent), matching the oracle.
  let keyPtr = L.lua_tolstring(2, nil)
  let key = if keyPtr != nil: $keyPtr else: ""
  let sym = lookup(gActiveScope, key)
  if sym != nil:
    pushSymbolWrapper(L, sym)
  else:
    L.lua_getglobal(cstring(key))
  return 1

proc cNeluaScope(L: PLuaState): int {.cdecl.} =
  ## `__nelua_scope(name)` -- resolve a bare identifier to the enclosing nelua
  ## scope's Symbol at preprocess time, returning a symbol wrapper (or nil).
  ## `##` blocks call this via the injected `<name> = __nelua_scope("<name>")`
  ## line, so a `##` line sees only the locals/params declared above it.
  let namePtr = L.lua_tolstring(1, nil)
  let name = if namePtr != nil: $namePtr else: ""
  let sym = lookup(gPreprocessScope, name)
  if sym != nil:
    pushSymbolWrapper(L, sym)
  else:
    L.lua_pushlightuserdata(nil)
  return 1

proc createSpliceEnv(L: PLuaState, scope: Scope) =
  ## Push a fresh per-evaluation environment table whose `__index` is
  ## `cSpliceEnvIndex`, and set `gActiveScope` so the metamethod can walk it.
  gActiveScope = scope
  L.lua_createtable(0, 1)              # env table
  L.lua_createtable(0, 1)              # env's metatable
  L.lua_pushcfunction(cSpliceEnvIndex); L.lua_setfield(-2, "__index")
  L.lua_setmetatable(-2)

proc runChunkWithEnv(L: PLuaState, text: string, chunkName: string,
                     scope: Scope): (string, int) =
  ## Load `text` as a Lua chunk, install `createSpliceEnv(scope)` as the chunk's
  ## `_ENV` (so bare identifiers resolve through the scope feed), and run it.
  ## Returns (errorMessage, nresults); on success the results are left on the
  ## stack.  `luaL_loadbufferx`'s 4th arg is the load *mode* ("t"), not an
  ## environment -- the environment is set on the loaded closure via
  ## `lua_setupvalue` (Lua 5.4's `_ENV` upvalue).
  let loadRes = luaL_loadbufferx(L, text.cstring, text.len.csize_t,
                                 chunkName.cstring, "t")
  if loadRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)
    return ((if msg.len > 0: msg else: "lua load error (code " & $loadRes & ")"), 0)
  # Closure at -1; set its `_ENV` (upvalue 1) to the env table.
  createSpliceEnv(L, scope)            # env at -1, closure at -2
  discard L.lua_setupvalue(-2, 1)  # closure._ENV = env; pop env
  let pcRes = lua_pcallk(L, 0, LUA_MULTIPLE, 0, 0, nil)
  if pcRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)
    return ((if msg.len > 0: msg else: "lua run error (code " & $pcRes & ")"), 0)
  let n = lua_gettop(L)
  return ("", n)

proc cConcept(L: PLuaState): int {.cdecl.} =
  ## `concept(func)` -- build a ConceptType carrying `func` (§6 / Step 6).
  ## The reference calls `func` during analysis whenever a type tries to match
  ## the concept; our clean-room build has no scope-aware splice evaluator
  ## (Stage 4 Steps 1-4), so `func` is captured but not yet invoked.  The
  ## ConceptType is still constructed and spliced, which is what
  ## `#[concept(function(x) return x.type.is_span end)]#` needs.
  if lua_gettop(L) < 1 or lua_type(L, 1) != LUA_TFUNCTION:
    discard L.luaL_error("concept: expected a function argument")
    return 0
  lua_pop(L, 1)                     # capture point (matching is out of scope)
  let t = conceptType("concept", 0)
  pushTypeWrapper(L, t)
  return 1

proc cGeneric(L: PLuaState): int {.cdecl.} =
  ## `generic(func)` -- build a GenericType carrying `func` (§6 / Step 6).
  if lua_gettop(L) < 1 or lua_type(L, 1) != LUA_TFUNCTION:
    discard L.luaL_error("generic: expected a function argument")
    return 0
  lua_pop(L, 1)
  inc TypeCounter
  var t = Type(kind: tkGeneric, name: "generic", funcRef: 0, typeid: TypeCounter)
  computeShaper(t)
  pushTypeWrapper(L, t)
  return 1

proc cGeneralize(L: PLuaState): int {.cdecl.} =
  ## `generalize(func)` -- the reference wraps `func` in `memoize(hygienize())`
  ## before passing it to `generic`.  Our build has neither memoize nor the
  ## hygienic-closure machinery, so this is `generic(func)`.
  return cGeneric(L)

proc cStaticError(L: PLuaState): int {.cdecl.} =
  ## `static_error(msg, ...)` -- raise a compile-time error (§6 / Step 6).
  let top = lua_gettop(L)
  let msgPtr = if top >= 1: lua_tolstring(L, 1, nil) else: nil
  var args: seq[string] = @[]
  for i in 2 .. top:
    let s = lua_tolstring(L, i, nil)
    args.add if s != nil: $s else: "nil"
  let msg = if msgPtr != nil: $msgPtr else: ""
  let full = "static_error: " & formatPPMessage(msg, args)
  lua_pushstring(L, full.cstring)
  discard lua_error(L)
  return 0

proc injectDirective(L: PLuaState, name: string): int =
  ## Build a `Directive` node from the call's string arguments and splice it
  ## into the current `##` inject position (§6 / Step 6: cinclude/cdefine/
  ## cemit/cflags are `pp_directives` in the reference).
  if gInjectStack.len == 0:
    discard L.luaL_error(name & ": not inside a ## block")
    return 0
  let pos = gInjectCurrent
  if pos >= gInjectStack[^1].len:
    return 0
  var kids: seq[Node] = @[]
  let top = lua_gettop(L)
  for i in 1 .. top:
    let s = lua_tolstring(L, i, nil)
    if s != nil:
      kids.add newString($s)
  let node = newDirective(name, kids)
  gNodeScratch.add node
  gInjectStack[^1][pos].add node
  return 0

proc cCinclude(L: PLuaState): int {.cdecl.} =
  return injectDirective(L, "cinclude")
proc cCdefine(L: PLuaState): int {.cdecl.} =
  return injectDirective(L, "cdefine")
proc cCemit(L: PLuaState): int {.cdecl.} =
  return injectDirective(L, "cemit")
proc cCflags(L: PLuaState): int {.cdecl.} =
  return injectDirective(L, "cflags")

proc registerPreprocessorBuiltins*(L: PLuaState) =
  ## Register the Phase-B preprocessor builtins into the shared Lua state.
  ## Idempotent (guarded by `gBuiltinsRegistered`, reset by
  ## `resetLuaState` via the `onResetEngine` hook).
  if gBuiltinsRegistered:
    return
  gBuiltinsRegistered = true
  L.lua_pushcfunction(cMark); L.lua_setglobal("__nelua_mark")
  L.lua_pushcfunction(cInject); L.lua_setglobal("__nelua_inject")
  L.lua_pushcfunction(cNeluaScope); L.lua_setglobal("__nelua_scope")
  L.lua_pushcfunction(cInjectAstnode); L.lua_setglobal("inject_astnode")
  L.lua_pushcfunction(cInjectAstnode); L.lua_setglobal("inject")
  L.lua_pushcfunction(cHygienize); L.lua_setglobal("hygienize")
  L.lua_pushcfunction(cStaticAssert); L.lua_setglobal("static_assert")
  L.lua_createtable(0, 0); L.lua_setglobal("ppregistry")
  registerAster(L)
  # --- Step 6: concept / generic / generalize / static_error / cinclude /
  ## cdefine / cemit / cflags builtins (the reference's pp_methods /
  ## pp_directives).  `concept`/`generic`/`generalize` construct comptime
  ## types; `static_error` raises; the four C directives splice a Directive
  ## node at the current `##` inject position.
  L.lua_pushcfunction(cConcept); L.lua_setglobal("concept")
  L.lua_pushcfunction(cGeneric); L.lua_setglobal("generic")
  L.lua_pushcfunction(cGeneralize); L.lua_setglobal("generalize")
  L.lua_pushcfunction(cStaticError); L.lua_setglobal("static_error")
  L.lua_pushcfunction(cCinclude); L.lua_setglobal("cinclude")
  L.lua_pushcfunction(cCdefine); L.lua_setglobal("cdefine")
  L.lua_pushcfunction(cCemit); L.lua_setglobal("cemit")
  L.lua_pushcfunction(cCflags); L.lua_setglobal("cflags")
  # --- splice-environment globals (`#[expr]#`) ---
  # The reference's splice environment exposes `primtypes` (every primitive
  # Type), `typedefs`, and the nelua type-name identifiers.  We seed the same
  # surface into the shared Lua state so `#[math.huge]#` and `#[integer]#`
  # resolve.  Each Type is pushed as a Type-wrapper table (with `cTypeIndex`
  # `__index`) so attribute splices like `#[atype.is_oneindexing and 1 or 0]#`
  # work; `luaValueToNode` recognises the wrapper and re-derives the same
  # `nkType(@nkId(name))` node the bare lightuserdata used to produce.
  L.lua_createtable(0, BuiltinTypes.len + PrimitiveTypes.len)
  for nm, ty in BuiltinTypes:
    pushTypeWrapper(L, ty)
    L.lua_setfield(-2, nm)
  for nm, ty in PrimitiveTypes:
    pushTypeWrapper(L, ty)
    L.lua_setfield(-2, nm)
  L.lua_setglobal("primtypes")
  L.lua_createtable(0, 1)
  L.lua_getglobal("primtypes")
  L.lua_setfield(-2, "primtypes")
  L.lua_setglobal("typedefs")
  # Seed the type-name identifiers as globals, skipping the three that collide
  # with standard Lua (`string` is the library, `nil` is a keyword, `type` is
  # the type-query function) so those keep their Lua meaning.
  for nm, ty in BuiltinTypes:
    if nm == "string" or nm == "nil" or nm == "type": continue
    pushTypeWrapper(L, ty)
    L.lua_setglobal(nm)
  for nm, ty in PrimitiveTypes:
    pushTypeWrapper(L, ty)
    L.lua_setglobal(nm)

## The Lua half of `setPragmasGlobal`: replicate configer.lua's
## `convert_param` -- a bare `name` becomes `name = true`, then every pragma is
## loaded as a chunk with `pragmas` as its environment, so `name=value`
## pragmas evaluate the value in that env (e.g. `-P abort=exit` leaves
## `pragmas.abort` nil because `exit` is not in scope there, exactly as the
## reference's pp phase does).
const PRAGMAS_INIT_CHUNK =
  "pragmas = {}\n" &
  "local raw = __nelua_raw_pragmas\n" &
  "for i = 1, #raw do\n" &
  "  local p = raw[i]\n" &
  "  local code = p:match('^%a[_%w]*$') and (p .. ' = true') or p\n" &
  "  local f, err = load(code, '@pragma', 't', pragmas)\n" &
  "  if not f then error('failed parsing pragma [' .. p .. ']: ' .. tostring(err)) end\n" &
  "  local ok, err2 = pcall(f)\n" &
  "  if not ok then error('failed parsing pragma [' .. p .. ']: ' .. tostring(err2)) end\n" &
  "end\n"

proc setPragmasGlobal*(L: PLuaState, pragmas: seq[string]): string =
  ## Expose the active `-P` pragmas to `##` blocks as the `pragmas` global
  ## table, matching the reference's model (configer.lua `convert_param`):
  ## a bare `name` becomes `pragmas.name = true`; a `name=value` pragma is
  ## loaded as a Lua chunk with `pragmas` as its environment, so e.g.
  ## `-P abort=exit` evaluates `exit` in that env (nil) and leaves
  ## `pragmas.abort` nil -- exactly as the reference's pp phase does.  The
  ## construction runs in Lua so the environment semantics are identical.
  ##
  ## Returns "" on success, an error message on failure (a pragma that does
  ## not load or run raises, like the reference).
  if pragmas.len == 0:
    L.lua_createtable(0, 0)
    L.lua_setglobal("pragmas")
    return ""
  L.lua_createtable(0, pragmas.len)
  for i, p in pragmas:
    L.lua_pushstring(cstring(p))
    L.lua_rawseti(-2, i + 1)          # Lua tables are 1-indexed
  L.lua_setglobal("__nelua_raw_pragmas")
  let err = runChunk(L, PRAGMAS_INIT_CHUNK, "nelua:pp:pragmas")
  L.lua_pushnil(); L.lua_setglobal("__nelua_raw_pragmas")
  return err

proc luaTableToNode*(L: PLuaState, idx: int): Node   # forward, see below

proc luaRawGetField(L: PLuaState, idx: int, name: string) =
  ## Raw field access (`lua_pushstring` + `lua_rawget`) that does NOT trigger the
  ## table's `__index` metamethod.  Used to read the wrapper marker fields
  ## (`__nelua_symbol`, `__nelua_type`, `_bn`) off a wrapper table without
  ## re-entering `cSymIndex`/`cTypeIndex`, which would happen with `lua_getfield`
  ## and is unsafe when called outside a protected Lua call (e.g. here).
  let base = L.lua_absidx(idx)
  L.lua_pushstring(cstring(name))
  L.lua_rawget(base)

proc luaValueToNode*(L: PLuaState, idx: int): Node =
  ## Convert a Lua value on the stack at `idx` into a Nelua AST node -- the Nim
  ## analogue of the reference's `aster.value`.  Conversion is by Lua type:
  ##
  ##   nil -> nkNil, boolean -> nkBoolean, string -> nkString,
  ##   number -> nkNumber (decimal text; `math.huge` -> "inf"),
  ##   a nelua `Type` (lightuserdata OR a Type-wrapper table) ->
  ##     `nkType(@nkId(name))` so `analyzeVarDecl`'s `isTypeBinding`
  ##     branch handles it,
  ##   table -> nkInitList, function -> `cannot convert ... function`.
  let tt = lua_type(L, idx)
  case tt
  of LUA_TNIL:
    return newNil()
  of LUA_TBOOLEAN:
    return newBoolean(lua_toboolean(L, idx) != 0)
  of LUA_TSTRING:
    let s = lua_tolstring(L, idx, nil)
    return newString(if s != nil: $s else: "")
  of LUA_TNUMBER:
    if lua_isinteger(L, idx) != 0:
      let i = lua_tointegerx(L, idx, nil)
      return newNumber($i)
    let f = lua_tonumberx(L, idx, nil)
    return newNumber($f)
  of LUA_TLIGHTUSERDATA:
    let p = lua_touserdata(L, idx)
    if p != nil:
      let ty = cast[Type](p)
      if ty != nil:
        let nm = if ty.name.len > 0: ty.name else: "any"
        return newType(newId(nm))
    return newNil()
  of LUA_TTABLE:
    # Read the wrapper marker fields with RAW access (`luaRawGetField`), which
    # does not trigger the wrapper's own `__index` metamethod.  `lua_getfield`
    # would re-enter `cSymIndex`/`cTypeIndex` here, which is unsafe outside a
    ## protected Lua call and aborts the process.
    # A Symbol wrapper table carries a `__nelua_symbol` lightuserdata field.
    # A bare symbol splice (`#[x]#`) resolves to the symbol itself, so unwrap
    # it to the symbol's comptime value: a Type for a type-typed symbol, else
    # its comptime literal string (nil when the symbol has no known value).
    L.luaRawGetField(idx, "__nelua_symbol")
    if L.lua_type(-1) == LUA_TLIGHTUSERDATA:
      let p = L.lua_touserdata(-1)
      L.lua_pop(1)
      if p != nil:
        let sym = cast[Symbol](p)
        if sym != nil:
          if sym.typ != nil and sym.typ == BuiltinTypes["type"] and
             sym.value.len > 0:
            let rt = resolveTypeKey(sym.value)
            if rt != nil:
              let nm = if rt.name.len > 0: rt.name else: "any"
              return newType(newId(nm))
            return newString(sym.value)
          if sym.value.len > 0:
            return newString(sym.value)
          return newNil()
    L.lua_pop(1)
    # A bigint value (primtypes.isize.min / .max) carries a `_bn=true` marker
    # and its exact decimal form in `dec`; splice it as a number literal so the
    # nelua parser re-applies its magnitude >= 2^63 -> float rule.
    L.luaRawGetField(idx, "_bn")
    if L.lua_type(-1) == LUA_TBOOLEAN and L.lua_toboolean(-1) != 0:
      L.lua_pop(1)
      L.luaRawGetField(idx, "dec")
      let s = if L.lua_type(-1) == LUA_TSTRING: $L.lua_tolstring(-1, nil) else: "0"
      L.lua_pop(1)
      return newNumber(s)
    L.lua_pop(1)
    # A Type wrapper table carries a `__nelua_type` lightuserdata field;
    # recognise it before falling through to the InitList path.
    L.luaRawGetField(idx, "__nelua_type")
    if L.lua_type(-1) == LUA_TLIGHTUSERDATA:
      let p = L.lua_touserdata(-1)
      L.lua_pop(1)
      if p != nil:
        let ty = cast[Type](p)
        if ty != nil:
          let nm = if ty.name.len > 0: ty.name else: "any"
          return newType(newId(nm))
    L.lua_pop(1)
    return luaTableToNode(L, idx)
  of LUA_TFUNCTION:
    raise PreprocessError(loc: newSourceLoc("", "", 0),
      msg: "cannot convert preprocess value of type \"function\" to an AST node")
  else:
    raise PreprocessError(loc: newSourceLoc("", "", 0),
      msg: "cannot convert preprocess value of type \"" & $tt & "\" to an AST node")

proc luaTableToNode*(L: PLuaState, idx: int): Node =
  ## Convert a Lua table into an `nkInitList`.  The C backend cannot consume
  ## tables, so this is MVP-only; it is here so a table splice does not crash.
  var elems: seq[Node] = @[]
  let narr = lua_rawlen(L, idx)
  for i in 1 .. narr:
    lua_rawgeti(L, idx, i)
    elems.add luaValueToNode(L, -1)
    lua_pop(L, 1)
  return newInitList(elems)

proc evaluateSplice*(scope: Scope, node: Node, path: string,
                       source: string): (Node, string) =
  ## Evaluate `#[expr]#` against the live analyzer `scope` (Stage 4).  When the
  ## splice was already run interleaved into its block's `##` chunk at
  ## preprocess time and produced a non-nil value, that value is used directly:
  ## this is how a `##`-local such as `## local x = 7` is visible to `#[x]#`
  ## (with correct source-order and `##`-local precedence).  Otherwise the
  ## splice is evaluated here against the live scope, which is what makes a
  ## nelua-scope symbol such as `local x = 5` resolve inside `#[x]#`.
  ## On error returns `(newNil(), errMsg)`; the caller adds it to `ctx.diags`.
  let p = cast[uint](node)
  if gSpliceResults.hasKey(p):
    let r = gSpliceResults[p]
    gSpliceResults.del(p)
    gActiveScope = nil
    if r != nil and r.kind != nkNil:
      return (r, "")
  let L = getLuaEngine(path)
  registerPreprocessorBuiltins(L)
  let chunkName = "@" & path & ":splice"
  let src = node.str.strip()
  let chunkText = if src.len == 0: "" else: "return (" & src & ")"
  let (errMsg, nres) = runChunkWithEnv(L, chunkText, chunkName, scope)
  gActiveScope = nil
  if errMsg.len > 0:
    return (newNil(), "error while preprocessing block: " & chunkName & ": " & errMsg)
  if nres == 0:
    return (newNil(), "")
  try:
    let result = luaValueToNode(L, -nres)
    lua_settop(L, 0)
    return (result, "")
  except PreprocessError as e:
    lua_settop(L, 0)
    return (newNil(), e.msg)

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
    of "cdefine", "cinclude", "cemit", "cflags":
      ## §6 / Step 6 Phase-B C directives.  They are injected by the matching
      ## preprocessor builtins (`cdefine`/`cinclude`/`cemit`/`cflags`, registered
      ## in `registerPreprocessorBuiltins`) from inside `##` Lua blocks.  The
      ## directive node is consumed here; the actual C-text emission is a `cgen`
      ## concern (it has no hook for user C at present), so the node is dropped
      ## silently rather than producing a spurious "unknown directive" diag.
      discard
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

proc collectSpliceParts(node: Node, parts: var seq[string], splices: var seq[Node]) =
  ## Walk `node` (recursively, but stopping at nested blocks) appending a
  ## `__nelua_spliceN = ...` capture line for every `#[expr]#` encountered, in
  ## source order, and recording the splice nodes in `splices` (parallel).
  ## Stopping at nested blocks keeps each block's splices in that block's own
  ## chunk (the `stopAtNestedBlock` boundary).
  ##
  ## The capture is wrapped in `pcall(...)` returning `nil` on error.  This is
  ## the safety net that lets the same splice be run in the `##` chunk (where a
  ## nelua-scope symbol such as `x` is an *undefined global*, so `x.name` would
  ## raise) without aborting the whole block: a capture that raises here simply
  ## yields `nil`, and `evaluateSplice` falls back to the live-scope evaluation
  ## at analysis time, which resolves `x` to its Symbol wrapper.
  if node == nil:
    return
  if node.kind == nkPreprocessExpr:
    let idx = splices.len
    splices.add node
    parts.add "__nelua_splice" & $idx & " = (function() local __ok, __r = pcall(function() return (" & node.str & ") end); if __ok then return __r else return nil end end)()"
    return
  if node.kind == nkBlock:
    return
  for child in node.children:
    collectSpliceParts(child, parts, splices)

proc runPreprocessChunk(ctx: var PreprocessContext, chunkParts: seq[string],
                        ppNodes: seq[Node], splices: seq[Node]):
                      (seq[seq[Node]], seq[Node]) =
  ## Run `chunkParts` (already built in source order, with `__nelua_mark(i)`
  ## position markers for the `##` nodes in `ppNodes` and `__nelua_spliceN =
  ## (expr)` capture lines for the splices) as a single Lua chunk, and return
  ## the nodes each `##` position injected (indexed parallel to `ppNodes`)
  ## and each splice's converted value (indexed parallel to `splices`).
  ##
  ## Because the `##` lines and the splice captures are interleaved in source
  ## order, a splice only sees the `##` effects that precede it textually --
  ## exactly the reference interpreter's model (a `## local` defined after a
  ## splice is not visible to it).  Running everything as *one* chunk (rather
  ## than one invocation per line) makes `local` declarations persist across
  ## adjacent `##` lines.  `gInjectStack` makes this re-entrant: an injected
  ## node that is itself a block pushes its own frame.
  if chunkParts.len == 0:
    return (@[], @[])
  gInjectStack.add newSeq[seq[Node]](ppNodes.len)
  gInjectCurrent = 0
  let chunkText = chunkParts.join("\n")
  let L = getLuaEngine(ctx.path)
  registerPreprocessorBuiltins(L)
  let chunkName = "@" & ctx.path & ":ppcode"
  let pragmaErr = setPragmasGlobal(L, ctx.pragmas)
  if pragmaErr.len > 0:
    gInjectStack.setLen(gInjectStack.len - 1)
    raise PreprocessError(loc: newSourceLoc(ctx.path, ctx.source, 0),
      msg: "error while setting up pragmas: " & chunkName & ": " & pragmaErr)
  gActiveCtx = addr ctx
  let (errMsg, nres) = runChunkGetResult(L, chunkText, chunkName)
  gActiveCtx = nil
  if errMsg.len > 0:
    gInjectStack.setLen(gInjectStack.len - 1)
    raise PreprocessError(loc: newSourceLoc(ctx.path, ctx.source, 0),
      msg: "error while preprocessing block: " & chunkName & ": " & errMsg)
  result[0] = gInjectStack[^1]
  result[1] = newSeq[Node](splices.len)
  if splices.len > 0 and nres > 0:
    for i in 0 ..< splices.len:
      lua_rawgeti(L, -nres, i + 1)     # Lua tables are 1-indexed
      result[1][i] = luaValueToNode(L, -1)
      lua_pop(L, 1)
  lua_settop(L, 0)
  gInjectStack.setLen(gInjectStack.len - 1)

proc runPreprocessChunk(ctx: var PreprocessContext, ppNodes: seq[Node]): seq[seq[Node]] =
  ## Backward-compatible wrapper used by the standalone-`##` path and the
  ## self-tests: run `##` nodes with no splices, returning only the injected
  ## nodes (indexed parallel to `ppNodes`).
  var chunkParts: seq[string] = @[]
  for i, node in ppNodes:
    chunkParts.add "__nelua_mark(" & $i & ") " & node.str
  let (injected, _) = runPreprocessChunk(ctx, chunkParts, ppNodes, @[])
  return injected

proc substituteSplices(node: Node, splices: seq[Node], results: seq[Node],
                        ctx: var PreprocessContext, i: var int): Node =
  ## Walk `node` (recursively) replacing each splice sentinel -- a node that is
  ## identity-equal to `splices[i]` -- with `preprocess(results[i], ctx)`.
  ## Splices are encountered in depth-first source order, matching the order
  ## they were collected into `splices`, so the parallel index `i` lines up.
  if node == nil:
    return nil
  if i < splices.len and node == splices[i]:
    inc i
    let processed = preprocess(results[i - 1], ctx)
    return if processed != nil: processed else: newNil()
  if node.children.len > 0:
    for j in 0 ..< node.children.len:
      node.children[j] = substituteSplices(node.children[j], splices, results, ctx, i)
  return node

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
    # Save and reset the deferred-splice list for this block; nested blocks
    # (reached through the recursive `preprocess` call below) do the same, so
    # each block collects only the splices that appear directly inside it.
    let savedSplices = gBlockSplices
    let savedDeferral = gInBlockSpliceDeferral
    gBlockSplices = @[]
    gInBlockSpliceDeferral = true
    defer:
      gBlockSplices = savedSplices
      gInBlockSpliceDeferral = savedDeferral
    var rewritten: seq[Node] = @[]
    var condStack: seq[CondState] = @[]
    var frameStack: seq[LuaFrame] = @[]
    var ppNodes: seq[Node] = @[]
    var chunkParts: seq[string] = @[]
    # Inject the enclosing function's params at the start of this block's
    # chunk so `##` lines in the body can resolve them (e.g.
    # `## if v.type.is_pointer then` for `v: auto`).  Params are declared
    # before the body, so they are visible from the first `##` line; block
    # locals are injected positionally below as they are walked.
    if gPreprocessScope != nil and gPreprocessScope.isFunction:
      for name, sym in gPreprocessScope.symbols:
        if sym.typ != nil:
          chunkParts.add name & " = __nelua_scope(\"" & name & "\")"
    # Pre-pass: register every `## local function f(p) in (body) ## end`
    # splice-function definition and remove its three nodes from the block so
    # they are not fed to the `##` Lua chunk (the opener line is not valid Lua
    # on its own -- it has no body -- and the `in (body)` is nelua syntax, not
    # Lua).  The body is stored on the registry for later argument splicing.
    var filtered: seq[Node] = @[]
    var spIdx = 0
    while spIdx < root.children.len:
      let n = root.children[spIdx]
      if n.kind == nkPreprocess and not n.boolVal and frameStack.len == 0:
        let (isOpener, sname, params) = parseSpliceFuncOpener(n.str)
        if isOpener and spIdx + 2 < root.children.len and
           root.children[spIdx + 1].kind == nkIn and
           root.children[spIdx + 2].kind == nkPreprocess and
           root.children[spIdx + 2].str.strip() == "end":
          let body = root.children[spIdx + 1].children[0]
          gSpliceFuncs[sname] = SpliceFuncDef(params: params, body: body)
          inc spIdx, 3
          continue
      filtered.add n
      inc spIdx
    root.children = filtered
    for n in root.children:
      if n.kind == nkDirective:
        handleDirective(n, rewritten, condStack, ctx)
      elif n.kind == nkPreprocess:
        if n.boolVal:
          # A `##[[ ... ]]` / `##[=[ ... ]=]` self-contained Lua block.  Its
          # body is a complete chunk and may contain `for`/`if`/`end`, so it
          # must NOT be subjected to the `luaBlockDelta` framing below (which
          # would treat it as an opener and either never run it or emit an
          # "unbalanced ## block" diagnostic).  Run it as a standalone chunk.
          rewritten.add n
          ppNodes.add n
          chunkParts.add "__nelua_mark(" & $(ppNodes.len - 1) & ") " & n.str
        else:
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
              chunkParts.add "__nelua_mark(" & $(ppNodes.len - 1) & ") " & node.str
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
              chunkParts.add "__nelua_mark(" & $(ppNodes.len - 1) & ") " & n.str
      elif n.kind == nkPreprocessExpr:
        if condStack.len == 0 or condStack[^1].active:
          # Hybrid: leave the sentinel in place (analysis-time `replaceSplices`
          # resolves it) but ALSO collect it into this block's `##` chunk so a
          # `##`-local defined above is visible to it.  `evaluateSplice` prefers
          # the non-nil preprocess result and falls back to the live scope for
          # nelua-scope splices (whose preprocess value is `nil`).
          rewritten.add n
          let idx = gBlockSplices.len
          gBlockSplices.add n
          chunkParts.add "__nelua_splice" & $idx & " = (function() local __ok, __r = pcall(function() return (" & n.str & ") end); if __ok then return __r else return nil end end)()"
      elif n.kind == nkPreprocessName:
        ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build; node consumed"
      else:
        if frameStack.len > 0:
          frameStack[^1].parts.add LuaFramePart(isBody: true, nodes: @[n])
        else:
          if n.kind == nkVarDecl:
            injectNeluaLocals(n, chunkParts)
          if condStack.len == 0 or condStack[^1].active:
            # Extract any `#[expr]#` nested in this statement into the block's
            # `##` chunk (interleaved in source order) so a `##`-local defined
            # above is visible to them; the sentinels stay in the tree and are
            # resolved by `replaceSplices` at analysis time.
            collectSpliceParts(n, chunkParts, gBlockSplices)
            rewritten.add preprocess(n, ctx)
    if frameStack.len > 0:
      ctx.diags.add "unbalanced ## block: unclosed Lua construct in " & ctx.path
    if gBlockSplices.len > 0:
      var ret = "{"
      for i in 0 ..< gBlockSplices.len:
        if i > 0: ret.add ", "
        ret.add "__nelua_splice" & $i
      ret.add "}"
      chunkParts.add "return " & ret
    if ppNodes.len > 0 or gBlockSplices.len > 0:
      let (injected, spliceResults) = runPreprocessChunk(ctx, chunkParts, ppNodes, gBlockSplices)
      # Record each splice's preprocess value (keyed by sentinel pointer) so
      # `evaluateSplice` can prefer it at analysis time.  Sentinels are left in
      # the tree -- they are resolved by `replaceSplices`, which calls
      # `evaluateSplice`.
      for i in 0 ..< gBlockSplices.len:
        gSpliceResults[cast[uint](gBlockSplices[i])] = spliceResults[i]
      # Splices have been collected and evaluated; turn deferral off so any
      # `#[expr]#` still in the tree (e.g. inside an injected `##` node) is
      # evaluated immediately as a standalone chunk rather than re-deferred
      # into an already-run chunk.
      gInBlockSpliceDeferral = false
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
          # Leave splice sentinels in place; `replaceSplices` (analysis) resolves
          # them via `evaluateSplice`, which prefers the preprocess result.
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
  of nkPreprocessExpr:
    # Stage 4: leave the splice in place.  It is evaluated later by
    # `replaceSplices` in the analyzer against the live scope; evaluating it
    # here (preprocess time) sees only the shared Lua globals, never the
    # enclosing nelua scope, so bare scope symbols resolved to `nil`.
    return root
  of nkPreprocessName:
    ctx.diags.add "#|name|# preprocessor replacement is unsupported in this build; node consumed"
    return newNil()
  of nkFuncDef:
    ## Push a scope carrying the function's params so `##` blocks in the body
    ## can resolve them (e.g. `## if v.type.is_pointer then` for `v: auto`).
    ## The body's own `local` declarations are added to this same scope as the
    ## block is walked (nelua locals are function-scoped), and the scope is
    ## restored when the function is left so siblings do not see them.
    let saved = gPreprocessScope
    var fscope = Scope(name: root.str, symbols: initTable[string, Symbol](),
                       parent: saved, isFunction: true)
    for child in root.children:
      if child.kind == nkIdDecl:
        let sym = Symbol(name: child.str, kind: skParam, typ: declaredTypeOf(child),
                         scope: fscope)
        fscope.symbols[child.str] = sym
    gPreprocessScope = fscope
    for i in 0 ..< root.children.len:
      root.children[i] = preprocess(root.children[i], ctx)
    gPreprocessScope = saved
    return tryExpand(root, ctx)
  of nkCall:
    ## `#[name]#(args)` where `name` is a registered splice function: splice
    ## the arguments into a clone of the stored body and return the resulting
    ## expression.  Checked before the generic `else` branch so the callee's
    ## `#[name]#` sentinel is never deferred/evaluated as an ordinary splice.
    let callee = root.children[^1]
    if callee.kind == nkPreprocessExpr and gSpliceFuncs.hasKey(callee.str):
      return applySpliceFunction(root, ctx)
    for i in 0 ..< root.children.len:
      root.children[i] = preprocess(root.children[i], ctx)
    # `require 'name'` lowers to an ordinary call on the builtin `require`
    # (parser.nim), so it is *not* a directive and is preserved intact here --
    # the module's resolution/compilation is the driver's job (compile.nim),
    # which runs on the raw parse tree before this pass is ever invoked.
    return tryExpand(root, ctx)
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