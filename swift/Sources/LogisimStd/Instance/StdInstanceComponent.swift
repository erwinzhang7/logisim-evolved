// StdInstanceComponent.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceComponent),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is not `LogisimFile.InstanceComponent` ─────────────────────────────────────────
//
// `LogisimFile.InstanceComponent` is, by its own file header, "the inert placement record":
// fixed ends handed in at construction, no port recomputation, no feature dispatch. A component
// that has *ports* needs both, ends must track the attribute set, and `getFeature` must reach
// the factory, and neither can be added from another module, because both need stored state.
//
// So `LogisimStd` owns its own `Component` conformer. `Component` is a protocol in `LogisimFile`
// precisely so `Wire`, `UnresolvedComponent` and `InstanceComponent` can coexist; this is a
// fourth conformer, and it is the one every `std` factory produces. When the simulation half of
// `LogisimFile` lands, the two should merge; `LogisimFile.InstanceComponent` is a strict
// subset of this.
//
// ── D3 ──────────────────────────────────────────────────────────────────────────────────────
//
// The `Instance` facade is gone. Upstream's `Instance` ⇄ `InstanceComponent` strong 2-cycle
// exists on every placed component in every circuit; `Instance` is a pure forwarder, so it
// collapses into this type. Every `instance.getAttributeValue(x)` in upstream component code
// becomes `component.attributeSet[x]` or, inside `propagate`, `state.attributeValue(x)`.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `draw`, `drawLabel`, `expose`, `computeLabelTextField`, the DRC mark flags: all drawing
//     (D6/M6).
//   * `setTextField`: D6, the six arguments are paint-time facts. What upstream achieves by
//     re-running it from `instanceAttributeChanged` is achieved here by re-deriving them; see
//     `textField` below and `InstanceTextFieldSpec.resolve`.
//   * `getToolTip`, `hasToolTips`: hover text, and `Port` carries no tool tip. See `Port`.
//   * `setInstanceStateImpl` / `getInstanceStateImpl`; the reusable scratch object belongs to
//     the simulation module and is installed there.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// A placed `std` component: factory, location, attributes, and connection points that track
/// the attribute set.
///
/// `final class`, deliberately not `Equatable`/`Hashable`: D4. Key it with `ComponentRef`.
public final class StdInstanceComponent: Component {

  private let listeners = ComponentListenerRegistry()

  /// `getFactory()` / `setFactory(ComponentFactory)`.
  public private(set) var factory: any ComponentFactory

  /// The same object as `factory`, pre-cast. Every `std` component has one; `nil` only if a
  /// `.circ` repair pass retargeted this component at a non-instance factory.
  public var instanceFactory: (any InstanceFactory)? { factory as? any InstanceFactory }

  /// `getLocation()`.
  public let location: Location

  /// `getAttributeSet()`. Owned: the component is the only thing that keeps it alive.
  public let attributeSet: any AttributeSet

  private var portList: [Port]
  private var endArray: [EndData]

  /// D3: owned by the component, and the closure captures `self` weakly, so the attribute set
  /// never gains a strong edge back here.
  private var attributeSubscription: AttributeSubscription?

  /// `InstanceComponent.textField` (`InstanceComponent.java:61`): the component's live editable
  /// text field, written only by `InstanceTextField.make`.
  ///
  /// ── WHY THIS EDGE IS WEAK, WHERE JAVA'S IS STRONG ─────────────────────────────────────────
  ///
  /// Upstream's pair is a strong 2-cycle: `InstanceComponent.textField` holds the field, and
  /// `InstanceTextField.comp` is a `final InstanceComponent`. A GC collects a cycle; ARC does
  /// not, so transcribing both edges strongly leaks the component, its attribute set and its end
  /// array for the life of the process, on every component whose label is ever clicked. The
  /// cycle has to be broken on one side and the choice is forced:
  ///
  ///   * making `InstanceTextField.component` `unowned` keeps upstream's ownership direction but
  ///     buys a trap; a caret held by `TextTool` outlives a component deleted mid-edit, and its
  ///     next `component.attributeSet` access is a crash where upstream has none. D13 reserves
  ///     traps for programmer error;
  ///   * making *this* edge weak keeps every access safe and costs only the field's lifetime.
  ///
  /// And that lifetime is exactly the one that matters. The field is strongly held for precisely
  /// as long as an edit is in progress, `TextFieldCaret.owner` holds it (that reference is
  /// already load-bearing, see its comment), which is the entire window in which upstream's
  /// `attributeValueChanged` has an observable effect. Outside an edit there is nothing to keep
  /// in sync: this port caches no text, font, colour or visibility on the field, because
  /// `InstancePainter.drawLabel()` reads all four from the attribute set at paint time.
  public internal(set) weak var textField: InstanceTextField?

