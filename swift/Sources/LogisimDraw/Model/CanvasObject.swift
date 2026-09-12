// CanvasObject.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/model/{CanvasObject,Handle,HandleGesture,ReorderRequest}.java.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── Seam: no drawing here ───────────────────────────────────────────────────────────────────
//
// Java's `CanvasObject.paint(Graphics g, HandleGesture gesture)` is dropped entirely. A
// separate workflow owns `RenderScene` (D6) and this module must not invent a drawing API or
// import CoreGraphics. What is ported is everything the renderer will need to *decide what to
// draw*: geometry, bounds, hit-testing, handles, and the SVG codec. The render layer is
// expected to call `getBounds()`/`getHandles(_:)`/attribute accessors and emit its own typed
// primitives; it does not call anything named `paint` here because nothing here is named
// `paint`.
//
// ── ARC note (extends D3's reasoning to the draw model) ─────────────────────────────────────
//
// Java's `Handle` holds a strong `CanvasObject object`, and every shape that has handles
// (`Poly`, `Curve`, `Rectangular`) stores an array of `Handle`s that point straight back at
// `this`. Under GC that is an ordinary cycle; under ARC it is a permanent 2-node leak on every
// polygon, curve, and rectangle ever created. `Handle.object` is therefore `weak` here, exactly
// per D3's rule for edges that are not the one owning direction in a cycle: the shape owns its
// `handles` array; the array must not own the shape back.

import LogisimKernel

// MARK: - Handle

/// `com.cburch.draw.model.Handle`: one draggable control point belonging to a `CanvasObject`.
public final class Handle {
  // See the file header: weak to avoid a shape <-> handle-array retain cycle under ARC. Every
  // Handle in normal use is created with (and typically stored inside) its still-live owning
  // object, so the force-unwrap mirrors Java's non-null `getObject()` contract safely.
  private weak var weakObject: AnyObject?

  public var object: CanvasObject {
    guard let object = weakObject as? CanvasObject else {
      preconditionFailure("Handle.object accessed after its owning CanvasObject was deallocated")
    }
    return object
  }

  public let x: Int
  public let y: Int

  public init(_ object: CanvasObject, _ x: Int, _ y: Int) {
    self.weakObject = object
    self.x = x
    self.y = y
  }

  public convenience init(_ object: CanvasObject, _ location: Location) {
    self.init(object, location.x, location.y)
  }

  public var location: Location { Location.create(x, y, hasToSnap: false) }

  public func isAt(_ xq: Int, _ yq: Int) -> Bool { x == xq && y == yq }
  public func isAt(_ loc: Location) -> Bool { x == loc.x && y == loc.y }
}

extension Handle: Equatable, Hashable {
  public static func == (lhs: Handle, rhs: Handle) -> Bool {
    lhs.object === rhs.object && lhs.x == rhs.x && lhs.y == rhs.y
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(object))
    hasher.combine(x)
    hasher.combine(y)
  }
}

// MARK: - GestureModifiers

/// The subset of `java.awt.event.InputEvent` modifier masks `HandleGesture` actually reads
/// (`isShiftDown`/`isControlDown`/`isAltDown`). Input handling belongs to `draw/canvas` and
/// `draw/tools` (explicitly out of scope here: Swing, M6/M7), so this is the seam: whatever
/// eventually drives a drag gesture constructs this option set from its own key-event type
/// instead of an AWT `InputEvent` mask.
public struct GestureModifiers: OptionSet {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let shift = GestureModifiers(rawValue: 1 << 0)
  public static let control = GestureModifiers(rawValue: 1 << 1)
  public static let alt = GestureModifiers(rawValue: 1 << 2)
}

// MARK: - HandleGesture

/// `com.cburch.draw.model.HandleGesture`.
public final class HandleGesture {
  public let handle: Handle
  public let deltaX: Int
  public let deltaY: Int
  public let modifiers: GestureModifiers
  public private(set) var resultingHandle: Handle?

  public init(handle: Handle, deltaX: Int, deltaY: Int, modifiers: GestureModifiers = []) {
    self.handle = handle
    self.deltaX = deltaX
    self.deltaY = deltaY
    self.modifiers = modifiers
  }

  public func setResultingHandle(_ value: Handle?) { resultingHandle = value }

  public var isShiftDown: Bool { modifiers.contains(.shift) }
  public var isControlDown: Bool { modifiers.contains(.control) }
  public var isAltDown: Bool { modifiers.contains(.alt) }
}

extension HandleGesture: CustomStringConvertible {
  public var description: String {
    "HandleGesture() [\(deltaX), \(deltaY) : \(ObjectIdentifier(handle.object))/\(handle.x), \(handle.y)]"
  }
}

