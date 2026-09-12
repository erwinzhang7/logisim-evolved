# What is left of the M3 simulation gate

Measured 2026-09-05. Every number below was produced by a command in this document; nothing is
carried over from an earlier session's notes, because most of what this file corrects came from
doing exactly that.

Companion to `docs/objectives.md` (M3) and tracker tasks #28 and #14.

---

## 0. Two things to fix before you measure anything

### Do not pipe a long gate run through `tail`

The first full rig run in this session finished with **exit 0 and completely empty output**, which
reads as "nothing to report". It was not: `rig.py` was killed part-way, and the `0` came from
`tail` at the end of the pipeline, not from the rig. This is the same class of trap as the jar's
`--test-fpga`, and the project's own note about `$?` from a pipeline being the last command's.

Run the gate straight into a file and assert the file is non-empty before reading a number off it.

---

## 1. Cost, and why this is measured with the release binary

`rig.py` and `TruthTableGoldenTests` both drive a **debug** build. Over the whole corpus that is
not merely slow, it is slow enough to stop the measurement happening: a full debug sweep reached
**100 of 1,392 cases in ~30 minutes** and was abandoned.

A release build of `logisim-cli` was made and **proved equivalent before being trusted**: 44
stratified cases (25 small, 15 medium, 4 over 4,096 rows), of which **41 were byte-identical** and
all 3 exceptions are nondeterministic under *any* binary (section 4). Build mode was ruled out
directly rather than assumed: three consecutive *release* runs of the one non-UUID exception
produced three different hashes.

```sh
swift build -c release --product logisim-cli
```

---

## 2. The corpus is 97% invisible to the swift-test gate

`TruthTableGoldenTests` caps at `LOGISIM_M3_MAX_ROWS = 4096` and skips 110 oracles. `objectives.md`
records the honest headline as 67.9% vs the flattering 73.7%, counting *oracles*. Counting **rows**
is much worse, and rows are what a simulation gate actually checks:

| | oracles | rows |
|---|---:|---:|
| attempted (≤ 4,096 rows) | 1,282 | 222,728 |
| **skipped (> 4,096 rows)** | **110** | **7,385,316** |
| total | 1,392 | 7,608,044 |

**The 110 skipped oracles carry 97.1% of every row in the corpus.** Median oracle is 17 rows; the
largest is 262,145. So the suite's headline is computed over 2.9% of the corpus by row, and it is
the *wide* tables, the ones with enough input bits to expose a masked shift, an overflow, or a
`Value` width-boundary defect, that are outside it. `rig.py` does not have this cap and is
therefore the stronger of the two gates on exactly the axis that matters.

```sh
python3 - <<'EOF'
import json, statistics
idx = json.load(open('$LOGISIM_CORPUS/golden/_inventory.json'))
rows = sorted(v['lines'] for v in idx.values())
big = [r for r in rows if r > 4096]
print(len(rows), statistics.median(rows), max(rows))
print(len(big), sum(big), sum(rows))
EOF
```

---

## 3. The two gates are not measuring the same thing — four causes, all structural

Both drive the same code (`StdLibraries.registerAll()` → `Loader().openLogisimFile` →
`TruthTableRun.run`), so a disagreement is not a code difference. It is one of these four, and
each one is worth knowing before comparing their numbers:

| # | difference | direction | size |
|---|---|---|---|
| 1 | **Row cap.** Suite skips > 4,096 rows; `rig.py` has no cap. | suite scores fewer cases | 110 oracles, 97.1% of rows |
| 2 | **UUID-label bucket.** The suite gives `generateValidVHDLLabel`'s random suffix its own outcome; `rig.py` compares bytes, so those are plain failures. | rig fails more | ~17 oracles |
| 3 | **`#Soc` registration.** `logisim-cli/main.swift` calls `SocLibrary.registerBuiltinTools()`; `TruthTableGoldenTests` calls only `StdLibraries.registerAll()`. A SoC placement therefore resolves under the rig and becomes an `UnresolvedComponent` under the suite. | rig passes more | **bounded at 1 corpus file**; `3.7.2__case-186.circ` is the only file in 594 that instantiates a `#Soc` component (measured; the other 353 files merely *declare* the library) |
| 4 | **Timeout.** `rig.py` kills at `--timeout` (default 25 s) and scores that as a failure; the suite has no timeout. | rig fails more, and the failures are size-correlated | interacts with #1 |

