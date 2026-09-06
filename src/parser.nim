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
  Parser* = object
    tokens*: seq[Token]
    pos*: int
    source*: string
    path*: string
    forInCount*: int          ## number of `for ... in` iterator forms lowered so far

## Type keywords that may appear as a static-method receiver (`string.copy(s)`).
## Only the concrete primitive value types are listed: a type keyword is accepted
## as an expression primary *solely* when immediately followed by `.` (so the
## `parsePostfix` loop can build the dot-index); bare type keywords remain
## rejected as general expression primaries.
proc isTypeKeyword*(s: string): bool =
  case s
  of "integer", "number", "string", "boolean", "isize", "usize",
      "cchar", "cshort", "cint", "clong", "cfloat", "cdouble",
      "auto", "void", "type", "any":
    result = true

proc newParser*(source: string, path: string = ""): Parser =
  Parser(tokens: tokenize(source, path), pos: 0, source: source, path: path,
         forInCount: 0)

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

proc parseAnnotationPart(s: string): Node =
  ## Parse a single comma-less annotation part: `name`, `name'value'`, or
  ## `name=value`.  Returns an nkAnnotation whose `str` is the name and whose
  ## children carry the value (if any).  Returns nil for empty input.
  var s = s.strip()
  if s == "": return nil
  let qpos = s.find('\'')
  if qpos >= 0:
    let name = s[0 ..< qpos].strip()
    let rest = s.substr(qpos + 1)
    let endq = rest.find('\'')
    let value = if endq >= 0: rest[0 ..< endq] else: rest
    return newAnnotation(name, @[newId(value)])
  let eq = s.find('=')
  if eq >= 0:
    let k = s[0 ..< eq].strip()
    let v = s.substr(eq + 1).strip()
    return newAnnotation(k, @[newId(v)])
  return newAnnotation(s, @[])

proc parseAnnotation*(p: var Parser): seq[Node] =
  ## Oracle PEG: `annots <-| '<' @Annotation (',' @Annotation)* @'>'` -- each
  ## comma-separated part is its OWN annotation node (so `<cimport,cinclude
  ## '<stdio.h>'>` yields a `cimport` node and a `cinclude` node, not one bundled
  ## node).  Commas inside a quoted `name'value'` do not split.
  let t = p.advance()
  let text = t.value[1 ..< t.value.len - 1]
  var nodes: seq[Node] = @[]
  var i = 0
  var start = 0
  var quote = '\0'
  while i <= text.len:
    if i < text.len:
      let c = text[i]
      if quote != '\0':
        if c == '\\': inc i, 2; continue
        if c == quote: quote = '\0'
        inc i; continue
      if c == '"' or c == '\'': quote = c
      if c == ',':
        let n = parseAnnotationPart(text[start ..< i])
        if n != nil: nodes.add n
        start = i + 1
      inc i
    else:
      let n = parseAnnotationPart(text[start ..< i])
      if n != nil: nodes.add n
      break
  return nodes

proc parseAnnotations*(p: var Parser): seq[Node] =
  var anns: seq[Node] = @[]
  while p.check(tkAnnotation):
    anns &= p.parseAnnotation()
  return anns

# --- type expressions -------------------------------------------------------

