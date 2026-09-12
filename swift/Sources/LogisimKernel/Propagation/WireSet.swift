//
//  WireSet.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (com.cburch.logisim.circuit.WireSet),
//  https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
//  developers. This translation is a derivative work and is therefore GPL-3.0-only.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16), read from `upstream-java-4.1.0/.../circuit/WireSet.java`,
//  NOT from main.
//

import Foundation

/// `com.cburch.logisim.circuit.WireSet`; an immutable set of wires plus the set of endpoints
/// they touch. Produced by `CircuitWires.getWireSet(_:)` and consumed by the canvas (highlighting)
/// and by the wire-editing tools.
///
/// **Membership is by endpoints, not identity.** Java stores `HashSet<Wire>` and `Wire` overrides
/// `equals`/`hashCode` structurally: `w.e0.equals(this.e0) && w.e1.equals(this.e1)`, hash
/// `e0.hashCode() * 31 + e1.hashCode()` (`Wire.java:160-162`, `:269-270`). So `containsWire` is
/// true for *any* wire drawn between the same two points, not only the identical object. That is
/// the one place in the wiring layer where D4's "identity everywhere" does not apply, and it is
/// reproduced here with an explicit endpoint key rather than by making the seam `Hashable`.
public final class WireSet {

  /// The endpoint pair that Java's `Wire.equals`/`hashCode` reduce a wire to.
  private struct EndpointKey: Hashable {
    let end0: Location
    let end1: Location
  }

  /// `WireSet.NULL_WIRES` / `WireSet.EMPTY` (`WireSet.java:18-19`).
  public static let empty = WireSet([])

  /// `WireSet.wires`. Strong: a `WireSet` is a short-lived snapshot handed to a tool or to the
  /// canvas, and it holds no edge that anything in the circuit points back along, so there is no
  /// cycle for D3 to break here.
  private let wires: [any WireSegmentComponent]

  private let wireKeys: Set<EndpointKey>

  /// `WireSet.points`.
  private let points: Set<Location>

  /// `WireSet(Set<Wire> wires)` (`WireSet.java:24-36`).
  public init(_ wires: [any WireSegmentComponent]) {
    if wires.isEmpty {
      self.wires = []
      self.wireKeys = []
      self.points = []
    } else {
      self.wires = wires
      var keys = Set<EndpointKey>()
      var pts = Set<Location>()
      for wire in wires {
        keys.insert(EndpointKey(end0: wire.wireEnd0, end1: wire.wireEnd1))
        pts.insert(wire.wireEnd0)
        pts.insert(wire.wireEnd1)
      }
      self.wireKeys = keys
      self.points = pts
    }
  }

  /// `boolean containsLocation(Location loc)` (`WireSet.java:38-40`).
  public func containsLocation(_ loc: Location) -> Bool {
    points.contains(loc)
  }

  /// `boolean containsWire(Wire w)` (`WireSet.java:42-44`).
  public func containsWire(_ wire: any WireSegmentComponent) -> Bool {
    wireKeys.contains(EndpointKey(end0: wire.wireEnd0, end1: wire.wireEnd1))
  }

  /// The members, for callers that need to iterate. Java exposes no accessor because every 4.1.0
  /// caller only tests membership; this is additive and behaviour-neutral.
  public var members: [any WireSegmentComponent] { wires }

  /// `true` when this is the `EMPTY` instance's shape.
  public var isEmpty: Bool { wires.isEmpty }
}
