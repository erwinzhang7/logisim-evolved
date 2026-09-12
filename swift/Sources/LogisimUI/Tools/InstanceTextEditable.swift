// InstanceTextEditable.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceTextField's
// `getTextCaret`/`getCommitAction`, i.e. its `com.cburch.logisim.tools.TextEditable` half),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── THE CONFORMER `TextEditable` HAS BEEN WAITING FOR ───────────────────────────────────────
//
// `TextEditable` is declared in `LogisimUI` because its two methods are spelled in tool-layer
// vocabulary: one returns a `Caret`, the other an undoable `Action`. Its only upstream implementor
// is `InstanceTextField`, which is a component-layer object and therefore lives in `LogisimStd`,
// *below* this module. A type cannot conform to a protocol it is not allowed to name, which is
// precisely why this seam sat open, and why the fix is a retroactive conformance declared up
// here, exactly as `extension Wire: CustomHandles {}` in `ToolFeatures.swift` already is, and for
// the identical reason: a single known concrete type, whose module cannot see the protocol.
//
// The alternative, moving `TextEditable` down beside `InstanceTextField`, the way `WireRepair`
// was moved, does not work here and it is worth saying why, so nobody re-tries it. `WireRepair`
// travels as a plain predicate over a `Location`; nothing in it is UI. `TextEditable` returns a
// `Caret`, and `Caret`'s own vocabulary is `ToolMouseEvent`, `ToolKeyEvent`, `ToolOverlayItem`,
// `PaintContext` and `RenderScene`. Moving it down would drag the entire tool-input surface into
// `LogisimStd`, which is D9's exact prohibition.

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

// MARK: - The measurer

extension InstanceTextField {
  /// The metrics source the canvas itself renders with.
  ///
  /// Upstream's `getTextCaret` reads `event.getCanvas().getGraphics()` and hands that `Graphics`
  /// to the field and the caret, so the box a click is tested against is measured with the same
  /// font engine that drew the label. `ComponentUserEvent` here deliberately carries no canvas
  /// (see its header), so the equivalent guarantee comes from using the same shared
  /// `CoreTextCache` the renderer uses, which is what `CoreTextMeasurer()`'s default argument
  /// resolves to.
  static let canvasMeasurer: any TextMeasurer = CoreTextMeasurer()
}

// MARK: - TextEditable

extension InstanceTextField: TextEditable {

  /// `InstanceTextField.getCommitAction(Circuit, String, String)` (`:107-112`).
  ///
  /// ── ONE DELIBERATE DIVERGENCE, AND IT IS THE DIFFERENCE BETWEEN UNDOABLE AND NOT ──────────
  ///
  /// Upstream's body is two lines: build a `SetAttributeAction` and `act.set(comp, labelAttr,
  /// newText)`. That looks undoable and is not, and the reason is an ordering upstream never
  /// reconciled:
  ///
  ///   1. `TextFieldCaret.stopEditing` calls `field.setText(curText)` **first**
  ///      (`TextFieldCaret.java:352-355`);
  ///   2. that fires `InstanceTextField.textChanged`, which writes `newText` straight into the
  ///      component's attribute set (`InstanceTextField.java:126-132`): no transaction, no undo
  ///      entry;
  ///   3. *then* the listeners run, `TextTool.editingStopped` asks for this action, and
  ///      `SetAttributeAction.doIt` routes the write through a `CircuitMutation`;
  ///   4. `CircuitMutatorImpl.set` records the old value **at execute time**
  ///      (`CircuitMutatorImpl.java:120-129`): by which point it is already `newText`.
  ///
  /// So the reverse transaction sets `newText` back to `newText`, and ⌘Z on a label edit in
  /// 4.1.0 restores nothing. Verified by reading, not assumed: `SetAttributeAction.doIt` takes
  /// the in-circuit branch for a placed component, and that branch keeps no `oldValue` of its own.
  ///
  /// This port puts `oldText` back before handing the action over, so the mutation records the
  /// value the user actually started from. The forward result is byte-identical, the attribute
  /// ends at `newText` either way, so a scripted edit saves the same `.circ`, and the difference
  /// is visible only after an undo, where upstream is wrong. An edit that silently bypasses the
  /// undo stack is data loss, not a cosmetic divergence, which is why this one is corrected
  /// rather than reproduced; contrast `TextTool.editingStopped`'s `add`-labelled-`remove`, which
  /// IS reproduced because there the wrong behaviour changes the saved bytes.
  public func commitAction(circuit: Circuit, oldText: String, newText: String) -> Action? {
    // `textChanged` has already written `newText` directly. Roll it back so the transaction
    // below has a real old value to invert. `try?` for the same D13 reason `textChanged` uses
    // one: the only failure is a factory naming an attribute its own set rejects.
    try? component.attributeSet.setValue(spec.textAttribute, oldText)

    let action = SetAttributeAction(circuit: circuit, name: .changeLabel)
    action.set(component, spec.textAttribute, newText)
    return action
  }

  /// `InstanceTextField.getTextCaret(ComponentUserEvent)` (`:114-133`).
  ///
  /// Three arms, transcribed:
  ///
  ///   * no text at all → a caret at position 0, with **no hit test**. This is what makes the
  ///     Text tool able to create a fresh annotation anywhere on the sheet: an empty field has
  ///     an empty box, so a hit test would refuse every click.
  ///   * a degenerate box (under 4 units either way) → union it with a 2-unit square at the
  ///     component's location before testing, so a one-character label is still clickable.
  ///   * otherwise → hit-test, and answer `nil` outside. `nil` is not an error; `TextTool`
  ///     treats it as "this component declined" and moves to the next candidate.
  public func textCaret(_ event: ComponentUserEvent) -> (any Caret)? {
    let measurer = InstanceTextField.canvasMeasurer
    let field = ensureField()

    if field.text.isEmpty {
      return TextFieldCaret(field: field, owner: self, measurer: measurer, position: 0)
    }

    var box = field.bounds(measurer: measurer)
    if box.width < 4 || box.height < 4 {
      box = box.add(Bounds.create(component.location).expand(2))
    }
    guard box.contains(event.x, event.y) else { return nil }
    return TextFieldCaret(
      field: field, owner: self, measurer: measurer, x: event.x, y: event.y)
  }
}

// MARK: - The action name

extension ToolActionName {
  /// `S.getter("changeLabelAction")`: `std.properties:433`, `Change Label` in the `en` bundle.
  ///
  /// Declared here rather than beside the other seven in `ToolSeams.swift` because this slice
  /// does not own that file. The consequence is small and worth naming: `displayName` falls
  /// through to its `default` arm and renders the raw key, so the Edit menu reads
  /// "Undo changeLabelAction" until one line is added to that switch. `actionName.key`, which
  /// is what a differential test asserts on: is already correct.
  public static let changeLabel = ToolActionName("changeLabelAction")
}
