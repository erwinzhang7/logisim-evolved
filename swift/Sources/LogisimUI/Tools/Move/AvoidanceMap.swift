// AvoidanceMap.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.AvoidanceMap),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// What a grid point permits a route to do. Upstream stores three interned `String` constants in
/// a `HashMap<Location, String>` and compares them with `==` as often as with `.equals`
/// (`Connector.java:143,145,154` use reference equality; `AvoidanceMap.java:73,106,114` use
/// `.equals`). Both work there only because the constants are compile-time string literals and so
/// are interned; an enum makes the intent explicit and the comparison total.
public enum AvoidancePermission: Hashable, Sendable {
  /// `Connector.ALLOW_NEITHER`; the point is inside something; no route may pass.
  case neither
  /// `Connector.ALLOW_VERTICAL`: occupied by a horizontal wire, so only a vertical crossing.
  case vertical
  /// `Connector.ALLOW_HORIZONTAL`: occupied by a vertical wire, so only a horizontal crossing.
  case horizontal
}

/// `com.cburch.logisim.tools.move.AvoidanceMap`; the grid of points a reroute must not run
/// through, and the ones it may only cross in one orientation.
///
/// `@unchecked Sendable`: built and consumed entirely on the connector thread, except for
/// `MoveGesture.fixedAvoidanceMap`, which is memoised under the gesture's lock. See
/// `ConnectorThread` for the threading contract.
public final class AvoidanceMap: @unchecked Sendable {

  private var map: [Location: AvoidancePermission]

  private init(_ map: [Location: AvoidancePermission]) {
    self.map = map
  }

  /// `create(Collection<Component>, int, int)`.
  public static func create(_ elements: [any Component], dx: Int, dy: Int) -> AvoidanceMap {
    let result = AvoidanceMap([:])
    result.markAll(elements, dx: dx, dy: dy)
    return result
  }

  /// `cloneMap()`.
  public func cloneMap() -> AvoidanceMap { AvoidanceMap(map) }

  /// `get(Location)`.
  public func permission(at location: Location) -> AvoidancePermission? { map[location] }

  /// `markAll(Collection<Component>, int, int)`.
  ///
  /// **Deliberate divergence, forced.** Upstream's callers pass `HashSet<Component>`
  /// (`MoveGesture.getSelected`, `getFixedAvoidanceMap`). `Component` does not override
  /// `hashCode`, so those sets iterate in *identity-hash* order; an order that differs between
  /// two runs of the same Java build on the same input. Order is observable here: a point covered
  /// by both a component and a wire ends up `neither` or `horizontal` depending on which was
  /// marked first (compare the `prev` handling in `markComponent` and `markWire`). So upstream's
  /// avoidance map is not reproducible even against itself, and there is nothing to be
  /// bug-for-bug faithful *to*. The port therefore takes an ordered `[Component]` and every caller
  /// supplies circuit order, which is deterministic. See `Connector`'s header for the full
  /// determinism analysis of this engine.
  public func markAll(_ elements: [any Component], dx: Int, dy: Int) {
    for element in elements {
      if let wire = element as? Wire {
        markWire(wire, dx: dx, dy: dy)
      } else {
        markComponent(element, dx: dx, dy: dy)
      }
    }
  }

  /// `markComponent(Component, int, int)`.
  ///
  /// The comment upstream leaves on the speculative insert is worth keeping, because the code
  /// reads backwards without it: the point is *probably* inside the component, so it is written
  /// as if it were and then withdrawn in the rare case it is not: one map write instead of a
  /// containment test per point.
  public func markComponent(_ component: any Component, dx: Int, dy: Int) {
    let translated = dx != 0 || dy != 0
    let bounds = component.bounds
    var x0 = wrap32(bounds.x &+ dx)
    var y0 = wrap32(bounds.y &+ dy)
    let x1 = wrap32(x0 &+ bounds.width)
    let y1 = wrap32(y0 &+ bounds.height)
    // Round the origin up to the first grid intersection inside the bounds. See `gridCeiling`:
    // this is *not* Java's expression transliterated, and the divergence is deliberate.
    x0 = gridCeiling(x0)
    y0 = gridCeiling(y0)

    var x = x0
    while x <= x1 {
      var y = y0
      while y <= y1 {
        let location = Location.create(x, y, hasToSnap: false)
        let previous = map.updateValue(.neither, forKey: location)
        if previous != .neither {
          let baseLocation = translated
            ? location.translate(javaNegate(dx), javaNegate(dy)) : location
          if !component.contains(baseLocation) {
            if let previous {
              map[location] = previous
            } else {
              map.removeValue(forKey: location)
            }
          }
        }
        y = wrap32(y &+ 10)
      }
      x = wrap32(x &+ 10)
    }
  }

  /// `markWire(Wire, int, int)`.
  ///
  /// A diagonal wire throws `RuntimeException("Diagonal wires are not supported.")` upstream. D13
  /// says a catchable Java exception becomes a Swift `throw`, but this one is not reachable from
  /// a `.circ` file or a gesture: `Wire.create` only ever produces axis-aligned wires (its
  /// `isXEqual` flag is computed from the endpoints and every construction site snaps first), so
  /// a diagonal wire is a broken invariant inside this process, not bad input. It stays an
  /// assertion, alongside the other API-misuse cases D13's audit left trapping. Making it throw
  /// would put a `try` on the connector thread's hot loop for a case no input can reach.
  public func markWire(_ wire: Wire, dx: Int, dy: Int) {
    let translated = dx != 0 || dy != 0
    var loc0 = wire.end0
    var loc1 = wire.end1
    if translated {
      loc0 = loc0.translate(dx, dy)
      loc1 = loc1.translate(dx, dy)
    }
    map[loc0] = .neither
    map[loc1] = .neither

    if loc0.x == loc1.x {
      // Vertical wire: a route may only cross it horizontally.
      for location in Wire.create(loc0, loc1) {
        let previous = map.updateValue(.horizontal, forKey: location)
        if previous == .neither || previous == .vertical {
          map[location] = .neither
        }
      }
    } else if loc0.y == loc1.y {
      for location in Wire.create(loc0, loc1) {
        let previous = map.updateValue(.vertical, forKey: location)
        if previous == .neither || previous == .horizontal {
          map[location] = .neither
        }
      }
    } else {
      assertionFailure("Diagonal wires are not supported.")
    }
  }

