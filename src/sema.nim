## Pure type-rule functions over Type (M2 Task 2).
##
## No scope dependency. Encapsulates §3.3 (type rules) and §3.4 (conversion
## matrix) so they are unit-testable without a scope:
##   inferUnary, inferBinary, commonType, convert, checkCall,
##   literal typing (Number/String/Boolean/Nilptr/Nil), resolveTypeExpr.
##
## Operator names accept both the reference's descriptive names
## (`unm`/`len`/`bnot`/`ref`/`deref`/`not`) and the symbolic names the M1
## parser emits (`-`/`#`/`~`/`&`/`$`); `normalizeUnaryOp` maps the latter.

import ast
import types
import tables
import strutils

# --- operator name normalization -------------------------------------------

proc normalizeUnaryOp(op: string): string =
  case op:
    of "-":  "unm"
    of "#":  "len"
    of "~":  "bnot"
    of "$":  "deref"
    of "&":  "ref"
    else:    op

proc normalizeBinaryOp(op: string): string =
  case op:
    of "^":  "^^"
    else:    op

# --- numeric promotion helpers ---------------------------------------------

proc widerIntegral(a, b: Type): Type =
  if a == nil: return b
  if b == nil: return a
  if a.size > b.size: a
  elif b.size > a.size: b
  else: a

proc widerFloat(a, b: Type): Type =
  if a == nil: return b
  if b == nil: return a
  if a.isFloat and b.isFloat:
    if a.size >= b.size: a else: b
  elif a.isFloat: a
  else: b

# --- conversion matrix (§3.4) ------------------------------------------------

proc convert*(fromT, toT: Type, explicit: bool = false): Conversion =
  if fromT == nil or toT == nil:
    return Conversion(kind: ckNone)
  if fromT == toT:
    return Conversion(kind: ckIdentity)
  # integral <-> integral
  if fromT.isIntegral and toT.isIntegral:
    if fromT.size < toT.size:
      return Conversion(kind: ckImplicit, check: false)   # widening
    elif fromT.size > toT.size:
      return Conversion(kind: ckImplicit, check: true)    # narrowing
    else:
      return Conversion(kind: ckImplicit, check: true)    # same width, sign change
  # float <-> float
  if fromT.isFloat and toT.isFloat:
    if fromT.size < toT.size:
      return Conversion(kind: ckImplicit, check: false)   # widening
    elif fromT.size > toT.size:
      return Conversion(kind: ckImplicit, check: true)    # narrowing
    else:
      return Conversion(kind: ckIdentity)
  # integral <-> float
  if (fromT.isIntegral and toT.isFloat) or (fromT.isFloat and toT.isIntegral):
    return Conversion(kind: ckImplicit, check: true)
  # integer <-> pointer: explicit cast (@T)e only
  if (fromT.isIntegral and toT.isPointer) or (fromT.isPointer and toT.isIntegral):
    if explicit:
      return Conversion(kind: ckExplicit, check: false)
    return Conversion(kind: ckNone)
  # function type -> pointer
  if fromT.isFunction and toT.isPointer:
    if explicit:
      return Conversion(kind: ckExplicit, check: false)
    return Conversion(kind: ckNone)
  # nilptr -> optional is an implicit conversion.  Assigning nil/nilptr to a
  # *typed pointer* is rejected (the oracle errors
  # `local p: *byte = nil` with "no viable type conversion from 'niltype' to
  # 'pointer(uint8)'"), so nilptr -> pointer no longer auto-succeeds here.
  if fromT.isNilptr and toT.isOptional:
    return Conversion(kind: ckImplicit, check: false)
  if fromT.isNilptr and toT.isPointer:
    return Conversion(kind: ckNone)
  # record value -> pointer-to-record: implicit address-taking (no check)
  if fromT.isRecord and toT.isPointer and fromT == toT.subtype:
    return Conversion(kind: ckImplicit, check: false)
  # pointer <-> pointer (subtype pointers)
  if fromT.isPointer and toT.isPointer:
    return Conversion(kind: ckImplicit, check: false)
  # other scalar -> scalar
  if fromT.isScalar and toT.isScalar:
    return Conversion(kind: ckImplicit, check: true)
  # record value to record field of the same type
  if fromT.isRecord and toT.isRecord and fromT == toT:
    return Conversion(kind: ckIdentity)
  # T -> any: implicit tagged store (any value can hold any scalar/string/nil)
  if toT.isAny and (fromT.isScalar or fromT.isStringy or
                    fromT.isNiltype or fromT.isNilptr or
                    fromT.isRecord or fromT.isTable):
    return Conversion(kind: ckAnyStore, check: false)
  # any -> T: explicit load with a runtime tag check
  if fromT.isAny and (toT.isScalar or toT.isStringy):
    return Conversion(kind: ckAnyLoad, check: true)
  return Conversion(kind: ckNone)

