# Repairing the golden set, and bucketing what the jar cannot reproduce

Measured 2026-09-05. Companion to `m3-simulation-gate.md` (which this corrects in two places) and
tracker task #48. Every number was produced by a command in this document.

---

## Summary

| | before | after |
|---|---:|---:|
| golden index entries | 1,392 | **1,391** |
| `.table` files on disk | 1,391 | **1,391** |
| unsound baselines excluded by the gate | 3 | **0** |
| `rig.py` pass / fail | 1,338 / 51 *(of 1,389)* | **1,343 / 48** *(of 1,391)* |
| real port defects among the failures | not separable | **12** |

The denominator moved *down* by one and that is the honest direction: one corpus case has no
oracle at all, because upstream crashes on it.

**The two `rig.py` rows are not directly comparable and should not be quoted as a +5.** The before
run used `--jobs 8 --timeout 180` on a machine at load average 60 and four of its 51 "failures"
were timeouts; the after run used `--jobs 6 --timeout 300`. See §5; the honest statement is that
the repair changed the *denominator and its soundness*, and the defect count is §4's 12.

---

## 1. The three known defects, and a fourth the repair exposed

`rig.py`'s preflight was already excluding two baselines loudly. Confirmed both, exactly as
recorded:

```
index entries 1392 · files on disk 1391 · names carrying the digest 0
case collisions: ['3.0.0__case-167.circ__Ctrl.table', '3.0.0__case-167.circ__ctrl.table']
  both st_ino 29754548          <- one file
ragged: ('3.5.0__case-383.circ__truc.table', 65655)   <- not 2^n+1
```

**0 of 1,392 names carried the sha256 digest**, so `golden_name`'s disambiguator, which exists
precisely to prevent this, had never been load-bearing, and `TruthTableGoldenTests.locate()`'s
digest branch was dead code.

A third check I added while hardening the generator found a **third** damaged baseline that
neither name-based check can see. The index records the sha256 of each capture, so the on-disk
bytes can be compared against it:

```
content drift: 2
    2.7.0__case-155.circ__main.table
    3.0.0__case-167.circ__Ctrl.table   (the collision, found again)
```

The second of those has a valid name and a valid `2^n + 1` line count, and is wrong anyway. Cause: the
generator writes `.table` files as each job finishes but `_inventory.json` only at the very end, so
**a run killed part-way leaves files newer than the hashes recorded for them.** That is invisible
for a deterministic oracle, a rewrite reproduces the same bytes, so drift is only *observable* on
the nondeterministic ones, which is why both drifted files are exactly those.

---

## 2. The truncated baseline is not a truncated capture — the jar crashes

`m3-simulation-gate.md` §8b reads: *"The oracle was captured from a run that stopped part-way"*,
i.e. harness flakiness, with a suggested fix of a shape assertion at capture time. The shape
assertion is right and is now in. **The diagnosis is wrong.**

The new assertion fired on the very first regeneration attempt, on a fresh capture:

```
TRUNCATED 3.5.0__case-383.circ::truc: 65653 lines is not 2^n+1; not written
```

Running the jar by hand with stderr attached says why:

```
$ java -jar logisim-evolution-4.1.0-all.jar --toplevel-circuit truc -tty table 3.5.0__case-383.circ
exit=255   stdout lines: 65654
java.lang.NullPointerException: Cannot invoke "java.lang.Thread.isAlive()" because "data.thread" is null
	at com.cburch.logisim.std.io.extra.Buzzer.propagate(Buzzer.java:255)
	at com.cburch.logisim.circuit.Propagator.propagate(Propagator.java:178)
	at com.cburch.logisim.gui.start.TtyInterface.doTableAnalysis(TtyInterface.java:428)
```

The jar dies in `Buzzer.propagate` partway through a 262,145-row table, **having already streamed
~65,000 perfectly valid rows to stdout**, and exits 255. It dies at a different row every time,
**65,653 / 65,654 / 65,655** across three runs, so the truncation is not even stable.

### The root cause is one unread return code

```python
p = subprocess.run(cmd, ..., timeout=timeout)
return p.stdout                       # <- returncode never examined
```

`run_java` returned stdout regardless of exit status, so a crashed run was **indistinguishable from
a complete one** and its partial table was written into the golden set as an oracle. Healthy
oracles exit 0 (verified on three), so the signal was there and simply had no reader.

This is the same family as the jar's `--test-fpga` trap already in `objectives.md`, *"a drivable
entry point that writes nothing and exits 0 looks exactly like agreement"*, with the nastier
variant that here it writes a great deal, and all of it looks right.

**No oracle exists for `3.5.0__case-383.circ::truc`, so it is dropped rather than re-captured.** 1,392 → 1,391.
A case upstream cannot produce is not a case the port can be scored on.

---

## 3. What the generator now refuses to do

`tools/difftest/rig.py --regenerate` gained four assertions. `tools/difftest/selftest_regenerate.py`
proves **each one can fire**, against the historical shape, because a generator that silently does
nothing looks exactly like a clean one: this project's own rule, earned on the `guard f.count >= 6`
gate and the empty-implementation scan that returned a false zero.

