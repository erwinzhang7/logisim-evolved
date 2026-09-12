// Wire.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.{Wire, WireIterator, WireFactory}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── Structural equality, and how that squares with D4 ───────────────────────────────────────
//
// D4 forbids *synthesised* value equality on components, because the simulator keys dirty lists
// on reference identity. `Wire` is the one deliberate exception upstream makes, and it makes it
// explicitly: `Wire.equals` compares endpoints and `Wire.hashCode` is `e0.hashCode() * 31 +
// e1.hashCode()`. The wire set is a `HashSet<Wire>` and `CircuitWires.addWire` *relies* on
// structural dedup; adding the same segment twice must be a no-op, or a file with a duplicated
// `<wire>` element would round-trip with an extra wire.
//
// So `==`/`hash(into:)` here are hand-written and documented, never synthesised, and `Wire`
// remains a `final class` so nothing else about it is copied by value.
//
// ── Dropped: the interning `Cache` ──────────────────────────────────────────────────────────
//
// `Wire.create` routes through `com.cburch.logisim.util.Cache`, a fixed-size (256-slot) lossy
// table. Because it is lossy, it does **not** canonicalise, two equal wires can be distinct
// objects whenever a slot has been evicted, so no upstream code can be relying on reference
// identity here, and every collection holding wires uses `equals`/`hashCode`. The cache is a pure
// allocation optimisation, and it is dropped for the same reason `Location`'s and `Bounds`'s were
// (D14): it buys nothing and imports allocation-order nondeterminism.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `draw`, `drawHandles`, `expose`, `contains(Location, Graphics)`, `getBounds(Graphics)`, the
//     four stroke-width constants, `HIGHLIGHTED_STROKE`, `DOT_MULTIPLY_FACTOR`, and the DRC
//     highlight colour: all drawing (D6/D9, M6). The DRC *flag* is kept because it is model
//     state that the design-rule checker sets; the `Color` that goes with it is not.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.Wire`.
///
/// Immutable, which is why upstream lets a wire be its own `AttributeSet`.
public final class Wire: Component, AttributeSet, Sequence {

  // MARK: Attribute vocabulary

  /// `Wire.VALUE_HORZ`.
  public static let valueHorizontal = AttributeOption(name: "horz")
  /// `Wire.VALUE_VERT`.
  public static let valueVertical = AttributeOption(name: "vert")

  /// `Wire.BUS_WIDTH_POS_NONE`.
  public static let busWidthPositionNone = AttributeOption(name: "none")
  /// `Wire.BUS_WIDTH_POS_START`.
  public static let busWidthPositionStart = AttributeOption(name: "start")
  /// `Wire.BUS_WIDTH_POS_CENTER`.
  public static let busWidthPositionCenter = AttributeOption(name: "center")
  /// `Wire.BUS_WIDTH_POS_END`.
  public static let busWidthPositionEnd = AttributeOption(name: "end")

  /// `Wire.DIR_ATTR`.
  public static let directionAttribute: Attribute<AttributeOption> = Attributes.forOption(
    "direction", choices: [valueHorizontal, valueVertical])

  /// `Wire.LEN_ATTR`.
  public static let lengthAttribute: Attribute<Int32> = Attributes.forInteger("length")

  /// `Wire.BUS_WIDTH_POS_ATTR`.
  public static let busWidthPositionAttribute: Attribute<AttributeOption> = Attributes.forOption(
    "buswidthpos",
    choices: [
      busWidthPositionNone, busWidthPositionStart, busWidthPositionCenter, busWidthPositionEnd,
    ])

  /// `Wire.ATTRIBUTES`.
  public static let attributeList: [AnyAttribute] = [
    directionAttribute, lengthAttribute, busWidthPositionAttribute,
  ]

  // MARK: Stored state

  /// `Wire.e0`: the lesser endpoint after normalisation.
  public let end0: Location
  /// `Wire.e1`: the greater endpoint after normalisation.
  public let end1: Location
  /// `Wire.isXEqual`; true when the wire is vertical.
  public let isXEqual: Bool

  /// `Wire.isDrcHighlighted`. The companion `drcWireMarkColor` is a `java.awt.Color` and is a
  /// rendering concern (D9), so only the flag is model state here.
  public var isDrcHighlighted: Bool = false

