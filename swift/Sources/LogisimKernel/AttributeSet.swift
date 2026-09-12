// AttributeSet: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/data/{AttributeSet,AbstractAttributeSet,AttributeSets,AttributeListener,
// AttributeEvent}.java. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── D3: listeners use registration tokens, not add/remove pairs ────────────────────────────
//
// Upstream registers 1,072 attribute listeners against 220 removals. That is not a discipline
// anyone maintained, and under ARC (unlike Java's GC) the surplus registrations are permanent
// leaks with a strong edge from every attribute set to every observer that ever looked at it.
//
// `addAttributeListener` therefore returns an `AttributeSubscription` the caller stores. The
// set holds the token *weakly* and the token holds the listener *strongly*, so dropping the
// token, including by simply letting the owning object die, unsubscribes. There is no
// set→listener strong edge for a cycle to form on.
//
// Callers whose listener is also the token's owner must capture `self` weakly in closure-based
// listeners, exactly as with Combine.

import Foundation

// MARK: - Events and listeners

/// `com.cburch.logisim.data.AttributeEvent`.
///
/// `attribute`, `value` and `oldValue` are all nil for a list-changed event, matching Java's
/// single-argument constructor.
public struct AttributeEvent {
  public let source: any AttributeSet
  public let attribute: AnyAttribute?
  public let value: AttributeValue?
  public let oldValue: AttributeValue?

  public init(source: any AttributeSet) {
    self.source = source
    self.attribute = nil
    self.value = nil
    self.oldValue = nil
  }

  public init(
    source: any AttributeSet,
    attribute: AnyAttribute?,
    value: AttributeValue?,
    oldValue: AttributeValue?
  ) {
    self.source = source
    self.attribute = attribute
    self.value = value
    self.oldValue = oldValue
  }

  /// Typed access to `value`, for listeners that already know which attribute they care about.
  public func value<V>(as attribute: Attribute<V>) -> V? {
    guard self.attribute === attribute else { return nil }
    return value.flatMap(attribute.decode)
  }

  /// Typed access to `oldValue`.
  public func oldValue<V>(as attribute: Attribute<V>) -> V? {
    guard self.attribute === attribute else { return nil }
    return oldValue.flatMap(attribute.decode)
  }
}

/// `com.cburch.logisim.data.AttributeListener`. Both methods default to no-ops, as upstream's
/// interface does.
public protocol AttributeListener: AnyObject {
  func attributeListChanged(_ event: AttributeEvent)
  func attributeValueChanged(_ event: AttributeEvent)
}

extension AttributeListener {
  public func attributeListChanged(_ event: AttributeEvent) {}
  public func attributeValueChanged(_ event: AttributeEvent) {}
}

/// A closure-backed `AttributeListener`, for observers that do not want to be a class.
public final class AttributeListenerClosures: AttributeListener {
  private let onValueChanged: ((AttributeEvent) -> Void)?
  private let onListChanged: ((AttributeEvent) -> Void)?

  public init(
    onValueChanged: ((AttributeEvent) -> Void)? = nil,
    onListChanged: ((AttributeEvent) -> Void)? = nil
  ) {
    self.onValueChanged = onValueChanged
    self.onListChanged = onListChanged
  }

  public func attributeValueChanged(_ event: AttributeEvent) { onValueChanged?(event) }
  public func attributeListChanged(_ event: AttributeEvent) { onListChanged?(event) }
}

/// The cancellation token returned by `addAttributeListener`. Holding it keeps the
/// subscription (and the listener) alive; releasing it unsubscribes.
public final class AttributeSubscription {
  fileprivate let listener: AttributeListener
  fileprivate let identifier: UInt64
  fileprivate weak var registry: AttributeListenerRegistry?

  fileprivate init(
    listener: AttributeListener,
    identifier: UInt64,
    registry: AttributeListenerRegistry
  ) {
    self.listener = listener
    self.identifier = identifier
    self.registry = registry
  }

  /// Unsubscribe now. Idempotent.
  public func cancel() {
    registry?.remove(identifier)
    registry = nil
  }

  deinit { cancel() }
}

