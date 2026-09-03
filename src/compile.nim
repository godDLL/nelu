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

import std/[options, strutils, os, osproc, tables]
import ./cgen
import ./config
import ./analyzer
import ./parser
import ./ast
import ./luaengine

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

  ModuleCache* = object
    ## Per-`compile()` invocation cache of resolved module path -> cached C
    ## file.  An empty string value marks a module currently being compiled
    ## (cycle break); a non-empty value is the on-disk `.c` file.
    files*: Table[string, string]

proc newModuleCache*: ModuleCache =
  ModuleCache(files: initTable[string, string]())

proc tmpDir(): string =
  ## Locate (creating if needed) the project's scratch `tmp/` directory.
  ## Never `/tmp`; always under the project tree.
  for base in [getCurrentDir(), getAppDir().parentDir()]:
    let d = base / "tmp"
    if dirExists(d):
      return d
  let d = getCurrentDir() / "tmp"
  createDir(d)
  return d

proc resolveModule*(name: string, config: Config, requiringPath: string): string =
  ## Resolve a required module name to an absolute `.nelua` file path.
  ##
  ## Module names use `.` as a path separator (`require 'allocators.general'`
  ## -> `lib/allocators/general.nelua`).  A leading `.` segment means "the
  ## directory of the file doing the requiring" (so `require '.foo'` from
  ## `tests/a.nelua` finds `tests/foo.nelua`).  Search order: `--path`
  ## entries, then the project `lib/` dir, then the requiring file's own
  ## directory, then the current working directory.  Returns "" when no
  ## candidate exists.
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
  for p in config.paths:
    candidates.add p / segments.join("/") & ".nelua"
  candidates.add getCurrentDir() / "lib" / segments.join("/") & ".nelua"
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

  let ast = parser.parse(source, path)
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

  let cSource = genC(source, path, config.release, false, config)
  result.cSource = cSource
  result.success = cSource.len > 0 and not cSource.startsWith("/* nelua")
  if not result.success:
    result.diagnostics.add "nelua: unable to analyze " & path & ":\n" & cSource.strip()
    return

  let unitname = analyzer.computeUnitname(path)
  let tdir = tmpDir()
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
  let tdir = tmpDir()
  let cfile = tdir / unitname & ".c"

  # Output path: -o overrides the destination, otherwise a per-mode default
  # under tmp/.  The oracle writes every artifact to its cache dir and only
  # honours -o as the final artifact path; we do the same from our tmp/.
  let outExt = outputExtension(config.outputKind)
  let outPath = if config.output.len > 0: config.output
                else: tdir / unitname & "." & outExt

  # The emitted TU only *declares* the runtime (struct nltype, nelua_print, ...);
  # their definitions live in `src/runtime.c`, which must be linked in or every
  # program fails to link.  Resolved at compile time so it is correct from any cwd.
  const runtimeC = currentSourcePath().splitFile().dir / "runtime.c"
  var ccCmd: string
  case config.outputKind:
    of okBinary:
      ccCmd = config.cc & " -o " & outPath.quoteShell & " " & cfile.quoteShell & " " & runtimeC.quoteShell & " -lm"
    of okObject:
      ccCmd = config.cc & " -c " & cfile.quoteShell & " -o " & outPath.quoteShell
    of okAssembly:
      ccCmd = config.cc & " -S " & cfile.quoteShell & " -o " & outPath.quoteShell
    of okStaticLib:
      let obj = tdir / unitname & ".o"
      ccCmd = config.cc & " -c " & cfile.quoteShell & " -o " & obj.quoteShell
    of okSharedLib:
      ccCmd = config.cc & " -shared -fPIC -o " & outPath.quoteShell & " " & cfile.quoteShell
  if config.cflags.len > 0:
    ccCmd.add " " & config.cflags
  # ldflags only make sense when linking (binary / shared lib); passing them
  # to -c/-S is noise.
  if config.ldflags.len > 0 and config.outputKind in {okBinary, okSharedLib}:
    ccCmd.add " " & config.ldflags

  let (ccOut, ccExit) = execCmdEx(ccCmd)
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

  # Only a binary is executed; object / assembly / library are artifacts.
  if config.outputKind == okBinary and config.binary:
    let (runOut, runExit) = execCmdEx(outPath.quoteShell)
    result.output = runOut
    # The oracle reports 255 when the compiled program is killed by a signal
    # (error/panic/assert all abort via SIGABRT).  On POSIX the shell reports
    # 128+N for signal N, so map any signal-death exit code (128..159) to 255
    # to match; normal exit codes (including high ones like os.exit(200))
    # are propagated unchanged.
    result.exitCode = if runExit >= 128 and runExit <= 159: 255 else: runExit

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

  # Clean up the transient build artefacts we created in tmp/ (scratch dir).
  let tdir = tmpDir()
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