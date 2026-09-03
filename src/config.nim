## Configuration object and defaults for the Nelua-in-Nim compiler.
##
## This module is dependency-free: it imports nothing from the standard
## library (and nothing from the rest of the compiler tree).

const
  LibPath*     = "/usr/lib/nelua/lib"              ## system module lib dir
  LualibPath*  = "/usr/lib/nelua/lualib"          ## system lua lib dir
  LuaVersion*  = "5.4"                            ## embedded lua version
  LuaPath*     = "/usr/lib/nelua/lualib/?.lua;/usr/lib/nelua/lualib/nelua/thirdparty/?.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;/usr/share/lua/5.4/?.lua;/usr/share/lua/5.4/?/init.lua;/usr/local/lib/lua/5.4/?.lua;/usr/local/lib/lua/5.4/?/init.lua;/usr/lib/lua/5.4/?.lua;/usr/lib/lua/5.4/?/init.lua;./?.lua;./?/init.lua"
  LuaCPath*    = "/usr/local/lib/lua/5.4/?.so;/usr/local/lib/lua/5.4/loadall.so;./?.so;/usr/lib/lua/5.4/?.so;/usr/lib/lua/5.4/loadall.so;./?.so;"
  DefaultPath* = "./?.nelua;./?/init.nelua;" & LibPath & "/?.nelua;" & LibPath & "/?/init.nelua"

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
    paths*: seq[string]         ## --path entries (last-wins; empty = use default)
    addPath*: seq[string]       ## -L/--add-path entries (accumulating; default {})
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
    config*: bool               ## --config
    parseError*: string         ## non-empty when CLI parsing failed

  OutputKind* = enum
    okBinary      ## -b --binary (default): link an executable and run it
    okObject      ## -B --object: compile to a relocatable .o
    okAssembly    ## -Y --assembly: emit assembly .s
    okStaticLib   ## -A --static-lib: archive into a .a
    okSharedLib   ## -H --shared-lib: link into a .so

proc defaultConfig*: Config =
  ## The default configuration: gcc as the C compiler, binary output enabled.
  Config(cc: "gcc", generator: "c", binary: true)

proc hasError*(c: Config): bool =
  ## True when the config carries a CLI parsing error.
  c.parseError.len > 0

proc addPath*(c: var Config, p: string) =
  ## Set the --path entry (last-wins; replaces any previous --path value).
  c.paths = @[p]

proc addAddPath*(c: var Config, p: string) =
  ## Append a -L/--add-path directory (accumulating).
  c.addPath.add(p)