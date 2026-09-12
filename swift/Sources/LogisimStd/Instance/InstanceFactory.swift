// InstanceFactory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceFactory and the parts of
// com.cburch.logisim.instance.Instance that survive D3),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ THE CHASSIS DECISION ════════════════════════════════════════════════════════════════════
//
// Upstream a component factory declares its connection points through **three** cooperating
// methods plus a mutable per-instance array:
//
//     configureNewInstance(Instance)          -> instance.setPorts(computePorts(attrs))
//     instanceAttributeChanged(Instance, attr)-> if attr is one of {…}: recomputeBounds();
//                                                                       setPorts(…)
//     InstanceComponent.computeEnds()         -> ports.map { it.toEnd(loc, attrs) }, diffed
//
// Every one of the ~350 implementations of the first two reads *only* the attribute set. There
// is no upstream component whose port list depends on anything else: not on the circuit, not
// on simulation state, not on call order. So the three collapse, with no loss of behaviour,
// into one pure function:
//
//     func ports(_ attributes: any AttributeSet) -> [Port]
//
// and the component recomputes-and-diffs whenever any attribute changes. What upstream's
// `instanceAttributeChanged` filter buys (recomputing only for the attributes that matter) is
// recovered exactly by the diff that `computeEnds` already performs: an attribute that does not
// affect the ports produces an identical array and therefore fires no `endChanged`. The
// filter's other two jobs are `recomputeBounds()`, automatic here, because `bounds` is derived
// from `offsetBounds(attributes)` on demand, and `fireInvalidated()`, which is a repaint
// request and belongs to M6.
//
// This is the single highest-leverage shape in the module: it removes ~700 lines of
// port-invalidation bookkeeping from the bulk port and removes the whole class of bug where a
// component forgets to list an attribute in its `instanceAttributeChanged`.
//
// `instanceAttributeChanged` is nevertheless **kept**, as an opt-in hook with a no-op default,
// because a handful of upstream components (memory contents resizing on a width change, and
// the components that poke their own `InstanceData`) do real work there that is not port or
// bounds related. Losing that would be losing behaviour.
//
// ── Protocol + base class, and why both ─────────────────────────────────────────────────────
//
// `InstanceFactory` is a protocol so that `as? any InstanceFactory` is the port's
// `instanceof InstanceFactory` and so that `InstanceState.factory` has a type. Its extension
// carries the defaults Java puts in the abstract base.
//
// `InstanceFactoryBase` is an `open class` conforming to it, because Java's `InstanceFactory`
// is not really an interface: it is *storage* (`attrs`/`defaults`/`bounds`/`portList`/
// `facingAttribute`/`shouldSnap`) configured by setters from a subclass constructor, and Swift
// protocols cannot hold storage. All 350 upstream components extend it, so the class earns its
// place; a component with genuinely dynamic bounds and ports overrides `offsetBounds`/`ports`
// and never calls the setters, exactly as upstream does.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `paintInstance`, `paintGhost`, `paintIcon`, `setIcon`, `setIconName`; D6/M6. Every
//     component file marks what upstream draws with a `// PAINT (M6):` comment; grep for it.
//   * `setKeyConfigurator`, `getKeyConfigurator`: the attribute-table key handler, UI (D9).
//   * `setInstanceLogger`; takes a `Class<?>` and instantiates it reflectively. No AOT-Swift
//     equivalent, and no witness in this port yet, so `getInstanceFeature`'s
//     `LoggableContract.class` arm is still unanswered.
//     (`setInstancePoker` WAS on this list. It is now `makePoker()`, and: since seam #15; it
//     is actually dispatched: see `InstanceFactoryFeatures` below.)
//   * `getHDLName`, `getHDLGenerator`, `providesSubCircuitMenu`; HDL/UI backlog (D11).
//   * `getDefaultToolTip`; localisation (D5's precedent).
//
// ── `getDisplayGetter` DOES come across, as a plain String. THIS IS THE SINGLE SOURCE ────────
//
// It used to be on the "not ported" list above, and that was a defect with a user-visible face,
// not a deferral: `getDisplayName()` fell through to `getName()`, the `_ID`, so the explorer
// sidebar, the component palette and `-tty stats` all printed programmer identifiers. The owner
// was looking at "DipSwitch", "NoConnect", "LedBar" and "Binary_to_BCD_converter" where 4.1.0
// says "DIP Switch", "Do not connect", "LED Bar" and "Binary to BCD". It was 105 of 105 of the
// remaining `--tty stats` failures.
//
// Upstream, the string comes from a `StringGetter` the constructor hands to
// `InstanceFactory(String name, StringGetter displayName, …)`, resolved out of a per-package
// `.properties` bundle. The port has no localisation, so the port's single source of truth is
// **the English string, passed as a literal at the same constructor call**:
//
//     super(_ID, S.getter("dipswitchComponent"))    ->    super.init(Self.id, displayName: "DIP Switch")
//     super(_ID)                                   ->    super.init(Self.id)
//
// One rule, no table, no lookup, and the fallback matches Java's exactly:
// `AbstractComponentFactory.getDisplayGetter()` is `constantGetter(getName())`, so a factory
// that passes nothing displays its `_ID`, which is right for `Adder`, `Pin`, `Ram` and the ~90
// other factories whose `_ID` already IS the English name.
//
// The literals are not transcribed from the Java source (which gives you the KEY, not the
// string). They are the measured output of `tools/valuebridge/NameBridge.java`, which asks the
// running 4.1.0 jar. `LogisimStdTests/DisplayNameOracleTests` pins every one of them against
// that measurement, so a wrong or missing literal fails a test rather than reaching the sidebar.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.instance.InstanceFactory`.
public protocol InstanceFactory: ComponentFactory {

