// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES A SUBCIRCUIT'S DEFAULT APPEARANCE FOLLOW ITS SOURCE CIRCUIT'S STATIC ATTRIBUTES?
//
// `CircuitMutatorImpl.setForCircuit` queues `appearanceRecomputeRequests` for two attributes,
// mirroring upstream's inline `circuit.getAppearance().recomputeDefaultAppearance()`. Nothing
// drained the queue, and `CircuitTransaction.appearanceHook` was declared, called, and assigned
// nowhere. Seam #25.
//
// ── THE TASK SAID TO TEST A RENAME. THE RENAME ALREADY WORKED ────────────────────────────────
//
// Measured before touching anything, on a one-in/one-out child placed in a parent and renamed
// `aa` → `a_very_long_circuit_name` through `project.doAction`:
//
//     bounds  (230,290) 70x40   →  (80,290) 220x40
//     ends    [(230,300), (300,300)]  →  [(80,300), (300,300)]
//
// Both correct. `CircuitStaticAttributeListener` fires `.setName`,
// `CircuitSubcircuitFactory.observeSource` handles it, and the layout cache is dropped. So a
// rename test does NOT discriminate: it is green against a build with no seam installed at all,
// which is exactly the failure mode this project keeps hitting.
//
// ── THE ATTRIBUTE THAT ACTUALLY HAD NO ROUTE HOME ────────────────────────────────────────────
//
// The queue's OTHER attribute, `namedCircuitBoxFixedSize`, fires `.changeDefaultBoxAppearance`,
// which is declared in `CircuitEvent`, handled in `observeSource`, and **fired nowhere in
// Sources or Tests**. Toggling it through the same action path, measured before the fix:
//
//     oracle (same circuit built fixed-size)  bounds (80,290) 220x40  ends [(80,300),(300,300)]
//     before the toggle                       bounds (230,290) 70x40  ends [(230,300),(300,300)]
//     after  the toggle                       bounds (80,290) 220x40  ends [(230,300),(300,300)]
//                                                     ^ correct              ^ NOT recomputed
//
// The box moved and the ports did not, because `offsetBounds` reads the attribute live while the
// port layout is cached. The west port ended up 150px inside the box it is supposed to sit on
// the edge of; nothing can be wired to where it is drawn, and `CircuitPoints` sees the end at
// the stale location.
//
// So `fixedSizeToggleMovesThePorts` is the discriminating test, and `renameMovesThePorts` is
// kept beside it as a labelled non-discriminator: it guards the listener path that makes the
// rename work, and it is documented here as passing both before and after so nobody later reads
// it as evidence the seam is installed.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Appearance recompute seam", .serialized)
struct AppearanceRecomputeSeamTests {

  // MARK: - Fixtures

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  /// A child circuit with one west input and one east output, so the box's width is observable
  /// in a port location: the east port sits at `origin.x + width`, the west port at `origin.x`.
  /// A west-only circuit would hide the whole defect, because its single port does not move when
  /// the box widens.
  @MainActor
  private func child(
    named name: String, fixedSize: Bool, in host: LogisimFileProjectHost
  ) throws -> Circuit {
    let circuit = try Circuit(name: name, file: host.file)
    try circuit.staticAttributes.setValue(
      CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
    try circuit.staticAttributes.setValue(
      CircuitAttributes.namedCircuitBoxFixedSize, fixedSize)
    try circuit.mutatorAdd(try pin(.input, labelled: "a", at: 100))
    try circuit.mutatorAdd(try pin(.output, labelled: "y", at: 300))
    host.file.addCircuit(circuit)
    return circuit
  }

  private enum PinKind { case input, output }

  @MainActor
  private func pin(_ kind: PinKind, labelled label: String, at x: Int) throws -> any Component {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, kind == .input ? Pin.input : Pin.output)
    try attrs.setValue(StdAttr.label, label)
    return try Pin.factory.createComponent(
      location: Location.create(x, 100, hasToSnap: true), attributes: attrs)
  }

  @MainActor
  private func place(_ inner: Circuit, in host: LogisimFileProjectHost) throws -> any Component {
    let parent = try #require(host.currentCircuitObject)
    let factory = inner.subcircuitFactory
    let placement = try factory.createComponent(
      location: Location.create(300, 300, hasToSnap: true),
      attributes: factory.createAttributeSet())
    let mutation = host.project.beginMutation(on: parent)
    mutation.add(placement)
    try host.project.doAction(mutation.toAction("place the subcircuit"))
    return placement
  }

  /// The same circuit built with the final attribute value from the start, so its layout is
  /// computed once and never has to be recomputed. This is the answer a correct recompute must
  /// reproduce; asserting on a hard-coded coordinate instead would only pin today's geometry.
  @MainActor
  private func oracleEnds(fixedSize: Bool, name: String) throws -> [Location] {
    let host = try makeHost()
    let placement = try place(
      try child(named: name, fixedSize: fixedSize, in: host), in: host)
    return placement.ends.map(\.location)
  }

