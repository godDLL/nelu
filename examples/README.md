# examples/ - corpus provenance

This directory holds the Nelua programs we compile and run as our test
corpus. It is two tiers deep, and the tiers have different origins. Recording
that here so no future sweep misattributes a file.

## Tier 1: `examples/*.nelua` - upstream's, used by us too

The top-level programs (`brainfuck`, `condots`, `fibonacci`, `gameoflife`,
`helloworld-ddx`, `matmul`, `mersenne-ddx`, `overview`, `record_inheretance`,
`snakesdl`) come from the **original / upstream Nelua project**. They are not
our code; we did not write them.

Two of them (`helloworld`, `mersenne`) carry the `-ddx` suffix — see
"Tagging" below. The suffix is cosmetic: `helloworld-ddx.nelua` is
byte-identical to upstream's `helloworld.nelua`, renamed so the passing test
is findable as an "achievement unlocked" marker without disturbing the
canonical name in any gate that still references it.

We keep them because they are our test corpus: `plan/examples_parity.py`
compiles each one with our compiler and with the oracle `/usr/bin/nelua`
and diffs stdout and exit code. They are the acceptance bar for end-to-end
behaviour, and the DIFFs they produce are triaged in
`plan/examples-diffs-triage.md`.

Treat them as read-only reference for *semantics* (they show what the language
should do) and as a live test target for *parity* (they show where we diverge).

## Tier 2: `examples/www/` - ours, mined from the web

`examples/www/` is **our own extension**. Every program there was written by
or mined for this clean-room reimplementation; none of it is upstream's.

It is a curated comparison corpus: each `www/*.nelua` is compiled with `-b`
through both compilers, run, and its stdout and exit code recorded by hand.
The full table, per-program feature coverage, and verdicts (MATCH / DIFF /
FAIL) live in `examples/www/README.md`. The machine gate over this tier is
`tmp/wwwcheck.py` (115 files, currently **91 PASS / 5 DIFF**).

The `www/` corpus is where a feature is *proven* before it is claimed: one
probe per construct, so a regression has its own file and its own verdict
line. Promote a probe that becomes permanent regression material from `tmp/`
into `examples/www/`; throwaway probes stay in `tmp/`.

## Tier 3: `examples/fuzz/` - ours, oracle-verified algorithms

`examples/fuzz/` is **our own extension** (51 files, tracked): one program
per classic algorithm, each compiled and run through both compilers and
diffed. It is a *regression* corpus — the point is that a change to the
compiler does not break a known-good program — rather than a feature-isolation
corpus. Verdicts recorded by the corpus agent: 22 MATCH / 5 DIFF / 21 CRASH /
2 HANG. The CRASH and HANG entries are the work queue, not failures of the
algorithms.

## Tier 4: `examples/nelu/` - ours, beyond-oracle Nelu extensions

`examples/nelu/` is **our own extension** (53 files, tracked): programs that
use features the oracle 0.2.0-dev does not have. Each was verified
"oracle-rejects / ours-accepts": the oracle refuses to compile it and ours does.
They are the evidence that the Nelu branch (syntactic sugar, missing features,
bug fixes) is a real extension and not just a fork, and they double as
regression material for those extensions.

## Tagging: `-ddx` and `-ffs` suffixes

Some files in tiers 1-4 carry a suffix inserted before `.nelua`. The suffix is
a verdict tag, not part of the program; the file content is unchanged.

- **`-ddx`** ("achievement unlocked") — 154 files across all four tiers. The
  test passes: ours runs it, and in the strict tiers (`spec/`, `tests/`) it
  matches the oracle exactly, crash-for-crash. Tagged by the `-ddx` devil
  (report `plan/devil-ddx-corpus.md`), which classified all 220 `examples/*/**`
  files: MATCH 129, O-REJ 47, DIFF-fail 8, OUR-REJ 30, SKIP 3.
- **`-ffs`** — files the oracle should *not* accept (the oracle rejects them).
  Tagged by a separate devil; report `plan/ffs-corpus.md` when it lands.

A file can legitimately carry both tags (a Nelu extension the oracle rejects is
both "ours runs it" and "OG should not accept"); that is recorded as an overlap
in the report, not silently resolved.

## Why the split matters

- Upstream programs are the *oracle's own* - diffing against them measures how
  close we are to 0.2.0-dev, and they are the honest floor.
- `www/`, `fuzz/`, and `nelu/` programs are *ours* - they are written to
  isolate one construct at a time, so a DIFF pins a single root cause instead
  of a tangle of features.

Both tiers feed the same gates. Neither is decorative.