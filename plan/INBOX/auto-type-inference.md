# Auto type inference

Status: design spec (most facets implemented 2026-09-06)

## What the oracle does with `auto`

`auto` is a builtin type (`BuiltinTypes["auto"]`, `tkAuto`) that means
**"infer this type"**.  The oracle implements it in several distinct
positions, each with its own rule.  Measured 2026-09-06 against
`/usr/bin/nelua` (Build 1635):

| # | Position | Oracle behaviour | Nelu status |
|---|---|---|---|
| 1 | `local x: auto = <init>` | infers the init expr type (`1`→int64, `"hi"`→string, `true`→bool) | **FIXED** (`56ae152`) |
| 2 | `local x: auto` (no init, unused) | accepted, exit 0 | accepted, exit 0 |
| 3 | `local x: auto` (no init) used in `print` | rejects: `in print: cannot handle type "auto"` | **FIXED** (`45dee17`) — same diagnostic |
| 4 | `auto` as a first-class type value | `auto == auto`→`true`, `auto == integer`→`false`, `print(auto)`→`in print: cannot handle type "type"`; `auto` is a *distinct* `type`-typed value | resolves to `nil`. **Open** -- part of the broader type-as-value gap (`type-as-value-design.md`); nelu does not resolve *any* type keyword as a value (`integer == integer`→`nil`), so this is not auto-specific |
| 5 | `function f(): auto return <literal>` (named) | accepted (`function foo(): auto return 42 end` → prints `42`) | **FIXED** (`413ad66`, via the global-function codegen fix) |
| 6 | `function f(x: auto)` (named polymorphic param) | the oracle itself rejects the simple form ("no viable type conversion to polyfunction"); polymorphization is finicky | both reject → MATCH (neg). No divergence to fix |
| 7 | `auto` on an anonymous function | **rejected**: "anonymous functions cannot be polymorphic" / "anonymous functions cannot have 'auto' returns" | both reject → MATCH (neg). No divergence to fix |

## Design

The unifying rule is: **`auto` is a placeholder that must be resolved to a
concrete type before the value is used.**  Where it can be resolved (from an
initializer, from a return expression, from a call argument), it becomes that
type.  Where it cannot be resolved, the value stays `auto`-typed and is
*unusable* -- every use is a compile error whose message names `auto`.

That single rule covers all seven positions:

- #1: initializer supplies the concrete type → resolve.
- #2/#3: no initializer → stays `auto`; unused is fine, any use errors.
- #4: `auto` in a value position is a type value of kind `tkAuto` (distinct
  from `integer`/`any`/etc.), usable only in type-comparison contexts the
  oracle accepts.  **Not implemented** -- see the type-as-value gap.
- #5: the function's return type is the placeholder; each `return` supplies
  the concrete type.  Requires the global-function codegen to be sound.
- #6/#7: the oracle draws the line at anonymous functions and at the simple
  polymorphic-param form; nelu rejects both too, so there is no divergence.

## Remaining work

Only **#4** remains, and it is not auto-specific: nelu resolves no type
keyword (`integer`, `any`, `auto`) as a first-class type value.  It is
tracked by `plan/INBOX/type-as-value-design.md`.  Auto-specific work is
complete.

## Verification

Each facet was matched against the oracle with an isolated probe; the full
harness (`python3 plan/harness.py`) shows 0 regressions after each commit.

## Notes

- The `auto` *return-type* inference (`deduceAutoReturns`) sets
  `ftype.returns[i]` to the first textual return's type; it was correct all
  along.  The #5 failure was a codegen duplicate-symbol, not an inference bug.
- #6 (polymorphic `auto` params) depends on the D1 monomorphization path
  (`specializeCall`); the oracle's own behaviour there is finicky and both
  compilers reject the simple form, so it is not a nelu divergence.