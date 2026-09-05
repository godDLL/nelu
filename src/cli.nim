## Command-line argument parsing for the Nelua-in-Nim compiler.
##
## Uses Nim's standard library parseopt. The parser runs in LaxMode so that
## value-taking options may separate their value by whitespace (both
## `-o out.bin` and `--cc gcc` work). The boolean flags are listed in
## ShortNoVal/LongNoVal so parseopt never consumes the following token as
## their value.
##
## Returns the populated Config together with the leftover positional
## arguments (the source files). Unknown flags do not crash: the problem is
## reported on stderr and the returned Config carries an error marker.

import std/[parseopt, os]
import config

type
  CliError* = object of ValueError
    ## Raised to signal a command-line usage error. The CLI layer itself
    ## reports the problem and stores the message on the Config instead.

const ShortNoVal = {'r', 'b', 'c', 'a', 'l', 's', 'h', 'v', 'V',
                    'B', 'Y', 'A', 'H',
                    'w', 'd', 'M', 't', 'T',
                    'S', 'C', 'j', 'q'}
const LongNoVal: seq[string] = @[
  "release", "binary", "code", "analyze", "lint",
  "strip-bin", "sanitize", "no-cache", "verbose",
  "version", "help", "no-warning", "no-color",
  "script", "lua",
  "print-ast", "print-analyzed-ast", "print-ppcode", "print-code",
  "print-assembly",
  "object", "assembly", "static-lib", "shared-lib",
  "timing", "more-timing", "maximum-performance", "debug", "semver",
  "config",
]

## Exact token of the explicitly-chosen output mode, kept across the parseopt
  ## loop so a second distinct mode can be reported as a conflict (the oracle's
  ## `option '<second>' can not be used together with option '<first>'`).
var currentOutputModeToken = ""

proc setOutputKind(c: var Config, k: OutputKind, token: string) =
  ## Set the output mode, rejecting conflicts.  The output modes are a choice
  ## group (the oracle lists them as `([-b] | [-B] | [-Y] | [-A] | [-H])`), so
  ## passing two DIFFERENT modes is a usage error rather than last-one-wins
  ## silently.  The error names the second token the subject and the first the
  ## conflict, using the EXACT form the user typed (`-b -B` ->
  ## `option '-B' can not be used together with option '-b'`; `--binary
  ## --object` -> the long form).  Repeating the SAME mode (`-b --binary`) is
  ## not a conflict.
  if currentOutputModeToken.len > 0 and k != c.outputKind:
    c.parseError = "option '" & token & "' can not be used together with option '" & currentOutputModeToken & "'"
  else:
    c.outputKind = k
    currentOutputModeToken = token