/// The listener list every attribute set embeds. Java keeps this inline in
/// `AbstractAttributeSet`; here it is a separate object so `EMPTY` and any future
/// `AttributeSet` that is not an `AbstractAttributeSet` can reuse it.
public final class AttributeListenerRegistry {
  private struct Entry {
    let identifier: UInt64
    weak var token: AttributeSubscription?
  }

  private var entries: [Entry] = []
  private var nextIdentifier: UInt64 = 1

  public init() {}

  public var isEmpty: Bool { entries.allSatisfy { $0.token == nil } }

  public func add(_ listener: AttributeListener) -> AttributeSubscription {
    let identifier = nextIdentifier
    nextIdentifier += 1
    let token = AttributeSubscription(
      listener: listener, identifier: identifier, registry: self)
    entries.append(Entry(identifier: identifier, token: token))
    return token
  }

  fileprivate func remove(_ identifier: UInt64) {
    entries.removeAll { $0.identifier == identifier || $0.token == nil }
  }

  /// Snapshot before dispatching. Java copies the list for exactly this reason: listeners
  /// routinely add or remove listeners while being notified.
  private func snapshot() -> [AttributeListener] {
    entries.removeAll { $0.token == nil }
    return entries.compactMap { $0.token?.listener }
  }

  public func fireAttributeListChanged(_ event: AttributeEvent) {
    for listener in snapshot() { listener.attributeListChanged(event) }
  }

  public func fireAttributeValueChanged(_ event: AttributeEvent) {
    for listener in snapshot() { listener.attributeValueChanged(event) }
  }
}

// MARK: - AttributeSet

/// `com.cburch.logisim.data.AttributeSet`.
///
/// A class protocol, because D4 requires attribute sets to be keyed by reference identity;
/// structural equality would silently corrupt the dirty lists and per-component state that
/// the simulator keys on.
public protocol AttributeSet: AnyObject {
  /// Java's `clone()`. `EMPTY` returns itself; everything else returns a detached copy whose
  /// listener list is empty.
  func copy() -> any AttributeSet

  /// Java's `getAttributes()`. Java can return `null` here; the port returns `[]`, and
  /// `AttributeSets.copy` no longer needs the null guard upstream carries.
  var attributes: [AnyAttribute] { get }

  func containsAttribute(_ attribute: AnyAttribute) -> Bool

  func attribute(named name: String) -> AnyAttribute?

  func getValue<V>(_ attribute: Attribute<V>) -> V?

  func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws

  /// Storage-level access, used by the `.circ` codec and by `AttributeSets.copy` so neither
  /// has to recover `V`.
  func rawValue(_ attribute: AnyAttribute) -> AttributeValue?

  func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws

  // Errors mirroring the `IllegalArgumentException`s in `AttributeSets.java:72/81/130/137`.
  // Both are reachable from a `.circ` file, a component element naming an attribute its
  // factory does not define, or assigning to one marked read-only, so they throw rather
  // than trap (D13). Java catches these during load and reports a file error; trapping
  // would abort the app on a malformed file.

  func isReadOnly(_ attribute: AnyAttribute) -> Bool

  /// Optional upstream; the default implementation traps, as Java's throws
  /// `UnsupportedOperationException`.
  func setReadOnly(_ attribute: AnyAttribute, _ value: Bool)

  func isToSave(_ attribute: AnyAttribute) -> Bool

  /// Attributes that may also change as a side effect of setting `attribute` to `value`.
  /// Does not itself change anything. `nil` when there are none.
  func attributesMayAlsoBeChanged<V>(_ attribute: Attribute<V>, _ value: V?) -> [AnyAttribute]?

  @discardableResult
  func addAttributeListener(_ listener: AttributeListener) -> AttributeSubscription
}

extension AttributeSet {
  /// The typed accessor component code uses: `attrs[Pin.appearance]`.
  ///
  /// Read-only by necessity: since D13, `setValue` throws (an absent or read-only attribute
  /// is reachable from a `.circ` file), and a Swift subscript setter cannot. Writes go
  /// through `try attrs.setValue(attribute, value)`, which is the honest signature; setting
  /// an attribute really can fail, and swallowing that to keep `attrs[x] = y` would hide a
  /// malformed-file error rather than surface it.
  public subscript<V>(attribute: Attribute<V>) -> V? {
    getValue(attribute)
  }

