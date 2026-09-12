// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE `<lib>`-DROP DIVERGENCE, PINNED WITH UPSTREAM'S OWN OUTPUT
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// This file exists because the migration gate reports 19 failures that are NOT port defects,
// and that has now been re-opened as a task twice. `LibraryResolutionTests` already pins the
// unit-level behaviour, `#Risc-V` resolves to a `MissingLibrary`, but nothing pinned the
// whole-file consequence, which is the part that shows up in the gate and the part that gets
// mistaken for a bug. Read this before proposing that the port drop an unresolvable `<lib>`.
//
// ── What upstream 4.1.0 does, measured ─────────────────────────────────────────────────────
//
// `PROBE` below is a synthetic 4.1.0-format file: `source="4.1.0"`, so no `considerRepairs`
// pass runs and the ONLY variable is library resolution. Run through the jar's own converter:
//
//     javac -cp $JAR -d out tools/valuebridge/CircBridge.java
//     printf 'probe.circ\tprobe.java.circ\n' \
//       | java -Djava.awt.headless=true -cp "$JAR:out" com.cburch.logisim.file.CircBridge
//
// stdout `OK<TAB>probe.circ`, 1099 bytes written. (Assert the oracle WROTE something; an entry
// point that exits 0 having written nothing looks exactly like agreement, and that has fooled
// this project twice.) `UPSTREAM_OUTPUT` is that file, byte for byte.
//
// Four things happen there, and none of them is a remap:
//
//   1. `LibraryManager.loadLibrary` case "" cannot find `#Risc-V` in the builtin list, calls
//      `loader.showError(S.get("fileBuiltinMissingError", name))` and returns **null**
//      (`LibraryManager.java:262-265`). Under `Main.headless` (D17) that error is a log line;
//      with a GUI it is a modal dialog.
//   2. `XmlReader.toLibrary` returns early on null, so the name is never entered into
//      `ReadContext.libs` and `file.addLibrary` is never called (`XmlReader.java:365`, `:423-433`).
//   3. Every later reference to that name therefore fails resolution, not by being renumbered:
//      `findLibrary` throws `XmlReaderException(libMissingError)` (`XmlReader.java:109-114`),
//      `XmlCircuitReader.getComponent` propagates it, and the catch at
//      `XmlCircuitReader.java:225` calls `addErrors` and **simply does not add the component**.
//      The `<toolbar>` entry goes the same way through `toTool`. So `RV32IM`, a real placed
//      component with a user's label on it, is destroyed, and the toolbar entry with it.
//   4. The renumbering is pure fallout of write order. `XmlWriter.fromLibrary` assigns
//      `Integer.toString(libs.size())` as it walks `file.getLibraries()` (`XmlWriter.java:375-384`)
//      and `fromComponent`/`fromTool` look the library up in that same map (`:347-355`, `:501-509`).
//      There is no remap table anywhere in the codebase. `#Base` is written as 3 in, 2 out
//      because the library ahead of it is gone, and every surviving reference follows.
//
// ── Which side of D8 this falls on, and why it is not a close call ─────────────────────────
//
// It is D8, and D8's own text says so: it decides "unrecognized `<comp>`/`<lib>` XML", and it
// names `#Yosys Components` and `#Risc-V` as the motivating corpus cases. The counter-argument
// on the table was that D8 covers content the port does not UNDERSTAND, whereas a library
// reference is something the port RESOLVES, and this one resolved to nothing. That distinction
// does not survive contact with the data, for two independent reasons:
//
//   * **The `<lib>` guarantee and the `<comp>` guarantee are one guarantee.** A preserved
//     `<comp lib="2" name="RV32IM">` is only meaningful while index 2 still denotes the library
//     it denoted on input. Drop the `<lib>` and the writer's positional numbering slides every
//     later index down, so the preserved component either binds to the WRONG library or has to
//     be dropped too, which is exactly the destruction D8 exists to prevent. There is no
//     coherent half-measure.
//   * **Dropping the libraries would not fix a single failing file.** Measured across the 18
//     18 cases of one harvested repository: 13 of them ALSO diverge because the port preserves `<comp>` elements whose
//     *tool name* 4.1.0 lacks, `BitLabeledTunnel`, `Logical AND Gate`, `Dynamic Shifter`, and
//     `BitLabeledTunnel` comes from `#Wiring`, a library that resolves perfectly. Together the
//     18 files preserve **389 components upstream destroys**, 311 of them `BitLabeledTunnel`.
//     `3.0.0__case-508.circ` alone keeps 19 of them, including every one of its labelled I/O tunnels. So
//     the library question is not even the load-bearing half.
//
// The 19th file, `2.7.1__case-338.circ`, is the same decision reached by the second route: a
// `<comp lib="1" name="Constant">` where lib 1 is `#Gates`, which has no `Constant` tool.
//
// **Conclusion: the port's behaviour is correct and upstream's is the data-destroying anomaly.
// The migration gate's 19 failures are a deliberate, documented divergence, not a defect.**
// Nothing in this file should be "fixed" to make the gate green. If the gate is ever changed,
// the right change is a fourth column that counts D8 divergences separately, the same
// treatment the VHDL-label and font-family classes already get, not a change to the codec.

