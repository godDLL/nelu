## Analyzer context, scope/symbol accessors, and label scope.

## This module is the *shared contract* between the analysis pass and everyone
## who consumes it (`cgen.nim`, `main.nim`, `compile.nim`).  It owns the two
## object types that describe an analysis run -- `AnalyzerContext` (the mutable
## pass state) and `AnalyzerResult` (its packaged output) -- plus `DumpInfo`,
## the per-node side table the `--print-analyzed-ast` printer merges with `Attr`.
##
## It also owns the scope/symbol/attr/label helpers that operate on the
## context.  They are leaf-ish (they touch only the context and the `types.nim`
## type system), so they are safe to import from any module that has a context.

import ast
import types
import sema
import tables
import hashes
import os
import strutils

# ---- DumpInfo: per-node fields the oracle dump needs that Attr does not carry --

type
  DumpInfo* = ref object
    builtin*: bool            ## Id: refers to a builtin symbol
    isConst*: bool            ## Id: `const` flag (rendered as oracle `const`)
    builtinType*: string      ## Call: builtin callee type string
    calleeSymStr*: string     ## Call: oracle `calleesym`
    calleeTypeStr*: string    ## Call: oracle `calleetype`
    sideeffect*: bool         ## Call: builtin call has side effects
    usemultirets*: bool       ## Call: multi-return call
    ftype*: string            ## FuncDef/name-IdDecl/func-ref-Id: function type str
    funcdeclared*: bool       ## FuncDef/name-IdDecl/func-ref-Id
    funcdefined*: bool        ## FuncDef/name-IdDecl/func-ref-Id
    compop*: string           ## ForNum: "le" / "ge"
    fixedend*: bool           ## ForNum
    fixedstep*: string        ## ForNum

  AnalyzerContext* = object
    source*: string
    path*: string
    unitname*: string
    attrOf*: Table[Node, Attr]
    symOf*: Table[Node, Symbol]
    dumpOf*: Table[Node, DumpInfo]
    funcTypeStrOf*: Table[Node, string]  ## nameNode -> rendered function type string
    scope*: Scope
    globals*: Scope
    assignTargets*: Table[Node, int]
    ifBranchCount*: Table[Node, int]
    ifHasElse*: Table[Node, bool]
    callRetTypes*: Table[Node, seq[Type]]
    multiRetCall*: Node
    diags*: seq[string]                  ## preprocessor diagnostics
    specials*: seq[Node]                 ## D1: monomorphized auto-param FuncDefs
    loopDepth*: int                     ## nesting depth of loops (for break/continue validation)
    specTable*: Table[string, Node]      ## D1: dedup key -> specialized FuncDef
    specCounter*: Table[string, int]     ## D1: per-function specialization counter
    specInFlight*: Table[string, bool]   ## D1: re-entrancy guard (recursion)
    funcReturnType*: Type                ## current function's return type (for init-list-in-return)
    labelScopes*: seq[Table[string, Node]]  ## block-scoped label name -> nkLabel node (goto)

  AnalyzerResult* = object
    root*: Node
    ctx*: AnalyzerContext
    specials*: seq[Node]                 ## D1: monomorphized auto-param FuncDefs
    deps*: seq[AnalyzerResult]          ## D2: recursively analyzed `require` dependencies

# ---- unitname -----------------------------------------------------------------

proc computeUnitname*(path: string): string =
  let name = path.splitFile().name
  var dir = path.splitFile().dir
  var parts: seq[string] = @[]
  for seg in dir.split('/'):
    if seg != "": parts.add seg.replace('-', '_')
  parts.add name.replace('-', '_')
  return parts.join("_")

# ---- scope / symbol helpers ---------------------------------------------------

proc newScope*(parent: Scope, name: string = ""): Scope =
  Scope(name: name, symbols: initTable[string, Symbol](), parent: parent)

proc getUpFunctionScope*(scope: Scope): Scope =
  ## Walk the scope chain until a function body scope is found. Returns nil if
  ## the referencing code is not inside any function (e.g. module scope). Used by
  ## the upvalue check to tell "same function" access from closure capture.
  var s = scope
  while s != nil:
    if s.isFunction: return s
    s = s.parent
  return nil

# ---- label scope (goto / ::label::) -----------------------------------------
#
# Labels are block-scoped and live on a separate stack from the symbol scopes:
# pushing a symbol scope for every block would also re-scope `local` declarations,
# which is a behaviour change unrelated to this feature.  `analyzeBlock` pushes
# and pops this stack, so every statement block (function body, do, for/while/
# repeat, switch case, if branch) gets its own label namespace.  A `goto` looks
# the name up from the top of the stack downward, so it sees labels in its own
# block and enclosing blocks but not in sibling or inner blocks (matching the
# oracle's "no visible label" rejection).

proc pushLabelScope*(ctx: var AnalyzerContext) =
  ctx.labelScopes.add initTable[string, Node]()

proc popLabelScope*(ctx: var AnalyzerContext) =
  discard ctx.labelScopes.pop()

proc registerLabel*(ctx: var AnalyzerContext, name: string, node: Node) =
  if ctx.labelScopes[^1].hasKey(name):
    ctx.diags.add ctx.path & ": error: label '" & name & "' already defined"
  else:
    ctx.labelScopes[^1][name] = node

proc lookupLabel*(ctx: var AnalyzerContext, name: string): Node =
  for i in countdown(ctx.labelScopes.len - 1, 0):
    if ctx.labelScopes[i].hasKey(name):
      return ctx.labelScopes[i][name]
  return nil

proc register*(ctx: var AnalyzerContext, name: string, kind: SymbolKind,
               typ: Type, node: Node = nil): Symbol =
  let sym = Symbol(name: name, kind: kind, typ: typ, node: node,
                   scope: ctx.scope, codename: "")
  ctx.scope.symbols[name] = sym
  return sym

proc lookup*(ctx: var AnalyzerContext, name: string): Symbol =
  var s = ctx.scope
  while s != nil:
    if s.symbols.hasKey(name): return s.symbols[name]
    s = s.parent
  return nil

# ---- attr / dump access ------------------------------------------------------

# Node is a ref object; Table[Node, ..] needs a hash. Key by object identity
# (pointer address), which is stable across the analysis pass.
proc hash*(n: Node): Hash =
  Hash(cast[uint](n))

proc getAttr*(ctx: var AnalyzerContext, node: Node): var Attr =
  if not ctx.attrOf.hasKey(node):
    ctx.attrOf[node] = Attr()
  return ctx.attrOf[node]

proc getDump*(ctx: var AnalyzerContext, node: Node): var DumpInfo =
  if not ctx.dumpOf.hasKey(node):
    ctx.dumpOf[node] = DumpInfo()
  return ctx.dumpOf[node]