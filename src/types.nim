## Type hierarchy for the Nelua-in-Nim analyzer (M2 Task 1).
##
## Implements design §3.1 (Type hierarchy), §3.2 (Attr payload), §5 (query surface).
## The Type object is the single typed-AST representation M4 codegen consumes.
##
## NOTE on `codename`: per the design §3.1 / §5, `codename` is the *C identifier*
## the codegen emits (e.g. `double`, `nlstring`, `bool`, `char`). It is deliberately
## NOT the Nelua-level analyzed-AST `type=` string the reference oracle dumps
## (which uses `float64`/`string`/`boolean`/`cchar`). Task 3's dump printer must
## render `type=` from a separate Nelua-level string; see the deviation report.

import tables
import strutils
import ast

type
  TypeKind* = enum
    tkNone, tkNiltype, tkVoid, tkBoolean, tkString,
    tkInteger, tkUinteger, tkNumber, tkByte, tkIsize, tkUsize,
    tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
    tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
    tkFloat32, tkFloat64, tkFloat128,
    tkCchar, tkCschar, tkCuchar, tkCshort, tkCushort, tkCint, tkCuint,
    tkCfloat, tkCdouble,
    tkClong, tkCulong, tkClonglong, tkCulonglong, tkCptrdiff, tkCsize,
    tkClongdouble, tkCstring, tkCvalist, tkCvarargs,
    tkAuto, tkAny, tkVarargs, tkVaranys,
    tkPointer, tkNilptr,
    tkArray, tkRecord, tkUnion, tkEnum, tkFunction,
    tkOptional, tkVariant, tkTable, tkGeneric, tkMetatype, tkTypeof

  Type* = ref object
    kind*: TypeKind           ## the tag
    name*: string             ## Nelua nickname (for named/generic types)
    codename*: string         ## C identifier (primitives) / structural string (composites)
    subtype*: Type            ## pointer / array / optional / typeof element
    arraySize*: int           ## array bound (0 = unbounded)
    fields*: seq[Field]       ## record / union fields
    metafields*: Table[string, Type]  ## metamethods (__add, __index, ...)
    enumFields*: seq[EnumField]
    args*: seq[Type]          ## function parameter types; variant alternatives
    returns*: seq[Type]       ## function return types
    isSigned*: bool
    typeid*: int
    note*: string             ## optional human note (e.g. "unsupported")
    funcRef*: int             ## Lua registry ref for a concept/generic function (0 = none)
    methods*: Table[string, MethodDesc]  ## colon-methods defined on this type
    ## §8 shaper booleans -- the hand-picked subset the stdlib and the splice
    ## probes read.  Derived ones are filled by `computeShaper` at type
    ## construction; the container family (is_span/is_sequence/...) is left
    ## false unless a lib definition sets it (our clean-room type system does
    ## not recognise lib types, which matches the oracle for non-lib types).
    is_oneindexing*: bool
    is_sequence*: bool
    is_span*: bool
    is_vector*: bool
    is_list*: bool
    is_hashmap*: bool
    is_contiguous*: bool
    is_container*: bool
    is_scalar*: bool
    is_arithmetic*: bool
    is_float*: bool
    is_integral*: bool
    is_stringy*: bool
    is_boolean*: bool
    is_string*: bool
    is_cstring*: bool
    is_record*: bool
    is_union*: bool
    is_enum*: bool
    is_function*: bool
    is_procedure*: bool
    is_pointer*: bool
    is_nilptr*: bool
    is_array*: bool
    is_optional*: bool
    is_variant*: bool
    is_table*: bool
    is_concept*: bool
    is_generic*: bool
    is_comptime*: bool
    is_polymorphic*: bool
    is_nilable*: bool
    is_unpointable*: bool
    is_nameable*: bool
    is_nolvalue*: bool
    is_nodecl*: bool
    is_overload*: bool
    is_facultative*: bool
    is_composite*: bool
    is_aggregate*: bool
    is_empty*: bool
    is_multipleargs*: bool
    is_falseable*: bool
    is_auto*: bool
    is_any*: bool
    is_varargs*: bool
    is_varanys*: bool
    is_void*: bool
    is_niltype*: bool
    is_type*: bool
    nickname*: string         ## Nelua nickname for named types; "" for primitives

  MethodDesc* = object
    sym*: Symbol              ## the defining function symbol
    codename*: string         ## C function name (<unit>_<Record>_<method>)
    ftype*: Type              ## full function type (args incl. self, returns)

  Field* = object
    name*: string
    typ*: Type
    offset*: int              ## filled by M4 layout

  EnumField* = object
    name*: string
    value*: int

  ConversionKind* = enum
    ckNone, ckIdentity, ckImplicit, ckExplicit, ckNarrow,
    ckAnyStore, ckAnyLoad
  Conversion* = ref object
    kind*: ConversionKind
    check*: bool             ## emit runtime narrow check in debug builds
    via*: Type               ## intermediate type for promotion

  SymbolKind* = enum
    skUnknown, skVar, skConst, skFunc, skType, skParam, skField, skEnumField, skBuiltin

  Symbol* = ref object
    name*: string
    typ*: Type
    kind*: SymbolKind
    node*: Node              ## declaring node (IdDecl / FuncDef), nil for builtins
    scope*: Scope
    used*: bool
    comptime*: bool
    isConst*: bool
    global*: bool
    staticstorage*: bool
    codename*: string
    mutate*: bool
    refed*: bool
    vardecl*: bool
    value*: string           ## comptime literal value (set for <comptime> vardecls)

  Scope* = ref object
    name*: string
    symbols*: Table[string, Symbol]
    parent*: Scope
    isFunction*: bool          ## true for scopes pushed by a function body

  Attr* = ref object
    ## Per-node analysis payload. Filled by M2, read by M4 codegen.
    typ*: Type                ## resolved type; nil for pure statements
    lvalue*: bool             ## assignable / addressable
    comptime*: bool           ## value known at compile time
    isConst*: bool            ## <const>
    noinit*: bool             ## <noinit>
    isClose*: bool            ## <close>
    isVolatile*: bool         ## <volatile>
    isInline*: bool           ## <inline>
    cimport*: bool            ## <cimport>
    cexport*: bool            ## <cexport>
    codename*: string         ## C identifier (symbols, types, function names)
    nodecl*: bool             ## <nodecl>
    cinclude*: string         ## <cinclude '...'>
    value*: string            ## compile-time literal value
    name*: string             ## Nelua name
    used*: bool               ## symbol is referenced (dead-code input)
    vardecl*: bool            ## this IdDecl declares a variable
    global*: bool             ## refers to a global symbol
    staticstorage*: bool      ## lives in static storage (top scope)
    mutate*: bool             ## variable assigned more than once
    refed*: bool              ## value passed by pointer (method receiver, &)
    base*: int                ## Number radix
    forcesymbol*: string      ## declaration source for a type symbol
    filename*: string         ## Block: source file
    conv*: Conversion         ## pending implicit conversion
    calleeSym*: Symbol        ## Call/CallMethod: resolved callee symbol
    calleeType*: Type         ## Call: type callee (record ctor / cast target)
    isConstructor*: bool      ## Call: record/enum constructor (compound literal)
    isTypeBinding*: bool      ## VarDecl: `local X = @record/@enum` binds a TYPE
    isMethod*: bool           ## CallMethod
    isMethodCall*: bool       ## DotIndex caller of a method (R.m(args))
    dotFieldName*: string     ## DotIndex/ColonIndex
    parentType*: Type         ## Pair: enclosing record/union type
    polySpec*: Node           ## Call into a polymorphic func: the specialization node
    unsupported*: bool        ## node involves any/table/dynamic (M4 must error)

