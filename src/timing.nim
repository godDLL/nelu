## Per-stage compile timing, enabled by `-t` / `-T`.
##
## `-t` buffers stage durations and flushes them as a group after the compile
## (gcc) step, before the program runs; `run` and `total time` are emitted at
## their own boundaries.  `-T` prints per-file lines inline as the stages
## complete.  All output goes to stdout, matching the oracle.
##
## Stage names are aggregated across modules (a `require`d dependency goes
## through the same parse/preprocess/analyze path as the main unit), so the
## buffered `-t` block emits each stage once regardless of how many modules
## compiled -- this is what the oracle's `-t` output shows.

import std/[times, strutils]

var enabled*: bool = false
var stages*: bool = false          ## -t buffered stage block
var detail*: bool = false          ## -T
var t0*: float = 0.0               ## process start, ms since epoch
var stack*: seq[tuple[name: string, t: float]] = @[]
var records*: seq[tuple[name: string, ms: float]] = @[]
var flushed*: bool = false         ## true once the buffered group printed
var startupPrinted*: bool = false

proc setStart*() =
  ## Record the process start time. Call as early as possible in main() so the
  ## `startup` stage measures arg parsing and config setup too.
  t0 = epochTime() * 1000.0

proc nowMs*: float =
  ## Current wall-clock time in ms since epoch.  Call sites that time a stage
  ## with their own local timer (the `-T` per-file lines) capture a start value
  ## and pass `nowMs() - start` to `markFile`.
  epochTime() * 1000.0

proc begin*() =
  if not enabled: return
  if t0 == 0.0: t0 = epochTime() * 1000.0

proc markStart*(name: string) =
  if not enabled: return
  if t0 == 0.0: t0 = epochTime() * 1000.0
  stack.add (name, epochTime() * 1000.0)

proc markStop*(name: string): float =
  ## Stop the most recent stage. Returns its duration in ms (0.0 if the stack
  ## is empty, which should not happen for a balanced mark pair).
  if not enabled or stack.len == 0: return 0.0
  let (n, t) = stack.pop()
  let ms = epochTime() * 1000.0 - t
  records.add (n, ms)
  return ms

proc markFile*(kind, file: string, ms: float) =
  ## Inline per-file line for `-T`.  `kind` is `parsed` / `preprocessed` /
  ## `analyzed`; `file` is the module path (empty for `analyzed`, which the
  ## oracle prints with no filename).  `ms` is the stage duration measured by
  ## the caller with its own local timer: the oracle times each stage with a
  ## local timer in `aster.parse` / `preprocessor.preprocess` / the analyze
  ## traverse, and our `-t` mark stack is balanced by the time the real stages
  ## run, so reading the stack here would report 0.0 for every line.
  ##
  ## `analyzed` is printed once per call (i.e. once per module), matching the
  ## oracle, which emits one `analyzed` line per analyzed translation unit.
  if not enabled or not detail: return
  if kind == "analyzed":
    echo "analyzed" & " (" & formatFloat(ms, ffDecimal, precision = 1) & " ms)"
  else:
    echo kind & " " & file & " (" & formatFloat(ms, ffDecimal, precision = 1) & " ms)"

proc flushStages*() =
  ## Print the buffered `-t` stage group (aggregated by name) and clear it.
  if not stages or flushed: return
  flushed = true
  var totals: seq[tuple[name: string, ms: float]] = @[]
  for (n, ms) in records:
    var found = false
    for i, t in totals:
      if t.name == n:
        totals[i].ms += ms
        found = true
        break
    if not found:
      totals.add (n, ms)
  let width = 13
  for (n, ms) in totals:
    echo n & " ".repeat(max(0, width - n.len)) &
        formatFloat(ms, ffDecimal, precision = 1) & " ms"
  records.setLen(0)

proc printRun*(ms: float) =
  if not stages or ms < 0.0: return
  echo "run" & " ".repeat(max(0, 13 - "run".len)) &
      formatFloat(ms, ffDecimal, precision = 1) & " ms"

proc printTotal*() =
  if not stages: return
  let ms = if t0 != 0.0: epochTime() * 1000.0 - t0 else: 0.0
  echo "total time" & " ".repeat(max(0, 13 - "total time".len)) &
      formatFloat(ms, ffDecimal, precision = 1) & " ms"