Difference #3 is the one to act on: it is the same defect class as the `PlexersLibrary` /
`ExtraIoLibrary` miss that was worth +102 oracles, and `main.swift`'s own comment already states
the principle; *"a registration living in one executable's `main` is a registration the other
executable silently lacks."* The suite is the other executable. It is currently worth ~1 file, but
it will silently grow every time a library lands in one path and not the other.

**Recommended change (in a file I do not own):** `swift/Tests/LogisimStdTests/TruthTableGoldenTests.swift`
line 312 calls `StdLibraries.registerAll()`. The test target cannot see `LogisimSoc`, so the honest
fix is not to add the call but to **record the exclusion**: the suite should skip or separately
bucket any oracle whose file instantiates a `#Soc` component, rather than counting it as a port
defect. One file, and the reason is a module boundary, not a bug.

---

## 4. A third class of oracle Java itself cannot reproduce — seed-0 `Random`

The suite already knows one: `XmlReader.generateValidVHDLLabel` appends a random UUID, so a column
*name* changes every run. There is a second, and nothing buckets it.

`Random.StateData.getRandomSeed` (4.1.0, `std/memory/Random.java:103-115`):

```java
long retValue = seed instanceof Integer ? (Integer) seed : 0;
if (retValue == 0) {
  retValue = (System.currentTimeMillis() ^ MULTIPLIER) & MASK;
```

Seed 0 is the default, so **any circuit reaching a `Random` left at its default prints different
*values* on every run of the same jar over the same bytes.** The port reproduces this faithfully
(`LogisimStd/Memory/RandomGenerator.swift:344-346`), which is why it shows up as a mismatch.

Demonstrated rather than deduced; three consecutive release runs over one file:

```
8257599  2205cd5f2f6702500c68ca6b3504256066abe4cc
8257599  2de4225461b273afac7679b98eeaabfebb85a30d
8257599  d85ff227ee66ef9a4551b3d03ecc906824f3e7f4
```

Identical length, three different hashes, differing from row 1 in the `RGB` column of
`3.3.0__case-075.circ::Datapath`. The debug binary
produced a fourth distinct hash, which is how this was mistaken for a build-mode divergence for
about ten minutes.

**Measured extent, counted transitively (a circuit is affected if it or any circuit it instantiates
places a `Random` with `seed` absent or 0): 6 of 1,392 oracles, across 2 corpus files**: 5 in
`3.6.0__case-458.circ`, 1 in the 3.3.0__case-075.circ file. Two of the
six are over 4,096 rows, so **4 sit inside the suite's attempted set and can never pass.**

Small, but it is 4 of the surviving mismatches that are not defects, and, like the UUID case,
counting them as mismatches permanently blames the port for matching upstream. `docs/objectives.md`
lists "part of the corpus is unreproducible by Java itself" as an open judgement call for one
cause; there are two.

---

## 5. A verified negative — the `CircuitAppearance` column-membership gap is unreachable here

`TruthTableRun.pinColumns` takes column **membership** from "every `Pin` component", and its own
header flags this as an approximation: upstream takes it from
`circuit.getAppearance().getPortOffsets(Direction.EAST).values()`, and *"a **custom** `<appear>` can
omit a pin from the ports, and that case is not reproduced; it needs `CircuitAppearance`, which is
M6."* With 101 oracles carrying `appearance=custom`, this looked like the largest single candidate
family for header-shape mismatches.

It is not reachable in this corpus. Two ways Java can differ, both decidable from the XML with no
simulation at all:

- **(a)** the `<appear>` declares fewer `<circ-port>` shapes than the circuit has `Pin`s → fewer
  columns;
- **(b)** `getPortOffsets` returns a `TreeMap<Location, Instance>` keyed on the *translated* offset,
  so two ports sharing an offset **collapse to one entry** → a lost column even when the counts
  match.

Measured over all 1,392 oracles: **1,227 have no `<appear>` at all** (default appearance, where the
port set is exactly the `Pin` set by construction), **165 have one and every one of them has
`ports == pins` with all offsets distinct**, and **case (a) occurs 0 times and case (b) 0 times.**