# --- property procs (§3.1 / §5) ----------------------------------------------

proc isIntegral*(t: Type): bool =
  t != nil and t.kind in {tkInteger, tkUinteger, tkByte, tkIsize, tkUsize,
    tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
    tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
    tkCchar, tkCschar, tkCuchar, tkCshort, tkCushort, tkCint, tkCuint,
    tkClong, tkCulong, tkClonglong, tkCulonglong, tkCptrdiff, tkCsize}

proc isUnsigned*(t: Type): bool =
  t != nil and t.kind in {tkUinteger, tkUint8, tkUint16, tkUint32, tkUint64,
    tkUint128, tkUsize, tkCuchar, tkCushort, tkCuint, tkCulong,
    tkCulonglong, tkCsize}

proc isFloat*(t: Type): bool =
  t != nil and t.kind in {tkNumber, tkFloat32, tkFloat64, tkFloat128,
    tkCfloat, tkCdouble, tkClongdouble}

proc isScalar*(t: Type): bool =
  t != nil and (t.isIntegral or t.isFloat or t.kind == tkBoolean or
    t.kind == tkNilptr or t.kind == tkPointer or t.kind == tkEnum)

proc isBoolean*(t: Type): bool =
  t != nil and t.kind == tkBoolean

proc isStringy*(t: Type): bool =
  t != nil and (t.kind == tkString or t.kind == tkCstring)

