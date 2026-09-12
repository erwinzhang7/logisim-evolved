// LabelHitTestTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceComponent's two `contains`
// overloads, com.cburch.logisim.circuit.Circuit.getAllContaining, com.cburch.logisim.tools.TextTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN YOU CLICK A LABEL THAT IS DRAWN OUTSIDE ITS COMPONENT'S BODY? (board #84)
//
// `14-caret-retype-detached-label.script` is the byte-level gate and it is the one that has to
// stay green. This suite is the unit-level *why*: it pins each of the three things that had to be
// true for that script to pass, so a future regression says which one broke instead of only that
// a saved file changed.
//
//   1. the label box is where the port already thought it was; the placement was never the bug;
//   2. the one-argument `contains` says no there and the two-argument one says yes;
//   3. an *unlabelled* component is unchanged, which is the half a careless fix breaks.
//
// (3) is not decoration. `InstanceTextField.updateField` (`InstanceTextField.java:153-158`)
// destroys the field when the label text goes empty, so in 4.1.0 an unlabelled component
// hit-tests on its body alone. A port that unions in a zero-width box at the label anchor instead
// would put an invisible, unclickable-looking hot spot a few pixels above every unlabelled
// component in the circuit, and no byte gate in the tree would notice: the extra hits only change
// which component a click *finds*, and the scripts all click things that are labelled.
//
// ── ON THE MEASURER ─────────────────────────────────────────────────────────────────────────
//
// Every number below is measured with `InstanceTextField.canvasMeasurer`, deliberately named
// rather than constructed here. That is the measurer `textCaret` hit-tests with and the one the
// canvas renders with, so these assertions move with the shipping metrics rather than pinning a
// second, private idea of how wide an "A" is. Board #75 is the precedent: a plausible-looking
// second measurer regressed an oracle by 9 cases because `FontMetrics.charWidth` rounds where
// `getStringBounds` truncates.
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

/// A project, its render surface, and the application's own canvas over both; the same shape
/// `CanvasTextEditingTests.Rig` uses, and for the same reason: the question is what the shipping
/// canvas does, so every part is a shipping one.
@MainActor
private struct Rig {
  let project: Project
  let circuit: Circuit
  let canvas: CircuitEditorCanvas

  init() throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: SelectTool())
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

  func selectTextTool() throws {
    let accepted = canvas.controller.setActiveTool(
      fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.textTool))
    #expect(accepted, "the controller does not resolve BaseToolIds.textTool at all")
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
  func key(_ characters: String, keyCode: UInt16 = 0) -> Bool {
    canvas.controller.canvasHandleKey(
      CanvasKeyEvent(
        phase: .down, characters: characters, keyCode: keyCode, modifiers: [], isRepeat: false))
  }

  func type(_ string: String) {
    for character in string { _ = key(String(character)) }
  }
}

/// `Register`, reached the way the other suites reach it: through the library's own `AddTool`,
/// so the factory under test is the registered one rather than a fresh instance.
@MainActor
private func registerFactory() throws -> any ComponentFactory {
  try #require(
    MemoryLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
      .first { ($0 as? any InstanceFactory)?.makePoker() is RegisterPoker })
}

/// The metrics source `TextTool.mousePressed` uses: the shipping one, not a copy of it.
@MainActor
private var metrics: StdComponentTextFieldMetrics { TextTool.hitTestMetrics }

// MARK: - The gate

@Suite("A label drawn outside the body is still clickable")
struct LabelHitTestTests {

  /// The click the parity script makes, and the four boxes around it.
  ///
  /// `Register` at (200,200) with `labelloc` at its default `north`: the label sits above the
  /// body and touches no part of it. The numbers are 4.1.0's, the spec (x=230 y=198,
  /// centre/bottom) is what `Instance.computeLabelTextField` produces there, and the box is what
  /// `TextField.getBounds(Graphics)` makes of it.
  @Test("the label box contains the click and the component's bounds do not")
  @MainActor
  func labelBoxIsOutsideTheBody() throws {
    let rig = try Rig()
    let component = try #require(
      try rig.add(registerFactory(), at: (200, 200), label: "A") as? StdInstanceComponent)
    let click = Location.create(230, 192, hasToSnap: false)

    #expect(component.bounds == Bounds.create(200, 200, 60, 90))
    #expect(component.bounds.contains(click) == false)

    let box = try #require(component.textFieldBounds(measurer: InstanceTextField.canvasMeasurer))
    #expect(box == Bounds.create(225, 181, 11, 17))
    #expect(box.contains(click))

