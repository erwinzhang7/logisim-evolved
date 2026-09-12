// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE WIRE ROUTER IS NOT PENNED IN AT THE ORIGIN EITHER.
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// The second half of D19, reported as soon as the first half shipped: "objects do drag anywhere,
// wires dont follow at same prev boundary."
//
// `SearchNode.next` had upstream's `if (nextLoc.getX() < 0 || nextLoc.getY() < 0) return null`,
// and the port's own comment on it already said what it cost; "a route never leaves the first
// quadrant even though the rest of the engine would happily go there". Harmless while nothing
// could be dragged there. The moment D19 removed the drag clamp it became live: the component
// moves, the destination is outside the pen, `findShortestPath` exhausts and returns nil, and the
// connector's honest answer to "no route exists" is an empty replacement map, so every attached
// wire stays exactly where it was. Which is what the report describes, at exactly the boundary
// the report names.
//
// ── Why removing it does not make the search unbounded ──────────────────────────────────────
//
// Because it never bounded it. `next` refuses nothing in +x or +y, so the search space was
// already infinite and termination has always come from `Connector`'s two caps: 20,000
// expansions per search (`maximumSearchIterations`) and ten seconds across the whole attempt
// (`maximumSeconds`). The clamp removed one quadrant of four from an unbounded plane. This is an
// argument about which code terminates the loop, so it is checkable by reading that loop, and
// `Connector.findShortestPath`'s `while !queue.isEmpty && iterations < maximumSearchIterations`
// is where it is.
//
// ── Threading ───────────────────────────────────────────────────────────────────────────────
//
// `.serialized`, and the moves here are **committed** rather than previewed. A release goes
// through `MoveGesture.forceRequest`, which enqueues at priority and blocks until the answer
// arrives, so there is nothing to poll for and no window in which the sibling drag suites'
// traffic through the process-wide `ConnectorThread` can starve this one. That is the difference
// between this file and `WireRerouteAsymmetryTests`, which measures *previews* and needs a
// precondition for exactly that reason.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Rig

/// A gate with exactly one wire attached: the only shape the move engine routes
/// deterministically, because `Connector.computeWires` shuffles the connection ordering for every
/// attempt after the second.
@MainActor
private struct RoutingRig {
  let circuit: Circuit
  let canvas: CircuitEditorCanvas
  let gate: any Component

  init(gateAt origin: Location, tailLength: Int = 100) throws {
    StdLibraries.registerAll()
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    let component = try AndGate.factory.createComponent(
      location: origin, attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    gate = component

    // One wire, east out of the gate's output, so there is exactly one connection to satisfy.
    try circuit.mutatorAdd(
      Wire.create(
        origin, Location.create(origin.x + tailLength, origin.y, hasToSnap: false)))

    let select = SelectTool()
    select.keepsConnectionsWhenMoving = true
    canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1, center: CGPoint(x: 200, y: 200), viewSize: CGSize(width: 800, height: 600)))
  }

  /// A point the gate reports as inside itself: `mousePressed` branches on
  /// `Circuit.allContaining`, and a point it rejects starts a marquee instead of a move.
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

  /// Press, drag, release. The release blocks on `forceRequest`, so when this returns the
  /// reroute has been computed and folded into the circuit.
  func commitDrag(by dx: Int, dy: Int) {
    let grab = grabPoint
    for phase in [CanvasPointerEvent.Phase.down, .dragged, .up] {
      let point =
        phase == .down
        ? grab : Location.create(grab.x + dx, grab.y + dy, hasToSnap: false)
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase, world: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
          modifiers: [], clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
    }
  }

  /// Where the gate's output port is now.
  var outputPort: Location {
    (circuit.nonWires.first ?? gate).location
  }

  /// Is any wire actually touching that port? This is "did the wires follow", asked the way a
  /// user asks it, rather than by counting wires; a reroute that adds three segments and one
  /// that adds one are both correct, and neither is what the report is about.
  func wireReachesTheOutput() -> Bool {
    let port = outputPort
    return circuit.wires.contains { $0.contains(port) }
  }

  var wireDescription: String {
    circuit.wires
      .map { "(\($0.end0.x),\($0.end0.y))-(\($0.end1.x),\($0.end1.y))" }
      .sorted()
      .joined(separator: " ")
  }
}

// MARK: - Tests

@Suite("Wire routing past the origin", .serialized)
@MainActor
struct WireRoutesPastOriginTests {

  /// **THE DEFECT.** Drag a wired gate above and left of the origin; the wire has to come too.
  @Test("a wire follows its component above and left of the origin")
  func wiresFollowPastTheOrigin() throws {
    let rig = try RoutingRig(gateAt: Location.create(60, 60, hasToSnap: false))
    #expect(rig.wireReachesTheOutput(), "the rig starts disconnected; nothing below means anything")

    rig.commitDrag(by: -100, dy: -100)

    #expect(
      rig.outputPort.x < 0 && rig.outputPort.y < 0,
      """
      the gate did not actually cross the origin — it is at \(rig.outputPort), so the router was \
      never asked the question this test exists for.
      """)
    #expect(
      rig.wireReachesTheOutput(),
      """
      the gate moved to \(rig.outputPort) and no wire reaches it. Wires are: \
      \(rig.wireDescription). That is `SearchNode.next` refusing every step into negative \
      coordinates: the destination sits outside the pen, `findShortestPath` exhausts, and the \
      connector publishes an empty replacement map — so the wires stay where they were, which is \
      the reported "wires dont follow at same prev boundary".
      """)
  }

  /// The calibration, and it is not optional: the same rig, the same distance, entirely inside
  /// the positive quadrant. If this fails, the test above is measuring a broken rig rather than
  /// the clamp.
  @Test("the same move inside the positive quadrant reconnects, as it always did")
  func wiresStillFollowInsideTheQuadrant() throws {
    let rig = try RoutingRig(gateAt: Location.create(300, 300, hasToSnap: false))
    rig.commitDrag(by: -100, dy: -100)

    #expect(rig.outputPort.x > 0 && rig.outputPort.y > 0)
    #expect(
      rig.wireReachesTheOutput(),
      "an ordinary reroute away from the origin stopped working: \(rig.wireDescription)")
  }

  /// The router must be able to route *through* negative space, not merely end there; a gate
  /// dragged straight up past the axis is reconnected by a route whose corner has to sit above
  /// it. Asserted by placing the stationary end so that any connecting route must occupy a
  /// negative coordinate that is neither endpoint.
  @Test("a route may pass through negative space, not just terminate in it")
  func routesMayCrossTheAxis() throws {
    let rig = try RoutingRig(gateAt: Location.create(40, 40, hasToSnap: false))
    rig.commitDrag(by: -80, dy: -80)

    let port = rig.outputPort
    #expect(port.x < 0 && port.y < 0, "the gate is at \(port), not across the axis")
    #expect(
      rig.wireReachesTheOutput(),
      "no wire reaches \(port); wires are \(rig.wireDescription)")
    #expect(
      rig.circuit.wires.contains { $0.end0.x < 0 || $0.end0.y < 0 || $0.end1.x < 0 || $0.end1.y < 0
      },
      """
      no wire has an endpoint in negative space at all, yet the port is at \(port). Either the \
      reroute did not happen or this fixture does not need the negative quadrant — \
      \(rig.wireDescription)
      """)
  }
}
