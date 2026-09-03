#!/usr/bin/env python3
"""www corpus parity: compile each examples/www/**/*.nelua with ours and the
oracle, compare stdout and exit code.  Uses unique paths per file under
$PROJECT/tmp/wwwcheck_tmp/ (the oracle caches --print-ast output by source
name, and a shared out-path leaves stale binaries on silent oracle failure),
and a unique source path per file for the same reason.  No rebuild: uses
tmp/nelua as-is.

Report-only: always exits 0 and prints counts.  Strict exit code is
examples_parity.py's job (it covers examples/*.nelua, the top tier).

ROOT is the project root (parent of plan/), so OUR = ROOT/tmp/nelua and the
corpus is ROOT/examples/www, i.e. the live tree.
"""
import subprocess, os, glob, sys, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUR = os.path.join(ROOT, "tmp", "nelua")
ORACLE = "/usr/bin/nelua"
WWW = os.path.join(ROOT, "examples", "www")
TMPDIR = os.path.join(ROOT, "tmp", "wwwcheck_tmp")


def run(comp, src, out, timeout=30):
    b = subprocess.run([comp, "-b", "-o", out, src],
                       capture_output=True, text=True, timeout=timeout)
    if b.returncode != 0:
        return None, b.returncode, (b.stderr.strip().splitlines()[0]
                                    if b.stderr.strip() else "build-failed")
    r = subprocess.run([out], capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.returncode, None


def main():
    # Recursive: examples/www/ has subdirs (seqtoy/, tetrix/) whose files are
    # part of the www corpus and must be checked too.
    files = sorted(glob.glob(os.path.join(WWW, "**", "*.nelua"), recursive=True))
    if TMPDIR:
        shutil.rmtree(TMPDIR, ignore_errors=True)
        os.makedirs(TMPDIR, exist_ok=True)

    fails = 0
    pas = 0
    total = 0
    for f in files:
        total += 1
        name = os.path.basename(f)
        o = os.path.join(TMPDIR, "wwwo_" + name)
        r = os.path.join(TMPDIR, "wwwr_" + name)
        mo, mrc, me = run(OUR, f, o)
        mr, orc, oe = run(ORACLE, f, r)
        if mo is None and mr is None:
            print(f"  SKIP {name}  both-build-fail")
            continue
        if mo is None:
            print(f"  DIFF {name}  ours-build-fail(rc={mrc}): {me}")
            fails += 1; continue
        if mr is None:
            print(f"  DIFF {name}  oracle-build-fail(rc={orc}): {oe}")
            fails += 1; continue
        if mo == mr and mrc == orc:
            pas += 1
        else:
            fails += 1
            print(f"  DIFF {name}  ours(rc={mrc}) oracle(rc={orc})")
            print(f"     ours  : {mo!r}")
            print(f"     oracle: {mr!r}")

    print(f"\n{pas} PASS / {fails} DIFF (of {total} www files)")


if __name__ == "__main__":
    main()