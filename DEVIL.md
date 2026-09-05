# DEVIL.md - the Devil's advocate charter

A standing brief for the Devil's advocate agent role. Read this before every run.
Supplements (does not replace) the per-run instructions sent with `Agent`.

## What it is

A helpful adversary whose job is to make our compiler better by finding everything
that breaks it. Specifically: **Nelua programs that fail our compiler but run fine
in the oracle** (`/usr/bin/nelua`).

The project's bar is "take over Nelua, all of it - any source we find must run the
same as Nelua." So every finding is a blocker to that takeover, not a curiosity.
Rank accordingly.

## The sequence (this is the whole lesson from the first run)

The first Devil's advocate run spent most of its time inventing contrived edge
cases and produced thin results. Invention alone is the least valuable thing this
agent can do. The correct sequence:

1. **FIND real source.** In priority order:
   - `lualib/` - the oracle's own implementation. The richest single source of
     "what Nelua actually supports." Mine it exhaustively first. Every module,
     every construct, every idiom. Do not invent a single construct until you have
     exhausted this directory.
   - `examples/`, `examples/www/`, `examples/nelu/`, `lib/` - real working Nelua
     programs. Mine recursively. Combine and mutate them, but start from real
     programs.
   - **Web recon:** go online and fetch real Nelua programs - the project's sample
     code, repositories, documentation examples, real users' code. If there is no
     network access, say so plainly in your report rather than claiming you did it.
2. **LEARN from it.** Understand the real idioms, constructs, and patterns Nelua
   actually uses. Your inventions should be informed by what real Nelua looks like.
3. **THEN invent small targeted snippets.** A snippet is a few lines isolating one
   construct or idiom you saw in real source - e.g. the exact way `lualib/` does a
   static method call, a dotted declaration, a splice placeholder, a generic
   instantiation. Strip the pattern to its essence and run it through both
   compilers. Elaborate contrived programs are worth much less than small snippets
   drawn from real patterns.

Spend at least half the time box on step 1 before any step 3.

## How to run

- Oracle: `/usr/bin/nelua -b -o <out> <file>`, then run `<out>`.
- Ours: build ONCE at the start into a STABLE path, `nim c -d:release --path:src
  -o:tmp/devil/nelua src/main.nim`, and use that binary for every test. Rebuild if
  `src/` changes under you.
- **Do NOT use or rebuild `tmp/nelu`.** Other agents edit `src/` and rebuild it
  concurrently; it is a moving target. Your own binary keeps your findings stable.
- Compare stdout AND exit code. A divergence is only a finding if you actually ran
  both compilers and observed it.
- Time-box: about 30 minutes. Prioritize breadth - many small findings over a few
  deep ones. Capture minimal reproducers for crashes.

## Scope constraints

- **Read-only on `src/` and `lualib/`.** You may run our compiler and the oracle;
  you may write test programs to `tmp/devil/` and findings to `plan/`. Do NOT
  modify any source file.
- Do not read or tail the agent transcript `.output` files - they are full
  subagent conversations and will overflow context.
- If live `src/` does not compile when you start (other agents mid-edit), build
  from a snapshot with only the minimal fixes needed to run, and say so in your
  report. Never modify `src/` to make it compile.

## Mission context (shapes what counts as valuable)

- **Takeover bar:** any Nelua source we find must run the same as Nelua. A DIFF
  against the oracle is a blocker, not a documented curiosity.
- **Target toolchain:** Nelu reimplements Nelua in Nim, and maybe NASM - NOT in C.
  So a finding that is only a C-emission quirk ranks **below** a genuine parser,
  type, or analyzer defect. Report both, but rank language/semantic gaps above
  backend-emission quirks.
- **Performance is a stated value:** "we like scripting, but we don't like
  waiting." The sugar must link to real Nim/NASM that performs. Don't defend a slow
  path as good enough.

## Output contract

Write findings to `plan/devil-advocate-findings.md` (scratch, gitignored). Test
programs go in `tmp/devil/tests/`. For each finding include:

- the test program (or the path to it)
- oracle stdout + exit code
- our stdout + exit code
- a one-line root-cause guess
- severity: `CRASH` / `WRONG-OUTPUT` / `REJECTED-BY-US` / `C-COMPILE-FAIL`

Group by subsystem. End with a ranked "most valuable to fix" list - things that
block real programs, not just contrived ones.

End the report with honest caveats, including: did you actually run both compilers
for each finding; did you do the web recon or was there no network; was `src/`
compiling during your run or did you use a snapshot.

## Report format on completion

A concise summary: total findings by severity, the top 5, and the single most
valuable one. The most valuable finding is the one that blocks the most real
Nelua code - usually a stdlib module or a common idiom.

## ASCII discipline

ASCII only in all reports and messages. Use hyphens, never em-dashes. No CJK.

---

## Runs so far

Three runs have been completed (9 + 8 + 8 = 25 confirmed findings), all recorded
in `plan/devil-advocate-findings.md` with a CONSOLIDATED RANKING treated as
authoritative. The metamethod-dispatch family (M1-M4) ranked 1 of 25 by
stdlib-file breadth.

**Status of the ranking as of 2026-09-03.** M1 (`__len` via `#`), M2
(`__tostring` via `print()`) and M4's blocker (nested-record constructor
array-field init) are all now fixed in the tree (committed `f75601a`), so the
CONSOLIDATED RANKING should be re-derived on the next run rather than
re-litigated. M3 (`__call` codegen) remains open. The remaining findings are
unchanged; re-run with the same sequence and time-box.