| assertion | fires when | self-test |
|---|---|---|
| no two jobs claim one path, **case-folded** | two circuits map to one file on APFS | A: digest stripped → aborts before any JVM starts |
| the output path must not already exist (`O_CREAT\|O_EXCL`) | a same-run collision wins a race | B: with the digest, two distinct inodes |
| line count is `2^n + 1` **before** writing | a capture was cut short | C: 100 lines rejected, not written, exit 1 |
| the JVM exited 0 | the jar crashed mid-table | §2, live |

A fifth property is not an assertion but mattered just as much: **a scoped `--filter` run used to
destroy the index.** `index` started empty and was written back wholesale, so regenerating three
bad baselines would have discarded the other 1,389; turning a small repair into a multi-hour
re-capture. Scoped runs now merge (self-test D).

`compare()`'s preflight also gained the content check from §1.

### Verified after regenerating the three repairable baselines

```
index entries 1391 · .table files 1391
entries sharing an inode  0
case-folded collisions    0
line counts not 2^n+1     0
content drift             0
```

and the repaired oracle is right, checked against an independent record rather than against itself.
`m3-simulation-gate.md` §8a states the live jar prints `start ready mul_rdy clk store mul_start`
with outputs `0 E` for `Ctrl`, against the collision's `clk start ready mul_rdy store mul_start` /
`U U`. The regenerated baseline:

```
start ready mul_rdy clk store mul_start
    0     0       0   0     0         E
```

Exactly as predicted, and `ctrl` keeps its own distinct output in its own file.

---

## 4. Bucketing what Java cannot reproduce (#48)

### Bucket on observed variation, never on static reachability

The tempting detector is static: find every circuit that places a `Random` with `seed` absent or 0,
transitively through subcircuits. **That detector was written and it is wrong.** It flagged
`3.6.0__case-458.circ::MoveCore`, which then passed byte-exactly once the unrelated ROM
port-geometry defect was fixed. A seed-0 `Random` on the schematic does not imply nondeterministic
*output*: whether it reaches a column depends on what is downstream of it, which is
circuit-dependent and not decidable from the placement.

`tools/difftest/nondet.py` therefore hashes **N real runs of the jar over the same bytes**, which is
how the 3.3.0__case-075.circ case was originally diagnosed. Validated before use, on two cases whose answer was
already documented, `3.3.0__case-075.circ::Datapath` (3 distinct hashes) and `golden-08.circ::main` (stable), and
on the crash path (`3.5.0__case-383.circ::truc` → `crash`, and the tool refuses to write a file when nothing
usable was captured).

Over the 48 surviving `rig.py` failures, 5 runs each, 240 JVM invocations:

| jar class | count |
|---|---:|
| `label`: differs, identical once `_<8 hex>` is masked | 43 |
| `stable`; all 5 runs identical | 4 |
| `value`; differs even after masking (seed-0 `Random`) | 1 |

### `label` is not an excuse, and treating it as one is the documented mistake

**This is the trap `m3-simulation-gate.md` §6 already fell into and corrected.** The classes above
describe how the *jar* varies. They say nothing about whether the *port* agrees. A case can be
`label`-class **and** have a genuine body divergence; the random label alone is enough to make
golden ≠ port, so it never reaches the UUID bucket and its real difference is never examined. That
is precisely how 8 defects hid.

So `tools/difftest/classify.py` does the comparison that actually decides it: run the port, mask
every `_<8 hex>` suffix out of **both** sides, diff the rest.

| verdict | count |
|---|---:|
| `label-only`; port matches Java once the label is masked | 35 |
| **`PORT-DEFECT`: genuine divergence** | **12** |
| `oracle-unreproducible`, seed-0 `Random` | 1 |

**The 12 are exactly §7b's 11 remaining defects, plus `3.0.0__case-167.circ::Ctrl`.** That is a clean
cross-validation of the whole pipeline: an independent investigation listed 11, and repairing the
collision surfaced the twelfth.

### The seed-0 `Random` class is one oracle, not six — and the suite cannot see it

`m3-simulation-gate.md` §4 puts the class at *"6 of 1,392 oracles, across 2 corpus files … 4 sit
inside the suite's attempted set and can never pass."* Those six were counted by the static
reachability search. Measured by re-running the jar, the class is **1**:

| | static estimate (§4) | measured |
|---|---:|---:|
| oracles whose values move run to run | 6 | **1** |
| of those, inside `TruthTableGoldenTests`' attempted set | 4 | **0** |

The five in `3.6.0__case-458.circ` pass byte-exactly; they are the `MoveCore` lesson, and the ROM fix
is what made them pass. The one that really moves, `3.3.0__case-075.circ::Datapath`, is **131,073 rows**, so it
is above the suite's 4,096-row cap and the suite skips it for size.

So the suite's `oracle not reproducible by the jar` line reads **0**, and that is the correct
answer rather than an inert bucket. Because those two look identical, the scoreboard now prints
how many cases it loaded and how many are value-class alongside the count. A bucket that can only
ever report zero, silently, is the shape of gate this project has been bitten by three times.

