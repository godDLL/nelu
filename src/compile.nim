## M4 compiler driver: nelua source -> C -> (optional) native executable.
##
## `compile` is the top-level entry point of the Nelua-in-Nim pipeline.  It is a
## thin wrapper around the M3 code generator `genC`, which is **self-contained**:
## `genC(source, path)` internally calls `parse` + `analyze` and emits one
## translation unit.  We therefore do *not* redundantly parse/preprocess/analyze
## here -- `compile` just emits the C, writes it under `tmp/`, invokes
## `config.cc`, and -- when `config.binary` -- runs the produced executable.
##
## Preprocessing is a separate stage (`preprocessor.nim`) that operates on the
## M1 AST.  It is NOT folded into this driver yet -- see backlog item **C3**
## (`tmp/NOTE_backlog.md`): the resolved seam is to run `preprocess` inside
## `analyze` right after `parse` (preprocessor.nim's `spliceInclude` re-parses
## `#include`s internally, so no signature change is needed), which makes it
## active for every pipeline including this one.  Trivial programs with no
## preprocessor directives are unaffected in the meantime.
##
## Diagnostics: analyzer failure is surfaced by `genC` returning a `/* nelua: ... */`
## stub instead of a real translation unit; C-compile failures are captured from
## the compiler's stderr.  Both land in `CompileResult.diagnostics`.

import std/[options, strutils, os, osproc, tables, times]
import ./cgen
import ./config
import ./analyzer
import ./parser
import ./ast
import ./luaengine
import ./timing

proc outputExtension(kind: OutputKind): string =
  ## File extension for the final artifact of an output mode ("" for a bare
  ## executable, which takes no suffix).
  case kind:
    of okBinary: ""
    of okObject: "o"
    of okAssembly: "s"
    of okStaticLib: "a"
    of okSharedLib: "so"

type
  CompileResult* = object
    success*: bool              ## genC emitted a real translation unit (not a stub)
    cSource*: string            ## the emitted C translation unit
    diagnostics*: seq[string]   ## analyzer / C-compile diagnostics
    exitCode*: int              ## -1 if nothing ran; else the last step's exit code
    output*: string             ## captured run stdout; "" if nothing was run
    assemblySource*: string     ## gcc -S stdout; populated by --print-assembly
    runMs*: float = -1.0        ## duration of the run step, in ms (-1 = no run)

  ModuleCache* = object
    ## Per-`compile()` invocation cache of resolved module path -> cached C
    ## file.  An empty string value marks a module currently being compiled
    ## (cycle break); a non-empty value is the on-disk `.c` file.
    files*: Table[string, string]

proc newModuleCache*: ModuleCache =
  ModuleCache(files: initTable[string, string]())

proc cacheDir*(): string =
  ## The build cache, matching the oracle's own layout: `~/.cache/nelu`,
  ## created if needed.  Every intermediate for a unit (.c, .o, .s, .a, .so)
  ## and the final binary live here, named after the unit -- so a recompile of
  ## the same source lands at the same path, and the run step finds the binary
  ## where the compile step put it.
  let d = getHomeDir() / ".cache" / "nelu"
  if not dirExists(d):
    createDir(d)
  return d