    // The two predicates, side by side. This is the whole defect in two lines.
    #expect(component.contains(click) == false)
    #expect(component.contains(click, measurer: InstanceTextField.canvasMeasurer))
  }

  /// `Circuit.getAllContaining(Location)` vs `getAllContaining(Location, Graphics)`.
  ///
  /// Both overloads are asserted, and the one-argument one is asserted to stay *empty*: it is
  /// `SelectTool`'s and `PokeTool`'s lookup, and widening it would make a label click select or
  /// poke the component, which 4.1.0 does not do.
  @Test("only the two-argument lookup finds a component by its label")
  @MainActor
  func theLookupIsWhatWasMissing() throws {
    let rig = try Rig()
    let component = try #require(
      try rig.add(registerFactory(), at: (200, 200), label: "A") as? StdInstanceComponent)
    let click = Location.create(230, 192, hasToSnap: false)

    #expect(rig.circuit.allContaining(click).isEmpty)

    let found = rig.circuit.allContaining(click, metrics: metrics)
    #expect(found.count == 1)
    #expect(found.first.map { $0 === component } == true)
  }

  /// The body is still the body: a click inside it finds the component through *both* overloads,
  /// which is upstream's `? true : contains(pt)` fall-through.
  @Test("a click on the body still finds the component through both overloads")
  @MainActor
  func theBodyIsUnchanged() throws {
    let rig = try Rig()
    try rig.add(registerFactory(), at: (200, 200), label: "A")
    let inside = Location.create(230, 240, hasToSnap: false)

    #expect(rig.circuit.allContaining(inside).count == 1)
    #expect(rig.circuit.allContaining(inside, metrics: metrics).count == 1)
  }

  /// `InstanceTextField.updateField`'s empty arm, ported as `textFieldBounds → nil`.
  ///
  /// The same Register with no label. The click point is the one that hits the label box when
  /// there *is* a label, so a port that unioned in an empty field's box would fail here and
  /// nowhere else in the tree.
  @Test("an unlabelled component hit-tests on its body alone")
  @MainActor
  func anEmptyLabelAddsNoHotSpot() throws {
    let rig = try Rig()
    let component = try #require(
      try rig.add(registerFactory(), at: (200, 200)) as? StdInstanceComponent)
    let click = Location.create(230, 192, hasToSnap: false)

    #expect(component.attributeSet[StdAttr.label] == "")
    #expect(component.textFieldBounds(measurer: InstanceTextField.canvasMeasurer) == nil)
    #expect(component.contains(click, measurer: InstanceTextField.canvasMeasurer) == false)
    #expect(rig.circuit.allContaining(click, metrics: metrics).isEmpty)
  }

  /// The fall-through arm of `StdComponentTextFieldMetrics`: anything that is not a
  /// `StdInstanceComponent` gets the one-argument predicate, which is `Wire.contains(pt, g)`
  /// (`Wire.java:129-131`) verbatim.
  @Test("a wire answers the one-argument predicate under either overload")
  @MainActor
  func aWireIsUnaffected() throws {
    let rig = try Rig()
    let wire = Wire.create(
      Location.create(100, 100, hasToSnap: false),
      Location.create(160, 100, hasToSnap: false))
    try rig.circuit.mutatorAdd(wire)

    let on = Location.create(130, 100, hasToSnap: false)
    let off = Location.create(130, 140, hasToSnap: false)
    #expect(metrics.contains(wire, on) == wire.contains(on))
    #expect(metrics.contains(wire, off) == wire.contains(off))
    #expect(metrics.contains(wire, on))
    #expect(metrics.contains(wire, off) == false)
  }

  /// The one claim no output can check, so it is asserted structurally.
  ///
  /// `TextTool` must hit-test with the same metrics `InstanceTextField.textCaret` does, or a
  /// click can find the component and then be refused by the caret, which the user sees as the
  /// click doing nothing at all. Measured: swapping the measurer in `hitTestMetrics` for
  /// `NominalTextMeasurer` leaves every other case in this suite *and* all 15 parity scripts
  /// green, because the scripted clicks land well inside the box under either metric. So the
  /// identity is pinned directly.
  @Test("the tool hit-tests with the same measurer the caret and the canvas use")
  @MainActor
  func theMeasurerIsTheCanvasOne() {
    #expect(TextTool.hitTestMetrics.measurer === InstanceTextField.canvasMeasurer)
  }

  /// End to end through the shipping canvas, which is what a user does.
  ///
  /// `14-caret-retype-detached-label.script` asserts the same gesture at the byte level; this
  /// asserts it at the model level, and adds the assertion the saved file only implies; that
  /// **no stray `Text` annotation** was created. That was the visible symptom: the click missed
  /// the component, fell into `TextTool.createTextComponent`, and the typing landed in a new
  /// free-standing label.
  @Test("clicking a detached label retypes it and creates no annotation")
  @MainActor
  func clickingTheLabelEditsIt() throws {
    let rig = try Rig()
    let component = try rig.add(registerFactory(), at: (200, 200), label: "A")
    let before = rig.circuit.nonWires.count

    try rig.selectTextTool()
    rig.click(230, 192)
    // The script's own clear: the caret opens *at the click point*, which for a one-character
    // label can be on either side of it, so two backspaces and two forward deletes are what
    // empties the field from wherever it landed. Same six keys as
    // `14-caret-retype-detached-label.script`, deliberately.
    _ = rig.key("\u{7F}", keyCode: 0x33)
    _ = rig.key("\u{7F}", keyCode: 0x33)
    _ = rig.key("\u{F728}", keyCode: 0x75)
    _ = rig.key("\u{F728}", keyCode: 0x75)
    rig.type("Q7")
    _ = rig.key("\r", keyCode: 0x24)

    #expect(component.attributeSet[StdAttr.label] == "Q7")
    #expect(rig.circuit.nonWires.count == before)
    #expect(rig.circuit.nonWires.contains { $0.factory.name == "Text" } == false)
  }
}