  /// Convenience for attributes that are always populated.
  public subscript<V>(attribute: Attribute<V>, default fallback: @autoclosure () -> V) -> V {
    getValue(attribute) ?? fallback()
  }

  /// Closure-based subscription. The returned token owns the closures; capture `self` weakly.
  @discardableResult
  public func addAttributeListener(
    onValueChanged: ((AttributeEvent) -> Void)? = nil,
    onListChanged: ((AttributeEvent) -> Void)? = nil
  ) -> AttributeSubscription {
    addAttributeListener(
      AttributeListenerClosures(
        onValueChanged: onValueChanged, onListChanged: onListChanged))
  }

  /// Every attribute that should be written to `.circ`, in declaration order.
  public var savedAttributes: [AnyAttribute] {
    attributes.filter { isToSave($0) }
  }
}

// MARK: - AbstractAttributeSet

/// `com.cburch.logisim.data.AbstractAttributeSet`.
///
/// Subclasses supply `attributes`, `rawValue`, `setRawValue`, `makeCopyInstance` and
/// `copyInto`; everything else is inherited.
open class AbstractAttributeSet: AttributeSet {
  private let registry = AttributeListenerRegistry()

  public init() {}

  // MARK: Subclass responsibilities

  open var attributes: [AnyAttribute] {
    fatalError("AbstractAttributeSet subclasses must override `attributes`")
  }

  open func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    fatalError("AbstractAttributeSet subclasses must override `rawValue(_:)`")
  }

  open func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    fatalError("AbstractAttributeSet subclasses must override `setRawValue(_:_:)`")
  }

  /// Java gets a blank instance from `Object.clone()`; Swift has no such thing, so the
  /// subclass makes one and `copyInto` fills it. Split exactly as upstream splits
  /// `clone()`/`copyInto()`.
  open func makeCopyInstance() -> AbstractAttributeSet {
    fatalError("AbstractAttributeSet subclasses must override `makeCopyInstance()`")
  }

  open func copyInto(_ destination: AbstractAttributeSet) {
    fatalError("AbstractAttributeSet subclasses must override `copyInto(_:)`")
  }

  // MARK: AttributeSet

  open func copy() -> any AttributeSet {
    let destination = makeCopyInstance()
    copyInto(destination)
    return destination
  }

  open func containsAttribute(_ attribute: AnyAttribute) -> Bool {
    attributes.contains { $0 === attribute }
  }

  open func attribute(named name: String) -> AnyAttribute? {
    attributes.first { $0.name == name }
  }

  open func getValue<V>(_ attribute: Attribute<V>) -> V? {
    rawValue(attribute).flatMap(attribute.decode)
  }

  open func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws {
    try setRawValue(attribute, value.map(attribute.encode))
  }

  open func isReadOnly(_ attribute: AnyAttribute) -> Bool { false }

  open func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    fatalError("this attribute set does not support read-only attributes")
  }

  open func isToSave(_ attribute: AnyAttribute) -> Bool { attribute.isToSave }

  open func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ value: V?
  ) -> [AnyAttribute]? {
    nil
  }

  @discardableResult
  public func addAttributeListener(_ listener: AttributeListener) -> AttributeSubscription {
    registry.add(listener)
  }

  // MARK: Firing

  /// `AbstractAttributeSet.fireAttributeListChanged()`.
  public func fireAttributeListChanged() {
    registry.fireAttributeListChanged(AttributeEvent(source: self))
  }

  /// `AbstractAttributeSet.fireAttributeValueChanged(attr, value, oldvalue)`.
  public func fireAttributeValueChanged(
    _ attribute: AnyAttribute,
    value: AttributeValue?,
    oldValue: AttributeValue?
  ) {
    registry.fireAttributeValueChanged(
      AttributeEvent(
        source: self, attribute: attribute, value: value, oldValue: oldValue))
  }

  /// Typed convenience wrapper around `fireAttributeValueChanged`.
  public func fireAttributeValueChanged<V>(
    _ attribute: Attribute<V>, value: V?, oldValue: V?
  ) {
    fireAttributeValueChanged(
      attribute,
      value: value.map(attribute.encode),
      oldValue: oldValue.map(attribute.encode))
  }
}

