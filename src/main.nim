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

# Nim's `quit` clamps the exit code to the `int8` range on POSIX (anything > 127
# becomes 127), which breaks exit-code propagation for programs that abort
# (the oracle reports 255) or os.exit with a high code.  Bypass it with a direct
# C `exit` import so the full 0..255 range is preserved.
proc cexit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

const VersionString = "Nelua-in-Nim 0.2.0-dev (clean-room reimplementation)"

proc printHelp() =
  echo "Usage: nelua [options] [input ...]"
  echo ""
  echo "Options:"
  echo "  -r, --release            Release build (optimize, disable checks)"
  echo "  -b, --binary             Produce a binary (default)"
  echo "  -B, --object             Compile to a relocatable object (.o)"
  echo "  -Y, --assembly          Emit assembly (.s)"
  echo "  -A, --static-lib         Archive into a static library (.a)"
  echo "  -H, --shared-lib         Link into a shared library (.so)"
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
  echo "  -L <dir>, --add-path <dir>  Add a module search path (accumulating)"
  echo "  -o <output>              Output file"
  echo "  --cache-dir <dir>        Compilation cache directory"
  echo "  -s, --strip-bin          Strip symbols from the binary"
  echo "  --sanitize               Enable runtime sanitizers"
  echo "  -g <generator>           Code generator backend (default: c)"
  echo "  --no-cache               Do not use cached compilation"
  echo "  --version                Print the version and exit"
  echo "  --config                 Dump the effective configuration and exit"
  echo "  -V                       Verbose: echo generated C and cc command line"
  echo "  --help                   Show this help and exit"

proc dumpConfig(c: Config) =
  ## Dump the effective configuration as a Lua-table-format JSON, matching the
  ## reference's `--config` output shape (lists as `{ "a", "b" }`, strings as
  ## `key = "value"`, the `path` key a single semicolon-joined string).  The
  ## final key has no trailing comma, matching the reference exactly.
  proc list(s: seq[string]): string =
    if s.len == 0:
      return "{}"
    result = "{ "
    for i, v in s:
      result.add "\"" & v & "\""
      if i < s.len - 1:
        result.add ", "
    result.add " }"
  proc str(v: string): string = "\"" & v & "\""
  let path = if c.paths.len == 0: DefaultPath else: ";" & c.paths.join(";")
  let cacheDir = if c.cacheDir.len > 0: c.cacheDir else: "/home/user/.cache/nelua"
  let gen = if c.generator.len > 0: c.generator else: "c"
  let lines = [
    "  add_path = " & c.addPath.list() & "",
    "  cache_dir = " & str(cacheDir) & "",
    "  cc = " & str(c.cc) & "",
    "  cflags = " & str(c.cflags) & "",
    "  define = " & c.defines.list() & "",
    "  gdb = " & str("gdb") & "",
    "  generator = " & str(gen) & "",
    "  ldflags = " & str(c.ldflags) & "",
    "  lib_path = " & str(LibPath) & "",
    "  lua = " & str("/usr/bin/nelua-lua") & "",
    "  lua_cpath = " & str(LuaCPath) & "",
    "  lua_path = " & str(LuaPath) & "",
    "  lua_version = " & str(LuaVersion) & "",
    "  lualib_path = " & str(LualibPath) & "",
    "  output_dir = " & str("/home/user/.cache/nelua") & "",
    "  path = " & str(path) & "",
    "  pragma = " & list(@[]) & "",
    "  pragmas = " & c.pragmas.list() & "",
    "  runargs = " & list(@[]) & "",
    "  stripflags = " & str("-x") & "",
  ]
  echo "{"
  for i, l in lines:
    if i < lines.len - 1:
      echo l & ","
    else:
      echo l
  echo "}"

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

  if c.config:
    if positionals.len > 0:
      stderr.writeLine("error: argument 'input' can not be used together with option '--config'")
      return 1
    dumpConfig(c)
    return 0

  if positionals.len == 0:
    ## No input: the oracle prints usage and exits 0.
    printHelp()
    return 0

  var failed = false
  var exitCode = 0
  for input in positionals:
    var source: string
    try:
      source = readFile(input)
    except OSError, IOError:
      stderr.writeLine("nelua: cannot read '" & input & "': " & getCurrentExceptionMsg())
      failed = true
      continue

    ## `--print-ast` / `--print-analyzed-ast` / `--analyze` / `--print-ppcode`
    ## only need the parser or analyzer.  They must NOT run the C code
    ## generator (genC in compile.nim:138): the emitter segfaults on valid
    ## constructs (method calls, anonymous functions, if/elseif) and would
    ## abort the dump.  The oracle's --print-ast also does not codegen.
    ##
    ## `--lint` is syntax-only too: the reference checks only that the source
    ## parses, and deliberately does NOT run the preprocessor, analyzer or
    ## codegen (a `## error(...)` line or an unresolved `#[x]#` splice is
    ## accepted by `--lint`; only a real parse error fails it).  Without this
    ## `--lint` drove the full compile pipeline and aborted on the unresolved
    ## splices in `lib/detail/xoshiro256.nelua`, a `require` of `lib/math.nelua`.
    let needsCompile = not (c.printAst or c.printAnalyzedAst or
                            c.analyze or c.printPpcode or c.lint)
    let res = if needsCompile: compile(source, input, c)
              else: CompileResult(success: true)
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
      # Syntax check only, matching the reference.  `parser.parse` prints the
      # diagnostic itself and returns nil on a ParseError; anything that does
      # not parse is a lint failure.  Preprocessor/analyzer/codegen are NOT
      # run, so unresolved `#[expr]#` splices and `##` directives are accepted.
      let ast = parser.parse(source, input)
      if ast == nil:
        failed = true
    elif c.analyze:
      var ar = analyzer.analyze(source, input)
      echo dumpAnaled(ar.ctx, ar.root)
    else:
      # Default / -b --binary: compile() already emitted and ran the binary.
      if c.output.len > 0:
        # Honor -o by copying the produced binary to the requested name.
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
      else:
        # No -o: the oracle compiles and runs, printing the program's stdout
        # and propagating its exit code. compile() already captured both.
        stdout.write(res.output)
        exitCode = res.exitCode

  return if failed: 1 elif exitCode != 0: exitCode else: 0

when isMainModule:
  cexit(cint(main()))