  private init(_ e0: Location, _ e1: Location) {
    // Java normalises so that e0 <= e1 along the wire's axis. Note it decides `isXEqual` from the
    // *original* arguments before any swap, which is the same answer either way.
    self.isXEqual = (e0.x == e1.x)
    if isXEqual {
      if e0.y > e1.y {
        self.end0 = e1
        self.end1 = e0
      } else {
        self.end0 = e0
        self.end1 = e1
      }
    } else {
      if e0.x > e1.x {
        self.end0 = e1
        self.end1 = e0
      } else {
        self.end0 = e0
        self.end1 = e1
      }
    }
  }

  /// `Wire.create(Location, Location)`. See the file header for why the interning cache is gone.
  public static func create(_ e0: Location, _ e1: Location) -> Wire {
    Wire(e0, e1)
  }

  // MARK: - Component

  public var attributeSet: any AttributeSet { self }

  public var factory: any ComponentFactory { WireFactory.instance }

  /// `getLocation()` returns `e0`.
  public var location: Location { end0 }

  /// `getBounds()`.
  public var bounds: Bounds {
    let x0 = end0.x
    let y0 = end0.y
    return Bounds.create(
      wrap32(x0 &- 2),
      wrap32(y0 &- 2),
      wrap32(wrap32(end1.x &- x0) &+ 5),
      wrap32(wrap32(end1.y &- y0) &+ 5))
  }

  /// `getEnds()`; upstream returns a two-element `AbstractList` view over `getEnd(i)`.
  public var ends: [EndData] { [end(at: 0), end(at: 1)] }

  /// `getEnd(int)`. Note the width is always `UNKNOWN` and the type always `INPUT_OUTPUT`: a wire
  /// has no width of its own, it inherits one from the bundle it joins.
  public func end(at index: Int) -> EndData {
    EndData(
      location: endLocation(at: index), width: BitWidth.unknown, type: .inputOutput)
  }

  /// `getEndLocation(int)`: index 0 is `e0`, **anything else** is `e1`.
  public func endLocation(at index: Int) -> Location {
    index == 0 ? end0 : end1
  }

  /// `getEnd0()`.
  public var endpoint0: Location { end0 }
  /// `getEnd1()`.
  public var endpoint1: Location { end1 }

  /// `contains(Location)`: a 5-pixel-wide band along the wire's axis.
  public func contains(_ point: Location) -> Bool {
    let qx = point.x
    let qy = point.y
    if isXEqual {
      let wx = end0.x
      return qx >= wx - 2 && qx <= wx + 2 && end0.y <= qy && qy <= end1.y
    } else {
      let wy = end0.y
      return qy >= wy - 2 && qy <= wy + 2 && end0.x <= qx && qx <= end1.x
    }
  }

  /// `endsAt(Location)`.
  public func endsAt(_ point: Location) -> Bool {
    end0 == point || end1 == point
  }

  /// `getFeature(Object)`: a wire supplies its own custom handles and nothing else.
  public func feature(_ key: ComponentFeatureKey) -> Any? {
    key == .customHandles ? self : nil
  }

  // MARK: - Wire geometry

  /// `getLength()`. Java `int` arithmetic, so it wraps.
  public var length: Int {
    wrap32(wrap32(end1.y &- end0.y) &+ wrap32(end1.x &- end0.x))
  }

  /// `isVertical()`.
  public var isVertical: Bool { isXEqual }

  /// `isParallel(Wire)`.
  public func isParallel(to other: Wire) -> Bool {
    isXEqual == other.isXEqual
  }

  /// `getOtherEnd(Location)`. Bug-for-bug: anything that is not `e0`, including a point that is
  /// on neither end, yields `e0`.
  public func otherEnd(from loc: Location) -> Location {
    loc == end0 ? end1 : end0
  }

  /// `sharesEnd(Wire)`.
  public func sharesEnd(with other: Wire) -> Bool {
    end0 == other.end0 || end1 == other.end0 || end0 == other.end1 || end1 == other.end1
  }

  /// `overlaps(Wire, boolean)`.
  public func overlaps(_ other: Wire, includeEnds: Bool) -> Bool {
    overlaps(other.end0, other.end1, includeEnds: includeEnds)
  }

  /// The private `overlaps(Location, Location, boolean)`.
  ///
  /// Bug-for-bug: the test uses only *this* wire's orientation. Two perpendicular wires are
  /// compared as if the other were parallel, which is why the first guard (`x0 != q1.x`) is what
  /// actually rejects them.
  private func overlaps(_ q0: Location, _ q1: Location, includeEnds: Bool) -> Bool {
    if isXEqual {
      let x0 = q0.x
      if x0 != q1.x || x0 != end0.x { return false }
      return includeEnds
        ? (end1.y >= q0.y && end0.y <= q1.y)
        : (end1.y > q0.y && end0.y < q1.y)
    } else {
      let y0 = q0.y
      if y0 != q1.y || y0 != end0.y { return false }
      return includeEnds
        ? (end1.x >= q0.x && end0.x <= q1.x)
        : (end1.x > q0.x && end0.x < q1.x)
    }
  }

