## C emitter helpers for the Nelua-in-Nim compiler (M3 foundation).
##
## Pure formatting helpers that never touch the analyzer: literal formatting,
## string escaping, identifier sanitization, casts and attribute qualifiers.
## Depends on `types` (for `Type`/`Attr`) and `cgen_types` (for `cType` inside
## `cCast`), both of which are M2/M3 modules — not the analyzer.

import types
import cgen_types
import tables
import strutils

proc cBoolLit*(b: bool): string =
  ## Nelua boolean literal → C literal.
  if b: "true" else: "false"

proc stripNeluaNumberSuffix(s: string): string =
  ## Drop a trailing Nelua numeric type suffix (`_u32`, `_f32`, `_cchar`, ...).
  ## Nelua numeric literals never embed `_` outside a suffix, so the first `_`
  ## delimits it; if there is none the literal is returned unchanged.
  let u = s.find('_')
  if u < 0: return s
  return s[0 ..< u]

proc cNilptrLit*(): string =
  ## Nelua `nilptr` literal → C null pointer.
  "NULL"

proc cNumberLit*(t: Type, s: string): string =
  ## Format a Nelua numeric literal `s` for the C type `t`.
  ##
  ## Floats get a decimal point (and an `f`/`L` suffix for float32/float128)
  ## when the source literal has no radix marker; integers are returned as-is
  ## (128-bit literals need no suffix on GCC/Clang). A trailing Nelua type
  ## suffix (`_u32`, `_f32`, ...) is stripped -- it is not valid C.
  let s = stripNeluaNumberSuffix(s)
  if t == nil:
    return s
  if t.isFloat:
    let hasMarker = s.contains('.') or s.contains('e') or s.contains('E') or
                     s.contains('f') or s.contains('F')
    var r = s
    if not hasMarker:
      r &= ".0"
    if t.kind == tkFloat32 or t.kind == tkCfloat:
      let last = r[^1]
      if last != 'f' and last != 'F':
        r &= "f"
    elif t.kind == tkFloat128 or t.kind == tkClongdouble:
      let last = r[^1]
      if last != 'l' and last != 'L':
        r &= "L"
    return r
  s

proc escapeCChar(c: char): string =
  case c
  of '\n': "\\n"
  of '\r': "\\r"
  of '\t': "\\t"
  of '\\': "\\\\"
  of '"':  "\\\""
  of '\0': "\\0"
  else:
    let o = c.ord
    if o < 0x20 or o > 0x7e:
      "\\x" & toHex(o, 2)
    else:
      $c

proc cStringLit*(s: string, long = false): string =
  ## Escape a Nelua string for a C string literal.
  ##
  ## `long = true` emits the content as a sequence of adjacent C string
  ## literals (split at newlines and at ~60 columns) so multi-line Nelua
  ## long strings stay readable in the generated C.
  if not long:
    var r = "\""
    for c in s:
      r &= escapeCChar(c)
    r &= "\""
    return r
  var parts: seq[string] = @[]
  var cur = ""
  for c in s:
    cur &= escapeCChar(c)
    if cur.len > 60 or c == '\n':
      parts.add("\"" & cur & "\"")
      cur = ""
  if cur.len > 0 or parts.len == 0:
    parts.add("\"" & cur & "\"")
  parts.join(" ")

proc cIdent*(s: string): string =
  ## Sanitize a Nelua codename into a valid C identifier: every character that
  ## is not alphanumeric or `_` is mapped to `_`, and a leading digit gets an
  ## `_` prefix.
  if s.len == 0:
    return "_"
  var r = ""
  for c in s:
    let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
             (c >= '0' and c <= '9') or c == '_'
    if ok:
      r &= c
    else:
      r &= '_'
  if r[0] >= '0' and r[0] <= '9':
    r = "_" & r
  if r == "":
    r = "_"
  r

proc cCast*(t: Type, expr: string): string =
  ## C cast of `expr` to the C spelling of `t`: `(cType(t))(expr)`.
  if t == nil:
    return expr
  "(" & cType(t) & ")(" & expr & ")"

