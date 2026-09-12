// InstanceTextField.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceTextField and the
// `Instance.setTextField` call sites it is reached through),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── WHAT THIS IS, AND WHY IT IS THE ONLY CONFORMER OF `TextEditable` ─────────────────────────
//
// `com.cburch.logisim.tools.TextEditable` has exactly one implementor in 4.1.0, and it is not a
// component: it is `InstanceTextField`, the in-canvas editable label that
// `InstanceComponent.getFeature(TextEditable.class)` hands back (`InstanceComponent.java:362-374`).
// The field itself is only ever built by `InstanceComponent.setTextField` (`:443-453`), reached
// from a factory's `configureNewInstance` via `Instance.setTextField(labelAttr, fontAttr, x, y,
// halign, valign)`.
//
// This port has no `Instance` facade (D3) and no `setTextField` (D6; the six arguments are all
// paint-time facts, and `InstancePainter.drawLabel()` already recomputes them on demand through
// `InstanceLabelProvider`/`LabelPlacement`). So the six arguments come across as data,
// `InstanceTextFieldSpec`, and are re-derived rather than pushed in. `LabelPlacement`'s own
// header records why that is sound: every upstream `computeLabel`/`configureLabel` is a pure
// function of the attribute set and the location, which is exactly why upstream has to re-run
// them from `instanceAttributeChanged`.
//
// The field itself is built on demand and then **registered on the component for the life of the
// edit** (`StdInstanceComponent.textField`, a weak reference; see that property for why the
// direction is inverted from Java's). Board #79 is why: an attribute-table edit landing under an
// open caret has to reach the field, and a field nothing can name cannot be told.
//
// ── THE SPLIT, STATED ONCE ──────────────────────────────────────────────────────────────────
//
// This file is the model half and is `import`-clean of AppKit/SwiftUI (D9). It knows which
// attribute holds the text, which holds the font, where the text sits, and how to write a new
// value back. It does **not** know what a `Caret` is: `Caret`, `TextEditable` and the caret's
// drawing all live in `LogisimUI`, and `LogisimUI/Tools/InstanceTextEditable.swift` is where this
// type acquires its `TextEditable` conformance; the same shape `Wire: CustomHandles` already
// uses, and for the same reason (a lower module cannot name a protocol declared above it).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - The spec

/// `Instance.setTextField(Attribute<String>, Attribute<Font>, int x, int y, int halign,
/// int valign)`, as data.
///
/// Upstream's call is a side effect on the component; here it is a value the component's factory
/// can be asked for, which is what removes the need for `InstanceComponent` to carry a mutable
/// `textField` field at all.
public struct InstanceTextFieldSpec {
  /// `labelAttr`; the attribute the edited string is read from and written to.
  public var textAttribute: Attribute<String>
  /// `fontAttr`. `nil` for a factory that passes `null`, which upstream's `createField` then
  /// resolves to the graphics context's font.
  public var fontAttribute: Attribute<FontSpec>?
  public var x: Int
  public var y: Int
  public var halign: HAlign
  public var valign: VAlign

  public init(
    textAttribute: Attribute<String>,
    fontAttribute: Attribute<FontSpec>?,
    x: Int,
    y: Int,
    halign: HAlign,
    valign: VAlign
  ) {
    self.textAttribute = textAttribute
    self.fontAttribute = fontAttribute
    self.x = x
    self.y = y
    self.halign = halign
    self.valign = valign
  }
}

/// A factory whose components carry an editable text field that is **not** the generic
/// `StdAttr.LABEL` in the generic place; i.e. one whose upstream `configureNewInstance` passes
/// something other than `(StdAttr.LABEL, StdAttr.LABEL_FONT, computeLabelTextField(...))`.
///
/// `std.base.Text` is the case that matters: its field *is* the component, anchored at the
/// component's own location and aligned by `ATTR_HALIGN`/`ATTR_VALIGN` (`Text.java:75-84`). A
/// factory that does not conform gets the generic derivation below.
public protocol InstanceTextFieldProvider: AnyObject {
  func textFieldSpec(
    _ component: StdInstanceComponent, measurer: any TextMeasurer
  ) -> InstanceTextFieldSpec?
}