proc resolveModule*(name: string, config: Config, requiringPath: string): string =
  ## Resolve a required module name to an absolute `.nelua` file path.
  ##
  ## Module names use `.` as a path separator (`require 'allocators.general'`
  ## -> `lib/allocators/general.nelua`).  A leading `.` segment means "the
  ## directory of the file doing the requiring" (so `require '.foo'` from
  ## `tests/a.nelua` finds `tests/foo.nelua`).  Search order: `-L`/`--add-path`
  ## dirs (first match wins), then `--path` entries (last-wins; any `--path`
  ## replaces the default entirely), then the default templates (`./?.nelua`,
  ## `./?/init.nelua`, the system lib dir, and its `init.nelua`), then OUR
  ## extensions (project `lib/`, the requiring file's dir, cwd).  Returns ""
  ## when no candidate exists.
  ##
  ## The lexer keeps a string literal's delimiters in its token value, so a
  ## `require 'foo'` name arrives as `'foo'`; strip the surrounding quotes here
  ## (the reference stores bare names) before splitting on `.`.
  var name = name
  if name.len >= 2 and ((name[0] == '"' and name[^1] == '"') or
                        (name[0] == '\'' and name[^1] == '\'')):
    name = name[1 ..< name.len - 1]
  let segments = name.split('.')
  var candidates: seq[string] = @[]
  if segments.len > 0 and segments[0] == "":
    let base = requiringPath.splitFile().dir
    candidates.add base / segments[1 ..< segments.len].join("/") & ".nelua"
  for p in config.addPath:
    candidates.add p / segments.join("/") & ".nelua"
    candidates.add p / segments.join("/") / "init.nelua"
  for p in config.paths:
    candidates.add p / segments.join("/") & ".nelua"
  if config.paths.len == 0:
    candidates.add getCurrentDir() / segments.join("/") & ".nelua"
    candidates.add getCurrentDir() / segments.join("/") / "init.nelua"
    # OUR project `lib/` is this compiler's stdlib -- the mirror of the oracle's
    # own system-lib default (`/usr/lib/nelua/lib/?.nelua`).  It is the terminal
    # default: `require 'string'` resolves to our `lib/string.nelua`, which our
    # own parser can compile.  We do NOT default to the oracle's system lib
    # (`LibPath`): that is the *oracle's* stdlib, and our compiler cannot compile
    # it (12 of its 51 modules SIGSEGV our analyzer; string.nelua uses `## if
    # <typequery>` preprocessor blocks and `auto` multi-returns ours lacks).
    # Users can still add it explicitly via `--path`.
    candidates.add getCurrentDir() / "lib" / segments.join("/") & ".nelua"
    candidates.add getCurrentDir() / "lib" / segments.join("/") / "init.nelua"
  let reqDir = requiringPath.splitFile().dir
  if reqDir.len > 0:
    candidates.add reqDir / segments.join("/") & ".nelua"
  candidates.add getCurrentDir() / segments.join("/") & ".nelua"
  for c in candidates:
    if fileExists(c):
      return c
  return ""

proc findRequires*(ast: Node): seq[string] =
  ## Collect the module names of every `require 'name'` call anywhere in the
  ## tree, not only top-level statement position.  `require` lowers to a call
  ## on the builtin `require` (see parser.nim); it may appear in expression
  ## position (`local m = require 'foo'`), inside a function body, or inside a
  ## branch that never executes -- the reference resolves it there too, so a
  ## missing module must be detected regardless of where the call sits instead
  ## of being silently lowered to nothing (which is what masked stdlib gaps:
  ## the program ran as if the require had returned nil).
  if ast == nil:
    return
  if ast.kind == nkCall and ast.children.len == 2 and
     ast.children[1].kind == nkId and ast.children[1].str == "require" and
     ast.children[0].kind == nkString:
    result.add ast.children[0].str
  for c in ast.children:
    let sub = findRequires(c)
    if sub.len > 0:
      result &= sub