  /// The connection points this factory declares for a component configured with `attributes`.
  ///
  /// Replaces `getPorts()` + `configureNewInstance`'s `instance.setPorts(…)` +
  /// `instanceAttributeChanged`'s `updatePorts(instance)`. See the file header.
  func ports(_ attributes: any AttributeSet) -> [Port]

  /// `propagate(InstanceState)`.
  ///
  /// D13: throws, because the kernel calls a component makes (`Value.create([Value])`,
  /// `Value.repeat`, `Value.set`, `BitWidth.create`) throw where Java throws catchably, and
  /// `Simulator` wraps propagation in `catch (Exception)` → `recordException`. A component
  /// that misbehaves must produce a circuit error the user sees, not a dead process.
  func propagate(_ state: any InstanceState) throws

  /// `setAttributes(Attribute<?>[], Object[])`, expressed as type-checked pairs.
  ///
  /// Empty means "this factory builds its own attribute set" (`createAttributeSet()` is
  /// overridden), which is exactly what Java's `attrs == null` branch means.
  var attributeTemplate: [AttributeBinding] { get }

  /// `getFacingAttribute()` / `setFacingAttribute`.
  var facingAttribute: Attribute<Direction>? { get }

  /// `getFeature(SHOULD_SNAP, …)`.
  var shouldSnap: Bool { get }

  /// `contains(Location, AttributeSet)`: hit testing in factory-relative coordinates.
  func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool

  /// `getInstanceFeature(Instance, Object)`.
  func instanceFeature(_ key: ComponentFeatureKey, _ component: StdInstanceComponent) -> Any?

  /// Swift witness-based replacement for Java's reflective `setInstancePoker(Class<?>)`.
  ///
  /// Declared on the protocol, not just on `InstanceFactoryBase`, because the default
  /// `instanceFeature` below has to be able to answer `.pokable` with it: see there.
  /// Upstream instantiates the poker class afresh on every `getFeature(Pokable.class)` call
  /// (`InstanceFactory.java:220`), i.e. once per mouse-down, and every poker in this port keeps
  /// per-gesture edit state (`RegisterPoker.curValue`, `ShiftRegisterPoker.loc`), so an
  /// implementation must return a **fresh instance** rather than a cached one.
  func makePoker() -> (any InstancePoker)?

  /// `instanceAttributeChanged(Instance, Attribute<?>)`, minus everything the chassis now does
  /// automatically. See the file header for what is left.
  func instanceAttributeChanged(_ component: StdInstanceComponent, _ attribute: AnyAttribute)
}

extension InstanceFactory {
  public var attributeTemplate: [AttributeBinding] { [] }
  public var facingAttribute: Attribute<Direction>? { nil }
  public var shouldSnap: Bool { true }
  public func ports(_ attributes: any AttributeSet) -> [Port] { [] }

  /// `InstanceFactory.contains`: `getOffsetBounds(attrs).contains(loc, 1)`.
  public func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    offsetBounds(attributes).contains(point, 1)
  }

  public func makePoker() -> (any InstancePoker)? { nil }

  public func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    InstanceFactoryFeatures.instanceFeature(key, of: self)
  }

  public func instanceAttributeChanged(
    _ component: StdInstanceComponent, _ attribute: AnyAttribute
  ) {}
}

// MARK: - getInstanceFeature

