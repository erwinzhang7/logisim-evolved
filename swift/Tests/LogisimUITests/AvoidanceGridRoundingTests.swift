// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE AVOIDANCE MAP MISSED TWO EDGES OF EVERY COMPONENT LEFT OF OR ABOVE THE ORIGIN.
//
// ── The defect ──────────────────────────────────────────────────────────────────────────────
//
// `AvoidanceMap.markComponent` rounds the component's bounds origin up to the first grid
// intersection inside it. Upstream does that with `x0 += 9 - (x0 + 9) % 10`
// (`AvoidanceMap.java:84-85`), which is a round-*up* only while `x0 + 9` is non-negative; `%`
// keeps the sign of the dividend in Java and in Swift alike, so at negative coordinates the
// correction is added with the wrong sign and the origin lands one grid step *past* the first
// intersection. The port transliterated it faithfully, including that half.
//
// Faithful and wrong are not in tension here, which is the whole reason this file exists. Upstream
// pens every component into the non-negative quadrant (D19 lists the five sites), so no component
// it can route has a negative bound and the two expressions agree character for character
// everywhere upstream can reach. D19 removed the wall, and made the unreachable half of
// upstream's arithmetic reachable.
//
// ── The before-state, measured ──────────────────────────────────────────────────────────────
//
// A default AND gate at (-100,-100) has bounds (-150,-125):50x50 and contains **30** grid
// points. **10** of them were absent from the avoidance map: the whole x = -150 column and the
// whole y = -120 row: both origins round the wrong way, and -125 rounds to -110 rather than
// -120. The same gate at (100,100) has bounds (50,75):50x50, 30 contained points, **0** missing.
//
// ── Why it is not cosmetic ──────────────────────────────────────────────────────────────────
//
// `Connector.findShortestPath` consults `avoid.permission(at:)` and nothing else: `.neither` sets
// `neighbours = 0`, and **nil sets it to 3 or 4**. An unmarked point is therefore not "unknown",
// it is "free in every direction". Measured through the real connector, with the fixture below:
// before the fix the reroute emitted `(-150,-280)-(-150,-130)`, `(-150,-130)-(-150,-80)`,
// `(-150,-80)-(-150,-40)`, a wire running straight down the obstacle's left edge through five
// points the gate contains, and `MoveResult` reported **zero** unsatisfied connections while
// doing it. After the fix the same drag routes around the obstacle and crosses nothing.
//
// ── What must not move ──────────────────────────────────────────────────────────────────────
//
// `floorRemainder` differs from `%` only for a negative dividend, so `gridCeiling(v)` is upstream's
// expression bit for bit for every `v >= -9`. `positiveDividendsMatchUpstreamExactly` asserts that
// against the Java expression written out inline, because `EditParityTests` byte-compares the wires
// this map produces against the 4.1.0 jar (`05-move-selection`, `09-move-reconnects-wire`) and
// those fixtures sit above the origin. Both still byte-match.
//
// ── A finding from red-probing this file ────────────────────────────────────────────────────
//
// The first draft asserted the coverage on an AND gate alone, and the "nothing extra is marked"
// half of that assertion could not be made to fail: breaking `markComponent`'s speculative-insert
// withdrawal outright (`if false, !component.contains(…)`) left it green. Every gate's `contains`
// **is** its bounding box, measured on AND, OR, NOT, NAND, NOR, XOR, and on Pin, Clock, Probe and
// Tunnel, so on any of them the withdrawal never fires and there is nothing for that half to
// watch. The transistor is in the fixture list for that reason and no other: it claims 9 of the 15
// grid points in its 40x20 bounds, and with it the withdrawal probe reddens.
//
// ── Threading ───────────────────────────────────────────────────────────────────────────────
//
// The map tests touch no shared state. The routing suite is `.serialized` and its drags are
// **committed**, not previewed, so `MoveGesture.forceRequest` blocks until the answer is in and
// there is nothing to poll for: the same contract `WireRoutesPastOriginTests` documents.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Coverage of the map itself

@Suite("Avoidance map grid coverage")
struct AvoidanceMapGridCoverageTests {

