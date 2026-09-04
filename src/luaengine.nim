## Embedded Lua 5.x interpreter for the M6 preprocessor (`##` blocks).
##
## This module compiles Nelua's bundled Lua C sources (`src/lua/*`) plus the
## Nelua init layer (`src/luainit.c`) into the compiler binary and exposes the
## small slice of the C API the preprocessor needs:
##
##   * create a state, open the standard libraries, run `luainit.lua` at
##     startup (it patches `package.path` so nelua lua files are findable);
##   * execute `##` blocks as Lua chunks in a state that persists across blocks
##     and across `require`d modules within one compilation.
##
## The state is a module-global so that `##` definitions made while compiling
## a `require`d dependency (e.g. `## function def_c() ... end` in
## `tests/require_test_dep.nelua`) are visible to the requiring module's own
## `##` blocks (e.g. `## def_c()` in `tests/require_test.nelua`), exactly as the
## reference interpreter does.  `resetLuaState()` at the top of `compile()`
## isolates each compilation.

import std/[options, strutils, os, streams]

# ---------------------------------------------------------------------------
# Compile the bundled Lua C sources + the Nelua init layer into this binary.
# `{.compile:}` paths are resolved by Nim relative to the project root (the
# cwd at compile time), so they are `src/...` paths.  `linit.c` provides
# `luaL_openlibs`, which registers every library listed in its `loadedlibs`
# table -- so all of lfs/sys/hasher/lpeglabel must be compiled too.  `lua.c`
# (the standalone interpreter) and `luac.c` are intentionally excluded: we
# only need the embedded engine.
# ---------------------------------------------------------------------------
# The Lua C sources are split across `src/lua/` and `src/lpeglabel/`, and the
# lpeglabel files `#include "lua.h"`/`"lauxlib.h"` which live in `src/lua/`.
# `#include "..."` (quotes) only searches the including file's own directory,
# so the compiler needs `-Isrc/lua` to find the core headers.
{.passC: "-Isrc/lua".}
{.compile: "src/lua/lapi.c".}
{.compile: "src/lua/lauxlib.c".}
{.compile: "src/lua/lbaselib.c".}
{.compile: "src/lua/lcode.c".}
{.compile: "src/lua/ldebug.c".}
{.compile: "src/lua/ldo.c".}
{.compile: "src/lua/ldump.c".}
{.compile: "src/lua/lfunc.c".}
{.compile: "src/lua/lgc.c".}
{.compile: "src/lua/lctype.c".}
{.compile: "src/lua/llex.c".}
{.compile: "src/lua/lmem.c".}
{.compile: "src/lua/loadlib.c".}
{.compile: "src/lua/lobject.c".}
{.compile: "src/lua/lopcodes.c".}
{.compile: "src/lua/lparser.c".}
{.compile: "src/lua/lstate.c".}
{.compile: "src/lua/lstring.c".}
{.compile: "src/lua/ltable.c".}
{.compile: "src/lua/ltm.c".}
{.compile: "src/lua/lundump.c".}
{.compile: "src/lua/lvm.c".}
{.compile: "src/lua/lzio.c".}
{.compile: "src/lua/lcorolib.c".}
{.compile: "src/lua/liolib.c".}
{.compile: "src/lua/loslib.c".}
{.compile: "src/lua/lmathlib.c".}
{.compile: "src/lua/lstrlib.c".}
{.compile: "src/lua/ltablib.c".}
{.compile: "src/lua/lutf8lib.c".}
{.compile: "src/lua/ldblib.c".}
{.compile: "src/lua/linit.c".}
{.compile: "src/lpeglabel/lpcap.c".}
{.compile: "src/lpeglabel/lpcode.c".}
{.compile: "src/lpeglabel/lpprint.c".}
{.compile: "src/lpeglabel/lptree.c".}
{.compile: "src/lpeglabel/lpvm.c".}
{.compile: "src/lfs.c".}
{.compile: "src/sys.c".}
{.compile: "src/hasher.c".}
{.compile: "src/luainit.c".}

# ---------------------------------------------------------------------------
# FFI to the Lua C API.
#
# `lua_State` is an opaque handle: we declare it as an empty Nim object and
# only ever pass `ptr lua_State` around, never dereference it.  Every access
## goes through a C API function, so the layout is irrelevant; the pointer is
## ABI-compatible with the C `lua_State*`.
# ---------------------------------------------------------------------------
type
  LuaState* = object
  PLuaState* = ptr LuaState
  lua_KContext* = int              ## matches C `lua_KContext` (uintptr_t)
  lua_KFunction* = pointer         ## matches C `lua_KFunction`

