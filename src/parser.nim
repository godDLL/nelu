## Nelua recursive-descent parser. Consumes the lexer token stream and emits
## an AST built on the ast.nim constructors. The internal `children` layout is
## the one documented in ast.nim; this module is the sole producer of it.
##
## Malformed input raises ParseError carrying a source location; `parse` catches
## it, reports a diagnostic, and returns nil so callers can abort cleanly.

import ast
import astshapes
import lexer
import span
import strutils

type
  ParseError* = ref object of ValueError
    loc*: SourceLoc

  Parser* = object
    tokens*: seq[Token]
    pos*: int
    source*: string
    path*: string

proc newParser*(source: string, path: string = ""): Parser =
  Parser(tokens: tokenize(source, path), pos: 0, source: source, path: path)

proc tok*(p: Parser): Token =
  if p.pos < p.tokens.len: p.tokens[p.pos] else: p.tokens[^1]

proc peek*(p: Parser, ahead = 0): Token =
  let i = min(p.pos + ahead, p.tokens.len - 1)
  p.tokens[i]

proc advance*(p: var Parser): Token {.discardable.} =
  result = p.tokens[p.pos]
  if p.pos < p.tokens.len - 1: inc p.pos

proc check*(p: Parser, kind: TokenType): bool =
  p.tok.kind == kind

proc checkKeyword*(p: Parser, kw: string): bool =
  p.tok.kind == tkKeyword and p.tok.value == kw

proc match*(p: var Parser, kind: TokenType): bool =
  if p.check(kind): discard p.advance(); return true
  return false

proc matchKeyword*(p: var Parser, kw: string): bool =
  if p.checkKeyword(kw): discard p.advance(); return true
  return false

proc error*(p: Parser, msg: string): ParseError
proc parseExpr*(p: var Parser): Node
proc parseOr*(p: var Parser): Node
proc parsePower*(p: var Parser): Node
proc parseBlock*(p: var Parser): Node
proc parseStatement*(p: var Parser): Node

proc expect*(p: var Parser, kind: TokenType, msg: string): Token {.discardable.} =
  if p.check(kind): return p.advance()
  raise p.error(msg)

proc expectKeyword*(p: var Parser, kw: string, msg: string): Token {.discardable.} =
  if p.checkKeyword(kw): return p.advance()
  raise p.error(msg)

proc error*(p: Parser, msg: string): ParseError =
  result = new ParseError
  result.msg = msg
  result.loc = p.tok.loc

# --- annotations -----------------------------------------------------------

proc parseAnnotation*(p: var Parser): Node =
  let t = p.advance()
  let text = t.value[1 ..< t.value.len - 1]
  let parts = text.split(',')
  var name = ""
  var args: seq[Node] = @[]
  for i, part in parts:
    let s = part.strip()
    if s == "": continue
    if i == 0:
      name = s
    else:
      let eq = s.find('=')
      if eq >= 0:
        let k = s[0 ..< eq].strip()
        let v = s.substr(eq + 1).strip()
        args.add newPair(k, newId(v))
      else:
        args.add newId(s)
  return newAnnotation(name, args)

proc parseAnnotations*(p: var Parser): seq[Node] =
  var anns: seq[Node] = @[]
  while p.check(tkAnnotation):
    anns.add p.parseAnnotation()
  return anns

# --- type expressions -------------------------------------------------------