  public init(
    factory: any ComponentFactory,
    location: Location,
    attributes: any AttributeSet
  ) throws {
    self.factory = factory
    self.location = location
    self.attributeSet = attributes

    let ports = (factory as? any InstanceFactory)?.ports(attributes) ?? []
    self.portList = ports
    // D13: `toEnd` throws when a width attribute the factory names is absent from the set,
    // which a malformed `<comp>` element can produce. `createComponent` throws for exactly
    // this, so the loader reports a file error rather than the app dying.
    self.endArray = try ports.map { try $0.toEnd(location: location, attributes: attributes) }

    attributeSubscription = attributes.addAttributeListener(
      onValueChanged: { [weak self] event in
        self?.attributeValueChanged(event)
      },
      onListChanged: { [weak self] _ in
        // `AbstractAttributeSet.fireAttributeListChanged()`; a gate's input count changed, so
        // the attribute list itself is a different length. Ports must be recomputed.
        self?.recomputePorts()
      })
  }

  // MARK: Component

  public func setFactory(_ factory: any ComponentFactory) {
    self.factory = factory
    recomputePorts()
  }

  /// `getBounds()`.
  ///
  /// Derived rather than cached, which is what makes upstream's `instance.recomputeBounds()`
  /// unnecessary: there is no stale copy to refresh.
  public var bounds: Bounds {
    factory.offsetBounds(attributeSet).translate(location.x, location.y)
  }

  /// `getEnds()`.
  public var ends: [EndData] { endArray }

  /// `getPorts()`.
  public var ports: [Port] { portList }

  /// `getEnd(int)`.
  ///
  /// Upstream indexes the array and lets an out-of-range index throw
  /// `ArrayIndexOutOfBoundsException`. Not reachable from a file, the index always comes from a
  /// loop over `getEnds()` or from a port number the factory itself defined, so it stays a
  /// trap (D13's programmer-error carve-out).
  public func end(at index: Int) -> EndData {
    precondition(
      endArray.indices.contains(index),
      "end index \(index) out of range for \(factory.name) at \(location)")
    return endArray[index]
  }

  /// `contains(Location)`: translate into factory-relative coordinates, then ask the factory,
  /// which is where a gate's negation-bubble carve-out lives.
  public func contains(_ point: Location) -> Bool {
    let translated = point.translate(-location.x, -location.y)
    guard let instanceFactory else { return bounds.contains(point) }
    return instanceFactory.contains(translated, attributeSet)
  }

  /// `contains(Location, Graphics)` (`InstanceComponent.java:223-226`): the *other* predicate,
  /// and the one every label click depends on:
  ///
  /// ```java
  /// final var field = textField;
  /// return (field != null && field.getBounds(g).contains(pt)) ? true : contains(pt);
  /// ```
  ///
  /// Without it a label drawn outside the body, which is where `InstanceLabelProvider` puts it
  /// for the overwhelming majority of factories, `bds.y - 3` above the body, cannot be clicked
  /// at all: `TextTool` finds nothing under the cursor and drops a free-standing `Text`
  /// annotation instead of editing the label the user aimed at. See
  /// `LogisimFile.ComponentTextFieldMetrics` for why the `Graphics` arrives as a measurer and why
  /// the seam is shaped the way it is.
  public func contains(_ point: Location, measurer: any TextMeasurer) -> Bool {
    if let box = textFieldBounds(measurer: measurer), box.contains(point) { return true }
    return contains(point)
  }