proc parseArgs*(args: seq[string]): (Config, seq[string]) =
  ## Parse args into a Config and the leftover positional arguments.
  var c = defaultConfig()
  var positionals: seq[string] = @[]
  currentOutputModeToken = ""
  # Order of the print-and-exit tokens (--version / --semver / --config) and
  # `input` as they appeared on the command line.  main.nim uses this to report
  # mutual exclusivity with the oracle's exact wording and subject ordering
  # (`--config hello` -> "argument 'input' can not be used together with
  # option '--config'"; `hello --config` -> the reverse).
  var cliTokens: seq[string] = @[]

  # Split on "--": everything from the first "--" onward is positional, so a
  # trailing value can never be mistaken for an option. parseopt would
  # otherwise consume the token after "--" as the value of an empty-named
  # long option, which is not the POSIX end-of-options semantics we want.
  var parsed: seq[string] = @[]
  var rest: seq[string] = @[]
  var pastDash = false
  for a in args:
    if pastDash:
      rest.add(a)
    elif a == "--":
      pastDash = true
    elif a == "-":
      # A lone dash is the stdin marker, not an option.  parseopt treats it as
      # a (valueless) short option and our case would reject it as unknown;
      # route it straight to the positionals so `--script -` works.
      positionals.add(a)
    else:
      parsed.add(a)

  # If nothing precedes the first "--" (or there were no args at all), there is
  # nothing for parseopt to consume. Note that initOptParser falls back to the
  # real process command line when given an empty sequence, so we must not hand
  # it an empty seq.
  if parsed.len == 0:
    for r in rest:
      positionals.add(r)
    return (c, positionals)

  var p = initOptParser(parsed, shortNoVal = ShortNoVal,
                        longNoVal = LongNoVal, mode = LaxMode)
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdArgument:
      positionals.add(p.key)
      cliTokens.add "input"
    of cmdShortOption:
      case p.key
      of "r", "release": c.release = true
      of "b", "binary": c.binary = true; setOutputKind(c, okBinary, "-" & p.key)
      of "c", "code": c.codeOnly = true
      of "a", "analyze": c.analyze = true
      of "l", "lint": c.lint = true
      of "s", "strip-bin": c.stripBin = true
      of "S": c.sanitize = true
      of "C": c.noCache = true
      of "w": c.noWarning = true
      of "d": c.debug = true
      of "M": c.maxPerf = true
      of "t": c.timing = true
      of "T": c.moreTiming = true
      of "h", "help": c.help = true
      of "v", "version": c.version = true; cliTokens.add "version"
      of "V": c.verbose = true
      of "o", "output": c.output = p.val
      of "B": setOutputKind(c, okObject, "-B")
      of "Y": setOutputKind(c, okAssembly, "-Y")
      of "A": setOutputKind(c, okStaticLib, "-A")
      of "H": setOutputKind(c, okSharedLib, "-H")
      of "P": c.pragmas.add(p.val)
      of "D": c.defines.add(p.val)
      of "g": c.generator = p.val
      of "i": c.eval = true; c.evalCode = p.val
      of "R": c.runner = p.val
      of "L":
        if not dirExists(p.val):
          c.parseError = "path '" & p.val & "' is not a valid directory"
          break
        c.addAddPath(p.val)
      of "j": discard
      of "q": discard
      else:
        c.parseError = "unknown option '" & ("-" & p.key) & "'"
        break
    of cmdLongOption:
      case p.key
      of "release": c.release = true
      of "script": c.script = true
      of "lua": c.luaRepl = true
      of "binary": c.binary = true; setOutputKind(c, okBinary, "--binary")
      of "code": c.codeOnly = true
      of "analyze": c.analyze = true
      of "lint": c.lint = true
      of "strip-bin": c.stripBin = true
      of "no-warning": c.noWarning = true
      of "no-color": c.noColor = true
      of "debug": c.debug = true
      of "maximum-performance": c.maxPerf = true
      of "timing": c.timing = true
      of "more-timing": c.moreTiming = true
      of "stripflags": c.stripflags = p.val
      of "generator": c.generator = p.val
      of "sanitize": c.sanitize = true
      of "no-cache": c.noCache = true
      of "version": c.version = true; cliTokens.add "version"
      of "verbose": c.verbose = true
      of "semver": c.semver = true; cliTokens.add "semver"
      of "help", "h": c.help = true
      of "print-ast": c.printAst = true
      of "print-analyzed-ast": c.printAnalyzedAst = true
      of "print-ppcode": c.printPpcode = true
      of "print-code": c.printCode = true
      of "print-assembly": c.printAssembly = true
      of "cc": c.cc = p.val
      of "cflags": c.cflags = p.val
      of "ldflags": c.ldflags = p.val
      of "path": c.addPath(p.val)
      of "runner": c.runner = p.val
      of "load": c.loads.add(p.val)
      of "eval": c.eval = true; c.evalCode = p.val
      of "add-path":
        if not dirExists(p.val):
          c.parseError = "path '" & p.val & "' is not a valid directory"
          break
        c.addAddPath(p.val)
      of "cache-dir": c.cacheDir = p.val
      of "output": c.output = p.val
      of "object": setOutputKind(c, okObject, "--object")
      of "assembly": setOutputKind(c, okAssembly, "--assembly")
      of "static-lib": setOutputKind(c, okStaticLib, "--static-lib")
      of "shared-lib": setOutputKind(c, okSharedLib, "--shared-lib")
      of "config": c.config = true; cliTokens.add "config"
      of "define": c.defines.add(p.val)
      of "pragma": c.pragmas.add(p.val)
      else:
        c.parseError = "unknown option '" & ("--" & p.key) & "'"
        break

  for r in rest:
    positionals.add(r)
    cliTokens.add "input"

  c.cliOrder = cliTokens
  return (c, positionals)
