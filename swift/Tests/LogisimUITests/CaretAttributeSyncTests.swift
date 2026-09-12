// CaretAttributeSyncTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.{InstanceTextField,
// InstanceComponent}, com.cburch.logisim.comp.{TextField, TextFieldCaret},
// com.cburch.logisim.tools.TextTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// AN ATTRIBUTE-TABLE EDIT MADE WHILE A CARET IS OPEN MUST SURVIVE THE COMMIT
//
// `InstanceTextField.attributeValueChanged` (`InstanceTextField.java:58-70`) has exactly one
// consequence this port can observe: when the label attribute changes *underneath an open
// caret*, upstream pushes the new string into the `TextField`, which fires
// `TextFieldCaret.textChanged` and restarts the editing session from it. Without that push the
// caret still holds the string the user was typing, and committing writes it over the table's
// edit; the table's value is silently lost.
//
// ── WHY THIS SUITE INTERLEAVES, AND WHY A NON-INTERLEAVED TEST PROVES NOTHING ────────────────
//
// This is a *sequencing* defect, not a value defect. Every one of these orderings is already
// green against the broken code and none of them touches the bug:
//
//   * change the attribute, then open a caret    ; the caret is built from the new value;
//   * open a caret, commit it, then change       ; the two edits never overlap;
//   * change an attribute no caret is editing    ; nothing to overwrite.
//
// The only shape that fails is: **open the caret, type into it, change the same attribute from
// outside, then commit.** Both tests below have exactly that shape, and each asserts the
// intermediate state (the attribute really did become the table's value while the caret was
// live) so that a failure cannot be blamed on the outside edit never landing.
//
// ── TWO ALTITUDES, DELIBERATELY ─────────────────────────────────────────────────────────────
//
// `caretIsReseeded…` drives the model directly: a `StdInstanceComponent`, an
// `InstanceTextField`, a `TextFieldCaret`, no project and no canvas. It names the mechanism,
// the caret's own text, so a failure points at the sync, not at the tool.
//
// `theTableEditSurvives…` drives the shipping stack: the real `CircuitEditorCanvas`, the real
// Text tool, real pointer and key events, and an attribute edit built from the same three lines
// `LogisimFileProjectHost.apply(AttributeEdit:)` executes for a row of the inspector
// (`beginMutation` / `set` / `doAction`). It names the consequence; the saved attribute.
//
// The third test is the guard on the fix rather than on the bug: the six `setTextField`
// arguments must keep being *recomputed* from `InstanceLabelProvider.labelPlacement`, which is
// the same function `InstancePainter.drawLabel()` uses. An ownership change that cached the
// placement would make an open caret sit where the label used to be drawn.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// The same rig `CanvasTextEditingTests` uses, a real project, a real surface, a real
/// `CircuitEditorCanvas`, restated here because that one is `private` to its own file.
@MainActor
private struct Rig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let canvas: CircuitEditorCanvas

  init() throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: SelectTool())
  }

  @discardableResult
  func selectTextTool() throws -> LogisimUI.TextTool {
    let accepted = canvas.controller.setActiveTool(
      fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.textTool))
    #expect(accepted, "the controller does not resolve BaseToolIds.textTool at all")
    return try #require(canvas.controller.activeTool as? LogisimUI.TextTool)
  }

  @discardableResult
  func add(
    _ factory: any ComponentFactory, at point: (Int, Int), label: String? = nil
  ) throws -> any Component {
    let attributes = factory.createAttributeSet()
    if let label { try attributes.setValue(StdAttr.label, label) }
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)
    return component
  }

  func click(_ x: Int, _ y: Int) {
    for phase in [CanvasPointerEvent.Phase.down, .up] {
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase,
          world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
          modifiers: [],
          clickCount: 1,
          buttonNumber: 1,
          dragOriginWorld: nil))
    }
  }

  @discardableResult
  func key(_ characters: String, keyCode: UInt16 = 0, modifiers: CanvasModifiers = []) -> Bool {
    canvas.controller.canvasHandleKey(
      CanvasKeyEvent(
        phase: .down, characters: characters, keyCode: keyCode, modifiers: modifiers,
        isRepeat: false))
  }

  func type(_ string: String) {
    for character in string { _ = key(String(character)) }
  }

  func returnKey() { _ = key("\r", keyCode: 0x24) }

  /// The attribute table's write, spelled exactly as `LogisimFileProjectHost.apply(_:)` spells
  /// it: a `CircuitMutation` carrying one `set`, performed through the project so it lands on
  /// the undo stack. Nothing here knows a caret is open, which is the whole point.
  func editFromTheAttributeTable<V>(
    _ component: any Component, _ attribute: Attribute<V>, _ value: V
  ) throws {
    let mutation = project.beginMutation(on: circuit)
    mutation.set(component, attribute, value)
    try project.doAction(mutation.toAction("Change Label"))
  }

  func label(of component: any Component) -> String? { component.attributeSet[StdAttr.label] }
}