/// `InstanceFactory.getInstanceFeature(Instance, Object)`'s body, shared by the protocol
/// extension and by `InstanceFactoryBase` so the two cannot drift.
///
/// ── SEAM #15's third piece ──────────────────────────────────────────────────────────────────
///
/// Both of those used to be `nil` for every key. `makePoker()` was declared here, overridden by
/// fourteen factories, and called from **nowhere in the package**; `grep -rn makePoker
/// Sources/` returned only the declaration and the overrides. The consequence was not "the poke
/// highlight is missing": it was that `Component.feature(.pokable)` answered `nil` for every
/// stock component, so `LogisimUI`'s `Component.pokeCaret(_:)` returned `nil`, so `PokeTool`
/// never built a caret, so **no component in the app could be poked at all**. Every ported
/// poker, `Button`, `DipSwitch`, `Switch`, `Slider`, `Joystick`, `Keyboard`, `PortIo`, the four
/// flip-flops, `Register`, `Counter`, `ShiftRegister`, was unreachable.
///
/// Upstream (`InstanceFactory.java:218-226`) answers `Pokable.class` with
/// `new InstancePokerAdapter(instance.getComponent(), pokerClass)`. This port's `Pokable` lives
/// in `LogisimUI` (it is a tool-facing interface and D9 keeps it above this module), and
/// `LogisimUI`'s `Component.pokeCaret(_:)` already accepts either a `Pokable` **or** a bare
/// `InstancePoker` from this key and wraps the latter in `InstancePokerCaret`; its port of
/// `InstancePokerAdapter`. So handing back the poker itself is the shape the consumer was
/// already written for, and the adapter stays on the side of the boundary that owns carets.
///
/// `LoggableContract.class` → `InstanceLoggerAdapter` is upstream's other arm; `setInstanceLogger`
/// has no witness in this port yet, so that key is still unanswered and is listed as such in the
/// file header.
public enum InstanceFactoryFeatures {
  public static func instanceFeature(
    _ key: ComponentFeatureKey, of factory: any InstanceFactory
  ) -> Any? {
    // `pokerClass != null`; a factory that never called `setInstancePoker` answers `null`, and
    // upstream's `PokeTool` then simply finds nothing pokable at that location.
    guard key == .pokable else { return nil }
    return factory.makePoker()
  }
}

// MARK: - InstanceFactoryBase

/// The concrete base every stock component extends; Java's `InstanceFactory` with its stored
/// configuration.
///
/// Configure it from `init` with the `set…` methods, exactly as upstream does:
///
/// ```swift
/// public final class Adder: InstanceFactoryBase {
///   public init() {
///     super.init(Adder.id)
///     setAttributes([StdAttr.width.binding(BitWidth.known(8))])
///     setOffsetBounds(Bounds.create(-40, -20, 40, 40))
///     setPorts([...])
///   }
/// }
/// ```
open class InstanceFactoryBase: AbstractComponentFactory, InstanceFactory {

  private let factoryName: String
  private let factoryDisplayName: String?
  private var attributeBindings: [AttributeBinding] = []
  private var fixedOffsetBounds: Bounds = .empty
  private var fixedPorts: [Port] = []
  private var facing: Attribute<Direction>?
  private var snap: Bool = true

  /// `InstanceFactory(String name[, StringGetter displayName][, …, boolean requiresLabel,
  /// boolean requiresGlobalClock])`.
  ///
  /// `displayName` is the port of the `StringGetter` overloads. Pass it exactly where upstream's
  /// constructor passes `S.getter(…)`, with the English string that getter resolves to; omit it
  /// exactly where upstream omits it. `nil` reproduces
  /// `AbstractComponentFactory.getDisplayGetter()` = `constantGetter(getName())`. See the file
  /// header for why this is the port's one source of truth for the string.
  public init(
    _ name: String,
    displayName: String? = nil,
    requiresLabel: Bool = false,
    requiresGlobalClock: Bool = false
  ) {
    self.factoryName = name
    self.factoryDisplayName = displayName
    super.init(requiresLabel: requiresLabel, requiresGlobalClock: requiresGlobalClock)
  }

  // MARK: Configuration (upstream's setters)

  /// `setAttributes(Attribute<?>[], Object[])`.
  public func setAttributes(_ bindings: [AttributeBinding]) {
    attributeBindings = bindings
  }

  /// `setOffsetBounds(Bounds)`.
  public func setOffsetBounds(_ bounds: Bounds) {
    fixedOffsetBounds = bounds
  }

  /// `setPorts(Port[])`.
  public func setPorts(_ ports: [Port]) {
    fixedPorts = ports
  }

