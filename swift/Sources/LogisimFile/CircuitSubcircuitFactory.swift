// CircuitSubcircuitFactory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SubcircuitFactory),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── Why the name differs ────────────────────────────────────────────────────────────────────
//
// `SubcircuitFactory` is already taken: `LibraryModel.swift` declares it as the *protocol* the
// library layer resolves `<comp>` elements against, precisely so library loading did not have to
// wait for `Circuit`. This is the concrete conformer. Upstream has one class in both roles.
//
// ── Scope ───────────────────────────────────────────────────────────────────────────────────
//
// `SubcircuitFactory.java` is 515 lines and roughly 400 of them are painting (three icon
// renderers, the label layout, ghost drawing) and the popup-menu `CircuitFeature`. None of that
// is ported here. What a subcircuit placement record needs is: an identity that tracks the
// circuit's name, an attribute set, a component, the `removeComponent` hook that keeps
// `circuitsUsingThis` honest: and, since `CircuitAppearance` landed, **`computePorts`**.
//
// ── `computePorts`: what it is and why it was the single highest-value gap ───────────────────
//
// A subcircuit component created with no ends does not appear in the netlist at all. Its ports
// join no net, so every wire attached to one reads `UNKNOWN`, and so does everything downstream
// of it, which for a hierarchical design is the entire circuit. Measured against the 1,282-case
// Java oracle before this landed: 232 of the 337 mismatches had the shape `java=0000` /
// `swift=UUUU`, i.e. 69% of all remaining simulation failures were this one missing method.
//
// Upstream derives the ports from the circuit's *appearance*, not from its pins directly:
//
//     final var portLocs = source.getAppearance().getPortOffsets(facing);
//
// so the appearance is a hard prerequisite, which is why it was recorded as blocked rather than
// guessed at. `CircuitAppearance.swift` now supplies exactly that one method (and nothing else
// from the 533-line canvas model); see its header for how, and for why a custom `<appear>` can be
// read without the draw model.
//
// Two things about the result are load-bearing and are called out here because a mistake in
// either is silent; it produces a circuit that loads, builds and simulates, and is wrong:
//
//   * **Port ORDER.** `getPortOffsets` returns a `TreeMap` keyed by location, so the ports are
//     numbered by ascending x then ascending y of their *anchor-relative* offset. That numbering
//     is what `propagate` indexes and what a parent circuit's wires bind to. Transposing two
//     ports miswires every instantiation of the circuit.
//   * **Port DIRECTION.** An input pin becomes a shared `INPUT_ONLY` end, an output pin an
//     exclusive `OUTPUT_ONLY` end (`Port.defaultExclusive`). Getting the exclusivity wrong turns
//     a legal circuit into a bus contention error, or hides a real one.
//
// ── Keeping the ends current ────────────────────────────────────────────────────────────────
//
// A stale end list is worse than no end list: it connects the *wrong* net, silently. Upstream
// keeps them current through a four-link chain,
//
//     CircuitPins (listens to pin add/remove/attribute changes)
//       -> PortManager.updatePorts
//       -> CircuitAppearance.recomputePorts / fireCircuitAppearanceChanged
//       -> CircuitAttributes.MyListener.circuitAppearanceChanged
//       -> SubcircuitFactory.computePorts(subcircInstance)
//
// , plus `instanceAttributeChanged` for the instance's own `StdAttr.FACING` and
// `APPEARANCE_ATTR`. The port collapses that chain into this class, which is the one object that
// already sits at both ends of it: it knows the source circuit (to observe) and it created every
// placement (to update). See `sourceObserver` and `placements` below.
//
// This is not a nicety for the editor. It is required for *loading*: `XmlCircuitReader` builds
// circuits in file order, so a parent circuit is routinely finished before the child it
// instantiates has any pins at all. Without the invalidation every such subcircuit would be
// computed against an empty circuit and left portless; the exact bug this file is fixing.
//
// ── `getOffsetBounds` is NOT stubbed, and here is why it could not be ───────────────────────
//
// It used to return `Bounds.empty`, on the reasoning that the box is `source.getAppearance()
// .getOffsetBounds().rotate(…)` and the appearance model is M6. That reasoning was wrong in
// consequence, and the consequence was silent data loss on load.
//
// `Bounds.empty` is the *sentinel*, and `Bounds.translate` returns the sentinel unchanged
// (`Bounds.java:261`, faithfully ported). So `InstanceComponent.bounds` gave every subcircuit
// placement in a circuit the identical box (0,0,0,0), whatever its location.
// `XmlCircuitReader.buildCircuit` keys its overlap map on exactly that box, so the second and
// every later placement was classified an exact overlap of the first. Upstream *nudges* an
// overlapping component clear by (10,10) rather than dropping it: but its second loop opens
// with `if (bds.getHeight() == 0 || bds.getWidth() == 0) continue;`, "ignore empty boxes", and a
// degenerate box takes that branch. So the components were not moved, they were deleted, and
// nothing in the saved file recorded that it happened. That is the D8 failure mode arriving by a
// different door, and it hits hierarchical designs hardest, which is most real circuits and all
// of the corpus.
//
// What replaces it is `DefaultEvolutionAppearanceGeometry` below: a port of the *geometry* half
// of `DefaultEvolutionAppearance.build`, which needs no renderer because every constant it uses
// is hard-coded in `DrawAttr` (`FIXED_FONT_CHAR_WIDTH = 8`, `FIXED_FONT_HEIGHT = 12`) rather than
// measured from a font. Read its own comment for exactly what is and is not reproduced.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.SubcircuitFactory`: the factory that places one circuit inside
/// another.
public final class CircuitSubcircuitFactory: AbstractComponentFactory, SubcircuitFactory {

