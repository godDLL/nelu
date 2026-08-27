## CLI entry point for the Nelua-in-Nim compiler.
##
## This module depends only on `cli` and `config` (it must not depend on
## `span`/`errors`, which are owned by the other agent). It reads the process
## command line, parses it, and dispatches on the resulting Config. The real
## compilation pipeline is wired in later milestones; for now the entry point
## handles `--help`/`--version` and otherwise returns quietly.

import std/os
import cli
import config

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
  ## Entry point. Returns the process exit code.
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
    # The error message was already written to stderr by the CLI layer.
    return 1
  # Real pipeline wiring comes in later milestones; nothing to print yet.
  discard positionals
  return 0

when isMainModule:
  quit(main())
