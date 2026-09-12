// WireRerouteAsymmetryTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16), disassembled from
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar.
//
// DIAGNOSTIC SCAFFOLD, see the suite comment.

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Rig

/// A gate with exactly **one** wire attached, which is the shape the report describes and the only
/// shape the move engine routes deterministically: `Connector.computeWires` shuffles the connection
/// ordering for every attempt after the second, so a selection with three or more connections has
/// no single right answer to compare against (see `Connector.swift`'s header).
@MainActor
private struct RerouteRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas
  let select: SelectTool
  let gate: any Component
  let tail: Wire

  init(tailLength: Int = 100) throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    let component = try AndGate.factory.createComponent(
      location: Location.create(200, 200, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    gate = component

    // One wire, running east out of the gate's output, so there is exactly one connection.
    let output = component.location
    let wire = Wire.create(
      output, Location.create(output.x + tailLength, output.y, hasToSnap: false))
    try circuit.mutatorAdd(wire)
    tail = wire

    select = SelectTool()
    select.keepsConnectionsWhenMoving = true
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1.0, center: CGPoint(x: 300, y: 250),
        viewSize: CGSize(width: 800, height: 600)))
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  var grabPoint: Location {
    let box = gate.bounds
    for dy in stride(from: 0, through: box.height, by: 1) {
      for dx in stride(from: 0, through: box.width, by: 1) {
        let point = Location.create(box.x + dx, box.y + dy, hasToSnap: false)
        if gate.contains(point) { return point }
      }
    }
    return gate.location
  }

  /// A fresh gesture over the untouched circuit; the same object `SelectTool.commitMove` would
  /// build, so `forceRequest` here answers exactly what a release at that delta would write.
  func detachedGesture() -> MoveGesture {
    MoveGesture(listener: nil, circuit: circuit, selected: [gate])
  }
}

/// The geometry of one reroute, flattened to something printable and comparable.
private struct Route: Equatable {
  var adds: [String]
  var removes: [String]

  init(_ result: MoveResult) {
    adds = result.wiresToAdd.map(Route.describe).sorted()
    removes = result.replacements.removals.compactMap { $0 as? Wire }.map(Route.describe).sorted()
  }

  init(adds: [String], removes: [String]) {
    self.adds = adds.sorted()
    self.removes = removes.sorted()
  }

  static func describe(_ wire: Wire) -> String {
    let a = wire.end0
    let b = wire.end1
    let lo = (a.x, a.y) <= (b.x, b.y) ? a : b
    let hi = (a.x, a.y) <= (b.x, b.y) ? b : a
    return "(\(lo.x),\(lo.y))-(\(hi.x),\(hi.y))"
  }

  var text: String {
    "add[" + adds.joined(separator: " ") + "] del[" + removes.joined(separator: " ") + "]"
  }
}

// MARK: - The measurement

/// ═══════════════════════════════════════════════════════════════════════════════════════════
/// "THE WIRE SNAPPING DOESN'T MAKE SENSE … THAT RIGHT BEND WAS PREV LOCATION SO IT MAINTAINED
///  THAT DESPITE INCREASING HEIGHT. OTHER DIRECTION WORKS FINE, IF NEW BEND IS CLOSER THAN THE
///  LAST."
///
/// Two candidate causes, and they need different fixes, so the first job is to tell them apart:
///
///   (a) the **preview** is stale, `SelectTool.previewResult` holds the last computed reroute
///       when the connector has not answered for the current delta, and a held preview is by
///       construction the *previous* position's route; or
///   (b) the **committed** route is wrong, `Connector`'s cost function genuinely prefers the old
///       bend when the route has to grow.
///
/// `committedRouteIsAFunctionOfTheDeltaAlone` settles (b) on its own, and the two sweep tests
/// settle (a). See each for what it found.
/// ═══════════════════════════════════════════════════════════════════════════════════════════
@Suite("Wire reroute — asymmetry between extending and shortening", .serialized)
struct WireRerouteAsymmetryTests {

