// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN THE APP PLACE AND SIMULATE A SoC COMPONENT?
//
// `LogisimSoc` is 82 files and was linked by `logisim-cli` alone, so nothing the *application*
// ran could name a single one of them. `LogisimFileProjectHostFactory`'s own comment predicted
// the consequence exactly, "a `#Soc` component loads as a D8 placeholder, visible and
// round-tripped, but not itself", and it was live.
//
// ── WHY THESE ASSERTIONS AND NOT "the call happens" ─────────────────────────────────────────
//
// A test that calls `SocLibrary.registerBuiltinTools()` and then checks the registry is a test
// of the registry. It passes against an application that never makes the call, because the test
// made it. Every assertion below therefore goes through
// `LogisimFileProjectHostFactory.openProject`; the one entry point the app itself uses, and
// then reads state the *user* would see:
//
//   * the component is not an `UnresolvedComponent` (D8's placeholder);
//   * it carries its ends, so a wire can connect to it (an `UnresolvedComponent` has none by
//     construction and `endLocation` throws);
//   * the canvas paints it, and it is NOT in `unresolvedTargetIndices`; the list of targets
//     that draw nothing and get the D8 dashed box painted over them instead;
//   * the explorer lists its tools by name;
//   * its bus fabric is live, which is seam #17's other half (board #49): `SocCircuitBinder`
//     was constructed by NOTHING outside `LogisimSocTests`, so the registration it wires
//     through `Circuit.mutatorAdd` was reachable only from a runtime that did not exist.
//
// Deleting `SocLibrary.registerBuiltinTools()` from `registerBuiltinLibrariesIfNeeded` turns
// the first four red; deleting the `socBinder` attach turns the fifth red.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimSoc
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixture

/// A `.circ` that places one of each of the four SoC parts a real design is built from, all on
/// one bus.
///
/// Hand-authored. It follows the shape the one SoC-using corpus file has, a bus plus a memory, a
/// PIO and a processor that all select it, but nothing is transcribed from it: the corpus is
/// coursework and does not belong in a public repository. The bus identifier is invented, and
/// that is safe because what `SocSimulationManager.registerComponent` keys on is the three
/// selections matching the bus, not the value itself.
///
/// Deliberately contains NOTHING else. `paintedComponentCount` is then a statement about SoC
/// components alone rather than about the gates standing next to them.
private let socFixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Base" name="0"/>
  <lib desc="#Wiring" name="1"/>
  <lib desc="#Soc" name="11"/>
  <main name="main"/>
  <circuit name="main">
    <comp lib="11" loc="(300,100)" name="SocBus">
      <a name="SocBusIdentifier" val="0x000001900000000000000001"/>
      <a name="TraceVisible" val="false"/>
    </comp>
    <comp lib="11" loc="(500,100)" name="Socmem">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
      <a name="label" val="mem"/>
    </comp>
    <comp lib="11" loc="(500,400)" name="SocPio">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
      <a name="StartAddress" val="0x448"/>
      <a name="direction" val="outputonly"/>
      <a name="label" val="port_out"/>
    </comp>
    <comp lib="11" loc="(100,100)" name="Rv32im">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
    </comp>
  </circuit>
