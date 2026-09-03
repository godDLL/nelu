#!/usr/bin/env python3
"""CLI conformance harness -- oracle (/usr/bin/nelua) vs ours (tmp/nelua).

Runs a MATRIX of flag combinations through BOTH compilers over a corpus of
.nelua programs and assigns a verdict per (program, flagset):

  MATCH      identical combined stdout+stderr AND exit code
  DIFF       diverges in output or exit code
  CRASH      ours dies on a signal (SIGSEGV/SIGABRT/panic) where the oracle
             did not -- a takeover blocker
  UNSUPPORTED ours rejects a flag the oracle accepts (unknown option / unimplemented)
  ORACLE-REJECT the oracle itself will not run this program (informational;
             not a parity target under the project triage rule)
  SKIP       both compilers fail to build/run (no oracle behaviour to compare)
  TIMEOUT     a run exceeded its deadline

Design notes
------------
* Every run writes the source to a UNIQUE /tmp path first.  The oracle caches
  compiled artefacts (and, for --print-ast, the dump) by source name, so a
  shared path would silently return a stale result for the next flagset.
* Build+run flagsets compile with `-b -o <unique>` (both compilers build but
  do NOT execute when -o is given) and then execute the artefact, so the
  verdict reflects the PROGRAM's behaviour, not the compiler's chatter.
  Dump flagsets compare the compiler's own stdout+stderr+exit.
* Deterministic and rerunnable: same corpus order, same flagset order, unique
  paths, fixed timeouts.  Exit code is 0 by default (report-only); pass --gate
  to make CRASH / UNSUPPORTED / DIFF-on-buildrun fatal.

Run examples
------------
  python3 tmp/cli_conformance.py                      # dump matrix over all www
  python3 tmp/cli_conformance.py --matrix buildrun    # build+run matrix over
                                                      # the representative subset
  python3 tmp/cli_conformance.py --matrix full --gate # everything, gated
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile

# Lives in plan/, so ROOT is the project root (parent of plan/).
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUR = os.path.join(ROOT, "tmp", "nelua")
ORACLE = "/usr/bin/nelua"
DEFAULT_CORPUS = os.path.join(ROOT, "examples", "www")

# Verdict enum (plain strings so the table is human-readable).
(MATCH, DIFF, CRASH, UNSUPPORTED, ORACLE_REJECT, SKIP, TIMEOUT) = (
    "MATCH", "DIFF", "CRASH", "UNSUPPORTED", "ORACLE-REJECT", "SKIP", "TIMEOUT")

# Signals that mean "ours died where the oracle ran".
CRASH_MARKERS = ("SIGSEGV", "SIGABRT", "SIGBUS", "SIGFPE", "Illegal storage",
                 "panicked", "stack overflow", "double free", "heap corruption")

# The oracle's --print-analyzed-ast emits REAL memory addresses
# (pseudoargattrs = "table: 0x7f7c34948cc0") that change on every run, so the
# oracle is not even self-comparable and this flagset could never MATCH.  Ours
# emits the literal placeholder <ptr>.  Both mean "a pointer to a table" -- map
# them to one token so the dump comparison is deterministic.  Applied to dump
# output ONLY: in buildrun output a 0x.. is real programme data (e.g. an address
# a program prints) and must not be masked.
import re as _re
_PTR_RE = _re.compile(r'"table: 0x[0-9a-fA-F]+"|<ptr>|0x[0-9a-fA-F]+')


def normalize_output(s):
    """Mask non-deterministic pointer tokens in dump output."""
    return _PTR_RE.sub("<PTR>", s)

# ---------------------------------------------------------------- flag matrix

# kind="dump": compare the compiler's own stdout+stderr+exit (no binary run).
# kind="buildrun": compile -b -o <out> + flags, run the artefact, compare the
#   PROGRAMME's stdout+stderr+exit.
# kind="eval": -i/--eval; the code IS the input, so GLOBAL (run once).
# kind="script": --script <file>; compare stdout+stderr+exit (.lua only).
# kind="error": deliberately bad flag; GLOBAL (run once).
MATRIX = [
    # ---- dump / analysis flags -------------------------------------------
    ("print-ast",         "dump",   ["--print-ast"]),
    ("print-analyzed-ast","dump",   ["--print-analyzed-ast"]),
    ("print-ppcode",      "dump",   ["--print-ppcode"]),
    ("print-code",        "dump",   ["--print-code"]),
    ("print-assembly",    "dump",   ["--print-assembly"]),
    ("code",              "dump",   ["-c"]),
    ("analyze",           "dump",   ["-a"]),
    ("lint",              "dump",   ["--lint"]),
    # ---- build + run modifiers -------------------------------------------
    ("default",           "buildrun", []),
    ("release",           "buildrun", ["-r"]),
    ("maxperf",           "buildrun", ["-M"]),
    ("strip",             "buildrun", ["-s"]),
    ("sanitize",          "buildrun", ["--sanitize"]),
    ("no-warning",        "buildrun", ["-w"]),
    ("no-color",          "buildrun", ["--no-color"]),
    ("verbose",           "buildrun", ["-V"]),
    ("timing",            "buildrun", ["-t"]),
    ("more-timing",       "buildrun", ["-T"]),
    # ---- eval ------------------------------------------------------------
    ("eval-short",        "eval",   ["-i", "print(42)"]),
    ("eval-long",         "eval",   ["--eval", "print(42)"]),
    # ---- script (only meaningful for .lua inputs) ------------------------
    ("script",            "script", ["--script"]),
    # ---- error handling --------------------------------------------------
    ("unknown-flag",      "error",  ["--bogus-flag-xyz"]),
]
GLOBAL_KINDS = {"eval", "error"}   # no source file -- run once, not per corpus file

# Files that exercise require (path resolution is flag-sensitive).
REQUIRE_FILES = ("www_math", "www_mipairs", "seqtoy", "tetrix")


# ---------------------------------------------------------------- helpers

def run(cmd, timeout=45):
    """Run a command, returning (combined stdout+stderr, exit code).

    subprocess returns a negative exit code when the process is killed by a
    signal; we keep that so CRASH detection can read it directly.
    """
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        return p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "(timeout)", -1


def is_crash(rc, out):
    """True when the exit code is signal-based or the output names a crash."""
    if rc < 0 or rc in (139, 134, 132, 131):   # SIGSEGV/SIGABRT/SIGILL/SIGINT
        return True
    return any(m in out for m in CRASH_MARKERS)


def compile_and_run(comp, srcpath, flags, outbin, timeout=60):
    """Compile srcpath with `flags` to outbin, then run outbin.

    Returns (prog_out, prog_rc, build_out, build_rc).  prog_out/rc are None
    when the build itself failed.
    """
    b = subprocess.run([comp, "-b", "-o", outbin] + flags + [srcpath],
                       capture_output=True, text=True, timeout=timeout)
    build_out = b.stdout + b.stderr
    build_rc = b.returncode
    if build_rc != 0:
        return None, build_rc, build_out, build_rc
    if not os.path.exists(outbin):
        return "(no binary)", -1, build_out, build_rc
    r = subprocess.run([outbin], capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr, r.returncode, build_out, build_rc


def verdict_for(kind, o_out, o_rc, i_out, i_rc, o_build=None, i_build=None):
    """Classify a single (program, flagset) pair.

    For buildrun, o_out/i_out are None when that compiler's BUILD failed (the
    programme never ran); the other kinds always pass strings.
    """
    if kind == "buildrun":
        # Both failed to build: nothing to compare.
        if o_out is None and i_out is None:
            return SKIP
        # Oracle could not build/run it -- not a parity target.
        if o_out is None:
            return ORACLE_REJECT
        # Ours failed to build where the oracle built and ran.
        if i_out is None:
            if i_rc < 0 or (i_build and is_crash(i_rc, i_build)):
                return CRASH
            return DIFF
        if is_crash(i_rc, i_out) and not is_crash(o_rc, o_out):
            return CRASH
        return MATCH if (o_out == i_out and o_rc == i_rc) else DIFF

    # Non-buildrun kinds always have string output.
    if o_out is None:
        o_out = ""
    if i_out is None:
        i_out = ""

    if o_rc == -1 or "(timeout)" in o_out:
        return ORACLE_REJECT
    if i_rc == -1 or "(timeout)" in i_out:
        # Ours timed out where the oracle ran -- a real divergence.
        return CRASH if o_rc == 0 else DIFF

    if kind == "error":
        # Both must reject the bad flag.  If ours accepts it (rc 0 / runs the
        # program) that is UNSUPPORTED; if the messages differ that is a DIFF.
        o_rej = o_rc != 0
        i_rej = i_rc != 0
        if o_rej and not i_rej:
            return UNSUPPORTED
        if o_rej and i_rej:
            return MATCH if o_out == i_out else DIFF
        return DIFF

    if kind in ("dump", "eval", "script"):
        if o_rc != 0 and i_rc == 0:
            return UNSUPPORTED      # ours accepted what oracle rejected? rare
        if o_rc == 0 and i_rc != 0:
            return UNSUPPORTED      # ours rejected a flag/oracle-ran programme
        if is_crash(i_rc, i_out) and not is_crash(o_rc, o_out):
            return CRASH
        return MATCH if (o_out == i_out and o_rc == i_rc) else DIFF

    # buildrun: compare the PROGRAMME's output.
    if o_out is None and i_out is None:
        return SKIP                # both failed to build
    if o_out is None:
        return ORACLE_REJECT       # oracle could not build/run it
    if i_out is None:
        # Ours failed to build where the oracle built and ran.
        if is_crash(i_rc, i_build or ""):
            return CRASH
        return DIFF
    if is_crash(i_rc, i_out) and not is_crash(o_rc, o_out):
        return CRASH
    if o_out == i_out and o_rc == i_rc:
        return MATCH
    return DIFF


# ---------------------------------------------------------------- main

def main():
    import argparse
    ap = argparse.ArgumentParser(description="Nelua CLI conformance harness")
    ap.add_argument("--corpus", default=DEFAULT_CORPUS)
    ap.add_argument("--matrix", default="dump",
                    choices=["dump", "buildrun", "eval", "script", "error",
                             "full"])
    ap.add_argument("--subset", type=int, default=0,
                    help="only the first N corpus files (alphabetical); "
                         "0 = all")
    ap.add_argument("--only", default="", help="regex filter on file basename")
    ap.add_argument("--gate", action="store_true",
                    help="exit non-zero on CRASH / UNSUPPORTED / buildrun DIFF")
    ap.add_argument("--timeout", type=int, default=45)
    args = ap.parse_args()

    if not os.path.exists(OUR):
        sys.stderr.write(f"ours missing: {OUR}\n")
        return 2

    files = sorted(
        glob.glob(os.path.join(args.corpus, "**", "*.nelua"), recursive=True) +
        glob.glob(os.path.join(args.corpus, "**", "*.lua"), recursive=True))
    if args.only:
        import re
        rx = re.compile(args.only)
        files = [f for f in files if rx.search(os.path.basename(f))]
    if args.subset:
        # Always include the require files, then the first N alphabetically.
        need = [f for f in files
                if os.path.basename(f)[:-6] in REQUIRE_FILES]
        rest = [f for f in files
                if os.path.basename(f)[:-6] not in REQUIRE_FILES]
        files = sorted(need) + rest[:args.subset]

    # Select the flagsets to run.
    if args.matrix == "full":
        flagsets = MATRIX
    else:
        kinds = {"dump": ("dump",), "buildrun": ("buildrun",),
                 "eval": ("eval",), "script": ("script",),
                 "error": ("error",)}
        flagsets = [m for m in MATRIX if m[1] in kinds[args.matrix]]

    tmpd = tempfile.mkdtemp(prefix="nelua_cli_conf_")
    counter = [0]

    def fresh_src(ext):
        counter[0] += 1
        p = os.path.join(tmpd, f"src_{counter[0]:04d}.{ext}")
        return p

    def fresh_bin():
        counter[0] += 1
        return os.path.join(tmpd, f"bin_{counter[0]:04d}")

    counts = {v: 0 for v in
              (MATCH, DIFF, CRASH, UNSUPPORTED, ORACLE_REJECT, SKIP, TIMEOUT)}
    rows = []
    nfiles = len(files)

    def record(name, fname, kind, v, detail):
        counts[v] += 1
        if v != MATCH:
            rows.append((name, fname, kind, v, detail))

    # Global flagsets (eval, error) do not take a source file -- run once.
    for fname, kind, flags in flagsets:
        if kind not in GLOBAL_KINDS:
            continue
        o_out, o_rc = run([ORACLE] + flags, args.timeout)
        i_out, i_rc = run([OUR] + flags, args.timeout)
        v = verdict_for(kind, o_out, o_rc, i_out, i_rc)
        detail = "" if v == MATCH else (
            f"O[{o_out[:40]!r} rc={o_rc}] I[{i_out[:40]!r} rc={i_rc}]")
        record("(global)", fname, kind, v, detail)

    for f in files:
        name = os.path.basename(f)[:-6]
        ext = "lua" if f.endswith(".lua") else "nelua"
        for fname, kind, flags in flagsets:
            if kind in GLOBAL_KINDS:
                continue
            if kind == "script" and ext != "lua":
                continue
            src = fresh_src(ext)
            shutil.copyfile(f, src)

            if kind == "buildrun":
                ob = fresh_bin()
                o_out, o_rc, o_build, _ = compile_and_run(
                    ORACLE, src, flags, ob, args.timeout)
                ib = fresh_bin()
                i_out, i_rc, i_build, _ = compile_and_run(
                    OUR, src, flags, ib, args.timeout)
                v = verdict_for(kind, o_out, o_rc, i_out, i_rc,
                                o_build, i_build)
                detail = "" if v == MATCH else (
                    f"O[{(o_out or '')[:40]!r} rc={o_rc}] "
                    f"I[{(i_out or '')[:40]!r} rc={i_rc}]")
            else:
                o_out, o_rc = run([ORACLE] + flags + [src], args.timeout)
                i_out, i_rc = run([OUR] + flags + [src], args.timeout)
                if kind == "dump":
                    o_out = normalize_output(o_out)
                    i_out = normalize_output(i_out)
                v = verdict_for(kind, o_out, o_rc, i_out, i_rc)
                detail = "" if v == MATCH else (
                    f"O[{o_out[:40]!r} rc={o_rc}] "
                    f"I[{i_out[:40]!r} rc={i_rc}]")
            record(name, fname, kind, v, detail)

    # ---- report -----------------------------------------------------------------
    width = max(len(r[0]) for r in rows) if rows else 8
    print(f"corpus: {args.corpus}  ({nfiles} files)")
    print(f"matrix: {args.matrix}  ({len(flagsets)} flagsets)")
    print("-" * 118)
    print(f"{'program':<{width}} {'flagset':<18} {'kind':<10} verdict")
    print("-" * 118)
    for name, fname, kind, v, detail in rows:
        print(f"{name:<{width}} {fname:<18} {kind:<10} {v}")
        if detail:
            print(f"{'':<{width}} {'':<18} {'':<10}   {detail}")
    print("-" * 118)
    total = sum(counts.values())
    print("verdict counts:")
    for v in (MATCH, DIFF, CRASH, UNSUPPORTED, ORACLE_REJECT, SKIP, TIMEOUT):
        if counts[v]:
            print(f"  {v:<16} {counts[v]}")
    print(f"  {'TOTAL':<16} {total}")
    print(f"\nMATCH rate: {counts[MATCH]}/{total} "
          f"({100.0 * counts[MATCH] / max(total, 1):.1f}%)")

    if args.gate:
        fatal = counts[CRASH] + counts[UNSUPPORTED]
        buildrun_diffs = sum(1 for r in rows if r[2] == "buildrun" and r[3] == DIFF)
        print(f"\n--gate: fatal={fatal} (CRASH+UNSUPPORTED), "
              f"buildrun DIFFs={buildrun_diffs}")
        return 1 if (fatal or buildrun_diffs) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())