// MARK: - Concrete sets

/// `AttributeSets.FixedSet`; a fixed attribute list with a 32-bit read-only mask.
public final class FixedAttributeSet: AbstractAttributeSet {
  private var attributeList: [AnyAttribute]
  private var values: [AttributeValue?]
  private var readOnlyMask: UInt32 = 0

  /// Upstream refuses more than 32 attributes because the read-only flags live in one `int`.
  public static let maximumAttributeCount = 32

  public init(attributes: [AnyAttribute], initialValues: [AttributeValue?]) {
    precondition(
      attributes.count == initialValues.count,
      "attribute and value arrays must have same length")
    precondition(
      attributes.count <= Self.maximumAttributeCount,
      "cannot handle more than 32 attributes")
    self.attributeList = attributes
    self.values = initialValues
    super.init()
  }

  private func index(of attribute: AnyAttribute) -> Int? {
    attributeList.firstIndex { $0 === attribute }
  }

  public override var attributes: [AnyAttribute] { attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    guard let index = index(of: attribute) else { return nil }
    return values[index]
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    guard let index = index(of: attribute) else {
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    guard !isReadOnly(at: index) else { throw AttributeSetError.readOnly(name: attribute.name) }
    let oldValue = values[index]
    values[index] = value
    fireAttributeValueChanged(attribute, value: value, oldValue: oldValue)
  }

  private func isReadOnly(at index: Int) -> Bool {
    (readOnlyMask >> UInt32(index)) & 1 == 1
  }

  /// Bug-for-bug: an attribute that is *absent* reports as read-only.
  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    guard let index = index(of: attribute) else { return true }
    return isReadOnly(at: index)
  }

  public override func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    guard let index = index(of: attribute) else {
      preconditionFailure("attribute \(attribute.name) absent")
    }
    if value {
      readOnlyMask |= (1 << UInt32(index))
    } else {
      readOnlyMask &= ~(1 << UInt32(index))
    }
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    FixedAttributeSet(attributes: attributeList, initialValues: values)
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? FixedAttributeSet else {
      preconditionFailure("FixedAttributeSet can only copy into a FixedAttributeSet")
    }
    destination.attributeList = attributeList
    destination.values = values
    destination.readOnlyMask = readOnlyMask
  }
}

/// `AttributeSets.SingletonSet`; a one-attribute set with a single read-only flag.
public final class SingletonAttributeSet: AbstractAttributeSet {
  private var attributeList: [AnyAttribute]
  private var value: AttributeValue?
  private var readOnly = false

  public init(attribute: AnyAttribute, initialValue: AttributeValue?) {
    self.attributeList = [attribute]
    self.value = initialValue
    super.init()
  }

  private func index(of attribute: AnyAttribute) -> Int? {
    attributeList.firstIndex { $0 === attribute }
  }

  public override var attributes: [AnyAttribute] { attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    index(of: attribute) != nil ? value : nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ newValue: AttributeValue?) throws {
    guard index(of: attribute) != nil else {
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    guard !readOnly else { throw AttributeSetError.readOnly(name: attribute.name) }
    let oldValue = value
    value = newValue
    fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
  }

  /// Bug-for-bug: upstream ignores its argument here, so *any* attribute, including one this
  /// set does not hold, reports the set's single read-only flag.
  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool { readOnly }

  public override func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    guard index(of: attribute) != nil else {
      preconditionFailure("attribute \(attribute.name) absent")
    }
    readOnly = value
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    SingletonAttributeSet(attribute: attributeList[0], initialValue: value)
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? SingletonAttributeSet else {
      preconditionFailure("SingletonAttributeSet can only copy into a SingletonAttributeSet")
    }
    destination.attributeList = attributeList
    destination.value = value
    destination.readOnly = readOnly
  }
}

/// `AttributeSets.EMPTY`. Immutable, shared, and `copy()` returns `self` exactly as upstream's
/// `clone()` does.
public final class EmptyAttributeSet: AttributeSet {
  public static let shared = EmptyAttributeSet()