const LUA_OK* = 0
const LUA_ERRRUN* = 2
const LUA_ERRMEM* = 3

# Stack manipulation / type queries.  NOTE: `lua_tostring` and `lua_pop` are
# *macros* in lua.h (expanding to `lua_tolstring` / `lua_settop`), so they are
# declared here as the underlying functions they map to.
proc lua_gettop*(L: PLuaState): int {.importc: "lua_gettop".}
proc lua_settop*(L: PLuaState, idx: int) {.importc: "lua_settop".}
# `lua_pop` is a macro in lua.h (`lua_settop(L, -(n)-1)`), so it cannot be
# imported directly -- implement it as a Nim wrapper over the real function.
proc lua_pop*(L: PLuaState, n: int) =
  L.lua_settop(-n - 1)
proc lua_type*(L: PLuaState, idx: int): int {.importc: "lua_type".}
proc lua_tolstring*(L: PLuaState, idx: int, len: ptr csize_t): cstring {.importc: "lua_tolstring".}
proc lua_close*(L: PLuaState) {.importc: "lua_close".}

# State creation / libraries
proc luaL_newstate*(): PLuaState {.importc: "luaL_newstate".}
proc luaL_openlibs*(L: PLuaState) {.importc: "luaL_openlibs".}
proc lua_luainit*(L: PLuaState) {.importc: "lua_luainit".}

# Loading and calling
proc luaL_loadbufferx*(L: PLuaState, buff: cstring, sz: csize_t,
                       name: cstring, mode: cstring): int {.importc: "luaL_loadbufferx".}
proc lua_pcallk*(L: PLuaState, nargs: int, nresults: int, errfunc: int,
                 kctx: lua_KContext, kfunc: lua_KFunction): int {.importc: "lua_pcallk".}

# Global variable access / stack pushing
proc lua_getglobal*(L: PLuaState, name: cstring) {.importc: "lua_getglobal".}
proc lua_setglobal*(L: PLuaState, name: cstring) {.importc: "lua_setglobal".}
proc lua_pushstring*(L: PLuaState, s: cstring) {.importc: "lua_pushstring".}
proc lua_pushnumber*(L: PLuaState, n: cdouble) {.importc: "lua_pushnumber".}
proc lua_createtable*(L: PLuaState, narr: int, nrec: int) {.importc: "lua_createtable".}
proc lua_setfield*(L: PLuaState, idx: int, name: cstring) {.importc: "lua_setfield".}
proc lua_rawseti*(L: PLuaState, idx: int, n: int) {.importc: "lua_rawseti".}
proc lua_rawgeti*(L: PLuaState, idx: int, n: int) {.importc: "lua_rawgeti".}
proc lua_rawlen*(L: PLuaState, idx: int): int {.importc: "lua_rawlen".}
proc lua_absidx*(L: PLuaState, idx: int): int {.importc: "lua_absindex".}
proc lua_getfield*(L: PLuaState, idx: int, name: cstring) {.importc: "lua_getfield".}
proc lua_setmetatable*(L: PLuaState, idx: int) {.importc: "lua_setmetatable".}
proc lua_pushvalue*(L: PLuaState, idx: int) {.importc: "lua_pushvalue".}
proc lua_isinteger*(L: PLuaState, idx: int): int {.importc: "lua_isinteger".}
proc lua_tonumberx*(L: PLuaState, idx: int, isnum: ptr cint): cdouble {.importc: "lua_tonumberx".}
proc lua_touserdata*(L: PLuaState, idx: int): pointer {.importc: "lua_touserdata".}
proc lua_pushlightuserdata*(L: PLuaState, p: pointer) {.importc: "lua_pushlightuserdata".}

const LUA_MULTIPLE* = -1
const LUA_TNIL* = 0
const LUA_TBOOLEAN* = 1
const LUA_TLIGHTUSERDATA* = 2
const LUA_TNUMBER* = 3
const LUA_TSTRING* = 4
const LUA_TTABLE* = 5
const LUA_TFUNCTION* = 6

# C callbacks and stack queries used by the preprocessor builtins.
#
# `lua_CFunction` mirrors the C `int (*)(lua_State *)`.  It carries no `gcsafe`
# annotation: real Lua C callbacks are not GC-safe (they may call `lua_error`
# which longjmps out of the C frame), and the preprocessor builtins touch
# module-global scratch buffers holding GC'd `Node` refs.  Requiring `gcsafe`
# here would force every builtin into `{.noGC.}` contortions; the callbacks
# themselves are well-behaved -- they only run inside `lua_pcallk`, never
# capture Nim references, and the globals they touch are alive for the whole
# compilation.
type
  lua_CFunction* = proc (L: PLuaState): int {.cdecl.}