proc parsePrimary*(p: var Parser): Node

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
      var primtype: Node = nil
      if p.match(tkLParen):
        primtype = p.parseType()
        p.expect(tkRParen, "expected ')' after enum primitive type")
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
      base = newEnumType(fields, primtype)
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
      if p.check(tkLParen):
        p.advance()
        var subtype: Node = nil
        if not p.check(tkRParen):
          subtype = p.parseType()
        p.expect(tkRParen, "expected ')' after pointer type")
        base = newPointerType(subtype)
      else:
        ## bare `pointer` is the generic pointer type; the reference accepts it
        ## bare, e.g. `local function f(a: pointer)`. It lowers to a pointer
        ## type with no element subtype (the analyzer treats a missing subtype
        ## as `void`, which is what the reference's `primtypes.pointer` is).
        base = newPointerType(nil)
    of "function":
      p.advance()
      p.expect(tkLParen, "expected '(' after function type")
      var args: seq[Node] = @[]
      if not p.check(tkRParen):
        while true:
          # A function-type argument is either a named parameter
          # (`name: type`) or an unnamed type argument (just `type`, e.g.
          # `function(*minicoro.Coro): void`).  Distinguish by whether an
          # identifier is immediately followed by `:`.
          if p.tok.kind == tkIdent and p.peek(1).kind == tkColon:
            let id = p.advance().value
            discard p.advance()  # consume `:`
            let atype = p.parseType()
            args.add newIdDecl(id, if atype != nil: atype else: newId("any"))
          else:
            let atype = p.parseType()
            if atype != nil: args.add atype
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
  of tkLBrack:
    # [size]type -- fixed-size array type. Multiple [...] prefix the base type,
    # associating right-to-left: [H][W]boolean == [H]([W]boolean).
    var sizes: seq[Node] = @[]
    while p.check(tkLBrack):
      p.advance()
      sizes.add p.parseExpr()
      p.expect(tkRBrack, "expected ']' after array size")
    let sub = p.parseType()
    if sub == nil:
      raise ParseError(loc: t.loc, msg: "expected type after ']'")
    base = sub
    for sz in countdown(sizes.len - 1, 0):
      base = newArrayType(base, sizes[sz])
  of tkHashLBrack:
    # `#[expr]#` compile-time splice used as a type, e.g.
    # `(@#[integer]#)(x)`.  The splice's raw inner text is captured by
    # `parsePrimary` as an `nkPreprocessExpr`; wrap it as a type node.
    let splice = p.parsePrimary()
    base = if splice != nil: newType(splice) else: nil
  of tkAt:
    # `@` is a type splice / cast in *expression* position (see parsePrimary),
    # but the reference rejects it at the start of a type expression with
    # "expected a type expression" -- `@pointer`, `@integer` and even
    # `@#[integer]#` are all invalid as annotation types.  Raise rather than
    # return nil so the tokens do not leak out and get reparsed as a
    # dangling expression (which produced a spurious MATCH-vs-DIFF on the
    # `@pointer[integer]` corpus case).
    raise ParseError(loc: t.loc, msg: "expected a type expression")
  else:
    return nil
  if base == nil: return nil
  # Dot-index type reference: `os.timedesc`, `primtypes.isize`.  A type
  # identifier followed by `.field` is a module/type reference, not a generic
  # type call -- build the dot-index chain before the generic-instantiation
  # check below so `facultative(os.timedesc)` parses the argument correctly.
  while p.check(tkDot):
    discard p.advance()
    let field = p.advance().value
    base = newDotIndex(field, base)
  # Generic type instantiation: `facultative(isize)`, `sequence(number)`.
  # A bare type identifier followed by `(...)` is a type-level call, producing
  # a `nkGenericType` node (the shape the reference `--print-ast` emits).
  if base.kind == nkId and p.check(tkLParen):
    discard p.advance()  ## consume '('
    var args: seq[Node] = @[]
    if not p.check(tkRParen):
      while true:
        let arg = p.parseType()
        if arg != nil: args.add arg
        if not p.match(tkComma): break
    p.expect(tkRParen, "expected ')' after generic type arguments")
    base = newGenericType(base.str, args)
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
      if p.check(tkDotDot):
        p.advance()
        var vkind = ""
        if p.match(tkColon):
          vkind = p.advance().value
        args.add newVarargsType(vkind)
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

proc parsePreprocessName*(p: var Parser): Node =
  ## Parse a `#|expr|#` splice placeholder into an `nkPreprocessName` node.
  ##
  ## The splice body is a Lua expression evaluated at compile time to produce
  ## the identifier name -- it is *not* restricted to a single identifier.  The
  ## reference accepts `#|'a'..i|#`, `#|("field"..tostring(i))|#` and so on, so
  ## capture the raw source text between the two `|` delimiters rather than
  ## demanding a single `tkIdent` token.  Returns `nil` when the current token
  ## sequence is not a `#|...|#` splice, so callers can fall back to ordinary
  ## identifier parsing.
  if p.tok.kind != tkHash: return nil
  if p.peek(1).kind != tkBor: return nil
  let openBor = p.peek(1)
  # Scan forward for the matching `|#` (a tkBor immediately followed by
  # tkHash).  The expression between the two `|` may be arbitrary Lua, so we
  # cannot require a single identifier here; capture the raw source text.
  var closePos = -1
  for i in (p.pos + 2) ..< p.tokens.len - 1:
    if p.tokens[i].kind == tkBor and p.tokens[i + 1].kind == tkHash:
      closePos = i
      break
  if closePos < 0: return nil
  let exprStart = openBor.loc.offset + 1
  let exprEnd = p.tokens[closePos].loc.offset
  let name = p.source[exprStart ..< exprEnd]
  discard p.advance()  ## `#`
  discard p.advance()  ## `|`
  while p.pos < closePos:
    discard p.advance()  ## expression tokens
  discard p.advance()  ## `|`
  discard p.advance()  ## `#`
  return Node(kind: nkPreprocessName, str: name)