# --- common type -------------------------------------------------------------

proc commonType*(a, b: Type): Type =
  if a == nil or b == nil:
    return nil
  if a == b:
    return a
  # nilptr is compatible with any pointer / optional
  if a.isNilptr and (b.isPointer or b.isOptional):
    return b
  if b.isNilptr and (a.isPointer or a.isOptional):
    return a
  # numeric widening
  if a.isIntegral and b.isIntegral:
    return widerIntegral(a, b)
  if a.isFloat and b.isFloat:
    return widerFloat(a, b)
  if (a.isIntegral and b.isFloat) or (a.isFloat and b.isIntegral):
    return widerFloat(a, b)
  if a.isStringy and b.isStringy:
    return BuiltinTypes["string"]
  # record / union / enum types must be identical
  if a.isRecord or a.isUnion or a.isEnum:
    return nil
  if b.isRecord or b.isUnion or b.isEnum:
    return nil
  if a.isPointer and b.isPointer:
    return GenericPointer
  return nil

# --- unary type rules (§3.3) -------------------------------------------------

proc inferUnary*(op: string, rhs: Type): (Type, Conversion) =
  let n = normalizeUnaryOp(op)
  let ident = Conversion(kind: ckIdentity)
  case n:
    of "not":
      (BuiltinTypes["boolean"], ident)
    of "unm":
      if rhs.isIntegral or rhs.isFloat:
        (rhs, ident)
      else:
        (nil, Conversion(kind: ckNone))
    of "len":
      if rhs.isRecord or rhs.isUnion or rhs.isEnum or rhs.isMetatype or rhs.isGeneric:
        # sizeOf a type -> usize
        (BuiltinTypes["usize"], ident)
      elif rhs.isArray or rhs.isStringy:
        (BuiltinTypes["integer"], ident)
      else:
        (nil, Conversion(kind: ckNone))
    of "bnot":
      if rhs.isIntegral:
        (rhs, ident)
      else:
        (nil, Conversion(kind: ckNone))
    of "ref":
      (pointerType(rhs), ident)
    of "deref":
      if rhs.isPointer:
        let sub = rhs.subtype
        if sub == nil or sub.isAny:
          (BuiltinTypes["void"], ident)
        else:
          (sub, ident)
      else:
        (nil, Conversion(kind: ckNone))
    else:
      (nil, Conversion(kind: ckNone))

# --- binary type rules (§3.3) ------------------------------------------------

proc inferBinary*(op: string, l, r: Type): (Type, Conversion, Conversion) =
  let o = normalizeBinaryOp(op)
  let ident = Conversion(kind: ckIdentity)
  let none = Conversion(kind: ckNone)
  ## A binary op whose operand failed to resolve (nil type) has no valid
  ## result.  Return nil rather than dereferencing a nil type here and
  ## SIGSEGVing -- the caller (analyzeBinaryOp) already tolerates a nil rtype,
  ## so an upvalue read inside `x + 1` exits with the diagnostic instead of
  ## crashing the whole compilation.
  if l == nil or r == nil:
    return (nil, none, none)
  case o:
    of "+", "-", "*":
      if l.isIntegral and r.isIntegral:
        let res = widerIntegral(l, r)
        (res, convert(l, res, false), convert(r, res, false))
      elif l.isFloat or r.isFloat:
        let res = widerFloat(l, r)
        (res, convert(l, res, false), convert(r, res, false))
      elif l.isStringy and r.isStringy:
        (BuiltinTypes["string"], ident, ident)
      else:
        (nil, none, none)
    of "/", "^^":
      let res =
        if l.isFloat or r.isFloat: widerFloat(l, r)
        else: BuiltinTypes["number"]
      (res, convert(l, res, false), convert(r, res, false))
    of "//", "%":
      if l.isIntegral and r.isIntegral:
        let res = widerIntegral(l, r)
        (res, convert(l, res, false), convert(r, res, false))
      else:
        (nil, none, none)
    of "..":
      (BuiltinTypes["string"], ident, ident)
    of "<", ">", "<=", ">=", "==", "~=":
      (BuiltinTypes["boolean"], ident, ident)
    of "and", "or":
      (BuiltinTypes["boolean"], ident, ident)
    of "&", "|", "~", "<<", ">>":
      if l.isIntegral and r.isIntegral:
        let res = widerIntegral(l, r)
        (res, convert(l, res, false), convert(r, res, false))
      else:
        (nil, none, none)
    else:
      (nil, none, none)