// MARK: - ReorderRequest

/// `com.cburch.draw.model.ReorderRequest`.
public struct ReorderRequest {
  public let object: CanvasObject
  public let fromIndex: Int
  public let toIndex: Int

  public init(object: CanvasObject, fromIndex: Int, toIndex: Int) {
    self.object = object
    self.fromIndex = fromIndex
    self.toIndex = toIndex
  }
}

extension ReorderRequest {
  /// Bug-for-bug: upstream declares four named comparators
  /// (`ASCENDING_FROM`/`DESCENDING_FROM`/`ASCENDING_TO`/`DESCENDING_TO`) but constructs every
  /// one of them as `new Compare(true, true)`: ascending-by-`fromIndex`, regardless of name.
  /// `DESCENDING_FROM`, `ASCENDING_TO`, and `DESCENDING_TO` are unreachable dead code upstream;
  /// nothing here "fixes" that, since a fidelity port does not silently correct behaviour no
  /// caller has ever actually observed.
  public static let ascendingFromComparator: (ReorderRequest, ReorderRequest) -> Bool = {
    $0.fromIndex < $1.fromIndex
  }
  public static let descendingFromComparator = ascendingFromComparator
  public static let ascendingToComparator = ascendingFromComparator
  public static let descendingToComparator = ascendingFromComparator
}

// MARK: - CanvasObject

/// `com.cburch.draw.model.CanvasObject`.
///
/// Class-bound (`AnyObject`) because `Handle` holds a weak reference to its owner and identity
/// is how `matches`/equality-adjacent comparisons key their fallback (Java relies on the
/// default `Object.equals`/`hashCode`, i.e. reference identity, since no shape overrides them).
public protocol CanvasObject: AnyObject {
  func canDeleteHandle(_ loc: Location) -> Handle?
  func canInsertHandle(_ desired: Location) -> Handle?
  func canMoveHandle(_ handle: Handle) -> Bool
  var canRemove: Bool { get }

  /// `Object.clone()` via `CanvasObject.clone()`. Returns a detached copy: fresh listener
  /// registry, and (per shape) freshly constructed handles that point at the new instance.
  func cloned() -> CanvasObject

  func contains(_ loc: Location, assumeFilled: Bool) -> Bool

  /// Returns the handle that should become "current" after deletion (Java's return value:
  /// the previous handle in sequence), or throws if the shape does not support deleting
  /// handles at all (`AbstractCanvasObject.deleteHandle` throws
  /// `UnsupportedOperationException`: reachable only by a programmer calling the wrong
  /// method on the wrong shape, never from a `.circ` file, so this traps rather than throws;
  /// see `CanvasObjectError`).
  func deleteHandle(_ handle: Handle) -> Handle?

  /// Java's `getAttributeSet()`. For every shape here that is `self`: `AbstractCanvasObject`
  /// implements `AttributeSet` directly rather than delegating to a separate object.
  var attributeSet: any AttributeSet { get }

  var bounds: Bounds { get }

  var displayName: String { get }

  var displayNameAndLabel: String { get }

  func handles(_ gesture: HandleGesture?) -> [Handle]

  func getValue<V>(_ attribute: Attribute<V>) -> V?

  func insertHandle(_ desired: Handle, after previous: Handle?) throws

  /// Structural (not identity) equality used by `MatchingSet`: e.g. diffing an appearance's
  /// shape list where two `Rectangle`s at the same place with the same paint should count as
  /// "the same shape" even though they are different objects.
  func matches(_ other: CanvasObject) -> Bool
  func matchesHashCode() -> Int

  func moveHandle(_ gesture: HandleGesture) -> Handle?

  func overlaps(_ other: CanvasObject) -> Bool

  func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws

  func translate(_ dx: Int, _ dy: Int)
}

/// Java's `UnsupportedOperationException` thrown by the default `deleteHandle`/`insertHandle`/
/// `moveHandle` bodies in `AbstractCanvasObject` for shapes that do not support handle editing
/// at all. None of these are reachable from a `.circ` file (a caller has to explicitly invoke
/// the wrong operation on a shape kind that does not support it), so, per the D13 rule that
/// only file-reachable failures become `throw`, these trap.
public enum CanvasObjectMisuse: Error, CustomStringConvertible {
  case deleteHandleUnsupported
  case insertHandleUnsupported
  case moveHandleUnsupported

  public var description: String {
    switch self {
    case .deleteHandleUnsupported: return "deleteHandle"
    case .insertHandleUnsupported: return "insertHandle"
    case .moveHandleUnsupported: return "moveHandle"
    }
  }
}