proc cQualifiers*(attr: Attr): string =
  ## Prefix qualifiers (`const`, `volatile`) from an `Attr`'s flag bits.
  if attr == nil:
    return ""
  var q = ""
  if attr.isConst:
    q &= "const "
  if attr.isVolatile:
    q &= "volatile "
  q

when isMainModule:
  let integer = BuiltinTypes["integer"]
  let number  = BuiltinTypes["number"]
  let flt32   = Type(kind: tkFloat32, name: "float32", codename: "float32")
  let stringT = BuiltinTypes["string"]
  let boolean = BuiltinTypes["boolean"]
  let nilptr  = BuiltinTypes["nilptr"]

  # --- boolean / nilptr literals ---
  doAssert cBoolLit(true)  == "true",  cBoolLit(true)
  doAssert cBoolLit(false) == "false", cBoolLit(false)
  doAssert cNilptrLit()    == "NULL",  cNilptrLit()

  # --- number literal formatting ---
  doAssert cNumberLit(integer, "42")        == "42",         cNumberLit(integer, "42")
  doAssert cNumberLit(number, "3")          == "3.0",       cNumberLit(number, "3")
  doAssert cNumberLit(number, "3.14")       == "3.14",      cNumberLit(number, "3.14")
  doAssert cNumberLit(number, "1e10")       == "1e10",      cNumberLit(number, "1e10")
  doAssert cNumberLit(flt32, "1")           == "1.0f",      cNumberLit(flt32, "1")
  doAssert cNumberLit(flt32, "2.5")         == "2.5f",      cNumberLit(flt32, "2.5")

  # --- string literal escaping ---
  doAssert cStringLit("hello")              == "\"hello\"",           cStringLit("hello")
  doAssert cStringLit("a\"b")               == "\"a\\\"b\"",           cStringLit("a\"b")
  doAssert cStringLit("a\\b")               == "\"a\\\\b\"",           cStringLit("a\\b")
  doAssert cStringLit("line1\nline2")       == "\"line1\\nline2\"",    cStringLit("line1\nline2")
  doAssert cStringLit("tab\there")          == "\"tab\\there\"",       cStringLit("tab\there")
  doAssert cStringLit("ctrl\x01")           == "\"ctrl\\x01\"",       cStringLit("ctrl\x01")
  let long = cStringLit("one two three four five six seven eight nine ten", true)
  doAssert long.contains("\"") and long.contains(" "), long
  doAssert cStringLit("", true) == "\"\"", cStringLit("", true)

  # --- identifier sanitization ---
  doAssert cIdent("FooBar")     == "FooBar",   cIdent("FooBar")
  doAssert cIdent("a-b.c")      == "a_b_c",    cIdent("a-b.c")
  doAssert cIdent("123abc")     == "_123abc",  cIdent("123abc")
  doAssert cIdent("")           == "_",        cIdent("")
  doAssert cIdent("foo bar")    == "foo_bar",  cIdent("foo bar")
  doAssert cIdent("__x__")      == "__x__",    cIdent("__x__")

  # --- cast ---
  doAssert cCast(integer, "x")      == "(int64_t)(x)",      cCast(integer, "x")
  doAssert cCast(nilptr, "p")      == "(nilptr)(p)",      cCast(nilptr, "p")
  doAssert cCast(number, "d")      == "(double)(d)",      cCast(number, "d")
  doAssert cCast(nil, "x")         == "x",                cCast(nil, "x")
  let ptrInt = pointerType(integer)
  doAssert cCast(ptrInt, "p")      == "(int64_t*)(p)",     cCast(ptrInt, "p")

  # --- qualifiers ---
  doAssert cQualifiers(nil)              == "",               cQualifiers(nil)
  doAssert cQualifiers(Attr(isConst: true))               == "const ",     cQualifiers(Attr(isConst: true))
  doAssert cQualifiers(Attr(isVolatile: true))            == "volatile ",  cQualifiers(Attr(isVolatile: true))
  doAssert cQualifiers(Attr(isConst: true, isVolatile: true)) == "const volatile ",
        cQualifiers(Attr(isConst: true, isVolatile: true))

  echo "cemitter.nim OK"