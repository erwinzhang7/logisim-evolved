// CanvasTextEditingTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.{TextField, TextFieldCaret},
// com.cburch.logisim.instance.InstanceTextField, com.cburch.logisim.tools.{TextTool,
// TextEditable, SetAttributeAction}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN YOU CLICK A LABEL ON THE CANVAS AND RETYPE IT?
//
// `TextEditable` had no conformer, so `TextTool.findEditable` and `TextTool.createTextComponent`
// both died at their `feature(.textEditable)` lookup and the Text tool was inert: it neither
// edited an existing label nor created a new one. This suite is the evidence that it is not.
//
// ── WHY "TextEditable HAS A CONFORMER" IS NOT THE TEST ───────────────────────────────────────
//
// `ToolFeatureSeamTests` already asserts a conformer exists, against one declared inside the test
// file; it would stay green if nothing in the shipping tree ever conformed. And a conformance
// that answers wrongly is non-nil too. So the observable here is the **edit**: a real pointer
// gesture through `CanvasInteractionHandler` into the application's own `CircuitEditorCanvas`,
// real key events through `canvasHandleKey`, and then two assertions that a half-working
// implementation cannot both satisfy;
//
//   1. the component's label attribute holds the new string, AND
//   2. ⌘Z puts the old string back.
//
// (2) is the one that discriminates, and it is worth saying why it is not free. Upstream's own
// path does not satisfy it: `TextFieldCaret.stopEditing` writes the attribute directly through
// `InstanceTextField.textChanged` *before* `getCommitAction` is asked for an action, and
// `CircuitMutatorImpl.set` reads the old value at execute time: by which point it is already the
// new one. So 4.1.0's reverse transaction sets `newText` back to `newText`. The divergence and
// its reasoning are written out on `InstanceTextField.commitAction` in
// `LogisimUI/Tools/InstanceTextEditable.swift`; this is where it is measured.
//
// ── THE GESTURE, STATED EXACTLY ─────────────────────────────────────────────────────────────
//
// "Double-click a label" is the user's description; in 4.1.0 the in-canvas caret is the **Text
// tool**, and `TextTool.mousePressed` never reads `getClickCount()`; one click opens the caret.
// (`SelectTool.mousePressed` *does* read it, at `SelectTool.java:541`, but a double-click there
// raises the `AutoLabel` modal dialog, which is a different feature and not this seam.) The
// gestures below therefore carry `clickCount: 2`, proving the tool is indifferent to it, as
// upstream is, and go through the Text tool, which is the path that actually edits in place.
//
// ── THE RED PROBE ───────────────────────────────────────────────────────────────────────────
//
// Recorded in the commit that adds this file. Three separate breakages were applied one at a
// time and the suite re-run; each turned exactly the cases that depend on it red and left the
// rest green. See the commit message for the measured counts.
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

/// A project, its real render surface, and a `CircuitEditorCanvas` over both: the same rig
/// `WireRepairComponentTests` and `CanvasTextToolTests` use, for the same reason: the question is
/// whether the *application's* canvas drives the tool, so every part is a shipping one.
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

  /// Select the Text tool the way the explorer does, so the instance under test is the one the
  /// app would use, including the `Text.factory` injection `CanvasToolController` performs.
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

  /// One press/release at a point, delivered exactly as `CanvasHostNSView` delivers it.
  func click(_ x: Int, _ y: Int, clickCount: Int = 2) {
    for phase in [CanvasPointerEvent.Phase.down, .up] {
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase,
          world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
          modifiers: [],
          clickCount: clickCount,
          buttonNumber: 1,
          dragOriginWorld: nil))
    }
  }

  /// A key-down, with the `keyTyped` replay `canvasHandleKey` performs for a printable key.
  @discardableResult
  func key(
    _ characters: String, keyCode: UInt16 = 0, modifiers: CanvasModifiers = []
  ) -> Bool {
    canvas.controller.canvasHandleKey(
      CanvasKeyEvent(
        phase: .down, characters: characters, keyCode: keyCode, modifiers: modifiers,
        isRepeat: false))
  }

  /// Type a string one key at a time, the way a user does.
  func type(_ string: String) {
    for character in string { _ = key(String(character)) }
  }

  func returnKey() { _ = key("\r", keyCode: 0x24) }
  func escapeKey() { _ = key("\u{1B}", keyCode: 0x35) }
  func selectAll() { _ = key("a", keyCode: 0x00, modifiers: .command) }

  func label(of component: any Component) -> String? {
    component.attributeSet[StdAttr.label]
  }
}

