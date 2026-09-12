// SearchNode.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.SearchNode),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimKernel

/// `com.cburch.logisim.tools.move.SearchNode`; one state of the A* that reroutes a wire.
///
/// The cost model, in full, because it is the whole reason the routed wires look the way they do:
///
///   * a grid step costs 10, or **9** if it merely extends the wire that was already there in the
///     connection's own direction: so the search prefers to lengthen an existing run over
///     starting a new one;
///   * turning costs 50, and the heuristic charges 50 up front when the destination is off-axis
///     and 100 when it is behind you, so a route that has to double back is discouraged before it
///     is ever expanded;
///   * crossing another wire costs 20.
///
/// The heuristic is admissible-ish rather than admissible, the 9-per-10 discount for extending a
/// wire makes it optimistic and the turn penalties make it pessimistic, which is fine, because
/// upstream is not looking for a provably shortest route, it is looking for a tidy one.
public final class SearchNode: @unchecked Sendable {

  private static let crossingPenalty = 20
  private static let turnPenalty = 50

  public let location: Location
  public let direction: Direction?
  public let connection: ConnectionData
  public let destination: Location
  /// `dist`: cost so far.
  public let distance: Int
  /// `heur`: `dist + getHeuristic()`, computed once at construction as upstream does.
  public let heuristicValue: Int
  /// `extendsWire`; true while the route is still running along the wire it started on.
  public let isExtendingWire: Bool
  public let previous: SearchNode?

  /// `SearchNode(ConnectionData, Location, Direction, Location)`: the public entry point.
  /// Note it seeds `extendsWire` from `srcDir != null`, so a connection with no attached wire
  /// starts out not extending anything.
  public convenience init(
    connection: ConnectionData, source: Location, sourceDirection: Direction?,
    destination: Location
  ) {
    self.init(
      location: source, direction: sourceDirection, connection: connection,
      destination: destination, distance: 0, isExtendingWire: sourceDirection != nil,
      previous: nil)
  }

  private init(
    location: Location, direction: Direction?, connection: ConnectionData,
    destination: Location, distance: Int, isExtendingWire: Bool, previous: SearchNode?
  ) {
    self.location = location
    self.direction = direction
    self.connection = connection
    self.destination = destination
    self.distance = distance
    self.isExtendingWire = isExtendingWire
    self.previous = previous
    self.heuristicValue = wrap32(
      distance
        &+ SearchNode.heuristic(
          location: location, destination: destination, direction: direction,
          isExtendingWire: isExtendingWire))
  }

  /// `getHeuristic()` (`SearchNode.java:96-136`).
  ///
  /// Two Java integer-arithmetic details are load-bearing and are reproduced rather than
  /// simplified. `dx / 10 * 9` truncates toward zero *before* multiplying, so it is not
  /// `dx * 0.9`; and in the `NORTH` branch upstream writes `Math.abs(dx) - dy / 10 * 9` with `dy`
  /// already known negative, which is an addition. Rewriting either as the "obvious" equivalent
  /// changes the routes the search returns.
  private static func heuristic(
    location: Location, destination: Location, direction: Direction?, isExtendingWire: Bool
  ) -> Int {
    let dx = wrap32(destination.x &- location.x)
    let dy = wrap32(destination.y &- location.y)
    var result = -1

    if isExtendingWire {
      switch direction {
      case .east: if dx > 0 { result = wrap32((dx / 10) &* 9 &+ javaAbs(dy)) }
      case .west: if dx < 0 { result = wrap32((javaNegate(dx) / 10) &* 9 &+ javaAbs(dy)) }
      case .south: if dy > 0 { result = wrap32(javaAbs(dx) &+ (dy / 10) &* 9) }
      case .north: if dy < 0 { result = wrap32(javaAbs(dx) &- (dy / 10) &* 9) }
      case nil: break
      }
    }
    if result < 0 {
      result = wrap32(javaAbs(dx) &+ javaAbs(dy))
    }

    var penalizeDoubleTurn = false
    switch direction {
    case .east: penalizeDoubleTurn = dx < 0
    case .west: penalizeDoubleTurn = dx > 0
    case .north: penalizeDoubleTurn = dy > 0
    case .south: penalizeDoubleTurn = dy < 0
    case nil:
      if dx != 0 || dy != 0 { result = wrap32(result &+ turnPenalty) }
    }

    if penalizeDoubleTurn {
      result = wrap32(result &+ 2 &* turnPenalty)
    } else if dx != 0 && dy != 0 {
      result = wrap32(result &+ turnPenalty)
    }
    return result
  }

  /// `isDestination()`.
  public var isDestination: Bool { destination == location }

  /// `isStart()`.
  public var isStart: Bool { previous == nil }