  /// `source`.
  ///
  /// D3: `unowned`, and this is the edge D3 names explicitly. In Java `Circuit` and
  /// `SubcircuitFactory` hold each other unconditionally, on every circuit in every open file;
  /// a strong two-cycle the GC absorbs and ARC would not. The circuit owns the factory; the
  /// factory points back without owning.
  ///
  /// `var` rather than `let` because `setSubcircuit(Circuit)` exists upstream and the library
  /// reloading path uses it to repoint a factory at a replacement circuit.
  public unowned var source: Circuit

  /// `source.getAppearance()`.
  ///
  /// Upstream hangs the appearance off `Circuit`; the port hangs it off the factory instead,
  /// because the factory is 1:1 with the circuit, is created by the circuit's own initialiser,
  /// and is the only object that reads it. Reaching it from a circuit is
  /// `circuit.subcircuitFactory`.
  /// `var` for the same reason `source` is: `setSubcircuit(Circuit)` repoints the factory, and an
  /// appearance still bound to the old circuit would compute ports from the wrong pins.
  public private(set) var appearance: CircuitAppearance

  /// Every placement of `source` this factory has created, weakly.
  ///
  /// This is the port's stand-in for walking `Circuit.circuitsUsingThis`, which holds exactly
  /// these components but keeps them private, and for upstream's
  /// `CircuitAttributes.subcircInstance` back-pointer. Weak on the component so a placement that
  /// has been deleted from its parent circuit cannot be kept alive by this list; the entry is
  /// reaped on the next pass.
  private struct Placement {
    weak var component: InstanceComponent?
    /// Retains the instance-attribute subscription; dropping it unsubscribes.
    var attributeSubscription: AttributeSubscription?
  }
  private var placements: [Placement] = []

  /// The subscription to `source`'s own events. `Circuit` holds its listeners weakly, so this
  /// must be retained here for the subscription to stay live.
  private var sourceObserver: CircuitListenerClosure?

  /// Re-entrancy guard. `setEnds` fires `endChanged`, which makes the *parent* circuit fire
  /// `ACTION_INVALIDATE`, which reaches the parent's own factory and can cascade back here on a
  /// deeply nested design. The cascade is finite (the circuit hierarchy is acyclic), but it is
  /// pointless to re-enter mid-pass.
  private var isRecomputingPorts = false

