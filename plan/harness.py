#!/usr/bin/env python3
"""One harness for all Nelu language-conformance comparison.

What it does, in order:
  1. rebuild tmp/nelua if stale (make nelu, which honours NELU_OUT -> tmp/nelua)
  2. walk ONE corpus directory (exam/) recursively; nothing enumerated by hand
  3. run every probe through our compiler (tmp/nelua) and the oracle (/usr/bin/nelua)
  4. print ONE table with one status vocabulary
  5. exit non-zero only on a REGRESSION (a previously MATCHing probe going
     DIFF/CRASH/REJECT, or a new crash)

Tiers, all walked from exam/:
  M1 parse-AST           examples/dump-ast/*.nelua        (0 probes today)
  M2 analyzed-AST        examples/dump-analyzed-ast/*.nelua (0 probes today)
  cmp                    40 inline token-level AST cases
  exec                   exam/*.nelua, run through -b -o and executed
  NEG                    exam/neg_*.nelua, programs the oracle rejects;
                         parity question is "does Nelu also reject it"
  CLI                    29 flagsets x 3 programs across dump/build/obj/lib/
                         c-roundtrip/asm-roundtrip/version/config/eval/error

Usage:
  python3 plan/harness.py          run everything, exit 1 on regression
  python3 plan/harness.py --record capture the baseline from this tree

The baseline lives in plan/harness_baseline.json.  A probe that is not in the
baseline is "new": a new crash is fatal, anything else is reported and not
fatal.  Run --record to (re)capture the baseline from this tree.
reported and not fatal.  Run --record to (re)capture the baseline from the
current tree.
"""
import glob
import json
import os
import re
import subprocess
import sys

# The harness spawns a lot of short-lived children in rapid succession (our
# compiler, the oracle, gcc, and the compiled probe binaries), and the
# resulting burst of CPU and I/O load hiccups the machine's video.  Run every
# child at niceness 15 so the harness process itself stays at normal priority
# while all of its work is deprioritised.  Children inherit, so `make nelu`
# (which spawns the nim compiler) is covered too -- only the direct children
# need the wrapper, the whole tree comes along.
_orig_subprocess_run = subprocess.run

def _nice_subprocess_run(cmd, *args, **kwargs):
  if isinstance(cmd, (list, tuple)):
    cmd = ["nice", "-n", "15"] + list(cmd)
  else:
    cmd = "nice -n 15 " + cmd
  return _orig_subprocess_run(cmd, *args, **kwargs)

subprocess.run = _nice_subprocess_run

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "exam")
# The OG upstream trees live alongside our own corpus; they are conformance
# probes too, so the harness walks all three.  exam/ is ours (neg_ prefixes,
# the neg tier), tests/ and examples/ are the upstream nelua trees taken over.
CORPUS_DIRS = [os.path.join(ROOT, d) for d in ("exam", "tests", "examples")]
TMP = os.path.join(ROOT, "tmp")
OUR = os.path.join(TMP, "nelua")
ORACLE = "/usr/bin/nelua"
BASELINE = os.path.join(ROOT, "plan", "harness_baseline.json")
OUTDIR = os.path.join(TMP, "harness_out")

# SDL/graphics probes run headless: the dummy video driver gives SDL a
# in-memory surface with no real window, so executing a visual demo in the
# harness does not spawn one.  Harmless for non-SDL programs (they ignore it).
HEADLESS_ENV = dict(os.environ)
HEADLESS_ENV["SDL_VIDEODRIVER"] = "dummy"
HEADLESS_ENV["SDL_AUDIODRIVER"] = "dummy"

# Negative-conformance probes are marked by filename prefix, NOT by living in
# a dedicated folder: the folder was a harness implementation detail that
# leaked into the corpus layout.  A probe named neg_<thing>.nelua is a
# candidate negative test; neg_probe() confirms it by running the oracle.
NEG_PREFIX = "neg_"


def is_neg_probe(rel):
    return os.path.basename(rel).startswith(NEG_PREFIX)

# M1 baseline, recorded inline by plan/regress.py 2026-09-03:
# 25 MATCH / 3 DIFF / 0 CRASH over the 28 parse-AST probes.  The 3 DIFFs
# (_8/_11/_12) use an @-prefixed type constructor the oracle 0.2.0-dev
# rejects outright, so they are a corpus-convention issue, not a parser bug.
M1_BASELINE_MATCHES = 25
M1_BASELINE_DIFFS = 3
M1_BASELINE_CRASHES = 0

# Examples that are not standalone programs; the oracle does not produce a
# clean exit for them either, so they are out of scope for the exec gate.
EXEC_SKIP = {
    "overview":  "illustrative, not a standalone program (oracle exits 1)",
}

