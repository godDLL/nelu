## M5 runtime type descriptors for the Nelua-in-Nim compiler.
##
## Emits the runtime type-info table the generated C links against: a `Type`
## → descriptor-tag mapping that M3 codegen consults for `traits.typeidof`,
## runtime `any` dispatch, and GC tracing.
##
## Layout-free by contract: this module emits NAMES and metadata only, never
## struct bodies. The struct definitions live in the generated C (`runtime.c`
## and the cgen visitor). Tag names are valid C identifiers and unique per
## canonicalized type.
##
## Depends on `types.nim` only — not on the analyzer (M2) and not on M3's
## codegen. The C-type spellings for `typeDescFields` are inlined here (mirroring
## `cgen_types.cType`) so the module stays self-contained. `typeid` values are
## sourced from `types.TypeCounter`, so a canonicalized type's descriptor id
## always matches the C struct/union/enum tag the codegen emits for it.

import tables
import strutils
import types

# --- module-level state -------------------------------------------------------

proc hash(t: Type): int =
  ## Identity hash for `Type` refs so they can key `Table[Type, V]`. Two
  ## canonicalized types that are `==` share an address and therefore a hash.
  cast[int](t)

var typeDescriptors*: Table[Type, string]   ## live registry: Type -> descriptor tag

proc kindName(t: Type): string =
  ## Short lowercase tag describing the type's runtime descriptor class.
  case t.kind:
    of tkNone: "none"
    of tkNiltype: "niltype"
    of tkVoid: "void"
    of tkBoolean: "boolean"
    of tkString: "string"
    of tkInteger: "integer"
    of tkUinteger: "uinteger"
    of tkNumber: "number"
    of tkByte: "byte"
    of tkIsize: "isize"
    of tkUsize: "usize"
    of tkInt8: "int8"
    of tkInt16: "int16"
    of tkInt32: "int32"
    of tkInt64: "int64"
    of tkInt128: "int128"
    of tkUint8: "uint8"
    of tkUint16: "uint16"
    of tkUint32: "uint32"
    of tkUint64: "uint64"
    of tkUint128: "uint128"
    of tkFloat32: "float32"
    of tkFloat64: "float64"
    of tkFloat128: "float128"
    of tkCchar: "cchar"
    of tkCschar: "cschar"
    of tkCuchar: "cuchar"
    of tkCshort: "cshort"
    of tkCushort: "cushort"
    of tkCint: "cint"
    of tkCuint: "cuint"
    of tkCfloat: "cfloat"
    of tkCdouble: "cdouble"
    of tkClong: "clong"
    of tkCulong: "culong"
    of tkClonglong: "clonglong"
    of tkCulonglong: "culonglong"
    of tkCptrdiff: "cptrdiff"
    of tkCsize: "csize"
    of tkClongdouble: "clongdouble"
    of tkCstring: "cstring"
    of tkCvalist: "cvalist"
    of tkCvarargs: "cvarargs"
    of tkAuto: "auto"
    of tkAny: "any"
    of tkVarargs: "varargs"
    of tkVaranys: "varanys"
    of tkPointer: "pointer"
    of tkNilptr: "nilptr"
    of tkArray: "array"
    of tkRecord: "record"
    of tkUnion: "union"
    of tkEnum: "enum"
    of tkFunction: "function"
    of tkOptional: "optional"
    of tkVariant: "variant"
    of tkTable: "table"
    of tkGeneric: "generic"
    of tkMetatype: "metatype"
    of tkTypeof: "typeof"