  public init(source: Circuit) {
    self.source = source
    self.appearance = CircuitAppearance(circuit: source)
    super.init(requiresLabel: false, requiresGlobalClock: false)
  }

  /// `getName()`: the circuit's own name, which is also the `<comp name="…">` token.
  public override var name: String { source.name }

  /// `getDisplayGetter()` returns `constantGetter(source.getName())`, so display name and name
  /// are the same string.
  public override var displayName: String { source.name }

  /// `getSubcircuit()`.
  public var subcircuit: any CircuitReference { source }

  /// `setSubcircuit(Circuit)`.
  public func setSubcircuit(_ circuit: Circuit) {
    source = circuit
    appearance = CircuitAppearance(circuit: circuit)
    sourceObserver = nil
    observeSource()
    recomputeAllPorts()
  }

  /// `createAttributeSet()`.
  public override func createAttributeSet() -> any AttributeSet {
    CircuitAttributes(source: source)
  }

  /// `createComponent(Location, AttributeSet)`.
  ///
  /// ```java
  /// public void configureNewInstance(Instance instance) {
  ///   final var attrs = (CircuitAttributes) instance.getAttributeSet();
  ///   attrs.setSubcircuit(instance);
  ///   computePorts(instance);
  ///   // configureLabel(instance); already done in computePorts
  /// }
  /// ```
  ///
  /// `configureLabel` is the label's text-field geometry, which is painting; it is the one line
  /// of `computePorts` not reproduced.
  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    let component = InstanceComponent(
      factory: self, location: location, attributes: attributes)
    if let circuitAttributes = attributes as? CircuitAttributes {
      circuitAttributes.setSubcircuit(component)
    }
    register(component, attributes: attributes)
    computePorts(component)
    return component
  }

  // MARK: - computePorts

  /// `computePorts(Instance)`.
  ///
  /// ```java
  /// final var facing = instance.getAttributeValue(StdAttr.FACING);
  /// final var portLocs = source.getAppearance().getPortOffsets(facing);
  /// final var ports = new Port[portLocs.size()];
  /// final var pins  = new Instance[portLocs.size()];
  /// int i = -1;
  /// for (final var portLoc : portLocs.entrySet()) {
  ///   i++;
  ///   final var loc  = portLoc.getKey();
  ///   final var pin  = portLoc.getValue();
  ///   final var type = Pin.FACTORY.isInputPin(pin) ? Port.INPUT : Port.OUTPUT;
  ///   final var width = pin.getAttributeValue(StdAttr.WIDTH);
  ///   ports[i] = new Port(loc.getX(), loc.getY(), type, width);
  ///   pins[i]  = pin;
  ///   final var label = pin.getAttributeValue(StdAttr.LABEL);
  ///   if (label != null && label.length() > 0) ports[i].setToolTip(constantGetter(label));
  /// }
  /// attrs.setPinInstances(pins);
  /// instance.setPorts(ports);
  /// instance.recomputeBounds();
  /// configureLabel(instance);
  /// ```
  ///
  /// Three differences from that text, each with a reason:
  ///
  ///   * **`Port` is not constructed.** `com.cburch.logisim.instance.Port` lives in `LogisimStd`,
  ///     above this module. Every port here is built by the same one constructor
  ///     (`Port(dx, dy, type, BitWidth)`), whose `toEnd` is `new EndData(loc.translate(dx, dy),
  ///     widthFixed, type, exclude)` with `exclude = defaultExclusive(type)`: `INPUT` → shared,
  ///     `OUTPUT` → exclusive. So the `EndData` is built directly and is the identical value.
  ///   * **The tool tip is dropped.** It is `Port.setToolTip`, read only by the canvas's hover
  ///     text; `EndData` has no such field and the netlist never sees it.
  ///   * **`setEnds` is only called when the ends actually changed.** That is upstream's
  ///     behaviour, not an optimisation: `InstanceComponent.computeEnds` builds
  ///     `endsChangedOld/New` lazily and fires `endChanged` only if one was allocated
  ///     (`InstanceComponent.java:153-195`). Firing unconditionally would make every recompute
  ///     invalidate the parent circuit, and the cascade described in the file header would not
  ///     terminate cheaply.
  ///
  /// `recomputeBounds()` is not called: `InstanceComponent.bounds` is computed on demand from
  /// `factory.offsetBounds`, so there is no cached box to refresh.
  public func computePorts(_ component: InstanceComponent) {
    let facing = component.attributeSet[StdAttr.facing] ?? .east
    let portLocations = appearance.portOffsets(facing: facing)

    var ends: [EndData] = []
    var pins: [any Component] = []
    ends.reserveCapacity(portLocations.count)
    pins.reserveCapacity(portLocations.count)

    for entry in portLocations {
      let isInput = !AppearancePinReader.isOutput(entry.pin)
      let width = AppearancePinReader.width(entry.pin)
      // `Port.toEnd(loc, attrs)`: the offset is applied to the *component's* location, and
      // `EndData`'s three-argument initialiser already derives `exclusive` as
      // `type == OUTPUT_ONLY`, which is exactly `Port.defaultExclusive`.
      ends.append(
        EndData(
          location: component.location.translate(entry.location.x, entry.location.y),
          width: width,
          type: isInput ? .inputOnly : .outputOnly))
      pins.append(entry.pin)
    }

    pinComponentsByPlacement[ObjectIdentifier(component)] = pins

    guard ends != component.ends else { return }
    component.setEnds(ends)
  }

  /// `CircuitAttributes.getPinInstances()` for one placement: the pin components, in the same
  /// order as that placement's ends, which is the order `SubcircuitFactory.propagate` indexes.
  ///
  /// **Why this is not `CircuitAttributes.pinInstances`.** That property is declared
  /// `[InstanceComponent]`, and a `Pin` placed from a `.circ` is a `StdInstanceComponent`: a
  /// sibling type, not a subclass. The list therefore cannot be stored there without widening
  /// that property's element type to `any Component`, which is a change to a file this work does
  /// not own. Recorded rather than worked around: see the note in the deviation report.
  public func pinComponents(for component: InstanceComponent) -> [any Component] {
    pinComponentsByPlacement[ObjectIdentifier(component)] ?? []
  }

  private var pinComponentsByPlacement: [ObjectIdentifier: [any Component]] = [:]

  // MARK: - Keeping the ends current

  /// Remember a placement, and subscribe to the two instance attributes that change its ports.
  ///
  /// `instanceAttributeChanged(Instance, Attribute)`:
  ///
  /// ```java
  /// if (attr == StdAttr.FACING) computePorts(instance);
  /// else if (attr == LABEL_LOCATION_ATTR) configureLabel(instance);
  /// else if (attr == APPEARANCE_ATTR) { …ChangeAppearanceTransaction…; computePorts(instance); }
  /// ```
  ///
  /// `LABEL_LOCATION_ATTR` is painting. `APPEARANCE_ATTR` on the *instance* forwards to the
  /// source circuit's static set (`CircuitAttributes.getValue`'s final `else`), so a write to it
  /// arrives here as well as through `observeSource`; recomputing twice is harmless because the
  /// second pass finds the ends unchanged and does not fire.
  private func register(_ component: InstanceComponent, attributes: any AttributeSet) {
    observeSource()
    reapDeadPlacements()

    // D3: `[weak self]`. The attribute set belongs to a component in a *different* circuit, so a
    // strong capture would let a parent circuit keep this factory alive past its own circuit,
    // and `source` is `unowned`.
    let subscription = attributes.addAttributeListener(
      onValueChanged: { [weak self, weak component] event in
        guard let self, let component else { return }
        guard let attribute = event.attribute else { return }
        guard attribute === StdAttr.facing || attribute === CircuitAttributes.appearance else {
          return
        }
        self.computePorts(component)
      })

    placements.append(Placement(component: component, attributeSubscription: subscription))
  }

  /// Attach to `source`'s events, once.
  ///
  /// Deliberately lazy rather than done in `init`: `Circuit.init` constructs this factory while
  /// the circuit is still initialising, and calling back into it there would be a use of a
  /// partially-initialised object. Nothing needs the observer until the first placement exists.
  ///
  /// The four actions handled are upstream's `CircuitPins` triggers, mapped onto the events the
  /// port's `Circuit` actually fires:
  ///
  ///   * `.add` / `.remove` / `.clear`; `CircuitPins.transactionCompleted`'s additions and
  ///     removals. A non-pin component changes nothing, but testing that here would mean
  ///     recomputing the appearance to find out, so the cheap over-approximation is taken and the
  ///     "ends unchanged" guard in `computePorts` absorbs it.
  ///   * `.invalidate`; fired by `Circuit.MyComponentListener.endChanged` and by
  ///     `componentInvalidated`, which is where a pin's `StdAttr.FACING`, `StdAttr.LABEL` or
  ///     `Pin.ATTR_TYPE` change surfaces (`CircuitPins.MyComponentListener`).
  ///   * `.changeDefaultBoxAppearance` and `.setName`: the circuit's name and its fixed-size
  ///     flag both feed the default box's *width*, and therefore its east ports' x offset.
  private func observeSource() {
    guard sourceObserver == nil else { return }
    let observer = CircuitListenerClosure { [weak self] event in
      guard let self else { return }
      switch event.action {
      case .add, .remove, .clear, .invalidate, .changeDefaultBoxAppearance, .setName:
        self.appearance.invalidate()
        self.recomputeAllPorts()
      case .checkName, .displayChange, .transactionDone:
        break
      }
    }
    sourceObserver = observer
    source.addCircuitListener(observer)
  }

  /// `CircuitPins.transactionCompleted(ReplacementMap)` → `PortManager.updatePorts`, as the
  /// end of a transaction reaches it.
  ///
  /// ```java
  /// // CircuitTransaction.execute(), before the WireRepair loop:
  /// final var pins = circuit.getAppearance().getCircuitPins();
  /// pins.transactionCompleted(repl);
  /// ```
  ///
  /// **Why this exists as an explicit call and is not left to `observeSource`.** During a load
  /// the placements of a circuit are created before that circuit is populated whenever the
  /// `<circuit>` elements are in that order, which is the common case; `main` is written first
  /// and the blocks it instantiates come after it. At the moment `createComponent` runs,
  /// `source` has no `Pin` yet, so `portOffsets` is empty and the placement gets **no ends**.
  ///
  /// A component with no ends is invisible to `CircuitPoints`, and `WireRepair.doMerges` then
  /// merges straight *through* the point where a port should have been. Measured on
  /// a corpus file whose `ALU` block is the last `<circuit>` in the
  /// file and its west ports land at x=390, so with `ALU` last the two wires
  /// `(360,310)-(390,310)` and `(390,310)-(400,310)` collapsed into one, and with the same file
  /// reordered to put `ALU` first they correctly stayed split. Upstream's own view, dumped from
  /// the 4.1.0 jar, is `ends=(390,270) (390,290) (390,310) (610,270)` and
  /// `getComponents((390,310))` = two wires **plus** the ALU: three, so upstream skips the
  /// merge.
  ///
  /// Upstream is immune to the ordering for the same reason this method exists: it does not rely
  /// on incremental listeners during a load, it re-derives every port from the finished circuits
  /// at the end of the transaction, before repairing wires.
  public func refreshPortsAfterSourceChanged() {
    appearance.invalidate()
    recomputeAllPorts()
  }

  /// `PortManager.updatePorts` → every placement of this circuit.
  private func recomputeAllPorts() {
    guard !isRecomputingPorts else { return }
    isRecomputingPorts = true
    defer { isRecomputingPorts = false }

    reapDeadPlacements()
    for placement in placements {
      guard let component = placement.component else { continue }
      computePorts(component)
    }
  }

  private func reapDeadPlacements() {
    guard placements.contains(where: { $0.component == nil }) else { return }
    let live = Set(placements.compactMap { $0.component.map(ObjectIdentifier.init) })
    placements.removeAll { $0.component == nil }
    pinComponentsByPlacement = pinComponentsByPlacement.filter { live.contains($0.key) }
  }

  /// `getOffsetBounds(AttributeSet)`:
  ///
  /// ```java
  /// final var facing = attrs.getValue(StdAttr.FACING);
  /// final var defaultFacing = source.getAppearance().getFacing();
  /// final var bds = source.getAppearance().getOffsetBounds();
  /// return bds.rotate(defaultFacing, facing, 0, 0);
  /// ```
  ///
  /// The rotation is upstream's, unchanged. The two appearance calls are what the port supplies
  /// itself:
  ///
  ///   * `getOffsetBounds()` becomes `DefaultEvolutionAppearanceGeometry.offsetBounds(of:)`.
  ///   * `getFacing()` is the appearance anchor's facing, and `AppearanceAnchor`'s constructor
  ///     assigns `Direction.EAST` (`AppearanceAnchor.java:41`): so for any *default* appearance,
  ///     which is every appearance this milestone can compute, the answer is east. A custom
  ///     `<appear>` may name something else in its anchor; that element is preserved verbatim
  ///     (`Circuit.rawAppearance`) and not parsed, so east is the assumption until M6 reads it.
  ///
  /// `StdAttr.FACING` is in `CircuitAttributes.INSTANCE_ATTRS`, so the read is the same one Java
  /// makes; `.east` covers an attribute set that does not carry it at all.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing] ?? .east
    let box = DefaultEvolutionAppearanceGeometry.offsetBounds(of: source)
    return box.rotate(
      from: DefaultEvolutionAppearanceGeometry.defaultFacing, to: facing, xc: 0, yc: 0)
  }

  /// `getFeature(Object, AttributeSet)`.
  ///
  /// `InstanceFactory`'s constructor calls `setFacingAttribute(StdAttr.FACING)`, which is what
  /// makes `FACING_ATTRIBUTE_KEY` answer for a subcircuit. `TOOL_TIP` is a `CircuitFeature`,
  /// i.e. a popup-menu object (M7), and `SHOULD_SNAP` is not set, so both are absent here.
  public override func feature(
    _ key: ComponentFactoryFeatureKey, _ attributes: any AttributeSet
  ) -> Any? {
    key == .facingAttribute ? StdAttr.facing : nil
  }

  /// `removeComponent(Circuit, Component, CircuitState)`.
  ///
  /// This is the eviction owner for the target circuit's `circuitsUsingThis` map: the explicit
  /// owner D3 demands in place of a `WeakHashMap`. `Circuit.mutatorRemove` and `mutatorClear`
  /// both route here.
  public override func removeComponent(
    from circuit: Circuit, component: any Component, state: AnyObject?
  ) {
    source.removeComponent(component)
    // Drop this placement's entry so a deleted component stops being recomputed and its pin list
    // stops being retained. Upstream's equivalent is `CircuitAttributes.subcircInstance` going
    // out of scope with the component.
    let identity = ObjectIdentifier(component)
    placements.removeAll { $0.component == nil || $0.component === component }
    pinComponentsByPlacement.removeValue(forKey: identity)
  }
}

