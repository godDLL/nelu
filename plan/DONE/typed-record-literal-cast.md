# `(@T){...}` typed record/union/enum constructor cast

**Status:** CLOSED -- implemented and verified against the oracle, 2026-09-06.

## What it was

The cast form of the record/union/enum constructor -- `(@T){ field = expr, ... }` --
was lowered to C with the wrong tag. `(@Point){ x = 1, y = 2 }` became
`(struct nlrec0){.x = 1, .y = 2}` and gcc rejected it:
`'struct nlrec0' has no member named 'x'`.

The bare constructor form `Point{ x = 1, y = 2 }` worked; only the `(@T){...}`
cast form was broken. The oracle treats the two identically.

## Root cause (precise)

`analyzeInitList` (src/analyzer.nim:507) falls back to an anonymous record when
there is no target type:

```nim
let t = if parentType != nil: parentType else: Type(kind: tkRecord)
```

The cast `(@T){...}` parses as a call whose callee is the type `T` and whose
single argument is an InitList, but the analyzer was analyzing that InitList with
**no target type**, so it built an anonymous `nlrec0` record. Codegen then emitted
`(struct Point)((struct nlrec0){...})` -- a cast from the anonymous record to the
named one, which is a type mismatch gcc rejects.

The second half: even when the tag was right, the C4 compound-literal path in
cgen always emitted the `struct` keyword, so a union constructor
`(@IOrF){ n = 3.5 }` (and the bare form `IOrF{...}`) produced
`((struct nlrec2){...})`, which gcc rejects: `invalid use of undefined type
'struct nlrec2'`.

## Fix (two localized changes)

1. **src/analyzer.nim** -- in `analyzeCall`, after resolving `castTarget`, route
   the cast form through the same constructor path as the bare form: analyze the
   InitList against `castTarget`, flag the call as a constructor
   (`a.isConstructor = true`), and return `castTarget`:

   ```nim
   if castTarget.kind in {tkRecord, tkUnion, tkEnum} and args.len == 1 and
      args[0].kind == nkInitList:
     discard analyzeInitList(ctx, args[0], castTarget)
     ca.typ = BuiltinTypes["type"]
     ca.name = "constructor"
     a.isConstructor = true
     a.typ = castTarget
     return castTarget
   ```

2. **src/cgen.nim** -- in the C4 constructor compound-literal path, choose the
   composite keyword from the type kind:

   ```nim
   let kind = if ct.kind == tkUnion: "union" else: "struct"
   return "((" & kind & " " & tag & "){ " & parts.join(" ") & " })"
   ```

## Verification

- `exam/cast_record.nelua` exercises named-field, mixed-order, union, and bare
  forms; all MATCH the oracle.
- Full harness: 247 MATCH, 2 pre-existing regressions (concept_param,
  conv_tostring), 22 improvements, 0 regressions from this change.
- `local p = (@Point){ x = 1, y = 2 }; print(p.x, p.y)` -> `1 2`.

## Related

- `plan/INBOX/record-enum-design.md` -- the design pass this closes a slice of
  (its A5 constructor case is what the analyzer change implements for the bare
  form; this ticket extends it to the cast form).
- `plan/DONE/union-field-access.md`, `plan/DONE/enum-c-emission.md` -- sibling
  record/union/enum parity fixes.