  /// Every grid intersection in the closed bounding box, and which of them the component claims.
  /// `markComponent` only ever visits grid-aligned points inside this box and withdraws the ones
  /// `contains` rejects, so this box *is* the universe the map can legally cover, which makes the
  /// comparison below exact in both directions rather than a one-sided "nothing is missing".
  private func gridPoints(of component: any Component) -> (all: [Location], contained: [Location]) {
    let box = component.bounds
    var all: [Location] = []
    var contained: [Location] = []
    var x = box.x
    while x <= box.x + box.width {
      if x % 10 == 0 {
        var y = box.y
        while y <= box.y + box.height {
          if y % 10 == 0 {
            let point = Location.create(x, y, hasToSnap: false)
            all.append(point)
            if component.contains(point) { contained.append(point) }
          }
          y += 1
        }
      }
      x += 1
    }
    return (all, contained)
  }

  private func component(_ shape: String, at location: Location) throws -> any Component {
    StdLibraries.registerAll()
    let factory: any ComponentFactory =
      shape == "AND gate" ? AndGate.factory : Transistor.factory
    return try factory.createComponent(
      location: location, attributes: factory.createAttributeSet())
  }

  /// **THE DEFECT**, its calibration, and the one shape that makes the second half of the
  /// comparison mean something.
  ///
  /// The AND gate is the audit's fixture. The transistor is here because every gate's `contains`
  /// **is** its bounding box, measured across AND/OR/NOT/NAND/NOR/XOR and Pin/Clock/Probe/Tunnel,
  /// all of them claim every grid point in their bounds, so on a gate alone the "nothing extra"
  /// direction below is unfalsifiable and the speculative-insert withdrawal in `markComponent`
  /// never fires. The transistor claims 9 of the 15 grid points in its 40x20 bounds, so it
  /// exercises both.
  @Test(
    "the map covers exactly the grid points a component contains",
    arguments: [
      (shape: "AND gate", x: -100, y: -100, gridPoints: 30, contains: 30),
      (shape: "AND gate", x: 100, y: 100, gridPoints: 30, contains: 30),
      (shape: "transistor", x: -100, y: -100, gridPoints: 15, contains: 9),
      (shape: "transistor", x: 100, y: 100, gridPoints: 15, contains: 9),
    ])
  func mapCoversTheContainedGridPoints(
    fixture: (shape: String, x: Int, y: Int, gridPoints: Int, contains: Int)
  ) throws {
    let origin = Location.create(fixture.x, fixture.y, hasToSnap: false)
    let component = try component(fixture.shape, at: origin)
    let box = component.bounds
    let (all, contained) = gridPoints(of: component)
    let map = AvoidanceMap.create([component], dx: 0, dy: 0)
    let marked = all.filter { map.permission(at: $0) != nil }

    #expect(
      (all.count, contained.count) == (fixture.gridPoints, fixture.contains),
      """
      the fixture changed: a default \(fixture.shape) at (\(fixture.x),\(fixture.y)) has bounds \
      (\(box.x),\(box.y)):\(box.width)x\(box.height), \(all.count) grid points in them and claims \
      \(contained.count) — expected \(fixture.gridPoints) and \(fixture.contains). Nothing below \
      means anything until this matches.
      """)

