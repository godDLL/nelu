## Configuration object and defaults for the Nelua-in-Nim compiler.
##
## This module is dependency-free: it imports nothing from the standard
## library (and nothing from the rest of the compiler tree).

type
  Config* = object
    release*: bool              ## -r --release
    binary*: bool               ## -b --binary
    codeOnly*: bool             ## -c --code
    analyze*: bool              ## -a --analyze
    lint*: bool                 ## --lint
    printAst*: bool             ## --print-ast
    printAnalyzedAst*: bool     ## --print-analyzed-ast
    printPpcode*: bool          ## --print-ppcode
    printCode*: bool            ## --print-code
    pragmas*: seq[string]       ## -P entries
    defines*: seq[string]       ## -D entries
    cc*: string                 ## --cc
    cflags*: string             ## --cflags
    ldflags*: string            ## --ldflags
    paths*: seq[string]         ## --path entries
    output*: string             ## -o
    cacheDir*: string           ## --cache-dir
    stripBin*: bool             ## -s --strip-bin
    sanitize*: bool             ## --sanitize
    generator*: string          ## -g
    noCache*: bool              ## --no-cache
    verbose*: bool              ## -V -- verbose: echo generated C and cc command line
    outputKind*: OutputKind     ## which final artifact to produce
    version*: bool              ## --version
    help*: bool                 ## --help
    parseError*: string         ## non-empty when CLI parsing failed

  OutputKind* = enum
    okBinary      ## -b --binary (default): link an executable and run it
    okObject      ## -B --object: compile to a relocatable .o
    okAssembly    ## -Y --assembly: emit assembly .s
    okStaticLib   ## -A --static-lib: archive into a .a
    okSharedLib   ## -H --shared-lib: link into a .so

proc defaultConfig*: Config =
  ## The default configuration: gcc as the C compiler, binary output enabled.
  Config(cc: "gcc", binary: true)

proc hasError*(c: Config): bool =
  ## True when the config carries a CLI parsing error.
  c.parseError.len > 0

proc addPath*(c: var Config, p: string) =
  ## Append a module search path (--path) to the configuration.
  c.paths.add(p)