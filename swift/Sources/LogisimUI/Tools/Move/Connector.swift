// Connector.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.Connector),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ════ Determinism, and what M7's byte-exact gate can and cannot ask of this file ════════════
//
// This is the one part of the editing layer where "byte-match what Java produces for the same
// sequence" is **not achievable in principle**, and the reason is upstream, not the port. Four
// sources of nondeterminism feed the routes this file emits, in decreasing order of severity:
//
//   1. `Collections.shuffle(connects)` for every attempt after the first two
//      (`Connector.java:72`). A shared `java.util.Random`, unseeded. With three or more
//      connections upstream tries eight or ten orderings, six or eight of them random, and keeps
//      whichever produced the fewest unsatisfied connections. **Two runs of the same Java build,
//      on the same file, dragging the same component the same distance, can and do emit different
//      wires.** No port can match that; there is no single correct answer to match.
//   2. A ten-second wall-clock budget (`MAX_SECONDS`), checked between attempts and again per
//      connection. Under load Java abandons attempts it would otherwise have made.
//   3. `HashSet<Component>` iteration order, which is identity-hashed and therefore varies per
//      JVM run. It reaches `AvoidanceMap.markAll` and the order connections are discovered in.
//      See `AvoidanceMap.markAll` and `MoveGesture.computeConnections`.
//   4. `PriorityQueue` tie-breaking on `SearchNode.hashCode()`. This one *is* deterministic,
//      `Location` and `Direction` both hash on content, which is why `JavaPriorityQueue` exists
//      and reproduces OpenJDK's heap arithmetic exactly.
//
// What the port does about each:
//
//   * (1) is replaced by a **seeded** shuffle, deterministic in the delta and the attempt number.
//     The port is therefore reproducible against itself, which is what makes a regression test
//     possible at all; it is simply not reproducible against any particular Java run, and neither
//     is Java.
//   * (2) is kept, because removing the budget would let a pathological circuit hang the drag.
//   * (3) is replaced by circuit order throughout; see the two files named above.
//   * (4) is reproduced exactly.
//
// **Consequence for the gate.** A scripted edit sequence that drags a selection with **zero, one
// or two** external connections is fully deterministic here (`tries` is 0, 1 or 2, and neither of
// the first two attempts shuffles), so it can be gated byte-exactly. A sequence that drags a
// selection with **three or more** connections cannot be, against Java or against itself across
// versions. Those sequences should be gated on the *set* of connections satisfied and on the
// endpoints of the selection, not on the exact wires. Recording this here so the gate is written
// knowing it, rather than discovered to be flaky later.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.move.Connector`, the reroute itself.
enum Connector {

  static let maximumSeconds: TimeInterval = 10
  private static let maximumOrderingTries = 10
  private static let maximumSearchIterations = 20000

