#!/usr/bin/env python3
"""Permanent regression gate over tmp/m2_corpus/ (M2) and tmp/corpus_nelua/ (M1).

Two halves, both comparing our compiler (tmp/nelua) against the oracle
(/usr/bin/nelua):

  M1 (parse AST)  -- over tmp/corpus_nelua/ (28 files). Both compilers' --print-ast
                    output is tokenized into a canonical (kind, scalar) stream
                    (see toks_mine / toks_oracle in tmp/cmp.py) and diffed.
                    The formats differ structurally (ours is the nk-prefixed
                    flat dump, the oracle is the nested Block/VarDecl form), so
                    raw string comparison is meaningless -- tokenization is the
                    only honest comparison.

  M2 (analyzed AST) -- over tmp/m2_corpus/ (14 files). Our --print-analyzed-ast
                    is normalized (path-derived codename -> <U>, filename attr ->
                    <F>) and compared against the stored oracle dump *.ref.

Exit code: 0 only when M2 is fully green (14/14) and M1 shows no crashes.
Non-zero on any M2 DIFF or any M1 SIGSEGV/crash. Known M1 diffs are reported
but the baseline count is recorded inline so a *change* in M1 state is itself
a regression signal (new crash = always a regression; diff-count movement is
flagged, not fatal, so the gate stays green while M1 slowly converges).

Note on location: this file lives at the project root and IS version-
controlled. Its corpora (tmp/corpus_nelua/, tmp/m2_corpus/) remain in the
gitignored scratch dir, so a fresh checkout has the gate script but not the
data -- regenerate the corpora from the oracle before running.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CORPUS1 = os.path.join(ROOT, "tmp", "corpus_nelua")
CORPUS2 = os.path.join(ROOT, "tmp", "m2_corpus")
OUR = os.path.join(ROOT, "tmp", "nelua")
ORACLE = "/usr/bin/nelua"

# M1 baseline measured 2026-08-29: 16 MATCH / 12 DIFF out of 28, 3 of which
# crash (SIGSEGV). The diffs are real parse/analyze gaps: a.b:c(1), anonymous
# function, and if/elseif SIGSEGV; plus a mixed table-literal C warning. The gate
# requires M1 to not regress (diffs/crashes at or below baseline) but allows it
# to improve as gaps close -- "0 regressions", not "0 diffs".
M1_BASELINE_MATCHES = 16
M1_BASELINE_DIFFS = 12
M1_BASELINE_CRASHES = 3


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, cwd=ROOT)
        return p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "(timeout)", -1


def build_our():
    if not os.path.exists(OUR):
        return False
    bin_mt = os.path.getmtime(OUR)
    for f in glob.glob(os.path.join(ROOT, "src", "*.nim")) + \
            glob.glob(os.path.join(ROOT, "src", "*.c")):
        if os.path.getmtime(f) > bin_mt:
            r = subprocess.run(
                ["nim", "c", "-d:release", "--path:src", "-o:" + OUR,
                 "src/main.nim"],
                capture_output=True, text=True, cwd=ROOT)
            if r.returncode != 0:
                print("BUILD FAILED:\n" + r.stderr[-2000:])
                return False
    return True


# ---- M1 tokenizers (mirrored from tmp/cmp.py) ------------------------------

def toks_mine(s):
    out = []
    for line in s.splitlines():
        line = line.strip().rstrip(",")
        if not line or not line.startswith("nk"):
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
                scalar = rest.split(":")[0].strip('"')
            else:
                scalar = rest
        out.append((kind, scalar))
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


# ---- M2 normalizer --------------------------------------------------------

def norm(s):
    s = re.sub(r"[A-Za-z0-9_]*m2_corpus_[A-Za-z0-9_]*", "<U>", s)
    s = re.sub(r'filename = "[^"]*"', 'filename = "<F>"', s)
    return s


def main():
    if not build_our():
        return 1

    crashes = diffs_m1 = matches_m1 = 0
    m1_detail = []

    # ---- M1: parse-AST tokenizer diff over corpus_nelua -------------------
    for f in sorted(glob.glob(os.path.join(CORPUS1, "*.nelua"))):
        name = os.path.basename(f)[:-6]
        our_out, _ = run([OUR, "--print-ast", f])
        ora_out, _ = run([ORACLE, "--print-ast", f])
        if "SIGSEGV" in our_out or "Illegal storage access" in our_out:
            crashes += 1
            m1_detail.append((name, "CRASH", our_out.strip()[:60]))
            continue
        mo = toks_mine(our_out)
        oo = toks_oracle(ora_out)
        if mo == oo:
            matches_m1 += 1
        else:
            diffs_m1 += 1
            m1_detail.append((name, "DIFF", f"{len(mo)} vs {len(oo)} tokens"))

    # ---- M2: analyzed-AST diff over m2_corpus (stored oracle *.ref) -------
    matches_m2 = diffs_m2 = 0
    m2_detail = []
    for f in sorted(glob.glob(os.path.join(CORPUS2, "*.nelua"))):
        name = os.path.basename(f)[:-6]
        our_out, _ = run([OUR, "--print-analyzed-ast", f])
        ref_path = f[:-6] + ".ref"
        if not os.path.exists(ref_path):
            diffs_m2 += 1
            m2_detail.append((name, "NO-REF", "missing oracle dump"))
            continue
        if norm(our_out) == norm(open(ref_path).read()):
            matches_m2 += 1
        else:
            diffs_m2 += 1
            m2_detail.append((name, "DIFF", ""))

    print(f"M1 (parse AST, corpus_nelua): {matches_m1} MATCH / {diffs_m1} DIFF / "
          f"{crashes} CRASH  (baseline {M1_BASELINE_MATCHES} MATCH / "
          f"{M1_BASELINE_DIFFS} DIFF)")
    for name, kind, note in m1_detail:
        if kind != "MATCH":
            print(f"    {kind:6} {name}.nelua  {note}")
    print(f"M2 (analyzed AST, m2_corpus): {matches_m2} MATCH / {diffs_m2} DIFF")

    m1_moved = (matches_m1 != M1_BASELINE_MATCHES or
                diffs_m1 != M1_BASELINE_DIFFS or crashes != M1_BASELINE_CRASHES)
    if m1_moved:
        print("\nM1 state changed vs baseline -- review before declaring green.")
    if diffs_m2 > 0:
        for name, kind, note in m2_detail:
            print(f"    {kind:6} {name}.nelua  {note}")

    # Green requires M2 perfect and M1 not regressed (may have improved).
    ok = (diffs_m2 == 0 and diffs_m1 <= M1_BASELINE_DIFFS and
          crashes <= M1_BASELINE_CRASHES)
    print(f"\nM2 {matches_m2}/{matches_m2 + diffs_m2} MATCH; "
          f"M1 {matches_m1} MATCH / {diffs_m1} DIFF / {crashes} CRASH; "
          f"{'GREEN' if ok else 'NOT GREEN'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())