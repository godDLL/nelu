# Global function C emission emits a duplicate nilptr symbol

Status: STILL OPEN

## Symptom

A named top-level function declared with `global` emits **two** symbols in
the C: a correct function declaration and a spurious `nilptr` variable of the
same name, so the C compiler reports `redeclared as different kind of
symbol`.

```
global foo
function foo()
  return 42
end
print(foo())
```

Emitted C (measured 2026-09-06):

```c
int64_t tmp_unit_foo();          /* correct forward decl */
static nilptr tmp_unit_foo;      /* BUG: spurious variable */
int64_t tmp_unit_foo() { ... }   /* definition */
```

## Scope

This is **not** an `auto` bug — it reproduces with a plain `global` function
that has no `auto` anywhere.  It blocks `plan/INBOX/auto-type-inference.md`
facets #5 and #6 (auto return / auto param on named functions), because the
oracle accepts those and nelu needs `global` to bind a polymorphic function's
name.

## Where to look

`src/cgen.nim` `genGlobal` / the global-symbol emission path.  A `global`
declaration creates a symbol; the subsequent `function` definition then
emits the function, but the global symbol is also being emitted as storage
(a `nilptr` variable).  Compare with the already-fixed
`plan/DONE/locals-in-functions-bug.md` (`cgen.nim:1788-1812`, declaration
pass gated on `isGlobal`) — the fix there distinguished global vs
function-body storage; the same distinction appears to be missing for the
`global <name>` + `function <name>()` case.

## Verification

- Isolated probe: `global foo; function foo() return 42 end; print(foo())`
  must print `42` (oracle: `42`).
- Harness must show 0 regressions; existing `exam/global_int.nelua`,
  `exam/global_arr.nelua`, `exam/global_rec.nelua` must stay MATCH.
- Then `auto` return/param functions become unblocked for
  `plan/INBOX/auto-type-inference.md`.