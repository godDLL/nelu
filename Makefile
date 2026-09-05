# Nelu build (clean-room Nelua-in-Nim).
#
# This is *our* Makefile, not the upstream one (preserved as Makefile.N200 for
# reference).  One artifact, one toolchain:
#
#   nelu      the Nelu compiler -- Nim -> C -> native.  This is the real
#            compiler; the upstream `nelua` was a shell wrapper around a Lua
#            interpreter, which we do not use.  Its embedded C Lua 5.4.3
#            engine (baked in via src/luaengine.nim's `{.compile:}`) provides
#            the two Lua access points `--script` (run a .lua file) and `--lua`
#            (interactive REPL), so there is no separate `nelua-lua` binary to
#            build -- `nelu` does all the things `nelua-lua` used to do.
#            The build artifact is `tmp/nelu` (renamed from `tmp/nelua` on
#            2026-09-06; historical docs that still name `tmp/nelua` refer to
#            the pre-rename binary).

NELU=nelu
# The compiler artifact the whole toolchain consumes.  Every gate script
# (plan/cmp.py, plan/regress.py, plan/examples_parity.py, plan/cover_gate.py,
# plan/cli_conformance.py, plan/wwwcheck.py) runs ROOT/tmp/nelu, so `make nelu`
# must build *here*, not at the repo root.  `nelu` is a phony marker over the
# real file so make skips the 40s Nim compile when tmp/nelu is current.
NELU_OUT=$(CURDIR)/tmp/nelu

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

###############################################################################
# The Nelu compiler (Nim).

NIM=nim
NIMCACHE?=$(CURDIR)/.cache/nim
NIMFLAGS=-d:release --path:src --nimcache:$(NIMCACHE) --passL:-s

.PHONY: $(NELU)
$(NELU): $(NELU_OUT)
	@mkdir -p $(CURDIR)/tmp

$(NELU_OUT): src/main.nim $(shell find src -name '*.nim' 2>/dev/null)
	@mkdir -p $(CURDIR)/tmp
	$(NIM) c $(NIMFLAGS) -o:$@ src/main.nim

###############################################################################
# Default + release.

.PHONY: all release
all: $(NELU)
release: $(NELU)

###############################################################################
# Testing.  The Lua spec suite (`spec/init.lua`) is pure Lua, so it runs through
# the embedded engine via `--script` -- no separate interpreter binary needed.

.PHONY: test test-quick
test: $(NELU)
	$(NELU_OUT) --script spec/init.lua

test-quick: $(NELU)
	@LESTER_QUIET=true LESTER_STOP_ON_FAIL=true $(NELU_OUT) --script spec/init.lua

###############################################################################
# Install.

PREFIX?=/usr/local
DPREFIX=$(DESTDIR)$(PREFIX)
PREFIX_BIN=$(DPREFIX)/bin
PREFIX_LIB=$(DPREFIX)/lib/nelua

.PHONY: install install-as-symlink uninstall
install: $(NELU)
	install -d "$(PREFIX_BIN)"
	install -m755 $(NELU_OUT) "$(PREFIX_BIN)/$(NELU)"
	install -d "$(PREFIX_LIB)"
	cp -R lualib "$(PREFIX_LIB)/lualib"
	cp -R lib "$(PREFIX_LIB)/lib"
	@echo "installed nelu to $(DPREFIX)"

uninstall:
	rm -f "$(PREFIX_BIN)/$(NELU)"
	rm -rf "$(PREFIX_LIB)"

###############################################################################
# Clean.

CACHE_DIR=$(CURDIR)/.cache

.PHONY: clean clean-nelu clean-cache
clean: clean-nelu clean-cache
clean-nelu:
	rm -f $(NELU_OUT) $(NELU)
clean-cache:
	rm -rf $(CACHE_DIR)