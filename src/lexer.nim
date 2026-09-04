## Nelua tokenizer. Produces a flat token stream with source spans.
##
## Tokens carry kind, textual value, and a SourceLoc (path/line/col/offset/length).
## Whitespace and comments are skipped and not emitted. Long strings, block
## comments and annotations span multiple lines and are handled explicitly.

import span

type
  TokenType* = enum
    tkEof
    tkIdent
    tkNumber
    tkString
    tkLString
    tkKeyword
    tkPlus, tkMinus, tkMul, tkDiv, tkIdiv, tkMod, tkPow
    tkLen, tkConcat
    tkBand, tkBor, tkBxor, tkShl, tkShr, tkAsr
    tkEq, tkNe, tkLt, tkLe, tkGt, tkGe
    tkAssign
    tkQuestion
    tkArrow
    tkLParen, tkRParen
    tkLBrace, tkRBrace
    tkLBrack, tkRBrack
    tkColon, tkColonColon, tkSemi, tkComma, tkDot, tkDotDot
    tkDots
    tkAt
    tkHash
    tkPipe
    tkHashLBrack
    tkDoubleHash
    tkAnnotation

  Token* = object
    kind*: TokenType
    value*: string
    loc*: SourceLoc

const
  Keywords* = [
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "nilptr", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
    "switch", "cond", "defer", "continue", "global", "require",
    "import", "macro", "record", "union", "enum", "varargs",
    "varautos", "varanys", "cvarargs", "any", "auto", "integer",
    "number", "string", "boolean", "isize", "usize", "cchar", "cshort",
    "cint", "clong", "cfloat", "cdouble", "void", "type",
  ]

proc isKeyword*(s: string): bool =
  for k in Keywords:
    if s == k: return true
  return false

## The keywords the oracle permits as ordinary identifiers.  It rejects every
## control-flow keyword (if/for/while/end/then/...), every literal
## (true/false/nil/nilptr) and every operator (and/or/not/break/goto/continue/
## defer) -- `local end = 7` is "syntax error: expected an declaration
## expression".  What survives is exactly the type/annotation/declaration
## vocabulary, so a user may write `local import = 42; print(import)`.
const IdentifierKeywords* = [
  "cond", "require", "import", "macro", "record", "union", "enum",
  "varargs", "varautos", "varanys", "cvarargs", "any", "auto", "integer",
  "number", "string", "boolean", "isize", "usize", "cchar", "cshort",
  "cint", "clong", "cfloat", "cdouble", "void", "type",
]

proc isIdentKeyword*(s: string): bool =
  for k in IdentifierKeywords:
    if s == k: return true
  return false