proc compileUnit*(source: string, path: string, config: Config,
                   cache: var ModuleCache): CompileResult =
  ## Compile one Nelua translation unit through the full pipeline, recursively
  ## compiling its `require` dependencies first (caching their emitted C under
  ## `tmp/`), then emitting this unit's own C via `genC` and writing it to the
  ## cache.  Returns the unit's `CompileResult`; the C file is written on disk
  ## only when the unit compiled cleanly.
  result.exitCode = -1
  result.output = ""
  # Mark in-progress before recursing so a circular require cannot loop.
  cache.files[path] = ""
  # A dependency that failed to compile must abort this unit too.  Without this
  # guard the driver proceeds to `genC` on this unit, which re-resolves the
  # require through `analyze`, gets a dependency result whose `root` is nil
  # (the dependency did not parse), and SIGSEGVs walking `root.children` in the
  # code generator.  Abort cleanly with the dependency's diagnostics instead.
  var depFailed = false

  # `-t` startup line: printed once, before the very first parse, measuring
  # process start -> arg parsing -> config setup -> driver dispatch.
  if timing.stages and timing.t0 != 0.0 and not timing.startupPrinted:
    timing.startupPrinted = true
    echo "startup" & " ".repeat(max(0, 13 - "startup".len)) &
        formatFloat(epochTime() * 1000.0 - timing.t0, ffDecimal, precision = 1) & " ms"

  timing.markStart("parse")
  let ast = parser.parse(source, path)
  discard timing.markStop("parse")
  if ast != nil:
    for modname in findRequires(ast):
      let depPath = resolveModule(modname, config, path)
      if depPath == "":
        result.diagnostics.add "require '" & modname & "': module not found"
        # Abort this unit.  Without this the driver proceeds to `genC`, which
        # re-resolves the require through `analyze` (whose `findRequires` is
        # still top-level-only) and -- for a require in expression/nested
        # position -- emits no diagnostic at all, lowering the call to nothing
        # so the program builds and runs as if `require` had returned nil.
        depFailed = true
        continue
      if cache.files.hasKey(depPath):
        continue  # already compiled (or currently being compiled)
      var depSrc = ""
      try:
        depSrc = readFile(depPath)
      except OSError, IOError:
        result.diagnostics.add "require '" & modname & "': cannot read '" & depPath & "'"
        continue
      let depRes = compileUnit(depSrc, depPath, config, cache)
      result.diagnostics &= depRes.diagnostics
      if not depRes.success:
        result.diagnostics.add "require '" & modname & "': dependency '" & depPath & "' did not compile"
        depFailed = true

  if depFailed:
    result.success = false
    return

  let cSource = genC(source, path, config.release or config.maxPerf,
                     config.release or config.maxPerf, config)
  result.cSource = cSource
  result.success = cSource.len > 0 and not cSource.startsWith("/* nelua")
  if not result.success:
    result.diagnostics.add "nelua: unable to analyze " & path & ":\n" & cSource.strip()
    return

  let unitname = analyzer.computeUnitname(path)
  let tdir = cacheDir()
  let cfile = tdir / unitname & ".c"
  try:
    writeFile(cfile, cSource)
    if config.verbose:
      echo "generated " & cfile
  except OSError, IOError:
    result.diagnostics.add "nelua: cannot write '" & cfile & "': " & getCurrentExceptionMsg()
    result.success = false
    return
  cache.files[path] = cfile

