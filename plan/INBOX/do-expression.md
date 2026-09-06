# `(do ... in expr end)` do-expression

**Status:** INBOX -- confirmed gap, no fix.  Found while mining `exam/everything.nelua`
(line 176: `local s = (do ... in "two" end)`).

## What it is

A `do`-block in **expression** position, wrapped in parens, whose value is the
expression after the final `in`:

```nelua
local i = 2
local s = (do
  if i == 1 then
    in "one"
  elseif i == 2 then
    in "two"
  else
    in "other"
  end
end)
```

The oracle evaluates this to `"two"` (verified: `/usr/bin/nelua tmp/doexpr1.nelua`
prints `two`, exit 0).  Nelu rejects it at parse time:

```
tmp/doexpr1.nelua:2:12: error: unexpected keyword 'do'
```

## Grammar note

The do-expression **must** be parenthesised.  A bare `local s = do ... end` is a
*statement* block, not an expression -- the oracle rejects it
(`doexpr2.nelua:2:11: syntax error: expected expressions`).  So the only entry
point is `(` `do` ... `)` in `parsePrimary`'s `tkLParen` case.

## Current state in Nelu

The shape is **half-wired but stubbed** -- this is not a from-scratch feature:

| layer | state |
|---|---|
| `src/astshapes.nim` | `nkDoExpr` shape declared (`@[nfChildren]`) |
| `src/cgen.nim:987` | `of nkDoExpr: return "/*do-expr*/"` -- a **placeholder**, emits nothing real |
| `src/ast.nim` | **no `newDoExpr` constructor** -- nothing can build the node |
| `src/parser.nim` | `parsePrimary` `of tkLParen:` (line 470) calls `parseExpr()`; the `do` keyword has no expression-position case, so `(do ... end)` raises "unexpected keyword 'do'" |
| `src/analyzer.nim` | **no `nkDoExpr` case** in `analyzeExpr`; `nkIn` (line 2023) is consumed only by the preprocessor as a splice-function body |

`parseStatement`'s `of "do":` (line 1285) and `of "in":` (line 1277) already parse
the statement forms correctly -- the block body and the `in expr` tail are
parseable.  Only the expression-position wrapping is missing.

## The fix (bounded, 4 sites)

1. **`src/ast.nim`** -- add `newDoExpr(blockNode: Node): Node` mirroring `newDo`
   (`Node(kind: nkDoExpr, children: @[blockNode])`).

2. **`src/parser.nim`** -- in `parsePrimary` `of tkLParen:`, after `p.advance()`,
   branch on the keyword:

   ```nim
   if p.checkKeyword("do"):
     let body = p.parseBlock()
     p.expectKeyword("end", "expected 'end' to close do-expression")
     p.expect(tkRParen, "expected ')' after do-expression")
     return newDoExpr(body)
   let e = p.parseExpr()
   p.expect(tkRParen, "expected ')' after expression")
   return newParen(e)
   ```

3. **`src/analyzer.nim`** -- add `of nkDoExpr:` to `analyzeExpr`.  Analyze the
   block body; the block's value is its trailing `nkIn` node (already parsed by
   `parseStatement` `of "in":`).  The result type is the `nkIn` child's type.
   `analyzeBlock` already calls `replaceSplices` and `analyzeStmt` per child, so
   wiring it in gives the right ordering.  The `nkIn` child must not be treated
   as the preprocessor splice-function form here (that path is gated on the
   enclosing `##` block).

4. **`src/cgen.nim`** -- replace the `/*do-expr*/` placeholder.  Emit the block
   statements, then emit the trailing `nkIn` child's expression as the value.
   Because a do-expression can appear inside another expression (e.g. as an
   argument or in a `print(... .. s .. ...)` concat), the cleanest lowering is
   to hoist the block to a containing statement and bind the `in` value to a
   fresh temp, then emit the temp -- mirroring how the oracle lowers it.  The
   exact C shape should be cross-checked against `nelua --print-code`.

## Verification

- `tmp/doexpr1.nelua` prints `two`, exit 0, matching the oracle.
- The `if/elseif/else` branching and the `in` tail both survive.
- `exam/everything.nelua` line 176 (`local s = (do ... in "two" end)`)
  parses and yields `two`.
- Guard: `plan/harness.py` must stay at 0 regressions.

## Not in scope

- Bare `do ... end` as an expression (the oracle rejects it; preserve that).
- `do`-expressions with no `in` tail (the oracle's behaviour is the reference).
- Closures / upvalues inside a do-expression (`plan/INBOX/closures-upvalues.md`).

## Where it hurts

Low traffic -- only `exam/everything.nelua` in the corpus uses it.  But it is a
clean, self-contained feature with an existing half-wired AST shape, so it is
cheap to land and it unblocks the do-expression line in everything.nelua.
Recorded separately from the require-cascade blockers
(`plan/INBOX/preprocess-name-splice.md`, `plan/INBOX/lib-reachability-per-file.md`)
because it is a language feature, not a stdlib-preprocessor gap.