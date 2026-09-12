// AnalyzeModelTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES "ANALYZE CIRCUIT" DERIVE THE RIGHT TABLE?
//
// The failure this suite exists to catch is the one the module-import sweep found: a module that
// builds, tests green in isolation, and is reachable from nothing. A test that imports
// `LogisimAnalyze` and constructs an `AnalyzerModel` passes against a module wired to no UI at
// all, so this suite never does that. Every assertion below is on **derived state**, the
// variables, the row count, and the entry in a specific cell, starting from a `.circ` and
// compared against numbers the 4.1.0 jar printed.
//
// ── Where the expected values come from ─────────────────────────────────────────────────────
//
// Two fixtures, written for this suite (NOT corpus files; the corpus is private and its golden
// tables are lab solutions, so neither may be committed). Each was run through the shipped jar's
// own `Analyze.getPinLabels` + `Analyze.computeTable`, by the `DeriveProbe` recorded in
// `docs/experiments/analyze-wiring.md`. The literal stdout is quoted beside each expectation.
//
//   andor   y = (a AND b) OR c        3 inputs, 1 output, 8 rows
//   notbus  q = NOT d, both 2 bits    2 inputs, 2 outputs, 4 rows : the width>1 case, where a
//                                     port most easily diverges on `Var(name,width)` bit naming
//                                     and on msb-first bit order.
//
// ── And one cross-check with no oracle in it ────────────────────────────────────────────────
//
// `tableAgreesWithTheTtyTablePath` runs the same circuit through `TruthTableRun.run`, the
// `-tty table` path, already pinned against 1,347 jar oracles, and asserts the two agree cell
// for cell. That is the anti-seam assertion: `CircuitAnalysis.computeTable` and
// `TruthTableRun.run` are two loops over the same simulation, exactly as upstream has two, and
// this is what stops them drifting apart.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// `y = (a AND b) OR c`, one AND and one OR gate.
///
/// Jar output (`DeriveProbe andor.circ andor`):
///
///     PIN a in width=1 loc=(80,100)      PIN b in width=1 loc=(80,140)
///     PIN y out width=1 loc=(390,170)    PIN c in width=1 loc=(80,220)
///     TABLE inputs=3 outputs=1 rows=8
///     HEADER a b c | y
///     ROW 0 0 0 0 | 0     ROW 4 1 0 0 | 0
///     ROW 1 0 0 1 | 1     ROW 5 1 0 1 | 1
///     ROW 2 0 1 0 | 0     ROW 6 1 1 0 | 1
///     ROW 3 0 1 1 | 1     ROW 7 1 1 1 | 1
///
/// Note the pin order: the output `y` sorts THIRD, between `b` and `c`, because
/// `Analyze.getPinLabels` sorts every pin top-to-bottom before splitting them into inputs and
/// outputs. A port that sorted inputs and outputs separately would still produce `a b c | y` and
/// would be wrong the moment two pins interleave differently.
private let andOrCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="andor"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="andor">
      <a name="circuit" val="andor"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(80,220)" name="Pin">
        <a name="label" val="c"/>
      </comp>
      <comp lib="0" loc="(390,170)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="y"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"/>
      <comp lib="1" loc="(340,170)" name="OR Gate"/>
      <wire from="(80,100)" to="(180,100)"/>
      <wire from="(80,140)" to="(180,140)"/>
      <wire from="(220,120)" to="(290,120)"/>
      <wire from="(290,120)" to="(290,150)"/>
      <wire from="(80,220)" to="(290,220)"/>
      <wire from="(290,190)" to="(290,220)"/>
      <wire from="(340,170)" to="(390,170)"/>
    </circuit>
  </project>
  """

/// `q = NOT d`, both 2 bits wide.
///
/// Jar output (`DeriveProbe notbus.circ notbus`):
///
///     TABLE inputs=2 outputs=2 rows=4
///     HEADER d[1] d[0] | q[1] q[0]
///     ROW 0 0 0 | 1 1        ROW 2 1 0 | 0 1
///     ROW 1 0 1 | 1 0        ROW 3 1 1 | 0 0
private let notBusCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="notbus"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="notbus">
      <a name="circuit" val="notbus"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="d"/>
        <a name="width" val="2"/>
      </comp>
      <comp lib="0" loc="(240,100)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="q"/>
        <a name="output" val="true"/>
        <a name="width" val="2"/>
      </comp>
      <comp lib="1" loc="(180,100)" name="NOT Gate">
        <a name="width" val="2"/>
      </comp>
      <wire from="(80,100)" to="(150,100)"/>
      <wire from="(180,100)" to="(240,100)"/>
    </circuit>
  </project>
  """

@MainActor
private func load(_ text: String, circuit name: String) throws -> (LogisimFile, Circuit) {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  let file = try #require(try Loader().openLogisimFile(data: Data(text.utf8)))
  let circuit = try #require(file.circuit(named: name))
  return (file, circuit)
}

// MARK: - Suite

@MainActor
@Suite("Analyze Circuit — the derived model")
struct AnalyzeModelTests {

  @Test("The derived variables and row count match the jar, output pin sorted in between")
  func variablesMatchTheJar() throws {
    let (file, circuit) = try load(andOrCirc, circuit: "andor")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)

    // `Analyze.getPinLabels` order: all four pins, top to bottom, inputs and outputs mixed.
    #expect(analysis.columns.map(\.label) == ["a", "b", "y", "c"])
    #expect(analysis.columns.map(\.isInput) == [true, true, false, true])