  private let registry = AttributeListenerRegistry()

  private init() {}

  public func copy() -> any AttributeSet { self }
  public var attributes: [AnyAttribute] { [] }
  public func containsAttribute(_ attribute: AnyAttribute) -> Bool { false }
  public func attribute(named name: String) -> AnyAttribute? { nil }
  public func getValue<V>(_ attribute: Attribute<V>) -> V? { nil }
  /// Silently discards, as upstream does.
  public func setValue<V>(_ attribute: Attribute<V>, _ value: V?) throws {}
  public func rawValue(_ attribute: AnyAttribute) -> AttributeValue? { nil }
  public func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {}
  public func isReadOnly(_ attribute: AnyAttribute) -> Bool { true }
  public func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    fatalError("AttributeSets.EMPTY does not support read-only attributes")
  }
  public func isToSave(_ attribute: AnyAttribute) -> Bool { attribute.isToSave }
  public func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ value: V?
  ) -> [AnyAttribute]? { nil }

  @discardableResult
  public func addAttributeListener(_ listener: AttributeListener) -> AttributeSubscription {
    registry.add(listener)
  }
}

// MARK: - Bindings and factories

/// An `(attribute, initial value)` pair, type-checked at the point of construction.
///
/// Java's `AttributeSets.fixedSet(Attribute<?>[], Object[])` takes two parallel arrays with no
/// type relationship between them at all; this makes the pairing static.
public struct AttributeBinding {
  public let attribute: AnyAttribute
  public let value: AttributeValue?

  public init(attribute: AnyAttribute, value: AttributeValue?) {
    self.attribute = attribute
    self.value = value
  }
}

extension Attribute {
  /// `attr.binding(x)`: a typed initial value for `AttributeSets.fixedSet`.
  public func binding(_ value: V?) -> AttributeBinding {
    AttributeBinding(attribute: self, value: value.map(encode))
  }
}

/// `com.cburch.logisim.data.AttributeSets`.
public enum AttributeSets {
  /// `AttributeSets.EMPTY`.
  public static var empty: any AttributeSet { EmptyAttributeSet.shared }

  /// `AttributeSets.fixedSet(attrs, initValues)`: a singleton set for one attribute, `EMPTY`
  /// for none, a fixed set otherwise.
  public static func fixedSet(_ bindings: [AttributeBinding]) -> any AttributeSet {
    if bindings.count > 1 {
      return FixedAttributeSet(
        attributes: bindings.map(\.attribute),
        initialValues: bindings.map(\.value))
    }
    if let only = bindings.first {
      return SingletonAttributeSet(attribute: only.attribute, initialValue: only.value)
    }
    return empty
  }

  /// The parallel-array form, for the `.circ` loader, which does not know `V` either.
  public static func fixedSet(
    attributes: [AnyAttribute], initialValues: [AttributeValue?]
  ) -> any AttributeSet {
    precondition(
      attributes.count == initialValues.count,
      "attribute and value arrays must have same length")
    return fixedSet(
      zip(attributes, initialValues).map(AttributeBinding.init(attribute:value:)))
  }

  /// `AttributeSets.copy(src, dst)`. Copies through storage form, so it neither needs nor
  /// recovers `V`: and, like upstream, it fires a value-changed event per attribute.
  public static func copy(from source: any AttributeSet, to destination: any AttributeSet) throws {
    for attribute in source.attributes {
      try destination.setRawValue(attribute, source.rawValue(attribute))
    }
  }
}

/// Java: the `IllegalArgumentException`s raised by `AttributeSets` when an attribute is not
/// part of a set, or is read-only (`AttributeSets.java:72`, `:81`, `:130`, `:137`).
///
/// Both are reachable from a `.circ` file, so they throw rather than trap (D13).
public enum AttributeSetError: Error, Equatable, CustomStringConvertible, Sendable {
  case attributeAbsent(name: String)
  case readOnly(name: String)

  public var description: String {
    switch self {
    case let .attributeAbsent(name): "attribute \(name) absent"
    case let .readOnly(name): "read only: \(name)"
    }
  }
}
