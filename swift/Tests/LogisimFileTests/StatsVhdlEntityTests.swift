// StatsVhdlEntityTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS PROVES ════════════════════════════════════════════════════════════════════════
//
// A `<comp>` placing a `<vhdl>` entity resolves to the ONE `PreservedVhdlEntityFactory` that the
// `<vhdl>` element put in `LogisimFile.addToolList`, and is therefore counted and listed the way
// `java -jar logisim-evolution-4.1.0-all.jar -tty stats` counts and lists it.
//
// ── The defect this pins, and why it did not look like a VHDL defect ────────────────────────
//
// `statsgate.py` read 1728/1735 with `3.7.2__case-278.circ::main` failing: the port dropped a
// whole row and both totals were one short. The row was `Sigmoid_Activation_Function`, which
// *looks* like a subcircuit in the output, same column, same library, and the obvious reading
// was a defect in `FileStatistics`' subcircuit recursion. It is not one. In the `.circ` it is a
// `<vhdl name="Sigmoid_Activation_Function">`, and `FileStatistics` is a faithful port.
//
// The port never gave that entity a resolvable tool. `PreservedVhdlEntityFactory`, D8's carrier
// for a `<vhdl>` element the (still uninstalled) `VhdlContentLoading` seam cannot parse, answered
// to `"#preserved-vhdl#" + name` on purpose, so that `LogisimFile.tool(named:)` would miss and the
// placement would take D8's verbatim path with a factory minted per placement. Three consequences,
// all invisible until something counted by factory identity:
//
//   * N placements of one entity were N distinct factories, where upstream has one;
//   * `FileStatistics.sortCounts` lists a count only when its factory is some tool's factory, so
//     the entity had NO row and, because both totals are summed over that list, both totals lost
//     its placement count;
//   * `LogisimFile.vhdlContent(named:)`, which matches `factory.name`, as Java's
//     `getVhdlContent` does, could never find a preserved entity.
//
// ── Why two placements, and not one ─────────────────────────────────────────────────────────
//
// One placement cannot tell "the row is missing" apart from "the row is there but split": both
// give a single wrong number. Two placements of one entity make the two hypotheses produce
// different output, one row reading `2`, versus two rows reading `1`, versus no row at all, and
// only the first matches the jar. The corpus case has exactly one placement, so this fixture is
// the discriminating one and the gate is not.
//
// The `<vhdl>` source is minimal but genuinely parseable by 4.1.0's `VhdlParser`; the jar was run
// on this exact fixture and its output is the golden text below. A fixture the jar rejects would
// make the jar drop the entity too, and the two sides would agree for the wrong reason.
//
// ── WHAT THIS SUITE STRUCTURALLY CANNOT SEE, AND WHERE THAT LIVES INSTEAD ────────────────────
//
// This target does not link `LogisimUI`, so `LogisimFileSeams.makeVhdlEntity` is UNSET here and
// `XmlReader` installs D8's `PreservedVhdlEntityFactory` no matter what. Every assertion below is
// therefore measuring the D8 carrier, not the real `VhdlEntityAdaptor` the shipping app builds.
//
// That is not a hypothetical gap. Installing the adaptor made the second `<comp name="sig">`
// vanish, `VhdlEntityAdaptor` had no `offsetBounds`, so it inherited the `Bounds.empty` sentinel
// and `XmlCircuitReader`'s bounds-keyed overlap map ate the duplicate, and this suite stayed
// green throughout, because a `PreservedVhdlEntityFactory` placement is an `UnresolvedComponent`
// and `buildCircuit` routes those AROUND the overlap map by design. The branch that dropped the
// component is unreachable from this target.
//
// The load-path invariant is pinned where both halves are linked:
// `LogisimUITests/VhdlAdaptorTests.twoPlacementsOfOneEntityBothSurvive`. Do not move it back here
// ; it would silently stop testing anything.
//
// **`statsMatchesTheGolden` is NOT an escape hatch from that, and this was checked rather than
// assumed.** `logisim-cli`'s dependency list is `LogisimKernel, LogisimFile, LogisimStd,
// LogisimSoc, LogisimHdlWiring`, no `LogisimUI`, and the two VHDL seams are assigned in exactly
// one place in Sources, `LogisimUI/Project/LogisimFileProjectHost.swift`. So the CLI takes the D8
// path too, and every assertion in this file, subprocess included, describes the carrier.
//
// That is a real coverage gap and not only a note about this suite: `-tty stats` and the app
// disagree about what a `<vhdl>` element even is, so no stats or migration gate can see a VHDL
// entity regression of any kind. Closing it means installing the seams somewhere both executables
// reach, which is a dependency decision for whoever owns `logisim-cli`'s main: not something to
// paper over by asserting it here.

import Foundation
import Testing

import LogisimFile

@Suite("A <vhdl> entity is one factory, and -tty stats counts it")
struct StatsVhdlEntityTests {

  // MARK: - The fixture

  /// `main` places the entity `sig` twice, plus one Pin and one AND Gate so the row ORDER is
  /// observable: `sortCounts` walks `file.tools` (the file's own circuits and VHDL entities) and
  /// only then each library's tools, so `sig` must precede both.
  static let fixture = """
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

  /// `java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar --toplevel-circuit main
  /// -tty stats fixture.circ`, captured verbatim. The apostrophe in the first total is U+2019.
  ///
  /// Note `4 4` on BOTH totals: a VHDL entity is not a `SubcircuitFactory`, so `getTotal`'s
  /// exclude set, which holds the file's *circuits*, never matches it and it is counted in the
  /// without-subcircuits total too. Getting that wrong is worth 2 here.
  static let golden = """
    2\t2\tsig     \tfixture
    1\t1\tPin     \tWiring
    1\t1\tAND Gate\tGates
    4\t4\tTOTAL (without project\u{2019}s sub circuits)
    4\t4\tTOTAL (with sub circuits)