proc isPointer*(t: Type): bool = t != nil and t.kind == tkPointer
proc isNilptr*(t: Type): bool = t != nil and t.kind == tkNilptr
proc isArray*(t: Type): bool = t != nil and t.kind == tkArray
proc isRecord*(t: Type): bool = t != nil and t.kind == tkRecord
proc isUnion*(t: Type): bool = t != nil and t.kind == tkUnion
proc isEnum*(t: Type): bool = t != nil and t.kind == tkEnum
proc isFunction*(t: Type): bool = t != nil and t.kind == tkFunction
proc isNiltype*(t: Type): bool = t != nil and t.kind == tkNiltype
proc isVoid*(t: Type): bool = t != nil and t.kind == tkVoid
proc isAuto*(t: Type): bool = t != nil and t.kind == tkAuto
proc isAny*(t: Type): bool = t != nil and t.kind == tkAny
proc isVarargs*(t: Type): bool = t != nil and t.kind == tkVarargs
proc isTable*(t: Type): bool = t != nil and t.kind == tkTable
proc isOptional*(t: Type): bool = t != nil and t.kind == tkOptional
proc isVariant*(t: Type): bool = t != nil and t.kind == tkVariant
proc isGeneric*(t: Type): bool = t != nil and t.kind == tkGeneric
proc isMetatype*(t: Type): bool = t != nil and t.kind == tkMetatype
proc isTypeof*(t: Type): bool = t != nil and t.kind == tkTypeof
proc isCstring*(t: Type): bool = t != nil and t.kind == tkCstring
proc isCvarargs*(t: Type): bool = t != nil and t.kind == tkCvarargs
proc isCvalist*(t: Type): bool = t != nil and t.kind == tkCvalist

# --- size / alignof ----------------------------------------------------------

proc primitiveSize(k: TypeKind): int =
  case k:
    of tkInteger, tkUinteger, tkNumber, tkIsize, tkUsize,
        tkInt64, tkUint64, tkClong, tkCulong, tkClonglong, tkCulonglong,
        tkCptrdiff, tkCsize, tkCdouble, tkFloat64, tkPointer, tkNilptr,
        tkFunction, tkCstring, tkMetatype:
          8
    of tkString:
      16
    of tkInt128, tkUint128, tkFloat128, tkClongdouble:
      16
    of tkInt32, tkUint32, tkCint, tkCuint, tkFloat32, tkCfloat:
      4
    of tkInt16, tkUint16, tkCshort, tkCushort:
      2
    of tkInt8, tkUint8, tkByte, tkBoolean, tkCchar, tkCschar, tkCuchar:
      1
    of tkCvalist, tkCvarargs:
      8
    else:
      0

proc size*(t: Type): int =
  if t == nil:
    return 0
  case t.kind:
    of tkArray:
      size(t.subtype) * max(t.arraySize, 0)
    of tkRecord:
      var off = 0
      var al = 0
      for f in t.fields:
        let fa = if f.typ != nil: alignof(f.typ) else: 1
        let fs = size(f.typ)
        if fa > al:
          al = fa
        off = (off + fa - 1) div fa * fa
        off += fs
      if al > 0:
        off = (off + al - 1) div al * al
      off
    of tkUnion:
      var s = 0
      var al = 0
      for f in t.fields:
        let fs = size(f.typ)
        let fa = if f.typ != nil: alignof(f.typ) else: 1
        if fs > s:
          s = fs
        if fa > al:
          al = fa
      if al > 0:
        s = (s + al - 1) div al * al
      s
    of tkEnum:
      if t.subtype != nil:
        size(t.subtype)
      else:
        8
    of tkOptional:
      let base = if t.subtype != nil: size(t.subtype) else: 0
      let al = if t.subtype != nil: alignof(t.subtype) else: 1
      if al <= 1:
        base + 1
      else:
        (base + 1 + al - 1) div al * al
    of tkVariant:
      var s = 0
      for ft in t.args:
        let fs = size(ft)
        if fs > s:
          s = fs
      s
    of tkTypeof:
      if t.subtype != nil:
        size(t.subtype)
      else:
        0
    else:
      primitiveSize(t.kind)

proc primitiveAlign(k: TypeKind): int =
  case k:
    of tkInteger, tkUinteger, tkNumber, tkIsize, tkUsize,
        tkInt64, tkUint64, tkClong, tkCulong, tkClonglong, tkCulonglong,
        tkCptrdiff, tkCsize, tkCdouble, tkFloat64, tkPointer, tkNilptr,
        tkFunction, tkCstring, tkString, tkMetatype:
      8
    of tkInt128, tkUint128, tkFloat128, tkClongdouble:
      16
    of tkInt32, tkUint32, tkCint, tkCuint, tkFloat32, tkCfloat:
      4
    of tkInt16, tkUint16, tkCshort, tkCushort:
      2
    of tkInt8, tkUint8, tkByte, tkBoolean, tkCchar, tkCschar, tkCuchar:
      1
    of tkCvalist, tkCvarargs:
      8
    else:
      0

