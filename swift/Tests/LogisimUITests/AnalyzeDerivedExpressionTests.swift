// AnalyzeDerivedExpressionTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The other half of the expression gate.
//
// `LogisimStdTests/AnalyzeExpressionTests` proves the *walk* is right: it runs
// `CircuitExpressions.compute` against a recording algebra and compares the resulting tree,
// node for node, with the 4.1.0 jar's. It cannot use the real `Expression`, because
// `LogisimStd` does not depend on `LogisimAnalyze`.
//
// This file closes that gap from the other side. It runs the same derivations through
// `AnalyzeExpressionAlgebra`, the algebra backed by the actual `LogisimAnalyze.Expression`,
// and asserts on the **rendered string**, against the `STR` column of the same jar probe. That
// is what the Analyze window puts on screen, so this is the end-to-end assertion: a `.circ` in,
// the string a user reads out.
//
// Together they close the loop. The tree test would pass against an algebra that built the right
// shape out of the wrong type; this one would pass against a printer that happened to agree on
// these five inputs. Neither passes against a derivation that is not wired to anything, because
// both start from a `Circuit`.
//
// Jar oracle (`ExprProbe`, source in `LogisimStdTests/AnalyzeExpressionTests`):
//
//     andor     STR y   a⋅b+c
//     notbus    STR q[1] ~d[1]   STR q[0] ~d[0]
//     nand2     STR y   ~(a⋅b)
//     nor2      STR y   ~(a+b)
//     xor2      STR y   a⊕b
//     xnor2     STR y   ~(a⊕b)
//     or3       STR y   a+b+c
//     splitand  STR y   d[0]⋅d[1]
//
// Note `nand2` renders `~(a⋅b)`, parenthesised, and not `~a⋅b`. `Expression`'s printer adds
// the parentheses from the tree's shape, so this string is also a check that the NOT wraps the
// whole AND rather than its first operand, which the prefix-form test asserts structurally.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@MainActor
private func loadCircuit(_ text: String, named name: String) throws -> Circuit {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  let file = try #require(try Loader().openLogisimFile(data: Data(text.utf8)))
  return try #require(file.circuit(named: name))
}

/// Six single-gate circuits plus a splitter, in one file. Geometry read out of the jar with
/// `ExprProbe`'s `ENDS` dump rather than computed from `getOffsetBounds` by hand: the input
/// wires deliberately run past every gate's input `x` so the same two rows serve AND (body 40),
/// NAND/XOR (50) and NOR/XNOR (60).
private let zooCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="nand2"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="nand2">
      <a name="circuit" val="nand2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="NAND Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="nor2">
      <a name="circuit" val="nor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="NOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="xor2">
      <a name="circuit" val="xor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="XOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="xnor2">
      <a name="circuit" val="xnor2"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="XNOR Gate"/>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="or3">
      <a name="circuit" val="or3"/>
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,120)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="c"/></comp>
      <comp lib="0" loc="(300,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="OR Gate"><a name="inputs" val="3"/></comp>
      <wire from="(80,100)" to="(215,100)"/>
      <wire from="(80,120)" to="(215,120)"/>
      <wire from="(80,140)" to="(215,140)"/>
      <wire from="(220,120)" to="(300,120)"/>
    </circuit>
    <circuit name="splitand">
      <a name="circuit" val="splitand"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="d"/><a name="width" val="2"/>
      </comp>
      <comp lib="0" loc="(400,120)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
      </comp>
      <comp lib="0" loc="(160,100)" name="Splitter">
        <a name="fanout" val="2"/><a name="incoming" val="2"/>
      </comp>
      <comp lib="1" loc="(320,120)" name="AND Gate"/>
      <wire from="(80,100)" to="(160,100)"/>
      <wire from="(320,120)" to="(400,120)"/>
      <wire from="(180,80)" to="(250,80)"/>
      <wire from="(250,80)" to="(250,100)"/>
      <wire from="(250,100)" to="(270,100)"/>
      <wire from="(180,90)" to="(230,90)"/>
      <wire from="(230,90)" to="(230,140)"/>
      <wire from="(230,140)" to="(270,140)"/>
    </circuit>
  </project>
  """

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
      <comp lib="0" loc="(80,100)" name="Pin"><a name="label" val="a"/></comp>
      <comp lib="0" loc="(80,140)" name="Pin"><a name="label" val="b"/></comp>
      <comp lib="0" loc="(80,220)" name="Pin"><a name="label" val="c"/></comp>
      <comp lib="0" loc="(390,170)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="y"/><a name="output" val="true"/>
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
        <a name="label" val="d"/><a name="width" val="2"/>
      </comp>
      <comp lib="0" loc="(240,100)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="q"/>
        <a name="output" val="true"/><a name="width" val="2"/>
      </comp>
      <comp lib="1" loc="(180,100)" name="NOT Gate"><a name="width" val="2"/></comp>
      <wire from="(80,100)" to="(150,100)"/>
      <wire from="(180,100)" to="(240,100)"/>
    </circuit>
  </project>
  """