proc compile*(source: string, path: string, config: Config = defaultConfig()): CompileResult =
  ## Compile a Nelua `source` (at `path`) through the full pipeline: resolve and
  ## recursively compile its `require` dependencies (caching their C), emit C
  ## via `genC`, write it to `tmp/<unitname>.c`, invoke `config.cc` to produce
  ## an executable in `tmp/`, and -- when `config.binary` -- run it and capture
  ## stdout.  Analyzer, dependency and C-compile diagnostics are returned in
  ## `CompileResult.diagnostics`.
  ##
  ## The embedded Lua preprocessor state is reset at the start of every
  ## compilation so that `##` globals do not leak between separate `compile()`
  ## calls in the same process; within one compilation the state is shared
  ## across `require`d dependencies (see `luaengine`).
  resetLuaState()
  var cache = newModuleCache()
  result = compileUnit(source, path, config, cache)
  if not result.success:
    return

  let unitname = analyzer.computeUnitname(path)
  let tdir = cacheDir()
  let cfile = tdir / unitname & ".c"

  # --print-assembly: emit the assembly for this translation unit to stdout and
  # stop.  This is the stdout form of -Y/--assembly (which writes the .s file):
  # run the same `gcc -S` step but with `-o -` so the assembly lands on stdout,
  # captured here rather than written to a file.  Short-circuits before the
  # outputKind switch and the binary-run step, matching the reference.
  if config.printAssembly:
    var asmCmd = config.cc & " -S -fverbose-asm -g0 " & cfile.quoteShell & " -o -"
    if config.cflags.len > 0:
      asmCmd.add " " & config.cflags
    let (asmOut, asmExit) = execCmdEx(asmCmd)
    result.exitCode = asmExit
    result.assemblySource = asmOut
    if asmExit != 0:
      result.diagnostics.add("nelua: assembly emission failed (cc=" & config.cc &
        ", exit=" & $asmExit & "):\n" & asmOut)
    return

  # Output path: -o overrides the destination for object/assembly/library
  # artifacts.  For a binary the artifact always lands in `tmp/<unitname>` (no
  # suffix) and main.nim copies it to the -o name: a binary must NOT be executed
  # when -o is given (the oracle builds but does not run), and the run step is
  # gated on `config.output.len == 0` below.
  let outExt = outputExtension(config.outputKind)
  let outPath =
    if config.outputKind == okBinary:
      tdir / unitname
    elif config.output.len > 0:
      config.output
    else:
      tdir / unitname & "." & outExt

  # The emitted TU is self-contained: every runtime helper it needs is emitted
  # as a `static` definition in its preamble (see cgen.genPreamble), so there is
  # no separate runtime.c to link and no `-lm` to pass.  The only math symbol
  # the runtime ever touched was `pow`, wrapped per-TU by `nlpow`; plain gcc
  # `pow` (via `nlpow`, the `^` operator) lives in libm.  Plain gcc does not
  # auto-link libm, so a TU that uses `^` needs `-lm` to resolve `pow`; the
  # oracle passes it for exactly this reason.  Non-math TUs need no libm at
  # all, so emit `-lm` only when the preamble actually pulled in <math.h>.
  # NOTE: the design doc claims `-lm` is a no-op here -- it is not.  Even the
  # oracle's own generated C fails to link `pow` at the default `-g` tier
  # without it; only release tiers fold `pow` away.  So `-lm` is kept, but
  # conditionally, matching the oracle's behaviour and keeping non-math
  # programs libm-free.
  let optFlags =
    if config.maxPerf:   " -fwrapv -fno-strict-aliasing -Ofast -march=native -DNDEBUG -fno-plt -flto=auto"
    elif config.release: " -fwrapv -fno-strict-aliasing -O2 -DNDEBUG"
    else:                " -fwrapv -fno-strict-aliasing -g"
  let asmExtra = if config.outputKind == okAssembly: " -fverbose-asm -g0 " else: ""
  var ccCmd: string
  case config.outputKind:
    of okBinary:
      ccCmd = config.cc & optFlags & " -o " & outPath.quoteShell & " " & cfile.quoteShell
    of okObject:
      ccCmd = config.cc & optFlags & " -c " & cfile.quoteShell & " -o " & outPath.quoteShell
    of okAssembly:
      ccCmd = config.cc & optFlags & " -S " & asmExtra & cfile.quoteShell & " -o " & outPath.quoteShell
    of okStaticLib:
      let obj = tdir / unitname & ".o"
      ccCmd = config.cc & optFlags & " -c " & cfile.quoteShell & " -o " & obj.quoteShell
    of okSharedLib:
      ccCmd = config.cc & optFlags & " -shared -fPIC -o " & outPath.quoteShell & " " & cfile.quoteShell
  # `-lm` only when the TU actually references a math helper (the preamble
  # emits `#include <math.h>` in that case).  Object / assembly / static-lib
  # steps do not link, so `-lm` is harmless noise there.
  if result.cSource.len > 0 and "#include <math.h>" in result.cSource:
    ccCmd.add " -lm"
  if config.cflags.len > 0:
    ccCmd.add " " & config.cflags
  # ldflags only make sense when linking (binary / shared lib); passing them
  # to -c/-S is noise.
  if config.ldflags.len > 0 and config.outputKind in {okBinary, okSharedLib}:
    ccCmd.add " " & config.ldflags

  # `-c --code` emits C and stops: no gcc, no strip, no run (matches the oracle).
  if not config.codeOnly:
    timing.markStart("compile")
    let (ccOut, ccExit) = execCmdEx(ccCmd)
    discard timing.markStop("compile")
    if config.verbose:
      echo ccCmd
    result.exitCode = ccExit
    if ccExit != 0:
      result.diagnostics.add("C compile failed (cc=" & config.cc & ", exit=" & $ccExit & "):\n" & ccOut)
      return

    # Static library: archive the object we just compiled.
    if config.outputKind == okStaticLib:
      let obj = tdir / unitname & ".o"
      let arCmd = "ar rcs " & outPath.quoteShell & " " & obj.quoteShell
      if config.verbose:
        echo arCmd
      let (arOut, arExit) = execCmdEx(arCmd)
      if arExit != 0:
        result.diagnostics.add("ar failed (exit=" & $arExit & "):\n" & arOut)
        result.exitCode = arExit
        return

    # `-s --strip-bin` strips the linked executable. Only meaningful for a
    # binary (the oracle never strips object/assembly/library artifacts).
    if config.stripBin and config.outputKind == okBinary:
      let stripCmd = "strip " & config.stripflags & " " & outPath.quoteShell
      if config.verbose:
        echo stripCmd
      let (stripOut, stripExit) = execCmdEx(stripCmd)
      if stripExit != 0:
        result.diagnostics.add("strip failed (exit=" & $stripExit & "):\n" & stripOut)
        result.exitCode = stripExit
        return

    # Flush the buffered `-t` stage group after gcc, before the program runs.
    timing.flushStages()

    # Only a binary is executed; object / assembly / library are artifacts.
    # `-o <name>` writes the artifact but does NOT run it (matches the oracle),
    # so the run is gated on `config.output.len == 0`.
    if config.outputKind == okBinary and config.binary and config.output.len == 0:
      if config.debug:
        # The oracle's `-V -d` reveals the actual GDB invocation: `set confirm
        # off` + `set breakpoint pending on` so an unresolved `break abort`
        # (normal programs never call abort) becomes a pending breakpoint
        # instead of a fatal error; `set print frame-info
        # source-and-location` for source/line frames; `bt` for the backtrace;
        # `quit` so gdb -batch returns 0 in all cases.
        let gdbCmd = config.gdb & " -q " &
                     "-ex \"set confirm off\" " &
                     "-ex \"set breakpoint pending on\" " &
                     "-ex \"set print frame-info source-and-location\" " &
                     "-ex \"set debuginfod enabled off\" " &
                     "-ex \"break abort\" -ex \"run\" -ex \"bt\" -ex \"quit\" " &
                     "--args " & outPath.quoteShell
        if config.verbose:
          echo gdbCmd
        let (gdbOut, gdbExit) = execCmdEx(gdbCmd)
        result.output = gdbOut
        # gdb -batch returns 0 even when the inferior aborts; the oracle always
        # exits 0 for -d.
        result.exitCode = gdbExit
      else:
        timing.markStart("run")
        # -R/--runner: run the compiled binary through `<runner>` instead of
        # executing it directly, passing any runargs after the binary path.
        let runCmd = if config.runner.len > 0:
                        config.runner & " " & outPath.quoteShell &
                        (if config.runargs.len > 0: " " & config.runargs.join(" ") else: "")
                      else:
                        outPath.quoteShell
        let (runOut, runExit) = execCmdEx(runCmd)
        result.runMs = timing.markStop("run")
        result.output = runOut
        # The oracle reports 255 when the compiled program is killed by a signal
        # (error/panic/assert all abort via SIGABRT).  On POSIX the shell reports
        # 128+N for signal N, so map any signal-death exit code (128..159) to 255
        # to match; normal exit codes (including high ones like os.exit(200))
        # are propagated unchanged.
        result.exitCode = if runExit >= 128 and runExit <= 159: 255 else: runExit
  else:
    timing.flushStages()

when isMainModule:
  let src = "print(1 + 2)\n"
  let res = compile(src, "test.nelua")

  echo "=== compile.nim self-test ==="
  echo "success    = ", res.success
  echo "cSourceLen = ", res.cSource.len
  echo "exitCode   = ", res.exitCode
  echo "output     = [", res.output, "]"
  echo "diagnostics (", res.diagnostics.len, "):"
  for d in res.diagnostics:
    for line in d.split("\n"):
      echo "  | " & line

  doAssert res.success, "genC must emit a real translation unit (not a diagnostic stub)"
  doAssert res.cSource.len > 0, "cSource must be non-empty"

  # Clean up the transient build artefacts the self-test wrote to the cache.
  let tdir = cacheDir()
  for f in [tdir / "test.c", tdir / "test"]:
    try:
      removeFile(f)
    except OSError:
      discard

  if res.exitCode == 0:
    echo "=== run output ==="
    echo res.output
  else:
    echo "=== produced executable failed to build/run (reported, not hidden) ==="
    echo "SELF-TEST RESULT: run NOT OK."