proc alignof*(t: Type): int =
  if t == nil:
    return 0
  case t.kind:
    of tkArray:
      if t.subtype != nil:
        alignof(t.subtype)
      else:
        0
    of tkRecord:
      var a = 0
      for f in t.fields:
        let fa = if f.typ != nil: alignof(f.typ) else: 1
        if fa > a:
          a = fa
      a
    of tkUnion:
      var a = 0
      for f in t.fields:
        let fa = if f.typ != nil: alignof(f.typ) else: 1
        if fa > a:
          a = fa
      a
    of tkEnum:
      if t.subtype != nil:
        alignof(t.subtype)
      else:
        8
    of tkOptional:
      max(if t.subtype != nil: alignof(t.subtype) else: 1, 1)
    of tkVariant:
      var a = 0
      for ft in t.args:
        let fa = alignof(ft)
        if fa > a:
          a = fa
      a
    of tkTypeof:
      if t.subtype != nil:
        alignof(t.subtype)
      else:
        0
    else:
      primitiveAlign(t.kind)

# --- query surface (§5) ------------------------------------------------------

proc fieldsOf*(t: Type): seq[Field] =
  if t != nil and t.kind in {tkRecord, tkUnion}:
    t.fields
  else:
    @[]

proc metafieldOf*(t: Type, name: string): Type =
  if t != nil and name in t.metafields:
    t.metafields[name]
  else:
    nil

proc subtypeOf*(t: Type): Type =
  if t != nil and t.kind in {tkPointer, tkArray, tkOptional, tkTypeof}:
    t.subtype
  else:
    nil

proc argsOf*(t: Type): seq[Type] =
  if t != nil and t.kind == tkFunction:
    t.args
  else:
    @[]

proc returnsOf*(t: Type): seq[Type] =
  if t != nil and t.kind == tkFunction:
    t.returns
  else:
    @[]

proc codename*(t: Type): string =
  if t == nil:
    return ""
  if t.codename != "":
    return t.codename
  case t.kind:
    of tkPointer:
      if t.subtype == nil or t.subtype.isAny:
        "pointer"
      else:
        "pointer(" & codename(t.subtype) & ")"
    of tkNilptr:
      "nilptr"
    of tkArray:
      let e = if t.subtype != nil: codename(t.subtype) else: "void"
      "array(" & e & ", " & $t.arraySize & ")"
    of tkRecord:
      var parts: seq[string] = @[]
      for f in t.fields:
        parts.add f.name & ": " & codename(f.typ)
      "record{" & parts.join(", ") & "}"
    of tkUnion:
      var parts: seq[string] = @[]
      for f in t.fields:
        parts.add f.name & ": " & codename(f.typ)
      "union{" & parts.join(", ") & "}"
    of tkEnum:
      let u = if t.subtype != nil: codename(t.subtype) else: "int64"
      var parts: seq[string] = @[]
      for ef in t.enumFields:
        parts.add ef.name & "=" & $ef.value
      "enum(" & u & "){" & parts.join(", ") & "}"
    of tkFunction:
      var ap: seq[string] = @[]
      for a in t.args:
        ap.add codename(a)
      var rp: seq[string] = @[]
      for r in t.returns:
        rp.add codename(r)
      "function(" & ap.join(", ") & "): " & rp.join(", ")
    of tkOptional:
      if t.subtype != nil:
        codename(t.subtype) & "?"
      else:
        "optional"
    of tkVariant:
      var parts: seq[string] = @[]
      for a in t.args:
        parts.add codename(a)
      parts.join("|")
    of tkGeneric:
      if t.name != "":
        t.name
      else:
        "generic"
    of tkAuto:
      "auto"
    of tkAny:
      "any"
    of tkVoid:
      "void"
    of tkNiltype:
      "nil"
    of tkTable:
      "table"
    of tkMetatype:
      "type"
    of tkTypeof:
      if t.subtype != nil:
        "typeof(" & codename(t.subtype) & ")"
      else:
        "typeof"
    else:
      if t.name != "":
        t.name
      else:
        ""

# --- structural canonicalization --------------------------------------------

var TypeCache*: Table[string, Type]
var TypeCounter*: int = 0