proc parseType*(p: var Parser): Node =
  let t = p.tok
  var base: Node = nil
  case t.kind
  of tkMul:
    p.advance()
    let sub = p.parseType()
    base = newPointerType(if sub != nil: sub else: newId("any"))
  of tkIdent, tkKeyword:
    case t.value
    of "record":
      p.advance()
      p.expect(tkLBrace, "expected '{' after record")
      var fields: seq[Node] = @[]
      while not p.check(tkRBrace):
        let name = p.advance().value
        p.expect(tkColon, "expected ':' after field name")
        let ft = p.parseType()
        fields.add newRecordField(name, if ft != nil: ft else: newId("any"))
        if not p.match(tkComma): break
      p.expect(tkRBrace, "expected '}' to close record")
      base = newRecordType(fields)
    of "union":
      p.advance()
      p.expect(tkLBrace, "expected '{' after union")
      var fields: seq[Node] = @[]
      while not p.check(tkRBrace):
        var name = ""
        if p.check(tkIdent):
          name = p.advance().value
          p.expect(tkColon, "expected ':' after union field name")
        let ft = p.parseType()
        fields.add newUnionField(name, if ft != nil: ft else: newId("any"))
        if not p.match(tkComma): break
      p.expect(tkRBrace, "expected '}' to close union")
      base = newUnionType(fields)
    of "enum":
      p.advance()
      p.expect(tkLBrace, "expected '{' after enum")
      var fields: seq[Node] = @[]
      while not p.check(tkRBrace):
        let name = p.advance().value
        var value: Node = nil
        if p.match(tkAssign):
          value = p.parseExpr()
        fields.add newEnumField(name, value)
        if not p.match(tkComma): break
      p.expect(tkRBrace, "expected '}' to close enum")
      base = newEnumType(fields)
    of "array":
      p.advance()
      p.expect(tkLParen, "expected '(' after array")
      var subtype: Node = nil
      if not p.check(tkRParen):
        subtype = p.parseType()
      var size: Node = nil
      if p.match(tkComma):
        size = p.parseExpr()
      p.expect(tkRParen, "expected ')' after array type")
      base = newArrayType(subtype, size)
    of "pointer":
      p.advance()
      p.expect(tkLParen, "expected '(' after pointer")
      var subtype: Node = nil
      if not p.check(tkRParen):
        subtype = p.parseType()
      p.expect(tkRParen, "expected ')' after pointer type")
      base = newPointerType(subtype)
    of "function":
      p.advance()
      p.expect(tkLParen, "expected '(' after function type")
      var args: seq[Node] = @[]
      if not p.check(tkRParen):
        while true:
          let id = p.advance().value
          let atype = if p.match(tkColon): p.parseType() else: nil
          args.add newIdDecl(id, atype)
          if not p.match(tkComma): break
      p.expect(tkRParen, "expected ')' after function type args")
      var returns: seq[Node] = @[]
      if p.match(tkColon):
        if p.check(tkLParen):
          p.advance()
          if not p.check(tkRParen):
            while true:
              let rt = p.parseType()
              if rt != nil: returns.add rt
              if not p.match(tkComma): break
          p.expect(tkRParen, "expected ')' after function type returns")
        else:
          let rt = p.parseType()
          if rt != nil: returns.add rt
      base = newFuncType(args, returns)
    else:
      p.advance()
      base = newId(t.value)
  else:
    return nil
  if base == nil: return nil
  var types: seq[Node] = @[base]
  while p.match(tkBor):
    let nxt = p.parseType()
    if nxt != nil: types.add nxt
  if types.len > 1:
    return newVariantType(types)
  return base

proc parseOptionalType*(p: var Parser): Node =
  ## Optional-type syntax (`T?`) is not accepted by the reference in type
  ## positions, so this is a plain type parse.
  return p.parseType()## Expression parsing: primary, postfix, unary, binary precedence climbing.

proc parseExpr*(p: var Parser): Node =
  p.parseOr()

# --- primary ----------------------------------------------------------------

proc parseFunctionLiteral*(p: var Parser): Node =
  p.expectKeyword("function", "expected 'function'")
  var name: Node = nil
  if p.check(tkIdent) and p.peek(1).kind == tkColon:
    let tname = p.advance().value
    p.advance()
    let mname = p.advance().value
    name = newColonIndex(mname, newId(tname))
  p.expect(tkLParen, "expected '(' after function")
  var args: seq[Node] = @[]
  if not p.check(tkRParen):
    while true:
      if p.check(tkDots):
        args.add newVarargsType("varautos")
        p.advance()
      else:
        let id = p.advance().value
        let atype = if p.match(tkColon): p.parseType() else: nil
        args.add newIdDecl(id, atype)
      if not p.match(tkComma): break
  p.expect(tkRParen, "expected ')' after function parameters")
  var returns: seq[Node] = @[]
  if p.match(tkColon):
    if p.check(tkLParen):
      p.advance()
      if not p.check(tkRParen):
        while true:
          let rt = p.parseType()
          if rt != nil: returns.add rt
          if not p.match(tkComma): break
      p.expect(tkRParen, "expected ')' after return types")
    else:
      let rt = p.parseType()
      if rt != nil: returns.add rt
  let anns = p.parseAnnotations()
  let body = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close function")
  return newFunction(args, returns, anns, body)

