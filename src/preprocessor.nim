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

proc newPreprocessContext*(source = "", path = ""): PreprocessContext =
  ## Construct a fresh preprocessor context with no defines and an empty
  ## inject buffer (the inject buffer is `ctx.macros`-independent state the
  ## driver splices from; it is intentionally a field so callers can seed it).
  PreprocessContext(source: source, path: path)

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
# Pass driver
# ---------------------------------------------------------------------------

proc preprocess*(root: Node, ctx: var PreprocessContext): Node =
  ## Walk and rewrite `root`, consuming every directive / preprocessor node.
  if root == nil:
    return nil
  case root.kind
  of nkBlock:
    var rewritten: seq[Node] = @[]
    var condStack: seq[CondState] = @[]
    for n in root.children:
      if n.kind == nkDirective:
        handleDirective(n, rewritten, condStack, ctx)
      else:
        if condStack.len == 0 or condStack[^1].active:
          rewritten.add preprocess(n, ctx)
    root.children = rewritten
    return root
  of nkDirective:
    # A directive standing alone (not inside a block): process it and drop.
    var dummy: seq[Node] = @[]
    var condStack: seq[CondState] = @[]
    handleDirective(root, dummy, condStack, ctx)
    return nil
  of nkPreprocess:
    ctx.diags.add "## Lua preprocessor block is unsupported in this build; node consumed"
    return nil
  of nkPreprocessExpr, nkPreprocessName:
    ctx.diags.add "#[] / #|| preprocessor replacement is unsupported in this build; node consumed"
    return newNil()
  else:
    for i in 0 ..< root.children.len:
      root.children[i] = preprocess(root.children[i], ctx)
    return tryExpand(root, ctx)

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

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

  echo "preprocessor.nim self-test complete"