# Splice blocks must see nelua-scope locals

**Status:** INBOX -- the core blocker for `lib/` stdlib reachability. Not started.

## What fails

Every `lib/*.nelua` file uses `##` splice blocks that reference nelua-scope
locals and their types, e.g. `hash.nelua`:

```
local v: cdouble = ...
## if v.type.is_cfloat then
  local function frexp(x: cfloat, exp: *cint): cfloat <cimport'frexpf',...> end
## else
  local function frexp(x: cdouble, exp: *cint): cdouble <cimport'frexp',...> end
## end
```

The `##` block runs in the preprocessor's Lua environment, where nelua locals
are not visible. Observed error:

```
error while preprocessing block: ... attempt to index a nil value (global 'v')
```

Verified on committed HEAD `tmp/nelua`: `## if v.type.is_cfloat then` with
`local v: cdouble = 1.0` above fails; the same file with the `##` blocks
removed compiles. Also verified: `#[math.huge]#` splice-idents in expression
position already work (that is NOT the blocker).

## The fix (bounded)

Make the `##` splice block's Lua environment expose the **live analyzer
scope's locals and their types**, so a `##` block can read a nelua local and
index its type. This is a natural extension of the machinery already committed
in `ec60323` (`src/preprocessor.nim` `gActiveScope` / `lookup` /
`resolveTypeKey` / `getWrapperSymbol`, which made `#[x]#` splice-idents
resolve at analysis time). The same scope lookup that serves `#[x]#` should
serve `##` blocks.

Scope of this ticket: make `## if <nelua-local>.<type-field> then ... ## else
... ## end` work, and `## <nelua-local> = ...` work. Do NOT go further into
`__nelua_mark`/`__nelua_inject` multi-chunk embedding (that is a separate,
unproven path -- see `plan/INBOX/splice-multichunk-mark-inject.md`).

## Verification

After the fix, `lib/hash.nelua` must compile end-to-end through `tmp/nelua`
(`-c -o /tmp/x lib/hash.nelua`). Then re-scan all 21 `lib/*.nelua` files;
each one that still fails gets its own ticket (see
`plan/INBOX/lib-reachability-per-file.md`).

## Note on the abandoned agent

An agent worked 8 hours on `__nelua_mark`/`__nelua_inject` in
`tmp/20260904-1543-lib-stdlib/` and produced 0/21 compiling lib files. Its
workcopy is preserved as evidence but is superseded by this ticket: it never
touched the actual blocker (splice-block local visibility) and its
preprocessor changes are based on a pre-`ec60323` baseline. Do not integrate
that workcopy without re-deriving against the current `src/`.