/// Where the label sits, taken from the same function the painter uses.
@MainActor
private func placement(of component: any Component) -> InstanceTextFieldSpec? {
  guard let std = component as? StdInstanceComponent else { return nil }
  return InstanceTextFieldSpec.resolve(for: std, measurer: CoreTextMeasurer())
}

/// A component, its text field and an open caret over it: the model half of the gesture, with
/// no project behind it.
///
/// The `InstanceTextField` is returned and must be held by the caller: the caret holds it
/// strongly as its `owner`, and the component refers to it only weakly, so dropping both ends
/// the session exactly as abandoning the edit does.
@MainActor
private func openCaret(
  on component: StdInstanceComponent
) throws -> (field: InstanceTextField, caret: TextFieldCaret) {
  let editable = try #require(
    InstanceTextField.make(for: component, measurer: CoreTextMeasurer()),
    "the component answers no editable text field at all")
  let textField = editable.ensureField()
  let caret = TextFieldCaret(
    field: textField, owner: editable, measurer: CoreTextMeasurer(),
    position: textField.text.count)
  return (editable, caret)
}

@MainActor
private func typeInto(_ caret: TextFieldCaret, _ string: String) {
  for character in string {
    var event = ToolKeyEvent(character: character, rawKeyCode: 0)
    caret.keyTyped(&event)
  }
}

// MARK: - The gate

@Suite("A caret and the attribute table editing the same label at the same time", .serialized)
@MainActor
struct CaretAttributeSyncTests {

  // ── 1. The mechanism: the open caret is re-seeded from the attribute ──────────────────────

  /// `InstanceTextField.attributeValueChanged` → `updateField` → `field.setText(text)` →
  /// `TextFieldCaret.textChanged` (`TextFieldCaret.java:377-383`), which restarts the session
  /// from the new string and parks the caret at its end.
  ///
  /// Without the push the caret is still editing `A1` when the table has already stored `Q`.
  @Test("an outside write to the label attribute re-seeds an open caret")
  func caretIsReseededByAnOutsideAttributeWrite() throws {
    StdLibraries.registerAll()
    let attributes = AndGate.factory.createAttributeSet()
    try attributes.setValue(StdAttr.label, "A")
    let component = try #require(
      try AndGate.factory.createComponent(
        location: Location.create(200, 100, hasToSnap: false), attributes: attributes)
        as? StdInstanceComponent)