proc stripLongBrackets(s: string): string   # forward, see below (parsePrimary use)

proc parsePrimary*(p: var Parser): Node =
  let t = p.tok
  case t.kind
  of tkNumber:
    p.advance()
    return newNumber(t.value)
  of tkString:
    p.advance()
    var litType = "string"
    # Typed string literal: `'A'_b`, `"x"_u8`.  The lexer emits the suffix as
    # a separate identifier; fold it onto the string when it is attached with
    # no whitespace in between (the oracle rejects a spaced `'A' _b`).
    if p.tok.kind == tkIdent and p.tok.value[0] == '_' and
       p.tok.loc.offset == t.loc.offset + t.loc.length:
      litType = p.tok.value
      p.advance()
    return newString(t.value, litType)
  of tkLString:
    p.advance()
    ## A Lua long string `[[\n...]]` carries its `[=`*`[` opener and `]`=`*`]`
    ## closer inside the token value.  Strip them (the shape the reference
    ## `--print-ast` emits) and drop the single leading newline that Lua
    ## semantics always removes right after the opener -- otherwise `[[\nfoo]]`
    ## round-trips as `[[\nfoo]]` instead of `foo` and `#s` counts the
    ## delimiters (23 where the oracle reports 18).
    let body = stripLongBrackets(t.value)
    let cleaned = if body.len > 0 and body[0] == '\n': body[1..^1] else: body
    return newString(cleaned, "lstring")
  of tkDotDot:
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
    p.advance()
    let ty = p.parseType()
    if ty != nil:
      return newType(ty)
    raise ParseError(loc: t.loc, msg: "expected type after '@'")
  of tkHashLBrack:
    ## `#[expr]#` compile-time splice.  The inner text is captured raw (the
    ## lexer folds string literals into single tokens, so a `]` inside a
    ## string is never a `tkRBrack`) and stored on an `nkPreprocessExpr` leaf
    ## for the preprocessor to evaluate at compile time.  Termination is the
    ## first `]` immediately followed by `#`; splices do not nest.
    let start = t.loc.offset + 2    ## text right after the `#[` chars
    p.advance()                      ## consume `#[`
    while p.pos < p.tokens.len and p.tokens[p.pos].kind != tkEof:
      let cur = p.tokens[p.pos]
      if cur.kind == tkRBrack and p.pos + 1 < p.tokens.len and
         p.tokens[p.pos + 1].kind == tkHash:
        break
      inc p.pos
    if p.pos >= p.tokens.len or p.tokens[p.pos].kind != tkRBrack:
      raise p.error("unterminated '#[' splice (expected ']#')")
    let rbrackTok = p.advance()      ## consume `]`
    discard p.expect(tkHash, "expected '#' after ']' to close splice")
    let inner = p.source[start ..< rbrackTok.loc.offset]
    return Node(kind: nkPreprocessExpr, str: inner)
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
    of "require":
      ## `require 'module'` may appear in expression position (e.g.
      ## `local s = require 'string'`); the reference lowers it to a call on
      ## the builtin `require`, so emit an `nkId` here and let `parsePostfix`
      ## build the call from the following string argument.
      p.advance()
      return newId("require")
    else:
      # A type keyword used as a static-method receiver, e.g.
      # `string.copy(s)`.  Accepted *only* when immediately followed by `.` so
      # the `parsePostfix` loop builds the dot-index.
      if isTypeKeyword(t.value) and p.peek(1).kind == tkDot:
        p.advance()
        return newId(t.value)
      # The oracle permits the type/annotation/declaration keywords as
      # ordinary identifiers (`local import = 42; print(import)`); the
      # control-flow, literal and operator keywords stay reserved.
      if isIdentKeyword(t.value):
        p.advance()
        return newId(t.value)
      raise ParseError(loc: t.loc, msg: "unexpected keyword '" & t.value & "'")
  else:
    raise ParseError(loc: t.loc, msg: "unexpected token")

# --- postfix (indexing / calls) --------------------------------------------