import Foundation
import Testing

@testable import LogisimFile

// MARK: - Fixtures

/// A 4.1.0-format file that exercises every path a dropped library touches: a `<comp>` using it,
/// a `<toolbar>` entry using it, a `<mappings>` entry after it, and survivors on both sides.
private let PROBE = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  This file is intended to be loaded by Logisim-evolution v4.1.0(https://github.com/logisim-evolution/).

  <lib desc="#Wiring" name="0"/>
  <lib desc="#Gates" name="1"/>
  <lib desc="#Risc-V" name="2">
    <tool name="RV32IM">
      <a name="contents">addr/data: 10 32
0
</a>
    </tool>
  </lib>
  <lib desc="#Base" name="3">
    <tool name="Text Tool">
      <a name="font" val="SansSerif plain 12"/>
    </tool>
  </lib>
  <main name="main"/>
  <options>
    <a name="gateUndefined" val="ignore"/>
    <a name="simlimit" val="1000"/>
    <a name="simrand" val="0"/>
  </options>
  <mappings>
    <tool lib="3" map="Button2" name="Menu Tool"/>
  </mappings>
  <toolbar>
    <tool lib="3" name="Poke Tool"/>
    <tool lib="2" name="RV32IM"/>
    <tool lib="1" name="AND Gate"/>
  </toolbar>
  <circuit name="main">
    <a name="circuit" val="main"/>
    <a name="clabelfont" val="SansSerif plain 12"/>
    <comp lib="0" loc="(100,100)" name="Pin"/>
    <comp lib="2" loc="(200,200)" name="RV32IM">
      <a name="label" val="cpu"/>
    </comp>
    <comp lib="1" loc="(300,300)" name="AND Gate"/>
  </circuit>
</project>

"""

/// What the 4.1.0 jar writes for `PROBE`, verbatim. Not reasoned about; captured from
/// `CircBridge` (command in the header). Present so the divergence is stated as a fact about
/// upstream rather than as an assumption about it.
private let UPSTREAM_OUTPUT = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  This file is intended to be loaded by Logisim-evolution v4.1.0(https://github.com/logisim-evolution/).

  <lib desc="#Wiring" name="0">
    <tool name="Pin">
      <a name="appearance" val="classic"/>
    </tool>
  </lib>
  <lib desc="#Gates" name="1"/>
  <lib desc="#Base" name="2">
    <tool name="Text Tool">
      <a name="font" val="SansSerif plain 12"/>
    </tool>
  </lib>
  <main name="main"/>
  <options>
    <a name="gateUndefined" val="ignore"/>
    <a name="simlimit" val="1000"/>
    <a name="simrand" val="0"/>
  </options>
  <mappings>
    <tool lib="2" map="Button2" name="Menu Tool"/>
  </mappings>
  <toolbar>
    <tool lib="2" name="Poke Tool"/>
    <tool lib="1" name="AND Gate"/>
  </toolbar>
  <circuit name="main">
    <a name="circuit" val="main"/>
    <a name="clabelfont" val="SansSerif plain 12"/>
    <comp lib="0" loc="(100,100)" name="Pin">
      <a name="appearance" val="classic"/>
    </comp>
    <comp lib="1" loc="(300,300)" name="AND Gate"/>
  </circuit>
</project>

"""

// MARK: - Harness

/// Records what a human would have been shown, so "was the user told?" is assertable.
private final class RecordingLoaderUI: LoaderUI {
  var errors: [String] = []
  var messages: [String] = []

  func showError(_ description: String) { errors.append(description) }
  func showMessage(_ message: String) { messages.append(message) }
  func autosaveDisposition(for file: URL, autosave: URL) -> AutosaveDisposition { .ignore }
  func chooseFile(prompt: String, kind: LoaderFileKind, startingAt: URL?) -> URL? { nil }
}

private struct RoundTrip {
  let text: String
  let errors: [String]
}

/// Identities of the elements whose survival is the actual claim: `<lib>` by descriptor, `<comp>`
/// by name and location, and the `<toolbar>`/`<mappings>` `<tool>` entries by name and mapping.
///
/// Three exclusions, each because including it would measure something other than the divergence:
///
///   * **The library index.** A `<lib>` is keyed by `desc` and never by `name="N"`; that digit is
///     exactly what upstream's renumbering moves, so keying on it would make every survivor look
///     lost. `<comp>`/`<tool>` likewise contribute `name`/`loc`/`map` and never their `lib="N"`.
///   * **`<a>` attribute children.** Only a registered factory emits attribute defaults, and this
///     target links no `LogisimStd`.
///   * **`<tool>` elements nested inside a `<lib>`.** Those appear only when a tool carries
///     non-default attribute state, which is the same factory dependence; upstream writes a
///     `<tool name="Pin">` block that nothing in this process could produce. They are told apart
///     from real toolbar/mapping entries by the `lib=` attribute, which only the latter carry.
private func elementIdentities(_ document: String) -> Set<String> {
  var found: Set<String> = []
  for raw in document.split(separator: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("<") else { continue }
    guard let tag = line.dropFirst().split(separator: " ").first.map(String.init) else { continue }
    guard ["lib", "comp", "tool"].contains(tag) else { continue }
    if tag == "tool" && !line.contains(" lib=\"") { continue }

    func value(_ key: String) -> String? {
      guard let start = line.range(of: key) else { return nil }
      guard let end = line[start.upperBound...].firstIndex(of: "\"") else { return nil }
      return key + line[start.upperBound..<end] + "\""
    }
    let keys = (tag == "lib" ? ["desc=\""] : ["name=\"", "loc=\"", "map=\""]).compactMap(value)
    found.insert(tag + " " + keys.joined(separator: " "))
  }
  return found
}

/// load → save through the real `Loader`, i.e. exactly what `logisim-cli --convert` does.
private func roundTrip(_ source: String) throws -> RoundTrip {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("libdrop-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let input = directory.appendingPathComponent("probe.circ")
  let output = directory.appendingPathComponent("out.circ")
  try source.write(to: input, atomically: true, encoding: .utf8)

  let ui = RecordingLoaderUI()
  let loader = Loader(ui: ui)
  let file = try loader.openLogisimFile(input)
  #expect(loader.save(file, to: output), "writer refused to save")
  let text = try String(contentsOf: output, encoding: .utf8)
  // An empty write reads exactly like agreement. Refuse to compare nothing.
  #expect(!text.isEmpty, "round trip produced no bytes")
  return RoundTrip(text: text, errors: ui.errors)
}

// MARK: - Upstream's behaviour, as a fact rather than an assumption

/// Guards the fixture itself: if `UPSTREAM_OUTPUT` is ever edited to agree with the port, this
/// test stops being evidence of anything. These assertions restate the four destructions.
@Test func theCapturedUpstreamOutputStillShowsTheDestruction() {
  #expect(!UPSTREAM_OUTPUT.contains("#Risc-V"), "captured baseline no longer drops the library")
  #expect(!UPSTREAM_OUTPUT.contains("RV32IM"), "captured baseline no longer drops the component")
  #expect(!UPSTREAM_OUTPUT.contains("label\" val=\"cpu\""))
  // The renumbering: `#Base` went in as 3 and comes out as 2, and its references follow.
  #expect(UPSTREAM_OUTPUT.contains("<lib desc=\"#Base\" name=\"2\">"))
  #expect(UPSTREAM_OUTPUT.contains("<tool lib=\"2\" map=\"Button2\" name=\"Menu Tool\"/>"))
  #expect(UPSTREAM_OUTPUT.contains("<tool lib=\"2\" name=\"Poke Tool\"/>"))
  // Survivors on either side of the hole keep the right library.
  #expect(UPSTREAM_OUTPUT.contains("<comp lib=\"0\" loc=\"(100,100)\" name=\"Pin\">"))
  #expect(UPSTREAM_OUTPUT.contains("<comp lib=\"1\" loc=\"(300,300)\" name=\"AND Gate\"/>"))
}

// MARK: - The port's behaviour

@Test func anUnresolvableLibraryAndEverythingUsingItSurviveTheRoundTrip() throws {
  let result = try roundTrip(PROBE)

  // D8, the whole point: the declaration comes back with its `<tool>` state untouched.
  #expect(result.text.contains("<lib desc=\"#Risc-V\" name=\"2\">"))
  #expect(result.text.contains("<a name=\"contents\">addr/data: 10 32"))
  // The placed component upstream destroys, label and all.
  #expect(result.text.contains("<comp lib=\"2\" loc=\"(200,200)\" name=\"RV32IM\">"))
  #expect(result.text.contains("<a name=\"label\" val=\"cpu\"/>"))
  // The toolbar entry upstream destroys.
  #expect(result.text.contains("<tool lib=\"2\" name=\"RV32IM\"/>"))
  // Because nothing was removed, nothing renumbers: `#Base` stays 3 and its references stay 3.
  #expect(result.text.contains("<lib desc=\"#Base\" name=\"3\">"))
  #expect(result.text.contains("<tool lib=\"3\" map=\"Button2\" name=\"Menu Tool\"/>"))
  #expect(result.text.contains("<tool lib=\"3\" name=\"Poke Tool\"/>"))
}

/// The divergence is asserted in the direction that matters: everything upstream keeps, the port
/// also keeps. A port that merely *differed* from upstream would satisfy the test above; this one
/// says the port's output is a SUPERSET, so the divergence can only ever be conservative.
///
/// ── Why this compares elements and not bytes, which is a limit of the target and not a dodge ──
///
/// `LogisimFileTests` depends on `LogisimFile` alone (Package.swift:248-250), so no component
/// factory is registered in this process: `#Wiring` is an empty shell, `Pin` is not a known tool,
/// and every `<comp>` here takes D8's verbatim path. Upstream's baseline, by contrast, was written
/// by a JVM with real factories, so it carries factory-supplied attribute defaults,
/// `<a name="appearance" val="classic"/>` on the `Pin`, and a `<tool name="Pin">` block on
/// `#Wiring`, that nothing in this target could ever emit. Comparing bytes here would fail on
/// component registration while claiming to measure library resolution.
///
/// The byte-level superset IS the real claim and it does hold; it is measured one layer up, where
/// `LogisimStd` is linked. Against the release CLI:
///
///     swift build -c release --product logisim-cli
///     .build/release/logisim-cli --convert probe.circ probe.swift.circ
///     # every line of the jar's output, present in the port's?
///     -> the only three absent are exactly the renumbered ones:
///          <lib desc="#Base" name="2">
///          <tool lib="2" map="Button2" name="Menu Tool"/>
///          <tool lib="2" name="Poke Tool"/>
///        i.e. the port keeps `appearance`, keeps the `<tool name="Pin">` block, and differs
///        from upstream ONLY by not shifting an index it had no reason to shift.
///
/// So this test pins the registration-independent half, identity of every library, component and
/// tool, and the header records the other half with the command that produced it.
@Test func thePortLosesNoLibraryComponentOrToolUpstreamKeeps() throws {
  let result = try roundTrip(PROBE)

  let lost = elementIdentities(UPSTREAM_OUTPUT).subtracting(elementIdentities(result.text))
  #expect(lost.isEmpty, "port lost elements upstream kept: \(lost.sorted())")
}

/// Negative control for the test above. A comparison that cannot fail is the recurring defect
/// shape in this project, `gateaudit.py` caught the canonical column passing a `cp(1)` stub, so
/// prove the subtraction actually detects a loss before trusting an empty result from it.
@Test func theSupersetComparisonDetectsALossWhenThereIsOne() throws {
  let intact = try roundTrip(PROBE)
  // Delete exactly what upstream deletes, then confirm the check notices.
  let damaged = intact.text.replacingOccurrences(
    of: "<comp lib=\"2\" loc=\"(200,200)\" name=\"RV32IM\">", with: "<comp lib=\"2\" name=\"gone\">")
  #expect(damaged != intact.text, "control fixture did not actually damage anything")
  let lost = elementIdentities(intact.text).subtracting(elementIdentities(damaged))
  #expect(
    lost.contains { $0.contains("RV32IM") },
    "the superset check failed to notice a deleted component; it proves nothing")
}

/// D13's neighbour: an unresolvable library is a non-fatal load problem, so it must neither trap
/// nor throw nor pass silently. Upstream reports it through `Loader.showError`
/// (`LibraryManager.java:263`); so does the port (`LibraryManager.loadLibrary`, case "").
///
/// NOTE for whoever wires the app shell and the CLI: `HeadlessLoaderUI` *records* these and
/// nothing reads them back, so `logisim-cli --convert` currently prints nothing where the jar
/// logs `The built-in library #Risc-V is not available`. That is a reporting gap in the CLI, not
/// in this layer; the message is produced here, as this test proves.
@Test func theUnresolvableLibraryIsReportedRatherThanSwallowed() throws {
  let result = try roundTrip(PROBE)
  #expect(
    result.errors.contains { $0.contains("Risc-V") },
    "no diagnostic mentioned the unresolvable library; got \(result.errors)")
}