The detector was self-tested before the zero was believed, per the rule this project learned the
hard way with the `guard f.count >= 6` gate and the empty-implementation scan: injecting a removed
port into a real circuit body makes it report (a), and moving two ports onto one offset makes it
report (b), while the unmodified control reports neither.

**So `CircuitAppearance` is not on the M3 critical path.** Do not spend M6 work on it expecting a
simulation win; this is exactly the shape of the `computePorts` projection that moved the gate by
zero. It remains a genuine correctness gap for hand-edited or future files, and the port's comment
should stay.

---

## 6. Where the gate actually stands — 1,330 / 1,392, and it is not 1,128

Two harnesses, run independently, agreeing exactly:

| | pass | fail |
|---|---:|---:|
| `tools/difftest/rig.py --max-fail 0 --jobs 8 --timeout 180` (release CLI) | **1,330** | **62** |
| the per-case classifier written for this investigation | 1,330 | 62 (35 UUID-label + 27 mismatch) |

`rig.py` scores the UUID-label cases as plain failures because it compares bytes; splitting them
out is the only difference between the two columns. **0 load failures, 0 runs that threw, 0
timeouts** at 180 s.

Restricted to the 1,282 oracles `TruthTableGoldenTests` attempts: **1,239 byte-exact, 24
UUID-label, 19 mismatched.** The suite's recorded floor is `1128`, so **the ratchet is stale by
+111** and should be raised (see §11).

**That number was first derived and then confirmed by running the suite**, which took 3,200 s under
load; the derivation came from the classifier filtered to the oracles the suite attempts, and the
worry was that the four structural differences in §3 would make such a prediction wrong. They did
not. `swift test --filter TruthTableGoldenTests` prints:

```
  golden oracles      1392
  skipped (> 4096 rows)  110
  attempted           1282
  byte-exact match    1239
  match but for a random UUID label  24
  mismatched          19
    of which hierarchical  10
  would not load      0
  run threw           0
```

**Three harnesses now agree**: `rig.py` (1,330 / 62 over 1,392), the per-case classifier (identical,
split 35 UUID + 27 mismatch), and `TruthTableGoldenTests` (1,239 / 24 / 19 over its 1,282). Every
apparent disagreement between them is one of §3's four structural differences and nothing else;
which is worth stating plainly, because the brief for this investigation expected the gates to
disagree and treated that as the most likely finding of the day. They do not disagree. The gate is
sound; what was stale was the recorded number.

(Note the filter spelling. `--filter "tty table"` matches the *display* name, runs nothing, and
reports `Test run with 0 tests in 0 suites passed`, see §10.)

And the answer to "skipped is not green", queue item #2: of the 110 oracles the suite skips,
**91 pass, 11 are UUID-label, 8 mismatch.** The widest tables in the corpus are not hiding a
systematic wide-value defect. That worry is now measured rather than outstanding, and it was a
reasonable worry, because a wrong shift or an overflow shows up *only* there and Java's 5-bit shift
masking had already caused 138 oracles to be wrongly refused once.

### Two premises to stop repeating, both stale rather than wrong-at-the-time

- **"137 mismatches, of which about 128 are hierarchical."** Measured now: **27 mismatches, 12
  hierarchical and 15 flat.** Hierarchy stopped being the dominant family when subcircuit
  propagation landed, and the ratio has actually *inverted*. Anyone picking up M3 on the strength of
  "it's mostly hierarchical" would be optimising the smaller half.
- **"1,026 → 1,128 byte-exact."** Both are behind: the suite's own recorded floor is `1128` and the
  measurement today is 1,239 on the same 1,282 oracles. Several other agents' merges landed between
  those numbers being written and this run. **Re-measure before choosing a fix**; which is the
  standing instruction in `objectives.md`, and it earned its place again here.

### The 27 mismatches, classified by asking a THIRD question

Golden-vs-port is two-way and cannot tell a port defect from a stale oracle. So every mismatch was
re-run through the **live 4.1.0 jar** and asked: does the jar today agree with the golden, or with
the port?