# --- call checking -----------------------------------------------------------

proc checkCall*(calleeType: Type, argTypes: seq[Type]): (bool, Type) =
  if calleeType == nil:
    return (false, nil)
  if calleeType.isFunction:
    if calleeType.args.len != argTypes.len:
      return (false, nil)
    for i, p in calleeType.args:
      let c = convert(argTypes[i], p, false)
      if c.kind == ckNone:
        return (false, nil)
    return (true, calleeType)
  # record / union / enum constructor, or cast target: calleeType is the type
  if calleeType.isRecord or calleeType.isUnion or calleeType.isEnum:
    return (true, calleeType)
  return (false, nil)

# --- literal typing ----------------------------------------------------------

proc litTypeOf*(node: Node): Type =
  if node == nil:
    return nil
  case node.kind:
    of nkNumber:
      if node.litType == "number": BuiltinTypes["number"]
      else: BuiltinTypes["integer"]
    of nkString:
      BuiltinTypes["string"]
    of nkBoolean:
      BuiltinTypes["boolean"]
    of nkNilptr:
      BuiltinTypes["nilptr"]
    of nkNil:
      BuiltinTypes["nil"]
    else:
      nil

# --- type-expression resolution ----------------------------------------------

proc resolveTypeExpr*(node: Node): Type =
  if node == nil:
    return nil
  case node.kind:
    of nkId:
      let name = node.str
      if BuiltinTypes.hasKey(name):
        return BuiltinTypes[name]
      if PrimitiveTypes.hasKey(name):
        return PrimitiveTypes[name]
      return nil
    of nkRecordType:
      var fields: seq[Field] = @[]
      for fnode in node.children:
        if fnode.kind == nkRecordField and fnode.children.len > 0:
          let ft = resolveTypeExpr(fnode.children[0])
          fields.add Field(name: fnode.str, typ: ft)
      return recordType(fields)
    of nkUnionType:
      var fields: seq[Field] = @[]
      for fnode in node.children:
        if fnode.kind == nkUnionField and fnode.children.len > 0:
          let ft = resolveTypeExpr(fnode.children[0])
          fields.add Field(name: fnode.str, typ: ft)
      return unionType(fields)
    of nkEnumType:
      let first = if node.children.len > 0: node.children[0] else: nil
      let underlying =
        if first != nil and first.kind == nkEnumField:
          BuiltinTypes["integer"]
        else:
          let t = resolveTypeExpr(first)
          if t != nil: t else: BuiltinTypes["integer"]
      var ef: seq[EnumField] = @[]
      for c in node.children:
        if c.kind == nkEnumField:
          let v =
            if c.children.len > 0:
              try: parseInt(c.children[0].str)
              except ValueError: 0
            else: 0
          ef.add EnumField(name: c.str, value: v)
      return enumType(underlying, ef)
    of nkArrayType:
      let sub = if node.children.len > 0: resolveTypeExpr(node.children[0]) else: nil
      let size =
        if node.children.len > 1:
          try: parseInt(node.children[1].str)
          except ValueError: 0
        else: 0
      return arrayType(sub, size)
    of nkPointerType:
      let sub = if node.children.len > 0: resolveTypeExpr(node.children[0]) else: nil
      if sub == nil:
        return GenericPointer
      return pointerType(sub)
    of nkFuncType:
      var args: seq[Type] = @[]
      var returns: seq[Type] = @[]
      var i = 0
      while i < node.children.len and node.children[i].kind == nkIdDecl:
        let at =
          if node.children[i].children.len > 0:
            resolveTypeExpr(node.children[i].children[0])
          else:
            nil
        args.add if at != nil: at else: BuiltinTypes["any"]
        inc i
      while i < node.children.len:
        let rt = resolveTypeExpr(node.children[i])
        if rt != nil:
          returns.add rt
        inc i
      return funcType(args, returns)
    of nkOptionalType:
      let sub = if node.children.len > 0: resolveTypeExpr(node.children[0]) else: nil
      return optionalType(sub)
    of nkGenericType:
      return genericType(node.str)
    of nkVariantType:
      var alts: seq[Type] = @[]
      for c in node.children:
        let t = resolveTypeExpr(c)
        if t != nil:
          alts.add t
      return variantType(alts)
    of nkType:
      # @typeexpr in value position: the node's type is the metatype `type`.
      return BuiltinTypes["type"]
    else:
      return nil