/// A caret driven directly, for the key-handling cases. `TextField` is a `LogisimStd` model
/// object with no canvas behind it, so these run without a project at all, which is the point:
/// a caret-behaviour failure should not be reported as a canvas failure.
@MainActor
private func caret(
  over text: String, at position: Int, halign: HAlign = .left, valign: VAlign = .baseline
) -> (field: TextField, caret: TextFieldCaret) {
  let field = TextField(x: 0, y: 0, halign: halign, valign: valign, font: StdAttr.defaultLabelFont)
  field.setText(text)
  let made = TextFieldCaret(
    field: field, owner: nil, measurer: CoreTextMeasurer(), position: position)
  return (field, made)
}

/// AWT virtual key codes arrive through `ToolKeyEvent.rawKeyCode`; these are the AppKit scan
/// codes and character payloads that `CanvasToolController` turns into them.
private enum Keys {
  static let leftArrow: (String, UInt16) = ("\u{F702}", 0x7B)
  static let rightArrow: (String, UInt16) = ("\u{F703}", 0x7C)
  static let upArrow: (String, UInt16) = ("\u{F700}", 0x7E)
  static let downArrow: (String, UInt16) = ("\u{F701}", 0x7D)
  static let backspace: (String, UInt16) = ("\u{7F}", 0x33)
  static let forwardDelete: (String, UInt16) = ("\u{F728}", 0x75)
}

@MainActor
private func press(
  _ caret: TextFieldCaret, _ key: (String, UInt16), _ modifiers: CanvasModifiers = []
) {
  var event = ToolKeyEvent(
    command: CanvasToolController.command(
      for: CanvasKeyEvent(
        phase: .down, characters: key.0, keyCode: key.1, modifiers: modifiers, isRepeat: false)),
    character: key.0.first,
    rawKeyCode: AwtKeyCodes.virtualKeyCode(
      for: CanvasKeyEvent(
        phase: .down, characters: key.0, keyCode: key.1, modifiers: modifiers, isRepeat: false)),
    modifiers: ToolModifiers(modifiers))
  caret.keyPressed(&event)
}

@MainActor
private func typeInto(_ caret: TextFieldCaret, _ string: String) {
  for character in string {
    var event = ToolKeyEvent(character: character, rawKeyCode: 0)
    caret.keyTyped(&event)
  }
}

// MARK: - The gate

@Suite("Canvas text editing — the TextEditable seam, end to end", .serialized)
@MainActor
struct CanvasTextEditingTests {

  // ── 1. The seam itself. Necessary, nowhere near sufficient; see the header. ───────────────

  @Test("a placed gate answers .textEditable")
  func placedComponentAnswersTheFeature() throws {
    let rig = try Rig()
    let gate = try rig.add(AndGate.factory, at: (200, 100), label: "A")
    #expect(gate.feature((any TextEditable).self, key: .textEditable) != nil)
  }

  /// The negative control for the arm above: a `Wire` is a `Component` and is not a
  /// `StdInstanceComponent`, so the routing must decline it rather than crash or invent a field.
  @Test("a wire answers nothing")
  func wireAnswersNothing() throws {
    let wire = Wire.create(Location.create(0, 0, hasToSnap: true), Location.create(30, 0, hasToSnap: true))
    #expect(wire.feature((any TextEditable).self, key: .textEditable) == nil)
  }

  // ── 2. THE EDIT. This is the test the whole task exists for. ──────────────────────────────

