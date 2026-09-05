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
    printAssembly*: bool        ## --print-assembly: emit assembly to stdout
    runner*: string             ## -R/--runner: run <runner> <binary> <runargs>
    runargs*: seq[string]       ## trailing positionals passed to the runner
    loads*: seq[string]         ## --load mod[:as] preload Lua modules into the
                                ## embedded engine's global namespace
                                ## (--script/--lua); `g=mod` binds to global `g`
    eval*: bool                 ## -i/--eval: compile a string instead of a file
    evalCode*: string           ## the -i/--eval code string
    script*: bool               ## --script: run a .lua file instead of compiling
    luaRepl*: bool              ## --lua: interactive Lua REPL (embedded engine)
    version*: bool              ## --version
    help*: bool                 ## --help
    config*: bool               ## --config
    ## Diagnostics / build-tuning tier (from the diagnostics agent).
    maxPerf*: bool              ## -M --maximum-performance
    noWarning*: bool            ## --no-warning
    stripflags*: string = "-x"  ## --stripflags
    timing*: bool               ## -t --timing
    moreTiming*: bool           ## -T --more-timing
    debug*: bool                ## -d --debug
    gdb*: string = "gdb"        ## GDB binary for -d
    noColor*: bool              ## --no-color
    semver*: bool               ## --semver
    ## Path-tier fields, declared so `--config` can dump a complete key set.
    libPath*: string            ## --lib-path
    luaBin*: string             ## --lua
    luaCpath*: string           ## --lua-cpath
    luaPath*: string            ## --lua-path
    luaVersion*: string         ## --lua-version
    lualibPath*: string         ## --lualib-path
    outputDir*: string          ## --output-dir
    cliOrder*: seq[string]      ## order of version/semver/config/input tokens
    parseError*: string         ## non-empty when CLI parsing failed

  OutputKind* = enum
    okBinary      ## -b --binary (default): link an executable and run it
    okObject      ## -B --object: compile to a relocatable .o
    okAssembly    ## -Y --assembly: emit assembly .s
    okStaticLib   ## -A --static-lib: archive into a .a
    okSharedLib   ## -H --shared-lib: link into a .so

proc defaultConfig*: Config =
  ## The default configuration: gcc as the C compiler, binary output enabled.
  Config(cc: "gcc", generator: "c", binary: true,
    libPath: LibPath,
    luaBin: "/usr/bin/nelua-lua",
    luaVersion: LuaVersion,
    lualibPath: LualibPath,
    outputDir: "/home/user/.cache/nelua",
    cacheDir: "/home/user/.cache/nelua",
    luaCpath: LuaCPath,
    luaPath: LuaPath,
  )

proc hasError*(c: Config): bool =
  ## True when the config carries a CLI parsing error.
  c.parseError.len > 0

proc addPath*(c: var Config, p: string) =
  ## Set the --path entry (last-wins; replaces any previous --path value).
  c.paths = @[p]

proc addAddPath*(c: var Config, p: string) =
  ## Append a -L/--add-path directory (accumulating).
  c.addPath.add(p)

proc configJson*(c: Config): string =
  ## Dump the configuration as a JSON object, keyed by the oracle's `--config`
  ## names.  Config is a plain object, so this is a manual enumeration (no
  ## reflection, no external dependency).  NOTE: the oracle emits Lua-table
  ## syntax; ours emits JSON per the design doc -- a deliberate divergence,
  ## see diagnostics_flags_blueprint.md §5.
  proc j(s: string): string =
    ## Minimal JSON string escaper (no external dependency).
    result = "\""
    for ch in s:
      case ch
      of '\\': result.add "\\\\"
      of '"':  result.add "\\\""
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      else: result.add ch
    result.add "\""
  proc arr(s: seq[string]): string =
    result = "["
    for i, v in s:
      if i > 0: result.add ", "
      result.add j(v)
    result.add "]"
  result = "{\n"
  result.add "  \"add_path\": " & arr(c.addPath) & ",\n"
  result.add "  \"cache_dir\": " & j(c.cacheDir) & ",\n"
  result.add "  \"cc\": " & j(c.cc) & ",\n"
  result.add "  \"cflags\": " & j(c.cflags) & ",\n"
  result.add "  \"define\": " & arr(c.defines) & ",\n"
  result.add "  \"gdb\": " & j(c.gdb) & ",\n"
  result.add "  \"generator\": " & j(c.generator) & ",\n"
  result.add "  \"ldflags\": " & j(c.ldflags) & ",\n"
  result.add "  \"lib_path\": " & j(c.libPath) & ",\n"
  result.add "  \"lua\": " & j(c.luaBin) & ",\n"
  result.add "  \"lua_cpath\": " & j(c.luaCpath) & ",\n"
  result.add "  \"lua_path\": " & j(c.luaPath) & ",\n"
  result.add "  \"lua_version\": " & j(c.luaVersion) & ",\n"
  result.add "  \"lualib_path\": " & j(c.lualibPath) & ",\n"
  result.add "  \"output_dir\": " & j(c.outputDir) & ",\n"
  let path = if c.paths.len == 0: DefaultPath
              else:
                var p = c.paths[0]
                for i in 1 ..< c.paths.len:
                  p.add ";" & c.paths[i]
                p
  result.add "  \"path\": " & j(path) & ",\n"
  result.add "  \"pragma\": " & arr(c.pragmas) & ",\n"
  result.add "  \"pragmas\": " & arr(c.pragmas) & ",\n"
  result.add "  \"runargs\": " & arr(c.runargs) & ",\n"
  result.add "  \"stripflags\": " & j(c.stripflags) & "\n"
  result.add "}"