proc typeKey(t: Type, depth = 0): string =
  if t == nil:
    return "nil"
  if depth > 16:
    return "..."
  case t.kind:
    of tkPointer:
      "P(" & typeKey(t.subtype, depth + 1) & ")"
    of tkNilptr:
      "NP"
    of tkArray:
      "A(" & typeKey(t.subtype, depth + 1) & "," & $t.arraySize & ")"
    of tkRecord:
      var s = "R{"
      for f in t.fields:
        s.add f.name & ":" & typeKey(f.typ, depth + 1) & ","
      s.add "}"
      s
    of tkUnion:
      var s = "U{"
      for f in t.fields:
        s.add f.name & ":" & typeKey(f.typ, depth + 1) & ","
      s.add "}"
      s
    of tkEnum:
      var s = "E(" & typeKey(t.subtype, depth + 1) & "){"
      for ef in t.enumFields:
        s.add ef.name & "=" & $ef.value & ","
      s.add "}"
      s
    of tkFunction:
      var s = "F("
      for a in t.args:
        s.add typeKey(a, depth + 1) & ","
      s.add "):"
      for r in t.returns:
        s.add typeKey(r, depth + 1) & ","
      s
    of tkOptional:
      "O(" & typeKey(t.subtype, depth + 1) & ")"
    of tkVariant:
      var s = "V("
      for a in t.args:
        s.add typeKey(a, depth + 1) & ","
      s.add ")"
      s
    of tkGeneric:
      "G(" & t.name & ")"
    of tkTypeof:
      "T(" & typeKey(t.subtype, depth + 1) & ")"
    else:
      codename(t)

proc computeShaper*(t: Type) =
  ## Fill the derived §8 shaper booleans from `t.kind`.  Idempotent; safe to
  ## call on cached (canonical) types.  The container family stays false unless
  ## a lib definition sets it explicitly (our type system does not recognise
  ## lib types, matching the oracle for non-lib types).
  let k = t.kind
  t.is_auto      = k == tkAuto
  t.is_any       = k == tkAny
  t.is_varargs   = k == tkVarargs
  t.is_varanys   = k == tkVaranys
  t.is_void      = k == tkVoid
  t.is_niltype   = k == tkNiltype
  t.is_boolean   = k == tkBoolean
  t.is_string    = k == tkString
  t.is_cstring   = k == tkCstring
  t.is_record    = k == tkRecord
  t.is_union     = k == tkUnion
  t.is_enum      = k == tkEnum
  t.is_function  = k == tkFunction
  t.is_procedure = k == tkFunction
  t.is_pointer   = k == tkPointer
  t.is_nilptr    = k == tkNilptr
  t.is_array     = k == tkArray
  t.is_optional  = k == tkOptional
  t.is_variant   = k == tkVariant
  t.is_table     = k == tkTable
  t.is_concept   = false
  t.is_generic   = k == tkGeneric
  t.is_type      = k == tkMetatype
  t.is_scalar    = k in {tkInteger, tkUinteger, tkNumber, tkByte, tkIsize,
                          tkUsize, tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
                          tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
                          tkFloat32, tkFloat64, tkFloat128, tkBoolean, tkNilptr,
                          tkPointer, tkEnum, tkCchar, tkCschar, tkCuchar,
                          tkCshort, tkCushort, tkCint, tkCuint, tkClong, tkCulong,
                          tkClonglong, tkCulonglong, tkCptrdiff, tkCsize,
                          tkCfloat, tkCdouble, tkClongdouble, tkCstring, tkString}
  t.is_integral  = k in {tkInteger, tkUinteger, tkByte, tkIsize, tkUsize,
                          tkInt8, tkInt16, tkInt32, tkInt64, tkInt128,
                          tkUint8, tkUint16, tkUint32, tkUint64, tkUint128,
                          tkCchar, tkCschar, tkCuchar, tkCshort, tkCushort,
                          tkCint, tkCuint, tkClong, tkCulong, tkClonglong,
                          tkCulonglong, tkCptrdiff, tkCsize, tkEnum}
  t.is_float     = k in {tkNumber, tkFloat32, tkFloat64, tkFloat128,
                          tkCfloat, tkCdouble, tkClongdouble}
  t.is_arithmetic = t.is_scalar
  t.is_stringy   = k in {tkString, tkCstring}
  t.is_falseable = t.is_scalar
  t.is_composite = k in {tkRecord, tkUnion}
  t.is_aggregate = k in {tkRecord, tkUnion, tkArray}
  t.is_empty     = (k in {tkRecord, tkUnion}) and t.fields.len == 0
  t.is_multipleargs = k == tkVarargs
  t.is_nilable   = k in {tkOptional, tkNilptr, tkNiltype, tkGeneric}
  t.is_comptime  = k in {tkGeneric, tkMetatype, tkTypeof}
  t.is_polymorphic = k in {tkGeneric}
  t.is_unpointable = k in {tkGeneric, tkMetatype, tkTypeof}
  t.is_nameable  = k in {tkRecord, tkEnum, tkGeneric}
  t.is_nolvalue  = k in {tkGeneric, tkMetatype}
  t.is_nodecl    = k in {tkGeneric}
  if t.name.len > 0 and t.is_nameable:
    t.nickname = t.name

proc canonicalize(t: Type): Type =
  if t == nil:
    return nil
  case t.kind:
    of tkPointer, tkArray, tkRecord, tkUnion, tkEnum, tkFunction,
       tkOptional, tkVariant, tkGeneric, tkTypeof:
      computeShaper(t)
      let key = typeKey(t)
      if key in TypeCache:
        result = TypeCache[key]
      else:
        inc TypeCounter
        t.typeid = TypeCounter
        TypeCache[key] = t
        result = t
    else:
      result = t