proc parseTable*(p: var Parser): Node =
  p.expect(tkLBrace, "expected '{'")
  var elems: seq[Node] = @[]
  while not p.check(tkRBrace):
    if p.check(tkLBrack):
      p.advance()
      let key = p.parseExpr()
      p.expect(tkRBrack, "expected ']' after table key")
      p.expect(tkAssign, "expected '=' after table key")
      let val = p.parseExpr()
      elems.add newPairExpr(key, val)
    elif p.check(tkIdent) and p.peek(1).kind == tkAssign:
      let name = p.advance().value
      p.advance()
      let val = p.parseExpr()
      elems.add newPair(name, val)
    elif p.check(tkString) and p.peek(1).kind == tkAssign:
      let key = p.advance().value
      p.advance()
      let val = p.parseExpr()
      elems.add newPair(key, val)
    else:
      elems.add p.parseExpr()
    if not p.match(tkComma): break
  p.expect(tkRBrace, "expected '}' to close table")
  return newInitList(elems)

proc parsePrimary*(p: var Parser): Node =
  let t = p.tok
  case t.kind
  of tkNumber:
    p.advance()
    return newNumber(t.value)
  of tkString:
    p.advance()
    return newString(t.value)
  of tkLString:
    p.advance()
    return newString(t.value, "lstring")
  of tkDots:
    p.advance()
    return newVarargs()
  of tkIdent:
    p.advance()
    return newId(t.value)
  of tkLParen:
    p.advance()
    let e = p.parseExpr()
    p.expect(tkRParen, "expected ')' after expression")
    return newParen(e)
  of tkLBrace:
    return p.parseTable()
  of tkAt:
    let ty = p.parseType()
    if ty != nil:
      return newType(ty)
    raise ParseError(loc: t.loc, msg: "expected type after '@'")
  of tkKeyword:
    case t.value
    of "true":
      p.advance()
      return newBoolean(true)
    of "false":
      p.advance()
      return newBoolean(false)
    of "nil":
      p.advance()
      return newNil()
    of "nilptr":
      p.advance()
      return newNilptr()
    of "function":
      return p.parseFunctionLiteral()
    else:
      raise ParseError(loc: t.loc, msg: "unexpected keyword '" & t.value & "'")
  else:
    raise ParseError(loc: t.loc, msg: "unexpected token")

# --- postfix (indexing / calls) --------------------------------------------

proc parsePostfix*(p: var Parser): Node =
  var base = p.parsePrimary()
  while true:
    if p.match(tkDot):
      let name = p.advance().value
      base = newDotIndex(name, base)
    elif p.match(tkColon):
      let name = p.advance().value
      if p.check(tkLParen):
        var args: seq[Node] = @[]
        p.advance()
        if not p.check(tkRParen):
          while true:
            if p.check(tkDots):
              args.add newVarargs()
              p.advance()
            else:
              args.add p.parseExpr()
            if not p.match(tkComma): break
        p.expect(tkRParen, "expected ')' after method arguments")
        base = newCallMethod(name, args, base)
      else:
        base = newColonIndex(name, base)
    elif p.match(tkLBrack):
      let key = p.parseExpr()
      p.expect(tkRBrack, "expected ']' after index")
      base = newKeyIndex(key, base)
    elif p.check(tkLParen):
      let caller = base
      var args: seq[Node] = @[]
      p.advance()
      if not p.check(tkRParen):
        while true:
          if p.check(tkDots):
            args.add newVarargs()
            p.advance()
          else:
            args.add p.parseExpr()
          if not p.match(tkComma): break
      p.expect(tkRParen, "expected ')' after arguments")
      base = newCall(args, caller)
    elif p.check(tkString):
      let s = p.advance().value
      base = newCall(@[newString(s)], base)
    else:
      break
  return base

# --- unary / power ----------------------------------------------------------

proc parseUnary*(p: var Parser): Node =
  let t = p.tok
  if t.kind == tkMinus:
    p.advance()
    return newUnaryOp("-", p.parseUnary())
  if t.kind == tkHash:
    p.advance()
    return newUnaryOp("#", p.parseUnary())
  if t.kind == tkKeyword and t.value == "not":
    p.advance()
    return newUnaryOp("not", p.parseUnary())
  if t.kind == tkBxor:
    p.advance()
    return newUnaryOp("~", p.parseUnary())
  return p.parsePower()

proc parsePower*(p: var Parser): Node =
  let base = p.parsePostfix()
  if p.check(tkPow):
    p.advance()
    let rhs = p.parseUnary()
    return newBinaryOp(base, "^", rhs)
  return base

# --- binary precedence chain (low to high) ---------------------------------

