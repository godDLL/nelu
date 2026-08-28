import astshapes
import options

export NodeKind, Node, NodeField, layoutFor

proc newNode*(kind: NodeKind): Node =
  Node(kind: kind)

proc addLast*(n: Node, child: Node) =
  n.children.add child

proc newBlock*(nodes: seq[Node] = @[]): Node =
  Node(kind: nkBlock, children: nodes)

proc newId*(name: string): Node =
  Node(kind: nkId, str: name)

proc newIdDecl*(name: string, typeexpr: Node = nil): Node =
  var children: seq[Node]
  if typeexpr != nil: children = @[typeexpr]
  Node(kind: nkIdDecl, str: name, children: children)

proc newNumber*(value: string, litType: string = "integer"): Node =
  Node(kind: nkNumber, str: value, litType: litType)

proc newString*(value: string, litType: string = "string"): Node =
  Node(kind: nkString, str: value, litType: litType)

proc newBoolean*(b: bool): Node =
  Node(kind: nkBoolean, boolVal: b)

proc newNil*(): Node = Node(kind: nkNil)
proc newNilptr*(): Node = Node(kind: nkNilptr)
proc newVarargs*(): Node = Node(kind: nkVarargs)

proc newPair*(name: string, value: Node): Node =
  Node(kind: nkPair, str: name, children: @[value])

proc newPairExpr*(key: Node, value: Node): Node =
  Node(kind: nkPair, children: @[key, value])

proc newInitList*(elems: seq[Node] = @[]): Node =
  let n = Node(kind: nkInitList, children: elems)
  n.isUnpackable = true
  n

proc newDotIndex*(name: string, expr: Node): Node =
  let n = Node(kind: nkDotIndex, str: name, children: @[expr])
  n.isIndex = true
  n

proc newColonIndex*(name: string, expr: Node): Node =
  let n = Node(kind: nkColonIndex, str: name, children: @[expr])
  n.isIndex = true
  n

proc newKeyIndex*(key: Node, expr: Node): Node =
  let n = Node(kind: nkKeyIndex, children: @[key, expr])
  n.isIndex = true
  n

proc newAnnotation*(name: string, args: seq[Node] = @[]): Node =
  Node(kind: nkAnnotation, str: name, children: args)

proc newParen*(expr: Node): Node =
  Node(kind: nkParen, children: @[expr])

proc newType*(typeexpr: Node): Node =
  Node(kind: nkType, children: @[typeexpr])

proc newVarargsType*(kind: string): Node =
  Node(kind: nkVarargsType, str: kind)

proc newFuncType*(argtypes: seq[Node], returns: seq[Node]): Node =
  Node(kind: nkFuncType, children: argtypes & returns)

proc newRecordField*(name: string, typeexpr: Node): Node =
  Node(kind: nkRecordField, str: name, children: @[typeexpr])

proc newRecordType*(fields: seq[Node]): Node =
  Node(kind: nkRecordType, children: fields)

proc newUnionField*(name: string, typeexpr: Node): Node =
  Node(kind: nkUnionField, str: name, children: @[typeexpr])

proc newUnionType*(fields: seq[Node]): Node =
  Node(kind: nkUnionType, children: fields)

proc newEnumField*(name: string, value: Node = nil): Node =
  var children: seq[Node]
  if value != nil: children = @[value]
  Node(kind: nkEnumField, str: name, children: children)

proc newEnumType*(fields: seq[Node], primtype: Node = nil): Node =
  var children = fields
  if primtype != nil: children = @[primtype] & fields
  Node(kind: nkEnumType, children: children)

proc newArrayType*(subtype: Node, size: Node = nil): Node =
  var children: seq[Node] = @[subtype]
  if size != nil: children = @[subtype, size]
  Node(kind: nkArrayType, children: children)

proc newPointerType*(subtype: Node = nil): Node =
  var children: seq[Node]
  if subtype != nil: children = @[subtype]
  Node(kind: nkPointerType, children: children)

proc newOptionalType*(subtype: Node): Node =
  Node(kind: nkOptionalType, children: @[subtype])

proc newGenericType*(name: string, args: seq[Node]): Node =
  Node(kind: nkGenericType, str: name, children: args)

proc newVariantType*(types: seq[Node]): Node =
  Node(kind: nkVariantType, children: types)

proc newFunction*(args: seq[Node], returns: seq[Node], annotations: seq[Node], body: Node): Node =
  let n = Node(kind: nkFunction, children: args & returns & annotations & @[body])
  n.isFunction = true
  n

proc newCall*(args: seq[Node], caller: Node): Node =
  let n = Node(kind: nkCall, children: args & @[caller])
  n.isCall = true
  n

proc newCallMethod*(name: string, args: seq[Node], caller: Node): Node =
  let n = Node(kind: nkCallMethod, str: name, children: args & @[caller])
  n.isCall = true
  n

proc newUnaryOp*(op: string, right: Node): Node =
  let n = Node(kind: nkUnaryOp, str: op, children: @[right])
  n.isOperator = true
  n

proc newBinaryOp*(left: Node, op: string, right: Node): Node =
  let n = Node(kind: nkBinaryOp, str: op, children: @[left, right])
  n.isOperator = true
  n

