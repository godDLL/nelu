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

import std/[options, strutils, os, osproc]
import ./cgen
import ./config
import ./analyzer

type
  CompileResult* = object
    success*: bool              ## genC emitted a real translation unit (not a stub)
    cSource*: string            ## the emitted C translation unit
    diagnostics*: seq[string]   ## analyzer / C-compile diagnostics
    exitCode*: int              ## -1 if nothing ran; else the last step's exit code
    output*: string             ## captured run stdout; "" if nothing was run

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

proc compile*(source: string, path: string, config: Config = defaultConfig()): CompileResult =
  ## Compile a Nelua `source` (at `path`) through the full pipeline: emit C via
  ## `genC`, write it to `tmp/<unitname>.c`, invoke `config.cc` to produce an
  ## executable in `tmp/`, and -- when `config.binary` -- run it and capture
  ## stdout.  Analyzer and C-compile diagnostics are returned in
  ## `CompileResult.diagnostics`.
  let cSource = genC(source, path, config.release, false)
  result.cSource = cSource
  result.exitCode = -1
  result.success = cSource.len > 0 and not cSource.startsWith("/* nelua")
  if not result.success:
    result.diagnostics.add("nelua: unable to analyze " & path & ":\n" & cSource.strip())
    return

  let unitname = computeUnitname(path)
  let tdir = tmpDir()
  let cfile = tdir / unitname & ".c"
  let bin = tdir / unitname
  writeFile(cfile, cSource)

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