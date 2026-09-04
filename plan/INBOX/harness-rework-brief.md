# Brief: consolidate the conformance / gating / examples mess into one harness

Status: **brief only -- do not start yet.**  An agent reads this, then stops.
No code, no edits, no gates run.  This exists so the work can be picked up
later with a single unambiguous target.

## 1. Why

The conformance-and-gating surface is scattered across ~12 gate scripts, ~20
`tmp/` corpora, two tiers of `examples/`, and ~55 `plan/` docs, with three
overlapping "coverage" narratives that contradict each other on the same
numbers.  It works (gates are green), but it is not one system, and every new
probe lands in a new place.  We want:

- **one harness** -- a single entry point that builds `tmp/nelua`, then runs
  every comparison we care about, in one command.
- **one coverage doc** -- a single `plan/` document that says, for every
  language element, whether Nelu handles it and how we know.
- **new examples only** -- everything old moves into a `tmp/` folder we try to
  forget about; new probes live in one place.

## 2. What to read first (the mess, in reading order)

1. `plan/GATES.md` -- the existing gate map.  Accurate, and the best starting
   point for what each gate *means*.
2. `plan/cover-corpus.md` -- the newest coverage narrative (44 probes in
   `examples/cover/`, run by `plan/cover_gate.py`).  Currently the cleanest
   single source, but it is only one slice.
3. `plan/nelu-language-coverage-gap.md` -- the older coverage narrative
   (verdicts A/B/C/D over `tmp/cov/`).  Overlaps #2 and disagrees with it on
   some counts.
4. `plan/examples-diffs-triage.md` + `plan/examples-diffs-design.md` --
   how the `examples/*.nelua` DIFFs are triaged.
5. `plan/M2_design.md`, `plan/M3_design.md`, `plan/gate-m1-diffs-design.md`
   -- the AST-gate design rationale.
6. `examples/README.md` -- provenance of the example tiers (upstream's vs
   ours vs mined-from-web).
7. `MAN_NELU.html` (repo root) -- the manual.  It is the reference for what the
   language *is*; the harness measures against the oracle, not the manual, but
   the manual is where a reader starts.