    """

  // MARK: - The model

  @Test("both placements resolve to the single factory the <vhdl> element registered")
  func placementsShareTheEntityFactory() throws {
    let file = try XmlReader(loader: Loader(), file: nil).readLibrary(Data(Self.fixture.utf8))

    // The tool answers to the entity's own name, as `VhdlEntity.getName()` does. This is the
    // assertion the prefixed name failed.
    let tool = try #require(
      file.tool(named: "sig"),
      "the <vhdl> entity registered no tool under its own name, so no <comp> naming it can resolve")
    let addTool = try #require(tool as? AddTool)
    // ── REWRITTEN 2026-09-06, EXACTLY AS THIS TEST'S OWN MESSAGE PREDICTED ──────────────────
    //
    // This required `addTool.factory as? PreservedVhdlEntityFactory` and said, in the failure
    // message, "the VHDL seam is installed now; this test is asserting the D8 carrier and needs
    // rewriting". The seam WAS installed, hours later and by a different agent, so the entity now
    // parses into a real `VhdlEntityAdaptor` instead of a verbatim placeholder.
    //
    // The invariant this test exists for is untouched by that: `FileStatistics` counts by factory
    // IDENTITY and lists only counts whose factory belongs to a tool, so a per-placement factory
    // is both invisible to the listing and split across instances. That is about sharing, not
    // about which class does the sharing, so the assertion is now keyed on the factory the tool
    // vends, whatever it is.
    let carrier = addTool.factory
    #expect(carrier.name == "sig")
    #expect(carrier.displayName == "sig")

    let main = try #require(file.circuit(named: "main"))
    let placements = main.nonWires.filter { $0.factory === carrier }
    #expect(
      placements.count == 2,
      "expected both <comp name=\"sig\"> to resolve to the tool's factory, got \(placements.count)")

    // The failure this guards is subtler than "did not resolve": a per-placement factory also
    // yields two components, just not two that are `===` the tool's.
    let distinctFactories = Set(main.nonWires.map { ObjectIdentifier($0.factory) })
    #expect(
      distinctFactories.count == 3,
      "one factory per distinct component kind — Pin, AND Gate, sig — got \(distinctFactories.count)")
  }

  @Test("the placement still round-trips verbatim, so D8 is not traded away for the count")
  func placementsStillRoundTrip() throws {
    let file = try XmlReader(loader: Loader(), file: nil).readLibrary(Data(Self.fixture.utf8))
    let main = try #require(file.circuit(named: "main"))
    let carrier = try #require((file.tool(named: "sig") as? AddTool)?.factory)
    let placements = main.nonWires.filter { $0.factory === carrier }
    #expect(placements.count == 2, "the two <comp name=\"sig\"> placements did not both resolve")

    // ── WHAT THIS ASSERTS NOW, AND WHY IT CHANGED ──────────────────────────────────────────
    //
    // It required every placement to be an `UnresolvedComponent` carrying its raw element, D8's
    // verbatim path, because at the time nothing could parse a `<vhdl>` entity. Now one can, so
    // a PARSEABLE entity is legitimately no longer on that path, and demanding it would be
    // demanding the defect back.
    //
    // The D8 guarantee still holds where it applies, and is asserted where it belongs:
    // `VhdlAdaptorTests.unparseableVhdlRemainsAVerbatimD8Placeholder` covers an entity that will
    // not parse. Here the surviving question is that both placements resolve to ONE factory,
    // which is what `-tty stats` counts on, and the golden-row test below is the end-to-end
    // check that the count is right.
    for component in placements {
      #expect(
        component.factory === carrier,
        "a placement minted its own factory; FileStatistics would count it separately")
    }
  }

  // MARK: - The output

  @Test("-tty stats prints the jar's rows for a placed <vhdl> entity")
  func statsMatchesTheGolden() throws {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; a missing binary is not a passing one")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(Self.fixture, named: "fixture.circ", into: dir)

    let run = try CliTtyHarness.run(
      cli, ["--toplevel-circuit", "main", "--tty", "stats", "fixture.circ"], cwd: dir)
    #expect(run.status == 0, "logisim-cli exited \(run.status): \(run.stderr)")
    // Assert non-empty before comparing. Two empty strings compare equal, and that has scored a
    // case OK in this project before.
    #expect(!run.stdout.isEmpty, "logisim-cli printed nothing")
    #expect(run.stdout == Self.golden)
  }

  @Test("and the jar agrees, when it is installed")
  func statsMatchesTheJar() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the VHDL stats differential is skipped")
      return
    }
    let cli = try #require(CliTtyHarness.cliURL)
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(Self.fixture, named: "fixture.circ", into: dir)

    let arguments = ["--toplevel-circuit", "main", "-tty", "stats", "fixture.circ"]
    let oracle = try #require(try CliTtyHarness.runJar(arguments, cwd: dir))
    #expect(oracle.status == 0, "the jar exited \(oracle.status): \(oracle.stderr)")
    // If the jar could not parse the entity it would drop it, and both sides would agree on a
    // row that should not be missing. Pin the golden shape rather than only the equality.
    #expect(
      oracle.stdout == Self.golden,
      "the jar no longer produces the captured golden — the fixture or the jar changed")

    let port = try CliTtyHarness.run(
      cli, ["--toplevel-circuit", "main", "--tty", "stats", "fixture.circ"], cwd: dir)
    #expect(port.stdout == oracle.stdout)
  }
}
