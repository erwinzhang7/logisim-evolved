// ComponentFactory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.{ComponentFactory,
// AbstractComponentFactory} and com.cburch.logisim.data.AttributeDefaultProvider),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── What did not come across, and why ───────────────────────────────────────────────────────
//
//   * `drawGhost`, `paintIcon`, `getDisplayGetter`; AWT drawing and localisation. D6 routes all
//     drawing through `RenderScene` in `LogisimRender`; D9 keeps both out of the model. M6.
//   * `getHDLGenerator`, `getHDLName`, `getHDLTopName`, `isHDLSupportedComponent`,
//     `checkForGatedClocks`, `clockPinIndex`: the HDL generation surface (~17k LOC upstream),
//     which `objectives.md` places in the parity backlog behind D11's FPGA decision. Declaring
//     stubs now would freeze a shape before the milestone that has to satisfy it.
//   * `getDisplayName()` is kept, because the loader reports unresolvable components by display
//     name, but it defaults to `name` instead of resolving a `StringGetter`.
//
// ── The `instanceof` stand-ins ──────────────────────────────────────────────────────────────
//
// `Circuit` branches on `factory instanceof Tunnel | Pin | Clock | Rom | SubcircuitFactory |
// VhdlEntity | DynamicElementProvider` in `mutatorAdd`, `mutatorRemove`, `isCorrectLabel` and
// `isDoubleMapped`. Those classes are M3–M5 work, and none of them exists yet, but the branches
// are *load-bearing at load time* (duplicate-label clearing runs while a `.circ` is being read),
// so they cannot be dropped and cannot be deferred.
//
// They are expressed as default-`false` capability properties on the factory. Each is named after
// the exact upstream test it replaces, so when `Tunnel` and `Pin` are ported at M5 they override
// one property each and every branch here starts working with no edits at the call sites. This is
// a deviation in mechanism, not in behaviour.

import Foundation
import LogisimKernel

/// The key space of `ComponentFactory.getFeature(Object, AttributeSet)`.
///
/// Java uses three `new Object()` sentinels (`SHOULD_SNAP`, `TOOL_TIP`, `FACING_ATTRIBUTE_KEY`);
/// this is the same idea with a debuggable name attached.
public struct ComponentFactoryFeatureKey: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }

  /// `ComponentFactory.SHOULD_SNAP`: returns a `Bool`.
  public static let shouldSnap = ComponentFactoryFeatureKey("SHOULD_SNAP")
  /// `ComponentFactory.TOOL_TIP`: returns a `String`.
  public static let toolTip = ComponentFactoryFeatureKey("TOOL_TIP")
  /// `ComponentFactory.FACING_ATTRIBUTE_KEY`; returns the `Attribute<Direction>` that carries
  /// this factory's facing.
  public static let facingAttribute = ComponentFactoryFeatureKey("FACING_ATTRIBUTE_KEY")

  public var description: String { rawValue }
}

/// `com.cburch.logisim.data.AttributeDefaultProvider`.
///
/// The value is returned in storage form (`AttributeValue`) rather than as `V`, because every
/// caller, the `.circ` writer deciding whether an attribute is at its default, and therefore
/// omissible, works without knowing `V`. `defaultValue(of:version:)` below recovers the typed
/// value when the caller does know it.
public protocol AttributeDefaultProvider: AnyObject {
  func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue?

  func isAllDefaultValues(_ attributes: any AttributeSet, version: LogisimVersion) -> Bool
}

extension AttributeDefaultProvider {
  /// Typed convenience over `defaultAttributeValue`.
  public func defaultValue<V>(of attribute: Attribute<V>, version: LogisimVersion) -> V? {
    defaultAttributeValue(attribute, version: version).flatMap(attribute.decode)
  }
}

/// `com.cburch.logisim.comp.ComponentFactory`.
public protocol ComponentFactory: AttributeDefaultProvider {
  /// `getName()`: the `.circ` `<comp name="…">` token. Never localised.
  var name: String { get }

  /// `getDisplayName()`.
  var displayName: String { get }

  /// `createAttributeSet()`.
  func createAttributeSet() -> any AttributeSet

  /// `createComponent(Location, AttributeSet)`.
  ///
  /// D13: this throws where upstream does not. Every implementation reads attributes out of the
  /// set it is handed, and an attribute that is absent or of the wrong kind is reachable from a
  /// malformed `.circ` file. Java would throw an unchecked exception that the loader catches and
  /// reports as a file error; the Swift equivalent of "catchable" is `throws`.
  func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component

  /// `getOffsetBounds(AttributeSet)`.
  func offsetBounds(_ attributes: any AttributeSet) -> Bounds

  /// `activeOnHigh(AttributeSet)`.
  func activeOnHigh(_ attributes: any AttributeSet) -> Bool

