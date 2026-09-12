# M2 re-verified against 4.1.0, not main — tasks #15 and #19

Run 2026-09-05. Every number below was produced by a command in this document, on this machine,
today. Reference tree `~/Developer/logisim/upstream-java-4.1.0` (D16); comparison tree
`~/Developer/logisim/upstream-java` (main, `4.2.0-dev`); oracle
`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`.

Baseline reproduced before any change:

```
swift build                 0 errors
rig.py --roundtrip          canonical 539 / 0   migration 434 / 105   transformed 500
swift test --filter LogisimFileTests   exit 0
```

---

## 1. Task #19 is stale — close it

Claim: "6 failing M2 tests, several encode wrong expectations."

```
$ swift test --filter LogisimFileTests
EXIT=0
Test run with 94 tests in 0 suites passed after 0.015 seconds.
   Executed 46 tests, with 0 failures (0 unexpected)
```

140 tests (94 swift-testing + 46 XCTest), **0 failures**. The codec gates are unchanged at
canonical 539/0 and migration 434/105. There are no failing M2 tests. This is the fourth stale
premise this session.

---

## 2. The 4.1.0-vs-main behavioural diff over the codec surface

Method: `diff -r` over `com/cburch/logisim/file/`, plus `data/Attributes.java`,
`circuit/CircuitWires.java`. Cosmetic-only differences (whitespace, `@SuppressWarnings`,
pattern-variable renames) are omitted.

**`considerRepairs` is byte-identical between the two trees.** The whole `XmlReader.java` diff is
two hunks, neither in the migration passes. No migration decision differs between 4.1.0 and main.
That is the single most reassuring result here, and it is a verified negative.