  /// Place a gate labelled `A`, pick the Text tool, click its label, select all, type `Q`,
  /// commit with Return: then undo.
  ///
  /// Both halves matter and they fail for different reasons:
  ///
  ///   * the label not becoming `Q` means the caret never reached the component (the seam), or
  ///     `textChanged` never wrote the attribute;
  ///   * the label not returning to `A` on undo means the commit bypassed the undo stack,
  ///     which is what upstream does, and is the divergence this port makes deliberately.
  @Test("clicking a gate's label, retyping it, and pressing Return changes the label — undoably")
  func editingALabelIsUndoable() throws {
    let rig = try Rig()
    let gate = try rig.add(AndGate.factory, at: (200, 100), label: "A")
    try rig.selectTextTool()

    let anchor = try #require(labelAnchor(of: gate), "the gate has no label placement")
    rig.click(anchor.x, anchor.y)

    rig.selectAll()
    rig.type("Q")
    rig.returnKey()

    #expect(rig.label(of: gate) == "Q", "label is \(rig.label(of: gate) ?? "nil")")
    #expect(rig.project.canUndo, "the edit produced no undoable action at all")

    let action = try #require(rig.project.lastAction)
    #expect(
      (action as? SetAttributeAction)?.actionName.key == "changeLabelAction",
      "the undo entry is \(action.name), not the label commit")

