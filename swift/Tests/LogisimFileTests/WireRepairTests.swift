// WireRepairTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// `WireRepair` is ported but NOT called yet: `XmlCircuitReader.execute()` documents why, with
// the numbers. That makes these tests the only thing keeping it honest, so they assert the
// behaviour rather than merely that it runs.
//
// Everything here is built out of `Wire` alone. That is not a limitation dodged, it is the
// point: `LogisimFileTests` links only `LogisimFile`, so there is no component whose `ends`
// could be wrong, and the pass is measured against an input that is definitionally correct.
// Feeding it a REAL circuit is exactly what fails today, and it fails on the input, not here.

import Foundation
import Testing

@testable import LogisimFile
@testable import LogisimKernel

private func at(_ x: Int, _ y: Int) -> Location { Location.create(x, y, hasToSnap: false) }

private func circuit(_ wires: [(Int, Int, Int, Int)]) throws -> Circuit {
  let circuit = try Circuit(name: "main")
  for (x0, y0, x1, y1) in wires {
    try circuit.mutatorAdd(Wire.create(at(x0, y0), at(x1, y1)))
  }
  return circuit
}

/// Endpoint pairs, sorted, so an assertion names positions rather than object order.
private func wireList(_ circuit: Circuit) -> [String] {
  circuit.wires.map { "\($0.endpoint0)-\($0.endpoint1)" }.sorted()
}

// MARK: - doMerges

@Test func twoCollinearWiresMeetingWhereNothingElseConnectsBecomeOne() throws {
  // The point (10,0) carries exactly two components, both wires, both horizontal: upstream's
  // definition of an artificial break.
  let c = try circuit([(0, 0, 10, 0), (10, 0, 20, 0)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(20,0)"])
}

@Test func aChainOfCollinearSegmentsCollapsesToItsExtremes() throws {
  // Merge sets are transitive: upstream unions them and then takes min/max of every endpoint,
  // so a four-segment chain becomes one wire and not three.
  let c = try circuit([(0, 0, 10, 0), (10, 0, 20, 0), (20, 0, 30, 0), (30, 0, 40, 0)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(40,0)"])
}

@Test func perpendicularWiresMeetingAtAPointAreNotMerged() throws {
  // Two components at the point, but `isParallel` is false, so nothing merges, and neither is
  // split, because the meeting point is an endpoint of both.
  let c = try circuit([(0, 0, 10, 0), (10, 0, 10, 10)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(10,0)", "(10,0)-(10,10)"])
}

// MARK: - doSplits

@Test func aWireIsCutWhereAnotherWireEndsInsideIt() throws {
  // The T-junction, and the shape of the corpus divergence this pass exists to fix: (10,0) lies
  // strictly inside the horizontal wire and is an endpoint of the vertical one.
  let c = try circuit([(0, 0, 20, 0), (10, 0, 10, 10)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(10,0)", "(10,0)-(10,10)", "(10,0)-(20,0)"])
}

@Test func aWireIsCutAtEveryInteriorConnectionNotJustTheFirst() throws {
  let c = try circuit([(0, 0, 30, 0), (10, 0, 10, 10), (20, 0, 20, 10)])
  WireRepair(circuit: c).run()
  #expect(
    wireList(c) == [
      "(0,0)-(10,0)", "(10,0)-(10,10)", "(10,0)-(20,0)", "(20,0)-(20,10)", "(20,0)-(30,0)",
    ])
}

// MARK: - doOverlaps

@Test func aWireLyingInsideAnotherIsAbsorbedAndTheUnionRecut() throws {
  // Genuine overlap rather than a shared endpoint: (10,0)-(20,0) sits within (0,0)-(30,0). The
  // union is (0,0)-(30,0), and with nothing else connected it stays whole.
  let c = try circuit([(0, 0, 30, 0), (10, 0, 20, 0)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(30,0)"])
}

@Test func anOverlapIsRecutWhereSomethingOutsideTheSetConnects() throws {
  // Same overlap, plus a vertical wire ending at (20,0). That location is foreign to the merge
  // set, so `doMergeSet` cuts the union there instead of returning it whole.
  let c = try circuit([(0, 0, 30, 0), (10, 0, 20, 0), (20, 0, 20, 10)])
  WireRepair(circuit: c).run()
  #expect(wireList(c) == ["(0,0)-(20,0)", "(20,0)-(20,10)", "(20,0)-(30,0)"])
}

// MARK: - Idempotence

@Test func repairingAnAlreadyRepairedCircuitChangesNothing() throws {
  // The property that makes the CANONICAL gate insensitive to this pass: upstream repairs on
  // every load, so its own output is a fixed point. A second run must be a no-op, or enabling
  // the pass would break files it had itself produced.
  let c = try circuit([(0, 0, 30, 0), (10, 0, 10, 10), (20, 0, 20, 10)])
  WireRepair(circuit: c).run()
  let once = wireList(c)
  WireRepair(circuit: c).run()
  #expect(wireList(c) == once)
}

@Test func aCircuitWithNoWiresIsLeftAlone() throws {
  let c = try circuit([])
  WireRepair(circuit: c).run()
  #expect(c.wires.isEmpty)
}
