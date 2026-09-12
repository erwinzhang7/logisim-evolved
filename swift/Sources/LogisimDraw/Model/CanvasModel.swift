// CanvasModel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/model/{CanvasModel,CanvasModelEvent,CanvasModelListener,AttributeMapKey,
// Drawing,DrawingOverlaps}.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Java's `CanvasModel.paint(Graphics, Selection)` is dropped: `Selection` belongs to
// `draw/canvas` (Swing, explicitly out of scope; M6/M7) and painting belongs to `RenderScene`
// (D6), owned by a separate workflow. Everything else, the object list, the overlap index,
// and every mutating operation and its change event, is ported in full.

import LogisimKernel

// MARK: - AttributeMapKey

/// `com.cburch.draw.model.AttributeMapKey`. Keys a `(shape, attribute)` pair for the bulk
/// attribute-change operations. Equality/hash are by *identity* on both fields, matching Java
/// (neither `Attribute` nor `CanvasObject` overrides `equals`/`hashCode` upstream).
public struct AttributeMapKey: Hashable {
  public let attribute: AnyAttribute
  public let object: CanvasObject

  public init(attribute: AnyAttribute, object: CanvasObject) {
    self.attribute = attribute
    self.object = object
  }

  public static func == (lhs: AttributeMapKey, rhs: AttributeMapKey) -> Bool {
    lhs.attribute === rhs.attribute && lhs.object === rhs.object
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(lhs: attribute))
    hasher.combine(ObjectIdentifier(object))
  }
}

// A tiny helper so the line above reads the same shape for both fields; `AnyAttribute` is a
// class, so `ObjectIdentifier(_:)` already applies directly, but the named overload keeps the
// call sites symmetric and self-documenting.
extension ObjectIdentifier {
  fileprivate init(lhs attribute: AnyAttribute) { self.init(attribute) }
}

// MARK: - CanvasModelEvent

/// `com.cburch.draw.model.CanvasModelEvent.ACTION_*` constants, as a closed enum.
public enum CanvasModelAction: Int {
  case added = 0
  case removed = 1
  case translated = 2
  case reordered = 3
  case handleMoved = 4
  case handleInserted = 5
  case handleDeleted = 6
  case attributesChanged = 7
  case textChanged = 8
}

/// `com.cburch.draw.model.CanvasModelEvent`.
public final class CanvasModelEvent {
  public let source: CanvasModel
  public let action: CanvasModelAction
  private var storedAffected: [CanvasObject]?
  public private(set) var deltaX: Int = 0
  public private(set) var deltaY: Int = 0
  public private(set) var oldValues: [AttributeMapKey: AttributeValue?]?
  public private(set) var newValues: [AttributeMapKey: AttributeValue?]?
  public private(set) var reorderRequests: [ReorderRequest]?
  public private(set) var handle: Handle?
  public private(set) var gesture: HandleGesture?
  public private(set) var oldText: String?
  public private(set) var newText: String?

  private init(source: CanvasModel, action: CanvasModelAction, affected: [CanvasObject]) {
    self.source = source
    self.action = action
    self.storedAffected = affected
  }

  public static func forAdd(_ source: CanvasModel, _ affected: [CanvasObject]) -> CanvasModelEvent {
    CanvasModelEvent(source: source, action: .added, affected: affected)
  }

  public static func forRemove(_ source: CanvasModel, _ affected: [CanvasObject]) -> CanvasModelEvent {
    CanvasModelEvent(source: source, action: .removed, affected: affected)
  }