    try rig.project.undoAction()
    #expect(
      rig.label(of: gate) == "A",
      """
      undo left the label at \(rig.label(of: gate) ?? "nil"). The commit action recorded the \
      already-written value as its old value, so the reverse transaction is a no-op — this is \
      exactly 4.1.0's behaviour and exactly what InstanceTextField.commitAction corrects.
      """)
  }

  /// The discriminator against "any click on a component edits its label".
  ///
  /// The click has to land **inside the gate's bounds** for this to test anything:
  /// `TextTool.mousePressed` searches `circuit.allContaining(point)`, so a click in open space
  /// never reaches the component at all and would prove nothing about the hit test. The gate's
  /// own location is inside its bounds and a long way from where the label sits, so the only
  /// thing that can decline it is `InstanceTextField.getTextCaret`'s
  /// `bds.contains(x, y)`: measured against the real text box, with the real canvas measurer.
  ///
  /// The second assertion records what upstream then does instead, which is not "nothing": the
  /// tool falls through to `createTextComponent` and drops a **new free-standing annotation** at
  /// the click point (`TextTool.java:296-307`). Asserting it is what makes this case fail in two
  /// directions; remove the hit test and the label changes *and* the annotation disappears.
  @Test("a click inside the gate but off its label creates an annotation, it does not retitle")
  func aClickOffTheLabelDoesNotEditIt() throws {
    let rig = try Rig()
    let gate = try rig.add(AndGate.factory, at: (200, 100), label: "A")
    try rig.selectTextTool()

    // A gate's label is centred on its body (`LabelPlacement.computed` with no `labelloc`), so
    // the far corner of the bounds is both inside the component and clear of the text.
    let anchor = try #require(labelAnchor(of: gate))
    let point = (x: gate.bounds.x + 3, y: gate.bounds.y + 3)
    #expect(
      gate.contains(Location.create(point.x, point.y, hasToSnap: false)),
      "the click point is not inside the gate, so the component is never consulted")
    #expect(
      abs(point.x - anchor.x) + abs(point.y - anchor.y) > 20,
      "the click point \(point) is not clear of the label anchor \(anchor)")

    rig.click(point.x, point.y)
    rig.selectAll()
    rig.type("Q")
    rig.returnKey()

    #expect(rig.label(of: gate) == "A", "label is \(rig.label(of: gate) ?? "nil")")
    #expect(
      rig.circuit.nonWires.contains { $0.factory === LogisimStd.Text.factory },
      "the tool neither edited the label nor created an annotation")
  }

  /// Escape abandons the edit. `TextFieldCaret.cancelEditing` restores `oldText` and fires
  /// `editingCanceled`, which `TextTool` handles by dropping the caret without an action, so
  /// neither the attribute nor the undo stack moves.
  @Test("Escape cancels an in-progress label edit")
  func escapeCancelsTheEdit() throws {
    let rig = try Rig()
    let gate = try rig.add(AndGate.factory, at: (200, 100), label: "A")
    try rig.selectTextTool()

    let undoDepthBefore = rig.project.undoActions.count
    let anchor = try #require(labelAnchor(of: gate))
    rig.click(anchor.x, anchor.y)
    rig.selectAll()
    rig.type("Q")
    rig.escapeKey()

    #expect(rig.label(of: gate) == "A", "label is \(rig.label(of: gate) ?? "nil")")
    #expect(
      rig.project.undoActions.count == undoDepthBefore,
      "a cancelled edit still pushed an undo entry")
  }

  // ── 3. Creating a free-standing annotation, which is the other half of TextTool ───────────

  /// `TextTool.createTextComponent` → `Text.factory` → `.textEditable` → caret → type → the
  /// component is *added* on commit, carrying the typed string in `Text.ATTR_TEXT`.
  ///
  /// This exercises the `InstanceTextFieldProvider` arm: a `Text` annotation's field is not
  /// `StdAttr.LABEL` placed by `computeLabelTextField`, it is `ATTR_TEXT` anchored at the
  /// component's own location (`Text.java:75-84`).
  @Test("clicking empty sheet with the Text tool and typing adds a Text annotation")
  func creatingAnAnnotation() throws {
    let rig = try Rig()
    try rig.selectTextTool()
    let before = rig.circuit.components.count

    rig.click(120, 120)
    rig.type("HELLO")
    rig.returnKey()

    #expect(rig.circuit.components.count == before + 1, "no component was added")
    let added = try #require(
      rig.circuit.nonWires.first { $0.factory === LogisimStd.Text.factory },
      "the added component is not a Text annotation")
    #expect(added.attributeSet[LogisimStd.Text.attrText] == "HELLO")
    #expect(rig.project.canUndo)
  }

  /// Upstream's own guard: an empty annotation is never added (`TextTool.editingStopped`'s
  /// "Don't add the blank text field"). Committing with nothing typed must leave the sheet as it
  /// was: otherwise every stray click litters the file with empty `<comp name="Text">`.
  @Test("committing an empty annotation adds nothing")
  func emptyAnnotationIsNotAdded() throws {
    let rig = try Rig()
    try rig.selectTextTool()
    let before = rig.circuit.components.count

    rig.click(120, 120)
    rig.returnKey()

    #expect(rig.circuit.components.count == before)
  }

  // ── 4. Caret behaviour, driven directly ──────────────────────────────────────────────────

  @Test("typing inserts at the caret and moves it")
  func typingInserts() {
    let (_, made) = caret(over: "abcd", at: 2)
    typeInto(made, "XY")
    #expect(made.text == "abXYcd")
  }

  @Test("backspace deletes behind the caret, forward delete deletes ahead of it")
  func backspaceAndDelete() {
    let (_, back) = caret(over: "abcd", at: 2)
    press(back, Keys.backspace)
    #expect(back.text == "acd")

    let (_, forward) = caret(over: "abcd", at: 2)
    press(forward, Keys.forwardDelete)
    #expect(forward.text == "abd")
  }

  /// `moveCaret` with `dy != 0` jumps to the ends of the string: a single-line field's answer
  /// to up and down (`TextFieldCaret.java:161-165`).
  @Test("up and down arrows jump to the ends of the string")
  func verticalArrowsJumpToTheEnds() {
    let (_, made) = caret(over: "abcd", at: 2)
    press(made, Keys.upArrow)
    typeInto(made, "^")
    #expect(made.text == "^abcd")

    let (_, other) = caret(over: "abcd", at: 2)
    press(other, Keys.downArrow)
    typeInto(other, "$")
    #expect(other.text == "abcd$")
  }

  /// **A deliberate macOS divergence, measured.** AWT reads the literal Home/End keys;
  /// `CanvasToolController` maps neither, so ⌘← / ⌘→ carry them. See `TextFieldCaret`'s header.
  @Test("Command-left and Command-right are Home and End")
  func commandArrowsAreHomeAndEnd() {
    let (_, home) = caret(over: "abcd", at: 2)
    press(home, Keys.leftArrow, .command)
    typeInto(home, "^")
    #expect(home.text == "^abcd")

    let (_, end) = caret(over: "abcd", at: 2)
    press(end, Keys.rightArrow, .command)
    typeInto(end, "$")
    #expect(end.text == "abcd$")
  }

  /// The other deliberate remap: AWT walks words with Control-arrow, this port with
  /// Option-arrow. `wordBoundary` is upstream's; a boundary is where whitespace-ness changes.
  @Test("Option-left walks back to the previous word boundary")
  func optionArrowWalksByWord() {
    let (_, made) = caret(over: "one two", at: 7)
    press(made, Keys.leftArrow, .option)
    typeInto(made, "|")
    #expect(made.text == "one |two", "caret landed wrong: \(made.text)")
  }

  /// Shift extends the selection instead of collapsing it, and typing then replaces the whole
  /// run. Both halves are upstream's `moveCaret`.
  @Test("Shift-left extends a selection that typing then replaces")
  func shiftArrowSelects() {
    let (_, made) = caret(over: "abcd", at: 4)
    press(made, Keys.leftArrow, .shift)
    press(made, Keys.leftArrow, .shift)
    typeInto(made, "Z")
    #expect(made.text == "abZ")
  }

  /// A plain arrow with a live selection **collapses** it without moving; the branch at
  /// `TextFieldCaret.java:154-158` that is easy to drop and produces an off-by-one every time.
  @Test("a plain arrow collapses a selection instead of moving past it")
  func plainArrowCollapsesSelection() {
    let (_, made) = caret(over: "abcd", at: 4)
    press(made, Keys.leftArrow, .shift)
    press(made, Keys.leftArrow, .shift)
    press(made, Keys.leftArrow)
    typeInto(made, "Z")
    #expect(made.text == "abZcd", "collapse landed wrong: \(made.text)")
  }

  /// `stopEditing` pushes the typed string into the field, which is what fires the write-back.
  /// `cancelEditing` does not.
  @Test("stopEditing publishes to the field and cancelEditing does not")
  func commitAndCancelReachTheField() {
    let (committed, first) = caret(over: "old", at: 3)
    typeInto(first, "!")
    first.stopEditing()
    #expect(committed.text == "old!")

    let (untouched, second) = caret(over: "old", at: 3)
    typeInto(second, "!")
    second.cancelEditing()
    #expect(untouched.text == "old")
  }

  /// The caret's hit region has to cover the text it is editing, or a click inside an open edit
  /// is read as a click outside it and `TextTool.mousePressed` commits and starts over.
  @Test("the caret's bounds contain the field's own box")
  func caretBoundsCoverTheField() {
    let (field, made) = caret(over: "abcd", at: 0)
    let fieldBox = field.bounds(measurer: CoreTextMeasurer())
    #expect(made.bounds.contains(fieldBox), "\(made.bounds) does not contain \(fieldBox)")
  }

  /// D6: the caret contributes geometry, not pixels. It is not routed to the canvas yet,
  /// `TextTool.overlay(for:)` reads only `overlayItems`, but the scene it would contribute is
  /// built and non-empty, so the drawing half is proved at the caret's own boundary.
  @Test("an open caret produces a non-empty overlay scene")
  func caretDrawsSomething() {
    let (_, made) = caret(over: "abcd", at: 2)
    let scene = made.overlayScene(context: StaticPaintContext())
    #expect(scene != nil && !(scene?.isEmpty ?? true))
  }
}

/// Where the gate's label sits, taken from the same function the painter uses so the test cannot
/// drift from where the label is actually drawn.
@MainActor
private func labelAnchor(of component: any Component) -> (x: Int, y: Int)? {
  guard let std = component as? StdInstanceComponent,
    let spec = InstanceTextFieldSpec.resolve(for: std, measurer: CoreTextMeasurer())
  else { return nil }
  return (spec.x, spec.y)
}