### The collision was hiding a real defect, not merely a stale oracle

§6 classified `Ctrl` as *"jar reproduces the port, golden is stale → oracle defect"*: the single
entry in that row. With the oracle corrected, the port still disagrees:

```
line 2: java=    0     0       0   0     0         E
        swift=  0     0       0   0     1         E          <- `store`
```

So that row was a misattribution. Repairing the golden set did not just fix a denominator; it
converted a wrongly-excused case into a correctly-attributed defect. **A wrong oracle can hide a
real bug as easily as it can invent a fake one**, and only one of those two failure modes is
usually looked for.

---

## 5. A measurement artifact worth knowing: the run is load-sensitive

The before/after failure sets differ by more than the repair explains. Diffing them:

```
was failing, now passing                     newly failing
  3.7.2__case-526.circ::test        …3.0.0__case-167.circ::Ctrl
  3.7.2__case-543.circ::rv32i_regbank
  4.0.0__case-387.circ::ALU
  4.1.0__case-113.circ::ALU1
```

`Ctrl` is explained above. **The other four are timeouts, not defects.** The baseline ran
`--jobs 8 --timeout 180` while two other agents were building and sweeping, load average 60, and
four large cases exceeded 180 s. At `--jobs 6 --timeout 300` they complete and match.

`rig.py` scores a timeout identically to a mismatch, so on a loaded machine the gate silently
invents defects. Quote the flags with the number, and prefer a generous timeout: the four cost
nothing but wall-clock, whereas chasing four phantom defects costs a session.

Related, and cheaper to hit: **`--cli` must be an absolute path.** `run_swift` executes with
`cwd=dirname(circ)`, so a relative path is never found and *every* case fails; a `pass 0 · fail
1389` that reads as total collapse. That happened here on the first attempt and cost a full sweep.
`classify.py` now rejects a relative `--cli` outright.

Also seen once: a full sweep killed externally, leaving **exit 144 and a zero-byte output file**.
Empty output is not a result. Assert the file is non-empty before reading a number off it.

---

## 6. `TruthTableGoldenTests` — floor raised, and the UUID bucket no longer hides bodies

The ratchet was `1128` against a measured ~1,239: stale by over 100, so it could not have caught a
regression. **Raised to 1,250.**

Derived from the `rig.py` sweep first, then confirmed by running the suite (3,295 s). Prediction
and measurement agree on every line, which is the same cross-check §6 used and is worth repeating
because it is cheap and the two harnesses have four structural differences:

| | predicted | measured |
|---|---:|---:|
| golden oracles / skipped / attempted | 1391 / 109 / 1282 | **1391 / 109 / 1282** |
| byte-exact match | 1250 | **1250** |
| match but for a random UUID label | 24 | **24** |
| oracle not reproducible by the jar | 0 | **0** |
| mismatched | 8 | **8** |

`would not load 0 · run threw 0`, and 6 of the 8 mismatches are hierarchical. The suite passes at
the new floor.

Note what the floor asserts: **byte-exact matches only.** The UUID and unreproducible buckets are
reported but deliberately not floored, because their membership turns on a random label and on
re-running the jar; neither of which is a property of the port.

The more important change is to the bucket itself. It used to require **every line after the header
to be byte-identical** before awarding `unreproducibleLabel`. That is strict in the *classifier* and
the opposite of strict in the *gate*: a case whose header carries a UUID and whose body also
diverges failed that test, fell through to `.mismatch`, and was then described by `firstDifference`
; which reported **line 1, the random header**, and never named the real divergence. The suite was
therefore incapable of pointing at any of the 8 defects §6 found by hand.

Both the classifier and the diagnostic now mask the suffix out of **both** sides. Nothing that used
to be a match becomes one, the bucket is still awarded only when the masked texts are exactly
equal, but a body divergence is now reported at the line that actually differs.

A third outcome, `unreproducibleOracle`, carries the seed-0 `Random` class, read from
`tools/difftest/nondeterministic.json`. It is checked **after** byte-equality and the label bucket,
so a listed case that happens to agree still scores as a match; the `MoveCore` lesson encoded in
the control flow. When the file is missing the bucket is inert, and the scoreboard says so out
loud rather than reporting a confident zero.

---

## 7. What to do next

1. **The 12 remaining defects.** Eleven are §7b's `U`-vs-`E` bus-resolution family, running in both
   directions; start at `2.7.1__case-514.circ::main`, which is 3 rows. The twelfth is `Ctrl`'s `store` column.
2. **`Buzzer.propagate`'s NPE is upstream's bug, and the port should be checked against it.** The
   port must decide what it does with `3.5.0__case-383.circ::truc`; matching a crash is not required, but
   diverging silently from one is worth knowing about. Note D5/D9: the port's `Buzzer` has no
   thread at all.
3. **Re-run `nondet.py` whenever the failure set changes.** It is scoped to current failures by
   design: probing all 1,391 would be 7,000 JVM invocations to learn nothing about the cases that
   already pass.