@MainActor
@Suite("Analyze — the derived expression, rendered through LogisimAnalyze.Expression")
struct AnalyzeDerivedExpressionTests {

  /// The one-gate cases, each string a literal from `ExprProbe`'s `STR` column.
  @Test(
    "Each derived expression renders exactly as the jar prints it",
    arguments: [
      ("nand2", "~(a⋅b)"),
      ("nor2", "~(a+b)"),
      ("xor2", "a⊕b"),
      ("xnor2", "~(a⊕b)"),
      ("or3", "a+b+c"),
      ("splitand", "d[0]⋅d[1]"),
    ])
  func renderedFormMatchesTheJar(name: String, expected: String) throws {
    let circuit = try loadCircuit(zooCirc, named: name)
    let derived = try CircuitAnalysis.deriveExpressions(circuit: circuit)
    #expect(derived.map(\.name) == ["y"])
    let expression = try #require(derived.first?.expression)
    #expect(expression.description == expected, "\(name)")
  }

  /// `ExprProbe andOrCirc.circ andor` → `STR y  a⋅b+c`.
  ///
  /// Two gates, so the fixpoint loop actually iterates, and the real `Expression` is the one
  /// being compared for equality by the loop's dirty test; the algebra's `equals` is
  /// `Expression`'s synthesised structural `==` here, not the test double's string compare.
  @Test("A two-gate circuit renders as the jar prints it")
  func twoGateCircuitRenders() throws {
    let circuit = try loadCircuit(andOrCirc, named: "andor")
    let derived = try CircuitAnalysis.deriveExpressions(circuit: circuit)
    #expect(derived.map(\.name) == ["y"])
    #expect(derived.first?.expression?.description == "a⋅b+c")
  }

  /// `ExprProbe notBusCirc.circ notbus` → `q[1] ~d[1]`, `q[0] ~d[0]`, in that order.
  @Test("A 2-bit output yields one rendered expression per bit, MSB first")
  func multiBitOutputRenders() throws {
    let circuit = try loadCircuit(notBusCirc, named: "notbus")
    let derived = try CircuitAnalysis.deriveExpressions(circuit: circuit)
    #expect(derived.map(\.name) == ["q[1]", "q[0]"])
    #expect(derived.map { $0.expression?.description } == ["~d[1]", "~d[0]"])
  }

  /// The derived expression is accepted by the model that the window reads, and survives the
  /// round trip without being replaced.
  ///
  /// This is the seam assertion for the *join*: a derivation nothing can consume is the defect
  /// this port keeps finding. `OutputExpressions.setExpression` is the API
  /// `Analyze.computeExpression` ends on, and the bit names produced here have to be exactly the
  /// ones `VariableList.bits` holds or the call silently no-ops on an unknown output.
  @Test("The derived expressions install into a real AnalyzerModel under the model's bit names")
  func expressionsInstallIntoTheModel() throws {
    let circuit = try loadCircuit(notBusCirc, named: "notbus")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: nil)
    let derived = try CircuitAnalysis.deriveExpressions(circuit: circuit)

    // The names line up index for index with the model's own output bit list.
    #expect(derived.map(\.name) == analysis.model.outputs.bits)