extension InstanceTextFieldSpec {

  /// `InstanceComponent.textField != null`, which factories have one, and where it sits.
  ///
  /// Two arms, matching the two shapes upstream's forty-odd `setTextField` call sites take:
  ///
  ///   * a factory that answers `InstanceTextFieldProvider` states its own attributes and
  ///     placement (`std.base.Text`);
  ///   * everything else uses `StdAttr.LABEL` / `StdAttr.LABEL_FONT` placed by
  ///     `Instance.computeLabelTextField`, which this port spells
  ///     `InstanceLabelProvider.labelPlacement(_:)`.
  ///
  /// The second arm is the load-bearing one: it makes every component that already draws a label
  /// editable, with no per-factory wiring, and it cannot drift from where the label is drawn
  /// because it asks the same function `drawLabel()` asks.
  ///
  /// `nil` means this component has no editable text: upstream's `getFeature(TextEditable.class)`
  /// returning a null `textField`, which is the answer for a component whose factory never called
  /// `setTextField`.
  public static func resolve(
    for component: StdInstanceComponent, measurer: any TextMeasurer
  ) -> InstanceTextFieldSpec? {
    if let provider = component.factory as? any InstanceTextFieldProvider {
      return provider.textFieldSpec(component, measurer: measurer)
    }
    guard component.attributeSet.containsAttribute(StdAttr.label) else { return nil }
    guard let provider = component.factory as? InstanceLabelProvider else { return nil }
    // `labelPlacement` takes an `InstancePainter` because upstream's `computeLabelTextField`
    // reads the component's bounds and facing; none of the implementations touch the emitter or
    // the circuit state, so a scratch builder over a `StaticPaintContext` answers exactly what a
    // real paint pass would.
    let painter = InstancePainter(
      g: SceneBuilder(measurer: measurer), context: StaticPaintContext(), component: component)
    guard let placement = provider.labelPlacement(painter) else { return nil }
    return InstanceTextFieldSpec(
      textAttribute: StdAttr.label,
      fontAttribute: StdAttr.labelFont,
      x: placement.x,
      y: placement.y,
      halign: placement.halign,
      valign: placement.valign)
  }
}

// MARK: - InstanceTextField

/// `com.cburch.logisim.instance.InstanceTextField`, model half.
///
/// One instance per *editing session*, reachable from the component for as long as that session
/// lasts. Upstream keeps one per component for life because the field caches the text, the font,
/// the colour and the visibility and those caches must not go stale; this port caches none of
/// them; `draw` is `InstancePainter.drawLabel()`, which reads all four from the attribute set at
/// paint time. What is left is the two `TextEditable` methods, the write-back, and the one thing
/// that genuinely needs the field to outlive a single call:
///
/// ── `attributeValueChanged`, AND WHY IT IS NOW PORTED (board #79) ────────────────────────────
///
/// Change a component's label in the attribute table *while a caret is open on that same label*
/// and commit the caret. Upstream pushes the new attribute value into the `TextField`
/// (`InstanceTextField.java:58-70` → `updateField` → `field.setText`), which fires
/// `TextFieldCaret.textChanged` and restarts the editing session from the new string, so the
/// commit agrees with the table. With no such push the caret still holds what the user was
/// typing and writes it over the table's edit: a completed, undoable edit silently lost.
///
/// Reaching the live field needs the component to know about it, which is why
/// `StdInstanceComponent.textField` exists and why its header explains at length why that edge is
/// weak while Java's is strong.
///
/// ── ONE ARM OF `updateField` IS DELIBERATELY NOT REPRODUCED ─────────────────────────────────
///
/// Upstream's `updateField` **destroys** the field when the text becomes empty (`:184-188`:
/// remove the listener, null the reference). Reproducing that here would reinstate exactly the
/// loss this board closes, for the empty case only: an open caret holds the `TextField` itself,
/// so a field dropped underneath it keeps the caret editing the stale string, and clearing a
/// label from the attribute table mid-edit would still be overwritten on commit. (That is what
/// 4.1.0 does: verified by reading, not assumed.) The arm exists upstream to make `draw` and
/// `getBounds(Graphics)` answer nothing for an empty label; neither is ported, because
/// `drawLabel()` already draws nothing for an empty attribute. So the field survives an empty
/// value and is simply set to `""`, which keeps the caret in step in both directions.
///
/// Contrast `TextTool.editingStopped`'s `add`-labelled-`remove`, which IS reproduced bug for bug
/// because there the wrong behaviour changes the saved bytes and the M7 gate pins them.
public final class InstanceTextField: TextFieldListener {