  /// `computeWires(MoveRequest)`.
  ///
  /// Tries several orderings of the connections and keeps the best: fewest unsatisfied
  /// connections first, shortest total route as the tie-break. The ordering matters because each
  /// route is marked into the avoidance map as it is committed, so an early route can box a later
  /// one out, which is exactly what upstream's `sortConnects` comment describes.
  ///
  /// Returns nil when the search was aborted by a higher-priority request, which the connector
  /// thread reads as "publish nothing".
  ///
  /// D13: `throws`. `ReplacementMap.add`/`remove`/`replace` reject a write to a frozen map,
  /// and `processPath` performs all three. No map this function builds is ever frozen, it
  /// creates its own and freezing happens only when a `CircuitMutation` takes ownership, so
  /// the error is unreachable in practice. It is still propagated rather than swallowed,
  /// because the alternative is a `try!` on the one path in this file that runs off the main
  /// thread, and D13 exists precisely to stop that becoming a process kill. `ConnectorThread`
  /// catches it, which is exactly what upstream's own `catch (Exception)` does.
  static func computeWires(_ request: MoveRequest) throws -> MoveResult? {
    let gesture = request.gesture
    let dx = request.dx
    let dy = request.dy
    var baseConnects = gesture.connections()
    let impossible = pruneImpossible(
      &baseConnects, avoid: gesture.fixedAvoidanceMap(), dx: dx, dy: dy)

    let selectionAvoid = AvoidanceMap.create(gesture.selected, dx: dx, dy: dy)
    var pathLocations: [ConnectionData: Set<Location>] = [:]
    var initialNodes: [ConnectionData: [SearchNode]] = [:]
    for connection in baseConnects {
      var locations: Set<Location> = []
      var nodes: [SearchNode] = []
      processConnection(
        connection, dx: dx, dy: dy, locations: &locations, nodes: &nodes,
        selectionAvoid: selectionAvoid)
      pathLocations[connection] = locations
      initialNodes[connection] = nodes
    }

    var bestResult: MoveResult?
    let tries: Int
    switch baseConnects.count {
    case 0: tries = 0
    case 1: tries = 1
    case 2: tries = 2
    case 3: tries = 8
    default: tries = maximumOrderingTries
    }
    let stopTime = Date(timeIntervalSinceNow: maximumSeconds)

    var tryNumber = 0
    while tryNumber < tries && stopTime.timeIntervalSinceNow > 0 {
      defer { tryNumber += 1 }
      if ConnectorThread.isOverrideRequested { return nil }

      var connects = baseConnects
      if tryNumber < 2 {
        sortConnects(&connects, dx: dx, dy: dy)
        if tryNumber == 1 { connects.reverse() }
      } else {
        // See this file's header: upstream shuffles with an unseeded shared `Random`. The port
        // seeds from the request so the same drag replays identically.
        var generator = SplitMix64(
          seed: seed(dx: dx, dy: dy, tryNumber: tryNumber, count: connects.count))
        connects.shuffle(using: &generator)
      }

      guard
        let candidate = try tryList(
          gesture: gesture, connects: connects, dx: dx, dy: dy,
          pathLocations: pathLocations, initialNodes: initialNodes, stopTime: stopTime)
      else {
        return nil
      }

      if bestResult == nil {
        bestResult = candidate
      } else if let best = bestResult {
        let unsatisfiedBest = best.unsatisfiedConnections.count
        let unsatisfiedCandidate = candidate.unsatisfiedConnections.count
        if unsatisfiedCandidate < unsatisfiedBest {
          bestResult = candidate
        } else if unsatisfiedCandidate == unsatisfiedBest,
          candidate.totalDistance < best.totalDistance
        {
          bestResult = candidate
        }
      }
    }

    if let best = bestResult {
      best.addUnsatisfiedConnections(impossible)
      return best
    }
    // Upstream's comment: "should only happen for no connections".
    return MoveResult(
      replacements: ReplacementMap(), unsatisfiedConnections: impossible, totalDistance: 0)
  }