# --- composite constructors --------------------------------------------------

proc pointerType*(elem: Type): Type =
  canonicalize(Type(kind: tkPointer, subtype: elem))

proc arrayType*(elem: Type, size: int): Type =
  canonicalize(Type(kind: tkArray, subtype: elem, arraySize: size))

proc recordType*(fields: seq[Field]): Type =
  canonicalize(Type(kind: tkRecord, fields: fields))

proc unionType*(fields: seq[Field]): Type =
  canonicalize(Type(kind: tkUnion, fields: fields))

proc enumType*(underlying: Type, fields: seq[EnumField]): Type =
  canonicalize(Type(kind: tkEnum, subtype: underlying, enumFields: fields))

proc funcType*(args, returns: seq[Type]): Type =
  canonicalize(Type(kind: tkFunction, args: args, returns: returns))

proc optionalType*(elem: Type): Type =
  canonicalize(Type(kind: tkOptional, subtype: elem))

proc variantType*(alts: seq[Type]): Type =
  canonicalize(Type(kind: tkVariant, args: alts))

proc genericType*(name: string, args: seq[Type] = @[]): Type =
  canonicalize(Type(kind: tkGeneric, name: name, args: args))

proc conceptType*(name: string, funcRef: int = 0): Type =
  ## A `concept` (§6 / Step 6).  Concepts are comptime types: they carry a Lua
  ## function (`funcRef`, a `luaL_ref` handle owned by the shared preprocessor
  ## state) and are used only in type positions -- they never emit storage.
  inc TypeCounter
  var t = Type(kind: tkGeneric, name: name, funcRef: funcRef, typeid: TypeCounter)
  t.methods = initTable[string, MethodDesc]()
  computeShaper(t)
  t.is_concept = true
  t

# --- nominal constructors (§6) ----------------------------------------------
# `@record`/`@enum` are NOMINAL: each definition site yields a fresh Type with
# its own typeid and C tag, distinct from any structural twin. These bypass the
# TypeCache canonicalization that structural `record{}`/`enum{}` rely on.

proc nominalRecordType*(name: string, fields: seq[Field] = @[]): Type =
  inc TypeCounter
  var t = Type(kind: tkRecord, name: name, fields: fields, typeid: TypeCounter)
  t.methods = initTable[string, MethodDesc]()
  computeShaper(t)
  t

proc nominalEnumType*(name: string, underlying: Type, enumFields: seq[EnumField] = @[]): Type =
  inc TypeCounter
  var t = Type(kind: tkEnum, name: name, subtype: underlying, enumFields: enumFields,
               typeid: TypeCounter)
  computeShaper(t)
  t

# --- builtin bootstrap -------------------------------------------------------

var BuiltinTypes*: Table[string, Type]

proc makePrimitive(name, codename: string, kind: TypeKind, signed = false): Type =
  result = Type(kind: kind, name: name, codename: codename, isSigned: signed)
  computeShaper(result)

proc initBuiltinTypes() =
  BuiltinTypes = initTable[string, Type]()
  BuiltinTypes["integer"]  = makePrimitive("integer",  "int64",   tkInteger,  true)
  BuiltinTypes["number"]   = makePrimitive("number",   "double",  tkNumber)
  BuiltinTypes["string"]   = makePrimitive("string",   "nlstring", tkString)
  BuiltinTypes["boolean"]  = makePrimitive("boolean",  "bool",    tkBoolean)
  BuiltinTypes["isize"]    = makePrimitive("isize",    "isize",   tkIsize,   true)
  BuiltinTypes["usize"]    = makePrimitive("usize",    "usize",   tkUsize)
  BuiltinTypes["byte"]     = makePrimitive("byte",     "byte",    tkByte)
  BuiltinTypes["cchar"]    = makePrimitive("cchar",    "char",    tkCchar,   true)
  BuiltinTypes["cschar"]   = makePrimitive("cschar",   "signed char", tkCschar, true)
  BuiltinTypes["cuchar"]   = makePrimitive("cuchar",   "unsigned char", tkCuchar)
  BuiltinTypes["cshort"]   = makePrimitive("cshort",   "short",   tkCshort,  true)
  BuiltinTypes["cushort"]  = makePrimitive("cushort",  "unsigned short", tkCushort)
  BuiltinTypes["cint"]     = makePrimitive("cint",     "int",     tkCint,    true)
  BuiltinTypes["cuint"]    = makePrimitive("cuint",    "unsigned int", tkCuint)
  BuiltinTypes["clong"]    = makePrimitive("clong",    "long",    tkClong,   true)
  BuiltinTypes["culong"]   = makePrimitive("culong",   "unsigned long", tkCulong)
  BuiltinTypes["cfloat"]   = makePrimitive("cfloat",   "float",   tkCfloat)
  BuiltinTypes["cdouble"]  = makePrimitive("cdouble",  "double",  tkCdouble)
  BuiltinTypes["void"]     = makePrimitive("void",     "void",    tkVoid)
  BuiltinTypes["auto"]     = makePrimitive("auto",     "auto",    tkAuto)
  BuiltinTypes["any"]      = makePrimitive("any",      "any",     tkAny)
  BuiltinTypes["nil"]      = makePrimitive("nil",      "nil",     tkNiltype)
  BuiltinTypes["nilptr"]   = makePrimitive("nilptr",   "nilptr",  tkNilptr)
  BuiltinTypes["varargs"]  = makePrimitive("varargs",  "varargs", tkVarargs)
  BuiltinTypes["varanys"]  = makePrimitive("varanys",  "varanys", tkVaranys)
  BuiltinTypes["cvarargs"] = makePrimitive("cvarargs", "cvarargs", tkCvarargs)
  BuiltinTypes["type"]     = makePrimitive("type",     "type",    tkMetatype)