| # | Difference | 4.1.0 | main (4.2.0-dev) | Port implements | Verdict |
|---|---|---|---|---|---|
| W1 | `XmlWriter.stringCompare(null, null)` | `-1` (inconsistent comparator; TimSort reverses tied runs) | `0` | **4.1.0** | correct, and documented at `XmlWriter.swift:715` |
| W2 | `findLibrary` / `libraryContains` / `Library.contains` | flat, depth 1 | recurses into sub-libraries | **4.1.0** | correct, documented at `XmlWriter.swift:1021` |
| W3 | `Image.ATTR_LICENSE` force-write in `addAttributeSetContent` | absent (`std.base.Image` does not exist in 4.1.0) | present | **4.1.0** | correct, documented at `XmlWriter.swift:320` |
| W4 | `<vhdl>` gets an `appearance=` attribute on write | no | yes | **4.1.0** | correct; `VhdlContentSaving` deliberately omits `getAppearance()` |
| W5 | `<wire buswidthpos=…>` written | no (`BUS_WIDTH_POS` does not exist anywhere in 4.1.0) | yes | **main** | deliberate, documented at `XmlWriter.swift:1372`; unreachable on 4.1.0-authored input |
| W6 | `out.flush()` after `tf.transform` | no | yes | n/a | no Swift analogue |
| W7 | bundle library paths via `ProjectBundlePaths` | `split(Pattern.quote(File.separator))` + `LineBuffer.format` | `ProjectBundlePaths.libraryEntry/Descriptor` | seam (`BundleSink`) | not exercised by the gate |
| R1 | `ReadContext.findTool` recursive sub-library lookup, used by `toTool` and `XmlCircuitReader.getComponent` | absent: flat `lib.getTool(name)`, throws `toolNotFound` | present | **4.1.0** | correct, documented at `XmlReader.swift:775` and `XmlCircuitReader.swift:94` |
| R2 | `<vhdl appearance=…>` parsed on read | no | yes | **main** | `XmlReader.swift:694`, see §3.2 |
| R3 | `initLegacyVhdlAppearance`: a `VhdlEntity` `<comp>`'s `<a name="appearance">` also pushed onto the content object | no | yes | **main** | `XmlCircuitReader.swift:151`, see §3.2 |
| R4 | `<wire buswidthpos=…>` parsed | no | yes | **main** | pair of W5, deliberate |
| F1 | `LogisimFile.isNameInUse` / `isNameInLibraries` | `equalsIgnoreCase` | `SyntaxChecker.namesEqualForCurrentHdl` | **main in shape, 4.1.0 in behaviour** | see §3.3 |
| F2 | `xmlConversionError` message | `if (msg == null) err += ": " + msg`; appends `": null"` when there is no message, nothing when there is | `if (msg != null)` | **main** | error text only; see §3.4 |
| F3 | `public write(OutputStream, LibraryLoader, File)`, `createEmpty` | absent | present | n/a | already recorded in D16 |
| L1 | `LibraryManager.toRelative` current-directory side | raw `currentDirectory.toString()` | `currentDirectory.getCanonicalPath()` | **main** | **DEFECT: see §3.1** |
| L2 | `loadLogisimLibrary` cache key | `findKnown(File)` | `findKnown(descriptor)` | n/a | caching only |
| L3 | `Loader.getFileFor` normalises `\` to `/` in a descriptor | no | yes (`ProjectBundlePaths.normalizeLibraryDescriptorPath`) | **main** | `Loader.swift:239`; read-side only, resolves Windows-authored descriptors 4.1.0 would prompt for |
| L4 | `LoadedLibrary.setBase` `componentMap` | `componentMap.put(oldFactory, tool.getFactory())`: maps the OLD factory to itself, a copy-paste bug | `newAddTool.getFactory()` | **main** | `LoadedLibrary.swift:132`; library-reload path, unreachable from the CLI |
| A1 | `Attributes.forMultilineString` / `MultilineStringAttribute` | absent | present | **main, but dead** | declared at `LogisimKernel/Attributes.swift:592`, **zero call sites**. Inert today; a future tranche wiring it would silently change `toStandardString` bytes. Recommend deleting or marking. |
| C1 | `CircuitWires.getWireBusWidthPos/setWireBusWidthPos` | absent | present | **main** | storage half of W5/R4. No change to `getWires()` ordering, so nothing else in the write path moves. |

Not audited (outside the codec surface named in the brief, and they do differ): `circuit/Circuit`,
`CircuitState`, `Simulator`, `SplitterAttributes`, `SubcircuitFactory`, `tools/AddTool`,
`tools/WiringTool`, `circuit/appear/*`. `circuit/WireRepair.java` and
`circuit/CircuitTransaction.java` are **identical** between the trees, which is what licenses §4.

---

## 3. The four items where the port follows main

### 3.1 `LibraryManager.toRelative` — a real bytes-written defect

This is the only finding here that changes what a saved `.circ` contains.

4.1.0 canonicalises **only the file side** and compares it against the raw directory string:

```java
var fileName = file.toString();
try { fileName = file.getCanonicalPath(); } catch (IOException e) { }
if (currentDirectory != null) {
  final var currentParts = currentDirectory.toString().split(Pattern.quote(File.separator));
  //                       ^^^^^^^^^^^^^^^^^^^^^^^^^^ raw, NOT canonical
```

main changed that to `currentDirectory.getCanonicalPath()`. `LibraryManager.swift:92-98` resolves
**both** sides:

```swift
fileName = file.resolvingSymlinksInPath().standardizedFileURL.path
let currentDirectoryPath =
  currentDirectory.resolvingSymlinksInPath().standardizedFileURL.path
```

Driven through the shipped jar's own private `toRelative` (`tools/m2audit/RelativeBridge.java`,
reflective; asserts it produced output) against the same three inputs run through a verbatim
reproduction of the Swift lines:

| current directory | library file | **4.1.0 jar** | **Swift port** |
|---|---|---|---|
| `/tmp/m2audit/proj` | `…/proj/libs/helper.circ` | `../../../private/tmp/m2audit/proj/libs/helper.circ` | `libs/helper.circ` |
| `/private/tmp/m2audit/proj` | `…/proj/libs/helper.circ` | `libs/helper.circ` | `libs/helper.circ` |
| `/Users/me/m2audit_link/proj` (symlink) | `…/proj/libs/helper.circ` | `../../m2audit_real/proj/libs/helper.circ` | `libs/helper.circ` |

Two of three disagree. The string goes verbatim into `<lib desc="file#…">` and `jar#…`. It is not
an exotic path: on macOS `/tmp`, `/var` and therefore every `$TMPDIR` are symlinks into
`/private`, so any harness that puts a project and its libraries in a temp directory hits row 1.

Note the Swift also diverges on the *file* side, differently: Foundation's
`resolvingSymlinksInPath()` deliberately does **not** resolve `/tmp` and `/var`, where Java's
`getCanonicalPath()` does. So the port is neither 4.1.0 nor main here; it happens to coincide
with main on these inputs.

**Change request** (`swift/Sources/LogisimFile/LibraryManager.swift`, not mine to edit):

```swift
  static func toRelative(_ loader: Loader, _ file: URL) throws -> String {
    // Java: `var fileName = file.toString(); try { fileName = file.getCanonicalPath(); } catch …`
    let fileName = LibraryManager.javaCanonicalPath(file)

    if let currentDirectory = loader.currentDirectory {
      // D16: 4.1.0 uses the RAW `currentDirectory.toString()` here. 4.2.0-dev changed it to
      // `getCanonicalPath()`; porting that fix rewrites `<lib desc="file#…">` whenever the
      // project is opened through a symlink (on macOS, anything under $TMPDIR).
      let currentDirectoryPath = currentDirectory.path
      …
```

and `javaCanonicalPath` must be `getCanonicalPath`, not `resolvingSymlinksInPath`: resolve the
deepest **existing** ancestor with `realpath(3)` and re-append the remaining components, since
`getCanonicalPath` resolves symlinks for the components that exist and normalises the rest
lexically. Pin it with the three rows of the table above; `RelativeBridge` regenerates them.

Also note `Loader.currentDirectory` must itself be stored raw, not normalised, or the fix is
undone one layer down.

### 3.2 VHDL appearance is read but not written — an asymmetry, currently dormant

`XmlReader.swift:694` parses `<vhdl appearance=…>` and `XmlCircuitReader.swift:151` runs
`initLegacyVhdlAppearance`; both are main-only. Neither is reachable today; the first sits behind
`guard let handler = VhdlContentReader.handler`, which is nil at this milestone, and the second
behind `source as? any VhdlEntityFactory`. The write side correctly omits it (W4).

Low severity, but the asymmetry is the shape D8 warns about: whoever installs the VHDL handler
inherits a reader that consumes an attribute the writer will never emit. Either drop both reads
(strict D16) or record them next to W4 the way `fromWire` records W5. **Do not** add the write
side; that would put an attribute in the output the oracle never writes.

### 3.3 `namesEqualForCurrentHdl` — main's shape, 4.1.0's behaviour

`LogisimFile.swift:650, 662` call `HdlNames.namesEqualForCurrentHdl`, which is main's API. It is
behaviourally identical to 4.1.0's `equalsIgnoreCase` **as long as `HdlNames.current == .vhdl`**.
Grepped: nothing in `Sources/` or `Tests/` ever assigns `HdlNames.current`, so it is permanently
`.vhdl` and the two agree. If anything ever sets it to `.verilog`, duplicate-name detection
silently becomes case-sensitive where 4.1.0 stays case-insensitive. No action needed now; worth a
one-line note at the declaration.

### 3.4 `xmlConversionError` — cosmetic

`LogisimFile.swift:768` appends the message when there is one. 4.1.0 does the opposite
(`if (msg == null) err += ": " + msg`, so it appends the literal `": null"` and drops real
messages). Error-dialog text only, never a saved byte. Fixing upstream's typo here is defensible;
it just wants recording as a knowing divergence rather than an oversight.

---

## 4. The 105 migration failures, grouped by cause

`rig.py --roundtrip` counts all 539; `migreport.py` excludes the 67. `105 = 67 + 38`.

| cause | count | is it a port defect? |
|---|---|---|
| **A.** the 4.1.0 jar is not reproducible against itself | **67** | no |
| **B.** `WireRepair` is disabled behind `LOGISIM_WIRE_REPAIR`, gated on one `LogisimStd` bug | **22** | yes, and fixable today |
| **C.** D8: the port preserves a builtin library 4.1.0 silently drops | **10** | no, deliberate, D8 |
| **D.** AWT substitutes `Dialog` for a font family not installed on the generating machine | **6** | no, machine-dependent oracle |
| | **105** | |

### A — 67 files the jar cannot reproduce, confirmed rather than trusted

Ran `CircBridge` over all 67 twice, in two separate JVMs, and diffed the pairs
(`/tmp/m2audit/nondet_check.py`):

```
selected 67  ·  jar disagrees with itself 67  ·  reproducible 0  ·  no output 0
of the disagreements, label/uuid-shaped only: 64

example diff (2.7.0__case-248.circ__…):
    -      <a name="label" val="Bn_1_83ef75d6"/>
    +      <a name="label" val="Bn_1_01b75253"/>
```

All 67 differ from themselves. The 3 that were not classified as "label-shaped" by the crude
filter were inspected individually: their extra lines are hunk context (`<a name="facing">`,
`</comp>`) displaced by a nearby label change, not a second nondeterminism class. **The exclusion
is sound and the count is exactly 67.**

### B — WireRepair, worth +22 at zero canonical cost, and the blocker is two lines

`CircuitTransaction.execute()` repairs wires after every transaction and loading a file is a
transaction, so the wire set 4.1.0 saves is not the wire set it read. `WireRepair.swift` ports it,
but `XmlCircuitReader.swift:645` only calls it when `LOGISIM_WIRE_REPAIR` is set, because a ROM
port-offset bug in `LogisimStd` made it regress the canonical gate.

Worked example, `2.7.0__case-471.circ`. Source has one wire
`(430,210)→(480,210)` and one `J-K Flip-Flop` at `loc=(430,210)`; the oracle writes
`<a name="appearance" val="logisim_evolution"/>` for it, and `AbstractFlipFlop.updatePorts`'s
non-classic branch puts `ps[numInputs + 4] = new Port(20, 0, …)` at `(450,210)`. `doSplits` cuts
there. With repair off the port emits the single unsplit wire.

Measured, all four ways, today:

| | canonical | migration |
|---|---|---|
| repair off (HEAD as shipped) | 539 / 0 | 434 / 105 |
| repair on, no other change | 519 / 20 | 440 / 99 |
| repair on + the ROM fix below | **539 / 0** | **456 / 83** |

The third row is the one that matters: **+22 migration, zero canonical regression.** It exactly
reproduces the projection recorded in `XmlCircuitReader.swift:592-598`, which is worth saying
plainly given this project's history with unverified projections.

The fix I measured (applied locally, then reverted; `LogisimStd/Memory` is not mine):

```swift
// RamAppearance.swift
public static func ports(_ attrs: any AttributeSet, xposOverride: Int? = nil) -> [Port] {
  …
  let xpos = xposOverride ?? offsetBounds(attrs).width

// Rom.swift
public override func ports(_ attributes: any AttributeSet) -> [Port] {
  RamAppearance.ports(attributes, xposOverride: offsetBounds(attributes).width)
}
```

Upstream passes the *instance's* width, `getDataOutPort(i, attrs, instance.getBounds().getWidth())`
(`RamAppearance.java:183`), and a ROM's bounds come from `Rom.getOffsetBounds`, which is
`SymbolWidth + 40 = 240` in both branches, whereas `RamAppearance.getBounds` is
`SymbolWidth + xoffset = 250` in the non-classic branch. Every ROM therefore carried its data-out
port 10 units too far right.

`Ram` already agrees with itself (`Ram.offsetBounds` *is* `RamAppearance.offsetBounds`), so the
override only has to be threaded through `Rom`; a named parameter rather than a second entry point
keeps `DualRam` untouched. Then delete the `LOGISIM_WIRE_REPAIR` check and the note above it.

This is the same defect as task #47 ("the single ROM bug behind 13 of the 16 real M3 defects").
One fix, two gates. Cheapest item on the board.

### C — 10 files where D8 beats the oracle

Counted by cause rather than by file: for every one of the 539, the set of `<lib desc="#…">` in the
source minus the set in the Java baseline is the set 4.1.0 dropped.

```
files where the 4.1.0 oracle dropped >= 1 builtin lib:  10 outside the excluded set, 8 inside
dropped lib names: #Risc-V (18), #Yosys Components (17)
```

10 is exactly the size of the residual bucket. Example diff (`conv_ser_par_handmade`): the port
emits `<lib desc="#Risc-V" name="8">` with its two `RV32IM` tools; the oracle emits nothing,
having destroyed them on load (D8's measured "one component destroyed by a plain open-and-save").

These are not port defects; they are D8 working. They should move into an
`_unreproducible.json`-style exclusion alongside the 67, with the reason recorded, so the
migration column stops charging the port for being non-destructive. That is task #48's shape.

### D — 6 files where the oracle depends on the fonts installed on the generating machine

```
$ java -cp out FontProbe "Ubuntu Sans Mono bold 18" "Courier 10 Pitch plain 12" "Helvetica plain 12"
Ubuntu Sans Mono bold 18   name=Ubuntu Sans Mono    family=Dialog     standard=Dialog bold 18
Courier 10 Pitch plain 12  name=Courier 10 Pitch    family=Dialog     standard=Dialog plain 12
Helvetica plain 12         name=Helvetica           family=Helvetica  standard=Helvetica plain 12
```

`Attributes.FontAttribute.parse` is `Font.decode(value)` and `toStandardString` is
`String.format("%s %s %s", font.getFamily(), …)` (`Attributes.java:184-196`). `Font.decode`
preserves the requested **name** but `getFamily()` reports `Dialog` for a family AWT cannot find,
so the oracle rewrites any uninstalled font family to `Dialog` on save. The port preserves the
requested name.

Affected: 3 × `<a name="font">`, 1 × `<a name="labelfont">`, 2 × `<text font-family=…>` inside a
circuit appearance (one file has both).

**This oracle is not portable.** The baseline was generated on this Mac; on a machine with Ubuntu
Sans Mono installed the same jar writes the name back unchanged. Matching it would mean
replicating AWT's font-availability lookup through CoreText and getting the same answer, which is
neither guaranteed nor worth it. Recommend the same treatment as C: exclude with the reason
recorded, and note it in D-something so it is not rediscovered as a codec bug.

---

## 5. Bottom line

* **#19: close it.** No failing M2 tests; 140 pass.
* **#15: the M2 codec is overwhelmingly correct against 4.1.0.** All five places where the two
  trees disagree in a way that changes bytes written or elements read on real corpus input,
  `stringCompare`, flat library lookup, `ATTR_LICENSE`, flat `getTool`, no `<vhdl appearance>`,
  are already 4.1.0-side, and each is documented in the source with the measurement that settled
  it. `considerRepairs` does not differ between the trees at all, so no migration decision was
  ever at risk.
* **One genuine D16 defect: `LibraryManager.toRelative` (§3.1)**, proven against the jar.
* **Three main-isms that are currently inert** and want a decision, not a fix: the VHDL appearance
  reads (§3.2), `namesEqualForCurrentHdl` (§3.3), dead `forMultilineString` (A1).
* **The 105 contains at most 22 port defects, and one two-line change removes all 22**: verified,
  not projected: canonical 539/0, migration 456/83.

## Reproducing this

```
tools/m2audit/RelativeBridge.java   # 4.1.0's private toRelative, reflectively
tools/m2audit/FontProbe.java        # FontAttribute's round-trip on the oracle's JDK

javac -cp $JAR -d tools/m2audit/out tools/m2audit/RelativeBridge.java
java -Djava.awt.headless=true -cp $JAR:tools/m2audit/out \
     com.cburch.logisim.file.RelativeBridge <mainFile> <libraryFile>

export LOGISIM_CORPUS=/path/to/corpus
python3 tools/difftest/rig.py --roundtrip --max-fail 0 --jobs 6
python3 tools/difftest/migreport.py --jobs 8 --show 20
LOGISIM_WIRE_REPAIR=1 python3 tools/difftest/rig.py --roundtrip --max-fail 0 --jobs 6
```

Both bridges assert they produced output and exit non-zero otherwise; a drivable entry point that
writes nothing and exits 0 looks exactly like agreement.