  /// `comp`; upstream's is `final InstanceComponent`. Strong, and the component's reference back
  /// is the weak one; `StdInstanceComponent.textField` states why that direction and not the
  /// other.
  public let component: StdInstanceComponent

  /// The six `setTextField` arguments.
  ///
  /// `var`, and re-derived rather than remembered; see `attributeValueChanged`. Upstream keeps
  /// these fresh by re-running `setTextField` from every factory's `instanceAttributeChanged`;
  /// this port has no `setTextField` (D6), so freshness comes from re-asking
  /// `InstanceTextFieldSpec.resolve`, which is the same `InstanceLabelProvider.labelPlacement`
  /// call `InstancePainter.drawLabel()` makes. That is what keeps an open caret on top of the
  /// label instead of where the label used to be.
  public private(set) var spec: InstanceTextFieldSpec

  /// The metrics source `resolve` is re-asked with, kept so a later re-derivation measures the
  /// same way the first one did. Upstream reaches a live `Graphics`; there is none here (D6).
  private let measurer: any TextMeasurer

  /// `field`. Built lazily by `ensureField`, which is upstream's `createField` fused with
  /// `updateField`'s "an existing field is re-read, not rebuilt" arm.
  public private(set) var field: TextField?

  public init(
    component: StdInstanceComponent, spec: InstanceTextFieldSpec, measurer: any TextMeasurer
  ) {
    self.component = component
    self.spec = spec
    self.measurer = measurer
  }

  /// `InstanceComponent.getFeature(TextEditable.class)`; nil when the factory never called
  /// `setTextField`.
  ///
  /// Upstream returns the *same* field object every time, because `getFeature` just reads
  /// `textField`. So does this: a component with a live field (i.e. one with an edit in progress)
  /// answers that one, refreshed, rather than minting a second field the component would not know
  /// about, which would leave the in-progress caret's field orphaned and unsynced.
  public static func make(
    for component: StdInstanceComponent, measurer: any TextMeasurer
  ) -> InstanceTextField? {
    guard let spec = InstanceTextFieldSpec.resolve(for: component, measurer: measurer) else {
      return nil
    }
    if let existing = component.textField {
      existing.spec = spec
      existing.updateFieldIfPresent()
      return existing
    }
    let made = InstanceTextField(component: component, spec: spec, measurer: measurer)
    component.textField = made
    return made
  }

  /// The current value of the text attribute: `attrs.getValue(labelAttr)`, with Java's `null`
  /// collapsed to `""` the way every reader here treats it.
  public var text: String {
    component.attributeSet[spec.textAttribute] ?? ""
  }

  /// `createField(AttributeSet, String)` + `updateField(AttributeSet)`.
  ///
  /// Idempotent: the second call re-reads the font, the placement and the text, which is what
  /// `updateField` does for an existing field.
  @discardableResult
  public func ensureField() -> TextField {
    if let field {
      updateField(field)
      return field
    }
    let created = TextField(
      x: spec.x, y: spec.y, halign: spec.halign, valign: spec.valign,
      font: spec.fontAttribute.flatMap { component.attributeSet[$0] })
    created.setText(text)
    created.addTextFieldListener(self)
    field = created
    return created
  }