proc parseMul*(p: var Parser): Node =
  var left = p.parseUnary()
  while true:
    let t = p.tok
    if t.kind == tkMul: p.advance(); left = newBinaryOp(left, "*", p.parseUnary())
    elif t.kind == tkDiv: p.advance(); left = newBinaryOp(left, "/", p.parseUnary())
    elif t.kind == tkIdiv: p.advance(); left = newBinaryOp(left, "//", p.parseUnary())
    elif t.kind == tkMod: p.advance(); left = newBinaryOp(left, "%", p.parseUnary())
    else: break
  return left

proc parseAdd*(p: var Parser): Node =
  var left = p.parseMul()
  while true:
    let t = p.tok
    if t.kind == tkPlus: p.advance(); left = newBinaryOp(left, "+", p.parseMul())
    elif t.kind == tkMinus: p.advance(); left = newBinaryOp(left, "-", p.parseMul())
    else: break
  return left

proc parseConcat*(p: var Parser): Node =
  var left = p.parseAdd()
  while p.match(tkConcat):
    left = newBinaryOp(left, "..", p.parseAdd())
  return left

proc parseShift*(p: var Parser): Node =
  var left = p.parseConcat()
  while true:
    let t = p.tok
    if t.kind == tkShl: p.advance(); left = newBinaryOp(left, "<<", p.parseConcat())
    elif t.kind == tkShr: p.advance(); left = newBinaryOp(left, ">>", p.parseConcat())
    else: break
  return left

proc parseBand*(p: var Parser): Node =
  var left = p.parseShift()
  while p.match(tkBand):
    left = newBinaryOp(left, "&", p.parseShift())
  return left

proc parseBxor*(p: var Parser): Node =
  var left = p.parseBand()
  while p.match(tkBxor):
    left = newBinaryOp(left, "~", p.parseBand())
  return left

proc parseBor*(p: var Parser): Node =
  var left = p.parseBxor()
  while p.match(tkBor):
    left = newBinaryOp(left, "|", p.parseBxor())
  return left

proc parseComparison*(p: var Parser): Node =
  var left = p.parseBor()
  while true:
    let t = p.tok
    case t.kind
    of tkLt: p.advance(); left = newBinaryOp(left, "<", p.parseBor())
    of tkGt: p.advance(); left = newBinaryOp(left, ">", p.parseBor())
    of tkLe: p.advance(); left = newBinaryOp(left, "<=", p.parseBor())
    of tkGe: p.advance(); left = newBinaryOp(left, ">=", p.parseBor())
    of tkEq: p.advance(); left = newBinaryOp(left, "==", p.parseBor())
    of tkNe: p.advance(); left = newBinaryOp(left, "~=", p.parseBor())
    else: break
  return left

proc parseAnd*(p: var Parser): Node =
  var left = p.parseComparison()
  while p.matchKeyword("and"):
    left = newBinaryOp(left, "and", p.parseComparison())
  return left

proc parseOr*(p: var Parser): Node =
  var left = p.parseAnd()
  while p.matchKeyword("or"):
    left = newBinaryOp(left, "or", p.parseAnd())
  return left## Statement parsing, block, entry point, dump and self-test.

proc isStmtEnd*(p: Parser): bool =
  let t = p.tok
  if t.kind == tkEof: return true
  if t.kind == tkSemi: return true
  if t.kind == tkKeyword:
    case t.value
    of "end", "else", "elseif", "until": return true
    else: discard
  if t.kind == tkColonColon: return true
  return false

proc parseBlock*(p: var Parser): Node =
  var stmts: seq[Node] = @[]
  while true:
    let t = p.tok
    if t.kind == tkEof: break
    if t.kind == tkKeyword and (t.value == "end" or t.value == "else" or t.value == "elseif" or t.value == "until"):
      break
    if t.kind == tkColonColon: break
    let s = p.parseStatement()
    if s != nil: stmts.add s
    if p.match(tkSemi): discard
  return newBlock(stmts)

proc parseIdDecl*(p: var Parser): Node =
  let name = p.advance().value
  var typeexpr: Node = nil
  if p.match(tkColon):
    typeexpr = p.parseOptionalType()
  return newIdDecl(name, typeexpr)

proc parseFuncName*(p: var Parser): Node =
  var name = newId(p.advance().value)
  while true:
    if p.match(tkDot):
      name = newDotIndex(p.advance().value, name)
    elif p.match(tkColon):
      name = newColonIndex(p.advance().value, name)
    else:
      break
  return name