    #expect(analysis.inputVariables.map(\.name) == ["a", "b", "c"])
    #expect(analysis.outputVariables.map(\.name) == ["y"])
    #expect(analysis.model.inputs.bits == ["a", "b", "c"])
    #expect(analysis.model.outputs.bits == ["y"])

    let table = analysis.truthTable
    #expect(table.inputColumnCount == 3)
    #expect(table.outputColumnCount == 1)
    #expect(table.rowCount == 8)
    #expect(analysis.tableComputed)
  }

  @Test("Every cell of the derived table matches the jar's computeTable")
  func entriesMatchTheJar() throws {
    let (file, circuit) = try load(andOrCirc, circuit: "andor")
    // `analysis` must stay alive: D3 puts `TruthTable.model` on an `unowned` edge, so a
    // `let table = analyze(...).truthTable` reads a destroyed object and traps. Found by this
    // test crashing the whole bundle on the first run.
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)
    let table = analysis.truthTable

    // ROW 0..7 of the jar output, column `y`.
    let expected: [Entry] = [.zero, .one, .zero, .one, .zero, .one, .one, .one]
    let actual = (0..<table.rowCount).map { table.outputEntry(row: $0, column: 0) }
    #expect(actual == expected)

    // And the input side, which the model derives rather than stores: row 6 is a=1 b=1 c=0.
    #expect(try table.inputEntry(row: 6, column: 0) == .one)
    #expect(try table.inputEntry(row: 6, column: 1) == .one)
    #expect(try table.inputEntry(row: 6, column: 2) == .zero)
  }

  @Test("A multi-bit pin becomes msb-first bit columns, matching the jar")
  func multiBitPinsMatchTheJar() throws {
    let (file, circuit) = try load(notBusCirc, circuit: "notbus")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)
    let table = analysis.truthTable

    #expect(analysis.model.inputs.bits == ["d[1]", "d[0]"])
    #expect(analysis.model.outputs.bits == ["q[1]", "q[0]"])
    #expect(table.rowCount == 4)
    #expect(table.outputColumnCount == 2)

    // HEADER d[1] d[0] | q[1] q[0], rows 0..3 -> 11, 10, 01, 00.
    let q1 = (0..<4).map { table.outputEntry(row: $0, column: 0) }
    let q0 = (0..<4).map { table.outputEntry(row: $0, column: 1) }
    #expect(q1 == [.one, .one, .zero, .zero])
    #expect(q0 == [.one, .zero, .one, .zero])
  }

  @Test("The minimal expression matches the jar's, on both fixtures")
  func minimalExpressionsMatchTheJar() throws {
    let (file, circuit) = try load(andOrCirc, circuit: "andor")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)
    // jar: `TABLE-MINIMAL y  c+a⋅b`
    #expect(analysis.minimalExpression(for: "y")?.toString() == "c+a⋅b")

    let (busFile, busCircuit) = try load(notBusCirc, circuit: "notbus")
    let bus = try CircuitAnalysis.analyze(circuit: busCircuit, file: busFile)
    // jar: `TABLE-MINIMAL q[1]  ~d[1]` / `TABLE-MINIMAL q[0]  ~d[0]`
    #expect(bus.minimalExpression(for: "q[1]")?.toString() == "~d[1]")
    #expect(bus.minimalExpression(for: "q[0]")?.toString() == "~d[0]")
  }

  @Test("The analyzer table and the -tty table path agree cell for cell")
  func tableAgreesWithTheTtyTablePath() throws {
    let (file, circuit) = try load(andOrCirc, circuit: "andor")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)
    let table = analysis.truthTable

    // The already-pinned path, rendered as text and re-read.
    let text = try TruthTableRun.run(file: file, circuitName: "andor")
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.count == table.rowCount + 1)  // header + 8 rows

    // Column order of the tty table is inputs-then-outputs, same as the analyzer's.
    #expect(lines[0].split(separator: " ").map(String.init) == ["a", "b", "c", "y"])

    for row in 0..<table.rowCount {
      let cells = lines[row + 1].split(separator: " ").map(String.init)
      #expect(cells.count == 4)
      for column in 0..<3 {
        let expected = try table.inputEntry(row: row, column: column) == .one ? "1" : "0"
        #expect(cells[column] == expected, "input column \(column), row \(row)")
      }
      let expected = table.outputEntry(row: row, column: 0) == .one ? "1" : "0"
      #expect(cells[3] == expected, "output column, row \(row)")
    }
  }

  @Test("A circuit with no output pins yields variables but no table")
  func noOutputsStopsBeforeTheTable() throws {
    // `configureAnalyzer`: "If there are no inputs or outputs, we stop with that tab selected."
    // The `andor` fixture with its one output pin removed; the gates and wires stay, so this is
    // a real circuit that simply has nowhere to report a result.
    let text = andOrCirc.replacingOccurrences(
      of: #"<a name="output" val="true"/>"#, with: "")
    let (file, circuit) = try load(text, circuit: "andor")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: file)
    // Jar output on the same edit (`DeriveProbe andor_noout.circ andor`):
    //     PIN a in / PIN b in / PIN y in / PIN c in
    //     TABLE inputs=4 outputs=0 rows=16
    // ; a Pin with no `output` attribute is an *input* pin, so `y` joins the inputs rather than
    // vanishing, and it keeps its position in the vertical sort.
    #expect(analysis.outputVariables.isEmpty)
    #expect(analysis.inputVariables.map(\.name) == ["a", "b", "y", "c"])
    // `configureAnalyzer` returns on the Inputs/Outputs tab before computing anything, so the
    // port must NOT have simulated 16 rows to fill zero columns.
    #expect(!analysis.tableComputed)
    #expect(analysis.truthTable.outputColumnCount == 0)
  }
}