  public static func forTranslate(_ source: CanvasModel, _ affected: [CanvasObject]) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .translated, affected: affected)
    event.deltaX = 0
    event.deltaY = 0
    return event
  }

  public static func forReorder(
    _ source: CanvasModel, _ requests: [ReorderRequest]
  ) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .reordered, affected: requests.map(\.object))
    event.reorderRequests = requests
    return event
  }

  public static func forMoveHandle(
    _ source: CanvasModel, _ gesture: HandleGesture
  ) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .handleMoved, affected: [gesture.handle.object])
    event.handle = gesture.handle
    event.gesture = gesture
    return event
  }

  public static func forInsertHandle(_ source: CanvasModel, _ desired: Handle) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .handleInserted, affected: [desired.object])
    event.handle = desired
    return event
  }

  public static func forDeleteHandle(_ source: CanvasModel, _ handle: Handle) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .handleDeleted, affected: [handle.object])
    event.handle = handle
    return event
  }

  public static func forChangeAttributes(
    _ source: CanvasModel,
    oldValues: [AttributeMapKey: AttributeValue?],
    newValues: [AttributeMapKey: AttributeValue?]
  ) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .attributesChanged, affected: [])
    event.storedAffected = nil
    event.oldValues = oldValues
    event.newValues = newValues
    return event
  }

  public static func forChangeText(
    _ source: CanvasModel, _ object: CanvasObject, oldText: String, newText: String
  ) -> CanvasModelEvent {
    let event = CanvasModelEvent(source: source, action: .textChanged, affected: [object])
    event.oldText = oldText
    event.newText = newText
    return event
  }

  /// Lazily derived from `newValues`' keys when constructed via `forChangeAttributes`, exactly
  /// as Java's `getAffected()` recomputes from `newValues` the first time it is asked, if no
  /// affected collection was supplied directly.
  public var affected: [CanvasObject] {
    if let affected = storedAffected { return affected }
    guard let newValues else { return [] }
    var seen = Set<ObjectIdentifier>()
    var ordered: [CanvasObject] = []
    for key in newValues.keys where seen.insert(ObjectIdentifier(key.object)).inserted {
      ordered.append(key.object)
    }
    storedAffected = ordered
    return ordered
  }
}

// MARK: - CanvasModelListener

/// `com.cburch.draw.model.CanvasModelListener`.
public protocol CanvasModelListener: AnyObject {
  func modelChanged(_ event: CanvasModelEvent)
}

// MARK: - CanvasModel

/// `com.cburch.draw.model.CanvasModel`, minus `paint(Graphics, Selection)`, see the file
/// header.
public protocol CanvasModel: AnyObject {
  func addCanvasModelListener(_ listener: CanvasModelListener)
  func removeCanvasModelListener(_ listener: CanvasModelListener)

  /// `addObjects(int index, Collection<? extends CanvasObject> shapes)`.
  func addObjects(at index: Int, _ shapes: [CanvasObject])
  /// `addObjects(Map<? extends CanvasObject, Integer> shapes)`.
  func addObjects(_ shapes: [(object: CanvasObject, index: Int)])

  func removeObjects(_ shapes: [CanvasObject])

  func translateObjects(_ shapes: [CanvasObject], dx: Int, dy: Int)

  /// Throws `CanvasModelError.reorderTargetMismatch` where Java throws
  /// `IllegalArgumentException` (`Drawing.java:844`); reachable if a caller's reorder request
  /// no longer matches the model's current order.
  func reorderObjects(_ requests: [ReorderRequest]) throws

  func setAttributeValues(_ values: [AttributeMapKey: AttributeValue?]) throws

  func setText(_ text: DrawText, _ value: String)

  /// Throws where Java's `Poly.insertHandle` throws `IllegalArgumentException("no such
  /// handle")` when `previous` names a handle the shape does not actually have.
  func insertHandle(_ desired: Handle, after previous: Handle?) throws

  func deleteHandle(_ handle: Handle) -> Handle?

  func moveHandle(_ gesture: HandleGesture) -> Handle?

  var objectsFromBottom: [CanvasObject] { get }
  var objectsFromTop: [CanvasObject] { get }

  func objects(in bounds: Bounds) -> [CanvasObject]
  func objectsOverlapping(_ shape: CanvasObject) -> [CanvasObject]
}

/// Mirrors `Drawing.reorderObjects`'s `IllegalArgumentException`.
public enum CanvasModelError: Error, CustomStringConvertible {
  case reorderTargetMismatch(fromIndex: Int)
  case insertHandleTargetMissing

  public var description: String {
    switch self {
    case .reorderTargetMismatch(let index):
      return "object not present at indicated index: \(index)"
    case .insertHandleTargetMissing:
      return "no such handle"
    }
  }
}

// MARK: - DrawingOverlaps

/// `com.cburch.draw.model.DrawingOverlaps`: package-private in Java; internal here.
final class DrawingOverlaps {
  private var map: [ObjectIdentifier: [CanvasObject]] = [:]
  /// Java's `map` is keyed directly by `CanvasObject` (`Map<CanvasObject, List<CanvasObject>>`),
  /// so iterating `map.keySet()` yields shapes. `ObjectIdentifier` cannot recover the object it
  /// was made from, so this parallel dictionary mirrors `map`'s key set as actual shapes;
  /// always kept in lock-step with `map` (same inserts, same removals).
  private var mapKeys: [ObjectIdentifier: CanvasObject] = [:]
  private var untested: [ObjectIdentifier: CanvasObject] = [:]