// MARK: - Default appearance geometry

/// The box `com.cburch.logisim.circuit.appear.DefaultEvolutionAppearance.build` lays a circuit's
/// default symbol out in, expressed relative to the anchor, which is exactly what
/// `CircuitAppearance.getOffsetBounds()` returns for a circuit that has not been given a custom
/// appearance.
///
/// ── Why this is portable at M2 and the rest of the appearance layer is not ──────────────────
///
/// `DefaultEvolutionAppearance` computes its box from `DrawAttr.FIXED_FONT_CHAR_WIDTH = 8` and
/// `DrawAttr.FIXED_FONT_HEIGHT = 12`: **hard-coded integers, not `FontMetrics` queries**
/// (`DrawAttr.java:27-30`). So the width/height arithmetic is pure integer arithmetic over the
/// circuit's own pins and name, and it ports exactly. What does *not* port is the part that needs
/// a renderer, and that part is enumerated rather than glossed:
///
///   | upstream contribution to `getBounds`      | reproduced? | effect on the box |
///   |-------------------------------------------|-------------|-------------------|
///   | outline `Rectangle`, pin stub rectangles   | yes         | it *is* the box   |
///   | `AppearancePort` / `AppearanceAnchor` locs | yes         | inside the box, except a 1 px east overshoot |
///   | outline stroke width 2 → `bounds.expand(1)`| no          | 1 px halo on all four sides |
///   | pin-label and title `Text` bounds          | no          | laid out inside the box by construction |
///   | clock-pin `Poly` indicator                 | no          | inside the box |
///
/// The port is therefore the box, without the stroke halo, and it is **≤ 2 px** narrower and
/// shorter than upstream's on every side. That difference is invisible to everything M2 does with
/// bounds: `XmlCircuitReader`'s overlap map compares boxes for *exact equality*, so what it needs
/// is an identity that is non-degenerate and varies with the circuit: not a pixel-accurate one.
/// M6 replaces this wholesale with the real `CircuitAppearance`, at which point the halo, the text
/// extents and the custom-`<appear>` case all arrive together.
///
/// Two further simplifications, both deliberate:
///
///   * **Only the evolution builder is ported**, not `DefaultClassicAppearance` (a different box)
///     or `DefaultHolyCrossAppearance`. `CircuitAttributes.APPEARANCE_ATTR` selects between them,
///     and the shipped preference is `logisim_evolution`
///     (`CircuitAttributes.preferenceDefaultCircuitAppearance`). A classic-styled circuit gets a
///     differently-sized box than upstream would give it: still non-degenerate, still varying
///     with the circuit, which is what the overlap map is asking of it.
///   * **A custom `<appear>` is not measured.** It is preserved verbatim and never parsed at this
///     milestone (`Circuit.rawAppearance`), so its shapes are not available to bound.
enum DefaultEvolutionAppearanceGeometry {