proc cTypeStr(t: Type): string =
  ## Inline C-type spelling. Mirrors `cgen_types.cType` (and `cFuncType` for
  ## function types) so this module needs no dependency on the M3 codegen.
  if t == nil:
    return "void"
  case t.kind:
    of tkNone, tkNiltype, tkVoid: "void"
    of tkBoolean: "bool"
    of tkString: "nlstring"
    of tkInteger: "int64_t"
    of tkUinteger: "uint64_t"
    of tkByte: "uint8_t"
    of tkIsize: "intptr_t"
    of tkUsize: "uintptr_t"
    of tkInt8: "int8_t"
    of tkInt16: "int16_t"
    of tkInt32: "int32_t"
    of tkInt64: "int64_t"
    of tkInt128: "__int128_t"
    of tkUint8: "uint8_t"
    of tkUint16: "uint16_t"
    of tkUint32: "uint32_t"
    of tkUint64: "uint64_t"
    of tkUint128: "__uint128_t"
    of tkNumber: "double"
    of tkFloat32: "float"
    of tkFloat64: "double"
    of tkFloat128: "long double"
    of tkCchar: "char"
    of tkCschar: "signed char"
    of tkCuchar: "unsigned char"
    of tkCshort: "short"
    of tkCushort: "unsigned short"
    of tkCint: "int"
    of tkCuint: "unsigned int"
    of tkCfloat: "float"
    of tkCdouble: "double"
    of tkClong: "long"
    of tkCulong: "unsigned long"
    of tkClonglong: "long long"
    of tkCulonglong: "unsigned long long"
    of tkCptrdiff: "ptrdiff_t"
    of tkCsize: "size_t"
    of tkClongdouble: "long double"
    of tkCstring: "const char*"
    of tkCvalist: "va_list"
    of tkCvarargs: "..."
    of tkAuto: "auto"
    of tkAny: "void*"
    of tkVarargs, tkVaranys: "..."
    of tkPointer:
      if t.subtype == nil or t.subtype.isAny:
        "void*"
      elif t.subtype.isArray:
        "(" & cTypeStr(t.subtype) & ")*"
      else:
        cTypeStr(t.subtype) & "*"
    of tkNilptr: "nilptr"
    of tkArray:
      let e = if t.subtype == nil: "void" else: cTypeStr(t.subtype)
      if t.arraySize <= 0:
        e & "[]"
      else:
        e & "[" & $t.arraySize & "]"
    of tkRecord: "struct nlrec" & $t.typeid
    of tkUnion: "union nlrec" & $t.typeid
    of tkEnum: "enum nlrec" & $t.typeid
    of tkFunction:
      let ret = if t.returns.len == 0:
          "void"
        elif t.returns.len == 1:
          cTypeStr(t.returns[0])
        else:
          var s = "nlmr"
          for r in t.returns:
            s &= "_" & cTypeStr(r).replace(" ", "_").replace(",", "_")
          s
      var params: seq[string] = @[]
      for a in t.args:
        if a != nil and a.kind in {tkVarargs, tkVaranys, tkCvarargs}:
          params.add "..."
        else:
          params.add if a == nil: "void" else: cTypeStr(a)
      let paramStr = if params.len == 0: "void" else: params.join(", ")
      ret & " (*)(" & paramStr & ")"
    of tkOptional:
      if t.subtype == nil:
        "nlopt_void"
      else:
        "nlopt_" & cTypeStr(t.subtype)
    of tkVariant: "nlvariant" & $t.typeid
    of tkTable: "nltable"
    of tkGeneric: "nlgeneric"
    of tkMetatype: "const nltype*"
    of tkTypeof:
      if t.subtype == nil: "void" else: cTypeStr(t.subtype)

proc typeidOf*(t: Type): int =
  ## A stable per-structure id, assigned from `types.TypeCounter` on first
  ## request. The same canonicalized `Type` object always returns the same id;
  ## two structurally different records are different objects and get different
  ## ids. The id matches the `typeid` the codegen uses for C struct/union/enum
  ## tags, so descriptor ids and composite tags agree for every type.
  if t == nil:
    return 0
  if t.typeid != 0:
    return t.typeid
  inc TypeCounter
  t.typeid = TypeCounter
  t.typeid

proc registerType*(t: Type): string =
  ## Idempotent descriptor registration. Returns the descriptor tag, storing it
  ## in `typeDescriptors` so subsequent lookups are O(1). The bootstrap calls
  ## this for every builtin type at module init.
  if t == nil:
    return ""
  if t in typeDescriptors:
    return typeDescriptors[t]
  let tag = "nltype_" & kindName(t) & "_" & $typeidOf(t)
  typeDescriptors[t] = tag
  tag

