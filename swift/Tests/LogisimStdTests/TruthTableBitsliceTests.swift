// TruthTableBitsliceTests.swift: part of logisim-evolved.
//
// M9 asked for bitsliced truth-table evaluation: pack 64 row assignments into the bit positions
// of one value, propagate once, read 64 rows out. `TruthTableRun`'s header records why that was
// rejected; the value *lattice* bitslices fine (it is three disjoint `Int64` planes and
// `Value.and`'s wide branch is already a 64-lane 4-valued AND), but 21.5% of the corpus's 40,569
// component placements are not gates, and re-expressing an adder, a multiplexer, a RAM or a
// register lane-wise is a second implementation of every component in the tree.
//
// One piece survived, and this suite is its guard. Building a row's input assignment does not
// need a `[Value]` of per-bit singletons that `Value.create(_:)` then re-packs bit by bit: the
// assignment is `width` KNOWN bits, so `error` and `unknown` are identically zero and the whole
// thing is one plane. `TruthTableRun.inputPlane` packs it directly.
//
// ── Why the packing gets a test of its own ──────────────────────────────────────────────────
//
// Because it carries three of upstream's quirks in four lines, and every one of them is a
// silent-wrong-answer if dropped:
//
//   * the shift distance is masked to 5 bits, so past 31 input bits distinct columns ALIAS onto
//     the same bit of the row index; that is not a bug to fix, it is the table 4.1.0 prints
//     (138 corpus oracles have more than 31 input bits, up to 74);
//   * `distance == 31` must produce `Int32.min`, i.e. a NEGATIVE mask, because Java's `int`
//     shift does;
//   * a pin's FIRST column is its MOST significant bit, so the bit loop counts down while the
//     column counter counts up.
//
// So the test holds the `[Value]`-array construction this replaced as a reference oracle and
// asserts the two agree, rather than asserting hand-computed constants; a hand-computed
// expectation for the aliasing regime is exactly as likely to be wrong as the code.
//
// The second half of the suite pins the property that any FUTURE strategy change depends on and
// that no existing test states: a table row is a pure function of its input assignment. That is
// what makes rows independent, and it is the precondition for evaluating them in any order, in
// parallel, or several at once. It is asserted against a circuit holding a component with state,
// because for a stateless one it is trivially true and proves nothing.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - Fixtures

/// `StdLibraries.registerAll()` once for the file. See `SubcircuitPropagationTests` for why once
/// is the correct number of times.
private let librariesRegistered: Void = StdLibraries.registerAll()

private func at(_ x: Int, _ y: Int) -> Location {
  Location.create(x, y, hasToSnap: true)
}

private func pin(
  _ label: String, _ type: AttributeOption, width: Int = 1, at location: Location
) throws -> any Component {
  let attrs = Pin.factory.createAttributeSet()
  try attrs.setValue(Pin.attrType, type)
  try attrs.setValue(StdAttr.label, label)
  try attrs.setValue(StdAttr.width, try BitWidth.create(width))
  return try Pin.factory.createComponent(location: location, attributes: attrs)
}

/// **The reference oracle: the construction `inputPlane` replaced**, verbatim.
///
/// A `[Value]` of one-bit singletons, most-significant bit first, handed to `Value.create(_:)`.
/// Kept here rather than deleted so the replacement is checked against the thing it replaced and
/// not against someone's reading of it.
private func referenceInputValue(
  row: Int, width: Int, firstColumn incol: inout Int, inputCount: Int
) throws -> Value {
  var bits = [Value](repeating: .falseValue, count: width)
  for b in stride(from: width - 1, through: 0, by: -1) {
    let distance = Int32((inputCount - incol - 1) & 31)
    let mask = Int(Int32(truncatingIfNeeded: 1 << distance))
    let set = (row & mask) != 0
    incol += 1
    bits[b] = set ? .trueValue : .falseValue
  }
  return try Value.create(bits)
}

// MARK: - The packing

@Suite("M9 — the one packing that survived, and the property it rests on")
struct TruthTableBitsliceTests {