    for entry in derived {
      try analysis.model.outputExpressions.setExpression(entry.name, entry.expression)
    }
    for entry in derived {
      #expect(analysis.model.outputExpressions.expression(for: entry.name) == entry.expression)
    }
    // Hold `analysis` past the last read: `TruthTable.model` is an `unowned` edge (D3), so
    // letting it go earlier destroys the model out from under these reads.
    withExtendedLifetime(analysis) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // SEAM #26; `analyze` ITSELF has to take the netlist path, and the test above does not say so
  // ═══════════════════════════════════════════════════════════════════════════════════════════
  //
  // `expressionsInstallIntoTheModel` performs the install itself, in the test body. That proves
  // `setExpression` accepts the bit names: a real question, and not this one. It passes
  // unchanged against a `CircuitAnalysis.analyze` that never calls `deriveExpressions` at all,
  // which is exactly what `analyze` did until 2026-09-06: the function was defined once in
  // Sources, called zero times there, and four times from this file.
  //
  // So the assertion that discriminates is on `analysis.derivation`, which only the product can
  // produce. Deleting the `do { … } catch is AnalyzeError` block from `analyze` turns the first
  // two of these red and leaves the third green.

  @Test("analyze takes the NETLIST path when every component vends the feature")
  func analyzeUsesTheNetlistPath() throws {
    let circuit = try loadCircuit(notBusCirc, named: "notbus")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: nil)
    #expect(
      analysis.derivation == .netlistExpressions,
      """
      analyze fell back to the truth table on a circuit of nothing but a NOT gate and two pins. \
      `deriveExpressions` is not being called — that is seam #26.
      """)
    #expect(analysis.tableComputed)
    withExtendedLifetime(analysis) {}
  }

  /// The netlist path must not cost the Table tab, and it does not come free: nothing simulates
  /// on this path. `OutputData.setExpression` evaluates the expression over every row and calls
  /// `truthTable.setOutputColumn` (`OutputExpressions.swift:184-188`), and this asserts that
  /// actually happened rather than trusting the read.
  ///
  /// `q = ~d` over a 2-bit `d`, so the four rows are 11, 10, 01, 00 top to bottom.
  @Test("the netlist path still fills the truth table, so the Table tab is not empty")
  func netlistPathStillFillsTheTable() throws {
    let circuit = try loadCircuit(notBusCirc, named: "notbus")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: nil)
    let table = analysis.truthTable

    #expect(analysis.derivation == .netlistExpressions)
    #expect(table.rowCount == 4)
    #expect(table.outputColumnCount == 2, "q is 2 bits, so there are two output columns")

    // Every cell must be a real 0/1. An all-`dontCare` column is precisely what "expressions set,
    // table never populated" would look like, and it would pass a mere rowCount check.
    var seen: [String] = []
    for row in 0..<table.rowCount {
      seen.append((0..<table.outputColumnCount).map { "\(table.outputEntry(row: row, column: $0))" }
        .joined())
    }
    #expect(
      !seen.contains { $0.contains("x") || $0.contains("-") },
      "an output cell is still unset, so the expression path did not populate the table: \(seen)")
    withExtendedLifetime(analysis) {}
  }

  @Test("analyze FALLS BACK to the truth table when a component vends no feature")
  func analyzeFallsBackWhenAComponentLacksTheFeature() throws {
    let circuit = try loadCircuit(muxFallbackCirc, named: "muxfall")
    let analysis = try CircuitAnalysis.analyze(circuit: circuit, file: nil)
    #expect(
      analysis.derivation == .truthTable,
      """
      analyze claimed the netlist path on a circuit containing a Multiplexer, which vends no \
      ExpressionComputer. `propagateComponents` should have thrown .cannotHandle.
      """)
    #expect(analysis.tableComputed, "the fallback must still produce a table")
    withExtendedLifetime(analysis) {}
  }
}

/// `notBusCirc` plus an **unconnected** Multiplexer.
///
/// Unconnected is deliberate and is not a shortcut: `Analyze.propagateComponents` iterates every
/// component in the circuit and aborts on the first one that vends no `ExpressionComputer` and is
/// not a pin, splitter or text label (`CircuitExpressions.swift:281-300`). It does not walk back
/// from the outputs, so a featureless part anywhere in the circuit is enough, which is exactly
/// why upstream takes the table path on two of three corpus circuits.
private let muxFallbackCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <lib desc="#Plexers" name="2"/>
    <main name="muxfall"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="muxfall">
      <a name="circuit" val="muxfall"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="d"/>
      </comp>
      <comp lib="0" loc="(240,100)" name="Pin">
        <a name="facing" val="west"/><a name="label" val="q"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(180,100)" name="NOT Gate"/>
      <comp lib="2" loc="(180,300)" name="Multiplexer"/>
      <wire from="(80,100)" to="(150,100)"/>
      <wire from="(180,100)" to="(240,100)"/>
    </circuit>
  </project>
  """
