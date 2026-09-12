// HdlModel: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/{HdlModel,HdlModelListener,HdlContent}.java. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Scope ────────────────────────────────────────────────────────────────────────────────
//
// `HdlModel`/`HdlModelListener` are generic across every HDL-backed component upstream
// (currently only VHDL ships an implementation, but the interface is deliberately not named
// `Vhdl*`). This port covers exactly that generic contract; the VHDL-specific implementation
// is `VhdlContent.swift`.
//
// ── Deviations from the Java shape ──────────────────────────────────────────────────────
//
//   * **Properties, not getters.** `getContent()`/`getName()` become `content`/`name`
//     computed properties, matching how the rest of this port already reads (e.g.
//     `AttributeSet.attributes`). Purely a style choice; behaviour is unchanged.
//
//   * **Listener subscriptions are tokens, not add/remove pairs (D3's pattern, applied
//     here too).** Java holds `HdlModelListener`s in an `EventSourceWeakSupport`: i.e.
//     *weakly*, precisely so a listener that forgets to unregister does not leak. Under ARC
//     that weak-collection idiom is actively dangerous (D3's corollary): the concrete
//     listener in this file tree, `VhdlEntityAttributes`'s inner `VhdlEntityListener`, holds
//     a strong reference back to the attribute set, which itself holds a strong reference to
//     the `VhdlContent` it listens to; `content → listener → attrs → content` is a real
//     three-node ARC cycle if `content`'s registry held the listener strongly. So this port
//     uses the same shape as `AttributeListenerRegistry`: the registry holds the token
//     *weakly*; the token holds the listener *strongly*; the caller owns the token. Dropping
//     the token (including by letting its owner die) unsubscribes with no strong edge for a
//     cycle to use.
//
//     `addHdlModelListener` therefore returns an `HdlModelSubscription` the caller must
//     retain. `removeHdlModelListener(_:)` is kept too, for callers that still want to
//     unregister by reference the way Java's `EventSourceWeakSupport.remove` does.

import Foundation

// MARK: - HdlModelListener

/// `com.cburch.logisim.vhdl.base.HdlModelListener`.
///
/// Every method is a Java `default` no-op; the protocol extension below reproduces that so
/// conformers only implement what they care about.
public protocol HdlModelListener: AnyObject {
  /// Called when the content of the given model has been set.
  func contentSet(_ source: HdlModel)
  /// Called when the content of the given model is about to be saved.
  func aboutToSave(_ source: HdlModel)
  /// Called when the HDL appearance has changed.
  func appearanceChanged(_ source: HdlModel)
  /// Called when the model's icon or name has changed.
  func displayChanged(_ source: HdlModel)
}

extension HdlModelListener {
  public func contentSet(_ source: HdlModel) {}
  public func aboutToSave(_ source: HdlModel) {}
  public func appearanceChanged(_ source: HdlModel) {}
  public func displayChanged(_ source: HdlModel) {}
}

// MARK: - Subscription token (see the header note on why this replaces add/remove)

/// The cancellation token returned by `addHdlModelListener`. Holding it keeps the
/// subscription (and the listener) alive; releasing it unsubscribes.
public final class HdlModelSubscription {
  fileprivate let listener: HdlModelListener
  fileprivate let identifier: UInt64
  fileprivate weak var registry: HdlModelListenerRegistry?

  fileprivate init(listener: HdlModelListener, identifier: UInt64, registry: HdlModelListenerRegistry) {
    self.listener = listener
    self.identifier = identifier
    self.registry = registry
  }

  /// Unsubscribe now. Idempotent.
  public func cancel() {
    registry?.remove(identifier: identifier)
    registry = nil
  }

  deinit { cancel() }
}

/// The listener list an `HdlContent` embeds. A separate object (as with
/// `AttributeListenerRegistry`) so it can be unit tested and reused independently of any one
/// `HdlModel` implementation.
public final class HdlModelListenerRegistry {
  private struct Entry {
    let identifier: UInt64
    weak var token: HdlModelSubscription?
  }

  private var entries: [Entry] = []
  private var nextIdentifier: UInt64 = 1
  /// Bookkeeping only: lets `remove(_ listener:)` find a subscription by reference, the way
  /// Java's `EventSourceWeakSupport.remove(Object)` does. Does not itself keep anything alive.
  private var identifierByListener: [ObjectIdentifier: UInt64] = [:]

  public init() {}

  public var isEmpty: Bool { entries.allSatisfy { $0.token == nil } }

  @discardableResult
  public func add(_ listener: HdlModelListener) -> HdlModelSubscription {
    let identifier = nextIdentifier
    nextIdentifier += 1
    let token = HdlModelSubscription(listener: listener, identifier: identifier, registry: self)
    entries.append(Entry(identifier: identifier, token: token))
    identifierByListener[ObjectIdentifier(listener)] = identifier
    return token
  }

  /// `HdlModel.removeHdlModelListener(HdlModelListener)`, remove by reference.
  public func remove(_ listener: HdlModelListener) {
    guard let identifier = identifierByListener[ObjectIdentifier(listener)] else { return }
    remove(identifier: identifier)
  }

  fileprivate func remove(identifier: UInt64) {
    entries.removeAll { $0.identifier == identifier || $0.token == nil }
    identifierByListener = identifierByListener.filter { $0.value != identifier }
  }

  private func snapshot() -> [HdlModelListener] {
    entries.removeAll { $0.token == nil }
    return entries.compactMap { $0.token?.listener }
  }

  public func fireContentSet(_ source: HdlModel) {
    for listener in snapshot() { listener.contentSet(source) }
  }

  public func fireAboutToSave(_ source: HdlModel) {
    for listener in snapshot() { listener.aboutToSave(source) }
  }

  public func fireAppearanceChanged(_ source: HdlModel) {
    for listener in snapshot() { listener.appearanceChanged(source) }
  }

  public func fireDisplayChanged(_ source: HdlModel) {
    for listener in snapshot() { listener.displayChanged(source) }
  }
}

// MARK: - HdlModel

/// `com.cburch.logisim.vhdl.base.HdlModel`.
public protocol HdlModel: AnyObject {
  /// Registers a listener for changes to the values. Returns a token the caller must retain
  /// (see the header note); dropping it unsubscribes.
  @discardableResult
  func addHdlModelListener(_ listener: HdlModelListener) -> HdlModelSubscription

  /// Unregisters a listener for changes to the values, by reference.
  func removeHdlModelListener(_ listener: HdlModelListener)

  /// Compares the model's content with another model's.
  func compare(toModel other: HdlModel) -> Bool

  /// Compares the model's content with a string.
  func compare(toContent text: String) -> Bool

  /// The content of the HDL-IP component.
  var content: String { get }

  /// The component's name.
  var name: String { get }

  /// Sets the content of the component. Returns whether the new content parsed successfully.
  @discardableResult
  func setContent(_ text: String) -> Bool

  /// Sets the content of the component without validating the code.
  @discardableResult
  func setContentNoValidation(_ text: String) -> Bool

  /// Whether the content of the component is currently valid.
  var isValid: Bool { get }

  /// Surfaces the last validation error, if any. Java shows a modal dialog here
  /// (`OptionPane.showMessageDialog`/`showOptionDialog`); per D9/D17 that is a UI concern, so
  /// this is a no-op in the kernel model and callers read `lastValidationError` instead
  /// (see `VhdlContent`).
  func showErrors()

  /// Fire notification that the display (icon/name) has changed.
  func displayChanged()
}