# `lua_pushcfunction` and `lua_tointeger` are *macros* in lua.h (they expand to
# `lua_pushcclosure(L,(f),0)` and `lua_tointegerx(L,(i),NULL)` respectively), so
# their `importc` names would not resolve at link time -- the Nim-generated C
# declares the literal symbol, which the Lua build does not export.  Import the
# underlying real functions instead.
proc lua_pushcfunction*(L: PLuaState, fn: lua_CFunction, n: int = 0) {.importc: "lua_pushcclosure".}
proc lua_pushboolean*(L: PLuaState, b: int) {.importc: "lua_pushboolean".}
proc lua_pushinteger*(L: PLuaState, n: int64) {.importc: "lua_pushinteger".}
proc lua_toboolean*(L: PLuaState, idx: int): int {.importc: "lua_toboolean".}
proc lua_tointegerx*(L: PLuaState, idx: int, isnum: ptr cint): int64 {.importc: "lua_tointegerx".}
proc lua_error*(L: PLuaState): int {.importc: "lua_error".}
proc luaL_error*(L: PLuaState, fmt: cstring): int {.importc: "luaL_error".}

# ---------------------------------------------------------------------------
# High-level engine handle.
# ---------------------------------------------------------------------------
type
  LuaEngine* = object
    state*: PLuaState

## Callback invoked with the freshly-created Lua state of every new engine,
## so the preprocessor module can register its compile-time builtins
## (`hygienize`, `static_assert`, `inject`, ...) exactly once per state.  Set
## by `preprocessor.nim` at module init.
var onNewEngine*: proc(L: PLuaState) = nil

## Callback invoked when the shared Lua state is reset (i.e. at the start of
## every compilation), so the preprocessor module can clear its per-state
## scratch buffers (`gCapturedBodies`, `gInjectStack`, the builtins flag).
## Set by `preprocessor.nim` at module init.
var onResetEngine*: proc() = nil

proc newLuaEngine*(inputPath = ""): LuaEngine =
  ## Create a fresh Lua state, open the standard libraries, run `luainit.lua`
  ## (which adjusts `package.path`), and seed the global `arg` table so that
  ## `luainit`'s `fs.findluabin()` does not error on a nil `arg[0]`.
  let L = luaL_newstate()
  if L == nil:
    raise newException(IOError, "luaL_newstate() returned nil")
  luaL_openlibs(L)

  # Seed the global `arg` table to mirror what the reference interpreter
  # exposes: arg[0] = "nelua.lua", arg[1] = the input source path,
  # arg[-1] = "-lnelua", arg[-2] = the nelua-lua driver path.  `luainit.lua`
  # reads `arg[0]` to locate the executable and is robust to a missing lualib
  # directory (it simply leaves package.path untouched), but it errors if
  # `arg[0]` is nil, so it must be seeded.
  lua_createtable(L, 0, 4)
  lua_pushstring(L, "nelua.lua")
  lua_rawseti(L, -2, 0)              # arg[0]
  if inputPath.len > 0:
    lua_pushstring(L, inputPath)
    lua_rawseti(L, -2, 1)            # arg[1]
  lua_pushstring(L, "-lnelua")
  lua_rawseti(L, -2, -1)             # arg[-1]
  lua_pushstring(L, "nelua.lua")
  lua_rawseti(L, -2, -2)             # arg[-2]
  lua_setglobal(L, "arg")

  lua_luainit(L)
  if onNewEngine != nil:
    onNewEngine(L)
  result.state = L

proc runChunk*(L: PLuaState, text: string, chunkName: string): string =
  ## Load and execute `text` as a Lua chunk in `L`.  Returns "" on success; on
  ## failure returns the Lua error message (with the stack popped).
  let loadRes = luaL_loadbufferx(L, text.cstring, text.len.csize_t,
                                chunkName.cstring, "t")
  if loadRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)               # pop the error string
    return if msg.len > 0: msg else: "lua load error (code " & $loadRes & ")"
  let pcRes = lua_pcallk(L, 0, 0, 0, 0, nil)
  if pcRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)               # pop the error string
    return if msg.len > 0: msg else: "lua run error (code " & $pcRes & ")"
  return ""