proc parseFuncDef*(p: var Parser, scope: string): Node =
  p.expectKeyword("function", "expected 'function'")
  var name = p.parseFuncName()
  if scope == "local":
    name = newIdDecl(name.str, nil)
  p.expect(tkLParen, "expected '(' after function name")
  var args: seq[Node] = @[]
  if not p.check(tkRParen):
    while true:
      if p.check(tkDots):
        args.add newVarargsType("varautos")
        p.advance()
      else:
        args.add p.parseIdDecl()
      if not p.match(tkComma): break
  p.expect(tkRParen, "expected ')' after function parameters")
  var returns: seq[Node] = @[]
  if p.match(tkColon):
    if p.check(tkLParen):
      p.advance()
      if not p.check(tkRParen):
        while true:
          let rt = p.parseType()
          if rt != nil: returns.add rt
          if not p.match(tkComma): break
      p.expect(tkRParen, "expected ')' after return types")
    else:
      let rt = p.parseType()
      if rt != nil: returns.add rt
  let anns = p.parseAnnotations()
  let body = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close function")
  return newFuncDef(scope, name, args, returns, anns, body)

proc parseVarDecl*(p: var Parser, scope: string): Node =
  p.advance()
  var iddecls: seq[Node] = @[p.parseIdDecl()]
  while p.match(tkComma):
    iddecls.add p.parseIdDecl()
  var inits: seq[Node] = @[]
  if p.match(tkAssign):
    inits.add p.parseExpr()
    while p.match(tkComma):
      inits.add p.parseExpr()
  return newVarDecl(scope, iddecls, inits)

proc parseIf*(p: var Parser): Node =
  p.advance()
  let cond = p.parseExpr()
  p.expectKeyword("then", "expected 'then' after if condition")
  let body = p.parseBlock()
  var branches: seq[tuple[cond: Node, body: Node]] = @[(cond, body)]
  while p.matchKeyword("elseif"):
    let ec = p.parseExpr()
    p.expectKeyword("then", "expected 'then' after elseif condition")
    branches.add (ec, p.parseBlock())
  var elseBlock: Node = nil
  if p.matchKeyword("else"):
    elseBlock = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close if")
  return newIf(branches, elseBlock)

proc parseWhile*(p: var Parser): Node =
  p.advance()
  let cond = p.parseExpr()
  p.expectKeyword("do", "expected 'do' after while condition")
  let body = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close while")
  return newWhile(cond, body)

proc parseRepeat*(p: var Parser): Node =
  p.advance()
  let body = p.parseBlock()
  p.expectKeyword("until", "expected 'until'")
  let cond = p.parseExpr()
  return newRepeat(body, cond)

proc parseFor*(p: var Parser): Node =
  p.advance()
  let first = p.advance().value
  if p.check(tkAssign):
    p.advance()
    let beginv = p.parseExpr()
    p.expect(tkComma, "expected ',' in for range")
    let endv = p.parseExpr()
    let step = if p.match(tkComma): p.parseExpr() else: nil
    p.expectKeyword("do", "expected 'do' in for")
    let body = p.parseBlock()
    p.expectKeyword("end", "expected 'end' to close for")
    return newForNum(newIdDecl(first), beginv, "", endv, step, body)
  var iddecls: seq[Node] = @[newIdDecl(first)]
  while p.match(tkComma):
    iddecls.add newIdDecl(p.advance().value)
  p.expectKeyword("in", "expected 'in' in for")
  var exprs: seq[Node] = @[p.parseExpr()]
  while p.match(tkComma):
    exprs.add p.parseExpr()
  p.expectKeyword("do", "expected 'do' in for")
  let body = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close for")
  return newForIn(iddecls, exprs, body)

proc parseReturn*(p: var Parser): Node =
  p.advance()
  var exprs: seq[Node] = @[]
  if not p.isStmtEnd():
    exprs.add p.parseExpr()
    while p.match(tkComma):
      if p.isStmtEnd(): break
      exprs.add p.parseExpr()
  return newReturn(exprs)

# --- preprocessor directives -----------------------------------------------
##
## A `#`-line at statement position is a preprocessor directive, not the `len`
## unary operator.  The M6 preprocessor pass consumes `nkDirective` nodes, so
## the parser must emit them; previously `parseUnary` swallowed `#` as `len`
## and the preprocessor received nothing to act on (backlog: parser directive
## gap).  An unrecognized `#` (e.g. a bare `#t` length expression) still falls
## through to `len` via parseUnary.

proc isDirectiveName*(s: string): bool =
  ## Whether `s` is a recognized preprocessor directive name.
  case s
  of "define", "undef", "if", "ifdef", "ifndef", "elif", "else", "endif",
      "error", "include", "pragma", "line":
    true
  else:
    false