initBuiltinTypes()

## Named fixed-size primitives (int8/int32/uint32/float32/...) that the oracle
## accepts as type annotations and as numeric-literal suffixes. These are NOT
## in `BuiltinTypes` (which only holds the bootstrap nicknames); the analyzer
## resolves a type-annotation identifier against this table as a fallback.
var PrimitiveTypes*: Table[string, Type]

proc initPrimitiveTypes() =
  PrimitiveTypes = initTable[string, Type]()
  PrimitiveTypes["int8"]   = makePrimitive("int8",   "int8",   tkInt8,   true)
  PrimitiveTypes["int16"]  = makePrimitive("int16",  "int16",  tkInt16,  true)
  PrimitiveTypes["int32"]  = makePrimitive("int32",  "int32",  tkInt32,  true)
  PrimitiveTypes["int64"]  = makePrimitive("int64",  "int64",  tkInt64,  true)
  PrimitiveTypes["int128"] = makePrimitive("int128", "int128", tkInt128, true)
  PrimitiveTypes["uint8"]  = makePrimitive("uint8",  "uint8",  tkUint8)
  PrimitiveTypes["uint16"] = makePrimitive("uint16", "uint16", tkUint16)
  PrimitiveTypes["uint32"] = makePrimitive("uint32", "uint32", tkUint32)
  PrimitiveTypes["uint64"] = makePrimitive("uint64", "uint64", tkUint64)
  PrimitiveTypes["uint128"]= makePrimitive("uint128","uint128",tkUint128)
  PrimitiveTypes["float32"]= makePrimitive("float32","float32",tkFloat32)
  PrimitiveTypes["float64"]= makePrimitive("float64","float64",tkFloat64)
  PrimitiveTypes["float128"]=makePrimitive("float128","float128",tkFloat128)
  PrimitiveTypes["clonglong"]  = makePrimitive("clonglong",  "clonglong",  tkClonglong,  true)
  PrimitiveTypes["culonglong"] = makePrimitive("culonglong", "culonglong", tkCulonglong)
  PrimitiveTypes["cptrdiff"]  = makePrimitive("cptrdiff",  "cptrdiff",  tkCptrdiff)
  PrimitiveTypes["csize"]     = makePrimitive("csize",     "csize",     tkCsize)
  PrimitiveTypes["cvalist"]   = makePrimitive("cvalist",   "cvalist",   tkCvalist)
  PrimitiveTypes["cvarargs"]  = makePrimitive("cvarargs",  "cvarargs",  tkCvarargs)
  PrimitiveTypes["cstring"]   = makePrimitive("cstring",   "cstring",   tkCstring)

initBuiltinTypes()
initPrimitiveTypes()

let GenericPointer* = pointerType(BuiltinTypes["any"])