    let missing = contained.filter { map.permission(at: $0) == nil }
    #expect(
      missing.isEmpty,
      """
      \(missing.count) of the \(contained.count) grid points inside the \(fixture.shape) at \
      (\(fixture.x),\(fixture.y)) are absent from the avoidance map: \
      \(missing.map { "(\($0.x),\($0.y))" }.joined(separator: " ")).
      That is `markComponent`'s round-up applied to a negative dividend — the origin lands one \
      grid step past the first intersection, so the first column and the first row are never \
      visited. `Connector.findShortestPath` reads an absent point as free in every direction, so a \
      reroute will run a wire straight through the component.
      """)

    #expect(
      Set(marked) == Set(contained),
      """
      the map marks \(marked.count) points but the \(fixture.shape) claims \(contained.count). \
      Extra: \(Set(marked).subtracting(contained).map { "(\($0.x),\($0.y))" }.sorted()
        .joined(separator: " ")).
      A point the component does not contain must not become an obstacle: `markComponent` inserts \
      speculatively and withdraws on `contains`, and this is the assertion that watches the \
      withdrawal.
      """)

    #expect(
      map.permission(at: contained[0]) == .neither,
      "a point inside a component must forbid both orientations, not merely be present")
  }

  /// The guard on the parity gate. For any dividend upstream can reach, `gridCeiling` must be
  /// upstream's expression *exactly*, so the 4.1.0 byte-comparison in `EditParityTests` cannot
  /// move. The Java expression is written out here rather than referenced so that this test keeps
  /// meaning something after the production copy is gone.
  @Test("positive dividends match upstream's expression exactly")
  func positiveDividendsMatchUpstreamExactly() {
    for value in -400...400 {
      // `AvoidanceMap.java:84`, `x0 += 9 - (x0 + 9) % 10`.
      let upstream = value + 9 - (value + 9) % 10
      let ours = gridCeiling(value)

      // The smallest multiple of ten that is not less than `value`. This is the property the
      // expression is *for*, and it is what the negative side was getting wrong.
      #expect(
        ours % 10 == 0 && ours >= value && ours - value < 10,
        "gridCeiling(\(value)) = \(ours)")

      if value >= -9 || (value + 9) % 10 == 0 {
        #expect(
          ours == upstream,
          """
          gridCeiling(\(value)) = \(ours) but upstream's expression gives \(upstream). This \
          dividend is one upstream can reach, so the two must agree bit for bit or the 4.1.0 \
          byte-comparison in EditParityTests moves.
          """)
      } else {
        #expect(
          ours == upstream - 10,
          """
          gridCeiling(\(value)) = \(ours); upstream's expression gives \(upstream), which is one \
          grid step too far. The fix is exactly one step on this side and nothing on the other.
          """)
      }
    }
  }
}

// MARK: - The consequence, through the real connector

/// A stationary obstacle, plus a wired gate below it whose reroute wants to run straight up
/// through the obstacle's left edge column. One connection only, so `Connector.computeWires` takes
/// the `tries == 1` path and never shuffles; the route is reproducible.
@MainActor
private struct ObstacleRig {
  let circuit: Circuit
  let canvas: CircuitEditorCanvas
  let obstacle: any Component
  private let obstacleOrigin: Location

  init(obstacleAt obstacleOrigin: Location, moverAt moverOrigin: Location, tail: Int) throws {
    StdLibraries.registerAll()
    self.obstacleOrigin = obstacleOrigin
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    obstacle = try AndGate.factory.createComponent(
      location: obstacleOrigin, attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(obstacle)

    let mover = try AndGate.factory.createComponent(
      location: moverOrigin, attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(mover)

    // One wire, straight north out of the mover's output port. Its far end stays put, so the
    // reroute has to get from that end to wherever the port lands.
    try circuit.mutatorAdd(
      Wire.create(
        moverOrigin, Location.create(moverOrigin.x, moverOrigin.y - tail, hasToSnap: false)))

    let select = SelectTool()
    select.keepsConnectionsWhenMoving = true
    canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1, center: CGPoint(x: CGFloat(obstacleOrigin.x), y: CGFloat(obstacleOrigin.y)),
        viewSize: CGSize(width: 800, height: 600)))
  }

  /// The moving gate, found by elimination rather than by holding the original reference: the move
  /// replaces the component with a translated copy, so the object added above is gone by then.
  var mover: any Component {
    circuit.nonWires.first { $0.location != obstacleOrigin } ?? obstacle
  }

  /// A point inside the mover and not inside the obstacle: `mousePressed` branches on
  /// `Circuit.allContaining`, and grabbing a shared point would drag the wrong thing.
  private var grabPoint: Location {
    let box = mover.bounds
    let component = mover
    for dy in stride(from: 0, through: box.height, by: 1) {
      for dx in stride(from: 0, through: box.width, by: 1) {
        let point = Location.create(box.x + dx, box.y + dy, hasToSnap: false)
        if component.contains(point) && !obstacle.contains(point) { return point }
      }
    }
    return component.location
  }

