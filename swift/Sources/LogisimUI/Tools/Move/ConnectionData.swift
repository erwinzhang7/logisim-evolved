// ConnectionData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.ConnectionData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.move.ConnectionData`; one point on the moving selection that has to
/// be reconnected to something that is staying put.
///
/// A reference type, not a struct, for the reason the Java code depends on: `Connector` keys two
/// dictionaries on it while `SearchNode` holds it, and the search compares nodes by their
/// *content*. Making it a class keeps the dictionary keying cheap and, more importantly, keeps
/// `SearchNode.conn` an aliasing reference so a truncated wire path is observed by every node
/// derived from the same connection.
///
/// **Equality is deliberately partial.** Upstream compares only `loc` and `dir`, ignoring
/// `wirePath` and `wirePathStart` (`ConnectionData.java:36-43`), and hashes the same two fields.
/// That is not an oversight: two connections at the same point approaching from the same direction
/// are the same connection for the search's purposes no matter which wires led there, and the
/// dictionaries in `Connector.computeWires` rely on it. Ported as written.
public final class ConnectionData: @unchecked Sendable {

  /// The point that must end up connected.
  public let location: Location

  /// The direction the existing wire arrives from, or nil when the connection is a bare component
  /// end with no wire attached.
  public let direction: Direction?

  /// "The list of wires leading up to this point - we may well want to truncate this path
  /// somewhat": upstream's own comment. Ordered from the far end inwards, i.e. reversed relative
  /// to how `MoveGesture.computeConnections` walks it.
  public let wirePath: [Wire]

  /// The far end of `wirePath`; equal to `location` when the path is empty.
  public let wirePathStart: Location

  public init(
    location: Location, direction: Direction?, wirePath: [Wire], wirePathStart: Location
  ) {
    self.location = location
    self.direction = direction
    self.wirePath = wirePath
    self.wirePathStart = wirePathStart
  }

  /// Java's `hashCode()`: `loc.hashCode() * 31 + (dir == null ? 0 : dir.hashCode())`.
  ///
  /// Reproduced exactly rather than synthesised, because `SearchNode.hashCode` is built on it and
  /// `SearchNode.compareTo` uses the hash as its tie-breaker, so the hash is not an implementation
  /// detail here, it is part of the search's ordering and therefore of the geometry that ends up
  /// in the file. `Location.hashCode()` is `31 * x + y` (`Location.java:25`) and
  /// `Direction.hashCode()` is its `id`, 0–3 (`Direction.java:72-74`); both are content-derived,
  /// so unlike most of upstream's hashing this really is deterministic across runs.
  public var javaHashCode: Int {
    wrap32(wrap32(JavaHashing.locationHashCode(location) &* 31) &+ (direction?.rawValue ?? 0))
  }
}

extension ConnectionData: Hashable {
  public static func == (lhs: ConnectionData, rhs: ConnectionData) -> Bool {
    lhs.location == rhs.location && lhs.direction == rhs.direction
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(location)
    hasher.combine(direction)
  }
}

/// The handful of Java hash codes this engine depends on numerically.
///
/// They are gathered here rather than added to `LogisimKernel` because they are not the kernel's
/// idea of hashing; `Location` is a Swift `struct` with a proper `Hashable` conformance, and D14
/// already records that the port dropped Java's interning. What is needed is the *numeric value*
/// Java's `hashCode()` produced, purely because upstream's A* tie-breaks on it.
/// `Math.abs(int)`, which, unlike Swift's `abs`, returns `Integer.MIN_VALUE` for
/// `Integer.MIN_VALUE` instead of trapping. Reachable only through a wrapped coordinate
/// difference, but D15's rule is that a Java `int` wraps where a Swift `Int` traps, and the whole
/// point of the rule is that the unreachable case is the one that takes the app down.
public func javaAbs(_ value: Int) -> Int {
  value < 0 ? wrap32(0 &- value) : value
}

/// Java's unary `-` on an `int`.
public func javaNegate(_ value: Int) -> Int {
  wrap32(0 &- value)
}

public enum JavaHashing {
  /// `Location.hashCode()`: the `31 * xRounded + yRounded` computed in `Location.create`
  /// (`Location.java:25`) and stored on the instance.
  public static func locationHashCode(_ location: Location) -> Int {
    wrap32(wrap32(31 &* location.x) &+ location.y)
  }
}
