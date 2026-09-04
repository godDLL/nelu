## AST node shapes — frozen contract (M1a).
## Mirrors language-review.md Appendix A exactly: the NodeKind enum plus the Node
## field schema. This file is the shared contract both streams build against,
## so it has zero imports and no behaviour.
##
## Representation note: the reference stores each shape's named fields as distinct
## Lua-table slots. Here Node is one ref object with a flat `children` seq plus a
## handful of scalar slots (str/litType/boolVal) and four analysis flags. Which
## children slot means what is documented per-shape in `layoutFor`; the *contract*
## (which shapes exist, which scalar/flag fields each carries) is preserved exactly.

type
  NodeKind* = enum
    nkBlock          ## statement list
    nkNumber         ## numeric literal
    nkString         ## string literal
    nkBoolean        ## true/false
    nkNilptr         ## nilptr
    nkNil            ## nil
    nkVarargs        ## ...
    nkDoExpr         ## (do ... end) expression
    nkIn             ## `in (expr)` splice-function / do-expression return
    nkPreprocess     ## ## block (removed after run)
    nkPreprocessExpr ## #[expr]#
    nkPreprocessName ## #|name|#
    nkPair           ## init-list field
    nkInitList       ## {...}
    nkDotIndex       ## .field
    nkColonIndex     ## :method
    nkKeyIndex       ## [key]
    nkAnnotation     ## <...>
    nkId             ## identifier
    nkIdDecl         ## declared name
    nkParen          ## (expr)
    nkType           ## @typeexpr
    nkVarargsType    ## ... type (varautos/varanys/cvarargs)
    nkFuncType       ## function type
    nkRecordField    ## record field
    nkRecordType     ## record type
    nkUnionField     ## union field
    nkUnionType      ## union type
    nkEnumField      ## enum field
    nkEnumType       ## enum type
    nkArrayType      ## array type
    nkPointerType    ## pointer type
    nkOptionalType   ## T?
    nkGenericType    ## generic instantiation
    nkVariantType    ## variant
    nkFunction       ## anonymous function
    nkCall           ## function call
    nkCallMethod     ## method call
    nkUnaryOp        ## unary operator
    nkBinaryOp       ## binary operator
    nkReturn         ## return
    nkIf             ## if
    nkSwitch         ## switch
    nkDo             ## do block
    nkDefer          ## defer
    nkWhile          ## while
    nkRepeat         ## repeat
    nkForNum         ## numeric for
    nkForIn          ## iterator for
    nkBreak          ## break
    nkContinue       ## continue
    nkLabel          ## ::name::
    nkGoto           ## goto name
    nkVarDecl        ## local/global declaration
    nkAssign         ## assignment
    nkFuncDef        ## named function
    nkDirective      ## internal directive

  Node* = ref object
    kind*: NodeKind
    ## Scalar slots — empty/zero when the shape does not use them.
    str*: string      ## name / code / value / operator / scope / varargs-kind
    litType*: string  ## Number.literaltype, String.literaltype
    boolVal*: bool    ## Boolean.value
    intVal*: int      ## Assign.targetCount: how many leading children are
                      ## left-hand-side targets (the rest are RHS values).
                      ## Zero/unused for every other shape.
    ## Flat child list; layout per shape (see layoutFor).
    children*: seq[Node]
    ## Analysis flags (Appendix A): set during analysis, read by codegen.
    isFunction*: bool   ## Function | FuncDef
    isCall*: bool       ## Call | CallMethod
    isUnpackable*: bool ## InitList | Return | VarDecl | Assign
    isIndex*: bool      ## DotIndex | ColonIndex | KeyIndex
    isOperator*: bool   ## UnaryOp | BinaryOp

  ## Which scalar/flag fields a shape actually carries.
  NodeField* = enum
    nfStr, nfLitType, nfBoolVal, nfIntVal, nfChildren, nfFunction, nfCall,
    nfUnpackable, nfIndex, nfOperator

proc layoutFor*(k: NodeKind): seq[NodeField] =
  ## Returns the fields each shape uses. The contract check; must match Appendix A.
  case k
  of nkBlock:         @[nfChildren]
  of nkNumber:        @[nfStr, nfLitType]
  of nkString:        @[nfStr, nfLitType]
  of nkBoolean:       @[nfBoolVal]
  of nkNilptr, nkNil, nkVarargs: @[]
  of nkDoExpr:        @[nfChildren]
  of nkIn:            @[nfChildren]
  of nkPreprocess, nkPreprocessExpr, nkPreprocessName: @[nfStr]
  of nkPair:          @[nfStr, nfChildren]
  of nkInitList:      @[nfChildren, nfUnpackable]
  of nkDotIndex, nkColonIndex: @[nfStr, nfChildren, nfIndex]
  of nkKeyIndex:      @[nfChildren, nfIndex]
  of nkAnnotation:    @[nfStr, nfChildren]
  of nkId:            @[nfStr]
  of nkIdDecl:        @[nfStr, nfChildren]
  of nkParen:         @[nfChildren]
  of nkType:          @[nfChildren]
  of nkVarargsType:   @[nfStr]
  of nkFuncType:      @[nfChildren]
  of nkRecordField:   @[nfStr, nfChildren]
  of nkRecordType:    @[nfChildren]
  of nkUnionField:    @[nfStr, nfChildren]
  of nkUnionType:     @[nfChildren]
  of nkEnumField:     @[nfStr, nfChildren]
  of nkEnumType:      @[nfChildren]
  of nkArrayType:     @[nfChildren]
  of nkPointerType:   @[nfChildren]
  of nkOptionalType:  @[nfChildren]
  of nkGenericType:   @[nfStr, nfChildren]
  of nkVariantType:   @[nfChildren]
  of nkFunction:      @[nfChildren, nfFunction]
  of nkCall:          @[nfChildren, nfCall]
  of nkCallMethod:    @[nfStr, nfChildren, nfCall]
  of nkUnaryOp:       @[nfStr, nfChildren, nfOperator]
  of nkBinaryOp:      @[nfStr, nfChildren, nfOperator]
  of nkReturn:        @[nfChildren, nfUnpackable]
  of nkIf:            @[nfChildren]
  of nkSwitch:        @[nfChildren]
  of nkDo, nkDefer:   @[nfChildren]
  of nkWhile:         @[nfChildren]
  of nkRepeat:        @[nfChildren]
  of nkForNum:        @[nfStr, nfChildren]
  of nkForIn:         @[nfChildren]
  of nkBreak, nkContinue: @[]
  of nkLabel, nkGoto: @[nfStr]
  of nkVarDecl:       @[nfStr, nfChildren, nfUnpackable]
  of nkAssign:        @[nfChildren, nfUnpackable, nfIntVal]
  of nkFuncDef:       @[nfStr, nfChildren, nfFunction]
  of nkDirective:     @[nfStr]