when isMainModule:
  let integer  = BuiltinTypes["integer"]
  let number   = BuiltinTypes["number"]
  let stringT  = BuiltinTypes["string"]
  let boolean  = BuiltinTypes["boolean"]
  let nilptr   = BuiltinTypes["nilptr"]
  let voidT    = BuiltinTypes["void"]
  let auto     = BuiltinTypes["auto"]
  let typeT    = BuiltinTypes["type"]
  let usizeT   = BuiltinTypes["usize"]

  # --- codenames ---
  doAssert integer.codename  == "int64",   integer.codename
  doAssert number.codename   == "double",  number.codename
  doAssert stringT.codename  == "nlstring", codename(stringT)
  doAssert boolean.codename  == "bool",    boolean.codename
  doAssert nilptr.codename   == "nilptr",  nilptr.codename
  doAssert voidT.codename    == "void",    voidT.codename
  doAssert auto.codename     == "auto",    auto.codename
  doAssert typeT.codename    == "type",    typeT.codename

  # --- sizes ---
  doAssert integer.size == 8,   $integer.size
  doAssert nilptr.size  == 8,   $nilptr.size
  doAssert voidT.size   == 0,   $voidT.size
  doAssert auto.size    == 0,   $auto.size
  doAssert typeT.size   == 8,   $typeT.size
  doAssert stringT.size == 16,  $stringT.size

  # --- properties ---
  doAssert integer.isIntegral
  doAssert number.isFloat
  doAssert boolean.isScalar
  doAssert nilptr.isNilptr
  doAssert voidT.isVoid
  doAssert auto.isAuto
  doAssert typeT.isMetatype
  doAssert not integer.isPointer
  doAssert not integer.isRecord

  # --- pointer ---
  let ptrT = pointerType(integer)
  doAssert ptrT.isPointer
  doAssert ptrT.size == 8
  doAssert ptrT.subtype == integer
  doAssert codename(ptrT) == "pointer(int64)", codename(ptrT)
  doAssert ptrT.isScalar

  # --- record ---
  let rec = recordType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: stringT),
  ])
  doAssert rec.isRecord
  doAssert rec.size == 24,            $rec.size
  doAssert codename(rec) == "record{x: int64, y: nlstring}", codename(rec)
  doAssert rec.fields.len == 2
  doAssert rec.fields[0].name == "x"
  doAssert rec.fields[0].typ == integer
  doAssert rec.fields[1].name == "y"
  doAssert rec.fields[1].typ == stringT
  doAssert fieldsOf(rec).len == 2
  doAssert metafieldOf(rec, "__add") == nil

  # --- canonicalization: two structurally equal records -> same object ---
  let rec2 = recordType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: stringT),
  ])
  doAssert rec == rec2
  doAssert rec.typeid == rec2.typeid
  doAssert codename(rec) == codename(rec2)
  # a different record == a different object
  let rec3 = recordType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: boolean),
  ])
  doAssert not (rec3 == rec)
  doAssert rec3.size == 16,            $rec3.size

  # --- function ---
  let fn = funcType(@[integer, integer], @[integer])
  doAssert fn.isFunction
  doAssert fn.size == 8
  doAssert fn.args.len == 2
  doAssert fn.returns.len == 1
  doAssert fn.args[0] == integer
  doAssert fn.returns[0] == integer
  doAssert codename(fn) == "function(int64, int64): int64", codename(fn)
  doAssert argsOf(fn).len == 2
  doAssert returnsOf(fn).len == 1
  doAssert subtypeOf(fn) == nil

  # --- array ---
  let arr = arrayType(integer, 3)
  doAssert arr.isArray
  doAssert arr.size == 24,            $arr.size
  doAssert arr.arraySize == 3
  doAssert arr.subtype == integer
  doAssert codename(arr) == "array(int64, 3)", codename(arr)
  doAssert subtypeOf(arr) == integer

  # --- nilptr / void / auto / type ---
  doAssert codename(nilptr) == "nilptr"
  doAssert voidT.isVoid
  doAssert auto.isAuto and auto.size == 0
  doAssert typeT.isMetatype and codename(typeT) == "type"

  # --- generic pointer ---
  doAssert GenericPointer.isPointer
  doAssert GenericPointer.subtype.isAny
  doAssert codename(GenericPointer) == "pointer"
  doAssert GenericPointer.size == 8

  # --- union / enum / optional / variant ---
  let uni = unionType(@[
    Field(name: "x", typ: integer),
    Field(name: "y", typ: boolean),
  ])
  doAssert uni.isUnion
  doAssert uni.size == 8
  doAssert codename(uni) == "union{x: int64, y: bool}", codename(uni)

  let en = enumType(integer, @[
    EnumField(name: "Red",   value: 0),
    EnumField(name: "Green", value: 1),
    EnumField(name: "Blue",  value: 2),
  ])
  doAssert en.isEnum
  doAssert en.size == 8
  doAssert en.subtype == integer
  doAssert codename(en) == "enum(int64){Red=0, Green=1, Blue=2}", codename(en)
  doAssert en.enumFields[0].name == "Red"
  doAssert en.enumFields[0].value == 0

  let opt = optionalType(integer)
  doAssert opt.isOptional
  doAssert opt.subtype == integer
  doAssert codename(opt) == "int64?", codename(opt)
  doAssert subtypeOf(opt) == integer

  let varT = variantType(@[integer, boolean])
  doAssert varT.isVariant
  doAssert varT.args.len == 2
  doAssert codename(varT) == "int64|bool", codename(varT)

  echo "types.nim OK"