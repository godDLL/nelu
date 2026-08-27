## Diagnostics: the single place that formats compiler error output.
## Every error carries a source span (path, line, col, offset, length), a
## one-line message, and an optional hint.

import span
import strutils

type
  NeluaError* = object
    loc*: SourceLoc
    message*: string
    hint*: string        # optional suggestion; "" if none

  Diagnostics* = ref object
    errors*: seq[NeluaError]

proc cformat*(fmt: string, args: seq[string]): string =
  ## C-style (Lua `string.format`) formatting: `%s`, `%d`, `%i`, `%f`, `%g`,
  ## `%x`, `%o`, `%c`, `%%`, optionally with a width/precision that is accepted
  ## but not reformatted (the args are already strings). The reference Nelua
  ## builds its diagnostics with Lua's `string.format`, so messages must use
  ## `%`-substitution, not Nim's `$`-style `%`. Args are consumed in order;
  ## a missing arg leaves the conversion verbatim.
  var i = 0
  var ai = 0
  while i < fmt.len:
    if fmt[i] == '%':
      if i + 1 < fmt.len and fmt[i + 1] == '%':
        result.add '%'
        i += 2
        continue
      # skip flags/width/precision: chars in [0-9.#\-+ '*#lllhjztp]
      var j = i + 1
      while j < fmt.len and fmt[j] in {'0'..'9', '.', '-', '+', ' ', '*', '#', 'l', 'h', 'j', 'z', 't', 'p'}:
        inc j
      if j < fmt.len:
        case fmt[j]
        of 's', 'd', 'i', 'f', 'g', 'x', 'X', 'o', 'c', 'e', 'E':
          if ai < args.len:
            result.add args[ai]
            inc ai
          else:
            result.add fmt[i .. j]
          i = j + 1
          continue
        else:
          # unknown conversion: emit literally
          result.add fmt[i]
          inc i
          continue
      # trailing '%' with no conversion
      result.add '%'
      inc i
      continue
    result.add fmt[i]
    inc i

proc errorf*(loc: SourceLoc, fmt: string, args: varargs[string]): NeluaError =
  ## Build a NeluaError by formatting fmt with C-style `%` substitution.
  ## If args is empty, fmt is used verbatim.
  result = NeluaError(loc: loc, message: if args.len == 0: fmt else: cformat(fmt, @args))

proc diagnose*(d: Diagnostics, loc: SourceLoc, fmt: string, args: varargs[string]) =
  ## Append an error to d.errors.
  d.errors.add errorf(loc, fmt, args)

proc hasErrors*(d: Diagnostics): bool =
  ## True if any errors have been recorded.
  result = d.errors.len > 0

proc sourceLineText(source: string, offset: int): string =
  ## Slice out the single source line that contains `offset`.
  let o = min(max(offset, 0), source.len)
  var start = o
  while start > 0 and source[start - 1] != '\n':
    dec start
  var finish = o
  while finish < source.len and source[finish] != '\n':
    inc finish
  result = source[start ..< finish]

proc render*(d: Diagnostics, source: string = ""): string =
  ## Render all errors, one per line, as:
  ##   path:line:col: error: <message>
  ##   path:line:col: hint: <hint>     (only when hint != "")
  ## When `source` is supplied, a caret line under the offending line text
  ## is appended for each error.
  var lines: seq[string] = @[]
  for e in d.errors:
    lines.add "$1:$2:$3: error: $4" % [e.loc.path, $e.loc.line, $e.loc.col, e.message]
    if e.hint != "":
      lines.add "$1:$2:$3: hint: $4" % [e.loc.path, $e.loc.line, $e.loc.col, e.hint]
    if source != "":
      let text = sourceLineText(source, e.loc.offset)
      if text != "":
        lines.add text
        var caret = ""
        for _ in 0 ..< max(e.loc.col - 1, 0):
          caret.add ' '
        caret.add '^'
        lines.add caret
  result = if lines.len > 0: lines.join("\n") else: ""

when isMainModule:
  let sample = "local x = 1\nlocal y = 2"
  let diags = new Diagnostics
  diags.diagnose(newSourceLoc("sample.lua", sample, 12), "unexpected near '%s'", ["2"])
  diags.errors.add NeluaError(
    loc: newSourceLoc("sample.lua", sample, 12),
    message: "duplicate local 'y'",
    hint: "did you mean 'x'?"
  )
  echo diags.render(sample)
  # C-style formatting sanity (must substitute, not pass through verbatim)
  let probe = errorf(newSourceLoc("p.lua", "x", 0), "expected %s got %s (%d times)", ["integer", "string", "3"])
  doAssert probe.message == "expected integer got string (3 times)", probe.message
  let literal = errorf(newSourceLoc("p.lua", "x", 0), "plain message")
  doAssert literal.message == "plain message"
  echo "cformat OK"