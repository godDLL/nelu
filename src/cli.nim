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
                    'B', 'Y', 'A', 'H'}
const LongNoVal: seq[string] = @[
  "release", "binary", "code", "analyze", "lint",
  "strip-bin", "sanitize", "no-cache",
  "version", "help",
  "print-ast", "print-analyzed-ast", "print-ppcode", "print-code",
  "object", "assembly", "static-lib", "shared-lib",
  "config",
]

proc setOutputKind(c: var Config, k: OutputKind, name: string) =
  ## Set the output mode, rejecting conflicts.  The output modes are a
  ## choice group (the oracle lists them as `([-b] | [-B] | [-Y] | [-A] |
  ## [-H])`), so passing more than one is a usage error rather than a
  ## last-one-wins silently.
  if c.outputKind != okBinary:
    c.parseError = "output mode conflicts with the already-set output mode"
    stderr.writeLine("nelua: --" & name & ": " & c.parseError)
  else:
    c.outputKind = k

proc parseArgs*(args: seq[string]): (Config, seq[string]) =
  ## Parse args into a Config and the leftover positional arguments.
  var c = defaultConfig()
  var positionals: seq[string] = @[]

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
    of cmdShortOption:
      case p.key
      of "r", "release": c.release = true
      of "b", "binary": c.binary = true
      of "c", "code": c.codeOnly = true
      of "a", "analyze": c.analyze = true
      of "l", "lint": c.lint = true
      of "s", "strip-bin": c.stripBin = true
      of "h", "help": c.help = true
      of "v", "version": c.version = true
      of "V": c.verbose = true
      of "o", "output": c.output = p.val
      of "B": setOutputKind(c, okObject, "object")
      of "Y": setOutputKind(c, okAssembly, "assembly")
      of "A": setOutputKind(c, okStaticLib, "static-lib")
      of "H": setOutputKind(c, okSharedLib, "shared-lib")
      of "P": c.pragmas.add(p.val)
      of "D": c.defines.add(p.val)
      of "g": c.generator = p.val
      of "L":
        if not dirExists(p.val):
          c.parseError = "path '" & p.val & "' is not a valid directory"
          stderr.writeLine("error: " & c.parseError)
          break
        c.addAddPath(p.val)
      else:
        c.parseError = "unknown short option: -" & p.key
        stderr.writeLine("nelua: " & c.parseError)
        break
    of cmdLongOption:
      case p.key
      of "release": c.release = true
      of "binary": c.binary = true
      of "code": c.codeOnly = true
      of "analyze": c.analyze = true
      of "lint": c.lint = true
      of "strip-bin": c.stripBin = true
      of "sanitize": c.sanitize = true
      of "no-cache": c.noCache = true
      of "version": c.version = true
      of "help", "h": c.help = true
      of "print-ast": c.printAst = true
      of "print-analyzed-ast": c.printAnalyzedAst = true
      of "print-ppcode": c.printPpcode = true
      of "print-code": c.printCode = true
      of "cc": c.cc = p.val
      of "cflags": c.cflags = p.val
      of "ldflags": c.ldflags = p.val
      of "path": c.addPath(p.val)
      of "add-path":
        if not dirExists(p.val):
          c.parseError = "path '" & p.val & "' is not a valid directory"
          stderr.writeLine("error: " & c.parseError)
          break
        c.addAddPath(p.val)
      of "cache-dir": c.cacheDir = p.val
      of "output": c.output = p.val
      of "object": setOutputKind(c, okObject, "object")
      of "assembly": setOutputKind(c, okAssembly, "assembly")
      of "static-lib": setOutputKind(c, okStaticLib, "static-lib")
      of "shared-lib": setOutputKind(c, okSharedLib, "shared-lib")
      of "config": c.config = true
      else:
        c.parseError = "unknown option: --" & p.key
        stderr.writeLine("nelua: " & c.parseError)
        break

  for r in rest:
    positionals.add(r)

  return (c, positionals)
