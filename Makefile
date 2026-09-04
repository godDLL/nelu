# Nelu build (clean-room Nelua-in-Nim).
#
# This is *our* Makefile, not the upstream one (preserved as Makefile.N200 for
# reference).  Two artifacts, two toolchains:
#
#   nelu      the Nelu compiler -- Nim -> C -> native.  This is the real
#            compiler; the upstream `nelua` was a shell wrapper around a Lua
#            interpreter, which we do not use.
#   nelu-lua  the bundled Lua 5.4.3 interpreter, built from C exactly as the
#            upstream `nelua-lua` is (onelua.c + the Nelua init layer + the
#            lpeglabel module).  Kept as a standalone interpreter for running
#            Lua scripts and the spec suite.
#
# Naming follows the upstream convention (`nelua` / `nelua-lua`) with the Nelu
# `u` substituted for the second `a`.

NELU=nelu
NELUALUA=nelu-lua
NELU_RUN=./$(NELU)

###############################################################################
# Platform detection (mirrors Makefile.N200, which is the reference).

DEVNULL=/dev/null
ifeq ($(OS), Windows_NT)
	SYS=Windows
	ifeq ($(wildcard /dev/null),)
		DEVNULL=NUL
	endif
	ifeq (, $(shell where which 2>$(DEVNULL)))
		WINMODE=1
	endif
else
	SYS=$(shell uname -s)
endif

LUA_CC=gcc
LUA_CFLAGS=-O2
LUA_DEFS=-DNDEBUG -DLUA_COMPAT_5_3 -DMAXRECLEVEL=400
LUA_INCS=-Isrc/lua
LUA_SRCS=src/lua/onelua.c $(wildcard src/*.c) $(wildcard src/lpeglabel/*.c)
LUA_LIBS=-lm -ldl

ifeq ($(SYS), Linux)
	LUA_CFLAGS=-O2 -fno-plt -flto
	LUA_LDFLAGS+=-Wl,-E
else ifeq ($(SYS), Darwin)
	LUA_CC=clang
	LUA_LDFLAGS+=-rdynamic
endif

###############################################################################
# The Nelu compiler (Nim).

NIM=nim
NIMCACHE?=$(CURDIR)/.cache/nim
NIMFLAGS=-d:release --path:src --nimcache:$(NIMCACHE)

$(NELU): src/main.nim $(shell find src -name '*.nim' 2>/dev/null)
	$(NIM) c $(NIMFLAGS) -o:$@ src/main.nim

###############################################################################
# The bundled Lua interpreter (C).

$(NELUALUA): $(LUA_SRCS) $(wildcard src/*.h) $(wildcard src/lua/*.h) $(wildcard src/lpeglabel/*.h)
	$(LUA_CC) $(LUA_DEFS) $(LUA_INCS) $(LUA_CFLAGS) $(LUA_SRCS) \
		-o $@ $(LUA_LDFLAGS) $(LUA_LIBS)

###############################################################################
# Default + release.

.PHONY: all release
all: $(NELU) $(NELUALUA)
release: $(NELU) $(NELUALUA)

###############################################################################
# Testing.

LUA=./$(NELUALUA)

.PHONY: test test-quick
test: $(NELUALUA)
	$(LUA) spec/init.lua

test-quick: $(NELUALUA)
	@LESTER_QUIET=true LESTER_STOP_ON_FAIL=true $(LUA) spec/init.lua

###############################################################################
# Install.

PREFIX?=/usr/local
DPREFIX=$(DESTDIR)$(PREFIX)
PREFIX_BIN=$(DPREFIX)/bin
PREFIX_LIB=$(DPREFIX)/lib/nelua

.PHONY: install install-as-symlink uninstall
install: $(NELU) $(NELUALUA)
	install -d "$(PREFIX_BIN)"
	install -m755 $(NELU) "$(PREFIX_BIN)/$(NELU)"
	install -m755 $(NELUALUA) "$(PREFIX_BIN)/$(NELUALUA)"
	install -d "$(PREFIX_LIB)"
	cp -R lualib "$(PREFIX_LIB)/lualib"
	cp -R lib "$(PREFIX_LIB)/lib"
	@echo "installed nelu + nelu-lua to $(DPREFIX)"

uninstall:
	rm -f "$(PREFIX_BIN)/$(NELU)" "$(PREFIX_BIN)/$(NELUALUA)"
	rm -rf "$(PREFIX_LIB)"

###############################################################################
# Clean.

CACHE_DIR=$(CURDIR)/.cache

.PHONY: clean clean-nelu clean-nelu-lua clean-cache
clean: clean-nelu clean-nelu-lua clean-cache
clean-nelu:
	rm -f $(NELU)
clean-nelu-lua:
	rm -f $(NELUALUA)
clean-cache:
	rm -rf $(CACHE_DIR)