proc restOfLine*(p: Parser): string =
  ## Capture the raw source text of the current statement line, from the
  ## current token up to (not including) the terminating newline.  The M6
  ## preprocessor stores directive bodies as raw strings and re-parses them
  ## on demand, so we capture text rather than an AST subtree.  A trailing
  ## line comment (`-- ...`) is trimmed.
  let start = p.tok.loc.offset
  let nl = p.source.find('\n', start)
  let raw = if nl < 0: p.source[start .. ^1] else: p.source[start .. nl - 1]
  let dc = raw.find("--")
  if dc >= 0: result = raw[0 .. dc - 1]
  else: result = raw

proc parseDirective*(p: var Parser): Node =
  ## Parse a `#`-line at statement position into an `nkDirective` node.
  ## Dispatched from `parseStatement` only when `#` is followed by a known
  ## directive name; see `isDirectiveName`.
  let line = p.tok.loc.line
  p.expect(tkHash, "expected '#' at start of preprocessor directive")
  let name = p.advance().value
  var children: seq[Node] = @[]
  case name
  of "define":
    let macroName = p.advance()
    children.add newId(macroName.value)
    if p.check(tkLParen):
      discard p.advance()
      while not p.check(tkRParen) and not p.check(tkEof):
        if p.check(tkComma):
          discard p.advance()
        else:
          children.add newId(p.advance().value)
      discard p.match(tkRParen)
    children.add newString(p.restOfLine())
  of "undef", "ifdef", "ifndef":
    children.add newId(p.advance().value)
  of "if", "elif", "error":
    children.add newString(p.restOfLine())
  of "include":
    if p.check(tkString):
      children.add newString(p.advance().value)
    else:
      children.add newString(p.restOfLine())
  of "else", "endif", "pragma", "line":
    discard
  else:
    discard
  # Newlines are whitespace and not emitted as tokens, so we cannot stop on a
  # semicolon: advance past every token that still lies on the directive's
  # source line.  The directive body was captured as raw text above.
  while p.pos < p.tokens.len and p.tokens[p.pos].kind != tkEof and
        p.tokens[p.pos].loc.line == line:
    inc p.pos
  return newDirective(name, children)

proc parsePreprocess*(p: var Parser): Node =
  ## Parse a `##`-line at statement position into an `nkPreprocess` node.
  ##
  ## The node's `str` is the raw source text of the line *after* `##` (e.g.
  ## `## x = 2` -> `nkPreprocess " x = 2"`), exactly the shape the reference
  ## interpreter's `--print-ast` emits.  The M6 preprocessor feeds this text to
  ## the embedded Lua interpreter at compile time.  A trailing line comment
  ## (`-- ...`) is trimmed, matching `restOfLine`.
  let hashTok = p.advance()             ## consume `##`
  let start = hashTok.loc.offset + 2    ## text right after the `##` chars
  let nl = p.source.find('\n', start)
  let raw = if nl < 0: p.source[start .. ^1] else: p.source[start .. nl - 1]
  let dc = raw.find("--")
  let body = if dc >= 0: raw[0 .. dc - 1] else: raw
  let line = hashTok.loc.line
  # Newlines are whitespace and not emitted as tokens, so we cannot stop on a
  # semicolon: advance past every token that still lies on this line.  The
  # body was captured as raw text above.
  while p.pos < p.tokens.len and p.tokens[p.pos].kind != tkEof and
        p.tokens[p.pos].loc.line == line:
    inc p.pos
  return Node(kind: nkPreprocess, str: body)

