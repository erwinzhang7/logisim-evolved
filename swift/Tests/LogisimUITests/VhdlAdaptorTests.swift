// VhdlAdaptorTests.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LogisimFile
import LogisimKernel
import LogisimVhdl
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

@Suite("VHDL file adaptor")
struct VhdlAdaptorTests {
  @Test("a parseable vhdl element becomes real content with its parsed ports")
  @MainActor
  func parseableContentLoadsIntoTheModel() throws {
    let source = """
      library ieee;
      use ieee.std_logic_1164.all;
      entity bus_gate is
        port (
          data : in std_logic_vector(7 downto 0);
          enable : in std_logic;
          result : out std_logic_vector(7 downto 0)
        );
      end bus_gate;
      architecture rtl of bus_gate is begin end rtl;
      """
    let data = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <project source="4.1.0" version="1.0">
        <vhdl name="bus_gate"><![CDATA[\(source)]]></vhdl>
        <circuit name="main"/>
      </project>
      """.utf8)

    // The `withKnownIssue` wrapper that stood here from 2026-09-06 is GONE, as its own comment
    // required. It was not `isIntermittent`, so it failed when the issue stopped occurring, which
    // is exactly what happened when the installation was restored; see
    // `VhdlEntityAdaptor.offsetBounds` for the defect it was standing in for.
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: data, url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let content = try #require(host.file.vhdlContents.first as? VhdlContent)

    #expect(content.name == "bus_gate")
    #expect(content.ports.map(\.name) == ["data", "enable", "result"])
    #expect(content.ports.map(\.direction) == [.input, .input, .output])
    #expect(content.ports.map { $0.width.width } == [8, 1, 8])
  }

  // ══ THE REGRESSION THIS SUITE EXISTS TO HOLD ═════════════════════════════════════════════════
  //
  // Installing the adaptor silently DELETED a component, and it shipped for an hour because no
  // test in this target loaded a circuit that *placed* an entity twice.
  //
  // ── Why it has to live HERE and not in StatsVhdlEntityTests ────────────────────────────────
  //
  // `StatsVhdlEntityTests` already loads this exact fixture and already asserts two placements,
  // and it CANNOT see this defect. It is in `LogisimFileTests`, which does not link `LogisimUI`,
  // so `LogisimFileSeams.makeVhdlEntity` is unset there and `XmlReader` installs D8's
  // `PreservedVhdlEntityFactory` instead. That carrier yields an `UnresolvedComponent`, which
  // `XmlCircuitReader.buildCircuit` deliberately routes *around* the overlap map, so the branch
  // that ate the placement is unreachable from that target no matter what the fixture contains.
  //
  // Two changes each green in isolation, and the join between them was a component that vanished.
  // The invariant is only observable where both halves are linked, which is this target.
  @Test("both placements of one entity survive the load, sharing one factory")
  @MainActor
  func twoPlacementsOfOneEntityBothSurvive() throws {
    // The seam is installed by the factory, not by the module, so a test that never opens a
    // project would silently measure the D8 path and pass for the wrong reason.
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()

    let ui = HeadlessLoaderUI()
    let file = try XmlReader(loader: Loader(ui: ui), file: nil)
      .readLibrary(Data(Self.twoPlacementFixture.utf8))
    let main = try #require(file.circuit(named: "main"))

    // ASSERT THE DIAGNOSTIC LIST IS EMPTY, FIRST. The loss was not silent in the code; it was
    // silent in the *reading*: the reader recorded
    //
    //     Components sig(200,110) and sig(200,110) exactly overlap each other.
    //     One has been moved slightly. [main]
    //
    // and nothing consulted it. The message is also false; the component was not moved, it was
    // dropped by the nudge loop's zero-area branch. A count assertion alone would go green again
    // the moment some future change made the entity merely *mis-sized* rather than degenerate, so
    // pin the channel that actually knew.
    #expect(
      ui.errors.isEmpty,
      "the reader recorded a diagnostic while loading a well-formed file: \(ui.errors)")

    #expect(main.nonWires.count == 4, "a component was dropped during the load")

    let carrier = try #require((file.tool(named: "sig") as? AddTool)?.factory)
    #expect(carrier is VhdlEntityAdaptor, "the <vhdl> element did not parse into a real entity")
    let placements = main.nonWires.filter { $0.factory === carrier }
    #expect(placements.count == 2)

    // ONE factory across both placements. `FileStatistics` counts by factory identity and lists
    // only counts whose factory belongs to a tool, so a per-placement factory would be invisible
    // to `-tty stats` AND split its count: a different bug with the same symptom (a wrong
    // number), which is why this is asserted separately from the count above.
    #expect(Set(placements.map { ObjectIdentifier($0.factory) }).count == 1)

    // The direct cause, pinned at its source so a regression names itself instead of presenting
    // as a missing component three layers away.
    for placement in placements {
      let bounds = placement.bounds
      #expect(
        bounds.width > 0 && bounds.height > 0,
        """
        degenerate bounds \(bounds): `Bounds.empty.translate` returns the sentinel unchanged, so \
        every placement collides in XmlCircuitReader's overlap map and all but one are cut
        """)
    }
    #expect(
      Set(placements.map(\.bounds)).count == 2,
      """
      two placements at different locations reported the SAME bounds — this is the exact \
      collision that deleted one of them
      """)
  }

  /// `StatsVhdlEntityTests.fixture`, duplicated because that suite is in another test target and
  /// test targets do not share code. Two `<comp name="sig">` at different locations, plus a Pin
  /// and an AND Gate so a wrong total is attributable.
  ///
  /// The jar was run on it: `--toplevel-circuit main -tty stats` prints `2 2 sig` and totals of
  /// `4 4`, so 4.1.0 keeps BOTH placements and the expectation above is upstream's, not the
  /// port's own invention.
  static let twoPlacementFixture = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Gates" name="1"/>
      <main name="main"/>
      <options/>
      <mappings/>
      <toolbar/>
      <circuit name="main">
        <a name="circuit" val="main"/>
        <comp lib="0" loc="(100,110)" name="Pin">
          <a name="label" val="a"/>
        </comp>
        <comp loc="(200,110)" name="sig"/>
        <comp loc="(300,110)" name="sig"/>
        <comp lib="1" loc="(400,110)" name="AND Gate">
          <a name="size" val="30"/>
        </comp>
      </circuit>
      <vhdl name="sig">LIBRARY ieee;
    USE ieee.std_logic_1164.all;

    ENTITY sig IS
      PORT (
        x : IN  std_logic;
        y : OUT std_logic
      );
    END sig;

    ARCHITECTURE behavioural OF sig IS
    BEGIN
      y &lt;= x;
    END behavioural;
    </vhdl>
    </project>

    """

  /// `VhdlEntity.getOffsetBounds` is `DefaultEvolutionAppearance.build(pins, name, fixedSize:
  /// true)` measured relative to its anchor, and with `fixedSize` true the box is a function of
  /// the port COUNTS alone; `textWidth` is the constant `25 * 8`, so no label and no entity name
  /// can move it. That makes the expected numbers exact rather than approximate, and worth
  /// pinning directly: the load-path test above would still pass with *any* non-degenerate box,
  /// so on its own it does not defend the geometry against a plausible-looking wrong formula.
  @Test("the entity's offset bounds are upstream's evolution box")
  @MainActor
  func offsetBoundsMatchTheEvolutionAppearance() throws {
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
    let file = try XmlReader(loader: Loader(), file: nil)
      .readLibrary(Data(Self.twoPlacementFixture.utf8))
    let factory = try #require((file.tool(named: "sig") as? AddTool)?.factory)

    // `sig` has one `IN` and one `OUT`, so numWest = numEast = 1 and maxVert = 1.
    //   width  = (25 * 8 / 10) * 10 + 20                = 220
    //   height = maxVert * dy + titleBarHeight = 20 + 20 = 40
    //   anchor = (width, 10) because numEast > 0, and the box is reported relative to it
    #expect(factory.offsetBounds(factory.createAttributeSet()) == Bounds.create(-220, -10, 220, 40))
  }

  @Test("unparseable vhdl remains a verbatim D8 placeholder")
  @MainActor
  func unparseableContentRoundTripsVerbatim() throws {
    let rawElement =
      #"<vhdl name="broken" preserve="yes">this is not VHDL &amp; stays &lt;exact&gt;</vhdl>"#
    let data = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <project source="4.1.0" version="1.0">
        \(rawElement)
        <circuit name="main"/>
      </project>
      """.utf8)

    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: data, url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let preserved = try #require(host.file.vhdlContents.first as? PreservedVhdlContent)

    #expect(preserved.name == "broken")
    let written = try host.serialize()
    let xml = try #require(String(data: written, encoding: .utf8))
    #expect(xml.contains(rawElement))

    let reloaded = try #require(try Loader().openLogisimFile(data: written))
    #expect(reloaded.vhdlContents.first is PreservedVhdlContent)
  }
}