proc runChunkGetResult*(L: PLuaState, text: string, chunkName: string): (string, int) =
  ## Load and run `text` as a Lua chunk in `L`.  Returns `(errorMessage, nresults)`.
  ## On success `errorMessage == ""` and the `nresults` return values are left on
  ## the top of the stack (caller must read/pop them).  On failure the stack is
  ## popped, `nresults == 0`, and `errorMessage` holds the Lua message.
  let loadRes = luaL_loadbufferx(L, text.cstring, text.len.csize_t,
                                chunkName.cstring, "t")
  if loadRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)               # pop the error string
    return ((if msg.len > 0: msg else: "lua load error (code " & $loadRes & ")"), 0)
  let pcRes = lua_pcallk(L, 0, LUA_MULTIPLE, 0, 0, nil)
  if pcRes != LUA_OK:
    var msg = ""
    if lua_gettop(L) > 0:
      let s = lua_tolstring(L, -1, nil)
      msg = if s != nil: $s else: "lua error (no message)"
      lua_settop(L, -2)               # pop the error string
    return ((if msg.len > 0: msg else: "lua run error (code " & $pcRes & ")"), 0)
  let n = lua_gettop(L)
  return ("", n)

proc close*(e: var LuaEngine) =
  if e.state != nil:
    lua_close(e.state)
    e.state = nil

# ---------------------------------------------------------------------------
# Module-global state, shared across all `preprocess` calls in this process.
# `resetLuaState()` is called from `compile()` so each compilation starts
# clean; within one compilation the state is shared across `require`d
# dependencies, matching the reference interpreter.
# ---------------------------------------------------------------------------
var gEngine: LuaEngine
var gEngineReady = false

proc resetLuaState*() =
  ## Close the shared Lua state if one exists.  The next `##` block lazily
  ## recreates it via `getLuaEngine`.
  if onResetEngine != nil:
    onResetEngine()
  if gEngineReady:
    close(gEngine)
    gEngineReady = false

proc getLuaEngine*(inputPath = ""): PLuaState =
  ## Return the shared Lua state, creating it (with `luainit` run) on first use
  ## within the current compilation.
  if not gEngineReady:
    gEngine = newLuaEngine(inputPath)
    gEngineReady = true
  result = gEngine.state

proc runScript*(path: string): (string, int) =
  ## Run a `.lua` file (`-` = stdin) as a plain Lua script for the `--script`
  ## flag -- the pure-Lua path that bypasses the nelua compiler entirely.
  ##
  ## Returns (errorMessage, exitCode).  The script's own stdout flows to the
  ## process stdout directly (Lua's `print` writes to stdout), so only the
  ## diagnostic and the exit code are returned from here.
  ##
  ## `os.exit` is intercepted.  The reference runs `--script` in a separate
  ## `nelua-lua` process, so its `os.exit(N)` only kills that child and the
  ## wrapper propagates N.  We emulate the propagation without terminating our
  ## own process: `os.exit(N)` is rewritten to raise an error carrying the code,
  ## which `runChunk` surfaces as a message we parse here.
  var text: string
  if path == "-":
    text = readAll(stdin)
  else:
    try:
      text = readFile(path)
    except OSError, IOError:
      return ("nelua: --script: cannot read '" & path & "': " &
              getCurrentExceptionMsg(), 1)

  let L = getLuaEngine(path)

  # Install the os.exit interceptor.  Must run before the script chunk.
  let hookErr = runChunk(L,
    "local _nelua_old_exit = os.exit\n" &
    "os.exit = function(code) error('NELUA_EXIT:' .. tostring(code or 0)) end",
    "nelua:script:os.exit")
  if hookErr.len > 0:
    return ("nelua: --script: failed to install os.exit hook: " & hookErr, 1)

  let err = runChunk(L, text, path)
  if err.len > 0:
    # `os.exit(N)` is rewritten to `error('NELUA_EXIT:' .. tostring(N))`.  Lua
    # prefixes the raised error with the location it was raised from (e.g.
    # `[string "nelua:script:os.exit"]:2: NELUA_EXIT:7`), so the marker is not
    # at the start of the message -- locate it anywhere and parse the code that
    # follows it.
    let marker = "NELUA_EXIT:"
    let pos = err.find(marker)
    if pos >= 0:
      let codeStr = err[pos + marker.len ..< err.len]
      try:
        return ("", parseInt(codeStr))
      except ValueError:
        discard
    return (err, 1)
  return ("", 0)