proc newReturn*(exprs: seq[Node]): Node =
  let n = Node(kind: nkReturn, children: exprs)
  n.isUnpackable = true
  n

proc newIf*(branches: seq[tuple[cond: Node, body: Node]], elseBlock: Node = nil): Node =
  let n = Node(kind: nkIf)
  for b in branches:
    n.children.add b.cond
    n.children.add b.body
  if elseBlock != nil:
    n.children.add elseBlock
  n

proc newSwitch*(expr: Node, cases: seq[tuple[exprs: seq[Node], body: Node]], elseBlock: Node = nil): Node =
  let n = Node(kind: nkSwitch)
  n.children.add expr
  for c in cases:
    for e in c.exprs:
      n.children.add e
    n.children.add c.body
  if elseBlock != nil:
    n.children.add elseBlock
  n

proc newDo*(blockNode: Node): Node =
  Node(kind: nkDo, children: @[blockNode])

proc newDefer*(blockNode: Node): Node =
  Node(kind: nkDefer, children: @[blockNode])

proc newWhile*(cond: Node, body: Node): Node =
  Node(kind: nkWhile, children: @[cond, body])

proc newRepeat*(body: Node, cond: Node): Node =
  Node(kind: nkRepeat, children: @[body, cond])

proc newForNum*(iddecl: Node, begin: Node, cmpop: string, endv: Node, step: Node = nil, body: Node): Node =
  let n = Node(kind: nkForNum, str: cmpop)
  n.children.add iddecl
  n.children.add begin
  n.children.add endv
  if step != nil:
    n.children.add step
  n.children.add body
  n

proc newForIn*(iddecls: seq[Node], exprs: seq[Node], body: Node): Node =
  Node(kind: nkForIn, children: iddecls & exprs & @[body])

proc newBreak*(): Node = Node(kind: nkBreak)
proc newContinue*(): Node = Node(kind: nkContinue)

proc newLabel*(name: string): Node =
  Node(kind: nkLabel, str: name)

proc newGoto*(name: string): Node =
  Node(kind: nkGoto, str: name)

proc newVarDecl*(scope: string, iddecls: seq[Node], inits: seq[Node]): Node =
  let n = Node(kind: nkVarDecl, str: scope, children: iddecls & inits)
  n.isUnpackable = true
  n

proc newAssign*(targets: seq[Node], values: seq[Node]): Node =
  let n = Node(kind: nkAssign, children: targets & values)
  n.isUnpackable = true
  n

proc newFuncDef*(scope: string, name: Node, args: seq[Node], returns: seq[Node], annotations: seq[Node], body: Node): Node =
  let n = Node(kind: nkFuncDef, str: scope, children: @[name] & args & returns & annotations & @[body])
  n.isFunction = true
  n

proc newDirective*(name: string, args: seq[Node] = @[]): Node =
  Node(kind: nkDirective, str: name, children: args)

proc childrenOf*(n: Node): seq[Node] = n.children

proc isCall*(n: Node): bool = n.isCall
proc isFunction*(n: Node): bool = n.isFunction
proc isUnpackable*(n: Node): bool = n.isUnpackable
proc isIndex*(n: Node): bool = n.isIndex
proc isOperator*(n: Node): bool = n.isOperator

proc walk*(n: Node, fn: proc(node: Node): Node): Node =
  let replaced = fn(n)
  let cur = if replaced != nil: replaced else: n
  for i in 0 ..< cur.children.len:
    cur.children[i] = walk(cur.children[i], fn)
  cur

proc map*(n: Node, fn: proc(node: Node): Node): Node =
  let cur = fn(n)
  for i in 0 ..< cur.children.len:
    cur.children[i] = map(cur.children[i], fn)
  cur

when isMainModule:
  let b = newBlock(@[newVarDecl("local", @[newIdDecl("x")], @[newId("init")])])
  doAssert b.kind == nkBlock
  doAssert b.children.len == 1
  doAssert b.children[0].kind == nkVarDecl
  doAssert b.children[0].str == "local"
  doAssert b.children[0].isUnpackable

  let f = newFuncDef("local", newId("foo"), @[newIdDecl("a")], @[], @[], newBlock(@[]))
  doAssert f.kind == nkFuncDef
  doAssert f.isFunction
  doAssert f.str == "local"
  doAssert f.children.len == 3
  doAssert f.children[0].kind == nkId
  doAssert f.children[1].kind == nkIdDecl
  doAssert f.children[2].kind == nkBlock

  let c = newCall(@[newId("x")], newId("f"))
  doAssert c.kind == nkCall and c.isCall
  doAssert c.children.len == 2

  let bo = newBinaryOp(newId("a"), "+", newId("b"))
  doAssert bo.kind == nkBinaryOp and bo.isOperator
  doAssert bo.children.len == 2

  let n = newNumber("1", "integer")
  doAssert n.str == "1" and n.litType == "integer"
  doAssert layoutFor(nkNumber) == @[nfStr, nfLitType]

  let walked = walk(b, proc(node: Node): Node =
    if node.kind == nkId: Node(kind: nkId, str: "renamed") else: nil)
  doAssert walked.children[0].children[1].str == "renamed"
  echo "ast.nim OK"