proc isIdentStart(c: char): bool =
  c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isIdentChar(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc isDigit(c: char): bool =
  c >= '0' and c <= '9'

proc isHexDigit(c: char): bool =
  isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: 0

proc isSpace(c: char): bool =
  c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\f' or c == '\v'

proc isNumberEnd(s: string, i: int): bool =
  if i >= s.len: return true
  let c = s[i]
  return not (isDigit(c) or c == '.' or c == 'x' or c == 'X' or
    c == 'b' or c == 'B' or c == 'e' or c == 'E' or
    c == 'a' or c == 'A' or c == 'f' or c == 'F' or
    c == '-' or c == '+')

proc lexNumber(s: string, start: int): (string, int) =
  var i = start
  if s[i] == '0' and i + 1 < s.len and (s[i+1] == 'x' or s[i+1] == 'X'):
    inc i, 2
    while i < s.len and isHexDigit(s[i]): inc i
  elif s[i] == '0' and i + 1 < s.len and (s[i+1] == 'b' or s[i+1] == 'B'):
    inc i, 2
    while i < s.len and (s[i] == '0' or s[i] == '1'): inc i
  else:
    while i < s.len and isDigit(s[i]): inc i
    if i < s.len and s[i] == '.':
      inc i
      while i < s.len and isDigit(s[i]): inc i
    if i < s.len and (s[i] == 'e' or s[i] == 'E'):
      inc i
      if i < s.len and (s[i] == '+' or s[i] == '-'): inc i
      while i < s.len and isDigit(s[i]): inc i
  # numeric literal suffix, e.g. _u32, _f32, _cchar (the analyzer rejects
  # unknown suffixes with "literal suffix '...' is undefined for numbers").
  if i < s.len and s[i] == '_' and i + 1 < s.len and isIdentStart(s[i+1]):
    inc i
    while i < s.len and isIdentChar(s[i]): inc i
  return (s[start ..< i], i)

proc isLongBracket(s: string, i: int): int =
  if s[i] != '[': return -1
  var j = i + 1
  while j < s.len and s[j] == '=':
    inc j
  if j < s.len and s[j] == '[':
    return j - i - 1
  return -1

proc lexLongString(s: string, start: int): (string, int) =
  let level = isLongBracket(s, start)
  var j = start + level + 2
  while j < s.len:
    if s[j] == ']':
      var k = j + 1
      var m = 0
      while k < s.len and s[k] == '=':
        inc k; inc m
      if k < s.len and s[k] == ']' and m == level:
        return (s[start ..< k + 1], k + 1)
    inc j
  return (s[start ..< s.len], s.len)

proc lexString(s: string, start: int, quote: char): (string, int) =
  var i = start + 1
  var buf = newStringOfCap(s.len)
  buf.add quote
  while i < s.len:
    let c = s[i]
    if c == '\\':
      inc i
      if i >= s.len: break
      case s[i]
      of 'a': buf.add '\a'; inc i
      of 'b': buf.add '\b'; inc i
      of 'f': buf.add '\f'; inc i
      of 'n': buf.add '\n'; inc i
      of 'r': buf.add '\r'; inc i
      of 't': buf.add '\t'; inc i
      of 'v': buf.add '\v'; inc i
      of '\\': buf.add '\\'; inc i
      of '"': buf.add '"'; inc i
      of '\'': buf.add '\''; inc i
      of 'z':
        inc i
        while i < s.len and isSpace(s[i]): inc i
        continue
      of 'x':
        inc i; var hx = ""
        while i < s.len and isHexDigit(s[i]) and hx.len < 2: hx.add s[i]; inc i
        if hx.len > 0:
          var v = hexVal(hx[0]) * 16
          if hx.len > 1: v += hexVal(hx[1])
          buf.add char(v)
        else: buf.add 'x'
      else: buf.add s[i]; inc i     # unknown escape: keep literally (current behavior)
      continue
    if c == quote: buf.add quote; return (buf, i + 1)
    if c == '\n': break
    buf.add c; inc i
  return (buf, s.len)

proc skipComment(s: string, i: int): int =
  if i + 1 >= s.len: return i + 1
  if s[i+1] == '-':
    if i + 2 < s.len and isLongBracket(s, i + 2) >= 0:
      let (_, e) = lexLongString(s, i + 2)
      return e
    var j = i + 2
    while j < s.len and s[j] != '\n': inc j
    return j
  return i + 1

proc lexAnnotation(s: string, start: int): (string, int) =
  var i = start + 1
  var quote = '\0'
  while i < s.len:
    let c = s[i]
    if quote != '\0':
      if c == '\\': inc i, 2; continue
      if c == quote: quote = '\0'
      inc i; continue
    if c == '"' or c == '\'': quote = c
    if c == '>': return (s[start ..< i + 1], i + 1)
    inc i
  return (s[start ..< s.len], s.len)

proc tokenize*(source: string, path: string = ""): seq[Token] =
  var tokens: seq[Token] = @[]
  var i = 0
  var line = 1
  var col = 1
  let n = source.len

  while i < n:
    let c = source[i]
    let tokStart = i

    if isSpace(c):
      if c == '\n': inc line; col = 1
      else: inc col
      inc i
      continue

    if c == '-' and i + 1 < n and source[i+1] == '-':
      i = skipComment(source, i)
      col += (i - tokStart)
      continue

    let loc = newSourceLoc(path, source, tokStart)

    if isIdentStart(c):
      var j = i + 1
      while j < n and isIdentChar(source[j]): inc j
      let word = source[i ..< j]
      let kind = if isKeyword(word): tkKeyword else: tkIdent
      tokens.add Token(kind: kind, value: word,
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: j - i))
      i = j
      col += (j - tokStart)
      continue

    if isDigit(c) or (c == '.' and i + 1 < n and isDigit(source[i+1])):
      let (text, j) = lexNumber(source, i)
      tokens.add Token(kind: tkNumber, value: text,
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: j - i))
      i = j
      col += (j - tokStart)
      continue

    if c == '"' or c == '\'':
      let (text, j) = lexString(source, i, c)
      tokens.add Token(kind: tkString, value: text,
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: j - i))
      i = j
      col += (j - tokStart)
      continue

    if c == '[' and isLongBracket(source, i) >= 0:
      let (text, j) = lexLongString(source, i)
      tokens.add Token(kind: tkLString, value: text,
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: j - i))
      i = j
      col += (j - tokStart)
      continue

    if c == '<' and i + 1 < n and source[i+1] == '=':
      tokens.add Token(kind: tkLe, value: "<=",
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: 2))
      i += 2; col += 2; continue
    if c == '<' and i + 1 < n and source[i+1] == '<':
      tokens.add Token(kind: tkShl, value: "<<",
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: 2))
      i += 2; col += 2; continue
    if c == '<' and i + 1 < n and isIdentStart(source[i + 1]):
      # Oracle PEG: `annots <-| '<' @Annotation (',' @Annotation)* @'>'`
      # only matches when the token after `<ident` (ignoring whitespace) is
      # `>`, `,`, `(`, `{`, `'`, `"` or `#`; otherwise `<` is the less-than
      # operator and the following `<ident do ...` is a bound expression, not
      # an annotation. Without this guard the greedy lexAnnotation (which
      # scans to the first `>`, spanning newlines) swallows comparison bodies
      # like `for i=1_u32,<MT19937_N do ... >> ... end`.
      var j = i + 1
      while j < n and isIdentChar(source[j]): inc j
      var k = j
      while k < n and source[k] in {' ', '\t', '\n', '\r', '\f', '\v'}: inc k
      let after = if k < n: source[k] else: '\0'
      if after in {'>', ',', '(', '{', '\'', '"', '#'}:
        let (atext, aj) = lexAnnotation(source, i)
        if aj > i + 1 and source[aj - 1] == '>':
          tokens.add Token(kind: tkAnnotation, value: atext,
            loc: SourceLoc(path: loc.path, line: line, col: col,
              offset: loc.offset, length: aj - i))
          i = aj
          col += (aj - tokStart)
          continue
      tokens.add Token(kind: tkLt, value: "<",
        loc: SourceLoc(path: loc.path, line: line, col: col,
          offset: loc.offset, length: 1))
      inc i; inc col; continue

    if i + 1 < n:
      let two = source[i ..< i + 2]
      case two
      of "..":
        if i + 2 < n and source[i+2] == '.':
          tokens.add Token(kind: tkDotDot, value: "...",
            loc: SourceLoc(path: loc.path, line: line, col: col,
              offset: loc.offset, length: 3))
          i += 3; col += 3; continue
        tokens.add Token(kind: tkConcat, value: "..",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "==":
        tokens.add Token(kind: tkEq, value: "==",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "~=":
        tokens.add Token(kind: tkNe, value: "~=",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of ">=":
        tokens.add Token(kind: tkGe, value: ">=",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "//":
        tokens.add Token(kind: tkIdiv, value: "//",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of ">>":
        tokens.add Token(kind: tkShr, value: ">>",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "->":
        tokens.add Token(kind: tkArrow, value: "->",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "::":
        tokens.add Token(kind: tkColonColon, value: "::",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "##":
        tokens.add Token(kind: tkDoubleHash, value: "##",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue
      of "#[":
        tokens.add Token(kind: tkHashLBrack, value: "#[",
          loc: SourceLoc(path: loc.path, line: line, col: col,
            offset: loc.offset, length: 2))
        i += 2; col += 2; continue

    case c
    of '+': tokens.add Token(kind: tkPlus, value: "+",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '-': tokens.add Token(kind: tkMinus, value: "-",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '*': tokens.add Token(kind: tkMul, value: "*",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '/': tokens.add Token(kind: tkDiv, value: "/",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '%': tokens.add Token(kind: tkMod, value: "%",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '^': tokens.add Token(kind: tkPow, value: "^",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '#': tokens.add Token(kind: tkHash, value: "#",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '&': tokens.add Token(kind: tkBand, value: "&",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '|': tokens.add Token(kind: tkBor, value: "|",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '~': tokens.add Token(kind: tkBxor, value: "~",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '=': tokens.add Token(kind: tkAssign, value: "=",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '?': tokens.add Token(kind: tkQuestion, value: "?",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '<': tokens.add Token(kind: tkLt, value: "<",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '>': tokens.add Token(kind: tkGt, value: ">",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '(': tokens.add Token(kind: tkLParen, value: "(",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of ')': tokens.add Token(kind: tkRParen, value: ")",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '{': tokens.add Token(kind: tkLBrace, value: "{",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '}': tokens.add Token(kind: tkRBrace, value: "}",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '[': tokens.add Token(kind: tkLBrack, value: "[",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of ']': tokens.add Token(kind: tkRBrack, value: "]",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of ':': tokens.add Token(kind: tkColon, value: ":",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of ';': tokens.add Token(kind: tkSemi, value: ";",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of ',': tokens.add Token(kind: tkComma, value: ",",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '.': tokens.add Token(kind: tkDot, value: ".",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    of '@': tokens.add Token(kind: tkAt, value: "@",
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    else:
      tokens.add Token(kind: tkIdent, value: $c,
        loc: SourceLoc(path: loc.path, line: line, col: col, offset: loc.offset, length: 1))
    inc i
    inc col

  tokens.add Token(kind: tkEof, value: "",
    loc: SourceLoc(path: path, line: line, col: col, offset: i, length: 0))
  return tokens

when isMainModule:
  let toks = tokenize("local x = 1\nprint(x)\n")
  doAssert toks.len == 9
  doAssert toks[0].kind == tkKeyword and toks[0].value == "local"
  doAssert toks[1].kind == tkIdent and toks[1].value == "x"
  doAssert toks[2].kind == tkAssign
  doAssert toks[3].kind == tkNumber and toks[3].value == "1"
  doAssert toks[4].kind == tkIdent and toks[4].value == "print"
  doAssert toks[5].kind == tkLParen
  doAssert toks[6].kind == tkIdent and toks[6].value == "x"
  doAssert toks[7].kind == tkRParen
  doAssert toks[8].kind == tkEof
  echo "lexer.nim OK"