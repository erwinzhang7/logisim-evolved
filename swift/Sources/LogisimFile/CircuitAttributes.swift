// CircuitAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── The two halves, and why they must not be confused ───────────────────────────────────────
//
// Upstream's `CircuitAttributes` is two different things wearing one class name, and the `.circ`
// codec depends on telling them apart:
//
//   * The **static** set: `AttributeSets.fixedSet(STATIC_ATTRS, STATIC_DEFAULTS)`, built by
//     `createBaseAttrs` and owned by the `Circuit`. This is what `<circuit>`'s own `<a>` children
//     serialise (`XmlWriter.java:279`), and what `Circuit.getName()` reads.
//   * The **instance** set: this class, one per placed subcircuit component. It stores five
//     values of its own (facing, label, label location, label font, label visibility) and
//     *forwards everything else to the source circuit's static set*. That forwarding is why a
//     `<comp>` for a subcircuit can name `circuit`, `clabel` or `appearance` at all.
//
// `isToSave` is where the two halves meet: it returns false for every static attribute, so the
// forwarded values are readable through an instance but are never written twice.
//
// ── D9: AppPreferences does not come across ─────────────────────────────────────────────────
//
// `createBaseAttrs` calls `AppPreferences.getDefaultCircuitAppearance()` and the `Circuit`
// constructor calls `AppPreferences.NAMED_CIRCUIT_BOXES_FIXED_SIZE.getBoolean()`. D9 forbids the
// model reaching into preferences, so both arrive as parameters whose defaults are the shipped
// preference defaults; `APPEAR_EVOLUTION` (`AppPreferences.java:802`) and `true`
// (`AppPreferences.java:790`). Behaviour on a default install is therefore identical, and the UI
// layer overrides them when the user has changed the preference.
//
// Note the asymmetry this preserves, which is easy to "tidy" into a bug: a *new* circuit gets
// `APPEAR_EVOLUTION`, but `DEFAULT_STATIC_ATTRIBUTES`, the provider the writer compares against
// when deciding whether an attribute is omissible, forces `APPEAR_CLASSIC`
// (`CircuitAttributes.java:44`). So `appearance="logisim_evolution"` is written out for a fresh
// circuit precisely because the two disagree.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `MyListener.circuitAppearanceChanged` and `StaticListener`'s dialogs/HDL syntax checks.
//     `CircuitAppearance` is M6, `SyntaxChecker` reaches `AppPreferences.HdlType` (D9), and
//     `OptionPane` is AWT. `StaticListener`'s *model* effect, firing `ACTION_SET_NAME` and
//     `ACTION_CHECK_NAME`, is kept, on `Circuit.setName`.
//   * `getPinInstances`/`setPinInstances` are typed `[InstanceComponent]` rather than
//     `Instance[]`, because D3 deletes the `Instance` facade. They stay empty until
//     `computePorts` becomes portable at M6 (it reads the appearance's port offsets).

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.CircuitAttributes`; the *instance* attribute set of a placed
/// subcircuit, plus the static attribute vocabulary shared with the `Circuit` itself.
public final class CircuitAttributes: AbstractAttributeSet {

  // MARK: - Attribute vocabulary

  /// `NAME_ATTR`.
  public static let nameAttribute: Attribute<String> = Attributes.forString("circuit")

  /// `LABEL_LOCATION_ATTR`.
  public static let labelLocationAttribute: Attribute<Direction> =
    Attributes.forDirection("labelloc")

  /// `CIRCUIT_LABEL_ATTR`.
  public static let circuitLabelAttribute: Attribute<String> = Attributes.forString("clabel")

  /// `CIRCUIT_LABEL_FACING_ATTR`.
  public static let circuitLabelFacingAttribute: Attribute<Direction> =
    Attributes.forDirection("clabelup")

  /// `CIRCUIT_LABEL_FONT_ATTR`.
  public static let circuitLabelFontAttribute: Attribute<FontSpec> =
    Attributes.forFont("clabelfont")

  /// `CIRCUIT_IS_VHDL_BOX`. Declared by upstream but absent from both `STATIC_ATTRS` and
  /// `INSTANCE_ATTRS`, so it belongs to no set; it is read by the VHDL box appearance code.
  /// Kept so nothing has to invent the token later.
  public static let circuitIsVhdlBox: Attribute<Bool> = Attributes.forBoolean("circuitvhdl")

  /// `NAMED_CIRCUIT_BOX_FIXED_SIZE` (`CircuitAttributes.java:174-175`).
  ///
  /// This declaration carries **no default**; `Attributes.forBoolean` takes only a name, in Java
  /// as here. Three separate values have been mistaken for "the default" of this attribute, and
  /// they are all upstream, all deliberate, and all different. Read them together before touching
  /// any one of them:
  ///
  ///   1. **`false`**: `STATIC_DEFAULTS` (`CircuitAttributes.java:206-208`, sixth slot), mirrored
  ///      by `staticDefaults` below. What a set built from these bindings starts out holding.
  ///   2. **`true`**: `AppPreferences.NAMED_CIRCUIT_BOXES_FIXED_SIZE`
  ///      (`AppPreferences.java:623-624`, `new PrefMonitorBoolean("namedBoxesFixed", true)`),
  ///      mirrored by `preferenceDefaultNamedCircuitBoxFixedSize`. `Circuit`'s constructor
  ///      (`Circuit.java:253-255`) overwrites (1) with it, so *every circuit built in memory* is
  ///      fixed-size. (1) is only ever observed by a caller of `createBaseAttrs` directly.
  ///   3. **`false` again, on load**; `XmlCircuitReader.java:187-189` forces it back to `false`
  ///      for any non-empty `<circuit>` that did not carry a `circuitnamedboxfixedsize` element,
  ///      undoing (2) for files that predate the attribute. Ported at
  ///      `XmlCircuitReader.swift`'s `buildCircuit`.
  ///
  /// A fourth value exists and is *not* a default at all: `CircuitAppearance
  /// .isNamedBoxShapedFixedSize()` (`CircuitAppearance.java:331-337`) answers **`true`** when the
  /// static set lacks the attribute entirely. That is a read-side fallback for a set this file
  /// never produces, not a default: see the `?? true` at `CircuitAppearance.swift` and
  /// `SubcircuitPainter.swift`.
  ///
  /// Measured, not argued: flipping (1) to `true` fails
  /// `testCreateBaseAttrsAppliesDefaultsThenOverrides`; flipping (3) to `true` takes the
  /// round-trip gate's canonical column from 539/0 to 326/213, since every pre-attribute file
  /// then gains an `<a name="circuitnamedboxfixedsize" val="true"/>` the jar does not write.
  public static let namedCircuitBoxFixedSize: Attribute<Bool> =
    Attributes.forBoolean("circuitnamedboxfixedsize")

  /// `APPEAR_CLASSIC`: the same option object as `StdAttr.APPEAR_CLASSIC`.
  public static let appearClassic = StdAttr.appearClassic
  /// `APPEAR_FPGA`. Serialises as `"evolution"`; see `StdAttr` for why that is not a typo.
  public static let appearFpga = StdAttr.appearFpga
  /// `APPEAR_EVOLUTION`. Serialises as `"logisim_evolution"`.
  public static let appearEvolution = StdAttr.appearEvolution
  /// `APPEAR_CUSTOM`: declared only here, not in `StdAttr`.
  public static let appearCustom = AttributeOption(name: "custom")

  /// `APPEARANCE_ATTR`. Four choices, one more than `StdAttr.APPEARANCE`: a circuit may also be
  /// `custom`, which is what a hand-edited appearance sets.
  ///
  /// Note this is a *different attribute identity* from `StdAttr.appearance` despite sharing the
  /// `.circ` token `"appearance"`; comparisons against it must be by identity, never by name.
  public static let appearance: Attribute<AttributeOption> = Attributes.forOption(
    "appearance", choices: [appearClassic, appearFpga, appearEvolution, appearCustom])

  /// Spelled-out alias of `appearance`, for call sites that want the `_ATTR` suffix upstream
  /// uses to distinguish it from the option constants beside it.
  public static var appearanceAttribute: Attribute<AttributeOption> { appearance }

  /// `SIMULATION_FREQUENCY`.
  public static let simulationFrequency: Attribute<Double> =
    Attributes.forDouble("simulationFrequency")

  /// `DOWNLOAD_FREQUENCY`.
  public static let downloadFrequency: Attribute<Double> =
    Attributes.forDouble("downloadFrequency")

  /// `DOWNLOAD_BOARD`.
  public static let downloadBoard: Attribute<String> = Attributes.forString("downloadBoard")

  /// `STATIC_ATTRS`, in declaration order, which is also the order `<circuit>`'s `<a>` children
  /// are emitted in.
  public static let staticAttributes: [AnyAttribute] = [
    nameAttribute,
    circuitLabelAttribute,
    circuitLabelFacingAttribute,
    circuitLabelFontAttribute,
    appearance,
    namedCircuitBoxFixedSize,
    simulationFrequency,
    downloadFrequency,
    downloadBoard,
  ]

  /// `STATIC_DEFAULTS`, paired positionally with `staticAttributes`.
  ///
  /// Java writes these as a bare `Object[]`, so the pairing is unchecked; `AttributeBinding`
  /// makes it type-checked at the point of construction.
  public static let staticDefaults: [AttributeBinding] = [
    nameAttribute.binding(""),
    circuitLabelAttribute.binding(""),
    circuitLabelFacingAttribute.binding(.east),
    circuitLabelFontAttribute.binding(StdAttr.defaultLabelFont),
    appearance.binding(appearClassic),
    namedCircuitBoxFixedSize.binding(false),
    simulationFrequency.binding(-1.0),
    downloadFrequency.binding(-1.0),
    downloadBoard.binding(""),
  ]

  /// `INSTANCE_ATTRS`.
  public static let instanceAttributes: [AnyAttribute] = [
    StdAttr.facing,
    StdAttr.label,
    labelLocationAttribute,
    StdAttr.labelFont,
    StdAttr.labelVisibility,
    nameAttribute,
    circuitLabelAttribute,
    circuitLabelFacingAttribute,
    circuitLabelFontAttribute,
  ]

  /// The shipped default of `AppPreferences.DefaultAppearance`, resolved through
  /// `getDefaultCircuitAppearance()`. See the file header for why this is a constant here.
  public static let preferenceDefaultCircuitAppearance = appearEvolution

  /// The shipped default of `AppPreferences.NAMED_CIRCUIT_BOXES_FIXED_SIZE`.
  public static let preferenceDefaultNamedCircuitBoxFixedSize = true

  // MARK: - The default provider the writer compares against

  /// `CircuitAttributes.defaultStaticAttributeProvider`.
  ///
  /// Bug-for-bug in two ways, both load-bearing for the writer:
  ///   * `ver` is ignored, so a 2.7.0 file's attributes are compared against today's defaults.
  ///   * a *fresh* set is built on every call, and `APPEARANCE_ATTR` is forced to
  ///     `APPEAR_CLASSIC`; not to the preference the circuit was actually created with.
  public final class DefaultStaticAttributeProvider: AttributeDefaultProvider {
    public init() {}

    public func defaultAttributeValue(
      _ attribute: AnyAttribute, version: LogisimVersion
    ) -> AttributeValue? {
      let set = AttributeSets.fixedSet(CircuitAttributes.staticDefaults)
      // Java calls `setValue`, which cannot fail on a set it just built from these very
      // attributes. D13 keeps the `throws` visible rather than swallowing it silently; a
      // failure here would be a port defect, not a file defect, so it is reported as one.
      do {
        try set.setValue(CircuitAttributes.appearance, CircuitAttributes.appearClassic)
      } catch {
        assertionFailure("static default set rejected its own appearance attribute: \(error)")
      }
      return set.rawValue(attribute)
    }

    public func isAllDefaultValues(
      _ attributes: any AttributeSet, version: LogisimVersion
    ) -> Bool {
      false
    }
  }

  /// `CircuitAttributes.DEFAULT_STATIC_ATTRIBUTES`.
  public static let defaultStaticAttributes = DefaultStaticAttributeProvider()

  // MARK: - Static set construction and copying

  /// `createBaseAttrs(Circuit, String)`.
  ///
  /// D13: `setValue` throws, so this does. Both writes are into a set built one line earlier out
  /// of exactly these attributes, so neither can fail on well-formed input, but swallowing the
  /// error is precisely what D13 forbids, and the caller (`Circuit.init`) is already throwing.
  ///
  /// The `StaticListener` upstream attaches here is not installed: its whole body is dialogs,
  /// HDL syntax checking and `Pin` inspection. Its two model-visible effects, firing
  /// `ACTION_CHECK_NAME` then `ACTION_SET_NAME`, are performed by `Circuit.setName` directly,
  /// which is where a caller can actually observe them.
  public static func createBaseAttrs(
    name: String,
    defaultAppearance: AttributeOption = preferenceDefaultCircuitAppearance
  ) throws -> any AttributeSet {
    let set = AttributeSets.fixedSet(staticDefaults)
    try set.setValue(appearance, defaultAppearance)
    try set.setValue(nameAttribute, name)
    return set
  }

  /// `copyStaticAttributes(AttributeSet, AttributeSet)`.
  ///
  /// Note the argument order: Java's is `(destination, source)`. Swift labels remove the chance
  /// of transposing them, which would silently blank a circuit's static attributes.
  ///
  /// Bug-for-bug: `LABEL_LOCATION_ATTR` is *not* copied even though it is a circuit-level label
  /// property, and neither is anything outside this list. Copying more would change what a
  /// "Copy circuit" produces.
  public static func copyStaticAttributes(
    from source: any AttributeSet, to destination: any AttributeSet
  ) throws {
    try destination.setValue(circuitLabelAttribute, source.getValue(circuitLabelAttribute))
    try destination.setValue(
      circuitLabelFacingAttribute, source.getValue(circuitLabelFacingAttribute))
    try destination.setValue(
      circuitLabelFontAttribute, source.getValue(circuitLabelFontAttribute))
    try destination.setValue(appearance, source.getValue(appearance))
    try destination.setValue(
      namedCircuitBoxFixedSize, source.getValue(namedCircuitBoxFixedSize))
    try destination.setValue(simulationFrequency, source.getValue(simulationFrequency))
    try destination.setValue(downloadFrequency, source.getValue(downloadFrequency))
    try destination.setValue(downloadBoard, source.getValue(downloadBoard))
  }

  /// The static `copyInto(AttributeSet, AttributeSet)`: the *instance* five, not the static
  /// nine. Upstream gives both methods almost the same name; the labels here say which is which.
  public static func copyInstanceAttributes(
    from source: any AttributeSet, to destination: any AttributeSet
  ) throws {
    try destination.setValue(StdAttr.facing, source.getValue(StdAttr.facing))
    try destination.setValue(StdAttr.label, source.getValue(StdAttr.label))
    try destination.setValue(StdAttr.labelFont, source.getValue(StdAttr.labelFont))
    try destination.setValue(
      StdAttr.labelVisibility, source.getValue(StdAttr.labelVisibility))
    try destination.setValue(
      labelLocationAttribute, source.getValue(labelLocationAttribute))
  }

  // MARK: - Instance state

  /// The circuit this instance set describes.
  ///
  /// D3: `unowned`. The owning direction is file → circuit → components; a `CircuitAttributes`
  /// hangs off a component in the *parent* circuit and points sideways at the child. Upstream
  /// forbids removing a circuit that is still in use (`Circuit.getCircuitsUsingThis`), which is
  /// the invariant that makes a non-optional reference safe here.
  public unowned let source: Circuit

  /// `subcircInstance`. D3 deletes the `Instance` facade, so this is the component itself.
  /// Weak: the component owns its attribute set, so a strong edge back would be a two-cycle on
  /// every placed subcircuit; exactly the shape D3 exists to remove.
  public weak var subcircuitInstance: InstanceComponent?

  private var facing: Direction
  private var label: String
  private var labelLocation: Direction
  private var labelFont: FontSpec
  private var labelVisible: Bool
  private var pinInstanceList: [InstanceComponent]
  private var nameReadOnly: Bool

  /// `CircuitAttributes(Circuit)`.
  ///
  /// `facing` is upstream's `source.getAppearance().getFacing()`. `CircuitAppearance` is M6;
  /// `getFacing()` returns `Direction.EAST` whenever there is no anchor shape
  /// (`CircuitAppearance.java`), which is every circuit until a custom appearance is drawn, so
  /// `.east` is the exact value and not a placeholder.
  public init(source: Circuit) {
    self.source = source
    self.subcircuitInstance = nil
    self.facing = .east
    self.label = ""
    self.labelLocation = .north
    self.labelFont = StdAttr.defaultLabelFont
    self.labelVisible = true
    self.pinInstanceList = []
    self.nameReadOnly = false
    super.init()

    // Upstream hides these three from the attribute table here: in a *constructor*, mutating
    // process-global attribute objects. Preserved because the writer consults `isHidden` and
    // because the flags are otherwise never set anywhere else.
    CircuitAttributes.downloadFrequency.isHidden = true
    CircuitAttributes.simulationFrequency.isHidden = true
    CircuitAttributes.downloadBoard.isHidden = true
  }

  /// `getFacing()`.
  public var instanceFacing: Direction { facing }

  /// `getPinInstances()` / `setPinInstances(Instance[])`.
  ///
  /// Populated by `computePorts`, which reads the circuit appearance's port offsets and is
  /// therefore M6. Until then a subcircuit instance has no ports, which is consistent with the
  /// inert model having no connectivity at all.
  public var pinInstances: [InstanceComponent] {
    get { pinInstanceList }
    set { pinInstanceList = newValue }
  }

  /// `setSubcircuit(Instance)`.
  ///
  /// The listener registration upstream performs here (`MyListener` on the static set and on the
  /// appearance) is not reproduced: its `attributeValueChanged` half only re-fires an event this
  /// set would fire anyway through the forwarding in `setRawValue`, and its
  /// `circuitAppearanceChanged` half is entirely M6.
  public func setSubcircuit(_ instance: InstanceComponent?) {
    subcircuitInstance = instance
  }

  // MARK: - AttributeSet

  public override var attributes: [AnyAttribute] { CircuitAttributes.instanceAttributes }

  /// `getValue(Attribute<E>)`.
  ///
  /// Bug-for-bug: the final `else` forwards to the static set for *any* attribute, including one
  /// that appears in neither `INSTANCE_ATTRS` nor `STATIC_ATTRS`: in which case the static set
  /// answers null. So `containsAttribute` and `getValue` disagree, and upstream relies on it:
  /// `SIMULATION_FREQUENCY` and friends are readable through an instance despite not being
  /// listed.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisible)
    }
    if attribute === CircuitAttributes.labelLocationAttribute {
      return CircuitAttributes.labelLocationAttribute.encode(labelLocation)
    }
    return source.staticAttributes.rawValue(attribute)
  }

  /// `setValue(Attribute<E>, E)`.
  ///
  /// Every branch is a no-op when the value is unchanged, and only then fires. Two details worth
  /// not tidying:
  ///
  ///   * `fireAttributeValueChanged` is called with `oldValue = null` for everything except
  ///     `LABEL`, which passes the real old value. Listeners that diff on `getOldValue()`
  ///     therefore behave differently per attribute: reproduced exactly.
  ///   * upstream's `LABEL_VISIBILITY` branch compares with `==` on a `Boolean`, i.e. by
  ///     reference. That happens to be correct because `Boolean.valueOf` returns cached
  ///     instances, so a value comparison is equivalent; it would not be for any other boxed
  ///     type.
  ///
  /// D13: `setRawValue` throws. A `.circ` file naming an attribute of the wrong kind reaches
  /// this, and the forwarding branch reaches `FixedAttributeSet.setRawValue`, which throws for
  /// an attribute the static set does not hold. Both must surface as file errors.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ value: AttributeValue?
  ) throws {
    if attribute === StdAttr.facing {
      guard let newValue = value.flatMap(StdAttr.facing.decode) else {
        throw AttributeSetError.attributeAbsent(name: attribute.name)
      }
      if facing == newValue { return }
      facing = newValue
      fireAttributeValueChanged(StdAttr.facing, value: value, oldValue: nil)
      // `subcircInstance.recomputeBounds()` needs the appearance; M6.
      return
    }
    if attribute === StdAttr.label {
      guard let newValue = value.flatMap(StdAttr.label.decode) else {
        throw AttributeSetError.attributeAbsent(name: attribute.name)
      }
      let oldValue = label
      if label == newValue { return }
      label = newValue
      fireAttributeValueChanged(
        StdAttr.label, value: value, oldValue: StdAttr.label.encode(oldValue))
      return
    }
    if attribute === StdAttr.labelFont {
      guard let newValue = value.flatMap(StdAttr.labelFont.decode) else {
        throw AttributeSetError.attributeAbsent(name: attribute.name)
      }
      if labelFont == newValue { return }
      labelFont = newValue
      fireAttributeValueChanged(StdAttr.labelFont, value: value, oldValue: nil)
      return
    }
    if attribute === StdAttr.labelVisibility {
      guard let newValue = value.flatMap(StdAttr.labelVisibility.decode) else {
        throw AttributeSetError.attributeAbsent(name: attribute.name)
      }
      if labelVisible == newValue { return }
      labelVisible = newValue
      fireAttributeValueChanged(StdAttr.labelVisibility, value: value, oldValue: nil)
      return
    }
    if attribute === CircuitAttributes.labelLocationAttribute {
      guard let newValue = value.flatMap(CircuitAttributes.labelLocationAttribute.decode) else {
        throw AttributeSetError.attributeAbsent(name: attribute.name)
      }
      if labelLocation == newValue { return }
      labelLocation = newValue
      fireAttributeValueChanged(
        CircuitAttributes.labelLocationAttribute, value: value, oldValue: nil)
      return
    }

    try source.staticAttributes.setRawValue(attribute, value)
    if attribute === CircuitAttributes.nameAttribute {
      let newName = value.flatMap(CircuitAttributes.nameAttribute.decode) ?? ""
      source.fireEvent(.setName, .name(newName))
    }
  }

  /// `isToSave(Attribute<?>)`: false for every static attribute, so a forwarded value is never
  /// written a second time on the instance that merely reads it.
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    if CircuitAttributes.staticAttributes.contains(where: { $0 === attribute }) { return false }
    return attribute.isToSave
  }

  /// `isReadOnly` / `setReadOnly`; only `NAME_ATTR` has a flag; everything else is writable and
  /// `setReadOnly` silently ignores the request. Upstream's `setReadOnly` does *not* throw here,
  /// unlike `AbstractAttributeSet`'s default, so this override is required rather than optional.
  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    attribute === CircuitAttributes.nameAttribute ? nameReadOnly : false
  }

  public override func setReadOnly(_ attribute: AnyAttribute, _ value: Bool) {
    if attribute === CircuitAttributes.nameAttribute {
      nameReadOnly = value
    }
  }

  // MARK: - Copying

  public override func makeCopyInstance() -> AbstractAttributeSet {
    CircuitAttributes(source: source)
  }

  /// `copyInto(AbstractAttributeSet)`.
  ///
  /// Java reaches here after `Object.clone()` has already field-copied everything, and its whole
  /// body is the two fields that must *not* survive the copy. Swift has no field-copying clone,
  /// so the copy is explicit, and the two upstream nulls are still nulls.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let other = destination as? CircuitAttributes else {
      preconditionFailure("CircuitAttributes can only copy into a CircuitAttributes")
    }
    other.facing = facing
    other.label = label
    other.labelLocation = labelLocation
    other.labelFont = labelFont
    other.labelVisible = labelVisible
    other.pinInstanceList = pinInstanceList
    other.nameReadOnly = nameReadOnly
    // Upstream: `other.subcircInstance = null; other.listener = null;`
    other.subcircuitInstance = nil
  }
}