  /// `InstanceComponent.textField.getBounds(g)`: the box this component's editable label
  /// occupies, or `nil` where upstream's `textField` is `null`.
  ///
  /// Also the field half of `getBounds(Graphics)` (`:329-334`), which unions exactly this box
  /// into `bounds`. That union is not ported: its only 4.1.0 callers are painting and selection
  /// code that this port's `RenderScene` pipeline does not route through a component's bounds, so
  /// installing it here would be an accessor nothing reads.
  ///
  /// ── THE TWO ARMS OF UPSTREAM'S `null`, AND WHY `nil` IS RIGHT FOR BOTH ──────────────────────
  ///
  ///   * a factory that never called `setTextField`; `InstanceTextFieldSpec.resolve` answers
  ///     `nil` for exactly that set of components, and it is the same predicate
  ///     `getFeature(TextEditable.class)` already answers with, so the hit test cannot disagree
  ///     with what a hit would then do;
  ///   * **an empty label.** `InstanceTextField.updateField` (`InstanceTextField.java:153-158`)
  ///     *destroys* the field when the text goes empty: `removeTextFieldListener`, `field =
  ///     null`, so in 4.1.0 an unlabelled component hit-tests on its body alone. Read, not
  ///     assumed. Getting this wrong would make the anchor point of every unlabelled component
  ///     in the circuit swallow clicks meant for the sheet.
  ///
  /// ── DERIVED, NOT READ OFF `textField` ───────────────────────────────────────────────────────
  ///
  /// Upstream reads its live `textField`; this port re-derives from the spec and the attribute
  /// set, and the difference is deliberate. `textField` here is **weak** and alive only for the
  /// duration of an edit (see its header), so consulting it would make a hit test depend on
  /// whether some other object still happens to hold a caret; the same gesture answering
  /// differently on ARC's say-so. Re-deriving is deterministic, and it cannot disagree with
  /// upstream anywhere reachable: the only moment the live field's text differs from the
  /// attribute is mid-edit, and `TextTool.mousePressed` tests the open caret's own box and then
  /// commits it *before* it ever reaches a component lookup.
  public func textFieldBounds(measurer: any TextMeasurer) -> Bounds? {
    guard let spec = InstanceTextFieldSpec.resolve(for: self, measurer: measurer) else {
      return nil
    }
    let text = attributeSet[spec.textAttribute] ?? ""
    guard !text.isEmpty else { return nil }
    let field = TextField(
      x: spec.x, y: spec.y, halign: spec.halign, valign: spec.valign,
      font: spec.fontAttribute.flatMap { attributeSet[$0] })
    field.setText(text)
    return field.bounds(measurer: measurer)
  }

  /// `endsAt(Location)`.
  public func endsAt(_ point: Location) -> Bool {
    endArray.contains { $0.location == point }
  }

  /// `getFeature(Object)` → `InstanceFactory.getInstanceFeature(Instance, Object)`.
  public func feature(_ key: ComponentFeatureKey) -> Any? {
    instanceFactory?.instanceFeature(key, self)
  }

  @discardableResult
  public func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription? {
    listeners.add(listener)
  }

  /// `InstanceComponent.fireInvalidated()`.
  public func fireInvalidated() {
    listeners.fireComponentInvalidated(ComponentEvent(source: self))
  }

  // MARK: Port maintenance

