# Missing oracle CLI flags — SUPERSEDED 2026-09-03

Status: **STALE.** Do not use this document as a work list. It was accurate before
the CLI flag conformance pass (agent `aae1cbdbf29400960`, 864 dump + 200 build/run
runs) and is now almost entirely wrong: nearly every flag it lists as missing is
implemented and verified, including byte-identical `--config`.

**Single source of truth for CLI gaps: the "CLI conformance task queue" section of
`NOTE_backlog.md`**, and the harness `plan/cli_conformance.py` (committed `fabea4e`).
That queue is the current work list. This file is kept for history only.

## What this document got wrong

Section 2 (output/execution) and section 3 (build/diagnostics) are obsolete.
Every flag they list as missing is implemented:

| Flag | Status now |
|---|---|
| `--print-assembly` | implemented (`src/main.nim:315`, `src/compile.nim:243-257`) |
| `-R` / `--runner` | implemented (`src/main.nim:222-228`) |
| `--script` | implemented (`src/main.nim:193-200`) |
| `-i` / `--eval` | implemented (`src/main.nim:208-216`) |
| `-t` / `--timing` | implemented (`src/main.nim:140-143`) |
| `-T` / `--more-timing` | implemented but **no-op** (queue item #3) |
| `-M` / `--maximum-performance` | implemented (`src/cli.nim:117,153`; `src/compile.nim:201`) |
| `-w` / `--no-warning` | implemented hook (`src/cli.nim:115,150`) |
| `--no-color` | implemented hook (`src/cli.nim:151`) |
| `--stripflags` | implemented (`src/cli.nim:156`) |
| `-d` / `--debug` | implemented (`src/cli.nim:116,152`) |
| `--config` | implemented, **byte-identical to the oracle** (`src/main.nim:82-128`) |
| `--semver` | implemented (`src/main.nim:176-178`) |
| `--define` / `--pragma` | implemented (`src/cli.nim:185-186`) |
| `-L` / `--add-path` | implemented (`src/cli.nim:133-137,173-177`) |

Section 1 (path tier) is partly stale too: `-L`/`--add-path` and the accumulating
`add_path` list are done. What remains of section 1 is the **system-lib default
search path** (`/usr/lib/nelua/lib`), which is not a CLI flag gap at all — it is
the stdlib-reachability takeover blocker driven by the `##` splice gap in
`lib/detail/xoshiro256.nelua`, tracked separately in `NOTE_backlog.md`.

## What is genuinely still open (as of the conformance queue)

1. `-Y` / `--assembly` emits a malformed gcc line (`-g0` glued to the quoted
   source path, `src/compile.nim:291/299`). One-char fix.
2. `--sanitize` / `-S` is a no-op and `-S` is not registered (queue #2/#8).
3. `-T` / `--more-timing` is a no-op (queue #3).
4. `-r` / `--release` does not elide runtime checks (`check(false,...)` aborts
   rc=255 vs oracle rc=0; `nochecks` hardcoded `false` at `src/compile.nim:201`,
   `s.release` is a dead field in `src/cgen.nim`) (queue #4).
5. `for ... in` SIGSEGVs (ours rc=139 vs oracle rc=1) — ours should reject cleanly
   (queue #6; also the S2 parser sweep).
6. stdin `-` unsupported (`src/main.nim:248`) (queue #7).
7. `--generator` / `--verbose` long forms and `-S` / `-C` short forms unregistered
   (queue #8/#9).
8. No `lua` codegen backend (queue #10; big feature, recorded not launched).

Items 2/7 were launched as the CLI flag-registration agent 2026-09-03 evening
(owns `src/cli.nim`); items 1/4/6 were launched as the CLI driver agent (owns
`src/compile.nim` + `src/main.nim`).

## Out of scope (unchanged from the original)

- Version-string format (clean-room; ours is a different but valid string).
- `-fwrapv`/`-fno-strict-aliasing` on the gcc line (separate correctness item).
- The `##[[` compile-time eval and `#[expr]#` splice scoping (splice B/C/D agent).