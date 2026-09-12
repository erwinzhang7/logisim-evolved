# Objectives — logisim-evolved

Operational tracker for the Swift/macOS port. **This file is the source of truth for what to
do next.** Update it as work lands; keep it accurate rather than aspirational.

Binding technical decisions live in [`decisions.md`](decisions.md). Read that first; it is
not optional context, it is the contract that delegated work must satisfy.

---

## The goal

A native Swift/macOS 26 port of logisim-evolution 4.1.0 at **full functional parity**, minus
what is structurally impossible on macOS (D11). Faster, genuinely native, and with the
simulation clock actually correct (D7). GPL-3.0-only, shipped as a signed and notarized DMG
plus a Homebrew cask; a thing upstream cannot do, because they have no Apple Developer
account (their issue #2699).

There is no reduced "v1" release gate. Milestones are verification checkpoints, not ship gates.

## Working environment

| | |
|---|---|
| Port repo | `~/Developer/logisim/logisim-evolved` (branch `swift-port`) |
| Upstream Java reference | `~/Developer/logisim/upstream-java-4.1.0`: **the port target** (D16) |
| Upstream main (comparison only) | `~/Developer/logisim/upstream-java`: 4.2.0-dev, do NOT port from |
| Swift package | `logisim-evolved/swift`: `swift build`, `swift test` |
| Corpus (private, never commit) | `$LOGISIM_CORPUS` |
| Golden baselines | `$LOGISIM_CORPUS/golden` or scratchpad `golden/` |
| Java oracle | `/opt/homebrew/opt/openjdk@21/bin/java -jar /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar` |

Oracle invocations and their gotchas are tabulated at the end of `decisions.md`. The ones that
bite:
- **Use `CircBridge`, not `-n`** (D17). `-n` needs a GUI and blocks on modal dialogs for 155 of
  the 594 corpus files. `CircBridge` sets `Main.headless = true`, batches, and is ~6× faster.
- **Conversion is not idempotent, and two passes is not enough**: 519 files reach a fixed point
  at pass 2, 20 need pass 3, and 2 never converge. `canonical.py` iterates.
- `--toplevel-circuit` is what turns 12 file-level oracles into 100 circuit-level ones.

### The most reliable technique found in this project: drive the real class inside the jar

Not "read the Java and transcribe carefully"; **run upstream's own class and diff its output**.
Every time this was done it beat reading, and it kept finding things a careful reader would not:

- `tools/valuebridge/ValueBridge.java` → the 33,124-case `Value` gate.
- `tools/difftest/canonical.py` + `CircBridge` → the round-trip baselines.
- `tools/analyze/MinProbe.java` → 616 minimisation cases, later an exhaustive 131,072-case sweep
  that found the port picks a different *equally optimal* cover on 1 function in 18.
- `tools/difftest/BoundsOracle.java` → 6,013 rows of component geometry; took non-hierarchical
  simulation mismatches from 105 to 9.
- `tools/hdlbridge/NetlistBridge.java` → 139 of 146 circuits byte-identical, and **three bugs
  reading the Java would not have revealed**: `isClock` never overridden so `Circuit.clocks` is
  empty everywhere; `isHDLSupportedComponent` and "has a generator" being different predicates
  upstream; and netlist membership needing a per-factory answer the port lacks.

Two hard-won caveats:

- **Check whether the entry point you pick is actually drivable.** The jar's own
  `--test-fpga … HDLONLY` looked like an HDL oracle and is not: it needs a board XML plus a saved
  pin map, and **exits silently having written nothing** for an unmapped design. Driving `Netlist`
  directly needs neither. A silent zero-output success is the worst possible oracle.
- **Java's collection iteration order is sometimes load-bearing output.** `getNetId` is an index
  into a `HashSet` drain and is emitted verbatim as `s_LOGISIM_NET_<id>`, so a Swift `Set` would
  permute every signal name in every generated file. `JavaHashSetOrder.swift` reproduces it,
  pinned against a real OpenJDK run rather than derived from reading `HashMap`. Note this is the
  *opposite* conclusion from `docs/experiments/hashorder.md`, which proved simulation output does
  **not** depend on hash order; the question has to be asked per subsystem, not answered once.

### A defect class that turned out NOT to exist here — do not build a checker for it

`seamcheck` finds "declared, called, no implementation". The obvious next worry is the opposite:
a conformer that exists and *does nothing*: the "stub wearing a disguise" the M2 audit named,
more dangerous than an absent file because it compiles **and** satisfies the seam check.

Scanned for it: **73 single-line empty implementations, 19 documented as deliberate, 54 bare.**
Spot-checking the bare ones shows they are faithful rather than stubbed; `InstancePoker`'s
`mousePressed`/`mouseReleased` are empty in Java too, and `componentInvalidated`/`endChanged`/
`labelChanged` are Java's own empty `ComponentListener` defaults. **Reproducing an empty default
is correct.** A checker here would flag ~54 correct ports and get silenced, which is worse than
no checker.

Worth recording chiefly for the *method* error it exposed: the first version of that scan
returned **0**, and the zero was false; the regex only matched multi-line bodies and missed
every single-line `{}`, including a `paintGhost` I already knew about. A probe that matches
nothing looks exactly like a clean result. **Verify the instrument can find a case you already
know exists, before believing it found none.**

## Standing rules

1. **Never commit the corpus or golden baselines.** They derive from private coursework and the
   golden tables are effectively lab solutions, so the repository cites corpus files by anonymous
   handle instead: see `tools/corpus.py`. `.gitignore` covers the data; do not defeat it.
2. **Never edit the reference copy of upstream's Java.** It is the specification, and a port
   checked against a tree you have edited is checked against nothing.
3. Every milestone has a machine-checkable pass condition. A milestone is not done because the
   code exists; it is done when its differential gate is green.
4. Preserve upstream behaviour even where it looks wrong, unless `decisions.md` explicitly
   overrides it. The oscillation heuristic and `InstanceStateImpl` reuse are deliberate.

---

## Where things stand

**Every row carries the date it was last actually run.** Rows marked 09-06 were re-run by me on
the current tree; the others are older and are NOT re-measured claims. That distinction is not
pedantry; this project has now had three separate incidents where a real-looking number described
something other than the current tree (a contaminated baseline, one sample of a flaky suite, and a
gate that will happily score a stale binary).

| | | last run |
|---|---|---|
| `swift build` | **0 errors**, 13 modules | 09-06 |
| canonical round-trip (M2 condition A) | **539 pass / 0 fail** | 09-06 |
| migration round-trip (M2 condition B) | **456 pass / 0 fail** · 50 vhdl-label · 14 font-unresolved · 19 d8-superset | 09-06 |
| codec actually transformed | **500 of 539** migration inputs | 09-06 |
| `-tty stats` gate | **1,731 pass / 6 fail of 1,737** | 09-06 |
| `-tty stats` coverage | **1,789 / 2,097** pairs; 308 without a golden, **0 unexplained** | 09-06 |
| `tools/graphcheck.py` | **14 edges, 12 test targets** | 09-06 |
| `tools/seamcheck.py` | **11 candidates, 11 known, 0 new** | 09-06 |
| `tools/deadseam.py` | 6 unassigned seams · 1 test-observed collection · 8 test-only types | 09-06 |
| `LogisimUITests` (the app half) | **278 tests / 46 suites** | 09-06 |
| full `swift test` | **1,333 tests / 137 suites** | 09-06 |
| M3 simulation vs the 4.1.0 `-tty table` oracle | **1,347 byte-exact / 1,347**: 0 failures, 44 excluded | 09-06 |
| HDL, gates/wiring/plexers | **952 cases byte-exact** vs the jar | 09-05 |
| HDL, arithmetic | **308 cases / 42,652 lines, 0 differ** | 09-05 |
| HDL, memory | **168 / 168**, no filters | 09-05 |
| HDL, io | **122 + 582 cases byte-exact** | 09-05 |
| FPGA board model | **29 / 29 boards, 1,440 IO components** identical | 09-05 |
| `tools/gateaudit.py` | **21 probes, 0 misbehaving** | 09-06 |

**THE FULL-`swift test` ROW IS BACK, AND IT IS QUOTED AS FIVE RUNS RATHER THAN ONE.** It was
withdrawn while the suite was unreliable: board #67's factory-identity race and #74's
seam-clearing race, both now fixed. **Five is the sampling floor, not three**: every
parallel-race investigation in this project that used three runs drew a wrong conclusion at least
once, most recently a fix that looked correct at 3/3 and still failed 2 of 5.

**HOW TO READ THE TWO M2 COLUMNS.** `canonical 539/0` is the **weaker** half. A canonical file is
by definition a fixed point of Java's converter, so `load → save` must return it unchanged, and
an identity codec returns everything unchanged. `gateaudit` proved this by substituting a stub
that is literally `cp(1)` and watching the canonical column report 539/0. **Migration is the
discriminating column** (the same stub scores 39/500), which is why the gate now also reports how
many inputs the codec actually transformed and refuses to pass when that is zero.

**QUOTE BOTH SIMULATION DENOMINATORS, AND KNOW WHICH HARNESS.** There are two gates over one
corpus and they do not measure the same thing:

* `rig.py` has **no row cap** and is the stronger one. **1,343/1,391** is its figure, run against
  a **release** binary; a debug sweep reaches ~100 of 1,392 cases in 30 minutes and never
  finishes. It is NOT the number in the table above, which is the suite's; the two denominators
  differ because the harnesses do, which is the whole point of this section.
* `TruthTableGoldenTests` caps at `LOGISIM_M3_MAX_ROWS` = 4,096 and skips 110 oracles. Those 110
  carry **7,385,316 of the corpus's 7,608,044 rows; 97.1%**. Median oracle is 17 rows; the largest
  is 262,145. So the suite's headline is computed over **2.9% of the corpus by row**, and the
  skipped set is exactly where a masked shift or a `Value` width-boundary defect would show.

Of the 63 non-passing cases, **16 are real port defects and 13 of those are one ROM bug** (task
#47). The rest are classes Java cannot reproduce against itself: `generateValidVHDLLabel` appends
a random UUID, and `Random` seed 0 means "use `currentTimeMillis`"; three consecutive release runs
over one file produced three different hashes of identical length (task #48).

## Status

Legend: `[x]` done · `[~]` in progress · `[ ]` not started · `[!]` blocked

> **THE CHECKBOXES BELOW ARE STALE AND UNDERSTATE THE PORT. The `Pass condition` lines are the
> authoritative ones; they were maintained, the boxes above them were not.** M2, M3, M4 and M6
> still show unticked sub-items whose own pass conditions are green and gated in CI: canonical
> 539/0, migration 456/0, M3 1,347/1,347 byte-exact, four HDL families byte-exact, 29/29 boards.
> Read a `[ ]` here as "nobody ticked it", not as "not built". Corrected 2026-09-06 rather than
> re-ticked line by line, because ticking forty boxes I had not individually re-measured would
> trade one wrong claim for forty.

### M0 — Harness, corpus, module skeleton
- [x] Fork created, cloned, `upstream` remote wired
- [x] SPM skeleton: 5 modules, mixed Swift 5 kernel / Swift 6 UI, builds clean
- [x] `decisions.md` D0–D12 recorded
- [x] Java oracle proven headless on real files
- [x] Seed corpus: 17 files / 107 circuits
- [x] Golden baselines: **100 oracles, 414,980 rows**
- [x] Clock claim measured (D7 table)
- [x] Harvest legacy `.circ`: `tools/difftest/harvest.py`. **577 files across 14 versions**
      (2.6.3 ×2, 2.7.0 ×54, 2.7.1 ×60, 2.7.2 ×55, 3.0.0 ×21, 3.3.0 ×56, 3.5.0 ×59, 3.6.0 ×10,
      3.6.1 ×54, 3.7.0 ×14, 3.7.1 ×19, 3.7.2 ×59, 4.0.0 ×54, 4.1.0 ×60)
- [~] **Migration gate coverage; one gate is still untested, do not claim fidelity for it:**

      | gate | wild files older than trigger | status |
      |---|---|---|
      | `<2.3.0` | 0 | **covered by a synthesized fixture** |
      | `<2.6.3` | 0 | **UNTESTED: and untestable by output comparison** |
      | `<2.7.2` | 116 | covered |
      | `<4.0.0` | 463 | covered |

      **Resolved as far as it can be; see `tools/difftest/fixtures.py`:**

      - **`<2.3.0` is now COVERED** by a synthesized fixture. Dropping the `source=` attribute
        makes `LogisimVersion.fromString` yield `0.0.0`, which is below the gate. Verified
        discriminating, not just loading: toolbar goes `Poke, Select, Wiring, Text` →
        `Poke, Edit, Text`, exactly the documented repair.
      - **`<2.6.3` remains UNTESTED**, but the earlier reason recorded here was **wrong** and is
        corrected: it claimed the repair "corrupts a modern-structured file", inferred from
        `2.6.0` hanging while `3.6.1` was clean. Those two versions straddle the 2.7.2 threshold
        at `XmlReader.java:414`, which pops a modal *"Old file format"* warning; the hang was
        the dialog, not the repair. The comparison had nothing to do with the gate under test.

        The real obstacle is different and firmer: the repair removes the `#Legacy` library, but
        an unresolvable library is **also silently dropped by the loader**, so both paths produce
        byte-identical output. Verified deterministically over 3 runs through `CircBridge`:
        `2.6.0` and `3.6.1` both strip `#Legacy` and both lose the component. The only signal
        separating them is a log line, too fragile to gate on. Closing it needs a genuine
        pre-2.6.3 file with old structure; none exists in the 594-file corpus.

      **M2 must not claim migration fidelity for `<2.6.3`.** Ship it as a known-untested path
      or find a real pre-2.6.3 file (original Logisim 2.x distributions, university course
      archives, the Wayback Machine).
- [x] Differential rig `tools/difftest/rig.py`, verified: 0 pass / 4 fail against the
      unimplemented CLI, and **exits 1** on both failure and no-match (checked directly, not
      through a pipe, `$?` from a pipeline is the last command's, a trap this repo's own notes
      warn about)
- [x] **CI PASSES, 2026-09-05.** Full package build 0 errors across all 11 modules, 399 tests
      pass, leak-detector self-check green (control 0 / injected 1), `leaks` clean. This is the
      first time every module has been in the build graph simultaneously; `LogisimSoc` had
      never been compiled by `swift build` at all until this day, which is exactly why five
      defects had accumulated in it invisibly.

- [~] **Earlier the same day, CI's first end-to-end run.** Result: build FAIL, test FAIL
      (both `LogisimUI` only, mid-reconciliation), **leak-detector self-check OK** (control
      clean = 0, injected cycle detected = 1) and **`leaks` on the test binary: NO LEAKS.**

      That last line is the first real evidence for D3; the `unowned`/`weak` ownership work is
      holding. Scope it honestly though: the test binary excludes `LogisimUI` because it does not
      build, and the M3 propagation core is not fully exercised by the current tests, so this is
      "no leaks in what runs", not "no leaks".

      The `LogisimUI` failure is a Swift 6 actor-isolation boundary the three M7 slices did not
      agree on; `main actor-isolated property 'factory' can not be referenced from a nonisolated
      context`. The UI target compiles in Swift 6 language mode with full isolation while the
      kernel deliberately opts out (D1), so anything the UI shares with a tool or an action has
      to pick a side consistently.

- [x] CI gate `tools/ci.sh`: build, test, leak-detector self-check, `leaks` on the test binary,
      differential rig. Uses `leaks --atExit` rather than Instruments (simpler, scriptable, same
      job). **The leak detector validates itself both ways**: an unmodified canary must exit 0
      *and* a canary with an injected retain cycle must exit nonzero. Without the control, a
      crash would read as a successful injection. Verified: control 0, injected 1.
      Also runs the **M2 round-trip gate**, reporting the canonical and migration conditions
      separately; informational until M2 lands, so the commit gate stays meaningful.
- [ ] GitHub Actions workflow; deliberately NOT added yet. We are not pushing, and GitHub's
      macOS runners may not carry Xcode 26 / macOS 26. A workflow that fails on first push is
      worse than none. Add when pushing is approved and runner support is confirmed.
- [x] Golden regenerated across the whole corpus: **1,392 oracles, 7,608,044 rows** over 594
      files.
- [x] **M2 canonical baselines: 539 files**, iterated to a true fixed point (`canonical.py`).
      53 excluded because upstream itself cannot load them, 2 because upstream's writer is
      non-deterministic for them; both lists recorded rather than silently dropped.

### M1 — Value / BitWidth / geometry / AttributeSet
- [x] `Value` as a struct (three `Int64` + width, mirroring Java's *signed* long). Interning
      `Cache` dropped.
- [x] **`Value.getColor()` did not port**; kernel returns a `ValuePalette` index (D9). Verified:
      zero AppKit/SwiftUI/CoreGraphics imports anywhere in `LogisimKernel`.
- [x] `BitWidth`, `Location`, `Bounds`, `Direction`, plus `MiniFloat` split out for FP16/FP8
- [x] `AttributeSet` per D5: generic `Attribute<V>` API over an `AttributeValue` enum with
      `.opaque(String)`; 30 unit tests green
- [x] **D13 audit complete: 25 traps → 14.** The 11 converted to `throws` were all reachable
      from a `.circ` file; the 14 left are 8 abstract-method stubs and 6 API-misuse cases no
      file can trigger. Full classification table in `decisions.md` D13.
- [x] Java oracle bridge `tools/valuebridge/ValueBridge.java` + `gen_golden.py`. Golden set is
      32,929 cases (edge-first, then seeded-random), generated once so the Swift test needs no
      JVM. Lives at `$LOGISIM_CORPUS/golden_value.txt` (3.1 MB, regenerable, not committed).
- [x] Pass condition: **GREEN: all 32,929 cases match**, including the `createUnsafe` probes at
      widths 65, 100 and −1. D13 applied to `Value`, so the 6 previously-unverifiable cases are
      now directly checked: Swift must throw exactly where Java throws.

**A trap worth remembering: the first run reported 344 divergences and every one was the
harness.** `Value.not()`/`xor()` compare by *reference identity* at width ≤ 1
(`if (this == TRUE) …`), and `Value.create()` returns the canonical singletons while
`create_unsafe()` cannot; the singletons are built with `new Value(…)` and never enter the
cache. Building cases through `create_unsafe` therefore made every identity branch fall through
to `ERROR`, which is indistinguishable from a port bug. Both sides of a differential harness
must construct values by the same route the real code uses. Then a second, subtler version of
the same mistake: the Java side was fixed to construct canonically while the Swift side still
used `createUnsafe`, leaving it holding unmasked values.

**Measured Java semantics the port MUST match — a "reasonable" port gets these wrong:**

| input | Java result | why it bites |
|---|---|---|
| `combine(TRUE, UNKNOWN)` | `ERROR` | not `TRUE`; combining a known with an unknown is a conflict |
| `Value` width 0 (NIL) | `isUnknown() == true`, renders `-` | NIL is *not* "no information", it reports unknown |
| `decu` width 64, all ones | `18446744073709551615` | exceeds `Int64`; needs wider formatting |
| `create_unsafe(65, …)` | 65-bit binary string | **width is NOT validated.** `create_unsafe(100, …)` gives 100 bits. A `UInt64`-shift port TRAPS here. |
| `create_unsafe(-1, …)` | accepted; empty binary/hex, `U` decimals | negative width is tolerated |
| `create_unsafe(8, 0,0, 999999)` | binary/hex/dec mask to 63, **but `toLongValue()` returns 999999** | display masks, `toLongValue` does not; an internal inconsistency that must be replicated |
| `get(99)` on width 4 | `ERROR` | out-of-range bit index returns, does not throw |

`create_unsafe` validates nothing and essentially never throws. **Do not add validation to it.**

### M2 — Netlist model + full `.circ` codec

**4.1.0-vs-main checklist (D16).** M2 was written against `upstream-java`, which is main
(4.2.0-dev); the target is 4.1.0. These `XmlWriter` changes are **main-only and must NOT appear
in the port**: verify each against a 4.1.0 checkout:

| # | main-only change | why it matters |
|---|---|---|
| 1 | `stringCompare` null handling | 4.1.0: `if (stringA == null) return -1;` so `stringCompare(null, null) == -1`: an **inconsistent comparator** claiming null < null. Main fixed it to `stringB == null ? 0 : -1`. **Sort order IS the pass condition**, so the port must reproduce the 4.1.0 bug. Reachable through attribute values (`getNodeValue()` can be null). |
| 2 | VHDL `appearance` attribute | main writes it, 4.1.0 does not; writing it breaks byte-match. *Verified absent so far.* |
| 3 | `out.flush()` | main only |
| 4 | `Image.ATTR_LICENSE` in the user-modified filter | main only |
| 5 | `fromWire(w, circuit)` | gained the circuit parameter in main |
| 6 | `libraryContains(lib, source)` | replaced `lib.contains(source)` in main |
| 7 | `ProjectBundlePaths.libraryEntry/libraryDescriptor` | main only; 4.1.0 builds these inline |

Re-check `Loader.java` (+52), `XmlCircuitReader.java` (+34), `XmlReader.java` (+25) and
`LogisimFile.java` (+19) the same way.

- [ ] `Circuit`, `Wire`, component placement, `LogisimFile`, `Loader`, `LibraryManager`
- [ ] **All 12 builtin library shells must resolve** even though SoC/TCL components come later:
      every corpus file declares 12 and instantiates from 2–3, and an unresolved declaration
      fails the whole load
- [ ] Every `XmlReader.considerRepairs` migration pass, in order
- [ ] `XmlWriter.sort` reproduced exactly
- [ ] D8 opaque round-trip for unknown `<comp>`/`<lib>`
- [ ] **Duplicate circuit names are real.** `2.7.1__case-169.circ` in the corpus
      declares two `<circuit name="decoder">`. Decide and pin what the loader does; Java's
      behaviour needs checking before we replicate it, and `--toplevel-circuit` is ambiguous
      for such a file.
- [x] **Pass condition A (canonical): 539 pass / 0 fail**: re-measured late 2026-09-05, green.
      **But read it correctly: this is the WEAKER of the two M2 columns.** A canonical file is a
      fixed point of Java's converter, so `load → save` must return it unchanged, and an identity
      codec returns *everything* unchanged. `tools/gateaudit.py` proved this by substituting a
      stub that is literally `cp(1)` and watching this column report 539/0. The gate now also
      reports how many migration inputs the codec actually transformed (**500 of 539**) and
      refuses to pass when that is zero.
      *Historical, kept because the mechanism recurs:* it once read 520/19, down from
      539 / 0. **The regression was revealed, not caused, by registering the builtin component
      libraries.** Until then no `<comp>` resolved, so the codec preserved every `contents`
      attribute verbatim and `MemContents` never parsed one. With real libraries registered it
      does, and its run-length encoder is wrong; Java `18*0 19*11` becomes `36*0 11`, and
      Java `18*ffff 18*3` drops the trailing `18*3` entirely. Those are memory images, so this
      is silent data loss in RAM/ROM contents on a plain open-and-save. Being fixed against
      Java's `gui/hex/HexFile`. **Reverting the registration would restore a green number that
      lies**, so it stays red until the encoder is right.

      Note the rig **counts canonical failures but never prints them**; the 19 had to be
      identified by converting the baselines directly. Worth fixing in `rig.py`.

      It reached a clean **539 / 0** earlier the same day, with Swift load→save of `-n(-n(f))`
      byte-matching on every file that has a baseline: independently spot-checked outside the
      rig on 5 files (including a 230 KB MIPS CPU and a CJK-named file) rather than trusting the
      harness twice. So the codec itself is proven; what is red now is the memory encoder behind
      it.
- [~] **Pass condition B (migration): 434 pass / 105 fail**; re-measured late 2026-09-05.
      **This is the discriminating column** (the `cp` stub scores 39/500 here), so it is the one
      to quote when asked whether the codec works. 67 of the 105 are excluded-with-reason because
      `generateValidVHDLLabel` appends a random UUID and the jar is not reproducible against
      itself on those files; the rest are being grouped by cause under task #15.
      *Historical:* this line read 0 / 539 after the builtin libraries were registered,

      1. **Wrong library index for the canvas tools.** Java writes `<tool lib="7" name="Poke
         Tool"/>`, Swift writes `lib="6"`. **Not** a table mismatch; both tables are identical
         (`0 #Wiring … 6 #I/O, 7 #Base`), so Java resolves those tools to `#Base` and Swift to
         `#I/O`. The lookup in `XmlWriter.findLibrary(of:)` finds the tool in the wrong library.
         Worth checking whether `MissingLibrary` is in the search path: it deliberately mints a
         placeholder for *any* name asked of it, so it would match everything.
      2. **Unsuppressed default attributes.** Swift emits `halign`, `text` and `valign` `<a>`
         children on the Text tool that Java omits, i.e. the default-vs-modified filter is not
         being applied to tool attributes.
      3. **Three `<tool>` blocks still missing**: `Probe`, `Clock`, `Pull Resistor`, 23 of 25
         sampled files each. `Pin` was in this list at 25/25 and is now correct, so whatever
         fixed `Pin` is the pattern for the remaining three.

      *Superseded diagnosis, kept because the reasoning still matters:* over 60 files the `<lib>`
      counts matched (8 vs 8) while Swift emitted **4** `<tool>` blocks against Java's **5**,
      `Pin` (25/25 files), `Probe` (23), `Clock` (23), `Pull Resistor` (23), and in 7 files
      Swift emits a `ROM` block Java does not.

      **Both directions come from one cause**: Java's `XmlWriter` only writes a `<tool>` block
      for attributes the user changed from the builtin default, so it needs the real builtin
      tool models to compute "differs from default". Swift has none (task #17's
      `BuiltinToolProviders` seam), so it neither suppresses defaults nor emits the ones it
      cannot evaluate. This is therefore **blocked on the M4/M5 component library**, not on the
      codec; the writer logic cannot be finished before the tools it must compare against exist.

### M3 — Simulation kernel, headless · hardest milestone
- [ ] `Propagator` + hand-rolled binary heap (Swift has no priority queue)
- [ ] `Simulator`/SimThread with the **D7 phase-anchored clock**; this is the headline fix
- [ ] `CircuitState` tree applying D3 ownership; `Instance` facade deleted
- [ ] `CircuitWires` union-find, plus the eager-connectivity fix that deletes the only
      sim→UI blocking call
- [ ] `SubcircuitFactory` recursion
- [ ] ~12 components to have something to run: Pin, Constant, Clock, Tunnel, Splitter,
      AND/OR/NOT/XOR, Probe
- [ ] Preserve verbatim: oscillation heuristic (`simLimit`, `simRandomShift`), reusable
      `InstanceStateImpl`
- [~] Pass condition: `logisim-cli --tty table` byte-matches golden on every corpus circuit using
      only those components, incl. feedback loops and ≥3 levels of subcircuit nesting.
      Leak check clean after 1,000 open/close cycles.
      **Measured late 2026-09-05: 1,339 / 1,389 byte-exact** via `rig.py` against a *release*
      binary, with 3 unsound baselines excluded (hence 1,389, not 1,392).
      Of the 50 remaining: **3 are timeouts rather than content differences**, and the rest span
      29 distinct corpus files. The ROM defect that accounted for 13 of them is FIXED (#47). The
      survivors are one family, `U`-vs-`E` bus resolution, running *both* ways, which points at
      `ValuedBus.recalculate`'s `width >= 2` loop rather than any component's `propagate`, plus
      two classes the jar cannot reproduce against itself (#48).
      Note which harness: `rig.py` has no row cap, while `TruthTableGoldenTests` skips the 110
      widest oracles; which carry **97.1% of the corpus by row**. Those 110 have now been
      measured directly: 91 pass, 11 UUID, 8 mismatch, so nothing was hiding behind the cap.

### M4 — Component library, mechanical tranche · ~80% delegatable
- [ ] gates, ttl (65 chips), plexers, base, bfh, arith
- [ ] **Hand-port one exemplar per family first**, then delegate the repetition
- [ ] Preserve TTL inheritance chains; flattening makes future fixes diverge silently
- [ ] Strip embedded HDL generators file-by-file (they are inner classes, not separate files)
- [ ] Pass condition: auto-generated exhaustive truth-table harness per component, gating every
      delegated batch

### M5 — Component library, bespoke tranche
- [ ] `wiring`, `Pin.java` (1,284 LOC) is disproportionately load-bearing
- [~] `memory`, flip-flops, Register, Counter, ShiftRegister, `Ram` (~3,700 LOC, two independent
      appearance renderers). In progress.
- [~] `io`; the corpus uses **RGB Video**, so it is in scope despite being deferred in the
      original plan. In progress.
- [ ] Pass condition: stateful sequence tests; RAM/ROM `contents` round-trips byte-exact

### M6 — Renderer + read-only canvas

**2026-09-05: component painting landed: 132 files across four families, `LogisimStd` at 0
errors.** M6 went from *zero* paint implementations to gates, wiring, memory, io, TTL and
arithmetic all drawing.

The seam that had to be invented: **nothing resembling `InstancePainter` existed**, and upstream's
is really two classes fused (`InstancePainter` + `ComponentDrawContext`). It lands over a
`SceneBuilder`, deliberately NOT conforming to `InstanceState`; that protocol's `component` is
non-optional and a ghost genuinely has none, which is why Java throws from four methods to cope.
The five `AppPreferences` reach-ins are behind a `PaintContext` protocol so D9 still holds.

**A correction to the brief, found by checking:** gates have **TWO** appearances in 4.1.0, not
three. `SHAPE_DIN40700` is commented out at `AppPreferences.java:507`, absent from the
`GATE_SHAPE` option array at `:512`, and its dispatch arm in `AbstractGate.paintBase` is
commented out too. `PainterDin` is ported and every gate declares `paintDinShape`, with the
dispatch left commented in the same place; **wiring it up would be a main-only behaviour.**

**Upstream bugs preserved verbatim, each with a comment saying so** (standing rule 4):
- `SplitterPainter` tests `fanout > 3` vertically but `>= 3` horizontally, so a 3-way splitter
  draws a bar one way and a dot the other.
- `PainterDin.paintOrLines` passes the input index to `isPortConnected(i)` instead of `i + 1`,
  so it asks about the output port for input 0.
- `Probe.paintGhost` insets by 1 where `paintInstance` insets by 2; a ghost is a pixel wider
  than the thing it becomes.
- `Constant`'s ghost uses `Long.toHexString` (unsigned, unpadded) while the placed component uses
  `Value.toHexString` (width-aware), so a 4-bit −1 ghosts as `ffffffffffffffff` and settles as `f`.
- `TransmissionGate` reads port `GATE0` into both gate leads, so they always share a colour.

**Deliberately not painted:** `paintIcon*` on every component (toolbar chrome drawn at
`AppPreferences.getIconSize()` in a scaled device space with `TextLayout`: a UI concern under D9,
and nothing a schematic renders is affected), and `PinPoker.paint`, which belongs with the poker
in M7. Both recorded as comments in each file rather than silently skipped.

`ShieldPath` had to be built rather than ported: `PainterShaped.getInputLineLengths` sizes OR/NOR
input leads by stepping one pixel at a time until `GeneralPath.contains` goes false, so
`Path2D.contains` is load-bearing geometry, not a utility call.


- [ ] `RenderScene` API first (D6): shared painters before any individual component draw
- [ ] CoreGraphics backend; viewport culling; cached `CTLine`; no per-component context clone
- [ ] the `paintInstance` ports (75 across 65 files; D6 recorded 109, which was a `paintGhost` count)
- [ ] Reproduce integer grid snapping exactly or every file looks subtly off-grid
- [ ] Pass condition: perceptual image-diff vs Java `ExportImage` at 3 zoom levels

### M7 — Editing
*Status as of 2026-09-06. Every box below cites what was run; the gate is `tools/editbridge` +
`Tests/LogisimUITests/EditParityTests.swift`.*
- [x] `Project` + undo/redo with `shouldAppendTo` coalescing (identity-compared → actions are
      classes). Gate-covered by `07-undo-multipart-delete` and `08-undo-redo`, both byte-matching;
      red-probed by making `Project.redoAction` return early, which reddens `08` **only**.
- [x] Select/Edit/Wiring/Poke/Text/Add tools; `tools/move` background reroute. `09-move-reconnects-wire`
      byte-matches the exact three-wire dogleg the `Connector` routes, and disabling
      `SelectTool.shouldConnect` reddens `09` only. Text editing landed 2026-09-06 (caret, selection,
      word motion, commit, undo). **Not complete:** labels draw and edit for 9 of upstream's 24
      factories: board **#78**, the largest remaining piece of this milestone.
- [x] Deliberate macOS modifier conventions, not literal AWT translation. ⌘A/C/X/V for Control,
      ⌥-arrow for word motion, ⌘←/→ as Home/End, Return commits via `character.isNewline`, and
      Option no longer suppresses typing (⌥5 is ∞ on macOS). A literal AWT transcription gives an
      editor where every one of those chords does nothing, because `keyPressed` returns early on
      any Alt or Meta chord.
- [x] **Pass condition: scripted interaction sequences whose saved `.circ` byte-matches Java:
      10 scripts, 10 byte-match, known-divergence table empty.** The Java side drives real
      `Tool`/`CircuitMutation`/`doAction`/`LogisimFile.write`; every byte of logisim bytecode that
      runs is 4.1.0's. Discrimination proven by five Sources probes each reddening exactly the
      predicted scripts, plus a harness probe (suppress `.dragged`) reddening 6 of 10.
      The gate found #77 on its first run.

### M8 — App shell + ship
- [ ] Document lifecycle, autosave, `.bak` rotation, preferences
- [ ] About window carrying the full GPLv3 §5 notice set (D10)
- [ ] Developer ID signing, notarization, DMG, Homebrew cask
- [ ] Pass condition: notarized DMG passes `spctl -a -vvv`; clean-install opens and simulates

### M9 — Performance
- [ ] Metal backend behind the unchanged `RenderScene` API
- [ ] Spatial index (picking first, culling second)
- [ ] `SimulatorEvent` pooling

### Parity backlog — **re-measured 2026-09-06, and most of it was already done**

This list had gone stale in the way lists do: it was written before M4–M7 and never re-checked, so
it listed four subsystems as pending that had shipped. Corrected by measuring the tree rather than
reading the list: the same method that closed #24 and #78.

- [x] `soc`: **closed as #24.** 78 of 91 files ported, 13 deliberate gaps each now recorded at a
      named file:line, one real factory-identity defect fixed. Corpus grounding: 337 of 576 files
      declare `#Soc`, exactly **one** places a component.
- [x] HDL generation: four families byte-exact against the jar, registry wired and proved reached
      at startup. `LogisimHdl` + `LogisimHdlWiring`.
- [x] Chronogram + Log window; **ported**: `Sources/LogisimUI/Log/` is twelve files
      (`LogWindow`, `LogWindowScene`, `LogChronogramView`, `LogController`, `LogModel`,
      `LogSignalHistory`, `LogFileExporter`, …).
- [x] Appearance editor: closed as #59 (spec from the jar, round-trip, then editing).
- [x] Test-vector runner; `Sources/logisim-cli/TestVectorRun.swift`. The CLI half is done; the
      GUI frame (`gui/test`, 6 upstream files) is unverified.
- [~] **Export image / export project; the menu commands exist AND DO NOTHING (board #97).**
      Recorded as `[x]` until 2026-09-06 on the strength of the menu items existing, which is
      exactly the confusion this port keeps hitting: `canPerform` returns true via its `default:`
      so the items are ENABLED, and `perform` falls to its own `default:` and throws
      `notImplemented`. Five items behave this way: Export Image, Merge Project, Export Project,
      Extract and Run, and Circuit ▸ FPGA Toolchain. Export Image is one arm from working
      (`CircuitRenderSurface.snapshotImage` returns real pixels, asserted); the other four are
      unported subsystems that should return false and grey out.
- [~] `analyze`: reachable (#58 wired it, #68 added the Minimize button that made `forcedOptimize`
      runnable at all). 22 Swift files against 49 upstream, which on its own means nothing: the
      SoC survey found 78 ported files spread across 82 Swift files. **Survey in flight.** The
      recorded hazard to confirm or refute: Java `HashMap` iteration order affects
      Quine-McCluskey/Petrick cover selection, so byte-comparing minimised expressions may not be
      a valid gate. Board #26 is the precedent: the same fear about `HashSet` and simulation
      turned out to be unfounded.
- [~] **Hex editor: BUILT, and unopenable (board #93).** The window and its controller exist
      under `Sources/LogisimUI/Hex/` and the scene is registered in `LogisimEvolvedApp.swift:93`.
      What is missing is the way in: `HexWindowController.open(contents:project:title:)` has
      **zero call sites across all 697 `Sources` files**, and `:93`'s own comment cites an "Edit
      Memory Contents" command that was never written. So the original measurement below no longer
      holds, and the user-visible outcome is unchanged; a RAM's contents still cannot be edited. For a port that exists to serve a
      computer-organisation course, that matters. Upstream is 11 files across `com/cburch/hex`
      (7) and `gui/hex` (4). The model half (`MemContents`) is already ported and must not be
      duplicated. **In flight.**
- [x] **Print: DONE 2026-09-06.** `Sources/LogisimUI/Print/` (5 files) reproduces `MyPrintable`'s
      geometry, header format and rotation gating, and is wired to File ▸ Print (⌘P). Print view
      emits 3 primitives where the screen emits 11 on the same two gates. Gated by `PrintTests`
      (18) and `PrintWiringTests` (6), the latter gating the JOIN: deleting the menu interception
      reddens it. The host builds the scenes so no `Circuit` crosses the project seam.
- [ ] FPGA toolchain (ghdl/yosys/nextpnr/openFPGALoader). The board *model* is done (29/29 boards,
      `LogisimHdl/Fpga/`); the toolchain driver is not, and is 86 upstream files.

**The lesson is the one this project keeps re-learning in new costume:** a to-do list is an
instrument too, and an uncalibrated one. Four of these entries would have had someone port
something that already existed. Before working off a list, measure the list.

### Upstream issues this port closes as a side effect
Worth tracking, since they are the argument for the project existing.
*Audited with evidence on 2026-09-06; `docs/experiments/upstream-issues.md`. All eight were
confirmed still open upstream via `gh issue view` on the day, not from memory. Nothing here is
ticked on an argument; each box cites the measurement or the test.*

- [ ] #2699 Gatekeeper failure + Homebrew cask disablement (upstream **cannot** fix: no Apple
      account): **open**, and ours to close at M8: `spctl -a` rejects the binary today, which is
      an ad-hoc signature and not a bundle
- [x] #747 firewall warning on launch (5 yrs): **closed by construction**: zero network file
      descriptors measured on the running app, and no socket API anywhere in the tree. It was the
      JVM opening a socket; this port never opens one
- [~] #786 GUI redraw (21 comments): **mechanism closed, no oracle**: 2.03 ms/frame at 5,000
      components against upstream's ~20 fps `CanvasPaintCoordinator` cap. Culling and rect
      invalidation are real and measured; "the reported symptom is gone" is not provable without
      the reporters' files
- [ ] #2661 canvas text ignores dark/light switch: **OPEN, and the port claimed otherwise.** Two
      source comments asserted this was fixed. The issue is about a label's per-instance stored
      `ATTR_COLOR`; the port has the same defect and labels are frozen. The comments described a
      genuine improvement to a *different* defect (`Value.java`'s nine static colours) and
      attributing it here is what let the claim stand.
      The audit's aside that `Text` **drew nothing at all** was acted on the same day and is
      fixed (`painted=0 prims=0` → `1/1`); two more defects were found stacked under it, so the
      issue itself stays open: see the Log and board #23
- [x] #1262 better mouse zoom/pan (5 yrs): **closed**, `UpstreamIssue1262Tests`, 6 tests
- [x] #2680 preferences dialogue defects: **closed**, measured window geometry and accessibility
      state on a dual-screen Mac
- [x] #1546 command-line verification cleanup: a real TA autograding tool: **closed**: `-tty
      stats` gated at 1,630/105 of 1,735, `--test-vector` byte-exact on 62 of 62, and the exit-code
      contract pinned against the jar including three deliberate divergences
- [ ] #6 FSM editor (open since 2015): **open**, greenfield, absent from the tree

---

## Current focus

*Rewritten three times on 2026-09-05: twice because it went stale, and again once the app
product and the `ToolCanvas` conformer, the two things the previous version named as blockers,
both landed. If this section and the Status table disagree, the table wins and this section is
what needs fixing.*

**Headless is closed. The app builds, launches, and opens a real editor window.**

Done and gated: M1, M2, M4, M5, the HDL subsystem (four families byte-exact, registry wired and
proved reached at startup), the FPGA board model (29/29 boards), SoC parity (78/91 files, 0
missing), and M6's renderer split. M3 stands at **1,347 byte-exact / 1,347: zero failures**, migration at
**456 / 0**, with 50 more identical but for a random VHDL label, 14 for a host font resolution and
19 where the port keeps strictly more than 4.1.0 does. Scored against `migrated_solo/`: never
`migrated/`, which a batched `canonical.py` run has now silently contaminated twice.

### 1. The two things that gated the app are both gone

**There is an app product, and it was run.** `logisim-evolved-app` builds (19,734,736 bytes) and,
launched unbundled with no `Info.plist`, gets a window out of the window server:

    pid 20322 · window 11028 · "Untitled" · 1280x820 at (116, 98) · isOnscreen: true · layer 0

Not a blank `NSWindow`: explorer sidebar with the Design/Simulate toggle and all twelve library
groups, toolbar, inspector showing `main`'s attributes, zoom at 99%, status "Idle". The canvas is
empty because a new document is `default.templ`'s one empty `main`, which is what
`CanvasWiringTests.newDocumentDraws` already asserts.

**`ToolCanvas` has a conformer.** `CircuitEditorCanvas` holds a surface, a `Project` and a
`Selection` and satisfies the protocol out of the three, rather than making `CircuitCanvasSurface`
carry a project it must not know about -- 82 of `ToolCanvas`'s 124 references are
`canvas.project`/`.selection`/`.circuit`, which is exactly the split D6 and `RenderSeam.swift`
already drew. Twelve round-trip tests drive real `CanvasPointerEvent`s through the same entry
point `CanvasHostNSView` uses. `ToolCanvas` has left the seamcheck baseline.

### 2. The app is wired end to end, and the UI is where the work is now

The join section 2 used to describe is **done**. `makeRenderSurface` builds the editing layer,
`Project.modelGuard` serialises tool edits against the propagation thread, and the host mirrors
the tool layer's `Selection` into its own `EditorSelection` so the inspector follows a canvas
click. Measured: a `doAction` waits 0.313s while another thread holds `modelLock`, against
0.000012s for a pass-through guard.

Two things found by wiring it, both of which had passed every test in the suite:

* **Seam #21; the five tools you edit with were unreachable.** Of 162 tools the explorer offers,
  the controller could drive 157; the five it could not were Edit, Menu, Poke, Wiring and Text.
  Selecting one returned `false`, which every call site discarded, and left the previous tool
  active. `Text Tool` is the sharpest case: **two** `TextTool` types exist, `LogisimFile`'s inert
  `Tool` and `LogisimUI`'s real `CanvasTool`, in different modules so nothing complains, and the
  explorer registers the inert one.
* **The window showed 5 tools where the document declares 17.** `Options.toolbarData` was parsed,
  stored, round-tripped byte-exactly across 539 canonical files, and read by no view. All six
  gates, NOT/AND/OR/XOR/NAND/NOR, were unreachable from the top of the window. Now a palette
  strip under the toolbar, with overflow into a menu.

**~~`MenuTool` is the one base tool with no implementation at all~~ — LANDED 2026-09-06.**
`MenuTool.swift` builds a `MenuToolMenu` value description and the one `NSMenu`, and the whole
chain from a right-click is present: `CanvasHostNSView.menu(for:)` → `delegate.interactionHandler`
→ `LogisimFileProjectHost.canvasContextMenu` → `controller.canvasContextMenu` → `MenuTool`.
Checked hop by hop rather than assumed, because this is the shape that has been wrong 25 times.

Three more claims this section made are also stale, all verified against the source today:
undo/redo is wired end to end (`CommandGroup(replacing: .undoRedo)` → `perform(.undo)` →
`project.undoAction()`); the attribute inspector is presented (`EditorWindow.swift:38`
`.inspector(isPresented:)`) and its bindings commit real edits; and the palette landed. **The UI
is in better shape than this section says: treat every remaining claim here as suspect until
re-checked.**

**The UI has no jar oracle, and today produced the first hard evidence of what that costs.** An
audit of the eight upstream issues (`docs/experiments/upstream-issues.md`) reversed a claim made
in two source-file comments: #2661 is **open**, canvas labels are frozen, and `Text` draws
nothing. The comments asserting otherwise had described a real improvement to a *different*
defect, `Value.java`'s nine static colours, and attributing it to #2661 is what let the claim
stand. Verdicts: three closed with evidence, one closed by construction, one partly closed, two
open.

### 3. Know what changes when the UI starts

Every gate that has caught a real defect here diffs against the jar: 1,392 simulation oracles,
952 HDL cases, 29 boards, 33,124 `Value` cases. **The UI has no oracle.** The technique that has
found nearly every defect in this port stops applying, and verification drops toward "it looked
right". Expect more iteration per unit of progress, and build the checkable parts, scene
primitive counts, hit-test geometry, `ExportImage` perceptual diffs, rather than assuming the
old leverage carries over.

**And audit gates as well as code.** `rig.py`'s simulation mode was structurally dead for its
whole existence because an all-fail reading was the documented expectation. `tools/gateaudit.py`
now asks of each gate: can it fail, can it pass, does it skip silently. Four gate defects were
found that way today, including a canonical column that a literal `cp` satisfies.

### 4. The queue as of 2026-09-06 — the menu surface promises more than the wiring delivers

Every open board now has the same shape, and naming it is more useful than the individual items:
**a control the user can reach, behind which the join is missing.** Not one of these is a missing
algorithm; all the hard parts are built, tested, and in most cases byte-exact against the jar.

Working end to end, gated, as of today: Print (⌘P), undo/redo for all six structural file
operations, circuit rename, the Analyze window's Expression tab, the palette, the context menu.

| # | the control | what happens when a user uses it |
|---|---|---|
| 97 | File ▸ Export Image, Merge Project, Export Project, Extract and Run; Circuit ▸ FPGA Toolchain | **enabled**, and `perform` throws `notImplemented`: a "Command unavailable" banner. `canPerform`'s `default: return true` enables them; `.loadJarLibrary` and `.revertAppearance` correctly return `false` and grey out |
| 93 | the hex memory editor | the window exists and registers a scene; `HexWindowController.open` has **zero call sites** in 697 `Sources` files, and the app file's comment cites a menu command that was never written |
| 98 | the Signal Log window | raisable from the Window menu; `LogController.attach` has no callers, so it can only ever show its empty state |
| 99 | matrix placement (a keystroke) | the matrix **preview draws** and the click places one component; `matrixPlacement` is read and assigned by nothing |
| 99 | every model-layer diagnostic | `Circuit.diagnosticReporter` is assigned in tests only, so `.emptyCircuitName`, `.circuitNameMatchesPinLabel` and `.labelCollision` go nowhere |
| 88 | "please locate this library" repair | `LoaderUI` has no app-shell conformer, so a load problem cannot be repaired |
| 89 | Save / autosave | `serialize()` clears the dirty flag at snapshot time, and `fileURL` goes stale after Save As |

Export Image is the one worth doing first: `CircuitRenderSurface.snapshotImage` already returns
real pixels (asserted), so it is an `NSSavePanel` and an encoder away. The other four commands in
#97 are genuinely unported subsystems and the honest fix there is to return `false` and grey them.

**Why this shape keeps recurring, stated plainly so it can be designed against.** The port's
verification leverage is the jar oracle, and the oracle can only see what a `.circ` file or a CLI
run produces. A menu item that never fires changes no bytes, so every gate stays green. That is
not a gap in diligence; it is the predicted cost of §3 above arriving. The countermeasure that has
actually worked is the one used for Print: gate the JOIN, not the machinery; assert that
performing the command reaches the thing that does the work, and red-probe by deleting the
interception.

## Release plan — 0.1.0 in waves, 1.0.0 at parity

Owner decision, 2026-09-08: ship 0.1.0 once the core is solid and native, then drive to 1.0.0 =
full parity with 4.1.0. Recorded here because the cut line is a scoping decision that must not be
confused with D11's retired "permanent gap" disposition.

**The distinction that matters, since it was got wrong once already.** Greying a feature out
*forever* and calling it honest is a missing feature with better manners; D11 retires that.
Scoping a *release* is different and legitimate. The rule for 0.1.0: a feature not in this release
is **absent or visibly marked "not in this release"; never enabled and throwing.** A
"Command unavailable" banner reads as broken software; a missing menu item reads as a young
release. Parity remains the 1.0.0 contract, and every deferral is listed in the README.

**Why ship early at all, beyond impatience: users are the oracle this project does not have.**
Every gate here diffs against the jar, and the jar oracle only sees what a `.circ` file or a CLI
run produces. A menu item that never fires changes no bytes, so the whole UI is unverifiable by
the technique that found nearly every other defect; that is how Print shipped complete and
unreachable, and how 24 dead menu items went unnoticed until they were counted. Real users on real
coursework are the substitute oracle. Getting them earlier is a verification decision, not only a
product one.

### 0.1.0 — "it is a real Logisim, and it is native"

- [x] Open, edit, save, simulate: jar-verified: M3 1,347/1,347, canonical 539/0, migration 456/0
- [x] Editing: select/wire/poke/text/add tools, undo/redo, palette, context menus, Print
- [ ] **Selection geometry** (7 commands): routing only; `EditTool` / `SelectionEditHandler` already implement it
- [ ] **Auxiliary windows**: Log, Chronogram, Analyze, Statistics. Mostly routing; `LogisimUI/Log/` is 12 ported files and Analyze already has its Expression tab
- [ ] **Hex editor** (#93): built and unopenable. For a computer-organisation course, editing RAM/ROM contents *is* the assignment, not a nice-to-have
- [ ] **Export Image** (#97); students put circuits in lab reports. `snapshotImage` already returns real pixels
- [ ] **Every remaining inert command made absent, not throwing**: one pass over `canPerform`, reversed as each feature lands
- [ ] **GPLv3 §5 notices + upstream credit** (D10): a legal obligation, not polish
- [ ] **Signed, notarized, DMG**: not optional for any public release

### 1.0.0 — full parity with 4.1.0

- [ ] **JAR component libraries**: the JVM subsystem. Measured demand: 5 of 593 corpus files, and
      they are `cs3410.jar` (Cornell CS3410), three CDM course libraries, `logi6502`,
      `logisim-time`. Rare by count, and concentrated in exactly this port's audience. See D19
- [ ] **FPGA Commander**; 86 files; the board model is already done, 29/29
- [ ] **VHDL entities**: `addVhdlEntity`, `importVhdl`
- [ ] **SoC UI**; the model is 78/91 files with 0 missing
- [ ] **`std/tcl`**: `tclsh` subprocess
- [ ] Everything else the command-surface audit still lists as inert

### The README carries the gap, generated not hand-written

`CommandSurfaceAuditTests` already measures exactly what works. The README's "what works today"
table should be generated from it, so it cannot go stale and cannot flatter. A young project with
an accurate feature table is disarming; one with a hand-written table is embarrassing the first
time someone checks.

## Log

The dated engineering log lives outside this repository. It is a working notebook: what was
measured on which day, which theories were wrong, and how each number above was arrived at.
The decisions it produced are in `docs/decisions.md`, the state it produced is above, and
every claim either is gated by a test or says that it is not.