# The 40 curated token-level AST cases (plan/cmp.py).  Inline, not a walked
# corpus: each is a 2-line source string with a known oracle verdict.
CMP_CASES = [
    ("1",  "local x: integer = 0"),
    ("2",  "local t = {1, 2, foo = 3}"),
    ("3",  "function foo(a: integer): integer return a + 1 end"),
    ("4",  "for i = 1, 10 do print(i) end"),
    ("5",  "local s = a.b:c(1)"),
    ("6",  "local f = function(x) return x + 1 end"),
    ("7",  "if a > 0 then x = 1 elseif a == 0 then x = 0 else x = -1 end"),
    ("8",  "local u: record { a: integer, b: string } = { a = 1, b = \"hi\" }"),
    ("9",  "local arr: array(integer, 10)"),
    ("10", "local p: pointer(integer)"),
    ("11", "local e: enum { Red = 0, Green = 1, Blue = 2 }"),
    ("12", "local un: union { X: integer, Y: string }"),
    ("13", "local fn: function(a: integer): integer"),
    ("14", "defer\n  print(1)\nend"),
    ("15", "local y = 1 + 2 * 3 - 4 / 5 % 6"),
    ("16", "local z = a and b or c"),
    ("17", "local w = not x"),
    ("18", "local v = #t"),
    ("19", "local b = a == b"),
    ("20", "local g = a < b and c >= d"),
    ("21", "local ptr: *integer"),
    ("22", "local arr2: array(integer)"),
    ("23", "local v: integer | string"),
    ("24", "local f2: function(a: integer, b: string): integer, string"),
    ("25", "local opt: integer?"),
    ("26", "local nested: array(pointer(integer), 5)"),
    ("27", "local rec2: record { name: string, age: integer, tags: array(string, 3) }"),
    ("28", "local x = -5"),
    ("29", "local s = \"hi\" .. \"lo\""),
    ("30", "local a, b = 1, 2"),
    ("31", "local t = { [1] = \"a\", [\"x\"] = 2, y = 3 }"),
    ("32", "function obj:method(a, b) return self end"),
    ("33", "local f = function(self, a): integer <ann> return a end"),
    ("34", "while x > 0 do x = x - 1 end"),
    ("35", "repeat print(x) until x == 0"),
    ("36", "local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end"),
    ("37", "local t = {1, 2, 3}; print(#t)"),
    ("38", "local x = (1 + 2) * 3"),
    ("39", "local s = [[long\nstring]]"),
    ("40", "local e: enum { Red, Green, Blue }"),
]


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def build_our():
    """Rebuild tmp/nelua via `make nelu` (NELU_OUT -> tmp/nelua) if stale."""
    if os.path.exists(OUR):
        bin_mt = os.path.getmtime(OUR)
        for f in glob.glob(os.path.join(ROOT, "src", "*.nim")) + \
                glob.glob(os.path.join(ROOT, "src", "*.c")):
            if os.path.getmtime(f) > bin_mt:
                break
        else:
            return True, "up to date"
    r = subprocess.run(["make", "nelu"], capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        return False, (r.stderr or r.stdout)[-2000:]
    return True, "built"


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def run(cmd, timeout=60):
    """Run cmd, returning (stdout, stderr, returncode)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, cwd=ROOT)
        return p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "(timeout)", "", -1


def combined(out):
    return out[0] + out[1]


def is_crash(out):
    return "SIGSEGV" in out or "Illegal storage access" in out or "panicked" in out


# ---------------------------------------------------------------------------
# M1: parse-AST tokenizer diff (mirrors plan/regress.py) -------------------
# The two --print-ast dumps are structurally different by design (ours is the
# nk-prefixed flat dump, the oracle is the nested Block/VarDecl form), so
# tokenization is the only honest comparison.  Two canonicalization rules are
# needed before the streams are comparable, both verified not to mask
# regressions (see tmp/m1probe_test.py / tmp/m1gate_sim.py):
#   Rule 1 -- drop the oracle's absent-field placeholder (a bare (None,'false')
#     never carries a genuine value; a real boolean is always wrapped).
#   Rule 2 -- our dump renders the binary operator as a pseudo-node
#     (BinaryOp,add); the oracle renders it as a bare scalar (None,add).

def toks_mine(s):
    out = []
    lines = s.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i].strip().rstrip(",")
        if not line or not line.startswith("nk"):
            i += 1
            continue
        body = line[2:].strip()
        parts = body.split(None, 1)
        kind = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        scalar = None
        if rest:
            if rest == ":true":
                scalar = "true"
            elif rest == "false":
                scalar = "false"
            elif ":" in rest and not rest.startswith('"'):
                scalar = rest.split(":")[0]
            elif rest.startswith('"'):
                q = rest.find('"', 1)
                if q == -1:
                    buf = rest
                    i += 1
                    while i < n:
                        buf += "\n" + lines[i].strip().rstrip(",")
                        q = buf.find('"', 1)
                        if q != -1:
                            break
                        i += 1
                    scalar = buf[1:q].replace("\n", "\\n") if q != -1 else buf[1:].strip('"')
                else:
                    scalar = rest[1:q]
            else:
                scalar = rest
        out.append((kind, scalar))
        i += 1
    return out


def toks_oracle(s):
    out = []
    pending = None
    for line in s.splitlines():
        line = line.strip().rstrip(",")
        if not line or line in ("{", "}"):
            continue
        if line.endswith("{"):
            out.append([line[:-1].strip(), None])
            pending = out[-1]
            continue
        if "{" in line and line.endswith("}"):
            kind = line[:line.index("{")].strip()
            inner = line[line.index("{") + 1:].rstrip("}").strip()
            scalar = "true" if inner in ("true", "false") else (
                inner.strip('"') if inner.startswith('"') else (inner or None))
            out.append([kind, scalar])
            pending = out[-1]
            continue
        if (line.startswith('"') and line.endswith('"')) or line in (
                "true", "false") or (line and line[0].isdigit()):
            scalar = line if line in ("true", "false") else (
                line.strip('"') if line.startswith('"') else line)
            if pending is not None and pending[1] is None:
                pending[1] = scalar
            else:
                out.append([None, scalar])
                pending = None
            continue
    return [tuple(t) for t in out]


def norm_m1(tokens):
    out = []
    for kind, scalar in tokens:
        if kind is None and scalar == "false":      # Rule 1: absent-field placeholder
            continue
        if kind == "BinaryOp" and scalar is not None:  # Rule 2: operator -> bare scalar
            out.append((None, scalar))
            continue
        out.append((kind, scalar))
    return out


def m1_probe(path):
    our_out = run([OUR, "--print-ast", path])
    ora_out = run([ORACLE, "--print-ast", path])
    if is_crash(combined(our_out)):
        return "NELU_CRASH", combined(our_out).strip()[:80]
    mo = norm_m1(toks_mine(combined(our_out)))
    oo = norm_m1(toks_oracle(combined(ora_out)))
    return ("MATCH" if mo == oo else "DIFF"), ""


# ---------------------------------------------------------------------------
# M2: analyzed-AST diff vs stored oracle dump *.ref ------------------------
# The codename is derived from the source path, so it moves with the corpus;
# the filename attr does too.  Both are normalized away so the comparison is
# path-independent.  The codename token is the corpus dir name ("dump_analyzed
# _ast" here, or the legacy "m2_corpus" the stored refs were captured with).

M2_CODENAME = re.compile(r"[A-Za-z0-9_]*(dump_analyzed_ast|m2_corpus)_[A-Za-z0-9_]*")


def norm_m2(s):
    s = M2_CODENAME.sub("<U>", s)
    s = re.sub(r'filename = "[^"]*"', 'filename = "<F>"', s)
    return s


def m2_probe(path):
    our_out = run([OUR, "--print-analyzed-ast", path])
    our_combined = combined(our_out)
    if is_crash(our_combined):
        return "NELU_CRASH", our_combined.strip()[:80]
    ref_path = path[:-6] + ".ref"
    if not os.path.exists(ref_path):
        return "NO-REF", "missing oracle dump"
    if norm_m2(our_combined) == norm_m2(open(ref_path).read()):
        return "MATCH", ""
    return "DIFF", ""


# ---------------------------------------------------------------------------
# exec mode: compile + run, compare stdout and exit ------------------------

def compile_run(comp, src, out):
    b = subprocess.run([comp, "-b", "-o", out, src],
                       capture_output=True, text=True, timeout=60, cwd=ROOT)
    if b.returncode != 0:
        # Full message, not just the last line: the driver appends
        # "no binary was produced to copy to ..." to *every* failure, so the
        # last line is useless for classification.  The real diagnostic is
        # earlier (a nelua parse/analyze "error:" or a gcc ".c:" line).
        msg = (b.stderr or b.stdout or "build-failed")
        return None, b.returncode, msg
    try:
        r = subprocess.run([out], capture_output=True, text=True, timeout=30,
                       cwd=ROOT, env=HEADLESS_ENV)
        return r.stdout, r.returncode, None
    except subprocess.TimeoutExpired:
        return None, -1, "timeout"


def classify_exec(name, our_out, our_exit, our_why, orc_out, orc_exit, orc_why):
    if name in EXEC_SKIP:
        return "SKIP", ""
    our_ok = our_out is not None
    orc_ok = orc_out is not None
    if our_ok and orc_ok:
        if our_out.rstrip() == orc_out.rstrip() and our_exit == orc_exit:
            return "MATCH", ""
        return "DIFF", ""
    if not our_ok and not orc_ok:
        return "BOTH_FAIL", ""
    if not our_ok:
        low = (our_why or "").lower()
        # A crash is a SIGSEGV/abort, or a gcc/linker failure on the generated
        # C (".c:", "undefined reference", "in function").  Everything else
        # that fails to build is a nelua parse/analyze/reject -- including the
        # driver's trailing "no binary was produced", which appears for all
        # of them and must not be mistaken for a C-gen crash.
        if any(k in low for k in ("segfault", "signal 11", "signal 6",
                                  "abort", "assertion", "panicked", "timeout")):
            return "NELU_CRASH", our_why
        if any(k in low for k in (".c:", "undefined reference", "in function")):
            return "NELU_CRASH", our_why
        return "NELU_REJECT", our_why
    # ours built fine but the oracle did not -- oracle-side unsupported.
    return "ORACLE_FAIL", orc_why


def exec_probe(path):
    rel = os.path.relpath(path, CORPUS)
    name = os.path.basename(path)[:-6]
    o_out = os.path.join(OUTDIR, rel[:-6] + ".o.bin")
    r_out = os.path.join(OUTDIR, rel[:-6] + ".r.bin")
    os.makedirs(os.path.dirname(o_out), exist_ok=True)
    our_out, our_exit, our_why = compile_run(OUR, path, o_out)
    orc_out, orc_exit, orc_why = compile_run(ORACLE, path, r_out)
    status, note = classify_exec(name, our_out, our_exit, our_why,
                                 orc_out, orc_exit, orc_why)
    if len(note) > 100:
        note = note[:100] + "..."
    return status, note


# ---------------------------------------------------------------------------
# NEG: negative conformance (exam/neg_<thing>.nelua) ------------------------
# A negative probe is a program the ORACLE REJECTS.  The parity question is
# not "does Nelu produce the same output" (there is none) but "does Nelu also
# reject it".  This is the half of conformance the positive corpus can never
# exercise: 99 MATCHes prove nothing about whether Nelu accepts garbage the
# oracle refuses.  The negative-ness is a filename prefix (neg_) confirmed
# behaviourally by running the oracle -- a neg_ probe the oracle actually
# accepts is SKIP, not a negative test.  Verdicts:
#   MATCH        both reject (rc != 0)
#   NELU_ACCEPT  Nelu builds (rc == 0) where the oracle rejected -- the bad one
#   SKIP         oracle did not actually reject this probe (not a negative test)

def neg_probe(path):
    o_out, o_exit, o_why = compile_run(ORACLE, path, path + ".orc.bin")
    i_out, i_exit, i_why = compile_run(OUR, path, path + ".nelu.bin")
    o_rej = o_out is None      # oracle failed to build -> it rejected
    i_rej = i_out is None
    if not o_rej:
        return "SKIP", "oracle accepted; not a negative test"
    # Oracle rejected this input.  Parity means Nelu rejects it too; if Nelu
    # builds it, that is the fatal divergence this tier exists to catch.
    if not i_rej:
        return "NELU_ACCEPT", (i_why or "")[:80]
    return "MATCH", ""


# ---------------------------------------------------------------------------
# CLI: command-line surface conformance -------------------------------------
# Fresh implementation -- the old standalone CLI harness in
# tmp/legacy/scripts/cli_conformance.py is not trusted and is not copied.
# The oracle's own behaviour IS the source here: for each flagset we run both
# compilers over a small representative corpus and compare combined
# stdout+stderr and exit code.  A flagset where the oracle runs but Nelu does
# not (rejects the flag, crashes, or times out) is a divergence.
#
#   MATCH      identical combined output AND exit code
#   DIFF       same flagset, output or exit differs
#   CRASH      ours died on a signal where the oracle ran
#   UNSUPPORTED ours rejects a flag the oracle accepts
#   SKIP       both reject / oracle rejects the program (nothing to compare)

CLI_FLAGSETS = [
    # ---- dump / analysis levels: compare the compiler's own output -------
    ("print-ast",         "dump", ["--print-ast"]),
    ("print-analyzed-ast","dump", ["--print-analyzed-ast"]),
    ("print-ppcode",      "dump", ["--print-ppcode"]),
    ("print-code",        "dump", ["--print-code"]),
    ("print-assembly",    "dump", ["--print-assembly"]),
    ("code",              "dump", ["-c"]),
    ("analyze",           "dump", ["-a"]),
    ("lint",              "dump", ["--lint"]),
    # ---- build levels: compile an artefact, then run it ------------------
    ("default",           "build", []),
    ("release",           "build", ["-r"]),
    ("maxperf",           "build", ["-M"]),
    ("strip",             "build", ["-s"]),
    ("sanitize",          "build", ["-S"]),
    ("no-warning",        "build", ["-w"]),
    ("no-color",          "build", ["--no-color"]),
    ("verbose",           "build", ["-V"]),
    ("timing",            "build", ["-t"]),
    ("more-timing",       "build", ["-T"]),
    ("no-cache",          "build", ["-C"]),
    # ---- non-runnable artefact levels ------------------------------------
    ("object",            "obj",  ["-B"]),
    ("static-lib",        "lib",  ["-A"]),
    ("shared-lib",        "lib",  ["-H"]),
    # ---- round-trip levels: Nelu's own dumped output fed back through gcc --
    # These are the real "C" and "assembly" conformance levels: not "does the
    # flag produce text" but "does that text actually build and run like the
    # oracle's binary".  Byte-comparing the dumped text is meaningless (the
    # two compilers format it differently by design).
    ("c-roundtrip",       "cround",  ["--print-code"]),
    ("asm-roundtrip",     "asmround",["--print-assembly"]),
    # ---- introspection / no-source levels --------------------------------
    ("version",           "version", ["-v"]),
    ("semver",            "version", ["--semver"]),
    ("config",            "config",  ["--config"]),
    ("eval",              "eval",    ["-i", 'print("eval")']),
    ("unknown-flag",      "error",   ["--bogus-flag-xyz"]),
]
GLOBAL_KINDS = {"version", "config", "eval", "error"}

CLI_PROGRAMS = [
    ("cli_hello",   'print("hello")\n'),
    ("cli_arith",   'local x = 6\nlocal y = 7\nprint(x * y)\n'),
    ("cli_string",  'print("a" .. "b" .. "c")\n'),
]


def _cli_run(comp, kind, flags, srcpath, outbin):
    """One (compiler, kind, flags, src) observation.

    dump and the no-source introspection kinds (version/config/eval/error)
    compare the compiler's own stdout+stderr+exit -- there is no artefact.
    build compiles -b -o outbin + flags and runs it; obj/lib compile an
    artefact that is not runnable.
    Returns (combined_output, exit_code, build_ok)."""
    if kind == "dump" or kind in GLOBAL_KINDS:
        args = [comp] + flags
        if srcpath is not None:
            args.append(srcpath)
        b = subprocess.run(args, capture_output=True, text=True,
                           timeout=45, cwd=ROOT)
        return (b.stdout or "") + (b.stderr or ""), b.returncode, True
    # obj/lib carry their own output-mode flag (-B/-A/-H), which is mutually
    # exclusive with -b; forcing -b here made every artefact build fail.
    if kind in ("obj", "lib"):
        args = [comp, "-o", outbin] + flags
    else:
        args = [comp, "-b", "-o", outbin] + flags
    if srcpath is not None:
        args.append(srcpath)
    b = subprocess.run(args, capture_output=True, text=True,
                       timeout=60, cwd=ROOT)
    build_out = (b.stdout or "") + (b.stderr or "")
    if b.returncode != 0:
        return build_out, b.returncode, False
    if kind == "build":
        if not os.path.exists(outbin):
            return build_out + "\n(no binary)", -1, False
        try:
            r = subprocess.run([outbin], capture_output=True, text=True,
                               timeout=30, cwd=ROOT, env=HEADLESS_ENV)
            return (r.stdout or "") + (r.stderr or ""), r.returncode, True
        except subprocess.TimeoutExpired:
            return "(timeout)", -1, True
    # obj / static-lib / shared-lib: artefact is not runnable, compare build
    return build_out, 0, os.path.exists(outbin)


def _cli_verdict(kind, o_out, o_rc, o_ok, i_out, i_rc, i_ok):
    if kind in ("obj", "lib"):
        # Both must produce an artefact; build output is path-laden so we
        # compare build success, not the messages.
        if o_ok and i_ok:
            return "MATCH", ""
        if not o_ok:
            return "SKIP", "oracle could not build"
        if not i_ok:
            if i_rc < 0 or "SIGSEGV" in i_out or "panicked" in i_out:
                return "CRASH", i_out[:60]
            return "UNSUPPORTED", i_out[:60]
        return "DIFF", ""
    if kind == "build":
        if not o_ok:
            return "SKIP", "oracle could not build"
        if not i_ok:
            if i_rc < 0 or "SIGSEGV" in i_out or "panicked" in i_out:
                return "CRASH", i_out[:60]
            return "UNSUPPORTED", i_out[:60]
        if i_rc < 0 or "SIGSEGV" in i_out or "panicked" in i_out:
            return "CRASH", i_out[:60]
        return "MATCH" if (o_out == i_out and o_rc == i_rc) else "DIFF", ""
    # dump / version / config / eval: compare the compiler's own output.
    # NB: byte-equality is NOT the verdict here.  The two compilers print
    # ASTs, ppcode, C and assembly in different formats by design (oracle:
    # "Block {", Nelu: "nkBlock {"), so raw diffing would report a spurious
    # DIFF on every dump flag forever.  What dump-level conformance actually
    # means is: the flag works on both, produces output, and neither crashes.
    # The *content* conformance for AST is the cmp/ tier (token-level, both
    # formats normalised) and for C it is the c-roundtrip tier below.
    if o_rc == 0 and i_rc != 0:
        return "UNSUPPORTED", i_out[:60]
    if o_rc != 0 and i_rc == 0:
        return "UNSUPPORTED", i_out[:60]
    if i_rc < 0 or "SIGSEGV" in i_out or "panicked" in i_out:
        return "CRASH", i_out[:60]
    if o_rc != 0 and i_rc != 0:
        # both rejected the input -- parity of rejection, not of message
        return "MATCH", ""
    return "MATCH", ""


def cli_probe(prog_name, src, kind, flags):
    """One (program, flagset) CLI conformance observation."""
    tag = (prog_name if prog_name else "(global)") + "_" + kind + "_" + \
        (flags[0] if flags else "default")
    # The oracle appends .o/.a/.so to the -o path when it is missing that
    # suffix; Nelu writes exactly the path given.  Give both the canonical
    # suffix up front so they land on the same file and os.path.exists agrees.
    if "-B" in flags:
        ext = ".o"
    elif "-A" in flags:
        ext = ".a"
    elif "-H" in flags:
        ext = ".so"
    else:
        ext = ""
    srcp = os.path.join(TMP, "cli_src_" + tag + ".nelua")
    obin = os.path.join(TMP, "cli_orc_" + tag + ext)
    ibin = os.path.join(TMP, "cli_ours_" + tag + ext)
    if src is not None:
        with open(srcp, "w") as fh:
            fh.write(src)
    else:
        srcp = None
    o_out, o_rc, o_ok = _cli_run(ORACLE, kind, flags, srcp, obin)
    i_out, i_rc, i_ok = _cli_run(OUR, kind, flags, srcp, ibin)
    for p in (obin, ibin):
        if os.path.exists(p):
            os.remove(p)
    if srcp and os.path.exists(srcp):
        os.remove(srcp)
    if kind == "error":
        o_rej = o_rc != 0
        i_rej = i_rc != 0
        if o_rej and not i_rej:
            return "UNSUPPORTED", i_out[:60]
        if o_rej and i_rej:
            return ("MATCH" if o_out == i_out else "DIFF"), ""
        return "DIFF", ""
    return _cli_verdict(kind, o_out, o_rc, o_ok, i_out, i_rc, i_ok)


def cli_probe_global(kind, flags):
    """A flagset that takes no source file (version/config/eval/error)."""
    return cli_probe("(global)", None, kind, flags)


def _gcc_roundtrip(dumpfile, outbin):
    """Compile/assemble a Nelu-emitted .c or .s file with gcc.

    Returns (combined_output, exit_code, artefact_built)."""
    if dumpfile.endswith(".s"):
        cmd = ["gcc", "-c", dumpfile, "-o", outbin]
    else:
        cmd = ["gcc", dumpfile, "-o", outbin]
    b = subprocess.run(cmd, capture_output=True, text=True, timeout=90, cwd=ROOT)
    return (b.stdout or "") + (b.stderr or ""), b.returncode, \
        os.path.exists(outbin)


def rt_probe(kind, prog_name, src):
    """Round-trip conformance for one program at the C or assembly level.

    Nelu dumps its own output (--print-code / --print-assembly), that output
    is fed straight through gcc, and the result is compared against the
    oracle's binary for the same source."""
    tag = prog_name + "_" + kind
    srcp = os.path.join(TMP, "cli_src_" + tag + ".nelua")
    dumpfile = os.path.join(TMP, "cli_" + tag + ".c" if kind == "cround"
                            else ".s")
    obin = os.path.join(TMP, "cli_orc_" + tag)
    ibin = os.path.join(TMP, "cli_ours_" + tag)
    with open(srcp, "w") as fh:
        fh.write(src)
    # oracle binary -> reference stdout/exit
    o_out, o_rc, o_ok = _cli_run(ORACLE, "build", [], srcp, obin)
    if not o_ok:
        return "SKIP", "oracle could not build"
    # Nelu dumps its own output for this level
    flag = "--print-code" if kind == "cround" else "--print-assembly"
    i_dump, i_rc, _ = _cli_run(OUR, "dump", [flag], srcp, None)
    if i_rc != 0:
        return "UNSUPPORTED", i_dump[:60]
    with open(dumpfile, "w") as fh:
        fh.write(i_dump)
    gcc_out, gcc_rc, gcc_ok = _gcc_roundtrip(dumpfile, ibin)
    if not gcc_ok:
        for p in (srcp, dumpfile, obin, ibin):
            if os.path.exists(p):
                os.remove(p)
        if gcc_rc < 0 or "SIGSEGV" in gcc_out or "panicked" in gcc_out:
            return "CRASH", gcc_out[:60]
        return "UNSUPPORTED", gcc_out[:60]
    if kind == "cround":
        try:
            r = subprocess.run([ibin], capture_output=True, text=True,
                               timeout=30, cwd=ROOT, env=HEADLESS_ENV)
        except subprocess.TimeoutExpired:
            for p in (srcp, dumpfile, obin, ibin):
                if os.path.exists(p):
                    os.remove(p)
            return "TIMEOUT", ""
        for p in (srcp, dumpfile, obin, ibin):
            if os.path.exists(p):
                os.remove(p)
        if r.returncode != o_rc or (r.stdout or "") != (o_out or ""):
            return "DIFF", "rc %d/%s out %r/%r" % (
                r.returncode, o_rc, r.stdout[:40], o_out[:40])
        return "MATCH", ""
    # assembly level: artefact built and is non-empty -> parity of build
    asm_ok = gcc_ok and os.path.exists(ibin) and os.path.getsize(ibin) > 0
    for p in (srcp, dumpfile, obin, ibin):
        if os.path.exists(p):
            os.remove(p)
    return ("MATCH" if asm_ok else "DIFF"), ""


# ---------------------------------------------------------------------------
# cmp: 40-case token-level AST diff (mirrors plan/cmp.py) -------------------

def cmp_probe(n, src):
    p = "/tmp/harness_cmp_%s.nelua" % n
    open(p, "w").write(src)
    try:
        our_stdout, our_stderr, _ = run([OUR, "--print-ast", p])
        ora_stdout, ora_stderr, ora_rc = run([ORACLE, "--print-ast", p])
    finally:
        os.remove(p)
    rej = ("syntax error" in ora_stderr) or ora_rc != 0
    our_err = our_stderr.strip() != ""
    if our_err and not rej:
        return "MINE-ERR", our_stderr.strip()[:80]
    if rej and not our_err:
        return "ORACLE_FAIL", "oracle rejects; ours parsed"
    if our_err:
        return "BOTH-ERR", ""
    if norm_m1(toks_mine(our_stdout)) == norm_m1(toks_oracle(ora_stdout)):
        return "MATCH", ""
    return "DIFF", ""


# ---------------------------------------------------------------------------
# corpus walk + regression detection ---------------------------------------

def walk_corpus():
    """Yield (key, path, mode) for every probe under examples/.

    Mode is derived from the path prefix -- the harness walks ONE directory
    (examples/) and nothing is enumerated by hand.
    """
    for d in CORPUS_DIRS:
        for f in sorted(glob.glob(os.path.join(d, "**", "*.nelua"),
                                  recursive=True)):
            rel = os.path.relpath(f, d)
            # neg_<thing>.nelua is the negative-conformance tier (see
            # neg_probe); it is NOT an exec probe (the oracle rejects every
            # one of them), so it must not also be walked as EXEC or every
            # neg probe appears twice.
            if is_neg_probe(rel):
                continue
            if rel.startswith("dump-ast" + os.sep):
                mode = "M1"
            elif rel.startswith("dump-analyzed-ast" + os.sep):
                mode = "M2"
            else:
                mode = "EXEC"
            cname = os.path.basename(d)
            yield os.path.join(cname, rel[:-6]), f, mode


def is_fatal(status, baseline_status):
    """A new crash, a previously-MATCHing probe that is no longer MATCH, or a
    negative probe Nelu accepts where the oracle rejects."""
    if status == "NELU_CRASH":
        return baseline_status != "NELU_CRASH"
    if status == "NELU_ACCEPT":
        return True
    if baseline_status == "MATCH":
        return status != "MATCH"
    return False


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    record = "--record" in sys.argv
    no_build = "--no-build" in sys.argv

    if not no_build:
        ok, msg = build_our()
        if not ok:
            print("BUILD FAILED:\n" + msg)
            return 2
        if msg == "built":
            print("built tmp/nelua")

    baseline = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as fh:
            baseline = json.load(fh)

    results = {}   # key -> {"status":.., "mode":.., "note":..}
    order = []

    # ---- M1: parse-AST ----------------------------------------------------
    m1_matches = m1_diffs = m1_crashes = 0
    m1_baseline_matches = M1_BASELINE_MATCHES
    m1_baseline_diffs = M1_BASELINE_DIFFS
    for key, path, mode in walk_corpus():
        if mode != "M1":
            continue
        status, note = m1_probe(path)
        results[key] = {"status": status, "mode": "M1", "note": note}
        order.append(key)
        if status == "MATCH":
            m1_matches += 1
        elif status == "DIFF":
            m1_diffs += 1
        elif status == "NELU_CRASH":
            m1_crashes += 1

    # ---- M2: analyzed-AST -------------------------------------------------
    m2_matches = m2_diffs = m2_crashes = 0
    for key, path, mode in walk_corpus():
        if mode != "M2":
            continue
        status, note = m2_probe(path)
        results[key] = {"status": status, "mode": "M2", "note": note}
        order.append(key)
        if status == "MATCH":
            m2_matches += 1
        elif status == "DIFF":
            m2_diffs += 1
        elif status == "NELU_CRASH":
            m2_crashes += 1

    # ---- exec: everything else under examples/ ----------------------------
    exec_counts = {}
    for key, path, mode in walk_corpus():
        if mode != "EXEC":
            continue
        status, note = exec_probe(path)
        results[key] = {"status": status, "mode": "EXEC", "note": note}
        order.append(key)
        exec_counts[status] = exec_counts.get(status, 0) + 1

    # ---- NEG: negative conformance (exam/neg_<thing>.nelua) ------------------
    neg_counts = {}
    for d in CORPUS_DIRS:
        for f in sorted(glob.glob(os.path.join(d, "**", "*.nelua"),
                                  recursive=True)):
            rel = os.path.relpath(f, d)
            if not is_neg_probe(rel):
                continue
            cname = os.path.basename(d)
            key = os.path.join(cname, rel[:-6])
            status, note = neg_probe(f)
            results[key] = {"status": status, "mode": "NEG", "note": note}
            order.append(key)
            neg_counts[status] = neg_counts.get(status, 0) + 1

    # ---- cmp: 40 inline cases ---------------------------------------------
    cmp_counts = {}
    for n, src in CMP_CASES:
        key = "cmp/" + n
        status, note = cmp_probe(n, src)
        results[key] = {"status": status, "mode": "CMP", "note": note}
        order.append(key)
        cmp_counts[status] = cmp_counts.get(status, 0) + 1

    # ---- print the table --------------------------------------------------
    print("Nelu conformance harness")
    print("  corpus: exam/ (walked recursively)  |  "
          "oracle: /usr/bin/nelua  |  ours: tmp/nelua")
    print("-" * 78)

    def show_section(title, keys, counts):
        print(title)
        for key in keys:
            r = results[key]
            base = baseline.get(key)
            marker = {"MATCH": "  ", "DIFF": "!!", "NELU_CRASH": "CR",
                      "NELU_REJECT": "RJ", "BOTH_FAIL": "BF",
                      "ORACLE_FAIL": "OF", "SKIP": "SK", "NOT-RUN": "NR",
                      "NO-REF": "NO", "MINE-ERR": "ME", "BOTH-ERR": "BE",
                      "NELU_ACCEPT": "NA", "ORACLE_ACCEPT": "OA"}.get(
                          r["status"], "??")
            note = ""
            if r["note"]:
                note = "  (" + r["note"] + ")"
            if base is not None and base != r["status"]:
                note += "  [was " + base + "]"
            print("  {} {:<42} {}{}".format(marker, key, r["status"], note))
        parts = ["{} {}".format(v, k) for k, v in sorted(counts.items())]
        print("  " + "  ".join(parts))
        print()

    m1_keys = [k for k in order if "dump-ast" in k]
    show_section("M1 parse-AST (dump-ast/, {})".format(len(m1_keys)),
                 m1_keys,
                 {"MATCH": m1_matches, "DIFF": m1_diffs, "NELU_CRASH": m1_crashes})
    m2_keys = [k for k in order if "dump-analyzed-ast" in k]
    show_section("M2 analyzed-AST (dump-analyzed-ast/, {})".format(
        len(m2_keys)), m2_keys,
        {"MATCH": m2_matches, "DIFF": m2_diffs, "NELU_CRASH": m2_crashes})
    cmp_keys = [k for k in order if k.startswith("cmp/")]
    show_section("cmp token-level AST ({} inline cases)".format(len(cmp_keys)),
                 cmp_keys, cmp_counts)
    # ---- CLI: command-line surface conformance ------------------------------
    cli_counts = {}
    # global flagsets (version/config/eval/error): no source file, run once
    for fname, kind, flags in CLI_FLAGSETS:
        if kind not in GLOBAL_KINDS:
            continue
        key = "cli/(global)/" + fname
        status, note = cli_probe_global(kind, flags)
        results[key] = {"status": status, "mode": "CLI", "note": note}
        order.append(key)
        cli_counts[status] = cli_counts.get(status, 0) + 1
    # per-program flagsets (dump/build/obj/lib/roundtrip)
    for pname, psrc in CLI_PROGRAMS:
        for fname, kind, flags in CLI_FLAGSETS:
            if kind in GLOBAL_KINDS:
                continue
            key = "cli/" + pname + "/" + fname
            if kind in ("cround", "asmround"):
                status, note = rt_probe(kind, pname, psrc)
            else:
                status, note = cli_probe(pname, psrc, kind, flags)
            results[key] = {"status": status, "mode": "CLI", "note": note}
            order.append(key)
            cli_counts[status] = cli_counts.get(status, 0) + 1

    exec_keys = [k for k in order if results[k]["mode"] == "EXEC"]
    show_section("exec (exam/ + tests/ + examples/, {})".format(
        len(exec_keys)), exec_keys, exec_counts)
    neg_keys = [k for k in order if results[k]["mode"] == "NEG"]
    show_section("NEG negative conformance (exam/neg_*.nelua, {})".format(
        len(neg_keys)), neg_keys, neg_counts)
    cli_keys = [k for k in order if results[k]["mode"] == "CLI"]
    show_section("CLI command-line surface ({} flagsets x {} programs)".format(
        len(CLI_FLAGSETS), len(CLI_PROGRAMS)), cli_keys, cli_counts)

    # ---- totals + regression detection ------------------------------------
    totals = {}
    for r in results.values():
        totals[r["status"]] = totals.get(r["status"], 0) + 1

    regressions = []
    improvements = []
    new_probes = []
    for key in order:
        st = results[key]["status"]
        base = baseline.get(key)
        if base is None:
            new_probes.append((key, st))
            continue
        if base == st:
            continue
        if st == "MATCH":
            improvements.append((key, base, st))
        else:
            regressions.append((key, base, st))

    fatal = [r for r in regressions if is_fatal(r[2], r[1])] + \
            [(k, None, st) for k, st in new_probes if is_fatal(st, None)]

    print("-" * 78)
    parts = ["{} {}".format(v, k) for k, v in sorted(totals.items())]
    print("TOTAL  " + "  ".join(parts))
    print("  baseline entries: {}   regressions: {}   improvements: {}   "
          "new: {}".format(len(baseline), len(regressions), len(improvements),
                           len(new_probes)))
    if improvements:
        print("  improvements (non-MATCH -> MATCH):")
        for k, was, now in improvements:
            print("    {} {} -> {}".format(k, was, now))
    if regressions:
        print("  regressions:")
        for k, was, now in regressions:
            print("    {} {} -> {}".format(k, was, now))
    if new_probes:
        print("  new (no baseline entry):")
        for k, st in new_probes:
            print("    {} {}".format(k, st))

    if record:
        with open(BASELINE, "w") as fh:
            json.dump({k: results[k]["status"] for k in order}, fh, indent=1,
                      sort_keys=True)
        print("\nrecorded baseline for {} probes -> {}".format(len(order), BASELINE))
        return 0

    if len(baseline) == 0:
        # No baseline to compare against: every probe is a first observation,
        # so nothing can be a regression (a "new crash" only becomes fatal
        # once a baseline exists).  Run --record to capture it.
        print("\nNO BASELINE -- run 'python3 plan/harness.py --record' to "
              "capture it; regression detection is disabled.")
        return 0

    if fatal:
        print("\nFATAL: {} regression(s) from MATCH or new crash.".format(len(fatal)))
        return 1
    print("\nOK: no regression.")
    return 0


if __name__ == "__main__":
    sys.exit(main())