  /// `setFacingAttribute(Attribute<Direction>)`.
  public func setFacingAttribute(_ attribute: Attribute<Direction>) {
    facing = attribute
  }

  /// `setShouldSnap(boolean)`.
  public func setShouldSnap(_ value: Bool) {
    snap = value
  }

  // MARK: InstanceFactory

  open var attributeTemplate: [AttributeBinding] { attributeBindings }

  open var facingAttribute: Attribute<Direction>? { facing }

  open var shouldSnap: Bool { snap }

  /// The stored port list. Override for a factory whose ports depend on its attributes; that
  /// is the direct replacement for upstream's `updatePorts(Instance)`.
  open func ports(_ attributes: any AttributeSet) -> [Port] { fixedPorts }

  /// Java declares `propagate` `abstract`, so the compiler makes it uncallable. Swift has no
  /// equivalent, and no `.circ` file can reach this; a factory that reaches propagation is one
  /// this port wrote. D13's "genuine programmer error" carve-out: trap.
  open func propagate(_ state: any InstanceState) throws {
    fatalError("\(factoryName): InstanceFactoryBase subclasses must override `propagate`")
  }

  open func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    offsetBounds(attributes).contains(point, 1)
  }

  open func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    InstanceFactoryFeatures.instanceFeature(key, of: self)
  }

  open func instanceAttributeChanged(
    _ component: StdInstanceComponent, _ attribute: AnyAttribute
  ) {}

  /// Swift witness-based replacement for Java's reflective `setInstancePoker(Class<?>)`.
  /// See the protocol requirement for why it must return a fresh instance.
  open func makePoker() -> (any InstancePoker)? { nil }

  // MARK: ComponentFactory

  open override var name: String { factoryName }

  /// `InstanceFactory.getDisplayName()` = `getDisplayGetter().toString()`, where the getter is
  /// the one the constructor stored: or `constantGetter(getName())` when it stored none.
  open override var displayName: String { factoryDisplayName ?? factoryName }

  /// `createAttributeSet()`: `AttributeSets.fixedSet(attrs, defaults)`, or `EMPTY` when the
  /// factory declared none. Override to supply a hand-written `AbstractAttributeSet` (gates and
  /// `Constant` both do); leave `attributeTemplate` empty when you do, which is what upstream's
  /// `attrs == null` state means.
  open override func createAttributeSet() -> any AttributeSet {
    attributeBindings.isEmpty ? AttributeSets.empty : AttributeSets.fixedSet(attributeBindings)
  }

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Upstream throws `RuntimeException("offset bounds unknown")` when `bounds == null`, but the
  /// constructor assigns `Bounds.EMPTY_BOUNDS`, so `bounds` is never null and the throw is dead
  /// code. Not ported.
  open override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    fixedOffsetBounds
  }

  /// The port's stand-in for the `ClassCastException` a factory with a bespoke
  /// `AbstractAttributeSet` raises the first time it casts (`(GateAttributes) attrs`).
  ///
  /// Java's cast is spread over `getOffsetBounds`, `computePorts`, `contains` and `propagate`,
  /// three of which cannot throw in Swift because the protocol they satisfy does not. Hoisting
  /// the check to construction keeps the *observable* behaviour, a mismatched set is a file
  /// error, not a silently wrong component, while letting those three degrade to a defined
  /// value if they are somehow reached anyway. Reachable from a `.circ` file whose repair pass
  /// retargets a component at a foreign factory, so it throws (D13).
  ///
  /// Default: accept anything. Override in every factory that overrides `createAttributeSet()`
  /// with a hand-written set.
  open func validateAttributeSet(_ attributes: any AttributeSet) throws {}

  /// `createComponent(Location, AttributeSet)`.
  open override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    try validateAttributeSet(attributes)
    return try StdInstanceComponent(factory: self, location: location, attributes: attributes)
  }

  /// `getFeature(Object, AttributeSet)`. `KeyConfigurator.class` is a UI key and is not ported.
  open override func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any? {
    switch key {
    case .facingAttribute: return facing
    case .shouldSnap: return snap
    default: return super.feature(key, attributes)
    }
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// Bug-for-bug: when the factory declared an attribute template, upstream scans it and
  /// returns `null` for anything not in it; it does **not** fall through to the cached-clone
  /// branch. Preserved; the `.circ` writer's "is this at its default?" test depends on it.
  open override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if !attributeBindings.isEmpty {
      for binding in attributeBindings where binding.attribute === attribute {
        return binding.value
      }
      return nil
    }
    return super.defaultAttributeValue(attribute, version: version)
  }
}