    let (field, caret) = try openCaret(on: component)
    typeInto(caret, "1")
    #expect(caret.text == "A1", "the caret is not editing what the user typed: \(caret.text)")
    #expect(
      component.attributeSet[StdAttr.label] == "A",
      "typing must not have reached the attribute yet — the commit does that")

    // The attribute table writes the same attribute while the caret is up.
    try component.attributeSet.setValue(StdAttr.label, "Q")
    #expect(
      component.attributeSet[StdAttr.label] == "Q",
      "the outside write never landed, so this test proves nothing about the caret")

    #expect(
      caret.text == "Q",
      """
      the caret is still editing \(caret.text). InstanceTextField.attributeValueChanged never \
      reached the field, so committing will write \(caret.text) over the table's Q.
      """)
    #expect(field.field?.text == "Q", "the TextField itself was not updated")

    // And committing now agrees with the table rather than overwriting it.
    caret.stopEditing()
    #expect(component.attributeSet[StdAttr.label] == "Q")
  }

  /// The negative control. With no outside write the caret still wins, which is the ordinary
  /// case and the one a too-eager "always re-read the attribute" fix would break.
  @Test("with no outside write the caret's own text still commits")
  func caretStillWinsWhenNobodyElseWrites() throws {
    StdLibraries.registerAll()
    let attributes = AndGate.factory.createAttributeSet()
    try attributes.setValue(StdAttr.label, "A")
    let component = try #require(
      try AndGate.factory.createComponent(
        location: Location.create(200, 100, hasToSnap: false), attributes: attributes)
        as? StdInstanceComponent)

    let (_, caret) = try openCaret(on: component)
    typeInto(caret, "1")
    caret.stopEditing()
    #expect(component.attributeSet[StdAttr.label] == "A1")
  }

  // ── 2. The consequence, through the shipping stack ───────────────────────────────────────

  /// Place a gate labelled `A`, open its label with the Text tool, type `1`, then edit the same
  /// attribute from the attribute table, then press Return.
  ///
  /// The table's value must be what the component ends up with. Before the fix the commit wrote
  /// the caret's own string (`1A`; the click lands at the anchor, which `findCaret` resolves to
  /// position 0) over it, which is a silent loss of a completed, undoable edit.
  @Test("an attribute-table edit made while the caret is open survives the commit")
  func theTableEditSurvivesTheCommit() throws {
    let rig = try Rig()
    let gate = try rig.add(AndGate.factory, at: (200, 100), label: "A")
    try rig.selectTextTool()

    let anchor = try #require(placement(of: gate), "the gate has no label placement")
    rig.click(anchor.x, anchor.y)
    rig.type("1")
    #expect(rig.label(of: gate) == "A", "typing reached the attribute before the commit")

    try rig.editFromTheAttributeTable(gate, StdAttr.label, "Q")
    #expect(
      rig.label(of: gate) == "Q",
      "the attribute-table edit never landed, so this test proves nothing about the caret")

    rig.returnKey()

    #expect(
      rig.label(of: gate) == "Q",
      """
      the label is \(rig.label(of: gate) ?? "nil"). The caret committed the string it was \
      holding when the table edit arrived, overwriting a completed edit the user had already \
      made — InstanceTextField.attributeValueChanged is what keeps the two in step.
      """)
  }

  // ── 3. D3: the new edge must not close a cycle ───────────────────────────────────────────

  /// The component now refers to its live `InstanceTextField`, and that field refers back to the
  /// component. Upstream's pair is exactly this and is a strong 2-cycle: fine under a GC, a
  /// permanent leak of the component, its attribute set and its ends under ARC, on every
  /// component whose label is ever clicked. `StdInstanceComponent.textField` is weak for that
  /// reason; this is the measurement, and it is a better instrument than `leaks` because it names
  /// the two objects rather than a byte count.
  ///
  /// (It is also the one that can actually run: `leaks --atExit -- <the .xctest binary>` cannot
  /// execute a Mach-O *bundle*, prints `cannot execute binary file`, and still exits 0, see the
  /// task report.)
  @Test("an ended edit session releases both the text field and the component")
  func theNewEdgeClosesNoCycle() throws {
    StdLibraries.registerAll()
    weak var releasedField: InstanceTextField?
    weak var releasedComponent: StdInstanceComponent?

    try {
      let attributes = AndGate.factory.createAttributeSet()
      try attributes.setValue(StdAttr.label, "A")
      let component = try #require(
        try AndGate.factory.createComponent(
          location: Location.create(200, 100, hasToSnap: false), attributes: attributes)
          as? StdInstanceComponent)
      releasedComponent = component

      let (field, caret) = try openCaret(on: component)
      releasedField = field
      #expect(component.textField === field, "the component never learned about its field")
      typeInto(caret, "1")
      caret.stopEditing()
      withExtendedLifetime((field, caret)) {}
    }()

    #expect(
      releasedField == nil,
      "the InstanceTextField outlived its edit — component ⇄ field is a retain cycle")
    #expect(
      releasedComponent == nil,
      "the component outlived its own text field, which is the same cycle seen from the other end")
  }

  // ── 4. The invariant the fix must not break ──────────────────────────────────────────────

  /// The six `setTextField` arguments are *derived*, never stored: `InstanceTextFieldSpec.resolve`
  /// recomputes them from `InstanceLabelProvider.labelPlacement`, the same function
  /// `InstancePainter.drawLabel()` reads. An `InstanceTextField` that outlives a single attribute
  /// change must therefore re-derive them, or an open caret drifts away from where the label is
  /// drawn.
  ///
  /// `Pin`'s label placement follows `StdAttr.FACING`, so rotating the pin moves the anchor; the
  /// first assertion proves the move is real, and the second proves the live field followed it.
  @Test("a live text field re-derives its placement when the label moves")
  func placementIsRederivedNotCached() throws {
    StdLibraries.registerAll()
    let attributes = Pin.factory.createAttributeSet()
    try attributes.setValue(StdAttr.label, "clk")
    let component = try #require(
      try Pin.factory.createComponent(
        location: Location.create(200, 100, hasToSnap: false), attributes: attributes)
        as? StdInstanceComponent)

    let (field, _) = try openCaret(on: component)
    let before = try #require(placement(of: component))
    #expect(field.field?.x == before.x && field.field?.y == before.y)

    try component.attributeSet.setValue(StdAttr.facing, Direction.south)

    let after = try #require(placement(of: component))
    #expect(
      (after.x, after.y) != (before.x, before.y),
      "rotating the pin did not move its label anchor, so this test measures nothing")
    #expect(
      field.spec.x == after.x && field.spec.y == after.y,
      "the spec is stale: \((field.spec.x, field.spec.y)) against \((after.x, after.y))")
    #expect(
      field.field?.x == after.x && field.field?.y == after.y,
      "the live TextField is stale: \((field.field?.x ?? 0, field.field?.y ?? 0))")
  }
}