  func addShape(_ shape: CanvasObject) {
    untested[ObjectIdentifier(shape)] = shape
  }

  private func addOverlap(_ a: CanvasObject, _ b: CanvasObject) {
    let key = ObjectIdentifier(a)
    var list = map[key] ?? []
    if !list.contains(where: { $0 === b }) {
      list.append(b)
      map[key] = list
    }
  }

  /// Mirrors `Drawing.Overlaps.ensureUpdated()` exactly, including the part that is easy to
  /// misread: each `o` is tested against `map.keySet()` *as it grows during this same call*:
  /// `map.put(o, over)` at the end of each iteration makes `o` visible to every subsequent `o`
  /// processed in this batch, not just to shapes from prior calls. There is no
  /// `ConcurrentModificationException` risk because the loop iterates `untested` (a separate
  /// collection) and mutates `map`, never the reverse.
  private func ensureUpdated() {
    guard !untested.isEmpty else { return }
    for (key, o) in untested {
      var over: [CanvasObject] = []
      for (_, o2) in mapKeys {
        if o !== o2 && o.overlaps(o2) {
          over.append(o2)
          addOverlap(o2, o)
        }
      }
      map[key] = over
      mapKeys[key] = o
    }
    untested.removeAll()
  }

  func getObjectsOverlapping(_ o: CanvasObject) -> [CanvasObject] {
    ensureUpdated()
    return map[ObjectIdentifier(o)] ?? []
  }

  func invalidateShape(_ shape: CanvasObject) {
    removeShape(shape)
    untested[ObjectIdentifier(shape)] = shape
  }

  func removeShape(_ shape: CanvasObject) {
    let key = ObjectIdentifier(shape)
    untested.removeValue(forKey: key)
    mapKeys.removeValue(forKey: key)
    if let mapped = map.removeValue(forKey: key) {
      for o in mapped {
        map[ObjectIdentifier(o)]?.removeAll { $0 === shape }
      }
    }
  }
}

// MARK: - Drawing

/// `com.cburch.draw.model.Drawing`, the default `CanvasModel`.
open class Drawing: CanvasModel {
  private var listeners: [ObjectIdentifier: CanvasModelListener] = [:]
  private var canvasObjects: [CanvasObject] = []
  private let overlaps = DrawingOverlaps()

  public init() {}

  public func addCanvasModelListener(_ listener: CanvasModelListener) {
    listeners[ObjectIdentifier(listener)] = listener
  }

  public func removeCanvasModelListener(_ listener: CanvasModelListener) {
    listeners.removeValue(forKey: ObjectIdentifier(listener))
  }

  private func fireChanged(_ event: CanvasModelEvent) {
    for listener in listeners.values { listener.modelChanged(event) }
  }

  /// Subclasses (e.g. an appearance-editing model) may veto a change by overriding this and
  /// returning `false`. Mirrors `Drawing.isChangeAllowed`.
  open func isChangeAllowed(_ event: CanvasModelEvent) -> Bool { true }

  public func addObjects(at index: Int, _ shapes: [CanvasObject]) {
    var indexed: [(CanvasObject, Int)] = []
    var i = index
    for shape in shapes {
      indexed.append((shape, i))
      i += 1
    }
    addObjectsHelp(indexed)
  }

  public func addObjects(_ shapes: [(object: CanvasObject, index: Int)]) {
    addObjectsHelp(shapes.map { ($0.object, $0.index) })
  }

  private func addObjectsHelp(_ shapes: [(CanvasObject, Int)]) {
    let event = CanvasModelEvent.forAdd(self, shapes.map(\.0))
    guard !shapes.isEmpty, isChangeAllowed(event) else { return }
    for (shape, index) in shapes {
      // Java: `canvasObjects.add(index, shape)`; an out-of-range index throws
      // `IndexOutOfBoundsException` uncaught, exactly as `Array.insert` traps here. Not
      // reachable from ordinary `.circ`/SVG loading, which only ever appends at index 0 or
      // the current count.
      canvasObjects.insert(shape, at: index)
      overlaps.addShape(shape)
    }
    fireChanged(event)
  }

  public func deleteHandle(_ handle: Handle) -> Handle? {
    let event = CanvasModelEvent.forDeleteHandle(self, handle)
    guard isChangeAllowed(event) else { return nil }
    let object = handle.object
    let result = object.deleteHandle(handle)
    overlaps.invalidateShape(object)
    fireChanged(event)
    return result
  }