  // MARK: - Sequence (Java's `Iterable<Location>`)

  /// `iterator()`: every grid point along the wire, 10 units apart.
  public func makeIterator() -> WireIterator {
    WireIterator(end0, end1)
  }

  // MARK: - AttributeSet
  //
  // "It makes some sense for a wire to be its own attribute, since after all it is immutable."
  // ; upstream's comment. Reproduced: the whole set is read-only and nothing is ever saved.

  /// `clone()` returns `this`.
  public func copy() -> any AttributeSet { self }

  public var attributes: [AnyAttribute] { Wire.attributeList }

  public func containsAttribute(_ attribute: AnyAttribute) -> Bool {
    Wire.attributeList.contains { $0 === attribute }
  }

  public func attribute(named name: String) -> AnyAttribute? {
    Wire.attributeList.first { $0.name == name }
  }

  /// `getValue(Attribute<V>)`.
  ///
  /// Bug-for-bug: `BUS_WIDTH_POS_ATTR` is listed in `getAttributes()` but has no branch here, so
  /// reading it always yields null. Upstream stores the bus-width position on `CircuitWires`, not
  /// on the wire, and `Circuit.getWireBusWidthPos(Wire)` is the accessor that actually works.
  public func getValue<V>(_ attribute: Attribute<V>) -> V? {
    rawValue(attribute).flatMap(attribute.decode)
  }

  public func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Wire.directionAttribute {
      return .option(isXEqual ? Wire.valueVertical : Wire.valueHorizontal)
    }
    if attribute === Wire.lengthAttribute {
      return .integer(Int32(truncatingIfNeeded: length))
    }
    return nil
  }

  /// `setValue` throws `IllegalArgumentException("read only attribute")`.
  ///
  /// D13: reachable from a file (a `<wire>` carrying an `<a>` element), so it throws.
  public func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws {
    throw AttributeSetError.readOnly(name: attribute.name)
  }

  public func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    throw AttributeSetError.readOnly(name: attribute.name)
  }

  /// `isReadOnly`: always true, for any attribute at all.
  public func isReadOnly(_ attribute: AnyAttribute) -> Bool { true }

  /// `setReadOnly` throws `UnsupportedOperationException`.
  ///
  /// D13: this is one of the six API-misuse traps, no `.circ` file can reach it, only
  /// programmatic misuse, so it stays a trap.
  public func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    fatalError("Wire does not support read-only attributes")
  }

  /// `isToSave`; always false. Wires are written as `<wire from= to=>`, never as attributes.
  public func isToSave(_ attribute: AnyAttribute) -> Bool { false }

  public func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ value: V?
  ) -> [AnyAttribute]? { nil }

  /// A wire never issues attribute events, so there is nothing to subscribe to. Upstream inherits
  /// the interface's no-op `addAttributeListener`; here the token is dropped immediately, which
  /// has the same effect.
  @discardableResult
  public func addAttributeListener(_ listener: AttributeListener) -> AttributeSubscription {
    Wire.inertListenerRegistry.add(listener)
  }

  /// Backing store for the no-op subscription above. Nothing ever fires through it.
  private static let inertListenerRegistry = AttributeListenerRegistry()

  // MARK: - Equality
  //
  // Hand-written, never synthesised; see the file header for why `Wire` is the one component
  // with structural equality and what depends on it.

  public static func == (lhs: Wire, rhs: Wire) -> Bool {
    lhs.end0 == rhs.end0 && lhs.end1 == rhs.end1
  }

  /// Java: `e0.hashCode() * 31 + e1.hashCode()`.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(end0)
    hasher.combine(end1)
  }
}

extension Wire: Hashable {}

extension Wire: CustomStringConvertible {
  /// `toString()`.
  public var description: String { "Wire[\(end0)-\(end1)]" }
}

// MARK: - WireIterator