  /// `CircuitAppearance.getFacing()` for any default appearance: `AppearanceAnchor`'s constructor
  /// sets `factingDirection = Direction.EAST` and only a custom appearance can change it.
  static let defaultFacing: Direction = .east

  /// `DrawAttr.FIXED_FONT_CHAR_WIDTH`.
  private static let fixedFontCharWidth = 8
  /// `DrawAttr.FIXED_FONT_HEIGHT`.
  private static let fixedFontHeight = 12

  /// `com.cburch.logisim.std.wiring.Pin._ID`.
  ///
  /// Reached by factory name for the same reason `XmlCircuitReader.isEmptyTextBox` reaches
  /// `Text.ATTR_TEXT` by attribute name: the wiring tranche is M5, so at this milestone a `<comp
  /// name="Pin">` is an `UnresolvedComponent` carrying its name and its attributes as strings.
  /// `ComponentFactory.isPin` is the right test and nothing sets it yet; when M5 does, this can
  /// become `component.factory.isPin`.
  private static let pinFactoryName = "Pin"

  /// `Pin.ATTR_TYPE` and its `Pin.OUTPUT` option. `XmlReader`'s pre-4.0 repair rewrites the old
  /// `<a name="output" val="true"/>` form into this one (`XmlReader.java:1090`) before any
  /// component is built, so only the modern spelling has to be recognised here.
  private static let pinTypeAttributeName = "type"
  private static let pinTypeOutput = "output"