proc parsePostfix*(p: var Parser): Node =
  var base = p.parsePrimary()
  while true:
    if p.match(tkDot):
      let ppField = p.parsePreprocessName()
      if ppField != nil:
        ## Computed field access `v.#|expr|#`: the field name is not known at
        ## parse time, so carry the `nkPreprocessName` as `children[1]` (the
        ## base stays `children[0]`) with an empty `.str`; `replaceSplices`
        ## resolves the splice and sets `.str` before analysis reads it.
        base = Node(kind: nkDotIndex, str: "", children: @[base, ppField])
        base.isIndex = true
      else:
        let name = p.advance().value
        base = newDotIndex(name, base)
    elif p.match(tkColon):
      let name = p.advance().value
      if p.check(tkLParen):
        var args: seq[Node] = @[]
        p.advance()
        if not p.check(tkRParen):
          while true:
            if p.check(tkDotDot):
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
    elif p.check(tkLBrace):
      # Record/enum constructor: `Rect{ x = 1, y = 2 }` -> Call(InitList, Rect)
      let init = p.parseTable()
      base = newCall(@[init], base)
    elif p.check(tkLParen):
      let caller = base
      var args: seq[Node] = @[]
      p.advance()
      if not p.check(tkRParen):
        while true:
          if p.check(tkDotDot):
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
    # `#` is the `len` operator, but `#|name|#` is a preprocessor splice
    # placeholder that can appear in expression position.  Check for the
    # splice first; if it is not a splice, treat `#` as `len`.
    let pp = p.parsePreprocessName()
    if pp != nil:
      return Node(kind: nkId, str: "", children: @[pp])
    p.advance()
    return newUnaryOp("#", p.parseUnary())
  if t.kind == tkKeyword and t.value == "not":
    p.advance()
    return newUnaryOp("not", p.parseUnary())
  if t.kind == tkBxor:
    p.advance()
    return newUnaryOp("~", p.parseUnary())
  if t.kind == tkBand:
    ## `&` is address-of (`ref`) when it prefixes an expression; the same token
    ## is the bitwise `band` operator between expressions (see parseBand). The
    ## reference grammar treats one `&` token as both `opunary`->'ref' and
    ## `opband`->'band', disambiguated by position.
    p.advance()
    return newUnaryOp("&", p.parseUnary())
  if t.kind == tkIdent and t.value == "$":
    ## `$` is the dereference operator. The lexer has no dedicated token for
    ## it (it falls through to tkIdent with value "$"); nelua identifiers
    ## cannot contain '$', so this is unambiguous.
    p.advance()
    return newUnaryOp("deref", p.parseUnary())
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
    elif t.kind == tkIdiv:
      # The lexer folds `///` (truncate division) into `tkIdiv` + `tkDiv`
      # because it has no dedicated token.  Recognize the pair here so the
      # oracle's `///` operator (AST `BinaryOp .. "tdiv"`) is accepted.
      if p.peek(1).kind == tkDiv:
        discard p.advance()  # consume `//`
        discard p.advance()  # consume the trailing `/`
        left = newBinaryOp(left, "tdiv", p.parseUnary())
      else:
        p.advance(); left = newBinaryOp(left, "//", p.parseUnary())
    elif t.kind == tkMod:
      # The lexer folds `%%%` (truncate modulo) into three `tkMod` tokens.
      # Recognize the triple so the oracle's `%%%` operator (AST
      # `BinaryOp .. "tmod"`) is accepted.
      if p.peek(1).kind == tkMod and p.peek(2).kind == tkMod:
        discard p.advance(); discard p.advance(); discard p.advance()
        left = newBinaryOp(left, "tmod", p.parseUnary())
      else:
        p.advance(); left = newBinaryOp(left, "%", p.parseUnary())
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
    elif t.kind == tkShr:
      # The lexer folds `>>>` (arithmetic shift right) into `tkShr` + `tkGt`.
      # Recognize the pair so the oracle's `>>>` operator (AST
      # `BinaryOp .. "asr"`) is accepted.
      if p.peek(1).kind == tkGt:
        discard p.advance()  # consume `>>`
        discard p.advance()  # consume the trailing `>`
        left = newBinaryOp(left, "asr", p.parseConcat())
      else:
        p.advance(); left = newBinaryOp(left, ">>", p.parseConcat())
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
    let s = p.parseStatement()
    if s != nil: stmts.add s
    if p.match(tkSemi): discard
  return newBlock(stmts)