proc parseStatement*(p: var Parser): Node =
  let t = p.tok
  if t.kind == tkHash:
    let nxt = p.peek(1)
    if (nxt.kind == tkIdent or nxt.kind == tkKeyword) and isDirectiveName(nxt.value):
      return p.parseDirective()
  if t.kind == tkDoubleHash:
    return p.parsePreprocess()
  if t.kind == tkColonColon:
    p.advance()
    let name = p.advance().value
    p.expect(tkColonColon, "expected '::' after label name")
    return newLabel(name)
  if t.kind == tkKeyword:
    case t.value
    of "local":
      if p.peek(1).kind == tkKeyword and p.peek(1).value == "function":
        discard p.advance()
        return p.parseFuncDef("local")
      return p.parseVarDecl("local")
    of "global": return p.parseVarDecl("global")
    of "function": return p.parseFuncDef("")
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "repeat": return p.parseRepeat()
    of "for": return p.parseFor()
    of "do":
      p.advance()
      let body = p.parseBlock()
      p.expectKeyword("end", "expected 'end' to close do")
      return newDo(body)
    of "return": return p.parseReturn()
    of "break":
      p.advance()
      return newBreak()
    of "continue":
      p.advance()
      return newContinue()
    of "defer":
      p.advance()
      let body = p.parseBlock()
      p.expectKeyword("end", "expected 'end' to close defer")
      return newDefer(body)
    of "goto":
      p.advance()
      let name = p.advance().value
      return newGoto(name)
    of "require":
      ## `require '<module>'` is a statement that loads another module.  The
      ## reference lowers it to a call on the builtin `require` (`require("name")`),
      ## so we emit an `nkCall` here -- the same shape `--print-ast` shows for the
      ## oracle -- and let the driver (compile.nim) do the resolution/compilation.
      p.advance()
      let mt = p.tok
      if mt.kind != tkString and mt.kind != tkLString:
        raise p.error("expected string module name after 'require'")
      discard p.advance()
      let lit = if mt.kind == tkLString: "lstring" else: "string"
      return newCall(@[newString(mt.value, lit)], newId("require"))
    else:
      discard
  let first = p.parseExpr()
  if p.check(tkComma) or p.check(tkAssign):
    var targets: seq[Node] = @[first]
    while p.match(tkComma):
      targets.add p.parseExpr()
    p.expect(tkAssign, "expected '=' in assignment")
    var values: seq[Node] = @[]
    values.add p.parseExpr()
    while p.match(tkComma):
      values.add p.parseExpr()
    return newAssign(targets, values)
  return first

proc parse*(source: string, path: string = ""): Node =
  var p = newParser(source, path)
  try:
    let body = p.parseBlock()
    discard p.expect(tkEof, "unexpected token after end of program")
    return body
  except ParseError as e:
    echo path & ":" & $e.loc.line & ":" & $e.loc.col & ": error: " & e.msg
    return nil

proc quoteStr*(s: string): string =
  ## Quote a string scalar for the dump. Long-string literals `[[...]]` have
  ## their delimiters stripped and are re-quoted; already-quoted scalars and
  ## bare identifiers are wrapped in double quotes.
  var v = s
  if v.len >= 4 and v.startsWith("[[") and v.endsWith("]]"):
    v = v[2 ..< v.len - 2]
    return "\"" & v & "\""
  if v.len >= 2 and v.startsWith("\"") and v.endsWith("\""):
    return v
  return "\"" & v & "\""

proc binaryOpName*(op: string): string =
  case op
  of "+": "add"
  of "-": "sub"
  of "*": "mul"
  of "/": "div"
  of "//": "idiv"
  of "%": "mod"
  of "^": "pow"
  of "..": "concat"
  of "<<": "shl"
  of ">>": "shr"
  of "&": "band"
  of "|": "bor"
  of "~": "bxor"
  of "<": "lt"
  of ">": "gt"
  of "<=": "le"
  of ">=": "ge"
  of "==": "eq"
  of "~=": "ne"
  of "and": "and"
  of "or": "or"
  else: op

proc unaryOpName*(op: string): string =
  case op
  of "-": "unm"
  of "#": "len"
  of "not": "not"
  of "~": "bnot"
  else: op

