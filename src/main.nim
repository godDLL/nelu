## CLI entry point for the Nelua-in-Nim compiler.
##
## Wires the parsed CLI `Config` to the M5 `compile` driver and the M2 analyzer
## / M1 parser.  Reads the process command line, parses it, and dispatches on
## the resulting `Config` per input file.  Diagnostics from `compile` are
## printed to stderr; the process exits 0 when every input compiled cleanly and
## 1 when any input produced a diagnostic or could not be read.

import std/[os, strutils]
import cli
import config
import compile
import parser
import analyzer
import osproc

const VersionString = "Nelua-in-Nim 0.2.0-dev (clean-room reimplementation)"

proc printHelp() =
  echo "Usage: nelua [options] [input ...]"
  echo ""
  echo "Options:"
  echo "  -r, --release            Release build (optimize, disable checks)"
  echo "  -b, --binary             Produce a binary (default)"
  echo "  -c, --code               Emit C and stop"
  echo "  -a, --analyze            Analyze only, no codegen"
  echo "  --lint                   Check for syntax errors only"
  echo "  --print-ast              Print the AST"
  echo "  --print-analyzed-ast     Print the analyzed AST"
  echo "  --print-ppcode           Print the preprocessing code"
  echo "  --print-code             Print the generated code"
  echo "  -P <pragma>              Set initial compiler pragma"
  echo "  -D <define>              Define a preprocessor value"
  echo "  --cc <cc>                C compiler to use (default: gcc)"
  echo "  --cflags <flags>         Extra flags for the C compiler"
  echo "  --ldflags <flags>        Extra flags for the linker"
  echo "  --path <dir>             Add a module search path"
  echo "  -o <output>              Output file"
  echo "  --cache-dir <dir>        Compilation cache directory"
  echo "  -s, --strip-bin          Strip symbols from the binary"
  echo "  --sanitize               Enable runtime sanitizers"
  echo "  -g <generator>           Code generator backend (default: c)"
  echo "  --no-cache               Do not use cached compilation"
  echo "  --version                Print the version and exit"
  echo "  --help                   Show this help and exit"

proc main(): int =
  ## Entry point. Returns the process exit code (0 = all clean, 1 = any
  ## diagnostic or unreadable input).
  var args = newSeq[string](paramCount())
  for i in 0..<paramCount():
    args[i] = paramStr(i + 1)

  let (c, positionals) = parseArgs(args)

  if c.help:
    printHelp()
    return 0
  if c.version:
    echo VersionString
    return 0
  if hasError(c):
    return 1

  var failed = false
  for input in positionals:
    var source: string
    try:
      source = readFile(input)
    except OSError, IOError:
      stderr.writeLine("nelua: cannot read '" & input & "': " & getCurrentExceptionMsg())
      failed = true
      continue

    let res = compile(source, input, c)
    for d in res.diagnostics:
      stderr.writeLine(d)
    if res.diagnostics.len > 0:
      failed = true

    if c.printAst:
      echo dump(parser.parse(source, input))
    elif c.printAnalyzedAst:
      var ar = analyzer.analyze(source, input)
      echo dumpAnaled(ar.ctx, ar.root)
    elif c.printPpcode:
      stderr.writeLine("nelua: --print-ppcode is not supported in this build (the preprocessor is not wired into the compile driver)")
    elif c.printCode:
      echo res.cSource
    elif c.codeOnly:
      if c.output.len > 0:
        try:
          writeFile(c.output, res.cSource)
        except OSError, IOError:
          stderr.writeLine("nelua: cannot write '" & c.output & "': " & getCurrentExceptionMsg())
          failed = true
      else:
        echo res.cSource
    elif c.lint:
      # Errors only, no codegen. Diagnostics were already printed above.
      discard
    elif c.analyze:
      var ar = analyzer.analyze(source, input)
      echo dumpAnaled(ar.ctx, ar.root)
    else:
      # Default / -b --binary: compile() already emitted and ran the binary.
      # Honor -o by copying the produced binary to the requested name.
      if c.output.len > 0:
        let builtBin = getCurrentDir() / "tmp" / analyzer.computeUnitname(input)
        try:
          if fileExists(builtBin):
            copyFile(builtBin, c.output)
            # `copyFile` writes the destination with default 0o644 permissions,
            # which strips the executable bit gcc set on the real binary. Copy
            # the source's permissions back so `-o name` yields a runnable file.
            setFilePermissions(c.output, getFilePermissions(builtBin))
          else:
            stderr.writeLine("nelua: no binary was produced to copy to '" & c.output & "'")
            failed = true
        except OSError, IOError:
          stderr.writeLine("nelua: cannot copy binary to '" & c.output & "': " & getCurrentExceptionMsg())
          failed = true

  return if failed: 1 else: 0

when isMainModule:
  if paramCount() == 0:
    # Self-test: exercise the real CLI pipeline end-to-end through the built
    # binary, then clean up the transient test files under tmp/.
    let projRoot = getAppDir().parentDir()
    let tmpDir = projRoot / "tmp"
    let testPath = tmpDir / "mains_selftest.nelua"
    let exe = getAppDir() / "main"
    let q = testPath.quoteShell

    var failed = false

    try:
      writeFile(testPath, "local x = 5\n")
    except OSError:
      echo "SELFTEST FAIL: could not write " & testPath
      quit(1)

    # 1. Default binary path: exit 0, no diagnostics, no stdout.
    let r1 = execCmdEx(exe.quoteShell & " " & q)
    if r1[1] != 0 or r1[0].len > 0:
      echo "SELFTEST FAIL [binary]: exit=" & $r1[1] & " output=[" & r1[0] & "]"
      failed = true
    else:
      echo "SELFTEST OK [binary]: exit 0, no diagnostics"

    # 2. --print-code: non-empty C translation unit.
    let r2 = execCmdEx(exe.quoteShell & " --print-code " & q)
    if r2[1] != 0 or r2[0].len == 0 or "nelua_main" notin r2[0]:
      echo "SELFTEST FAIL [print-code]: exit=" & $r2[1] & " len=" & $r2[0].len
      failed = true
    else:
      echo "SELFTEST OK [print-code]: " & $r2[0].len & " chars of C"

    # 3. --print-analyzed-ast: typed AST dump.
    let r3 = execCmdEx(exe.quoteShell & " --print-analyzed-ast " & q)
    if r3[1] != 0 or "Block" notin r3[0] or "VarDecl" notin r3[0]:
      echo "SELFTEST FAIL [print-analyzed-ast]: exit=" & $r3[1]
      failed = true
    else:
      echo "SELFTEST OK [print-analyzed-ast]: typed AST present"

    # Clean up the test source and any compile() scratch artefacts in tmp/.
    try: removeFile(testPath) except OSError, IOError: discard
    for f in walkDirRec(tmpDir):
      if "mains_selftest" in f:
        try: removeFile(f) except OSError, IOError: discard

    quit(if failed: 1 else: 0)
  else:
    quit(main())