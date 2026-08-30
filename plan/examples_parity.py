#!/usr/bin/env python3
"""End-to-end execution-parity gate over examples/.

Runs every standalone program in examples/ through both our compiler
(tmp/nelua, rebuilt as needed) and the oracle (/usr/bin/nelua), and compares
stdout + exit code. This is the existing-program execution gate (§11.0c):
regress.py compares AST/analysis dumps; this compares what programs actually
do when run.

SKIPped examples are not standalone programs (benchmark loop, illustrative
snippet, interactive SDL game) -- the oracle itself does not produce a clean
exit for them, so they are out of scope for this gate.

Exit code: 0 only when every runnable example MATCHes. Non-zero on any DIFF.
"""
import os
import sys
import glob
import subprocess

# Lives in plan/ now, so ROOT is the project root (parent of plan/).
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = os.path.join(ROOT, "examples")
TMP = os.path.join(ROOT, "tmp")
OUR = os.path.join(TMP, "nelua")
# Run SDL programs headlessly: this gate sweeps *every* example before
# classifying, and the SDL ones (snakesdl/condots/overview) would otherwise
# open a real window and sit there until killed. The dummy video driver
# still exercises the code path and exits normally. Override per run with
# SDL_VIDEODRIVER=display if you actually want the window.
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")

ORACLE = "/usr/bin/nelua"

# Examples that are not runnable standalone programs; the oracle does not
# produce a clean exit for them either, so they are out of scope for this gate.
SKIP = {
    "condots": "benchmark loop; runs forever (FPS counter), killed by timeout",
    "snakesdl": "interactive SDL game loop; runs forever, killed by timeout",
    "overview": "illustrative, not a standalone program (oracle exits 1)",
}

# A tracked source file newer than the binary means the binary is stale.
TRACKED = glob.glob(os.path.join(ROOT, "src", "*.nim")) + \
    glob.glob(os.path.join(ROOT, "src", "*.c"))


def run(cmd, timeout=12):
    """Run a command, returning (combined stdout+stderr, exit code)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, cwd=ROOT)
        return p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "(timeout)", -1


def build_our_compiler():
    """Rebuild tmp/nelua when the binary is missing or stale vs src/."""
    need = not os.path.exists(OUR)
    if not need:
        bin_mt = os.path.getmtime(OUR)
        for f in TRACKED:
            if os.path.getmtime(f) > bin_mt:
                need = True
                break
    if need:
        r = subprocess.run(
            ["nim", "c", "-d:release", "--path:src", "-o:" + OUR, "src/main.nim"],
            capture_output=True, text=True, cwd=ROOT)
        if r.returncode != 0:
            print("BUILD FAILED:\n" + r.stderr[-2000:])
            sys.exit(1)
    return True


def classify(name, our_out, our_exit, oracle_out, oracle_exit):
    if name in SKIP:
        return "SKIP"
    # Trailing-whitespace differences are not parity breaks.
    if our_out.rstrip() == oracle_out.rstrip() and our_exit == oracle_exit:
        return "MATCH"
    return "DIFF"


def main():
    build_our_compiler()
    files = sorted(glob.glob(os.path.join(EXAMPLES, "*.nelua")))
    matches = diffs = skips = 0
    for f in files:
        name = os.path.basename(f)[:-6]
        our_out, our_exit = run([OUR, f])
        oracle_out, oracle_exit = run([ORACLE, f])
        verdict = classify(name, our_out, our_exit, oracle_out, oracle_exit)
        if verdict == "SKIP":
            print(f"  SKIP {name}.nelua           {SKIP.get(name, '')}")
            skips += 1
        elif verdict == "MATCH":
            print(f"  MATCH {name}.nelua")
            matches += 1
        else:
            print(f"  DIFF  {name}.nelua          "
                  f"ours(exit={our_exit}) oracle(exit={oracle_exit})")
            print(f"         ours  : {our_out[:140]!r}")
            print(f"         oracle: {oracle_out[:140]!r}")
            diffs += 1
    print(f"\n  {matches} MATCH / {diffs} DIFF / {skips} SKIP  "
          f"(of {len(files)} examples)")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())