/// A preserved placeholder must not accumulate or drift: the port's own output has to be a fixed
/// point. Without this, D8's guarantee decays over repeated opens, which is the failure mode
/// that would make preservation worse than dropping.
@Test func preservedLibrariesReachAFixedPointImmediately() throws {
  // BOTH round trips under one pin; board #83. Without it this compares a file written while
  // `#Wiring` had no tools registered against one written after `LogisimStdTests` called
  // `registerAll()` on another thread, so the second gains a `<tool name="Pin">` block and the
  // comparison fails on a registration this test has nothing to do with. Measured: 5 failures in
  // 8 runs of `swift test --filter "LogisimFileTests|LogisimStdTests"` before, 0 after.
  //
  // Pinning rather than registering is deliberate: this target cannot see `LogisimStd`, and the
  // property under test is that the port's own output is a FIXED POINT, which holds whether or
  // not the builtin tools are present, so long as the answer does not change underneath it.
  try BuiltinToolProviders.withRegistryPinned {
    let once = try roundTrip(PROBE)
    let twice = try roundTrip(once.text)
    #expect(once.text == twice.text, "second round trip moved; placeholders are not stable")
  }
}

/// The other half of the same decision, and the half that actually dominates the corpus: a
/// component whose *library resolves* but whose *tool name* does not. `BitLabeledTunnel` is a
/// 3.0.0-era `#Wiring` component; 4.1.0 has no such tool and destroys all 311 occurrences across
/// the corpus. No library is unresolvable in that case, so it cannot be argued away as a
/// library-resolution question, which is why removing the `<lib>` preservation would still leave
/// 13 of those 18 files failing the migration gate.
///
/// **What this test does and does not establish.** It pins that the preservation path carries a
/// component's attributes through intact. It does NOT isolate the "resolved library, unknown tool"
/// branch, because this target links no `LogisimStd` and so `Pin` and `AND Gate` are equally
/// unknown here (see `thePortLosesNoLibraryComponentOrToolUpstreamKeeps`). The branch itself is
/// covered where it can be: by the 13 corpus files in the migration gate, run against the release
/// CLI where the factories are real.
@Test func aComponentWithAnUnknownToolNameInAResolvedLibrarySurvives() throws {
  let source = PROBE.replacingOccurrences(
    of: "<comp lib=\"1\" loc=\"(300,300)\" name=\"AND Gate\"/>",
    with: """
      <comp lib="0" loc="(400,400)" name="BitLabeledTunnel">
          <a name="bitSpecs" val="N2,N3"/>
          <a name="label" val="x"/>
        </comp>
      """)
  #expect(source != PROBE, "fixture substitution did not apply")
  let result = try roundTrip(source)
  #expect(result.text.contains("name=\"BitLabeledTunnel\""))
  #expect(result.text.contains("<a name=\"bitSpecs\" val=\"N2,N3\"/>"))
  #expect(result.text.contains("<a name=\"label\" val=\"x\"/>"))
}