  /// `unmarkLocation(Location)`.
  public func unmarkLocation(_ location: Location) {
    map.removeValue(forKey: location)
  }

  /// `unmarkWire(Wire, Location, Set<Location>)`.
  ///
  /// **Two upstream bugs are preserved here on purpose, because they change the result.**
  ///
  /// 1. The guard inside both loops tests `unmarkable.contains(deletedEnd)`, the *end* passed in
  ///    , not `unmarkable.contains(loc)`, the point being unmarked
  ///    (`AvoidanceMap.java:149,159`). So the set either gates the whole wire or none of it. The
  ///    outer guard on line 139 already made that decision; re-testing it per point is a no-op
  ///    with the shape of a filter. Writing the filter the author evidently meant would unmark a
  ///    strictly smaller set of points and change which routes are legal afterwards.
  ///
  /// 2. The two branches are asymmetric. The vertical branch restores `.vertical` only when the
  ///    previous value was exactly `.horizontal`; the horizontal branch restores `.horizontal`
  ///    whenever the previous value was **anything except** `.vertical`: including nil, so it
  ///    can mark a point that was never marked (`AvoidanceMap.java:151-163`). Mirroring the two
  ///    branches would be the natural "fix" and would change the map.
  public func unmarkWire(_ wire: Wire, deletedEnd: Location, unmarkable: Set<Location>?) {
    let loc0 = wire.end0
    let loc1 = wire.end1
    let allowed = unmarkable == nil || unmarkable!.contains(deletedEnd)
    if allowed {
      map.removeValue(forKey: deletedEnd)
    }

    if loc0.x == loc1.x {
      for location in wire where allowed {
        let previous = map.removeValue(forKey: location)
        if previous == .horizontal {
          map[location] = .vertical
        }
      }
    } else if loc0.y == loc1.y {
      for location in wire where allowed {
        let previous = map.removeValue(forKey: location)
        if previous != .vertical {
          map[location] = .horizontal
        }
      }
    } else {
      assertionFailure("Diagonal wires are not supported.")
    }
  }
}

/// The grid intersection at or after `value`; the smallest multiple of ten that is not less than
/// it.
///
/// **Deliberate divergence.** Upstream writes the round-up inline, twice, as
/// `x0 += 9 - (x0 + 9) % 10` (`AvoidanceMap.java:84-85`). Swift's `%` and Java's `%` agree
/// exactly, both keep the sign of the *dividend*, so transliterating it is faithful; it is also
/// wrong, because that expression is only a round-**up** while `x0 + 9` is non-negative. At
/// `x0 = -150`, `(x0 + 9) % 10` is `-1`, the correction becomes `9 - (-1) = 10`, and the origin
/// lands on `-140`: one whole grid step *past* the first intersection inside the bounds. The
/// x = -150 column is then never visited and never marked, and `Connector.findShortestPath` reads
/// an unmarked point as free in every direction, so a reroute runs a wire straight through the
/// component, and `MoveResult` reports zero unsatisfied connections while doing it. Measured on a
/// default AND gate at (-100, -100): ten of the thirty grid points it contains were absent, the
/// whole x = -150 column and the whole y = -120 row (its bounds are (-150,-125):50x50, so both
/// origins round the wrong way).
///
/// Faithfulness is not at stake, for the reason D19 gives: upstream pens every component into the
/// non-negative quadrant (`SelectTool.computeDxDy`, `AddTool.performPlacement`,
/// `TextTool.createTextComponent`), so nothing upstream can route *has* a negative bound, and the
/// two expressions are character-for-character equivalent everywhere upstream can reach. This
/// port removed that wall, which is what made the unreachable half of upstream's arithmetic
/// reachable.
///
/// **The positive quadrant is untouched, by construction.** `floorRemainder` differs from `%` only
/// when the dividend is negative, so for every `value >= -9` this returns exactly what upstream's
/// expression returns, bit for bit. That matters because `EditParityTests` byte-compares the wires
/// this map produces against the 4.1.0 jar (`05-move-selection`, `09-move-reconnects-wire`), and
/// those fixtures live above the origin.
///
/// The `wrap32` calls are kept so the arithmetic still truncates to 32 bits exactly where Java's
/// `int` does, rather than quietly becoming 64-bit correct in a place nothing else is.
func gridCeiling(_ value: Int) -> Int {
  let shifted = wrap32(value &+ 9)
  return wrap32(shifted &- floorRemainder(shifted, 10))
}

/// `Math.floorMod(int, int)`; the remainder that keeps the sign of the *divisor*, as distinct
/// from `%`, which keeps the sign of the dividend. Written out rather than reached for via
/// `Int.quotientAndRemainder` so that the one line the rounding depends on is readable here.
func floorRemainder(_ dividend: Int, _ divisor: Int) -> Int {
  let remainder = dividend % divisor
  if remainder != 0 && (remainder < 0) != (divisor < 0) { return remainder &+ divisor }
  return remainder
}