8. `plan/INBOX/MAN_NELU-improvements.md` -- the improvement list that came out of the
   manual.  Some of its items are harness items (e.g. "make stdlib
   end-to-end analyzable").

Then skim the scripts themselves: `plan/cmp.py`, `plan/regress.py`,
`plan/examples_parity.py`, `plan/cover_gate.py`, `plan/cli_conformance.py`,
`plan/wwwcheck.py`, and the `tmp/*.py` helpers (`tmp/cmp_fix.py`,
`tmp/corpus_probe.py`, `tmp/wwwcheck.py`, the `probe_*.py` family).

## 2.6. The plan/ vs tmp/ split (the organizing principle)

Two tiers, and the boundary is the whole point:

- **`plan/` is the durable, git-tracked surface.**  It holds the **ticketing
  system** (`INBOX/`, `WIP/`, `DONE/`, `TICKETS.md`) plus the two deliverables
  this brief produces -- the harness (`plan/harness.py`) and the single coverage
  doc (`plan/coverage.md`).  Everything in `plan/` is committed and survives
  deletion of `tmp/`.
- **`tmp/` is gitignored scratch.**  It holds **everything else**: the old gate
  scripts, the old corpora, the old probes/tests/examples, the old coverage
  docs, the agent workcopies, and the legacy example folders.  It is abandoned
  on purpose -- the point is to stop discovering it.

The agent's job is to *enforce* this split, not just to create the harness:

1. Move every old probe/test/example/corpus/coverage doc/agent workcopy into
   `tmp/` (a single `tmp/legacy/` subtree is fine).  Nothing old stays in
   `examples/`, `lib/`, `lualib/`, `spec/`, or the `plan/` root.
2. Put the ticketing in `plan/INBOX|WIP|DONE` and **git-track it** -- these are
   the durable record.  `plan/*.py` (the harness) and `plan/coverage.md` are
   tracked too.
3. Leave `tmp/` untracked.  Do not commit anything from `tmp/`.
4. `MAN_NELU.html` (repo root) and `src/`, `lib/`, `lualib/`, `spec/` are not
   part of this rework -- do not touch them.

## 3. Target shape

### 3a. One harness

A single command, e.g. `python3 plan/harness.py`, that:

1. rebuilds `tmp/nelua` if stale (the Makefile already builds it there now --
   see the `NELU_OUT` change; do not regress that),
2. runs every comparison we care about,
3. prints one table and exits non-zero only on a *regression* (a previously
   MATCHing probe going DIFF/CRASH, or a new crash).

It subsumes, in order of fineness:

| today | becomes |
|---|---|
| M1 parse-AST gate (`plan/regress.py` over `tmp/corpus_nelua/`) | harness mode |
| M2 analyzed-AST gate (`plan/regress.py` over `tmp/m2_corpus/`) | harness mode |
| token-level cmp (`plan/cmp.py`, 40 inline cases) | harness mode |
| examples parity (`plan/examples_parity.py`, `examples/*.nelua`) | harness mode |
| wwwcheck (`plan/wwwcheck.py`, `examples/www/`) | harness mode |
| cover corpus (`plan/cover_gate.py`, `examples/cover/`) | harness mode |

**CLI conformance is NOT part of this harness.**  It is not language
conformance -- it is flag registration and driver mimicry (`-Y`, `-S`, `-T`,
`-r`, `--print-ppcode`, stdin `-`, short/long form registration, the `lua`
codegen backend), and it is a separate task queue in `NOTE_backlog.md`
("CLI conformance task queue", harness `plan/cli_conformance.py`, 896 cases).
That queue is for a **separate agent launched after `lib/` is done**.  Do not
fold it into this harness and do not let the two conflation counts confuse the
coverage numbers.

Every gate today has its own "rebuild if stale" duplicate; the harness has one.
Every gate today compares against its own recorded baseline in its own format;
the harness has one baseline file and one status vocabulary.

### 3b. One coverage doc

A single `plan/coverage.md` (or similar) that replaces `plan/cover-corpus.md`
and `plan/nelu-language-coverage-gap.md` and the coverage sections of
`plan/GATES.md`.  It must answer, for every language element we track:

- does the oracle accept it?  does Nelu?
- what is the verdict (MATCH / DIFF / REJECT / CRASH / BOTH_FAIL / NOT-RUN)?
- where is the probe that proves it?
- what is the recorded baseline, and when did it last change?

One table, one status vocabulary, one number for "how many MATCH".  No
"README and everywhere it is I can see now, everywhere".

### 3c. New examples only

- Move `examples/cover/`, `examples/www/`, and the top-level `examples/*.nelua`
  into `tmp/` (e.g. `tmp/legacy-examples/`) and forget them -- see §2.6: all old
  probes/tests/examples are `tmp/` scratch, not tracked.  The point is to stop
  discovering them.
- New probes go in **one** place, decided by the harness: probably
  `examples/` (flat, one file per construct) or a single corpus dir the
  harness scans.  Pick one.  No more `examples/cover/` + `examples/www/` +
  `tmp/corpus_nelua/` + `tmp/m2_corpus/` + `tmp/cov/` + `tmp/nelu_probes/` +
  `tmp/probes/` + `tmp/oracle_probe/` + `tmp/gen_probe/` + `tmp/pprobe/` +
  `tmp/rpr/` + `tmp/sp/` + `tmp/tv/` + `tmp/depmod/` ...
- The harness discovers its corpus by walking one directory.  Nothing is
  enumerated by hand in a dozen scripts.

### 3d. The manual and the coverage skits

`MAN_NELU.html` stays -- it is the reference, and it is a deliverable, not a
test artifact.  Do not touch it.

The "coverage skits" (`examples/cover/`, `plan/cover-corpus.md`,
`plan/nelu-language-coverage-gap.md`, and the verdict tables scattered through
`*-design.md` and `*-behavior-design.md`) consolidate into the single
`plan/coverage.md` from 3b.  The old ones move to `tmp/` and are forgotten.

## 4. What goes where (see §2.6)

**To `tmp/` (gitignored scratch, abandoned):**

- All the `tmp/<date>-<task>/` agent workcopies -- already scratch, already
  forgotten, but delete the ones that are clearly superseded.
- The old corpora named in 3c (`tmp/corpus_nelua/`, `tmp/m2_corpus/`,
  `tmp/cov/`, `tmp/nelu_probes/`, `tmp/probes/`, `tmp/oracle_probe/`,
  `tmp/gen_probe/`, `tmp/pprobe/`, `tmp/rpr/`, `tmp/sp/`, `tmp/tv/`,
  `tmp/depmod/`, ...).
- The old gate scripts named in 3a (`plan/cmp.py`, `plan/regress.py`,
  `plan/examples_parity.py`, `plan/cover_gate.py`, `plan/cli_conformance.py`,
  `plan/wwwcheck.py`) -- replaced by the harness.  Keep them in `tmp/` for
  reference for one cycle, then delete.
- The `tmp/*.py` helper scripts (probe families, survey scripts, `m1gate_sim`,
  etc.) -- superseded by the harness.
- The old coverage docs (`plan/cover-corpus.md`,
  `plan/nelu-language-coverage-gap.md`) -- replaced by `plan/coverage.md`.
- The old examples (`examples/cover/`, `examples/www/`, top-level
  `examples/*.nelua`) -- see 3c.

**Stays in `plan/` and is git-tracked (the durable surface):**

- The ticketing system (`INBOX/`, `WIP/`, `DONE/`, `TICKETS.md`).
- The harness (`plan/harness.py`) and the coverage doc (`plan/coverage.md`).

**Not touched:** `src/`, `lib/`, `lualib/`, `spec/`, `MAN_NELU.html`.

## 5. Acceptance criteria

1. `python3 plan/harness.py` runs end to end, builds `tmp/nelua` once, prints
   one table, exits 0 on no regression.
2. Every probe the old gates ran is still run (no coverage lost), and the
   harness reports the same MATCH/DIFF/CRASH verdicts the old gates reported
   on the current tree -- so the harness can be trusted as a drop-in.
3. Exactly one corpus directory; the harness walks it, nothing enumerated by
   hand.
4. Exactly one `plan/coverage.md`; no other `plan/` doc claims to be the
   coverage narrative.
5. Old probes/tests/examples/corpus/coverage docs are in `tmp/` and not
   discovered by any gate.
6. **The ticketing is git-tracked in `plan/`** (`INBOX/`, `WIP/`, `DONE/`,
   `TICKETS.md`, `plan/harness.py`, `plan/coverage.md`).  Nothing from `tmp/`
   is committed.  Work in an isolation copy under
   `tmp/<date>-<time>-harness-rework/`; never touch live `src/`, never commit a
   `src/` change.  The coordinator integrates.

## 6. Out of scope

- **CLI conformance is not language conformance and is not in this harness.**
  Flag registration and driver mimicry live in the "CLI conformance task queue"
  section of `NOTE_backlog.md` (harness `plan/cli_conformance.py`, 896 cases)
  and are for a separate agent launched after `lib/` is done.  Keep the two
  counts separate; do not let CLI DIFFs pollute the language coverage numbers.

- Fixing any DIFF or CRASH.  The harness measures; it does not repair.  The
  remaining open gap is `record-literal-typed.nelua` (typed record literal
  mis-lowers to `struct nlrec0`); that is a `src/cgen.nim` fix, not a harness
  task.
- Rewriting `MAN_NELU.html`.
- Deciding which language elements to implement next -- that is
  `plan/INBOX/MAN_NELU-improvements.md`'s job, and it stays separate.

## 7. Handoff

When the agent finishes, the coordinator gets: the harness script, the
coverage doc, the new corpus directory, the ticketing in `plan/INBOX|WIP|DONE`,
and the list of what was moved to `tmp/`.  Then the coordinator runs the
harness on the live tree, confirms the verdicts match the old gates, rolls the
old stuff up into `tmp/` permanently, and only then commits the `plan/` surface
(ticketing + harness + coverage doc) under the repo identity
(`Cleanroom <agent@nelua-lang>`).
`tmp/`.  Then the coordinator runs the harness on the live tree, confirms the
verdicts match the old gates, and only then rolls the old stuff up into
`tmp/` permanently.
