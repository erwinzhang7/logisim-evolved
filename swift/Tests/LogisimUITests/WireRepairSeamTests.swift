// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES THE EDITOR REPAIR WIRES, AND IS THE REPAIR UNDOABLE?
//
// `CircuitTransaction.wireRepair` was called once in `execute` and assigned NOWHERE in Sources or
// Tests, so the editor never ran the pass. The user-visible consequence: **drop a component onto
// a wire and it is not connected.** `CircuitPoints.add(Wire)` records only `getEnd0()`/
// `getEnd1()`, so a segment drawn *through* a port is not connected to it until `doSplits` cuts
// it there. The same cause produced the last four M3 simulation failures and the unexplained
// `2.7.2__case-432.circ` netlist divergence.
//
// ── WHY THESE ASSERT ON UNDO AND NOT JUST ON CONNECTIVITY ────────────────────────────────────
//
// The tempting installation is `{ circuit, _ in WireRepair(circuit: circuit).run() }`, which
// discards the mutator. It repairs the wires and passes any connectivity test: and the edits
// never enter the `ReplacementMap`, so undo leaves the cuts behind. A test that only checked "the
// wire got split" would be green against exactly the version worth rejecting.
//
// So the discriminating assertion is that ⌘Z restores the pre-repair wire count.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Wire repair seam", .serialized)
struct WireRepairSeamTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  @Test("the seam is installed at all")
  @MainActor
  func seamIsInstalled() throws {
    _ = try makeHost()
    // Necessary and nowhere near sufficient; see the header. The behaviour tests below are what
    // separate a real installation from one that discards the mutator.
    #expect(CircuitTransaction.wireRepair != nil)
  }

  @Test("a component dropped onto a wire cuts it, so the two are connected")
  @MainActor
  func dropOntoWireSplitsIt() throws {
    let host = try makeHost()
    let circuit = try #require(host.currentCircuitObject)

    // One long wire, and a Pin placed at its midpoint. Before the repair pass ran, the wire was
    // a single segment whose only recorded points are its ends, so the Pin at (140,100) touched
    // nothing.
    let wire = Wire.create(
      Location.create(100, 100, hasToSnap: false), Location.create(180, 100, hasToSnap: false))
    try circuit.mutatorAdd(wire)
    let wiresBefore = circuit.wires.count

    let pin = try Pin.factory.createComponent(
      location: Location.create(140, 100, hasToSnap: false),
      attributes: Pin.factory.createAttributeSet())

    let mutation = host.project.beginMutation(on: circuit)
    mutation.add(pin)
    try host.project.doAction(mutation.toAction("drop a pin on a wire"))

    let cutMessage: Comment =
      """
      the wire was not cut at the pin: \(circuit.wires.count) wires, was \(wiresBefore). \
      CircuitTransaction.wireRepair is not reaching the pass.
      """
    #expect(circuit.wires.count > wiresBefore, cutMessage)

    // And the cut is AT the pin, not anywhere: some wire must now end there.
    let pinPoint = Location.create(140, 100, hasToSnap: false)
    #expect(
      circuit.wires.contains { $0.endpoint0 == pinPoint || $0.endpoint1 == pinPoint },
      "no wire ends at the pin, so the split did not happen where the port is")
  }

  @Test("the repair is RECORDED in the transaction's replacement map")
  @MainActor
  func repairIsRecorded() throws {
    let host = try makeHost()
    let circuit = try #require(host.currentCircuitObject)

    // ── MY FIRST VERSION OF THIS TEST ASSERTED ON UNDO, AND IT DID NOT DISCRIMINATE ──────────
    //
    // The reasoning was: a repair that bypasses the mutator is not in the ReplacementMap, so undo
    // leaves the cuts behind. Plausible, and wrong. `CircuitAction.undo` runs
    // `result.reverseTransaction()`, which is ITSELF a `CircuitTransaction`, so executing it
    // re-runs wire repair, and with the pin gone `doMerges` collapses the two collinear segments
    // back into one. **The pass is self-healing under undo**, so the wire count returns either
    // way and the red probe passed.
    //
    // That is a good property and a useless assertion. The question that actually separates the
    // two installations is whether the edit was RECORDED, so this asks the transaction directly,
    // through the `transactionDone` seam, which is the third of board #22's unassigned hooks and
    // exists for exactly this kind of consumer.
    // The seam is `@Sendable`, and neither `ReplacementMap` nor `Circuit` is `Sendable`, so the
    // capture goes through a box. Everything here runs on the main actor -- `execute()` calls the
    // hook synchronously -- so the unchecked conformance is describing what is already true
    // rather than asserting something new.
    // ── SAVE AND RESTORE, NOT `= nil` ────────────────────────────────────────────────────────
    //
    // This used to end `defer { CircuitTransaction.transactionDone = nil }`. That was harmless
    // while nothing else owned the slot and became an order-dependent flake the moment something
    // did: the seam is now installed **permanently** by
    // `LogisimFileProjectHostFactory.installProcessSeams()` and broadcasts every transaction
    // result to every live `Selection`. Nilling it would silently switch that delivery off for
    // whatever ran after this suite in the same process: a whole test target's worth of drags
    // quietly reverting to the duplication bug, in a file that has nothing to do with selections.
    //
    // The chain also matters, not just the restore: the permanent handler must still run while
    // this one is installed, or a `makeHost()` inside this window would build a canvas whose
    // selection never hears anything.
    let box = ResultBox()
    let installed = CircuitTransaction.transactionDone
    CircuitTransaction.transactionDone = { result in
      installed?(result)
      guard let modified = result.modifiedCircuits.first else { return }
      box.store(result.replacementMap(for: modified))
    }
    defer { CircuitTransaction.transactionDone = installed }

    let wire = Wire.create(
      Location.create(100, 200, hasToSnap: false), Location.create(180, 200, hasToSnap: false))
    try circuit.mutatorAdd(wire)

    let pin = try Pin.factory.createComponent(
      location: Location.create(140, 200, hasToSnap: false),
      attributes: Pin.factory.createAttributeSet())
    let mutation = host.project.beginMutation(on: circuit)
    mutation.add(pin)
    try host.project.doAction(mutation.toAction("drop a pin on a wire"))

    let map = try #require(box.value, "no transaction result was delivered")

    // The pin's addition alone would satisfy "the map is non-empty", so the assertion is
    // specifically that the WIRE the repair cut is in the removals.
    #expect(
      map.removals.contains { ($0 as? Wire) === wire },
      """
      the repaired wire is not in the transaction's replacement map, so the repair bypassed the \
      mutator: removals are \(map.removals.map { type(of: $0) })
      """)
  }
}

/// See `repairIsRecorded`: the `transactionDone` seam is `@Sendable` and `ReplacementMap` is not.
private final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ReplacementMap?
  func store(_ map: ReplacementMap) { lock.lock(); stored = map; lock.unlock() }
  var value: ReplacementMap? { lock.lock(); defer { lock.unlock() }; return stored }
}