/// `com.cburch.logisim.circuit.WireIterator`: walks the grid points of a wire, 10 units apart.
///
/// Bug-for-bug: when the endpoints are not a multiple of 10 apart the constructor "corrects" the
/// destination with `destX = curX + deltaX * ((destX - curX) / 10)`, which for a negative delta
/// moves the destination the *wrong* way (`deltaX` is already signed, and so is the quotient), so
/// the loop overshoots and the iterator runs until integer wraparound brings it back. Upstream's
/// own comment is "should not happen, but in case it does...". Preserved verbatim; every wire the
/// editor creates is grid-aligned, so it does not happen in practice.
public struct WireIterator: IteratorProtocol {
  private var curX: Int
  private var curY: Int
  private let destX: Int
  private let destY: Int
  private let deltaX: Int
  private let deltaY: Int
  private var destReturned: Bool

  public init(_ e0: Location, _ e1: Location) {
    let startX = e0.x
    let startY = e0.y
    var targetX = e1.x
    var targetY = e1.y

    let stepX: Int
    let stepY: Int
    if startX < targetX { stepX = 10 } else if startX > targetX { stepX = -10 } else { stepX = 0 }
    if startY < targetY { stepY = 10 } else if startY > targetY { stepY = -10 } else { stepY = 0 }

    // Java: `(destX - curX) % 10`. Swift's `%` truncates toward zero exactly as Java's does.
    let offX = wrap32(targetX &- startX) % 10
    if offX != 0 {
      targetX = wrap32(startX &+ wrap32(stepX &* (wrap32(targetX &- startX) / 10)))
    }
    let offY = wrap32(targetY &- startY) % 10
    if offY != 0 {
      targetY = wrap32(startY &+ wrap32(stepY &* (wrap32(targetY &- startY) / 10)))
    }

    self.curX = startX
    self.curY = startY
    self.destX = targetX
    self.destY = targetY
    self.deltaX = stepX
    self.deltaY = stepY
    self.destReturned = false
  }

  public mutating func next() -> Location? {
    guard !destReturned else { return nil }
    let result = Location.create(curX, curY, hasToSnap: true)
    destReturned = destReturned || (curX == destX && curY == destY)
    curX = wrap32(curX &+ deltaX)
    curY = wrap32(curY &+ deltaY)
    return result
  }
}

// MARK: - WireFactory

/// `com.cburch.logisim.circuit.WireFactory`.
public final class WireFactory: AbstractComponentFactory {
  /// `WireFactory.instance`.
  public static let instance = WireFactory()

  /// Upstream's constructor is `private`, so the singleton is the only instance.
  private init() {
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  public override var name: String { "Wire" }

  /// `createAttributeSet()` returns a *wire*: the same self-describing trick `Wire` plays.
  public override func createAttributeSet() -> any AttributeSet {
    Wire.create(
      Location.create(0, 0, hasToSnap: true),
      Location.create(100, 0, hasToSnap: true))
  }

  /// `createComponent(Location, AttributeSet)`.
  ///
  /// D13: Java would throw `NullPointerException` on a set that carries neither attribute, which
  /// the tool layer catches; here that is a thrown `AttributeSetError.attributeAbsent`.
  ///
  /// Deviation in mechanism only: Java compares `dir == Wire.VALUE_HORZ` by reference, relying on
  /// `OptionAttribute.parse` returning one of the interned choices. `AttributeOption` is a Swift
  /// value type, so this compares by value, which is the same test, since the choices are
  /// distinguished by name and no two share one.
  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    guard let direction = attributes.getValue(Wire.directionAttribute) else {
      throw AttributeSetError.attributeAbsent(name: Wire.directionAttribute.name)
    }
    guard let length = attributes.getValue(Wire.lengthAttribute) else {
      throw AttributeSetError.attributeAbsent(name: Wire.lengthAttribute.name)
    }
    let distance = Int(length)
    return direction == Wire.valueHorizontal
      ? Wire.create(location, location.translate(distance, 0))
      : Wire.create(location, location.translate(0, distance))
  }

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Bug-for-bug: a set missing either attribute makes Java throw here too. Because this method
  /// is not `throws` upstream *or* in the protocol (it is called from paint paths that cannot
  /// recover), a missing attribute falls back to `Bounds.empty` rather than trapping; D13's rule
  /// is that a file-reachable failure must not kill the process, and an empty box is the least
  /// harmful answer a bounds query can give.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let direction = attributes.getValue(Wire.directionAttribute),
      let length = attributes.getValue(Wire.lengthAttribute)
    else {
      return Bounds.empty
    }
    let len = Int(length)
    return direction == Wire.valueHorizontal
      ? Bounds.create(0, -2, len, 5)
      : Bounds.create(-2, 0, 5, len)
  }
}