proc canStartExpr*(p: Parser): bool =
  ## Whether the current token may begin an expression.  Used by the switch
  ## parser to distinguish a genuine case value from a clause terminator such
  ## as `else`/`then`/`end`, which the reference reports as "expected
  ## expressions" rather than "unexpected keyword".
  let t = p.tok
  case t.kind
  of tkNumber, tkString, tkLString, tkIdent, tkDotDot, tkLParen, tkLBrace, tkAt,
      tkMinus, tkHash, tkBxor, tkBand:
    return true
  of tkKeyword:
    return t.value in ["true", "false", "nil", "nilptr", "function", "not"]
  else:
    return false

proc parseSwitchBlock*(p: var Parser): Node =
  ## Parse a `switch` case body (or the `else` body): a statement list that
  ## stops at the next clause -- `case` (an identifier, not a keyword), `else`
  ## or `end` -- in addition to the usual block terminators.  `case` is not a
  ## keyword, so `parseBlock` would not stop for it and would misparse the
  ## following clause as part of this body.
  ##
  ## Labels (`::name::`) are *not* clause terminators: a `goto` target may
  ## live inside a case/else body (the stdlib's `string.pack` does exactly
  ## this), so they are parsed as ordinary statements here.
  var stmts: seq[Node] = @[]
  while true:
    let t = p.tok
    if t.kind == tkEof: break
    if t.kind == tkKeyword and (t.value == "end" or t.value == "else" or t.value == "elseif" or t.value == "until"):
      break
    if t.kind == tkIdent and t.value == "case": break
    let s = p.parseStatement()
    if s != nil: stmts.add s
    if p.match(tkSemi): discard
  return newBlock(stmts)

proc parseSwitch*(p: var Parser): Node =
  ## Parse `switch <expr> { case <iv> [, <iv> ...] then <block> ; [else <block>] } end`.
  ## Produces an `nkSwitch` (`Switch(expr, cases: seq[(seq[Node], Node)], elseBlock)`)
  ## via the existing `newSwitch` constructor; the flat child layout is
  ## `[subject, case1-vals..., case1-body, case2-vals..., ..., [else-body]]`,
  ## which the analyzer/codegen/dump traverse by scanning for `nkBlock`
  ## boundaries (case bodies are always Blocks; case values never are).
  p.expectKeyword("switch", "expected 'switch' keyword")
  let expr = p.parseExpr()
  var cases: seq[tuple[exprs: seq[Node], body: Node]] = @[]
  var elseBlock: Node = nil
  while not p.checkKeyword("end"):
    if p.tok.kind == tkIdent and p.tok.value == "case":
      discard p.advance()
      if not p.canStartExpr():
        raise p.error("expected expressions")
      var exprs: seq[Node] = @[]
      exprs.add p.parseExpr()
      while p.match(tkComma):
        if not p.canStartExpr():
          raise p.error("expected expressions")
        exprs.add p.parseExpr()
      p.expectKeyword("then", "expected `then` keyword to begin a statement block")
      let body = p.parseSwitchBlock()
      cases.add (exprs, body)
    elif p.checkKeyword("else"):
      discard p.advance()
      if elseBlock != nil:
        raise p.error("multiple `else` clauses in `switch` statement")
      elseBlock = p.parseSwitchBlock()
    else:
      raise p.error("expected `case` keyword in `switch` statement")
  if cases.len == 0 and elseBlock == nil:
    raise p.error("expected `case` keyword in `switch` statement")
  discard p.advance()  # consume `end`
  return newSwitch(expr, cases, elseBlock)

proc parseIdDecl*(p: var Parser): Node =
  var name: Node
  var nameStr: string
  var nameIsSplice = false
  let ppName = p.parsePreprocessName()
  if ppName != nil:
    name = ppName
    nameStr = ppName.str
    nameIsSplice = true
  else:
    name = newId(p.advance().value)
    nameStr = name.str
  var isDotted = false
  # Dotted declaration names: `global io.stderr`, `Rect.field`, `a.b.c`.  Build
  # a dot-index chain (as `parseFuncName` does for `.`/`:` postfixes) and record
  # the full dotted string on the node, matching the reference AST shape where
  # a dotted name carries its dot-index node as `children[0]`.
  while p.check(tkDot):
    isDotted = true
    discard p.advance()                   ## consume '.'
    let field = p.advance().value
    name = newDotIndex(field, name)
    nameStr &= "." & field
  var typeexpr: Node = nil
  if p.match(tkColon):
    typeexpr = p.parseOptionalType()
  var children: seq[Node] = @[]
  # A `#|name|#` splice name carries its `nkPreprocessName` node as
  # `children[0]` (the reference dumps it there, unlike a plain identifier
  # whose spelling lives only in `str`).
  if isDotted or nameIsSplice:
    children.add name
  if typeexpr != nil: children.add typeexpr
  children &= p.parseAnnotations()
  return Node(kind: nkIdDecl, str: nameStr, children: children)

