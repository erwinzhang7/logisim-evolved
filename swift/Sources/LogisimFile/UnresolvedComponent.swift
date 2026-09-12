// UnresolvedComponent.swift: part of logisim-evolved.
//
// No upstream counterpart. Derived from logisim-evolution only in the sense that it exists to
// repair a behaviour of it. https://github.com/logisim-evolution/logisim-evolution is
// GPL-3.0-only; this port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── D8: an unknown `<comp>` round-trips instead of being dropped ─────────────────────────────
//
// Upstream, a `<comp lib="6" name="UART">` whose library did not resolve is discarded by
// `XmlReader` and is gone from the next save. There is no placeholder mechanism anywhere in the
// codebase, so the loss is silent and permanent; open a file with a `jar#` library on a machine
// that cannot load the jar, save it, and the components are simply not there any more. Five
// files in the corpus reference `jar#logisim-uart.jar#…`, and D11 makes that gap permanent for
// this port, so without D8 we would be *worse* than upstream rather than merely equal.
//
// `MissingLibrary` handles the `<lib>` half. This is the `<comp>` half: the element is kept
// verbatim, its attributes are parsed only as far as "a name and an unexamined string", and the
// writer re-emits exactly what it read.
//
// D8 is called out in `decisions.md` as something that "changes `Circuit`'s data model, so it
// cannot be retrofitted cheaply", which is why it is built here alongside `Circuit` rather than
// bolted onto the loader later. The consequence in the model is small but structural: `Circuit`
// holds `any Component`, and one of the conformers is a thing that cannot be simulated, drawn or
// meaningfully queried. Every consumer must therefore tolerate a component with no ends, empty
// bounds and an attribute set of pure strings.

import Foundation
import LogisimKernel

// MARK: - Attribute set

/// An attribute set for a component we could not resolve: every `<a name= val=>` is kept as an
/// unexamined string, in file order.
///
/// **Deliberately unlike `FixedAttributeSet`.** That one throws `attributeAbsent` for a name it
/// does not hold, which is right for a real component; a `.circ` naming an attribute the factory
/// does not define is a malformed file, and D13 says surface it. Here there is no factory and
/// therefore no definition to violate, so an unknown name is *the expected case* and is accepted
/// by creating the attribute. Rejecting it would defeat the entire purpose.
///
/// Values are `.opaque(String)`, whose codec is the one kernel codec that does not scrub its text
/// in either direction (`Attributes.forOpaque`). That is what makes the round-trip byte-exact
/// rather than merely semantically equal.
public final class OpaqueAttributeSet: AbstractAttributeSet {
  private var attributeOrder: [Attribute<OpaqueAttributeValue>] = []
  private var storage: [String: AttributeValue] = [:]

  public init(bindings: [(name: String, value: String)] = []) {
    super.init()
    for binding in bindings {
      setOpaqueValue(binding.value, forName: binding.name)
    }
  }

  public override var attributes: [AnyAttribute] { attributeOrder }

  /// Looks up by *name*, not by identity: an `OpaqueAttributeSet` mints its own attribute
  /// objects, so no caller can hold the identical one.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    storage[attribute.name]
  }

  /// Accepts any attribute, creating it when absent. See the type's doc comment for why this
  /// deviates from `FixedAttributeSet` on purpose.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ value: AttributeValue?
  ) throws {
    let oldValue = storage[attribute.name]
    if attributeOrder.first(where: { $0.name == attribute.name }) == nil {
      attributeOrder.append(Attributes.forOpaque(attribute.name))
    }
    if let value {
      storage[attribute.name] = value
    } else {
      storage.removeValue(forKey: attribute.name)
    }
    fireAttributeValueChanged(attribute, value: value, oldValue: oldValue)
  }

  /// The reader's entry point: record `<a name="x" val="y"/>` with no interpretation at all.
  public func setOpaqueValue(_ value: String, forName name: String) {
    if attributeOrder.first(where: { $0.name == name }) == nil {
      attributeOrder.append(Attributes.forOpaque(name))
    }
    storage[name] = .opaque(value)
  }

  /// The writer's entry point: the exact text that was read, in the order it was read.
  public var opaqueBindings: [(name: String, value: String)] {
    attributeOrder.compactMap { attribute in
      guard case .opaque(let raw)? = storage[attribute.name] else { return nil }
      return (name: attribute.name, value: raw)
    }
  }

  public override func containsAttribute(_ attribute: AnyAttribute) -> Bool {
    storage[attribute.name] != nil
  }

  public override func attribute(named name: String) -> AnyAttribute? {
    attributeOrder.first { $0.name == name }
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    OpaqueAttributeSet()
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let other = destination as? OpaqueAttributeSet else {
      preconditionFailure("OpaqueAttributeSet can only copy into an OpaqueAttributeSet")
    }
    other.attributeOrder = attributeOrder
    other.storage = storage
  }
}

// MARK: - Factory

/// The factory of a component whose library did not resolve.
///
/// It exists because `Component.factory` is not optional and because the writer needs a `name` to
/// put back. It creates nothing that can be simulated, and says so: `offsetBounds` is empty and
/// none of the `instanceof` capability flags are set, so the label rules, the clock list and the
/// subcircuit-usage map all correctly ignore an unresolved component.
public final class UnresolvedComponentFactory: AbstractComponentFactory {
  private let componentName: String