proc dump*(n: Node, indent = 0): string =
  if n == nil: return "(nil)"
  var s = ""
  for _ in 0..<indent: s.add "  "
  case n.kind:
  of nkDoExpr:      s.add "nkDoExpr"
  of nkPreprocess:  s.add "nkPreprocess " & quoteStr(n.str)
  of nkPreprocessExpr: s.add "nkPreprocessExpr " & quoteStr(n.str)
  of nkPreprocessName: s.add "nkPreprocessName " & quoteStr(n.str)
  of nkBlock:       s.add "nkBlock"
  of nkVarDecl:     s.add "nkVarDecl " & quoteStr(n.str)
  of nkIdDecl:      s.add "nkIdDecl " & quoteStr(n.str)
  of nkId:          s.add "nkId " & quoteStr(n.str)
  of nkNumber:      s.add "nkNumber " & quoteStr(n.str)
  of nkString:      s.add "nkString " & quoteStr(n.str)
  of nkBoolean:     s.add "nkBoolean " & (if n.boolVal: "true" else: "false")
  of nkNil:         s.add "nkNil"
  of nkNilptr:      s.add "nkNilptr"
  of nkVarargs:     s.add "nkVarargs"
  of nkPair:        s.add "nkPair " & quoteStr(n.str)
  of nkInitList:    s.add "nkInitList"
  of nkDotIndex:    s.add "nkDotIndex " & quoteStr(n.str)
  of nkColonIndex:  s.add "nkColonIndex " & quoteStr(n.str)
  of nkKeyIndex:    s.add "nkKeyIndex"
  of nkAnnotation:  s.add "nkAnnotation " & quoteStr(n.str)
  of nkParen:       s.add "nkParen"
  of nkType:        s.add "nkType"
  of nkVarargsType: s.add "nkVarargsType " & quoteStr(n.str)
  of nkFuncType:    s.add "nkFuncType"
  of nkRecordField: s.add "nkRecordField " & quoteStr(n.str)
  of nkRecordType:  s.add "nkRecordType"
  of nkUnionField:  s.add "nkUnionField " & quoteStr(n.str)
  of nkUnionType:   s.add "nkUnionType"
  of nkEnumField:   s.add "nkEnumField " & quoteStr(n.str)
  of nkEnumType:    s.add "nkEnumType false"
  of nkArrayType:   s.add "nkArrayType"
  of nkPointerType: s.add "nkPointerType"
  of nkOptionalType: s.add "nkOptionalType"
  of nkGenericType: s.add "nkGenericType " & quoteStr(n.str)
  of nkVariantType: s.add "nkVariantType"
  of nkFunction:    s.add "nkFunction"
  of nkCall:        s.add "nkCall"
  of nkCallMethod:  s.add "nkCallMethod " & quoteStr(n.str)
  of nkUnaryOp:     s.add "nkUnaryOp " & unaryOpName(n.str)
  of nkBinaryOp:    s.add "nkBinaryOp"
  of nkReturn:      s.add "nkReturn"
  of nkIf:          s.add "nkIf"
  of nkSwitch:      s.add "nkSwitch"
  of nkDo:          s.add "nkDo"
  of nkDefer:       s.add "nkDefer"
  of nkWhile:       s.add "nkWhile"
  of nkRepeat:      s.add "nkRepeat"
  of nkForNum:      s.add "nkForNum"
  of nkForIn:       s.add "nkForIn"
  of nkBreak:       s.add "nkBreak"
  of nkContinue:    s.add "nkContinue"
  of nkLabel:       s.add "nkLabel " & quoteStr(n.str)
  of nkGoto:        s.add "nkGoto " & quoteStr(n.str)
  of nkAssign:      s.add "nkAssign"
  of nkFuncDef:
    if n.str == "": s.add "nkFuncDef false"
    else: s.add "nkFuncDef " & quoteStr(n.str)
  of nkDirective:   s.add "nkDirective " & quoteStr(n.str)
  s.add "\n"
  let ind = "  ".repeat(indent)
  s.add ind & "{\n"
  if n.kind == nkBinaryOp and n.children.len == 2:
    s.add dump(n.children[0], indent + 1)
    s.add "  ".repeat(indent + 1) & "nkBinaryOp " & binaryOpName(n.str) & "\n"
    s.add dump(n.children[1], indent + 1)
  else:
    for c in n.children:
      s.add dump(c, indent + 1)
  s.add ind & "}\n"
  return s

when isMainModule:
  let tests = [
    "local x = 1\nprint(x)\n",
    "local a, b = 1, 2\n",
    "for i = 1, 10 do\n  local t = a.b:c(1)\nend\n",
    "local f = function(x) return x + 1 end\n",
    "local s = [[hello\nworld]]\n",
    "function foo(a, b)\n  return a + b\nend\n",
    "local x: integer = 0\n",
    "if a > 0 then\n  x = 1\nelseif a == 0 then\n  x = 0\nelse\n  x = -1\nend\n",
    "local t = {1, 2, foo = 3}\n",
    "defer\n  print(1)\nend\n",
  ]
  for src in tests:
    let ast = parse(src)
    if ast == nil:
      echo "FAIL: ", repr(src)
    else:
      echo "OK: ", repr(src)

  # nilptr keyword must emit nkNilptr, not nkId "nilptr"
  let npAst = parse("local p = nilptr")
  doAssert npAst != nil, "parse(local p = nilptr) failed"
  let npVar = npAst.children[0]
  doAssert npVar.kind == nkVarDecl, "expected nkVarDecl, got " & $npVar.kind
  let npInit = npVar.children[^1]
  doAssert npInit.kind == nkNilptr, "nilptr must parse as nkNilptr, got " & $npInit.kind
  doAssert npInit.kind != nkId, "nilptr must NOT be nkId"
  echo "nilptr parses as nkNilptr OK"
  echo "parser.nim self-test done"