proc parseFuncName*(p: var Parser): Node =
  ## A function name is either a `#|name|#` preprocessor splice placeholder
  ## (carried as an `nkPreprocessName` node, matching the reference AST) or an
  ## ordinary identifier optionally followed by `.field` / `:field` suffixes.
  let ppName = p.parsePreprocessName()
  if ppName != nil:
    return ppName
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
    if name.kind == nkPreprocessName:
      ## A `#|name|#` splice function name is wrapped in an `nkIdDecl` that
      ## carries the splice node as `children[0]`, exactly the shape the
      ## reference `--print-ast` emits (`IdDecl { PreprocessName { "name" } }`).
      name = Node(kind: nkIdDecl, str: name.str, children: @[name])
    else:
      name = newIdDecl(name.str, nil)
  p.expect(tkLParen, "expected '(' after function name")
  var args: seq[Node] = @[]
  if not p.check(tkRParen):
    while true:
      if p.check(tkDotDot):
        p.advance()
        var vkind = ""
        if p.match(tkColon):
          vkind = p.advance().value
        args.add newVarargsType(vkind)
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

proc newForInLowering(iddecls: seq[Node], inexp: seq[Node], body: Node,
                      n: int): Node =
  ## Lower `for <vars> in <exprs> do <body> end` to the oracle's stateless-iterator
  ## while loop (analyzer.lua `visitors.ForIn`): the `in` expression list yields
  ## the iterator function, the state and the initial control value, and each
  ## iteration calls `iter(state, control)`, stopping when the first return is
  ## false/nil.  Lowering here (instead of a ForIn-specific codegen path) lets
  ## the existing analyzer multi-return inference and cgen call/VarDecl lowering
  ## handle the state machine with no new machinery.
  ##
  ##   do
  ##     local __fornext, __forstate, __fornextit = <exprs>
  ##     while true do
  ##       local __forcont, <vars...> = __fornext(__forstate, __fornextit)
  ##       if not __forcont then break end
  ##       __fornextit = <vars[0]>
  ##       <body>
  ##     end
  ##   end
  ##
  ## The outer `do` scopes the iterator locals so two `for in` loops in the same
  ## function do not redeclare `__fornext`.  The first loop variable doubles as
  ## the iterator control variable (the oracle advances `__fornextit` to it after
  ## every call), which is exactly the stateless-iterator protocol `ipairs` and
  ## `pairs` use: their next function returns `(true, newkey, value)`.
  let sfx = "_" & $n
  let fnId = newId("__fornext" & sfx)
  let fsId = newId("__forstate" & sfx)
  let fiId = newId("__fornextit" & sfx)
  let fcId = newId("__forcont" & sfx)
  let iterIddecls = @[newIdDecl("__fornext" & sfx), newIdDecl("__forstate" & sfx),
                      newIdDecl("__fornextit" & sfx)]
  let iterVarDecl = newVarDecl("local", iterIddecls, inexp)
  let iterCall = newCall(@[fsId, fiId], fnId)
  var loopIddecls: seq[Node] = @[newIdDecl("__forcont" & sfx)]
  for id in iddecls: loopIddecls.add id
  let loopVarDecl = newVarDecl("local", loopIddecls, @[iterCall])
  let cond = newUnaryOp("not", fcId)
  let ifNode = newIf(@[(cond, newBlock(@[newBreak()]))], nil)
  let controlAssign = newAssign(@[fiId], @[newId(iddecls[0].str)])
  let bodyDo = newDo(body)
  let whileBody = newBlock(@[loopVarDecl, ifNode, controlAssign, bodyDo])
  let whileNode = newWhile(newBoolean(true), whileBody)
  let outerBlock = newBlock(@[iterVarDecl, whileNode])
  return newDo(outerBlock)