  private func attributeValueChanged(_ event: AttributeEvent) {
    if let attribute = event.attribute, attribute === StdAttr.label {
      listeners.fireLabelChanged(ComponentEvent(source: self, data: event))
    }
    recomputePorts()
    if let attribute = event.attribute {
      instanceFactory?.instanceAttributeChanged(self, attribute)
    }
    // `InstanceTextField.attributeValueChanged` (`InstanceTextField.java:58-70`), plus the
    // `setTextField` re-run every factory's `instanceAttributeChanged` performs above it.
    //
    // **Last, and that is upstream's order.** Java's `AbstractAttributeSet` fires its listeners
    // in registration order; `InstanceComponent` registers in its constructor and the
    // `InstanceTextField` only later, from `setTextField`, so the ports and the factory's own
    // reaction are already settled by the time the field is asked to re-derive its placement
    // from them.
    textField?.attributeValueChanged(event)
  }

  /// `InstanceComponent.computeEnds()` merged with every factory's `updatePorts(Instance)`.
  ///
  /// Recompute unconditionally, then diff. Upstream instead filters in
  /// `instanceAttributeChanged` and diffs in `computeEnds`; the diff is what makes the two
  /// equivalent, since an attribute that does not affect the ports produces an identical array
  /// and therefore fires nothing. See `InstanceFactory.swift`'s header.
  ///
  /// **Deviation.** `Port.toEnd` throws (D13) and a listener callback cannot. Upstream lets the
  /// `IllegalArgumentException` escape through `AttributeSet.setValue` to whatever is driving
  /// the edit. Here an end that cannot be computed keeps its previous value, and the component
  /// stays consistent. The only way to reach it is an attribute set that stops answering a
  /// width attribute mid-life, which no stock attribute set does.
  public func recomputePorts() {
    let newPorts = instanceFactory?.ports(attributeSet) ?? []
    var newEnds: [EndData] = []
    newEnds.reserveCapacity(newPorts.count)
    for (index, port) in newPorts.enumerated() {
      if let end = try? port.toEnd(location: location, attributes: attributeSet) {
        newEnds.append(end)
      } else if endArray.indices.contains(index) {
        newEnds.append(endArray[index])
      } else {
        return  // cannot build a coherent end list; leave the old one in place
      }
    }

    guard newEnds != endArray else {
      portList = newPorts
      return
    }
    let oldEnds = endArray
    portList = newPorts
    endArray = newEnds
    listeners.fireEndChanged(ComponentEvent(source: self, oldData: oldEnds, data: newEnds))
  }
}

// MARK: - The `Graphics` argument, supplied

/// `LogisimFile.ComponentTextFieldMetrics`, answered for real.
///
/// This is the module that owns both halves, a `TextMeasurer` and the one component type that
/// can have a text field, which is the whole reason the seam is declared a module below and
/// filled in here. `Circuit.allContaining(_:metrics:)` is the caller.
///
/// Note the fall-through: anything that is not a `StdInstanceComponent` gets the one-argument
/// predicate, which is upstream's answer for `Wire` (`Wire.java:129-131`) and for every
/// `AbstractComponent` (whose `getBounds(Graphics)` is `return getBounds()`). It is also the
/// answer for `LogisimFile.InstanceComponent`, the inert placement record; that type has no text
/// field to union in, so there is nothing to lose, and nothing in the running app puts one in a
/// circuit where a Text-tool click could reach it.
public struct StdComponentTextFieldMetrics: ComponentTextFieldMetrics {

  /// Readable so a test can assert *which* measurer a call site chose, not merely that the box it
  /// produced looks right. The two are not the same claim: a wrong measurer moves the hit box by
  /// a pixel or two, which no byte gate in the tree can see (measured: swapping this for
  /// `NominalTextMeasurer` reddens nothing else).
  public let measurer: any TextMeasurer

  public init(measurer: any TextMeasurer) {
    self.measurer = measurer
  }

  public func contains(_ component: any Component, _ point: Location) -> Bool {
    guard let instance = component as? StdInstanceComponent else {
      return component.contains(point)
    }
    return instance.contains(point, measurer: measurer)
  }
}

extension StdInstanceComponent: CustomStringConvertible {
  public var description: String {
    "StdInstanceComponent[\(factory.name) @ \(location)]"
  }
}
