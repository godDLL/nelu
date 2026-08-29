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
  ## Collect the module names of every top-level `require 'name'` statement.
  ## `require` lowers to a call on the builtin `require` (see parser.nim), so we
  ## look for `nkCall` nodes whose caller is the `require` identifier and whose
  ## single argument is a string literal.
  if ast == nil:
    return
  for c in ast.children:
    if c.kind == nkCall and c.children.len == 2 and
       c.children[1].kind == nkId and c.children[1].str == "require" and
       c.children[0].kind == nkString:
      result.add c.children[0].str

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

  let ast = parser.parse(source, path)
  if ast != nil:
    for modname in findRequires(ast):
      let depPath = resolveModule(modname, config, path)
      if depPath == "":
        result.diagnostics.add "require '" & modname & "': module not found"
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

  let cSource = genC(source, path, config.release, false)
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
  let bin = tdir / unitname

  # The emitted TU only *declares* the runtime (struct nltype, nelua_print, ...);
  # their definitions live in `src/runtime.c`, which must be linked in or every
  # program fails to link.  Resolved at compile time so it is correct from any cwd.
  const runtimeC = currentSourcePath().splitFile().dir / "runtime.c"
  var ccCmd = config.cc & " -o " & bin.quoteShell & " " & cfile.quoteShell & " " & runtimeC.quoteShell & " -lm"
  if config.cflags.len > 0:
    ccCmd.add " " & config.cflags
  if config.ldflags.len > 0:
    ccCmd.add " " & config.ldflags

  let (ccOut, ccExit) = execCmdEx(ccCmd)
  result.exitCode = ccExit
  if ccExit != 0:
    result.diagnostics.add("C compile failed (cc=" & config.cc & ", exit=" & $ccExit & "):\n" & ccOut)
    return

  if config.binary:
    let (runOut, runExit) = execCmdEx(bin.quoteShell)
    result.output = runOut
    result.exitCode = runExit

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