  /// `source.getAppearance().getOffsetBounds()`.
  ///
  /// Guaranteed non-degenerate, and that is the property `XmlCircuitReader` depends on rather
  /// than pixel accuracy. `textWidth` is at least 35 (the `maxLeft + maxRight + 35` arm, both
  /// operands non-negative) so `width = (textWidth / 10) * 10 + 20` is at least 50; `dy` is 20
  /// and `titleBarHeight` 20, so `height` is at least 30. The box therefore never equals
  /// `Bounds.empty` and never takes the reader's "ignore empty boxes" branch, whatever the
  /// circuit contains, including a circuit with no pins and an empty name.
  static func offsetBounds(of circuit: Circuit) -> Bounds {
    // `build`'s first loop: split the pins east/west and track the widest label on each side.
    var numEast = 0
    var numWest = 0
    var maxLeftLabelLength = 0
    var maxRightLabelLength = 0

    for component in circuit.nonWires {
      let factory = component.factory
      guard factory.isPin || factory.name == pinFactoryName else { continue }
      let attributes = component.attributeSet
      // Java measures `new Text(0, 0, label).getText().length()`; `Text`'s constructor stores the
      // string it is given, and a null label yields a null text whose length would throw, which
      // it cannot, because `StdAttr.LABEL` defaults to "".
      let label = stringValue(of: attributes, named: StdAttr.label.name) ?? ""
      let labelWidth = label.utf16.count * fixedFontCharWidth
      if stringValue(of: attributes, named: pinTypeAttributeName) == pinTypeOutput {
        numEast += 1
        if labelWidth > maxRightLabelLength { maxRightLabelLength = labelWidth }
      } else {
        // `PinAttributes.type` defaults to `Pin.INPUT`, so an absent or unrecognised type is west.
        numWest += 1
        if labelWidth > maxLeftLabelLength { maxLeftLabelLength = labelWidth }
      }
    }

    // `DefaultAppearance.sortPinList` only orders the two lists; the box depends on their sizes.
    let maxVert = max(numEast, numWest)

    // Java's `TitleWidth`. The `circuitName == null` branch (14 characters' worth) belongs to
    // `VhdlEntity`, which passes null; a `Circuit` always has a name attribute, and `Circuit.name`
    // already substitutes "" for Java's nullable one.
    let titleWidth = circuit.name.utf16.count * fixedFontCharWidth

    // `isFixed` is `NAMED_CIRCUIT_BOX_FIXED_SIZE`, read off the circuit's static attributes;
    // `Circuit.recalcDefaultShape` passes exactly this.
    let fixedSize = circuit.staticAttributes[CircuitAttributes.namedCircuitBoxFixedSize] ?? false

    // The four size expressions, verbatim. Every operand is non-negative, so Swift's `/` and
    // Java's integer division agree (they differ only in rounding direction for negatives).
    let dy = ((fixedFontHeight + (fixedFontHeight >> 2) + 5) / 10) * 10
    let textWidth =
      fixedSize
      ? 25 * fixedFontCharWidth
      : max(maxLeftLabelLength + maxRightLabelLength + 35, titleWidth + 15)
    let titleBarHeight = ((fixedFontHeight + 10) / 10) * 10
    let width = (textWidth / 10) * 10 + 20
    let height = (maxVert > 0) ? maxVert * dy + titleBarHeight : 10 + titleBarHeight

    // "compute position of anchor relative to top left corner of box", verbatim. `getOffsetBounds`
    // is `getBounds(relativeToAnchor: true)`, i.e. the box translated by `-anchor`, and the box's
    // top-left is `(rx, ry)` while the anchor sits at `(rx + ax, ry + ay)`. `rx`/`ry` themselves,
    // the `OFFS`-based grid alignment, cancel out, which is why they do not appear here.
    let ax: Int
    let ay: Int
    if numEast > 0 {
      ax = width
      ay = 10
    } else if numWest > 0 {
      ax = 0
      ay = 10
    } else {
      ax = 0
      ay = 0
    }

    return Bounds.create(-ax, -ay, width, height)
  }

  /// One attribute, read as the string the `.circ` file spelled it with.
  ///
  /// By name rather than by `Attribute` identity because the set may be an `OpaqueAttributeSet`
  /// (D8) whose attributes are synthesised from the element and are therefore not the same objects
  /// as `StdAttr.label` and friends. `attribute(named:)` answers for both kinds.
  private static func stringValue(of set: any AttributeSet, named name: String) -> String? {
    guard let attribute = set.attribute(named: name),
      let raw = set.rawValue(attribute)
    else { return nil }
    return attribute.standardString(for: raw)
  }
}