  /// `next(Direction, boolean)` (`SearchNode.java:168-179`).
  ///
  /// ── DELIBERATE DIVERGENCE (D19): THE ROUTER IS NOT PENNED IN EITHER ─────────────────────
  ///
  /// Upstream returns null for a step into negative coordinates:
  ///
  ///     if (nextLoc.getX() < 0 || nextLoc.getY() < 0) return null;
  ///
  /// This port had it, and the comment that used to sit here said what it cost; "a route never
  /// leaves the first quadrant even though the rest of the engine would happily go there". That
  /// became a user-visible defect the moment D19 let components be dragged above the origin:
  /// reported as "objects do drag anywhere, wires dont follow at same prev boundary". The
  /// component moved and the reroute failed, so every attached wire was left behind; the
  /// connector's own honest answer to "no route exists", which is what a penned-in search returns
  /// once the destination is outside the pen.
  ///
  /// **Removing it does not make the search unbounded, because it never bounded it.** The
  /// positive quadrant is itself infinite: `next` refuses nothing in +x or +y, so the space was
  /// always infinite and termination has always come from `Connector`'s two caps, 20,000
  /// expansions per search and a ten-second budget across the whole connection attempt. The
  /// clamp removed one quadrant of four from an already-unbounded plane.
  ///
  /// Route fidelity is untouched for anything upstream can produce. A node only ever *offers* a
  /// negative neighbour when it sits within one 10-unit step of an axis, so no circuit drawn
  /// clear of the origin can route differently, which is why the `editbridge` move scripts,
  /// which compare our wires against the jar's at coordinates of 150 and up, are unaffected.
  public func next(_ moveDirection: Direction, crossing: Bool) -> SearchNode? {
    var newDistance = distance
    let connectionDirection = connection.direction
    let nextLocation = location.translate(moveDirection, 10)
    let stillExtending = isExtendingWire && moveDirection == connectionDirection
    newDistance = wrap32(newDistance &+ (stillExtending ? 9 : 10))
    if crossing { newDistance = wrap32(newDistance &+ SearchNode.crossingPenalty) }
    if moveDirection != direction { newDistance = wrap32(newDistance &+ SearchNode.turnPenalty) }
    return SearchNode(
      location: nextLocation, direction: moveDirection, connection: connection,
      destination: destination, distance: newDistance, isExtendingWire: stillExtending,
      previous: self)
  }

  /// Java's `hashCode()` (`SearchNode.java:150-154`). Not an implementation detail: it is the
  /// tie-breaker in `compareTo`, so its exact numeric value selects between two equally-promising
  /// routes and therefore between two different sets of wires in the saved file.
  public var javaHashCode: Int {
    let directionHash = direction?.rawValue ?? 0
    let locationPart = wrap32(wrap32(JavaHashing.locationHashCode(location) &* 31) &+ directionHash)
    return wrap32(wrap32(locationPart &* 31) &+ JavaHashing.locationHashCode(destination))
  }

  /// `compareTo(SearchNode)` (`SearchNode.java:52-60`).
  ///
  /// Upstream returns `this.heur - o.heur`, falling back to `this.hashCode() - o.hashCode()`.
  /// Both are `int` subtractions and both can overflow, so both wrap here; the *sign* is what the
  /// priority queue reads, and a wrapped sign is what Java's queue would have read too.
  public static func javaCompare(_ lhs: SearchNode, _ rhs: SearchNode) -> Int {
    let byHeuristic = wrap32(lhs.heuristicValue &- rhs.heuristicValue)
    if byHeuristic != 0 { return byHeuristic }
    return wrap32(lhs.javaHashCode &- rhs.javaHashCode)
  }
}

extension SearchNode: Hashable {
  /// `equals(Object)` (`SearchNode.java:63-78`).
  ///
  /// Upstream's own comment marks the commented-out version as a null-pointer bug; the live
  /// version compares `loc`, `dir` (null-safe both ways) and `dest`, and deliberately ignores
  /// `dist`, `heur`, `extendsWire` and `prev`. That is what makes the `visited` set collapse two
  /// routes that arrive at the same place facing the same way, which is the whole point of the
  /// closed set.
  public static func == (lhs: SearchNode, rhs: SearchNode) -> Bool {
    lhs.location == rhs.location && lhs.direction == rhs.direction
      && lhs.destination == rhs.destination
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(location)
    hasher.combine(direction)
    hasher.combine(destination)
  }
}

extension SearchNode: CustomStringConvertible {
  /// `toString()`, preserved because it is the only readable trace of a failed route.
  public var description: String {
    "\(location)/\(direction.map(\.name) ?? "null")\(isExtendingWire ? "+" : "-")"
      + "/\(destination):\(distance)+\(wrap32(heuristicValue &- distance))"
  }
}