  /// The `<lib>` handle the `<comp>` carried, so the writer puts the same one back rather than
  /// recomputing an index into a library list that does not contain this component.
  public let sourceLibraryReference: String?

  /// The unresolved library this component's name was asked of, when there was one. `nil` for a
  /// `<comp>` naming a tool that a *resolvable* library did not turn out to have, which is the
  /// other way a component fails to resolve, and which upstream also drops.
  public weak var missingLibrary: MissingLibrary?

  /// The library the reader's `findLibrary(_:)` actually returned for `sourceLibraryReference`.
  ///
  /// **This is what makes the preserved element re-emittable.** `sourceLibraryReference` is the
  /// `lib="n"` handle as it appeared *in the input document*, and that number is not stable:
  /// `XmlWriter.fromLibrary` renumbers every library from 0 in write order, and the reader's own
  /// migration repairs insert libraries (`repairForFPArithmetic` adds `#FPArithmetic` and points
  /// its components at the *string* `lib="float"`). Re-emitting the handle verbatim therefore
  /// produces a `<comp>` pointing at the wrong library, or at none, and the component is then
  /// destroyed by the *next* load, one pass later than upstream destroys it but just as
  /// permanently. Measured before this field existed, on
  /// `3.7.2__case-321.circ`: 101 components in, 101 out, **95** after a second
  /// open-and-save.
  ///
  /// Weak, per D3: `LogisimFile` owns its libraries and a component must not keep one alive.
  /// A cleared reference simply falls back to the verbatim handle, which is no worse than not
  /// having recorded it.
  public weak var sourceLibrary: Library?

  public init(
    name: String,
    sourceLibraryReference: String? = nil,
    missingLibrary: MissingLibrary? = nil,
    sourceLibrary: Library? = nil
  ) {
    self.componentName = name
    self.sourceLibraryReference = sourceLibraryReference
    self.missingLibrary = missingLibrary
    self.sourceLibrary = sourceLibrary
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  public override var name: String { componentName }

  public override func createAttributeSet() -> any AttributeSet { OpaqueAttributeSet() }

  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    UnresolvedComponent(
      factory: self, location: location, attributes: attributes)
  }

  /// Empty, and honestly so: nothing is known about the shape of a component whose code we do
  /// not have. A renderer at M6 draws a placeholder box from the element's own `loc`, not from
  /// this.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds { Bounds.empty }

  /// `getDefaultAttributeValue`: always `nil`, so the writer never treats an opaque attribute as
  /// omissible-because-default and every one is written back out. That is the whole guarantee.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    nil
  }
}

// MARK: - Component

/// A placement record for a `<comp>` we could not resolve.
///
/// `final class`, not `Equatable`/`Hashable`: D4, like every other component. It is a real
/// member of `Circuit.nonWires`, so it participates in ordering and in `contains`, and it is
/// deliberately inert everywhere else.
public final class UnresolvedComponent: Component {

  public private(set) var factory: any ComponentFactory

  public let location: Location

  public let attributeSet: any AttributeSet

  /// The `<comp>` element exactly as it was read, detached from its document.
  ///
  /// This is the authority for what gets written back. The parsed `location` and attribute set
  /// exist so the model can answer ordinary questions (where is it, what is it called) without
  /// re-walking XML; they are never the source of truth for serialisation.
  public private(set) var rawElement: XMLElement?

  public init(
    factory: any ComponentFactory,
    location: Location,
    attributes: any AttributeSet,
    rawElement: XMLElement? = nil
  ) {
    self.factory = factory
    self.location = location
    self.attributeSet = attributes
    self.rawElement = rawElement
  }

  /// Records the `<comp>` element verbatim.
  ///
  /// A detached copy is taken: the source document is released when the load finishes, and
  /// Foundation's DOM nodes do not outlive their document safely. `MissingLibrary.absorb` takes
  /// the same precaution for the same reason.
  public func absorb(componentElement element: XMLElement) {
    guard let duplicate = element.copy() as? XMLElement else { return }
    duplicate.detach()
    rawElement = duplicate
  }

  public func setFactory(_ factory: any ComponentFactory) {
    self.factory = factory
  }

  /// Empty. An unresolved component has no known geometry, and inventing one would put a
  /// placeholder into `Circuit.bounds` and change what a saved viewport looks like.
  public var bounds: Bounds { Bounds.empty }

  /// No ends: with no code for the component there is no port list, so it connects to nothing.
  /// M3's connectivity will therefore skip it, which is correct; a wire touching an unresolved
  /// component must not be assumed to be driven by it.
  public var ends: [EndData] { [] }

  /// Traps rather than throws, and that is D13-correct: no index is valid, so any call is a
  /// programmer error reached by iterating `ends` incorrectly, not something a file can cause.
  public func end(at index: Int) -> EndData {
    preconditionFailure(
      "unresolved component \(factory.name) has no ends; index \(index) requested")
  }

  public func contains(_ point: Location) -> Bool { false }

  public func endsAt(_ point: Location) -> Bool { false }

  public func feature(_ key: ComponentFeatureKey) -> Any? { nil }

  /// No events are ever fired, so there is nothing to subscribe to; the same answer `Wire`
  /// gives, spelled the same way (D3: "I do not notify" is "no token to hold").
  @discardableResult
  public func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription? {
    nil
  }
}

extension UnresolvedComponent: CustomStringConvertible {
  public var description: String {
    "UnresolvedComponent[\(factory.name) @ \(location)]"
  }
}
