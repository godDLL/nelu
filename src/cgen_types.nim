## C type mapping for the Nelua-in-Nim compiler (M3 foundation).
##
## Pure `Type` → C type spelling. Depends only on `types` (the M2 type
## hierarchy); it never touches the analyzer, so it can be built and tested
## before M2 lands.
##
## Spelling uses standard C99 types from <stdint.h>/<stdbool.h>. The `nl*`
## names (`nlstring`, `nilptr`, `nltype`, `nlopt_*`, `nlvariant`, `nlmr_*`)
## are typedefs the runtime / cgen visitor emit; this module only produces the
## spellings and leaves the definitions to them.

import types
import tables
import strutils

proc cTag*(t: Type): string =
  ## C tag (struct/union/enum) for a composite type. Named types use their
  ## sanitized Nelua name; anonymous types synthesize a tag from the canonical
  ## `typeid` so structurally-equal types share a tag.
  proc isCIdentChar(c: char, first: bool): bool =
    if first:
      (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'
    else:
      (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
      (c >= '0' and c <= '9') or c == '_'
  if t.name.len > 0 and isCIdentChar(t.name[0], true):
    var ok = true
    for i in 1 ..< t.name.len:
      if not isCIdentChar(t.name[i], false):
        ok = false
        break
    if ok:
      return t.name
  "nlrec" & $t.typeid

proc cFuncType*(t: Type): string   ## forward decl (cType ↔ cFuncType mutual recursion)

proc cType*(t: Type): string =
  ## The C type spelling of `t`. Returns `"void"` for `nil`.
  if t == nil:
    return "void"
  case t.kind:
    of tkNone, tkNiltype, tkVoid:
      "void"
    of tkBoolean:
      "bool"
    of tkString:
      "nlstring"
    of tkInteger:
      "int64_t"
    of tkUinteger:
      "uint64_t"
    of tkByte:
      "uint8_t"
    of tkIsize:
      "intptr_t"
    of tkUsize:
      "uintptr_t"
    of tkInt8:
      "int8_t"
    of tkInt16:
      "int16_t"
    of tkInt32:
      "int32_t"
    of tkInt64:
      "int64_t"
    of tkInt128:
      "__int128_t"
    of tkUint8:
      "uint8_t"
    of tkUint16:
      "uint16_t"
    of tkUint32:
      "uint32_t"
    of tkUint64:
      "uint64_t"
    of tkUint128:
      "__uint128_t"
    of tkNumber:
      "double"
    of tkFloat32:
      "float"
    of tkFloat64:
      "double"
    of tkFloat128:
      "long double"
    of tkCchar:
      "char"
    of tkCschar:
      "signed char"
    of tkCuchar:
      "unsigned char"
    of tkCshort:
      "short"
    of tkCushort:
      "unsigned short"
    of tkCint:
      "int"
    of tkCuint:
      "unsigned int"
    of tkCfloat:
      "float"
    of tkCdouble:
      "double"
    of tkClong:
      "long"
    of tkCulong:
      "unsigned long"
    of tkClonglong:
      "long long"
    of tkCulonglong:
      "unsigned long long"
    of tkCptrdiff:
      "ptrdiff_t"
    of tkCsize:
      "size_t"
    of tkClongdouble:
      "long double"
    of tkCstring:
      "const char*"
    of tkCvalist:
      "va_list"
    of tkCvarargs:
      "..."
    of tkAuto:
      "auto"
    of tkAny:
      "void"
    of tkVarargs, tkVaranys:
      "..."
    of tkPointer:
      if t.subtype == nil or t.subtype.isAny:
        "void*"
      elif t.subtype.isArray:
        "(" & cType(t.subtype) & ")*"
      else:
        cType(t.subtype) & "*"
    of tkNilptr:
      "nilptr"
    of tkArray:
      let e = if t.subtype == nil: "void" else: cType(t.subtype)
      if t.arraySize <= 0:
        e & "[]"
      else:
        e & "[" & $t.arraySize & "]"
    of tkRecord:
      "struct " & cTag(t)
    of tkUnion:
      "union " & cTag(t)
    of tkEnum:
      # C1: `@enum` lowers to `typedef <underlying> <tag>;` (no C enum body),
      # so the enum's C spelling is just the typedef name -- the enum fields
      # are compile-time constants folded by the analyzer, never emitted as C
      # enum constants.
      cTag(t)
    of tkFunction:
      cFuncType(t)
    of tkOptional:
      if t.subtype == nil:
        "nlopt_void"
      else:
        "nlopt_" & cType(t.subtype)
    of tkVariant:
      "nlvariant" & $t.typeid
    of tkTable:
      "nltable"
    of tkGeneric:
      "nlgeneric"
    of tkMetatype:
      "const nltype*"
    of tkTypeof:
      if t.subtype == nil: "void" else: cType(t.subtype)

proc cConstType*(t: Type): string =
  ## `const`-qualified spelling of `t`. Types already const-qualified
  ## (`const char*`, `const nltype*`) are returned unchanged; pointer types get
  ## `T* const` (const pointer, not pointer-to-const).
  if t == nil:
    return "const void"
  let ct = cType(t)
  if ct.startswith("const"):
    return ct
  if t.kind == tkPointer:
    return ct & " const"
  "const " & ct

proc multiRetTag*(returns: seq[Type]): string =
  ## Tag for the small struct that replaces a multi-value return.
  result = "nlmr"
  for r in returns:
    result &= "_" & cType(r).replace(" ", "_").replace(",", "_")

proc cFuncType*(t: Type): string =
  ## Function-pointer spelling: `ret (*)(p1, p2, ...)`. Zero params/returns use
  ## `void`; multiple returns use the multi-return struct tag.
  if t == nil:
    return "void (*)(void)"
  let ret = if t.returns.len == 0:
      "void"
    elif t.returns.len == 1:
      cType(t.returns[0])
    else:
      multiRetTag(t.returns)
  var params: seq[string] = @[]
  for a in t.args:
    if a != nil and a.kind in {tkVarargs, tkVaranys, tkCvarargs}:
      params.add "..."
    else:
      params.add if a == nil: "void" else: cType(a)
  let paramStr = if params.len == 0: "void" else: params.join(", ")
  ret & " (*)(" & paramStr & ")"

when isMainModule:
  let integer  = BuiltinTypes["integer"]
  # `uinteger` is not in the bootstrap table; synthesize its primitive for the
  # mapping test only (the analyzer would build it the same way).
  let uinteger = Type(kind: tkUinteger, name: "uinteger", codename: "uinteger")
  let number   = BuiltinTypes["number"]
  let stringT  = BuiltinTypes["string"]
  let boolean  = BuiltinTypes["boolean"]
  let nilptr   = BuiltinTypes["nilptr"]
  let voidT    = BuiltinTypes["void"]
  let auto     = BuiltinTypes["auto"]
  let anyT     = BuiltinTypes["any"]
  let niltype  = BuiltinTypes["nil"]
  let usizeT   = BuiltinTypes["usize"]
  let isizeT   = BuiltinTypes["isize"]
  let byteT    = BuiltinTypes["byte"]

  # Non-bootstrapped primitives the analyzer builds from user type expressions.
  let int8  = Type(kind: tkInt8,   name: "int8",   codename: "int8",   isSigned: true)
  let int16 = Type(kind: tkInt16,  name: "int16",  codename: "int16",  isSigned: true)
  let int32 = Type(kind: tkInt32,  name: "int32",  codename: "int32",  isSigned: true)
  let int64 = Type(kind: tkInt64,  name: "int64",  codename: "int64",  isSigned: true)
  let int128= Type(kind: tkInt128, name: "int128", codename: "int128", isSigned: true)
  let uint8 = Type(kind: tkUint8,  name: "uint8",  codename: "uint8")
  let uint16= Type(kind: tkUint16, name: "uint16", codename: "uint16")
  let uint32= Type(kind: tkUint32, name: "uint32", codename: "uint32")
  let uint64= Type(kind: tkUint64, name: "uint64", codename: "uint64")
  let uint128=Type(kind: tkUint128,name: "uint128",codename: "uint128")
  let flt32 = Type(kind: tkFloat32, name: "float32", codename: "float32")
  let flt64 = Type(kind: tkFloat64, name: "float64", codename: "float64")
  let flt128= Type(kind: tkFloat128,name: "float128",codename: "float128")
  let cchar  = BuiltinTypes["cchar"]
  let cschar = BuiltinTypes["cschar"]
  let cuchar = BuiltinTypes["cuchar"]
  let cshort = BuiltinTypes["cshort"]
  let cushort= BuiltinTypes["cushort"]
  let cint   = BuiltinTypes["cint"]
  let cuint  = BuiltinTypes["cuint"]
  let cfloat = BuiltinTypes["cfloat"]
  let cdouble= BuiltinTypes["cdouble"]
  let clong  = BuiltinTypes["clong"]
  let culong = BuiltinTypes["culong"]
  let cllong = Type(kind: tkClonglong, name: "clonglong", codename: "clonglong", isSigned: true)
  let cullong= Type(kind: tkCulonglong, name: "culonglong", codename: "culonglong")
  let cptrdiff = Type(kind: tkCptrdiff, name: "cptrdiff", codename: "cptrdiff")
  let csize    = Type(kind: tkCsize,    name: "csize",    codename: "csize")
  let clongdouble = Type(kind: tkClongdouble, name: "clongdouble", codename: "clongdouble")
  let cvalist  = Type(kind: tkCvalist,  name: "cvalist",  codename: "cvalist")
  let cvarargs = Type(kind: tkCvarargs, name: "cvarargs", codename: "cvarargs")
  let cstring  = Type(kind: tkCstring, name: "cstring", codename: "cstring")

  # --- primitives ---
  doAssert cType(integer)  == "int64_t",   cType(integer)
  doAssert cType(uinteger) == "uint64_t",  cType(uinteger)
  doAssert cType(number)   == "double",    cType(number)
  doAssert cType(stringT)  == "nlstring",  cType(stringT)
  doAssert cType(boolean)  == "bool",      cType(boolean)
  doAssert cType(byteT)    == "uint8_t",   cType(byteT)
  doAssert cType(isizeT)   == "intptr_t",  cType(isizeT)
  doAssert cType(usizeT)   == "uintptr_t", cType(usizeT)
  doAssert cType(niltype)  == "void",      cType(niltype)
  doAssert cType(voidT)    == "void",      cType(voidT)
  doAssert cType(auto)     == "auto",      cType(auto)
  doAssert cType(anyT)     == "void",      cType(anyT)
  doAssert cType(nilptr)   == "nilptr",    cType(nilptr)

  doAssert cType(int8)   == "int8_t",       cType(int8)
  doAssert cType(int16)  == "int16_t",      cType(int16)
  doAssert cType(int32)  == "int32_t",      cType(int32)
  doAssert cType(int64)  == "int64_t",      cType(int64)
  doAssert cType(int128) == "__int128_t",   cType(int128)
  doAssert cType(uint8)  == "uint8_t",      cType(uint8)
  doAssert cType(uint16) == "uint16_t",     cType(uint16)
  doAssert cType(uint32) == "uint32_t",     cType(uint32)
  doAssert cType(uint64) == "uint64_t",     cType(uint64)
  doAssert cType(uint128) == "__uint128_t", cType(uint128)

  doAssert cType(flt32)  == "float",        cType(flt32)
  doAssert cType(flt64)  == "double",       cType(flt64)
  doAssert cType(flt128) == "long double",  cType(flt128)

  doAssert cType(cchar)    == "char",            cType(cchar)
  doAssert cType(cschar)   == "signed char",     cType(cschar)
  doAssert cType(cuchar)   == "unsigned char",    cType(cuchar)
  doAssert cType(cshort)   == "short",            cType(cshort)
  doAssert cType(cushort)  == "unsigned short",   cType(cushort)
  doAssert cType(cint)     == "int",              cType(cint)
  doAssert cType(cuint)    == "unsigned int",      cType(cuint)
  doAssert cType(cfloat)   == "float",            cType(cfloat)
  doAssert cType(cdouble)  == "double",           cType(cdouble)
  doAssert cType(clong)    == "long",             cType(clong)
  doAssert cType(culong)   == "unsigned long",     cType(culong)
  doAssert cType(cllong)   == "long long",        cType(cllong)
  doAssert cType(cullong)  == "unsigned long long", cType(cullong)
  doAssert cType(cptrdiff) == "ptrdiff_t",       cType(cptrdiff)
  doAssert cType(csize)    == "size_t",           cType(csize)
  doAssert cType(clongdouble) == "long double",  cType(clongdouble)
  doAssert cType(cvalist)  == "va_list",          cType(cvalist)
  doAssert cType(cvarargs) == "...",              cType(cvarargs)
  doAssert cType(cstring)  == "const char*",      cType(cstring)

  # --- const qualification ---
  doAssert cConstType(integer) == "const int64_t",   cConstType(integer)
  doAssert cConstType(boolean) == "const bool",      cConstType(boolean)
  doAssert cConstType(number)  == "const double",    cConstType(number)
  doAssert cConstType(cstring) == "const char*",     cConstType(cstring)
  doAssert cConstType(nilptr)  == "const nilptr",    cConstType(nilptr)
  doAssert cConstType(voidT)   == "const void",      cConstType(voidT)

  # --- composite: array, pointer ---
  let arr = arrayType(integer, 3)
  doAssert cType(arr) == "int64_t[3]",        cType(arr)
  let arr0 = arrayType(integer, 0)
  doAssert cType(arr0) == "int64_t[]", cType(arr0)
  let ptri = pointerType(integer)
  doAssert cType(ptri) == "int64_t*",        cType(ptri)
  let ptrAny = pointerType(anyT)
  doAssert cType(ptrAny) == "void*",         cType(ptrAny)
  let ptrarr = pointerType(arrayType(integer, 2))
  doAssert cType(ptrarr) == "(int64_t[2])*", cType(ptrarr)
  doAssert cConstType(ptri) == "int64_t* const", cConstType(ptri)

  # --- composite: record, union, enum ---
  let rec = recordType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: boolean),
  ])
  doAssert cType(rec) == "struct nlrec" & $rec.typeid, cType(rec)
  doAssert cConstType(rec) == "const struct nlrec" & $rec.typeid, cConstType(rec)

  let uni = unionType(@[
    Field(name: "X", typ: integer),
    Field(name: "Y", typ: stringT),
  ])
  doAssert cType(uni) == "union nlrec" & $uni.typeid, cType(uni)

  let en = enumType(integer, @[
    EnumField(name: "Red",   value: 0),
    EnumField(name: "Green", value: 1),
    EnumField(name: "Blue",  value: 2),
  ])
  doAssert cType(en) == "nlrec" & $en.typeid, cType(en)

  # --- function / function pointer ---
  let fn = funcType(@[integer, integer], @[integer])
  doAssert cFuncType(fn) == "int64_t (*)(int64_t, int64_t)", cFuncType(fn)
  doAssert cType(fn) == cFuncType(fn)
  let fn0 = funcType(@[], @[])
  doAssert cFuncType(fn0) == "void (*)(void)", cFuncType(fn0)
  let fnMulti = funcType(@[integer, boolean], @[integer, boolean])
  doAssert cFuncType(fnMulti) == "nlmr_int64_t_bool (*)(int64_t, bool)", cFuncType(fnMulti)

  # --- optional, variant, metatype, typeof ---
  let opt = optionalType(integer)
  doAssert cType(opt) == "nlopt_int64_t",     cType(opt)
  let optStr = optionalType(stringT)
  doAssert cType(optStr) == "nlopt_nlstring",  cType(optStr)
  let varT = variantType(@[integer, boolean])
  doAssert cType(varT) == "nlvariant" & $varT.typeid, cType(varT)
  doAssert cType(BuiltinTypes["type"]) == "const nltype*", cType(BuiltinTypes["type"])
  let typeofInt = Type(kind: tkTypeof, subtype: integer)
  doAssert cType(typeofInt) == "int64_t", cType(typeofInt)

  echo "cgen_types.nim OK"