  // MARK: - The seams exist

  @Test("both appearance seams are installed")
  @MainActor
  func seamsAreInstalled() throws {
    _ = try makeHost()
    // Necessary, nowhere near sufficient: a hook assigned to `{ _ in }` passes this and fails
    // every test below. Kept only so a REMOVED installation reports as "not installed" rather
    // than as a confusing geometry mismatch.
    #expect(CircuitTransaction.appearanceRecompute != nil)
    #expect(CircuitTransaction.appearanceHook != nil)
  }

  // MARK: - The discriminating test

  @Test("toggling namedCircuitBoxFixedSize moves the placement's ports")
  @MainActor
  func fixedSizeToggleMovesThePorts() throws {
    let host = try makeHost()
    let inner = try child(named: "aa", fixedSize: false, in: host)
    let placement = try place(inner, in: host)

    let loose = placement.ends.map(\.location)
    let expected = try oracleEnds(fixedSize: true, name: "aa")
    // The premise: the two layouts really do differ, so the assertion below can fail. Without
    // this, a change that made fixed and loose boxes identical would turn the whole test green
    // while measuring nothing.
    #expect(loose != expected, "fixed-size and loose layouts coincide; the test cannot discriminate")

    let mutation = host.project.beginMutation(on: inner)
    mutation.setForCircuit(CircuitAttributes.namedCircuitBoxFixedSize, true)
    try host.project.doAction(mutation.toAction("Fixed size"))

    #expect(
      placement.ends.map(\.location) == expected,
      """
      the placement's ports were not recomputed: ends are \(placement.ends.map(\.location)), \
      still the loose-box \(loose), where a fixed-size box puts them at \(expected). \
      CircuitTransaction.appearanceRecompute is not draining appearanceRecomputeRequests.
      """)
  }

  /// The same edit, seen the way a user sees it: the box is drawn at the fixed-size width, so a
  /// port left behind is a port floating inside the drawing rather than on its edge.
  @Test("the ports end up ON the box the placement draws")
  @MainActor
  func portsLandOnTheDrawnBox() throws {
    let host = try makeHost()
    let inner = try child(named: "aa", fixedSize: false, in: host)
    let placement = try place(inner, in: host)

    let mutation = host.project.beginMutation(on: inner)
    mutation.setForCircuit(CircuitAttributes.namedCircuitBoxFixedSize, true)
    try host.project.doAction(mutation.toAction("Fixed size"))

    let box = placement.bounds
    for end in placement.ends {
      let onVerticalEdge = end.location.x == box.x || end.location.x == box.x + box.width
      #expect(
        onVerticalEdge,
        """
        port at \(end.location) is not on either vertical edge of the drawn box \(box) — \
        it is \(min(abs(end.location.x - box.x), abs(end.location.x - box.x - box.width))) px \
        away from the nearest one.
        """)
    }
  }

  // MARK: - The non-discriminator, labelled as one

  /// **This passes with the seam removed.** See the file header. It is here to guard the
  /// `.setName` listener that makes it pass, not as evidence about the seam.
  @Test("renaming a circuit moves the placement's ports (already worked; guards the listener)")
  @MainActor
  func renameMovesThePorts() throws {
    let host = try makeHost()
    let inner = try child(named: "aa", fixedSize: false, in: host)
    let placement = try place(inner, in: host)

    let before = placement.ends.map(\.location)
    let expected = try oracleEnds(fixedSize: false, name: "a_very_long_circuit_name")
    #expect(before != expected, "the two names give the same box; the test cannot discriminate")

    let mutation = host.project.beginMutation(on: inner)
    mutation.setForCircuit(CircuitAttributes.nameAttribute, "a_very_long_circuit_name")
    try host.project.doAction(mutation.toAction("Rename"))

    #expect(placement.ends.map(\.location) == expected)
  }

  /// And the same statement about `appearanceHook`, made as a test rather than as a comment:
  /// adding a pin through a transaction updates the placement's ports through the incremental
  /// `.add` listener, so the hook has nothing left to repair on this path.
  @Test("a pin added through a transaction moves the ports without the hook")
  @MainActor
  func pinAddedThroughATransactionMovesThePorts() throws {
    let host = try makeHost()
    let inner = try child(named: "aa", fixedSize: false, in: host)
    let placement = try place(inner, in: host)
    let before = placement.ends.count

    let saved = CircuitTransaction.appearanceHook
    CircuitTransaction.appearanceHook = nil
    defer { CircuitTransaction.appearanceHook = saved }

    let mutation = host.project.beginMutation(on: inner)
    mutation.add(try pin(.input, labelled: "b", at: 100))
    try host.project.doAction(mutation.toAction("add a pin"))

    #expect(
      placement.ends.count == before + 1,
      """
      with appearanceHook CLEARED the new pin still reached the placement (\(before) → \
      \(placement.ends.count) ends). If this ever fails, the hook has become load-bearing and \
      the header's claim that it is redundant on the editor path is out of date.
      """)
  }
}
