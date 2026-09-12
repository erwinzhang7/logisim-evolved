// Component.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.{Component, ComponentEvent,
// ComponentListener}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// ── D4: identity, and why this is a protocol rather than one final class ────────────────────
//
// D4 requires that components be reference types keyed by `ObjectIdentifier`, and forbids
// synthesised `Equatable`/`Hashable` on them: the simulator keys dirty lists, `componentData`,
// `CircuitPoints` and `BusConnection` matching on reference identity, and structural equality
// corrupts that silently rather than loudly.
//
// This file expresses that the same way `LogisimKernel` already expressed it for `AttributeSet`
// (D4 names both in one breath): a **class-constrained protocol** whose conformers are all
// `final class`. `AttributeSet` is a protocol with `AbstractAttributeSet` and three final
// concrete sets; `Component` is a protocol with `InstanceComponent`, `Wire` and
// `UnresolvedComponent`. A single final class cannot work here because Java's `Wire` genuinely is
// a `Component` with its own geometry and its own attribute behaviour, and it is not an instance
// of anything; collapsing the two would mean a discriminated union inside one class, which is
// strictly worse for the same guarantee.
//
// What D4 actually buys is preserved exactly: `Component` declares **no** `Equatable`/`Hashable`
// conformance, so `==` on two components does not compile, and all keying goes through
// `ComponentRef` (below) or `ObjectIdentifier` directly.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `draw(ComponentDrawContext)`, `expose(ComponentDrawContext)`, `contains(Location, Graphics)`
//     and `getBounds(Graphics)`; all four take an AWT drawing context. D6 puts every drawing
//     API behind `RenderScene` in `LogisimRender`, and D9 keeps drawing types out of the model
//     entirely, so these belong to M6 and are not declared here.
//   * `propagate(CircuitState)`; M3. This milestone is the inert netlist: placement records, no
//     simulation.

import Foundation
import LogisimKernel

// MARK: - Feature keys

/// The key space of `Component.getFeature(Object)`.
///
/// Java passes `Class` literals (`Pokable.class`, `WireRepair.class`, …) as opaque keys. Swift
/// metatypes would work but make the call site depend on types that live in modules this one
/// cannot see yet, so the keys are named constants. The set below is the one enumerated in
/// upstream's own doc comment; adding a key is a one-line change and does not disturb callers.
public struct ComponentFeatureKey: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }

  public static let pokable = ComponentFeatureKey("Pokable")
  public static let customHandles = ComponentFeatureKey("CustomHandles")
  public static let wireRepair = ComponentFeatureKey("WireRepair")
  public static let textEditable = ComponentFeatureKey("TextEditable")
  public static let menuExtender = ComponentFeatureKey("MenuExtender")
  public static let toolTipMaker = ComponentFeatureKey("ToolTipMaker")
  public static let expressionComputer = ComponentFeatureKey("ExpressionComputer")
  public static let loggable = ComponentFeatureKey("Loggable")

  public var description: String { rawValue }
}

// MARK: - Events and listeners

/// `com.cburch.logisim.comp.ComponentEvent`.
///
/// `oldData`/`data` are `Any?` because upstream stores heterogeneous payloads through them: a
/// `List<EndData>` or a single `EndData` for `endChanged`, an `AttributeEvent` for `labelChanged`,
/// and nothing at all for `componentInvalidated`.
public struct ComponentEvent {
  public let source: any Component
  public let oldData: Any?
  public let data: Any?

  public init(source: any Component, oldData: Any? = nil, data: Any? = nil) {
    self.source = source
    self.oldData = oldData
    self.data = data
  }
}

/// `com.cburch.logisim.comp.ComponentListener`. All three methods default to no-ops, as
/// upstream's interface does.
public protocol ComponentListener: AnyObject {
  func componentInvalidated(_ event: ComponentEvent)
  func endChanged(_ event: ComponentEvent)
  func labelChanged(_ event: ComponentEvent)
}

extension ComponentListener {
  public func componentInvalidated(_ event: ComponentEvent) {}
  public func endChanged(_ event: ComponentEvent) {}
  public func labelChanged(_ event: ComponentEvent) {}
}

/// The cancellation token returned by `addComponentListener`, mirroring `AttributeSubscription`
/// in the kernel. D3: the component holds the token weakly and the token holds the listener
/// strongly, so dropping the token unsubscribes and no component→listener strong edge exists.
public final class ComponentSubscription {
  fileprivate let listener: ComponentListener
  fileprivate let identifier: UInt64
  fileprivate weak var registry: ComponentListenerRegistry?