  /// `hasThreeStateDrivers(AttributeSet)`.
  func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool

  /// `getFeature(Object, AttributeSet)`.
  func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any?

  /// `requiresGlobalClock()`.
  var requiresGlobalClock: Bool { get }

  /// `requiresNonZeroLabel()`.
  var requiresNonZeroLabel: Bool { get }

  /// `isSocComponent()`.
  var isSocComponent: Bool { get }

  /// `removeComponent(Circuit, Component, CircuitState)`.
  ///
  /// `CircuitState` is M3, so the third argument is `AnyObject?` for now; every stock factory
  /// ignores it (`AbstractComponentFactory` calls it "dummy factory") and the handful that do
  /// not are memory/IO components in M5.
  func removeComponent(from circuit: Circuit, component: any Component, state: AnyObject?)

  // MARK: instanceof stand-ins — see the file header

  /// `factory instanceof Tunnel`. Tunnels are exempt from every label-uniqueness rule.
  var isTunnel: Bool { get }

  /// `factory instanceof Pin`.
  var isPin: Bool { get }

  /// `factory instanceof Clock`. `Circuit` keeps a separate list of these.
  var isClock: Bool { get }
}

// `factory instanceof SubcircuitFactory` needs no stand-in: `SubcircuitFactory` is a real
// protocol in `LibraryModel.swift`, so the test is a plain `as? any SubcircuitFactory`.

extension ComponentFactory {
  public var displayName: String { name }
  public func createAttributeSet() -> any AttributeSet { AttributeSets.empty }
  public func offsetBounds(_ attributes: any AttributeSet) -> Bounds { Bounds.empty }
  public func activeOnHigh(_ attributes: any AttributeSet) -> Bool { true }
  public func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool { false }
  public func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any? { nil }
  public var requiresGlobalClock: Bool { false }
  public var requiresNonZeroLabel: Bool { false }
  public var isSocComponent: Bool { false }
  public func removeComponent(
    from circuit: Circuit, component: any Component, state: AnyObject?
  ) {}
  public var isTunnel: Bool { false }
  public var isPin: Bool { false }
  public var isClock: Bool { false }
  public func isAllDefaultValues(
    _ attributes: any AttributeSet, version: LogisimVersion
  ) -> Bool { false }
}

/// `com.cburch.logisim.comp.AbstractComponentFactory`; the base every stock factory extends.
///
/// Subclasses must override `name` and `createComponent`; everything else has upstream's default.
open class AbstractComponentFactory: ComponentFactory {

  /// Upstream's lazily built, permanently cached `defaultSet`.
  private var defaultSet: (any AttributeSet)?

  private let requiresLabel: Bool
  private let requiresGlobalClockConnection: Bool

  public init(requiresLabel: Bool = false, requiresGlobalClock: Bool = false) {
    self.requiresLabel = requiresLabel
    self.requiresGlobalClockConnection = requiresGlobalClock
  }

  open var name: String {
    fatalError("AbstractComponentFactory subclasses must override `name`")
  }

  /// `toString()` returns `getName()`.
  open var displayName: String { name }

  open func createAttributeSet() -> any AttributeSet { AttributeSets.empty }

  open func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    fatalError("AbstractComponentFactory subclasses must override `createComponent`")
  }

  open func offsetBounds(_ attributes: any AttributeSet) -> Bounds { Bounds.empty }

  open func activeOnHigh(_ attributes: any AttributeSet) -> Bool { true }

  open func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool { false }

  open func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any? { nil }

  open var requiresGlobalClock: Bool { requiresGlobalClockConnection }

  open var requiresNonZeroLabel: Bool { requiresLabel }

  open var isSocComponent: Bool { false }

  open func removeComponent(
    from circuit: Circuit, component: any Component, state: AnyObject?
  ) {
    // "dummy factory", upstream's own comment.
  }

  open var isTunnel: Bool { false }
  open var isPin: Bool { false }
  open var isClock: Bool { false }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// Bug-for-bug: upstream ignores `ver` entirely here and caches one attribute set forever, so
  /// the "default" a 2.7.0 file is compared against is whatever the *current* build's
  /// `createAttributeSet()` produces. Factories that genuinely need version-dependent defaults
  /// override this (e.g. `Pin.appearance` for pre-4.0 files, which is the pass1/pass2 delta the
  /// migration oracle shows).
  open func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    let set: any AttributeSet
    if let cached = defaultSet {
      set = cached
    } else {
      // Java: `(AttributeSet) createAttributeSet().clone()`.
      let fresh = createAttributeSet().copy()
      defaultSet = fresh
      set = fresh
    }
    return set.rawValue(attribute)
  }

  open func isAllDefaultValues(
    _ attributes: any AttributeSet, version: LogisimVersion
  ) -> Bool {
    false
  }
}
