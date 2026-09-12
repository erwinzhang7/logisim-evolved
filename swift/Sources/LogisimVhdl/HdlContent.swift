// HdlContent: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/HdlContent.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Java's `HdlContent` is `abstract ... implements HdlModel, Cloneable`, supplying only the
// listener bookkeeping and leaving `getContent`/`getName`/`setContent`/
// `setContentNoValidation`/`isValid`/`compare`/`showErrors` abstract. `clone()` is not carried
// here: it exists solely so `VhdlContent.clone()` (its only override in the whole codebase)
// can reset the listener list on a copy, and `VhdlContent`'s own `copy()` does that directly
// (see `VhdlContent.swift`); a second copying mechanism on the base class would be dead code.
//
// The abstract members below trap rather than throw: no `.circ` file can reach an
// uninstantiated `HdlContent` (D13's "abstract-method stub" category, alongside
// `AnyAttribute`/`AbstractAttributeSet` in LogisimKernel).

import Foundation

open class HdlContent: HdlModel {
  private let registry = HdlModelListenerRegistry()

  public init() {}

  // MARK: HdlModel — listener wiring (concrete; this is all Java's `HdlContent` implements)

  @discardableResult
  public func addHdlModelListener(_ listener: HdlModelListener) -> HdlModelSubscription {
    registry.add(listener)
  }

  public func removeHdlModelListener(_ listener: HdlModelListener) {
    registry.remove(listener)
  }

  /// `HdlContent.fireContentSet()`.
  public func fireContentSet() { registry.fireContentSet(self) }

  /// `HdlContent.fireAboutToSave()`.
  public func fireAboutToSave() { registry.fireAboutToSave(self) }

  /// `HdlContent.fireAppearanceChanged()`.
  public func fireAppearanceChanged() { registry.fireAppearanceChanged(self) }

  /// `HdlContent.displayChanged()`.
  open func displayChanged() { registry.fireDisplayChanged(self) }

  // MARK: HdlModel — abstract in Java; subclasses (`VhdlContent`) must override every one

  open var content: String {
    fatalError("HdlContent subclasses must override `content`")
  }

  open var name: String {
    fatalError("HdlContent subclasses must override `name`")
  }

  open var isValid: Bool {
    fatalError("HdlContent subclasses must override `isValid`")
  }

  /// `HdlContent.compare(HdlModel)` has a concrete Java implementation
  /// (`compare(model.getContent())`), so it is not abstract; kept concrete here too.
  open func compare(toModel other: HdlModel) -> Bool {
    compare(toContent: other.content)
  }

  open func compare(toContent text: String) -> Bool {
    fatalError("HdlContent subclasses must override `compare(toContent:)`")
  }

  @discardableResult
  open func setContent(_ text: String) -> Bool {
    fatalError("HdlContent subclasses must override `setContent(_:)`")
  }

  @discardableResult
  open func setContentNoValidation(_ text: String) -> Bool {
    fatalError("HdlContent subclasses must override `setContentNoValidation(_:)`")
  }

  /// No-op by default (D9/D17: dialogs are a UI concern). `VhdlContent` does not override
  /// this; it exposes `lastValidationError` instead, for a caller to present however it likes.
  open func showErrors() {}
}