proc parseFor*(p: var Parser): Node =
  p.advance()
  # The loop variable may carry a type annotation, e.g.
  # `for i:isize=0,<n do`.  Parse it as an `IdDecl` (which reads the optional
  # `:type`) so the annotation is preserved in the AST, matching the
  # reference's `ForNum { IdDecl { "i", Id { "isize" } }, ... }` shape.
  let firstDecl = p.parseIdDecl()
  if p.check(tkAssign):
    p.advance()
    let beginv = p.parseExpr()
    p.expect(tkComma, "expected ',' in for range")
    var cmpop = ""
    var endv: Node
    if p.check(tkLt):
      ## `<expr>` exclusive upper bound: the loop runs while `i < expr`
      ## (default inclusive `<=` becomes `lt`).  The oracle writes the
      ## bound as `<N` (no closing `>`) in for-position, so this is a bare
      ## `tkLt` token, not a `tkAnnotation`.
      discard p.advance()
      cmpop = "lt"
      endv = p.parseExpr()
    elif p.check(tkLe):
      ## `<=expr` inclusive upper bound: the loop runs while `i <= expr`.
      discard p.advance()
      cmpop = "le"
      endv = p.parseExpr()
    elif p.check(tkGt):
      ## `>expr` exclusive lower bound: the loop runs while `i > expr`,
      ## descending.  The oracle writes the bound as `>N` in for-position.
      discard p.advance()
      cmpop = "gt"
      endv = p.parseExpr()
    elif p.check(tkGe):
      ## `>=expr` inclusive lower bound: the loop runs while `i >= expr`,
      ## descending.  `www_neg_for.nelua` uses `for i = 5, >=1, -1 do`.
      discard p.advance()
      cmpop = "ge"
      endv = p.parseExpr()
    else:
      endv = p.parseExpr()
    let step = if p.match(tkComma): p.parseExpr() else: nil
    p.expectKeyword("do", "expected 'do' in for")
    let body = p.parseBlock()
    p.expectKeyword("end", "expected 'end' to close for")
    return newForNum(firstDecl, beginv, cmpop, endv, step, body)
  # `for ... in` iterator form.  The loop variable list may carry type
  # annotations (`for i: integer, v in ... do`); each is parsed as an IdDecl so
  # the annotation is preserved.  The `in` expression list yields the iterator
  # function, the state and the initial control value (the stateless-iterator
  # protocol used by `ipairs`/`pairs`/`utf8.iter`).
  var iddecls: seq[Node] = @[]
  iddecls.add firstDecl
  while p.match(tkComma):
    iddecls.add p.parseIdDecl()
  p.expectKeyword("in", "expected 'in' in for loop")
  var inexp: seq[Node] = @[]
  inexp.add p.parseExpr()
  while p.match(tkComma):
    if p.isStmtEnd() or p.checkKeyword("do"): break
    inexp.add p.parseExpr()
  p.expectKeyword("do", "expected 'do' in for")
  let body = p.parseBlock()
  p.expectKeyword("end", "expected 'end' to close for")
  let n = p.forInCount
  p.forInCount += 1
  return newForInLowering(iddecls, inexp, body, n)

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

proc stripLongBrackets(s: string): string =
  ## Remove the `[=`*`[` opener and `]`=`*`]` closer of a Lua long-string token,
  ## returning the inner text (the shape the reference `--print-ast` emits for a
  ## `##[[ ... ]]` block).  Only strips a well-formed long string; otherwise
  ## returns `s` unchanged.
  if s.len < 4 or s[0] != '[':
    return s
  var level = 0
  var i = 1
  while i < s.len and s[i] == '=':
    inc level; inc i
  if i >= s.len or s[i] != '[':
    return s
  let openLen = level + 2
  if s.len < 2 * openLen or s[s.len - 1] != ']':
    return s
  for k in 0 ..< level:
    if s[s.len - 2 - k] != '=':
      return s
  if s[s.len - openLen] != ']':
    return s
  result = s[openLen ..< s.len - openLen]