  /// Press, drag, release. The release blocks on `forceRequest`, so the reroute is folded in by
  /// the time this returns.
  func commitDrag(by dx: Int, dy: Int) {
    let grab = grabPoint
    for phase in [CanvasPointerEvent.Phase.down, .dragged, .up] {
      let point =
        phase == .down ? grab : Location.create(grab.x + dx, grab.y + dy, hasToSnap: false)
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase, world: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
          modifiers: [], clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
    }
  }

  /// Points on some wire that the obstacle claims as its own interior. Anything here is a wire
  /// drawn through a component.
  var crossings: [Location] {
    let blocker = obstacle
    var seen: Set<Location> = []
    return circuit.wires
      .flatMap { wire in wire.filter { blocker.contains($0) } }
      .filter { seen.insert($0).inserted }
      .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
  }

  var wireReachesTheMover: Bool {
    let port = mover.location
    return circuit.wires.contains { $0.contains(port) }
  }

  var wireDescription: String {
    circuit.wires
      .map { "(\($0.end0.x),\($0.end0.y))-(\($0.end1.x),\($0.end1.y))" }
      .sorted()
      .joined(separator: " ")
  }
}

@Suite("Avoidance map grid coverage, through the router", .serialized)
@MainActor
struct AvoidanceMapRoutesAroundComponentsTests {

  /// **THE DEFECT, as a user meets it.** Obstacle at (-100,-100); a wired gate dragged from
  /// (-150,-180) to (-150,-20), i.e. from above the obstacle to below it, with the stationary wire
  /// end at (-150,-280). The only straight route is down x = -150, which is the obstacle's left
  /// edge; the column the rounding skipped.
  @Test("a reroute does not run a wire through a component left of the origin")
  func routesAroundAnObstacleAtNegativeCoordinates() throws {
    let rig = try ObstacleRig(
      obstacleAt: Location.create(-100, -100, hasToSnap: false),
      moverAt: Location.create(-150, -180, hasToSnap: false), tail: 100)
    rig.commitDrag(by: 0, dy: 160)

    let port = rig.mover.location
    #expect(
      port == Location.create(-150, -20, hasToSnap: false),
      "the gate is at \(port), so the router was never asked this fixture's question")
    #expect(
      rig.wireReachesTheMover,
      """
      nothing reached the port at all, so a clean obstacle check below would be vacuous: \
      \(rig.wireDescription)
      """)
    #expect(
      rig.crossings.isEmpty,
      """
      the reroute ran a wire through the obstacle at \(rig.obstacle.bounds), crossing \
      \(rig.crossings.map { "(\($0.x),\($0.y))" }.joined(separator: " ")).
      Wires are: \(rig.wireDescription).
      Those points are inside a component and the router still stepped on them, which means they \
      were absent from the avoidance map — `markComponent`'s round-up skipped the x = -150 column. \
      The connector reports this as a *successful* reroute with no unsatisfied connections.
      """)
  }

  /// The calibration, and it is not optional: the identical fixture translated by (300,300), which
  /// puts every coordinate above the origin. This passed before the fix and must still pass after
  /// it; if it ever fails, the fix has changed the quadrant `EditParityTests` measures.
  @Test("the same fixture above the origin routes around it too, as it always did")
  func routesAroundAnObstacleInThePositiveQuadrant() throws {
    let rig = try ObstacleRig(
      obstacleAt: Location.create(200, 200, hasToSnap: false),
      moverAt: Location.create(150, 120, hasToSnap: false), tail: 100)
    rig.commitDrag(by: 0, dy: 160)

    let port = rig.mover.location
    #expect(
      port == Location.create(150, 280, hasToSnap: false),
      "the gate is at \(port), so this calibration is not measuring the same move")
    #expect(
      rig.wireReachesTheMover, "the positive-quadrant reroute failed: \(rig.wireDescription)")
    #expect(
      rig.crossings.isEmpty,
      """
      an ordinary reroute above the origin started cutting through components: \
      \(rig.wireDescription)
      """)
  }
}