proc typeDesc*(t: Type): string =
  ## The C struct/union tag name for the type's runtime descriptor (e.g.
  ## `nltype_record_1234`). Allocated once per canonicalized `Type` and stable
  ## across calls; consults the live `typeDescriptors` registry.
  if t == nil:
    return ""
  if t in typeDescriptors:
    return typeDescriptors[t]
  registerType(t)

proc needsTrace*(t: Type): bool =
  ## Does the type hold GC-traced pointers? True for `string`, `pointer`,
  ## `nilptr`, `any` (universal pointer), `optional` containing a traced type,
  ## `record`/`union` with any traced field, `function` pointer, and
  ## `variant`/`generic`/`typeof` whose element/alternative is traced. False
  ## for integers, floats, booleans, void, enums, arrays of non-traced
  ## elements, and borrowed/C types (`cstring`, C primitives).
  if t == nil:
    return false
  case t.kind:
    of tkString, tkPointer, tkNilptr, tkFunction, tkAny:
      true
    of tkOptional:
      t.subtype != nil and needsTrace(t.subtype)
    of tkArray:
      t.subtype != nil and needsTrace(t.subtype)
    of tkTypeof:
      t.subtype != nil and needsTrace(t.subtype)
    of tkRecord, tkUnion:
      for f in t.fields:
        if f.typ != nil and needsTrace(f.typ):
          return true
      false
    of tkVariant:
      for a in t.args:
        if a != nil and needsTrace(a):
          return true
      false
    of tkGeneric:
      for a in t.args:
        if a != nil and needsTrace(a):
          return true
      false
    else:
      false

proc typeDescFields*(t: Type): seq[(string, string)] =
  ## For records/unions: `(fieldname, fieldCtype)` pairs, so the codegen can
  ## emit a per-type trace function walking its fields. Empty for other kinds.
  result = @[]
  if t == nil:
    return
  if t.kind notin {tkRecord, tkUnion}:
    return
  for f in t.fields:
    let ft = if f.typ != nil: cTypeStr(f.typ) else: "void"
    result.add (f.name, ft)

# --- bootstrap: register every builtin type -----------------------------------

typeDescriptors = initTable[Type, string]()
for t in BuiltinTypes.values:
  discard registerType(t)

when isMainModule:
  let integer  = BuiltinTypes["integer"]
  let boolean  = BuiltinTypes["boolean"]
  let stringT  = BuiltinTypes["string"]

  # --- needsTrace ---
  doAssert needsTrace(pointerType(stringT)) == true, "pointer(string)"
  doAssert needsTrace(recordType(@[
      Field(name: "a", typ: integer),
      Field(name: "b", typ: pointerType(integer)),
  ])) == true, "record{a:integer,b:pointer(integer)}"
  doAssert needsTrace(optionalType(pointerType(integer))) == true, "optional(pointer(integer))"
  doAssert needsTrace(integer) == false, "integer"
  doAssert needsTrace(boolean) == false, "boolean"
  doAssert needsTrace(arrayType(integer, 3)) == false, "array(integer,3)"
  let enumT = enumType(integer, @[EnumField(name: "Red", value: 0)])
  doAssert needsTrace(enumT) == false, "enum"

  # --- typeidOf: stable, distinct for different records, shared for canonicalized ---
  let rec1 = recordType(@[Field(name: "x", typ: integer), Field(name: "y", typ: boolean)])
  let rec2 = recordType(@[Field(name: "x", typ: integer), Field(name: "y", typ: boolean)])
  doAssert rec1 == rec2, "canonicalized records share an object via TypeCache"
  let id1 = typeidOf(rec1)
  doAssert typeidOf(rec1) == id1, "typeidOf stable across calls"
  doAssert typeidOf(rec2) == id1, "same canonicalized record shares its id"
  let rec3 = recordType(@[Field(name: "x", typ: integer), Field(name: "y", typ: integer)])
  doAssert rec3 != rec1, "structurally different records are distinct objects"
  doAssert typeidOf(rec3) != id1, "structurally different records get distinct ids"

  # --- descriptor tags ---
  echo "record descriptor:   " & typeDesc(rec1)
  echo "pointer descriptor: " & typeDesc(pointerType(integer))

  echo "typedesc.nim OK"