when isMainModule:
  let integer  = BuiltinTypes["integer"]
  let number   = BuiltinTypes["number"]
  let stringT  = BuiltinTypes["string"]
  let boolean  = BuiltinTypes["boolean"]
  let nilptr   = BuiltinTypes["nilptr"]
  let voidT    = BuiltinTypes["void"]
  let usizeT   = BuiltinTypes["usize"]
  let i8  = Type(kind: tkInt8,  name: "int8",  codename: "int8")
  let i64 = integer
  let f32 = Type(kind: tkFloat32, name: "float32", codename: "float32")
  let f64 = number
  let p1  = pointerType(integer)
  let pi  = pointerType(i8)
  let fnT = funcType(@[integer, integer], @[integer])

  # --- conversion matrix ---
  doAssert convert(i64, i64).kind == ckIdentity
  doAssert convert(i8, i64).kind == ckImplicit and convert(i8, i64).check == false
  doAssert convert(i64, i8).kind == ckImplicit and convert(i64, i8).check == true
  doAssert convert(i64, f64).kind == ckImplicit and convert(i64, f64).check == true
  doAssert convert(f32, f64).kind == ckImplicit and convert(f32, f64).check == false
  doAssert convert(f64, f32).kind == ckImplicit and convert(f64, f32).check == true
  doAssert convert(f64, f64).kind == ckIdentity
  doAssert convert(i64, p1).kind == ckNone
  doAssert convert(i64, p1, explicit=true).kind == ckExplicit
  doAssert convert(i64, p1, explicit=true).check == false
  doAssert convert(p1, p1).kind == ckIdentity
  doAssert convert(p1, pi).kind == ckImplicit and convert(p1, pi).check == false
  doAssert convert(fnT, p1, explicit=true).kind == ckExplicit
  doAssert convert(fnT, p1).kind == ckNone
  # nilptr -> typed pointer is no longer an implicit conversion (see the matrix
  # row above); nilptr -> optional still is.
  doAssert convert(nilptr, p1).kind == ckNone
  doAssert convert(boolean, i64).kind == ckImplicit and convert(boolean, i64).check == true
  doAssert convert(voidT, i64).kind == ckNone

  # --- 1 + 2.0 -> number ---
  let (rAdd, lcAdd, rcAdd) = inferBinary("+", integer, number)
  doAssert rAdd.isFloat and rAdd == number
  doAssert lcAdd.kind == ckImplicit and lcAdd.check == true   # int64 -> float64
  doAssert rcAdd.kind == ckIdentity                          # float64 -> float64

  # --- 1 + 1 -> integer ---
  let (rInt, _, _) = inferBinary("+", integer, integer)
  doAssert rInt.isIntegral and rInt == integer

  # --- a and b -> boolean ---
  let (rAnd, _, _) = inferBinary("and", integer, integer)
  doAssert rAnd.kind == tkBoolean
  let (rOr, _, _) = inferBinary("or", boolean, boolean)
  doAssert rOr.kind == tkBoolean

  # --- #rec -> usize ---
  let rec = recordType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: stringT),
  ])
  let (rLen, _) = inferUnary("len", rec)
  doAssert rLen.kind == tkUsize
  # symbolic name also works
  let (rLen2, _) = inferUnary("#", rec)
  doAssert rLen2.kind == tkUsize
  # len of a string value -> integer
  let (rStr, _) = inferUnary("len", stringT)
  doAssert rStr.kind == tkInteger
  # len of an array value -> integer
  let (rArr, _) = inferUnary("len", arrayType(integer, 3))
  doAssert rArr.kind == tkInteger

  # --- deref of generic pointer -> void ---
  let (rDeref, _) = inferUnary("deref", GenericPointer)
  doAssert rDeref.kind == tkVoid
  # symbolic name also works
  let (rDeref2, _) = inferUnary("$", GenericPointer)
  doAssert rDeref2.kind == tkVoid

  # --- *pointer(T) -> T ---
  let (rDerefT, _) = inferUnary("deref", p1)
  doAssert rDerefT == integer
  # ref of T -> pointer(T)
  let (rRef, _) = inferUnary("ref", integer)
  doAssert rRef.isPointer and rRef.subtype == integer

  # --- commonType ---
  doAssert commonType(integer, number) == number
  doAssert commonType(integer, integer) == integer
  doAssert commonType(nilptr, p1) == p1
  doAssert commonType(p1, nilptr) == p1
  doAssert commonType(rec, rec) == rec
  doAssert commonType(rec, boolean) == nil

  # --- checkCall ---
  let (ok1, spec1) = checkCall(fnT, @[integer, integer])
  doAssert ok1 and spec1 == fnT
  let (ok2, _) = checkCall(fnT, @[integer])
  doAssert not ok2
  let (ok3, spec3) = checkCall(rec, @[integer])
  doAssert ok3 and spec3 == rec

  # --- literal typing ---
  doAssert litTypeOf(newNumber("1", "integer")).kind == tkInteger
  doAssert litTypeOf(newNumber("1.5", "number")).kind == tkNumber
  doAssert litTypeOf(newString("hi")).kind == tkString
  doAssert litTypeOf(newBoolean(true)).kind == tkBoolean
  doAssert litTypeOf(newNilptr()).kind == tkNilptr
  doAssert litTypeOf(newNil()).kind == tkNiltype

  # --- resolveTypeExpr ---
  let rnode = newRecordType(@[
    newRecordField("x", newId("integer")),
    newRecordField("y", newId("string")),
  ])
  let rt = resolveTypeExpr(rnode)
  doAssert rt.isRecord
  doAssert rt.size == 24
  doAssert codename(rt) == "record{x: int64, y: nlstring}", codename(rt)
  doAssert rt == rec

  let anode = newArrayType(newId("integer"), newNumber("3"))
  let at = resolveTypeExpr(anode)
  doAssert at.isArray and at.arraySize == 3 and at.size == 24

  let pnode = newPointerType(newId("integer"))
  let pt = resolveTypeExpr(pnode)
  doAssert pt.isPointer and pt.subtype == integer

  let pnode2 = newPointerType(nil)
  let pt2 = resolveTypeExpr(pnode2)
  doAssert pt2.isPointer and pt2.subtype.isAny

  let fnode = newFuncType(
    @[newIdDecl("a", newId("integer")), newIdDecl("b", newId("integer"))],
    @[newId("integer")])
  let ft = resolveTypeExpr(fnode)
  doAssert ft.isFunction and ft.args.len == 2 and ft.returns.len == 1
  doAssert ft == fnT

  let enode = newEnumType(
    @[newEnumField("Red", newNumber("0")), newEnumField("Green", newNumber("1"))],
    newId("integer"))
  let et = resolveTypeExpr(enode)
  doAssert et.isEnum and et.enumFields.len == 2
  doAssert et.subtype == integer
  doAssert et.enumFields[0].value == 0
  doAssert codename(et) == "enum(int64){Red=0, Green=1}", codename(et)

  let onode = newOptionalType(newId("integer"))
  let ot = resolveTypeExpr(onode)
  doAssert ot.isOptional and ot.subtype == integer

  let vnode = newVariantType(@[newId("integer"), newId("boolean")])
  let vt = resolveTypeExpr(vnode)
  doAssert vt.isVariant and vt.args.len == 2

  let gnode = newGenericType("Vec2", @[newId("integer")])
  let gt = resolveTypeExpr(gnode)
  doAssert gt.isGeneric and gt.name == "Vec2"

  let tnode = newType(newId("integer"))
  let tt = resolveTypeExpr(tnode)
  doAssert tt.isMetatype

  echo "sema.nim OK"