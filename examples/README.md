# examples/ — corpus provenance

This directory holds the Nelua programs we compile and run as our test
corpus. It is two tiers deep, and the tiers have different origins. Recording
that here so no future sweep misattributes a file.

## Tier 1: `examples/*.nelua` — upstream's, used by us too

The top-level programs (`brainfuck`, `condots`, `fibonacci`, `gameoflife`,
`helloworld`, `matmul`, `mersenne`, `overview`, `record_inheretance`,
`snakesdl`) come from the **original / upstream Nelua project**. They are not
our code; we did not write them.

We keep them because they are our test corpus: `plan/examples_parity.py`
compiles each one with our compiler and with the oracle `/usr/bin/nelua`
and diffs stdout and exit code. They are the acceptance bar for end-to-end
behaviour, and the DIFFs they produce are triaged in
`plan/examples-diffs-triage.md`.

Treat them as read-only reference for *semantics* (they show what the language
should do) and as a live test target for *parity* (they show where we diverge).

## Tier 2: `examples/www/` — ours, mined from the web

`examples/www/` is **our own extension**. Every program there was written by
or mined for this clean-room reimplementation; none of it is upstream's.

It is a curated comparison corpus: each `www/*.nelua` is compiled with `-b`
through both compilers, run, and its stdout and exit code recorded by hand.
The full table, per-program feature coverage, and verdicts (MATCH / DIFF /
FAIL) live in `examples/www/README.md`. The machine gate over this tier is
`tmp/wwwcheck.py` (22 files, currently 22 PASS / 0 DIFF).

The `www/` corpus is where a feature is *proven* before it is claimed: one
probe per construct, so a regression has its own file and its own verdict
line. Promote a probe that becomes permanent regression material from `tmp/`
into `examples/www/`; throwaway probes stay in `tmp/`.

## Why the split matters

- Upstream programs are the *oracle's own* — diffing against them measures how
  close we are to 0.2.0-dev, and they are the honest floor.
- `www/` programs are *ours* — they are written to isolate one construct at a
  time, so a DIFF pins a single root cause instead of a tangle of features.

Both tiers feed the same gates. Neither is decorative.