  /// The packed plane and the `[Value]` array agree, over every shape the corpus can present.
  ///
  /// Sweeps widths 1…64, input counts spanning the three regimes that the `& 31` mask creates,
  /// below 31 (no aliasing), exactly 31 (`rowCount` goes negative and upstream prints nothing),
  /// and above 31 (columns alias), and, at each, a spread of row indices including the ones
  /// whose bit patterns are all-zero, all-ones and the sign bit alone.
  @Test("the packed input plane equals the [Value] construction it replaced")
  func packingMatchesTheArrayConstruction() throws {
    _ = librariesRegistered
    let widths = Array(1...64)
    let inputCounts = [1, 2, 7, 8, 30, 31, 32, 33, 40, 63, 64, 66, 74]
    let rows = [
      0, 1, 2, 3, 5, 7, 8, 15, 16, 255, 256, 4095, 4096, 65535, 65536,
      0x1234_5678, 0x7FFF_FFFF, 0x4000_0000,
    ]

    var checked = 0
    for inputCount in inputCounts {
      for width in widths where width <= inputCount {
        for row in rows {
          var packedColumn = 0
          let plane = TruthTableRun.inputPlane(
            row: row, width: width, firstColumn: &packedColumn, inputCount: inputCount)
          let packed = Value.create(width: width, error: 0, unknown: 0, value: plane)

          var referenceColumn = 0
          let reference = try referenceInputValue(
            row: row, width: width, firstColumn: &referenceColumn, inputCount: inputCount)

          #expect(
            packed == reference,
            """
            inputCount=\(inputCount) width=\(width) row=\(row): \
            packed=\(packed.toBinaryString()) reference=\(reference.toBinaryString())
            """)
          #expect(packedColumn == referenceColumn, "the column counter must advance identically")
          checked += 1
        }
      }
    }
    // A filter that matched nothing would print "0 tests passed" and look green; a sweep that
    // swept nothing would look the same. Name the number.
    #expect(checked > 5_000, "expected a broad sweep, ran \(checked) comparisons")
  }

  /// The column counter is shared across pins, so pin *k*'s bits must continue where pin *k-1*
  /// stopped. Two 3-bit pins in an 6-bit table must produce the same six columns as one 6-bit
  /// pin; this is the invariant that a refactor to `inout` is most likely to break.
  @Test("consecutive pins consume consecutive columns")
  func consecutivePinsShareTheColumnCounter() throws {
    for row in 0..<64 {
      var wide = 0
      let whole = TruthTableRun.inputPlane(
        row: row, width: 6, firstColumn: &wide, inputCount: 6)

      var split = 0
      let high = TruthTableRun.inputPlane(
        row: row, width: 3, firstColumn: &split, inputCount: 6)
      let low = TruthTableRun.inputPlane(
        row: row, width: 3, firstColumn: &split, inputCount: 6)

      #expect(split == wide, "both forms must consume 6 columns")
      #expect((high << 3) | low == whole, "row \(row): split pins must reassemble the whole")
    }
  }

  // MARK: - The property a future strategy change would rest on

  /// **A row is a pure function of its input assignment**, even when the circuit holds state,
  /// and this is asserted by pinning a table whose bytes *say so*, not by comparing a run
  /// against itself.
  ///
  /// Comparing a run against itself would prove nothing here: a state-reusing implementation is
  /// perfectly deterministic and agrees with itself every time. So the expectation is the literal
  /// table, and `statefulCircuit` explains why it takes both a flip-flop **and** an AND gate to
  /// make that table discriminating; the flip-flop alone was tried, and it is not.
  ///
  /// Confirmed by red probe: hoisting `createRootState` out of the row loop, the exact mutation
  /// any row-batching strategy would make, fails this test and the shared-session one, and
  /// leaves the two packing tests green, which is the correct split.
  ///
  /// Upstream creates that fresh state inside the loop deliberately (`TtyInterface`); this is the
  /// test that says so in bytes.
  @Test("a row is a pure function of its inputs, with state in the circuit")
  func rowsAreIndependentOfEvaluationHistory() throws {
    _ = librariesRegistered
    let circuit = try statefulCircuit(named: "m9-purity")

    let table = try TruthTableRun.run(
      circuit: circuit, session: SimulationSession(host: SimulationHost()))

    #expect(
      table == """
        d c a b q x
        0 0 0 0 0 0
        0 0 0 1 0 0
        0 0 1 0 0 0
        0 0 1 1 0 1
        0 1 0 0 0 0
        0 1 0 1 0 0
        0 1 1 0 0 0
        0 1 1 1 0 1
        1 0 0 0 0 0
        1 0 0 1 0 0
        1 0 1 0 0 0
        1 0 1 1 0 1
        1 1 0 0 0 0
        1 1 0 1 0 0
        1 1 1 0 0 0
        1 1 1 1 0 1

        """,
      "the fresh-state table; a frozen or state-carrying evaluation differs. got:\n\(table)")
  }

  /// The same fixture, run twice through **one shared session**, which is the thing that would
  /// catch state pooled a level up rather than per row. `SimulationSession` caches one
  /// `SimulatedCircuit` per `Circuit`, so the second run reaches the same wrapper the first did.
  @Test("a shared session does not carry state between runs")
  func rowsAreIndependentOfTheSession() throws {
    _ = librariesRegistered
    let circuit = try statefulCircuit(named: "m9-purity-shared")
    let session = SimulationSession(host: SimulationHost())

    let first = try TruthTableRun.run(circuit: circuit, session: session)
    let second = try TruthTableRun.run(circuit: circuit, session: session)

    #expect(first == second, "a reused session must not change the table")
    #expect(first.hasSuffix("1 1 1 1 0 1\n"), "and it must still be the fresh-state table")
  }

  /// A 2-input circuit whose output pin is fed by a `D Flip-Flop`; a component that keeps
  /// `componentData` across a propagation. What it *computes* does not matter; that it has state
  /// to carry is the point.
  private func statefulCircuit(named name: String) throws -> Circuit {
    let circuit = try Circuit(name: name, defaultAppearance: CircuitAttributes.appearEvolution)
    try circuit.staticAttributes.setValue(
      CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
    try circuit.staticAttributes.setValue(CircuitAttributes.namedCircuitBoxFixedSize, false)

    // The flip-flop goes down first and the pins land **exactly on its ends**, rather than being
    // placed at chosen coordinates and wired across. `SubcircuitPropagationTests.wrap` does the
    // same thing for the same reason: a wire between two points this fixture picked would have to
    // be axis-aligned, and the port geometry is not this suite's contract; a layout change one
    // file over would show up here as a propagation failure.
    //
    // `AbstractFlipFlop.updatePorts` (`:171-207`) lays a D flip-flop out as
    // `[D, clock, Q, Q̄, preset, clear]`, so `ends[0]`/`ends[1]` are the two driven inputs and
    // `ends[2]` is the observed output. Indexing `ends.last` would land on `clear`.
    let factory = DFlipFlop()
    let ff = try factory.createComponent(
      location: at(250, 150), attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(ff)

    let ends = ff.ends
    #expect(ends.count >= 3, "a D flip-flop should expose D, clock and Q")
    guard ends.count >= 3 else { throw CancellationError() }
    try circuit.mutatorAdd(try pin("d", Pin.input, at: ends[0].location))
    try circuit.mutatorAdd(try pin("c", Pin.input, at: ends[1].location))
    try circuit.mutatorAdd(try pin("q", Pin.output, at: ends[2].location))

    // ── And a combinational half, which is not decoration ─────────────────────────────────────
    //
    // The flip-flop alone cannot carry this test. Measured: hoisting the per-row
    // `createRootState` out of the loop, the exact mutation this suite exists to catch, leaves
    // the flip-flop's table **byte-identical**, because two errors cancel. Nothing re-marks the
    // pins dirty on rows 1…n, so the circuit stops re-propagating altogether and Q freezes at
    // row 0's `0`; and the correct fresh-state answer is also `0` on every row, since a clock that
    // goes `U -> 1` is not a rising edge and Q never loads.
    //
    // So the fixture needs a column that **moves with the inputs**. An AND gate does: the correct
    // table has `1` in its last row, and any evaluation that stops re-propagating freezes it at
    // `0`. The flip-flop stays because it is the component with `componentData`; it is what makes
    // a state-carrying implementation (as opposed to a frozen one) show up as well.
    let gate = AndGate.factory
    let andGate = try gate.createComponent(
      location: at(500, 500), attributes: gate.createAttributeSet())
    try circuit.mutatorAdd(andGate)
    // Direction read off `EndData.type` rather than assumed from a port index, so a change to the
    // gate's port order is not silently absorbed.
    var inputIndex = 0
    for end in andGate.ends {
      if end.type == EndType.inputOnly {
        try circuit.mutatorAdd(
          try pin(inputIndex == 0 ? "a" : "b", Pin.input, at: end.location))
        inputIndex += 1
      } else {
        try circuit.mutatorAdd(try pin("x", Pin.output, at: end.location))
      }
    }
    #expect(inputIndex == 2, "a default AND gate should have two inputs")
    return circuit
  }
}