  /// `updateField(AttributeSet)`'s "the field already exists" arm (`:192-197`), which is the
  /// whole of it here; see the type header for why the "text went empty, drop the field" arm is
  /// deliberately not reproduced.
  ///
  /// `TextField.setText` fires only on a real change, so this is safe to run on every attribute
  /// event: an attribute that moves nothing notifies nobody. It is also why the re-entrancy
  /// terminates: `setText` publishes to `textChanged`, which writes the attribute, which comes
  /// back here to a `setText` that now matches and returns without firing.
  private func updateField(_ field: TextField) {
    field.font = spec.fontAttribute.flatMap { component.attributeSet[$0] }
    field.setLocation(x: spec.x, y: spec.y, halign: spec.halign, valign: spec.valign)
    field.setText(text)
  }

  fileprivate func updateFieldIfPresent() {
    if let field { updateField(field) }
  }

  /// `InstanceTextField.attributeValueChanged(AttributeEvent)` (`:58-70`), fused with the
  /// `setTextField` re-run that upstream's factories drive from `instanceAttributeChanged`.
  ///
  /// Upstream splits by attribute; `labelAttr` re-reads the text, `fontAttr` re-reads the font,
  /// `LABEL_COLOR` and `LABEL_VISIBILITY` refresh caches this port does not keep. Here every
  /// event does the same two things unconditionally, and that is a superset rather than a
  /// difference: re-deriving the spec and re-reading the attribute set is idempotent, and
  /// `setText`/`setLocation`/`font` on unchanged values notify nothing. It also covers the
  /// attributes upstream reaches only indirectly: `FACING`, `LABEL_LOC` and the rest move the
  /// label, and upstream picks them up by re-running `setTextField` from each factory's
  /// `instanceAttributeChanged`, which this port does not have.
  ///
  /// Called only by `StdInstanceComponent.attributeValueChanged`, and only while a field is
  /// alive, so the `resolve` below runs at most once per attribute edit *during an open caret*.
  public func attributeValueChanged(_ event: AttributeEvent) {
    // A `nil` answer means the component no longer has editable text at all; the label
    // attribute left the set, or the factory was retargeted. Upstream cannot express that (its
    // six arguments were pushed in and stay), so there is no behaviour to match; keeping the
    // last known placement is the answer that cannot move an open caret somewhere arbitrary.
    if let recomputed = InstanceTextFieldSpec.resolve(for: component, measurer: measurer) {
      spec = recomputed
    }
    updateFieldIfPresent()
  }

  /// `InstanceTextField.textChanged(TextFieldEvent)`; the write-back.
  ///
  /// D13: `setValue` throws in this port where upstream's does not. The only reachable failure is
  /// an attribute set that rejects a `String` for the attribute the factory itself named, which
  /// is a broken factory rather than bad user input; the write is dropped and the commit action
  /// that follows sets the same value through the undo stack anyway.
  public func textChanged(_ event: TextFieldEvent) {
    guard event.text != event.oldText else { return }
    try? component.attributeSet.setValue(spec.textAttribute, event.text)
  }
}

// MARK: - std.base.Text

/// `Text.configureLabel(Instance)` (`Text.java:75-84`).
///
/// The annotation's text field is anchored at the component's own location and aligned by its two
/// alignment attributes: not by `computeLabelTextField`, and not on `StdAttr.LABEL`. This is the
/// whole reason `InstanceTextFieldProvider` exists.
extension Text: InstanceTextFieldProvider {
  public func textFieldSpec(
    _ component: StdInstanceComponent, measurer: any TextMeasurer
  ) -> InstanceTextFieldSpec? {
    guard let attrs = component.attributeSet as? TextAttributes else { return nil }
    let location = component.location
    return InstanceTextFieldSpec(
      textAttribute: Text.attrText,
      fontAttribute: Text.attrFont,
      x: location.x,
      y: location.y,
      // `TextHorizontalAlign.alignmentValue` and `HAlign.rawValue` are both the
      // `GraphicsUtil.H_*` constant, so this is a re-tag rather than a mapping. The `??` arms
      // are unreachable for the four options the attribute admits and are the D13-correct
      // answer for a `.circ` file that somehow carried another.
      halign: HAlign(rawValue: attrs.horizontalAlign) ?? .center,
      valign: VAlign(rawValue: attrs.verticalAlign) ?? .baseline)
  }
}