| verdict | count |
|---|---:|
| jar reproduces the golden → **real port defect** | 16 |
| three-way disagreement (jar ≠ golden ≠ port) | 10 |
| jar reproduces the **port**, golden is stale → **oracle defect** | 1 |

**Correcting that table before anyone quotes it.** "Three-way disagreement" is not a synonym for
"nondeterministic oracle", and reading it that way understates the defect count. Those 10 were
re-examined by masking every 8-hex UUID suffix out of *both* the live jar's output and the port's
and diffing token by token. **8 of the 10 have a genuine body divergence from the jar**; the
random label only made `golden ≠ jar` so they never reached the UUID bucket. Only 2 are truly
oracle-side: the seed-0 `Random` case (§4) and one truncated golden (§8b).

| corrected verdict | count |
|---|---:|
| **real port defect** | **24** |
| oracle is not reproducible by Java (seed-0 `Random`) | 1 |
| oracle is damaged (truncated capture) | 1 |
| oracle is stale (case-insensitive filename collision) | 1 |

So the port's real remaining defect count on this corpus is **24**, not 137 and not 16, and the
honest denominator is 1,392. **13 of the 24 are the single ROM bug in §7**, leaving **11**.

---

## 7. The single cause behind 13 of the 24 — `Rom` overrides `getOffsetBounds` and the port's `ports()` does not know

**Signature.** The 16 defects that were visible before §6's correction all read `U` where Java reads
a real value, and 16 of 17 value divergences appear on the *very first data row*. `ROM` is present
in 14 of those 16 failing circuits. (The other 8 defects, the ones the UUID header was hiding, are
a different family, §7b.)

**Enrichment, measured over the whole corpus (transitively through subcircuits):**

| component | pass | mismatch | fail rate |
|---|---:|---:|---:|
| **ROM** | 35 | 17 | **32.1%** |
| RAM | 51 | 4 | 7.0% |
| Register | 137 | 14 | 8.9% |
| Splitter | 574 | 20 | 3.3% |
| *(all oracles)* | 1,330 | 27 | **1.9%** |

ROM is 17× the base rate: but 35 ROM oracles pass, so it is configuration-dependent. Splitting
ROM placements by attribute finds the configuration immediately:

| ROM `appearance` | pass | mismatch | fail rate |
|---|---:|---:|---:|
| `classic` | 12 | 0 | **0%** |
| `logisim_evolution` | 8 | 13 | **62%** |

**Mechanism, read out of the jar rather than inferred.** A ports oracle (`PortsBridge.java`, §10)
was written because `tools/difftest/BoundsOracle.java` covers `getOffsetBounds` **only; nothing in
this project has ever compared port geometry against upstream.** On the minimal reproducer
`4.1.0__case-483.circ::rom_instru`, which is Pin ×2 and ROM ×1 and nothing else,
the jar reports:

```
ROM loc=(170,150) bounds=170,150,240x540 ends=[(170,160)Iw8 (410,210)Ow24]
```

Width **240**, data-out at offset **(240, 60)**. The circuit's wires run to `(170,160)` and
`(410,210)`, so those are the coordinates that must be hit.

Upstream, `Rom.getOffsetBounds` (`Rom.java:166-173`) **overrides** the shared
`RamAppearance.getBounds` and uses `SymbolWidth + 40` in **both** branches, it never consults
`xoffset`:

```java
public Bounds getOffsetBounds(AttributeSet attrs) {
  final var len = attrs.getValue(Mem.DATA_ATTR).getWidth();
  if (attrs.getValue(StdAttr.APPEARANCE) == StdAttr.APPEAR_CLASSIC) {
    return Bounds.create(0, 0, SymbolWidth + 40, 140);
  } else {
    return Bounds.create(0, 0, SymbolWidth + 40, RamAppearance.getControlHeight(attrs) + 20 * len);
  }
}
```

and `RamAppearance.configurePorts` takes the x of the data-out port from
**`instance.getBounds().getWidth()`** (`RamAppearance.java:183`): i.e. from *that override*, 240.

The port transcribed `Rom.offsetBounds` correctly (`Rom.swift:141-148`, `Mem.symbolWidth + 40` in
both branches). But `Rom.ports` delegates to `RamAppearance.ports(attributes)`, and that function
takes the width from **`RamAppearance`'s own** `offsetBounds`:

```swift
// RamAppearance.swift:266
let xpos = offsetBounds(attrs).width          // symbolWidth + xoffset
```

`xoffset` is `separatedBus(attrs) ? 40 : 50`, and `separatedBus` reads `RamAttributes.dataBus`,
which **`RomAttributes` does not carry**: in the port *or* upstream, where
`RomAttributes.getValue(ATTR_DBUS)` returns `null` (`RomAttributes.java:106-134`). So the shared
function yields `200 + 50 = 250` for every ROM, and the port puts the data-output port at x=250
where Java puts it at x=240.

**Every evolution-appearance ROM's data output is therefore 10 units to the right of where the
file's wires are.** Nothing connects to it, the ROM drives no net, and everything downstream reads
`U`; which is exactly the observed signature.

It predicts the appearance split too, and this is the part that makes it a mechanism rather than a
correlation: in the **classic** branch `Rom.offsetBounds` gives `symbolWidth + 40 = 240` and
`RamAppearance.offsetBounds` *also* gives `symbolWidth + 40 = 240`. The two agree, so classic ROMs
are untouched, **0 of 12 fail.**

`Ram` is unaffected in both trees, and for the same structural reason: `Ram.getOffsetBounds` simply
returns `RamAppearance.getBounds(attrs)` (`Ram.java:175-177`; `Ram.swift:78-80`), so the width the
ports are placed against is the width the factory reports. **`Rom` is the only memory factory that
overrides, and it is the only one broken.**

### The change (in files I do not own — `LogisimStd/Memory/`, reported, not made)

Mirror Java's data flow: the width must come from **the factory's** offset bounds, the way
`configurePorts` reads `instance.getBounds()`. `RamAppearance.ports(_:)` has no instance, so the
caller has to supply it.

`swift/Sources/LogisimStd/Memory/RamAppearance.swift`, split the entry point:

```swift
public static func ports(_ attrs: any AttributeSet) -> [Port] {
  ports(attrs, width: offsetBounds(attrs).width)
}

/// `configurePorts(Instance)`. `width` is `instance.getBounds().getWidth()` upstream: the
/// **factory's** offset bounds, which `Rom` overrides (`Rom.java:166`) and which is therefore
/// NOT always `RamAppearance.offsetBounds(attrs).width`.
public static func ports(_ attrs: any AttributeSet, width: Int) -> [Port] {
  ...
  let xpos = width          // was: offsetBounds(attrs).width
  ...
}
```

`swift/Sources/LogisimStd/Memory/Rom.swift:136`, pass its own override:

```swift
public override func ports(_ attributes: any AttributeSet) -> [Port] {
  RamAppearance.ports(attributes, width: offsetBounds(attributes).width)
}
```

`Ram.swift` and `DualRam.swift` need no change (their `offsetBounds` *is*
`RamAppearance.offsetBounds`), but routing them through the same two-argument call is worth doing
so the coupling is explicit rather than incidental.

### Measured, not projected: +13

The change above was applied locally, built, run against the full gate, and then **reverted**;
those files are outside this agent's ownership, so the measurement is the deliverable and the diff
is not. This project has twice had a projection be badly wrong (`computePorts` was projected to
take simulation "past 90%" and moved it by zero), so the number below is a before/after on the same
harness, same corpus, same binary flags:

| | pass | fail |
|---|---:|---:|
| `swift-port` @ `5a252a49f` | 1,330 | 62 |
| with the two-line `Rom.ports` change | **1,343** | **49** |

**+13 oracles, exactly the 13 evolution-appearance ROM mismatches the mechanism predicted before
the change was made.** Nothing else moved: no regressions, and the other 3 of the 16 real defects
are untouched, so they are separate causes still to be diagnosed.

The minimal reproducer goes byte-exact:

```
$ logisim-cli --toplevel-circuit rom_instru --tty table 4.1.0__case-483.circ
addr instru_out
0x00   0x000000       # java: identical
```

---

## 7b. The 11 that survive — one family, and it is `U`-vs-`E` resolution

Every one of the 11 remaining defects was re-checked against the **live jar** (not the golden), with
UUID label suffixes masked so the comparison is about values only. The complete list, with the
first genuinely differing token:

| case | rows | jar | port |
|---|---:|---|---|
| `2.7.0__case-218.circ::main` | 262,145 | `0000` | `UUUU` |
| `2.7.1__case-514.circ::main` | 3 | `0xEE` | `0xUU` |
| `3.0.0__case-501.circ::ram_search` | 4,097 | `E` | `U` |
| `2.7.0__case-058.circ::PC` | 5 | `0xUEUEUEUE` | `0xUUUUUUUU` |
| `2.7.1__case-169.circ::CPU` | 1,025 | `0x0UUUU` | `0x00000` |
| `2.7.1__case-430.circ::CPU` | 1,025 | `E` | `U` |
| `2.7.1__case-430.circ::DL` | 8,193 | `0x00` | `0xUU` |
| `2.7.1__case-438.circ::CPU` | 2,049 | `E` | `U` |
| `2.7.1__case-438.circ::DL` | 8,193 | `0x00` | `0xUU` |
| `2.7.2__case-078.circ::main` | 9 | `0xUUUUUUUU` | `0x40000000` |
| `3.0.0__case-110.circ::tester` | 9 | `0` | `U` |

**It is one family, and it is not "the port is too pessimistic".** The divergence runs *both*
ways: in 2 of the 11 (`2.7.1__case-169.circ::CPU`, `2.7.2__case-078.circ::main`) the **port is more defined than Java**,
producing a value where the jar produces `U`. A theory that only explains missing drive is wrong.

Two observations that should shape the next investigation, neither of them a fix:

- **`0xUEUEUEUE` is the most informative single row in the set.** Java resolves *alternating bits*
  of one 32-bit bus to `UNKNOWN` and `ERROR`; the port makes the whole bus `UNKNOWN`. A per-bit
  disagreement on one bus is `ValuedBus.recalculate`'s `width >= 2` loop or the `ValuedThread`
  values feeding it: **not** a component's `propagate`, which deals in whole `Value`s. That points
  at `CircuitWires`, and it is the same code §9 discusses.
- **Do not assume this is the same bug as the ROM one.** It would be easy to guess "more mis-placed
  ports", and the two port-is-*more*-defined cases contradict that directly: a disconnected port
  can only lose drive, never gain it.

The cheapest next experiment is the one that worked in §7: pick `2.7.1__case-514.circ::main`, which is
**3 rows**, and walk one bus.

---

## 8. Two defects in the gate itself, both of the silent kind

### 8a. A golden oracle that is simply wrong, and the disambiguator that was supposed to prevent it

`3.0.0__case-167.circ::Ctrl` was the one mismatch where the **live jar
reproduces the port and not the golden**, and not marginally: the golden's header is
`clk start ready mul_rdy store mul_start` with outputs `U U`, while three consecutive runs of the
jar today all print `start ready mul_rdy clk store mul_start` with outputs `0 E`. The jar is
deterministic here; the golden is wrong.

The cause is a **case-insensitive filesystem collision**, and it is provable rather than inferred:

```
'Ctrl'  inode 29754548  name 3.0.0__case-167.circ__Ctrl.table
'ctrl'  inode 29754548  name 3.0.0__case-167.circ__ctrl.table
```

**Same inode.** That file has two circuits, `Ctrl` and `ctrl`, and on APFS the two golden paths are
one file; whichever `regenerate()` thread finished last wrote both entries' oracle.

`rig.py`'s `golden_name` was hardened against exactly this shape once before ("silently overwrote 8
oracles") by appending `sha256(abspath + "__" + circuit)[:8]`. That fix is real and is in the
source. **It is not in the golden set on disk: 0 of 1,392 golden filenames carry the digest.** The
baselines predate the hardening, so:

- the collision is live: 1 group, 2 oracles, 1 of them permanently unpassable;
- `TruthTableGoldenTests.locate()`'s digest branch **can never fire** against this golden set. It
  reads `stem.components(separatedBy: "__").last` and gets `Ctrl`, never an 8-hex digest, so it
  always falls back to `candidates.first`. That safety net is dead code today. It happens to be
  harmless, measured: **0 corpus files share a basename**, but it is a net that would not catch
  the thing it exists for.