  /// A stable seed for the ordering shuffle. Not a security or statistical concern; it only has
  /// to differ between attempts and be a function of the request.
  private static func seed(dx: Int, dy: Int, tryNumber: Int, count: Int) -> UInt64 {
    var value = UInt64(bitPattern: Int64(dx)) &* 0x9E37_79B9_7F4A_7C15
    value = (value ^ UInt64(bitPattern: Int64(dy))) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ UInt64(tryNumber)) &* 0x94D0_49BB_1331_11EB
    return value ^ UInt64(count)
  }

  /// `tryList(...)` (`Connector.java:314-351`).
  private static func tryList(
    gesture: MoveGesture,
    connects: [ConnectionData],
    dx: Int,
    dy: Int,
    pathLocations: [ConnectionData: Set<Location>],
    initialNodes: [ConnectionData: [SearchNode]],
    stopTime: Date
  ) throws -> MoveResult? {
    let avoid = gesture.fixedAvoidanceMap().cloneMap()
    avoid.markAll(gesture.selected, dx: dx, dy: dy)

    let replacements = ReplacementMap()
    var unconnected: [ConnectionData] = []
    var totalDistance = 0

    for connection in connects {
      if ConnectorThread.isOverrideRequested { return nil }
      if stopTime.timeIntervalSinceNow <= 0 {
        unconnected.append(connection)
        continue
      }
      let nodes = initialNodes[connection] ?? []
      let connectionPathLocations = pathLocations[connection] ?? []
      if let node = findShortestPath(nodes, pathLocations: connectionPathLocations, avoid: avoid) {
        totalDistance = wrap32(totalDistance &+ node.distance)
        let path = convertToPath(node)
        try processPath(
          path, connection: connection, avoid: avoid, replacements: replacements,
          unmarkable: connectionPathLocations)
      } else if ConnectorThread.isOverrideRequested {
        return nil
      } else {
        unconnected.append(connection)
      }
    }
    return MoveResult(
      replacements: replacements, unsatisfiedConnections: unconnected,
      totalDistance: totalDistance)
  }

  /// `findShortestPath(List<SearchNode>, Set<Location>, AvoidanceMap)` (`Connector.java:119-186`).
  ///
  /// A* with a closed set, capped at 20,000 expansions. The neighbour fan-out is where the
  /// avoidance map earns its name: a point marked `.neither` has no neighbours at all, and a point
  /// occupied by a wire offers only the two directions that cross it. `dir` is *reassigned* in the
  /// `nil` cases so that the `switch` on `i` below has an axis to work from; that reassignment is
  /// upstream's and it is load-bearing, not tidying.
  private static func findShortestPath(
    _ nodes: [SearchNode], pathLocations: Set<Location>, avoid: AvoidanceMap
  ) -> SearchNode? {
    var queue = JavaPriorityQueue(nodes, comparator: SearchNode.javaCompare)
    var visited: Set<SearchNode> = []
    var iterations = 0

    while !queue.isEmpty && iterations < maximumSearchIterations {
      iterations += 1
      guard let node = queue.removeFirst() else { return nil }
      if iterations % 64 == 0 && ConnectorThread.isOverrideRequested { return nil }
      if node.isDestination { return node }
      guard visited.insert(node).inserted else { continue }

      let location = node.location
      var direction = node.direction
      var neighbours = 3
      var allowed = avoid.permission(at: location)
      // The start point of a route is allowed to sit on the very wire it is replacing.
      if allowed != nil && node.isStart && pathLocations.contains(location) {
        allowed = nil
      }

      switch allowed {
      case .neither:
        neighbours = 0
      case .vertical:
        if direction == nil {
          direction = .north
          neighbours = 2
        } else if direction == .north || direction == .south {
          neighbours = 1
        } else {
          neighbours = 0
        }
      case .horizontal:
        if direction == nil {
          direction = .east
          neighbours = 2
        } else if direction == .east || direction == .west {
          neighbours = 1
        } else {
          neighbours = 0
        }
      case nil:
        if direction == nil {
          direction = .north
          neighbours = 4
        } else {
          neighbours = 3
        }
      }

      guard let axis = direction else { continue }
      for i in 0..<neighbours {
        let outDirection: Direction
        switch i {
        case 0: outDirection = axis
        case 1: outDirection = neighbours == 2 ? axis.reverse() : axis.getLeft()
        case 2: outDirection = axis.getRight()
        default: outDirection = axis.reverse()
        }
        if let next = node.next(outDirection, crossing: allowed != nil), !visited.contains(next) {
          queue.add(next)
        }
      }
    }
    return nil
  }

  /// `convertToPath(SearchNode)` (`Connector.java:100-117`).
  ///
  /// Walks the parent chain back to the start, keeping only the points where the route *turns*;
  /// those are the wire endpoints. The trailing `if` catches the case where the start itself was
  /// not a turn and would otherwise be dropped.
  private static func convertToPath(_ last: SearchNode) -> [Location] {
    var next = last
    var previous = last.previous
    var result: [Location] = [next.location]
    while let current = previous {
      if current.direction != next.direction {
        result.append(current.location)
      }
      next = current
      previous = current.previous
    }
    if result.last != next.location {
      result.append(next.location)
    }
    result.reverse()
    return result
  }

  /// `processConnection(...)` (`Connector.java:188-231`).
  ///
  /// Seeds the search. The connection's own point is a start node unless the moving selection
  /// will land on top of it; every point along the wire path leading in is also a start node, so
  /// the route may begin part-way down an existing wire and shorten it rather than replacing it.
  private static func processConnection(
    _ connection: ConnectionData,
    dx: Int,
    dy: Int,
    locations: inout Set<Location>,
    nodes: inout [SearchNode],
    selectionAvoid: AvoidanceMap
  ) {
    let current = connection.location
    let destination = current.translate(dx, dy)
    if selectionAvoid.permission(at: current) == nil {
      var preferred = connection.direction
      if preferred == nil {
        preferred =
          javaAbs(dx) > javaAbs(dy)
          ? (dx > 0 ? .east : .west)
          : (dy > 0 ? .south : .north)
      }
      locations.insert(current)
      nodes.append(
        SearchNode(
          connection: connection, source: current, sourceDirection: preferred,
          destination: destination))
    }

    for wire in connection.wirePath {
      for location in wire {
        guard selectionAvoid.permission(at: location) == nil || location == destination else {
          continue
        }
        guard locations.insert(location).inserted else { continue }
        var direction: Direction?
        if wire.endsAt(location) {
          if wire.isVertical {
            let y0 = location.y
            let y1 = wire.otherEnd(from: location).y
            direction = y0 < y1 ? .north : .south
          } else {
            let x0 = location.x
            let x1 = wire.otherEnd(from: location).x
            direction = x0 < x1 ? .west : .east
          }
        }
        nodes.append(
          SearchNode(
            connection: connection, source: location, sourceDirection: direction,
            destination: destination))
      }
    }
  }

  /// `processPath(...)` (`Connector.java:233-269`).
  ///
  /// Turns a route into edits. The first half retires the part of the old wire path the route no
  /// longer follows, either removing a wire outright or replacing it with a shortened one, and
  /// the second half lays the new segments. Both halves also update the avoidance map, so the
  /// *next* connection in this attempt routes around what this one just committed.
  private static func processPath(
    _ path: [Location],
    connection: ConnectionData,
    avoid: AvoidanceMap,
    replacements: ReplacementMap,
    unmarkable: Set<Location>
  ) throws {
    var iterator = path.makeIterator()
    guard var loc0 = iterator.next() else { return }

    if loc0 != connection.location {
      var pathLocation = connection.wirePathStart
      var found = loc0 == pathLocation
      for wire in connection.wirePath {
        let nextLocation = wire.otherEnd(from: pathLocation)
        if found {
          // The existing wire is entirely past the point the new route joins, so it goes.
          try replacements.remove(wire)
          avoid.unmarkWire(wire, deletedEnd: nextLocation, unmarkable: unmarkable)
        } else if wire.contains(loc0) {
          // The route joins part-way along this wire; everything after it is removed and this
          // one is truncated.
          found = true
          if loc0 != nextLocation {
            avoid.unmarkWire(wire, deletedEnd: nextLocation, unmarkable: unmarkable)
            let shortened = Wire.create(pathLocation, loc0)
            try replacements.replace(wire, with: shortened)
            avoid.markWire(shortened, dx: 0, dy: 0)
          }
        }
        pathLocation = nextLocation
      }
    }

    while let loc1 = iterator.next() {
      let newWire = Wire.create(loc0, loc1)
      try replacements.add(newWire)
      avoid.markWire(newWire, dx: 0, dy: 0)
      loc0 = loc1
    }
  }

  /// `pruneImpossible(...)` (`Connector.java:271-296`).
  ///
  /// Drops connections whose destination is already occupied by something that is not part of any
  /// wire path we are allowed to rearrange. Mutates `connects` in place, as upstream's
  /// `it.remove()` does, and returns what it removed.
  private static func pruneImpossible(
    _ connects: inout [ConnectionData], avoid: AvoidanceMap, dx: Int, dy: Int
  ) -> [ConnectionData] {
    var pathWires: [Wire] = []
    for connection in connects {
      pathWires.append(contentsOf: connection.wirePath)
    }

    var impossible: [ConnectionData] = []
    var kept: [ConnectionData] = []
    for connection in connects {
      let destination = connection.location.translate(dx, dy)
      if avoid.permission(at: destination) != nil {
        let isInPath = pathWires.contains { $0.contains(destination) }
        if !isInPath {
          impossible.append(connection)
          continue
        }
      }
      kept.append(connection)
    }
    connects = kept
    return impossible
  }

  /// `sortConnects(List<ConnectionData>, int, int)` (`Connector.java:298-312`).
  ///
  /// Upstream's comment explains the intent: moving an east-facing gate southeast, connect the
  /// inputs top-down so the new wires do not fight each other; moving it northeast, bottom-up.
  ///
  /// **The comparator is not a valid ordering and that is preserved.** `abx * dx + aby * dy` is a
  /// projection onto the move direction, and projections are not transitive as comparators;
  /// three points can compare a < b, b < c, c < a. Java's `List.sort` is a TimSort that may throw
  /// `IllegalArgumentException: Comparison method violates its general contract!` on such input;
  /// it usually does not, for lists this short. Swift's `sort` does not validate and simply
  /// produces some order. So the port cannot crash where Java could, and the resulting order for
  /// a non-transitive input may differ: one more entry in this file's determinism ledger, and a
  /// far smaller one than the shuffle. It is left as-is rather than "fixed" into a total order,
  /// because a total order would change the routing for *every* drag, not just the pathological
  /// ones.
  private static func sortConnects(_ connects: inout [ConnectionData], dx: Int, dy: Int) {
    connects.sort { lhs, rhs in
      let a = lhs.location
      let b = rhs.location
      let abx = wrap32(a.x &- b.x)
      let aby = wrap32(a.y &- b.y)
      return wrap32(wrap32(abx &* dx) &+ wrap32(aby &* dy)) < 0
    }
  }
}

/// A tiny, fixed-behaviour PRNG for the ordering shuffle. SplitMix64, the same generator Java's
/// own `SplittableRandom` uses for its increment step, chosen because it is three lines and its
/// output is fully determined by the seed on every platform.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { self.state = seed }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