  /// The rig's own gate. Every claim in this suite rests on the drag being **deterministic**, and
  /// what buys that is having exactly one connection: `Connector.computeWires` runs one ordering
  /// attempt for one connection and two for two, neither shuffled, but eight or ten for three or
  /// more, six or eight of them shuffled: see `Connector.swift`'s header. Wire a second tail onto
  /// this gate and the tests below start comparing routes that have no single right answer.
  @Test("the rig presents the move engine exactly one connection")
  @MainActor
  func rigIsDeterministic() throws {
    let rig = try RerouteRig()
    let connections = rig.detachedGesture().connections()
    #expect(
      connections.count == 1,
      """
      the rig has \(connections.count) connections, not one, so `Connector` will shuffle its \
      ordering and no route below is reproducible.
        gate \(rig.gate.location) ends \(rig.gate.ends.map(\.location))
        tail \(Route.describe(rig.tail))
        connections at \(connections.map(\.location))
      """)
    #expect(connections.first?.location == rig.gate.location)
  }

  /// **The measurement that separates (a) from (b).**
  ///
  /// Every `MoveResult` is computed from `MoveGesture`'s immutable snapshot of the circuit taken
  /// at the start of the drag, keyed only by `(gesture, dx, dy)`; there is no carry-over between
  /// deltas anywhere in `Connector`. So if the committed route for a delta is the same whether it
  /// was reached by extending or by shortening, the engine is symmetric and the report is about
  /// the preview.
  @Test("DIAGNOSTIC: committed routes, swept out and back")
  @MainActor
  func committedSweep() throws {
    let rig = try RerouteRig()
    let gesture = rig.detachedGesture()

    var lines: [String] = []
    let outward = stride(from: 10, through: 80, by: 10).map { (0, $0) }
    let inward = stride(from: 70, through: 0, by: -10).map { (0, $0) }

    var first: [String: Route] = [:]
    var disagreements = 0
    for (dx, dy) in outward + inward {
      let route = Route(gesture.forceRequest(dx: dx, dy: dy))
      let key = "\(dx),\(dy)"
      if let seen = first[key] {
        if seen != route {
          disagreements += 1
          lines.append("(\(dx),\(dy))  DISAGREES  first=\(seen.text)  now=\(route.text)")
        } else {
          lines.append("(\(dx),\(dy))  same       \(route.text)")
        }
      } else {
        first[key] = route
        lines.append("(\(dx),\(dy))  \(route.text)")
      }
    }
    print("\n=== COMMITTED SWEEP (out then back) ===\n" + lines.joined(separator: "\n") + "\n")
    let report = lines.joined(separator: "\n")
    #expect(
      disagreements == 0,
      """
      the committed route for a delta depends on how the drag arrived at it
      \(report)
      """)
  }

  /// **The decisive one.** The same drag, out and then back, so the return leg asks for deltas the
  /// outbound leg already had computed. `MoveGesture` caches by `(gesture, dx, dy)`, so the return
  /// leg is a pure cache hit and the outbound leg is a pure cache miss, which is the asymmetry,
  /// stated in the only terms that survive: not "further versus closer", but "a delta this drag has
  /// already been to versus one it has not".
  @Test("DIAGNOSTIC: out-and-back, hit rate per leg")
  @MainActor
  func outAndBack() async throws {
    let rig = try RerouteRig()
    let grab = rig.grabPoint

    // The truth table is built **before** the drag starts, and never touched during it.
    // `forceRequest` enqueues with priority, which sets `ConnectorThread.overrideRequest` and
    // therefore *deletes* whatever the drag has pending: measuring the drag with a live oracle
    // measures the oracle. (First cut of this test did exactly that and reported 0/8 outbound for
    // the wrong reason.)
    let oracle = rig.detachedGesture()
    var truth: [Int: [String]] = [:]
    for dy in stride(from: 0, through: 80, by: 10) {
      truth[dy] = Route(oracle.forceRequest(dx: 0, dy: dy)).adds
    }

    rig.pointer(.down, grab.x, grab.y)

    func shownNow() -> [String] {
      rig.canvas.toolOverlay.items.compactMap {
        if case .proposedWire(let s, let e) = $0 { return Route.describe(Wire.create(s, e)) }
        return nil
      }.sorted()
    }

    func leg(_ deltas: [Int], _ label: String) async -> String {
      var lines: [String] = []
      var atEvent = 0
      var afterYield = 0
      for dy in deltas {
        try? await Task.sleep(nanoseconds: 12_000_000)
        rig.pointer(.dragged, grab.x, grab.y + dy)
        // Two samples, because they answer two different questions. The first is the frame the
        // event itself built. The second is the frame the user actually sees: `makeMoveListener`
        // republishes through a `Task { @MainActor }`, so the connector's answer cannot reach the
        // overlay until the main actor yields, which it always does between real mouse events and
        // never does inside this loop unless asked.
        let immediate = shownNow()
        try? await Task.sleep(nanoseconds: 4_000_000)
        let settled = shownNow()
        if immediate == truth[dy] { atEvent += 1 }
        if settled == truth[dy] { afterYield += 1 }
        lines.append(
          "  dy=\(dy)  atEvent=\(immediate == truth[dy] ? "yes" : "NO ")"
            + "  afterYield=\(settled == truth[dy] ? "yes" : "NO ")")
      }
      return "[\(label)] overlay matched the commit — at the event: \(atEvent)/\(deltas.count),"
        + " after a yield: \(afterYield)/\(deltas.count)\n" + lines.joined(separator: "\n")
    }

    let outward = await leg(Array(stride(from: 10, through: 80, by: 10)), "outbound, fresh deltas")
    let back = await leg(Array(stride(from: 70, through: 10, by: -10)), "return, visited deltas")
    rig.pointer(.up, grab.x, grab.y + 10)
    print("\n=== OUT AND BACK ===\n" + outward + "\n" + back + "\n")
  }

  /// **The freeze.** `previewResult` refreshes its held box *only* on a cache hit at the delta the
  /// pointer is currently at. A drag that outruns the connector never gets one, so the held route
  /// stays at whatever delta last produced a hit, for the whole drag, while the ghost marches
  /// on. That is "the bend stayed at the previous location", and it is not a one-frame lag.
  /// Deliberately **unpaced**. Every extra millisecond between events is another chance for the
  /// connector to answer the delta the pointer is standing on *before* the overlay is built, which
  /// would let even the old rule refresh its box and weaken the probe. A burst is also the case
  /// that matters: a real drag on a real circuit outruns the connector, and that is the drag the
  /// report is about.
  @Test("the preview keeps advancing during a drag that outruns the connector")
  @MainActor
  func heldPreviewAdvancesUnderABurst() async throws {
    /// One attempt. Returns nil when the connector answered too little of the burst for the run to
    /// mean anything, which is not hypothetical: `ConnectorThread` is a **process-wide singleton
    /// with one pending slot**, `.serialized` only orders a suite against *itself*, and the
    /// sibling `DragWirePreviewTests` drags concurrently. A starved rig measured a frozen preview
    /// for the honest reason that nothing new had been computed, and a frozen preview is the
    /// *correct* answer to that. Caught by this precondition on the first combined run, not
    /// guessed at.
    func attempt() async throws -> (shown: [String], ghost: [Int], answered: Int, report: String)? {
      let rig = try RerouteRig(tailLength: 400)
      let grab = rig.grabPoint
      rig.pointer(.down, grab.x, grab.y)
      rig.pointer(.dragged, grab.x, grab.y + 10)
      let deadline = Date(timeIntervalSinceNow: 5)
      while Date() < deadline, rig.select.moveGesture?.findResult(dx: 0, dy: 10) == nil {
        try? await Task.sleep(nanoseconds: 2_000_000)
        rig.pointer(.dragged, grab.x, grab.y + 10)
      }
      guard let gesture = rig.select.moveGesture else { return nil }

      var shown: [String] = []
      var ghost: [Int] = []
      let deltas = (2...26).map { 10 * $0 }
      // The precondition has to be "the connector published something **while the burst was
      // running**", and getting that wrong is what made two earlier versions of this test flake:
      //
      //   * counting after the burst counts answers that landed too late to reach any frame;
      //   * counting only before the last frame passes when the single answer was already there
      //     before the *first* frame too, in which case first and last legitimately match.
      //
      // So: count before the first frame and again before the last, and require growth.
      var answeredBeforeFirst = 0
      var answeredBeforeLast = 0
      for (index, dy) in deltas.enumerated() {
        if index == 0 || index == deltas.count - 1 {
          let count = deltas.filter { gesture.findResult(dx: 0, dy: $0) != nil }.count
          if index == 0 { answeredBeforeFirst = count } else { answeredBeforeLast = count }
        }
        rig.pointer(.dragged, grab.x, grab.y + dy)
        let overlay = rig.canvas.toolOverlay
        shown.append(
          overlay.items.compactMap {
            if case .proposedWire(let s, let e) = $0 { return Route.describe(Wire.create(s, e)) }
            return nil
          }.sorted().joined(separator: " "))
        for item in overlay.items {
          if case .selectionGhost(_, let gy) = item { ghost.append(gy) }
        }
      }
      rig.pointer(.up, grab.x, grab.y + 260)

      let report =
        "ghost took \(Set(ghost).count) distinct positions over \(ghost.count) frames\n"
        + "preview took \(Set(shown).count) distinct shapes over \(shown.count) frames\n"
        + "connector had answered \(answeredBeforeFirst) of the \(deltas.count) burst deltas "
        + "before the first frame and \(answeredBeforeLast) before the last\n"
        + "first preview: \(shown.first ?? "-")\nlast  preview: \(shown.last ?? "-")"
      guard answeredBeforeLast > answeredBeforeFirst, Set(ghost).count > 1 else { return nil }
      return (shown, ghost, answeredBeforeLast - answeredBeforeFirst, report)
    }

    var run: (shown: [String], ghost: [Int], answered: Int, report: String)?
    let giveUp = Date(timeIntervalSinceNow: 30)
    while run == nil, Date() < giveUp {
      run = try await attempt()
      if run == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    let measured = try #require(
      run,
      """
      rig: thirty seconds of attempts and the connector never published a new answer *while* a \
      burst was running. Something else is starving it — `ConnectorThread` is one thread with one \
      pending slot for the whole process — and with nothing new computed mid-burst, a preview \
      that did not advance is the correct answer, so nothing below would be diagnostic.
      """)
    print("\n=== BURST: does the preview advance? ===\n" + measured.report + "\n")

    #expect(
      measured.shown.first != measured.shown.last,
      """
      the preview showed the same wires on the first and last frame of the burst while the ghost \
      crossed \(Set(measured.ghost).count) positions and the connector published \
      \(measured.answered) new answer(s) in between — answers the preview could have shown and \
      did not. The held route is pinned at the delta that last produced an exact cache hit — \
      "that right bend was prev location so it maintained that despite increasing height".
      \(measured.report)
      """)
  }

  /// Does the bend stick across *committed* drags? A second drag reroutes from a circuit that
  /// already contains the first drag's Z, so if anything in the engine were sticky this is where
  /// it would compound: each round would strand the previous round's stub and the wire count would
  /// climb. It does not; the count stays at three and the free end tracks the gate exactly.
  @Test("successive committed drags neither strand nor accumulate wires")
  @MainActor
  func successiveCommits() throws {
    let rig = try RerouteRig()
    let grab = rig.grabPoint
    let port = rig.gate.location
    var lines: [String] = []
    var faults: [String] = []
    for round in 1...4 {
      rig.pointer(.down, grab.x, grab.y + (round - 1) * 20)
      rig.pointer(.dragged, grab.x, grab.y + round * 20)
      rig.pointer(.up, grab.x, grab.y + round * 20)
      let wires = rig.circuit.wires
      lines.append(
        "after drag \(round) (dy=+20): \(wires.map(Route.describe).sorted().joined(separator: " "))")
      if wires.count != 3 {
        faults.append("round \(round): \(wires.count) wires, expected 3")
      }
      let moved = port.translate(0, round * 20)
      if !wires.contains(where: { $0.end0 == moved || $0.end1 == moved }) {
        faults.append("round \(round): no wire reaches the port at \(moved)")
      }
    }
    print("\n=== SUCCESSIVE COMMITS ===\n" + lines.joined(separator: "\n") + "\n")
    #expect(
      faults.isEmpty,
      """
      \(faults.joined(separator: "\n"))
      \(lines.joined(separator: "\n"))
      """)
  }

  // MARK: - The gates

  /// **The gate for the reported defect, and it is race-free.**
  ///
  /// Set up a gesture whose cache holds answers for `dy = 10` and `dy = 50`, with `dy = 10` the
  /// one the tool last *read* on a hit, and then ask for the preview at `dy = 48`; a delta
  /// nothing has computed. The old rule returned `dy = 10`'s route, because the held box was only
  /// ever refreshed by a hit at the pointer's own delta; the answer for `dy = 50`, sitting in the
  /// same cache and four times closer, was unreachable. That is the freeze the report describes.
  ///
  /// No pointer event and no connector thread are involved in the assertion itself, so there is
  /// nothing here to lose a race with, which matters, because `ConnectorThread` is a process-wide
  /// singleton with one pending slot that any other suite can empty.
  @Test("the preview falls back to the nearest computed reroute, not the last one read")
  @MainActor
  func fallbackPrefersTheNearestComputedRoute() async throws {
    let rig = try RerouteRig()
    let grab = rig.grabPoint
    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, grab.x, grab.y + 10)

    let gesture = try #require(rig.select.moveGesture)
    // `forceRequest` jumps the queue and blocks, so both entries exist whatever else the process
    // is dragging.
    let near = Route(gesture.forceRequest(dx: 0, dy: 10))
    let far = Route(gesture.forceRequest(dx: 0, dy: 50))
    try #require(near != far, "rig: the two deltas produced the same route, so this proves nothing")

    // Read the preview at dy = 10 so the held box is populated from that delta, exactly as a real
    // drag that paused there would leave it.
    let seeded = try #require(rig.select.previewResultForTesting(dx: 0, dy: 10))
    try #require(Route(seeded) == near)

    let shown = try #require(
      rig.select.previewResultForTesting(dx: 0, dy: 48),
      "the preview blanked instead of falling back — that is the flicker, not a fix")
    #expect(
      Route(shown) == far,
      """
      the preview fell back to the route for dy=10 while the gesture had already computed dy=50, \
      which is four times nearer. The held picture can only advance when the pointer lands on a \
      delta the connector has already answered, so a drag that outruns it stays pinned at the \
      previous position's bend.
        pointer at dy=48
        shown : \(Route(shown).text)
        dy=10 : \(near.text)
        dy=50 : \(far.text)
      """)
    rig.pointer(.up, grab.x, grab.y + 10)
  }

  /// Equidistant answers must not swap, or the fix trades the freeze for a flicker of its own.
  ///
  /// This is not a corner case, it is the common one: the pointer snaps to the grid and so do the
  /// cached deltas, so a query at `dy = 50` with `40` and `60` computed is an exact tie, and every
  /// other frame of a steady drag is one. `Dictionary` iteration order is stable for an unmutated
  /// dictionary but not across insertions, and Swift seeds its hashing per process, so leaving
  /// the choice to iteration order would make the preview jump between two shapes as the cache
  /// grew, differently on each launch.
  @Test("equidistant cached reroutes resolve to the same one every time")
  @MainActor
  func nearestResultBreaksTiesDeterministically() throws {
    let rig = try RerouteRig()
    let gesture = rig.detachedGesture()
    let low = Route(gesture.forceRequest(dx: 0, dy: 40))
    let high = Route(gesture.forceRequest(dx: 0, dy: 60))
    try #require(low != high, "rig: the two deltas routed identically, so a tie proves nothing")

    let firstAnswer = Route(try #require(gesture.nearestResult(dx: 0, dy: 50)))
    #expect(
      firstAnswer == low,
      "the tie between dy=40 and dy=60 did not resolve to the lexicographically smaller delta")

    // Grow the cache, including with entries that are *further* away, and ask again. A choice
    // made by iteration order would be free to change here; a choice made by `(dx, dy)` cannot.
    for dy in [0, 10, 20, 30, 70, 80, 90] { _ = gesture.forceRequest(dx: 0, dy: dy) }
    for _ in 0..<8 {
      #expect(
        Route(try #require(gesture.nearestResult(dx: 0, dy: 50))) == firstAnswer,
        """
        the answer for dy=50 changed as the cache grew — the preview would flicker between two \
        equally near reroutes
        """)
    }
  }

  /// The clearing rules still mean what they said. The fallback now consults `MoveGesture`'s
  /// cache, which **nothing clears**, so if the held box stopped being the gate, a cleared
  /// preview would come straight back from the cache. `DragWirePreviewClearingTests` covers the
  /// three clear sites; this covers the one thing that changed underneath them.
  @Test("a cleared preview stays cleared even though the gesture's cache still has answers")
  @MainActor
  func clearingBeatsTheCache() async throws {
    let rig = try RerouteRig()
    let grab = rig.grabPoint
    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, grab.x, grab.y + 10)
    let gesture = try #require(rig.select.moveGesture)
    _ = gesture.forceRequest(dx: 0, dy: 10)
    _ = try #require(rig.select.previewResultForTesting(dx: 0, dy: 10))
    try #require(rig.select.isHoldingPreviewForTesting)

    rig.select.selectionChanged(rig.canvas.selection)

    try #require(
      gesture.nearestResult(dx: 0, dy: 48) != nil,
      "rig: the cache emptied, so this cannot tell a working gate from a lucky miss")
    #expect(
      rig.select.previewResultForTesting(dx: 0, dy: 48) == nil,
      """
      the selection changed mid-drag and the preview came back anyway, out of the gesture's cache. \
      The held box is what "nothing may be drawn" means; the cache is not cleared and cannot be.
      """)
    rig.pointer(.up, grab.x, grab.y + 10)
  }

  /// The committed route for a two-dimensional drag, swept over a grid, so a bend that refuses to
  /// track the pointer would show up as a repeated corner across rows or columns.
  @Test("DIAGNOSTIC: committed routes over a 2-D grid of deltas")
  @MainActor
  func committedGrid() throws {
    let rig = try RerouteRig()
    let gesture = rig.detachedGesture()
    let port = rig.gate.location
    var lines: [String] = []
    var stranded: [String] = []
    for dy in stride(from: -40, through: 40, by: 20) {
      for dx in stride(from: -40, through: 40, by: 20) where dx != 0 || dy != 0 {
        let result = gesture.forceRequest(dx: dx, dy: dy)
        let route = Route(result)
        lines.append("(\(dx),\(dy))  \(route.text)")
        // The invariant that says the bend tracked the pointer: whatever shape the route takes,
        // one of its endpoints must be the port's **new** location. A route that stopped at the
        // old one, the shape the report describes, fails here.
        let moved = port.translate(dx, dy)
        let reaches = result.wiresToAdd.contains { $0.end0 == moved || $0.end1 == moved }
        if !reaches { stranded.append("(\(dx),\(dy)) -> \(route.text)") }
      }
    }
    print("\n=== 2-D COMMITTED GRID ===\n" + lines.joined(separator: "\n") + "\n")
    #expect(
      stranded.isEmpty,
      """
      \(stranded.count) committed routes never reach the port's new location \
      — the reroute left the wire attached to where the component used to be:
      \(stranded.joined(separator: "\n"))
      """)
  }
}