**Recommended (files I do not own):** case-fold into the name or append the digest unconditionally,
then regenerate. Lower-casing alone is not enough; `Ctrl` and `ctrl` would still collide. The
existing digest is the right disambiguator; it simply has to be *in the baselines*. A one-line
assertion in `regenerate()` that the output path did not already exist would have caught this the
day it happened.

### 8b. One golden is truncated

`3.5.0__case-383.circ::truc`; the golden has **65,656 lines**, which is not
`2^n + 1` for any n, while the port emits 262,146 (= 2^18 + 2). The oracle was captured from a run
that stopped part-way; `regenerate()` only rejects outputs of two lines or fewer, so a truncated
6-million-character capture is indistinguishable from a complete one. Worth an
`is-it-a-power-of-two-plus-one` assertion at capture time.

---

## 9. Task #14 — the `CircuitWires` `width <= 1` guard: present, faithful, and load-bearing for a different reason than D15 says

**The premise holds, and the code is already correct.** `ValuedBus.recalculate()`
(`LogisimKernel/Propagation/CircuitWires.swift:748-807`) carries all three early returns,
`width <= 0`, `dependentBuses.isEmpty`, `width == 1`, **in Java's exact order**, checked against
`CircuitWires.java:341-376`, with a boxed comment naming D15 and tracker task #14 and a second
copy of the warning in the file header. `Value.createUnsafe` is reached only at `width >= 2`.
Nothing needs doing to the code.

Two corrections to the surrounding claims, though, both of which matter to whoever maintains this:

1. **The stated reason does not apply to the port.** D15 says removing the `width == 1` return
   would make width-1 results `ERROR`, because Java's `and`/`or`/`xor`/`not`/`combine` compare by
   *reference* against interned singletons and a `create_unsafe` value is never interned. The port
   has no interning at all, `Value` is a struct, so a width-1 `createUnsafe` value there is
   `==`-equal to the canonical one and every operator behaves normally. **If the guard were removed
   from the port for that reason alone, nothing would change.**

2. **It is still load-bearing, via a different route.** The `width >= 2` loop classifies each
   thread value with `if tv == .trueValue … else if .falseValue … else if .unknownValue … else
   error |= mask`, so **anything that is not one of those three becomes `ERROR`**; including
   `.nilValue`. Guard 3 returns `threads[0].threadValue()` verbatim and preserves it. So the guard
   converts "a width-1 bus whose thread is NIL" from `E` into `NIL`, which is a real output
   difference. Keep the guard; fix the *comment*, which currently justifies it with an interning
   argument that does not hold here and would invite someone to delete it.

3. **D15 asks for a test and there is not one.** Grepping `swift/Tests/` finds nothing that
   references `ValuedBus`, `recalculate` or the narrow-width path; the guard's only cover is the
   corpus gate, which is indirect. `CircuitWires.swift` is in `LogisimKernel`, so the test belongs
   in `LogisimKernelTests`: outside this agent's ownership, hence reported rather than written.

---

## 10. The gate that was missing — port geometry (`SimPortGeometryTests`, landed)

The ROM bug in §7 survived every gate this project has because **nothing had ever compared port
geometry against upstream.** `BoundsOracle.java` compares `getOffsetBounds` over 6,013 rows and
earned its keep, it took non-hierarchical mismatches from 105 to 9, and it is blind to this
class by construction: the ROM's *bounds* were correct throughout. Only the port sitting on them
was wrong.

That is the worst shape a defect can have here, because from the simulation gate it presents as
"some value is `U`", which is also exactly what an unported component, an unregistered library and
a propagation-ordering bug look like. Three of those four have each cost this project a day.

So `swift/Tests/LogisimStdTests/SimPortGeometryTests.swift` now exists, with an oracle generated by
driving the real 4.1.0 classes:

```sh
javac -cp "$JAR" -d out PortsBridge.java            # source in the test file's header comment
java -Djava.awt.headless=true -cp "$JAR:out" \
     com.cburch.logisim.file.PortsBridge < files.txt > "$LOGISIM_CORPUS/golden_ports.txt"
```