  public var objectsFromBottom: [CanvasObject] { canvasObjects }
  public var objectsFromTop: [CanvasObject] { Array(canvasObjects.reversed()) }

  public func objects(in bounds: Bounds) -> [CanvasObject] {
    objectsFromBottom.filter { bounds.contains($0.bounds) }
  }

  public func objectsOverlapping(_ shape: CanvasObject) -> [CanvasObject] {
    overlaps.getObjectsOverlapping(shape)
  }

  public func insertHandle(_ desired: Handle, after previous: Handle?) throws {
    let object = desired.object
    let event = CanvasModelEvent.forInsertHandle(self, desired)
    guard isChangeAllowed(event) else { return }
    try object.insertHandle(desired, after: previous)
    overlaps.invalidateShape(object)
    fireChanged(event)
  }

  public func moveHandle(_ gesture: HandleGesture) -> Handle? {
    let event = CanvasModelEvent.forMoveHandle(self, gesture)
    let object = gesture.handle.object
    guard canvasObjects.contains(where: { $0 === object }),
      gesture.deltaX != 0 || gesture.deltaY != 0,
      isChangeAllowed(event)
    else { return nil }
    let moved = object.moveHandle(gesture)
    gesture.setResultingHandle(moved)
    overlaps.invalidateShape(object)
    fireChanged(event)
    return moved
  }

  public func removeObjects(_ shapes: [CanvasObject]) {
    let found = restrict(shapes)
    let event = CanvasModelEvent.forRemove(self, found)
    guard !found.isEmpty, isChangeAllowed(event) else { return }
    for shape in found {
      canvasObjects.removeAll { $0 === shape }
      overlaps.removeShape(shape)
    }
    fireChanged(event)
  }

  public func reorderObjects(_ requests: [ReorderRequest]) throws {
    let hasEffect = requests.contains { $0.fromIndex != $0.toIndex }
    let event = CanvasModelEvent.forReorder(self, requests)
    guard hasEffect, isChangeAllowed(event) else { return }
    for request in requests {
      guard request.fromIndex >= 0, request.fromIndex < canvasObjects.count,
        canvasObjects[request.fromIndex] === request.object
      else {
        throw CanvasModelError.reorderTargetMismatch(fromIndex: request.fromIndex)
      }
      canvasObjects.remove(at: request.fromIndex)
      canvasObjects.insert(request.object, at: request.toIndex)
    }
    fireChanged(event)
  }

  private func restrict(_ shapes: [CanvasObject]) -> [CanvasObject] {
    shapes.filter { shape in canvasObjects.contains { $0 === shape } }
  }

  public func setAttributeValues(_ values: [AttributeMapKey: AttributeValue?]) throws {
    var oldValues: [AttributeMapKey: AttributeValue?] = [:]
    for key in values.keys {
      // `updateValue(_:forKey:)`, not subscript assignment: the value being stored is itself
      // `AttributeValue?`, and `dict[key] = nil` would be read as "remove this key" rather than
      // "store a present-but-nil value" (the classic nested-Optional dictionary-subscript trap).
      oldValues.updateValue(key.object.attributeSet.rawValue(key.attribute), forKey: key)
    }
    let event = CanvasModelEvent.forChangeAttributes(self, oldValues: oldValues, newValues: values)
    guard isChangeAllowed(event) else { return }
    for (key, value) in values {
      try key.object.attributeSet.setRawValue(key.attribute, value)
      overlaps.invalidateShape(key.object)
    }
    fireChanged(event)
  }

  public func setText(_ text: DrawText, _ value: String) {
    let oldValue = text.text
    let event = CanvasModelEvent.forChangeText(self, text, oldText: oldValue, newText: value)
    guard canvasObjects.contains(where: { $0 === text }), oldValue != value, isChangeAllowed(event)
    else { return }
    text.text = value
    overlaps.invalidateShape(text)
    fireChanged(event)
  }

  public func translateObjects(_ shapes: [CanvasObject], dx: Int, dy: Int) {
    let found = restrict(shapes)
    let event = CanvasModelEvent.forTranslate(self, found)
    guard !found.isEmpty, dx != 0 || dy != 0, isChangeAllowed(event) else { return }
    for shape in shapes {
      shape.translate(dx, dy)
      overlaps.invalidateShape(shape)
    }
    fireChanged(event)
  }
}