proc parsePreprocess*(p: var Parser): Node =
  ## Parse a `##`-line at statement position into an `nkPreprocess` node.
  ##
  ## The node's `str` is the raw source text of the line *after* `##` (e.g.
  ## `## x = 2` -> `nkPreprocess " x = 2"`), exactly the shape the reference
  ## interpreter's `--print-ast` emits.  The M6 preprocessor feeds this text to
  ## the embedded Lua interpreter at compile time.  A trailing line comment
  ## (`-- ...`) is trimmed, matching `restOfLine`.
  ##
  ## A `##[[ ... ]]` / `##[=[ ... ]=]` multi-line block is folded by the lexer
  ## into a single `tkLString` token; its body is the inner Lua text (brackets
  ## stripped).  Such a block is self-contained, so its node is flagged
  ## (`boolVal = true`) for the preprocessor to run it as a standalone chunk,
  ## bypassing the `luaBlockDelta` framing that would otherwise mis-frame a
  ## body that happens to contain `for`/`if`/`end`.
  let hashTok = p.advance()             ## consume `##`
  if p.tok.kind == tkLString:
    let body = stripLongBrackets(p.tok.value)
    p.advance()                          ## consume the `tkLString`
    return Node(kind: nkPreprocess, str: body, boolVal: true)
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
    of "global":
      if p.peek(1).kind == tkKeyword and p.peek(1).value == "function":
        discard p.advance()
        return p.parseFuncDef("global")
      return p.parseVarDecl("global")
    of "function": return p.parseFuncDef("")
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "repeat": return p.parseRepeat()
    of "for": return p.parseFor()
    of "in":
      ## `in (expr)` is the splice-function / do-expression return statement.
      ## It appears inside a `##` block as the body of a splice function
      ## (`## local function f(p) in (#[p]#) ## end`) and inside a `(do ... in
      ## expr end)` do-expression.  Store the expression on an `nkIn` node.
      discard p.advance()
      let expr = p.parseExpr()
      return Node(kind: nkIn, children: @[expr])
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
    of "switch":
      return p.parseSwitch()
    else:
      discard
  if t.kind == tkIdent and t.value == "fallthrough":
    p.advance()
    return newFallthrough()
  if t.kind == tkIdent and t.value == "case":
    ## `case` has no meaning outside a `switch`; the reference reports it as
    ## "unexpected syntax".  This check fires only at genuine statement
    ## position -- `parseSwitch` consumes `case` clauses itself and
    ## `parseSwitchBlock` stops before handing the body to `parseStatement`.
    raise p.error("unexpected syntax")
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
  var p: Parser
  try:
    p = newParser(source, path)
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

proc dump*(n: Node, indent = 0): string

proc dumpSwitchChildren(n: Node, indent: int): string =
  ## Render an `nkSwitch`'s children in the reference's nested shape:
  ##
  ##   Switch { <subject>, { { <case-vals> }, <case-body Block>, ... [, <else Block>] } }
  ##
  ## The flat `newSwitch` layout is `[subject, vals..., body, vals..., body,
  ## ..., [else-body]]`; case bodies are always `nkBlock` and case values are
  ## never blocks, so scanning on `nkBlock` boundaries recovers the clauses.
  let fldInd = "  ".repeat(indent)        ## cases-container indent
  let valInd = "  ".repeat(indent + 1)    ## value-list / body indent
  var s = ""
  s.add dump(n.children[0], indent)
  s.add ",\n"
  s.add fldInd & "{\n"
  var i = 1
  let nc = n.children.len
  var first = true
  while i < nc:
    var vals: seq[Node] = @[]
    while i < nc and n.children[i].kind != nkBlock:
      vals.add n.children[i]
      inc i
    if i >= nc: break
    let body = n.children[i]
    inc i
    if not first: s.add ",\n"
    first = false
    if vals.len > 0:
      s.add valInd & "{\n"
      for vi, v in vals:
        s.add dump(v, indent + 2)
        if vi < vals.len - 1: s.add ",\n"
        else: s.add "\n"
      s.add valInd & "},\n"
      s.add dump(body, indent + 1)
    else:
      s.add dump(body, indent + 1)
  s.add fldInd & "}\n"
  return s

proc dump*(n: Node, indent = 0): string =
  if n == nil: return "(nil)"
  var s = ""
  for _ in 0..<indent: s.add "  "
  case n.kind:
  of nkDoExpr:      s.add "nkDoExpr"
  of nkIn:          s.add "nkIn"
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
  of nkPair:
    if n.str.len > 0:
      s.add "nkPair " & quoteStr(n.str)
    else:
      s.add "nkPair"
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
  of nkFallthrough: s.add "nkFallthrough"
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
  elif n.kind == nkSwitch:
    s.add dumpSwitchChildren(n, indent + 1)
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