**46,503 rows over 594 files**, one per component: file, circuit, factory, location, bounds, and
every end as `x,y,IO,width` **in `getEnds()` order**; the order is contract, not incidental,
because `Ram.propagate` and friends index ports by number on every simulation step.

The generator emits 53 `FAIL` lines, and those are **exactly** the 53 files recorded in
`canonical/_failed.json` as unloadable by upstream; checked as *set equality*, not as a matching
count:

```
canonical _failed entries: 53 · PortsBridge FAIL files: 53 · identical set: True
only in canonical: 0 · only in ports: 0
```

That is the "assert your oracle produced output" check, and it is a real cross-check rather than a
formality: two unrelated Java paths, `CircBridge`'s load-and-write and this one's load-and-dump,
fail on precisely the same files, which is strong evidence the generator ran the code it claims to
and did not quietly skip anything.

First measurement:

| | |
|---|---:|
| components byte-identical | **44,076** |
| geometry differs | 2,374 |
| **in the oracle, absent from the port** | **0** |
| in the port, absent from the oracle | 391 |

Two things fall out immediately:

- **96 `ROM` rows differ, every one by exactly 10 in the data-output x**: the §7 bug, reproduced
  independently at *component* granularity rather than inferred from 13 failing oracles.
- **The rest are subcircuit placements differing in `bounds` only, with every end identical.**
  `ALU`, `MUX`, `full_adder`, `HEX_DECODER` and friends: the port draws a default box where Java
  uses the custom `<appear>`'s. That is the `CircuitAppearance` gap, it is real, it is M6, and
  because the *ends* match, **it cannot affect simulation**, which is consistent with §5's verified
  negative rather than in tension with it.

The 391 port-only rows are all factory names 4.1.0 does not have: `BitLabeledTunnel` ×311 leads,
and the corpus declares it under `<lib desc="#Wiring">` even though 4.1.0's Wiring library has no
such component. It is a fork's type (LogisimCL). Upstream drops it on load; D8 preserves it here.
**Worth a follow-up rather than a conclusion:** if a D8-preserved unknown component carries ends,
it joins nets upstream does not join, and that is a live candidate for the two §7b cases where the
port is *more* defined than Java. `UnresolvedComponent.propagate` is a no-op, so it cannot drive,
but joining is not driving, and I have not measured whether it has ends.

### Two harness traps found while building it, both worth inheriting

- **`--filter "tty table"` matched nothing and reported `Test run with 0 tests in 0 suites
  passed`.** A green run over zero tests. swift-testing's `--filter` wants the *type* name
  (`SimPortGeometryTests`), not the display name. Anyone iterating on `TruthTableGoldenTests` with
  a display-name filter is running nothing and being told it passed.
- **The ratchet was verified to fail before being trusted**, by raising it one above the
  measurement and confirming a red run. Per this project's own rule about probes that match
  nothing: the `guard f.count >= 6` gate, the empty-implementation scan that returned a false 0,
  and `rig.py`'s simulation mode being dead for its entire existence.

---

## 11. What to do next, in value order

1. **`Rom.ports` (§7).** Two lines, +13 oracles, mechanism understood and measured. The only item
   here with a number attached.
2. **Bucket the unreproducible oracles (§4, §8).** Seed-0 `Random` (6 oracles) deserves the same
   treatment `unreproducibleLabel` already gets, and the UUID-label bucket needs to stop requiring
   *every other line* to be byte-identical: §7b found 8 real defects hiding behind that
   requirement, which is a gate that hides bugs rather than merely mis-scoring them.
3. **Raise `TruthTableGoldenTests.floor` from 1128 to 1239** (§6), and consider whether the
   `LOGISIM_M3_MAX_ROWS` cap is still worth its cost now that the skipped 110 are measured at 91
   pass / 11 UUID / 8 mismatch.
4. **Regenerate the golden set with the digest in the filename (§8a)**, and add the two capture-time
   assertions: the output path must not already exist, and a table's line count must be
   `2^n + 1`.
5. **The 11 remaining defects (§7b)**: one family, `U`-vs-`E` bus resolution, running in both
   directions. Start at `2.7.1__case-514.circ::main`, which is 3 rows.
6. **Correct `CircuitWires`' D15 comment (§9)** and write the test D15 has asked for since M3 was
   planned.