  fileprivate init(
    listener: ComponentListener, identifier: UInt64, registry: ComponentListenerRegistry
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

/// The listener list a component embeds. Java keeps a `ComponentListener[]` inline in
/// `InstanceComponent`; this mirrors `AttributeListenerRegistry` so both halves of the model
/// have the same lifetime story.
public final class ComponentListenerRegistry {
  private struct Entry {
    let identifier: UInt64
    weak var token: ComponentSubscription?
  }

  private var entries: [Entry] = []
  private var nextIdentifier: UInt64 = 1

  public init() {}

  public var isEmpty: Bool { entries.allSatisfy { $0.token == nil } }

  public func add(_ listener: ComponentListener) -> ComponentSubscription {
    let identifier = nextIdentifier
    nextIdentifier += 1
    let token = ComponentSubscription(
      listener: listener, identifier: identifier, registry: self)
    entries.append(Entry(identifier: identifier, token: token))
    return token
  }

  fileprivate func remove(_ identifier: UInt64) {
    entries.removeAll { $0.identifier == identifier || $0.token == nil }
  }

  /// Snapshot before dispatching: listeners routinely mutate the list while being notified.
  private func snapshot() -> [ComponentListener] {
    entries.removeAll { $0.token == nil }
    return entries.compactMap { $0.token?.listener }
  }

  public func fireComponentInvalidated(_ event: ComponentEvent) {
    for listener in snapshot() { listener.componentInvalidated(event) }
  }

  public func fireEndChanged(_ event: ComponentEvent) {
    for listener in snapshot() { listener.endChanged(event) }
  }

  public func fireLabelChanged(_ event: ComponentEvent) {
    for listener in snapshot() { listener.labelChanged(event) }
  }
}

// MARK: - Component

/// `com.cburch.logisim.comp.Component`.
///
/// A placement record: which factory produced it, where it sits, what its attributes are, and
/// where its connection points are. Nothing here simulates.
public protocol Component: AnyObject, LocationAt {
  /// `getAttributeSet()`.
  var attributeSet: any AttributeSet { get }

  /// `getFactory()`.
  var factory: any ComponentFactory { get }

  /// `setFactory(ComponentFactory)`: a no-op by default, exactly as upstream's interface
  /// declares it. The `.circ` repair passes use it to retarget a component at a replacement
  /// factory without rebuilding it.
  func setFactory(_ factory: any ComponentFactory)

  /// `getBounds()`.
  var bounds: Bounds { get }

  /// `getEnds()`.
  var ends: [EndData] { get }

  /// `getEnd(int)`.
  func end(at index: Int) -> EndData

  /// `contains(Location)`.
  func contains(_ point: Location) -> Bool

  /// `endsAt(Location)`.
  func endsAt(_ point: Location) -> Bool

  /// `getFeature(Object)`.
  func feature(_ key: ComponentFeatureKey) -> Any?

  /// `addComponentListener(ComponentListener)`.
  ///
  /// Returns `nil` for components that never issue events; upstream's `Wire` says so by simply
  /// not implementing the method, and the interface default is a no-op. D3 turns the
  /// add/remove pair into a token, so "I do not notify" is spelled as "no token to hold".
  @discardableResult
  func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription?
}

extension Component {
  public func setFactory(_ factory: any ComponentFactory) {}

  @discardableResult
  public func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription? {
    nil
  }

  /// `Component.getEnd(Location)`: the interface's default implementation, a linear scan.
  public func end(at point: Location) -> EndData? {
    ends.first { $0.location == point }
  }

  /// D4: the only sanctioned key for a component.
  public var identityKey: ObjectIdentifier { ObjectIdentifier(self) }
}

/// A `Hashable` box around a component so it can be a dictionary key or set member **by
/// reference identity**, per D4.
///
/// This exists precisely so that `Component` itself never conforms to `Hashable`: a caller has to
/// write `ComponentRef(comp)` and thereby state that identity keying is what it meant.
public struct ComponentRef: Hashable {
  public let component: any Component

  public init(_ component: any Component) { self.component = component }

  public static func == (lhs: ComponentRef, rhs: ComponentRef) -> Bool {
    lhs.component === rhs.component
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(component))
  }
}