</project>
"""

/// The four `_ID`s the fixture names, in the order the file lists them. These strings are the
/// interface (`SocLibrary.swift`'s header says so): `"Socmem"` really is lower-case `m` and no
/// separator, and one wrong character makes exactly one tool silently unresolvable.
private let socComponentIds = ["SocBus", "Socmem", "SocPio", "Rv32im"]

@MainActor
private func openFixture(_ text: String) throws -> LogisimFileProjectHost {
  let host = try LogisimFileProjectHostFactory().openProject(
    data: Data(text.utf8), url: nil, contentType: LogisimDocumentType.circuit)
  return try #require(host as? LogisimFileProjectHost)
}

private func corpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

// MARK: - The gate

@Suite("SoC registration reaches the app")
struct SocRegistrationTests {

  /// The headline. Before the `LogisimUI -> LogisimSoc` edge and the registration call, all four
  /// of these loaded as `UnresolvedComponent`; D8 kept the XML, and the user got a dashed box.
  @Test("a #Soc component opened by the app resolves to its real factory")
  @MainActor
  func socComponentsResolveRatherThanBecomingPlaceholders() throws {
    let host = try openFixture(socFixture)
    let circuit = try #require(host.currentCircuitObject)
    let placed = circuit.nonWires

    #expect(placed.count == 4, "the fixture places four SoC components")

    let unresolved = placed.compactMap { $0 as? UnresolvedComponent }
    #expect(
      unresolved.isEmpty,
      Comment(
        rawValue: "\(unresolved.count) of 4 SoC components loaded as D8 placeholders — #Soc is "
          + "not registered in the app's startup path"))

    let names = Set(placed.map(\.factory.name))
    for id in socComponentIds {
      #expect(names.contains(id), "no component resolved to the \(id) factory")
    }
  }

  /// A placeholder has no ends by construction, `UnresolvedComponent.ends` is empty and
  /// `endLocation(_:)` throws, so nothing can be wired to it and M3 skips it entirely. Ends are
  /// therefore the difference between "the picture is right" and "the circuit is right".
  ///
  /// ── `Socmem` IS EXPECTED TO HAVE NONE, AND THIS TEST FIRST CLAIMED OTHERWISE ────────────────
  ///
  /// The obvious expectation, "every resolved component has ends", failed on `Socmem` alone,
  /// and the reference tree says the expectation was wrong, not the port. `SocMemory.java`
  /// contains no `setPorts` call at all: a memory is a pure bus slave reached through
  /// `SocBusSlaveInterface`, so it has no pins to wire. Checked across the four the fixture
  /// places (`grep -c setPorts` on 4.1.0):
  ///
  /// ```
  /// soc/bus/SocBus.java          1
  /// soc/pio/SocPio.java          1
  /// soc/rv32im/Rv32imRiscV.java  1
  /// soc/memory/SocMemory.java    0   <- correct, not a gap
  /// ```
  ///
  /// So the assertion is per-factory, and `Socmem` is pinned at zero rather than exempted: if it
  /// ever grows ends, that is a divergence and this turns red.
  @Test("the resolved SoC components carry the ends upstream gives them")
  @MainActor
  func socComponentsCarryTheirEnds() throws {
    let host = try openFixture(socFixture)
    let circuit = try #require(host.currentCircuitObject)

    for component in circuit.nonWires {
      let name = component.factory.name
      if name == "Socmem" {
        #expect(
          component.ends.isEmpty,
          "Socmem grew ends; SocMemory.java calls no setPorts, so this is a divergence")
      } else {
        #expect(
          !component.ends.isEmpty,
          "\(name) has no ends, so no wire can connect to it")
      }
      let bounds = component.bounds
      #expect(
        bounds.width > 0 && bounds.height > 0,
        "\(name) has empty bounds, so it cannot be hit-tested or drawn")
    }
  }

  /// D6: a component draws by emitting primitives into a `RenderScene`. `unresolvedTargetIndices`
  /// is the canvas's own list of targets that emitted nothing and need the D8 dashed box drawn
  /// over them, so it is the exact observable this task set out to remove, and it is now empty.
  ///
  /// ── THE SECOND HOP, MEASURED: REGISTRATION IS NOT THE LAST ONE ──────────────────────────────
  ///
  /// Registration makes a SoC component real; it has a factory, ends, bounds, an attribute set,
  /// a place in the netlist and a live bus fabric. It does **not** make it visible, and this test
  /// is where that is recorded rather than assumed:
  ///
  /// ```
  /// unresolvedTargetIndices  [0,1,2,3] -> []   the fix
  /// paintedComponentCount    0 -> 0            the remaining gap
  /// ```
  ///
  /// **No SoC factory has a ported `paintInstance`.** All eight say so in their own headers
  /// ("Not ported: `paintInstance` … D6/D9"), while all eight implement one upstream
  /// (`grep -rln "public void paintInstance" soc/` on 4.1.0 lists bus, memory, pio, rv32im,
  /// nios2, dma, vga, jtaguart). `CircuitRenderer` paints a component only if its factory
  /// conforms to `InstancePaintable`, and none of them does, so all four emit nothing.
  ///
  /// That is a **deliberate trade with a visible cost**, and it belongs in the open rather than
  /// behind a green test: before this change the user saw a dashed placeholder box, and now the
  /// component is fully real and draws nothing at all, so the canvas shows blank space where the
  /// SoC parts sit. They are still selectable and hit-testable, `bounds` is real, which is what
  /// keeps them reachable, but the schematic no longer shows them.
  ///
  /// Porting the eight painters is `LogisimSoc`'s work, not this task's, and this assertion is
  /// written to FAIL THE MOMENT IT LANDS so nobody has to remember to come back: raise the pin
  /// from 0 to 4 then.
  @Test("SoC components stop taking the D8 placeholder path; the painters are the next hop")
  @MainActor
  func socComponentsLeaveThePlaceholderPath() throws {
    let host = try openFixture(socFixture)
    let circuit = try #require(host.currentCircuitObject)
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())

    #expect(build.components.count == 4)
    #expect(
      build.unresolvedTargetIndices.isEmpty,
      Comment(
        rawValue: "the canvas still wants to draw the D8 dashed box over "
          + "\(build.unresolvedTargetIndices.count) SoC components — the registration did not "
          + "take"))

    // Real geometry, which is what makes them selectable and hit-testable even while unpainted.
    #expect(!build.contentBounds.isNull)
    #expect(build.targets.allSatisfy { !$0.bounds.isNull })

    #expect(
      build.paintedComponentCount == 0,
      "a SoC paintInstance has landed — raise this pin and delete the note above")
  }

  /// The explorer sidebar is where a user finds a component to place. `#Soc` resolved as a
  /// library shell even before this work, `Builtin` declares it, so the group header was
  /// always there; what was missing was every tool underneath it.
  @Test("the explorer lists the eight #Soc tools by name")
  @MainActor
  func socToolsReachTheExplorer() throws {
    let host = try openFixture(socFixture)
    let soc = try #require(
      host.outline.libraries.first { $0.name == "System On a Chip" },
      "the #Soc library group is missing from the explorer entirely")

    #expect(
      soc.tools.count == 8,
      "the #Soc group lists \(soc.tools.count) tools; SocLibrary declares 8")

    // ── ASSERTED ON THE TOOL'S IDENTITY, NOT ITS RENDERED NAME ────────────────────────────
    //
    // This originally matched `socComponentIds` against `tool.name`, and it broke the moment a
    // second branch landed: `soc-display-names` gave the SoC factories their real display
    // names, so `Rv32imRiscV` renders as "Risc V IM simulator" and the substring match found
    // nothing. Two changes each correct on their own, and the join between them was this
    // assertion: the twenty-fifth instance of that shape here, and the first where I owned
    // both halves.
    //
    // Resolved by asking the question the test actually means. "Is this tool present" is about
    // identity; `_ID` is what the `.circ` codec keys on and what survives a rename, whereas the
    // display name is presentation and is *expected* to change. Matching on the rendered string
    // made a display-name fix look like a registration failure.
    for id in socComponentIds {
      #expect(
        host.handles.tools.values.contains { $0.name == id },
        "no registered tool has _ID \(id); #Soc registration did not reach the explorer")
    }

    // And the rendered names are real display names rather than programmer identifiers: the
    // other half of the pair, asserted here so the two cannot silently diverge again.
    let rendered = Set(soc.tools.map(\.name))
    #expect(
      !rendered.contains("Rv32imRiscV"),
      "the explorer is showing _IDs again; display names regressed: \(rendered.sorted())")
  }

  /// The attribute-UI half. Selecting a SoC component used to produce the D8 form: the notice
  /// "This component comes from a library that could not be resolved… written back unchanged",
  /// over whatever attributes the raw XML happened to carry. It now produces the component's own
  /// `AttributeSet`, which is what makes `StartAddress`, `SocBusSelection` and the rest editable
  /// : and editable through `CircuitMutation`, so onto the undo stack.
  ///
  /// No SoC attribute needs a custom editor this port does not have: they project through
  /// `InspectorProjection` like any other, which is why the inspector needed no SoC-specific
  /// work at all. That is a *checked* absence, not an assumed one; it is the reason this test
  /// exists rather than a note saying it should be fine.
  @Test("selecting a SoC component gives the inspector its real attributes, not the D8 form")
  @MainActor
  func socComponentInspectorIsReal() throws {
    let host = try openFixture(socFixture)
    let circuit = try #require(host.currentCircuitObject)
    let pio = try #require(circuit.nonWires.first { $0.factory.name == "SocPio" })

    let form = host.inspectorForm(for: .components([CircuitSceneSource.identity(of: pio)]))

    #expect(form.subtitle == "SocPio")
    #expect(
      form.notice == nil,
      "the inspector still shows the D8 unresolved-library notice for a SoC component")

    let keys = Set(form.sections.flatMap(\.rows).map(\.key.name))
    #expect(
      keys.contains("StartAddress"),
      Comment(rawValue: "the PIO's own attributes are missing; rows are \(keys.sorted())"))
    #expect(keys.contains("SocBusSelection"))
  }

  /// Seam #17 / board #49's other half. `SocCircuitBinder` reproduces Java's `Circuit.socSim`
  /// field, which upstream calls from `mutatorAdd`/`mutatorRemove`/`mutatorClear`. The binder
  /// landed, its own suite passed: and **nothing outside that suite ever constructed one**, so
  /// the registration was reachable only from a runtime that did not exist. A `SocMemory` whose
  /// `SocBusInfo.simulationManager` is nil does not error: a read from it falls through to
  /// `rand.nextInt()`.
  @Test("the app's project host gives every circuit a live SoC bus fabric")
  @MainActor
  func socBusFabricIsLiveInTheApp() throws {
    let host = try openFixture(socFixture)
    let circuit = try #require(host.currentCircuitObject)

    let manager = try #require(
      host.socBinder.manager(for: circuit),
      "the host attached no SocSimulationManager to the circuit it is showing")
    #expect(
      manager.hasSocBusses,
      Comment(
        rawValue: "the SocBus placed by the file reached no bus fabric — seam #17 is "
          + "unreachable from the app"))

    let memory = try #require(circuit.nonWires.first { $0.factory.name == "Socmem" })
    let info = try #require(memory.attributeSet.getValue(SocSimulationManager.socBusSelect))
    #expect(
      info.simulationManager === manager,
      "the memory's live SocBusInfo points at no manager, so a read from it returns noise")
    #expect(info.component === memory)

    let fabric = try #require(manager.busFabric("0x000001900000000000000001"))
    #expect(
      fabric.slaves.count >= 1,
      "neither the memory nor the PIO registered as a slave on the bus they name")
    #expect(fabric.slaves.allSatisfy { $0.slaveName != "BUG: Unknown" })
  }

  /// A second circuit added after the file is open must get its own manager too: Java creates
  /// the `socSim` field in `Circuit`'s constructor, so there is no such thing as a circuit
  /// without one.
  @Test("a circuit created after the file is open is bound as well")
  @MainActor
  func newCircuitsAreBoundToo() throws {
    let host = try openFixture(socFixture)
    let before = host.socBinder.attachedCircuitCount

    try host.perform(.addCircuit)

    let added = try #require(host.currentCircuitObject)
    #expect(host.socBinder.attachedCircuitCount == before + 1)
    #expect(
      host.socBinder.manager(for: added) != nil,
      "File ▸ Add Circuit produced a circuit with no SoC manager")
  }

  /// The one corpus file that PLACES SoC components rather than only declaring the library.
  /// 354 of 539 carry `<lib desc="#Soc">`; this is the one that instantiates it, so it is the
  /// only real-world evidence available and worth naming explicitly.
  @Test("the corpus file that places SoC components resolves all of them")
  @MainActor
  func corpusFileResolvesItsSocComponents() throws {
    guard let corpus = corpusDirectory() else {
      print("LOGISIM_CORPUS unset — corpus SoC check skipped")
      return
    }
    let url = corpus.appendingPathComponent(
      "the one SoC-using corpus file")
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("corpus SoC fixture missing at \(url.path) — skipped")
      return
    }

    let host = try openFixture(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    let circuit = try #require(host.currentCircuitObject)

    // Named in the file; counted from it rather than hard-coded, so a corpus refresh cannot
    // make this assertion vacuous by removing the components it is about.
    let socNames: Set<String> = ["SocBus", "Socmem", "SocPio", "Rv32im"]
    let socComponents = circuit.nonWires.filter { socNames.contains($0.factory.name) }
    #expect(
      socComponents.count == 10,
      "expected the 10 SoC components the file places; found \(socComponents.count)")
    #expect(circuit.nonWires.compactMap { $0 as? UnresolvedComponent }.isEmpty)

    let manager = try #require(host.socBinder.manager(for: circuit))
    #expect(manager.hasSocBusses)

    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    #expect(build.unresolvedTargetIndices.isEmpty)
    // The rest of the file is ordinary gates and IO, so unlike the synthetic fixture this one
    // does paint, which is the check that the SoC components' silence is theirs alone and this
    // change broke nothing around them.
    #expect(build.paintedComponentCount > 0)
  }
}
