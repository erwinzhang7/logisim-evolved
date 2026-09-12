// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE IO FAMILY'S LABEL PLACEMENTS, MEASURED AGAINST THE 4.1.0 ARITHMETIC
//
// Board #78. Fifteen io factories install a label text field upstream and none of them did so
// here, so their labels neither drew nor edited. Ten install it with a single
// `Instance.computeLabelTextField(mask)` call, four with an explicit `setTextField`, and the
// fifteenth, `HexDigit`, through `SevenSegment.computeTextField`, a spelling the brief's grep
// missed. Fourteen are closed here; `HexDigit` is outside this slice's file ownership and is
// pinned as a known gap by `hexDigitIsAMeasuredGap`.
//
// The failure mode this suite exists to catch is **the wrong mask**, not the missing
// conformance. A missing conformance is loud, the label disappears, but ten call sites that
// differ only in an integer literal are exactly the shape that gets pattern-matched from a
// neighbour and then never questioned, because every mask produces *a* placement and four of
// the five label locations agree under all of them.
//
// So every assertion below is a full six-tuple `(x, y, halign, valign)` at a known location,
// and the cases are chosen so that each mask is separated from its neighbours by at least one
// row:
//
//   * `AVOID_LEFT`               (Led, RgbLed, DotMatrix/LedBar, DipSwitch, DigitalOscilloscope,
//                                 ProgrammableGenerator): nudges the one edge the component
//                                 faces, and *only* that one.
//   * `AVOID_CENTER | AVOID_LEFT` (Button); additionally pulls a `LABEL_CENTER` label 3px up
//                                 and left, which is the only mask in the family that moves the
//                                 centred case at all.
//   * `AVOID_RIGHT | AVOID_LEFT` (Switch): nudges `EAST` *and* `WEST`, two edges rather than one.
//   * `AVOID_BOTTOM`             (PortIo); rotates to a different edge entirely: on an
//                                 east-facing PortIo it is `NORTH` that gets nudged, where an
//                                 `AVOID_LEFT` component of the same facing nudges `EAST`.
//   * `AVOID_SIDES`              (Telnet): the same two bits as `Switch`, but on a factory with
//                                 no `StdAttr.FACING`, so nothing rotates.
//
// The four explicit `setTextField` factories are separated from the generic routine by
// construction: `Buzzer` uses `- 3` where every generic NORTH arm uses `- 2`, `PlaRom` sits
// *inside* the body at a third of its height, `Slider` branches on `WEST` alone and hangs the
// label off `bds.x - 3`, and `SevenSegment`, which has no `StdAttr.FACING`, never nudges any
// edge, where the generic routine with a null facing would still nudge `WEST`.
//
// Both halves of #78 are covered. `labelPlacement` is what `InstancePainter.drawLabel()` reads,
// and `InstanceTextFieldSpec.resolve` recomputes the same six `setTextField` arguments for the
// caret, so the last test asserts the two agree rather than trusting that they must.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// Every io factory this port has, plus `ProgrammableGenerator`.
///
/// `ProgrammableGenerator` is **not** in `ExtraIoLibrary().tools` and that is deliberate and
/// upstream's (`ExtraIoLibrary.swift`'s header: upstream comments the `AddTool` out as
/// "TODO: Broken"). It still installs a label field in its `configureNewInstance`, so it is
/// still in scope for #78; it just has to be constructed by hand because no library publishes it.
private func ioFactoriesIncludingUnregistered() -> [any ComponentFactory] {
  var result = (IoLibrary().tools + ExtraIoLibrary().tools)
    .compactMap { ($0 as? AddTool)?.factory }
  result.append(ProgrammableGenerator())
  return result
}

/// Places one component of `factory` at (200, 200) with `labelLoc` selected, and asks the
/// factory where its label goes.
///
/// (200, 200) rather than the origin so that a placement that silently dropped the component's
/// location, the classic offset-bounds-instead-of-bounds slip, cannot pass by coincidence.
private func placement(
  _ factory: any ComponentFactory, labelLoc: StdAttr.LabelLocation? = nil,
  facing: Direction? = nil
) throws -> LabelPlacement? {
  let attributes = factory.createAttributeSet()
  if let labelLoc, attributes.containsAttribute(StdAttr.labelLocation) {
    try attributes.setValue(StdAttr.labelLocation, labelLoc)
  }
  if let facing, attributes.containsAttribute(StdAttr.facing) {
    try attributes.setValue(StdAttr.facing, facing)
  }
  let component = try factory.createComponent(
    location: Location.create(200, 200, hasToSnap: false), attributes: attributes)
  let painter = InstancePainter(
    g: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext(),
    component: component)
  return (factory as? InstanceLabelProvider)?.labelPlacement(painter)
}

/// One expected row: the label location under test and the four numbers it must produce.
private struct Row {
  let loc: StdAttr.LabelLocation?
  let x: Int
  let y: Int
  let halign: HAlign
  let valign: VAlign
}

private func check(
  _ factory: any ComponentFactory, _ rows: [Row], _ label: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  for row in rows {
    let got = try placement(factory, labelLoc: row.loc)
    let want = LabelPlacement(x: row.x, y: row.y, halign: row.halign, valign: row.valign)
    #expect(
      got == want,
      "\(label) at labelLoc=\(row.loc.map { "\($0)" } ?? "n/a"): got \(String(describing: got)), want \(want)",
      sourceLocation: sourceLocation)
  }
}

// MARK: - The gate

@Suite("Io label placements (board #78)")
struct IoLabelPlacementTests {

  // MARK: Coverage — which factories have a label field at all

  /// The 14 upstream call sites, by factory name, plus the two `DotMatrixBase` subclasses that
  /// inherit `configureNewInstance` from it. `ProgrammableGenerator` is included because it
  /// installs a field even though no library publishes it.
  ///
  /// The negative half is the point: an io factory that upstream does *not* label must not
  /// conform either, or the port draws a label 4.1.0 does not. Five of the six that do not
  /// conform are genuine negatives, confirmed against the jar in
  /// `docs/experiments/label-fields-measured.txt`: `Joystick`, `Keyboard`, `TTY`, `RGB Video`
  /// and `ReptarLB` are all measured `NO label field`.
  ///
  /// The sixth, `Hex Digit Display`, is **a real gap, not a negative**, see
  /// `hexDigitIsAMeasuredGap` below.
  @Test("exactly the io factories upstream labels have a label placement")
  func labelledFactoriesAreExactlyUpstreams() {
    // `factory.name` is the `.circ` token (`_ID`), not the display name, so these are the
    // strings a saved file carries.
    let expected: Set<String> = [
      "Button", "DipSwitch", "DotMatrix", "LedBar", "Buzzer", "PlaRom", "LED",
      "7-Segment Display", "PortIO", "Telnet", "RGBLED", "Slider", "ProgrammableGenerator",
      "Digital Oscilloscope", "Switch",
      // Added 2026-09-06 when the integrator closed the gap the deleted `hexDigitIsAMeasuredGap`
      // test used to pin. HexDigit reaches `setTextField` through a THIRD spelling,
      // `SevenSegment.computeTextField(instance)` at HexDigit.java:110 and :116, which is why
      // every grep-based survey scoped this family as 14 factories when it is 15.
      "Hex Digit Display",
    ]
    let actual = Set(
      ioFactoriesIncludingUnregistered()
        .filter { $0 is InstanceLabelProvider }
        .map(\.name))
    let all = Set(ioFactoriesIncludingUnregistered().map(\.name))

    let diff =
      "missing: \(expected.subtracting(actual).sorted()); "
      + "unexpected: \(actual.subtracting(expected).sorted())"
    #expect(actual == expected, "\(diff)")
    // Stated separately so the report carries the denominator, not just a set difference.
    #expect(all.count == 21, "io factory count changed: \(all.sorted())")

    // The five genuine negatives, named rather than left implicit in the set difference.
    let unlabelled = all.subtracting(actual)
    #expect(
      unlabelled == ["Joystick", "Keyboard", "TTY", "RGB Video", "ReptarLB"],
      "\(unlabelled.sorted())")
  }

  // `hexDigitIsAMeasuredGap` stood here and has been DELETED, not disabled. It asserted that
  // HexDigit did NOT conform, and its failure message read "HexDigit now conforms; good; move it
  // into `expected` above and delete this test." The integrator closed the gap on 2026-09-06, this
  // reddened exactly as designed, and both instructions were followed. A tripwire that is retired
  // by being satisfied is the only kind worth writing.

  // MARK: AVOID_LEFT — six factories, one nudged edge

  /// `Led` faces WEST by default, so `AVOID_LEFT` is not rotated and the WEST label is the one
  /// nudged: `y` drops 2 and the alignment becomes `V_BOTTOM`. Bounds are (200,190) 20×20.
  @Test("Led — AVOID_LEFT, west-facing, nudges only the WEST label")
  func ledPlacement() throws {
    try check(
      Led(),
      [
        Row(loc: .center, x: 210, y: 200, halign: .center, valign: .center),
        Row(loc: .north, x: 210, y: 188, halign: .center, valign: .bottom),
        Row(loc: .south, x: 210, y: 212, halign: .center, valign: .top),
        Row(loc: .east, x: 222, y: 200, halign: .left, valign: .center),
        // The nudge. Under AVOID_CENTER|AVOID_LEFT this row is identical, but the .center row
        // above is not; under AVOID_BOTTOM or AVOID_SIDES this row changes.
        Row(loc: .west, x: 198, y: 198, halign: .right, valign: .bottom),
      ], "Led")
  }

  /// Byte-identical to `Led`: same 20×20 offset bounds, same default facing, same mask.
  @Test("RgbLed — AVOID_LEFT, identical geometry to Led")
  func rgbLedPlacement() throws {
    try check(
      RgbLed(),
      [
        Row(loc: .center, x: 210, y: 200, halign: .center, valign: .center),
        Row(loc: .east, x: 222, y: 200, halign: .left, valign: .center),
        Row(loc: .west, x: 198, y: 198, halign: .right, valign: .bottom),
      ], "RgbLed")
  }

  /// `DotMatrix` has **no `StdAttr.FACING`**, so the mask is never rotated and the nudge stays
  /// on WEST. Bounds are (195,130) 50×70; the x offset is the component's own, not a typo.
  ///
  /// The conformance is declared on `DotMatrixBase`, which is why `LedBar` gets it without
  /// `LedBar.swift` being touched; `ledBarInheritsTheBasePlacement` below is the assertion.
  @Test("DotMatrix — AVOID_LEFT, no facing attribute")
  func dotMatrixPlacement() throws {
    try check(
      DotMatrix(),
      [
        Row(loc: .center, x: 220, y: 165, halign: .center, valign: .center),
        Row(loc: .north, x: 220, y: 128, halign: .center, valign: .bottom),
        Row(loc: .east, x: 247, y: 165, halign: .left, valign: .center),
        Row(loc: .west, x: 193, y: 163, halign: .right, valign: .bottom),
      ], "DotMatrix")
  }

  /// Upstream installs the field in `DotMatrixBase.configureNewInstance`, which both subclasses
  /// inherit unchanged; this port conforms the base class for the same reason. Bounds are
  /// (195,170) 80×30.
  @Test("LedBar inherits DotMatrixBase's placement")
  func ledBarInheritsTheBasePlacement() throws {
    #expect(LedBar() is InstanceLabelProvider)
    try check(
      LedBar(),
      [
        Row(loc: .center, x: 235, y: 185, halign: .center, valign: .center),
        Row(loc: .west, x: 193, y: 183, halign: .right, valign: .bottom),
      ], "LedBar")
  }

  /// `DipSwitch` faces **NORTH** by default, and that is what makes it the useful witness for
  /// the rotation: `AVOID_LEFT` (0b1000) rotated once becomes `AVOID_TOP` (0b0001), so it is
  /// the NORTH label that gets `x += 2` and `H_LEFT`: not the WEST one, as on `Led`.
  /// Bounds are (200,200) 90×40.
  @Test("DipSwitch — AVOID_LEFT rotated by a NORTH facing nudges the NORTH label")
  func dipSwitchPlacement() throws {
    try check(
      DipSwitch(),
      [
        Row(loc: .center, x: 245, y: 220, halign: .center, valign: .center),
        Row(loc: .north, x: 247, y: 198, halign: .left, valign: .bottom),
        Row(loc: .south, x: 245, y: 242, halign: .center, valign: .top),
        Row(loc: .east, x: 292, y: 220, halign: .left, valign: .center),
        Row(loc: .west, x: 198, y: 220, halign: .right, valign: .center),
      ], "DipSwitch")
  }

  /// No facing attribute, so `AVOID_LEFT` stays put. Bounds are (200,158) 335×152: much the
  /// largest body in the family, which is why the numbers look nothing like `Led`'s despite the
  /// identical mask.
  @Test("DigitalOscilloscope — AVOID_LEFT, no facing attribute")
  func digitalOscilloscopePlacement() throws {
    try check(
      DigitalOscilloscope(),
      [
        Row(loc: .center, x: 367, y: 234, halign: .center, valign: .center),
        Row(loc: .east, x: 537, y: 234, halign: .left, valign: .center),
        Row(loc: .west, x: 198, y: 232, halign: .right, valign: .bottom),
      ], "DigitalOscilloscope")
  }

  /// East-facing, so `AVOID_LEFT` rotates twice to `AVOID_RIGHT` and it is the EAST label that
  /// is nudged. Bounds are (200,185) 30×30.
  @Test("ProgrammableGenerator — AVOID_LEFT rotated by an EAST facing nudges the EAST label")
  func programmableGeneratorPlacement() throws {
    let generator = ProgrammableGenerator()
    let east = try #require(try placement(generator, labelLoc: .east))
    let west = try #require(try placement(generator, labelLoc: .west))
    // The whole content of "the mask rotated": EAST is on V_BOTTOM, WEST is not.
    #expect(east.valign == .bottom, "EAST label not nudged: \(east)")
    #expect(west.valign == .center, "WEST label nudged when it should not be: \(west)")
    let bounds = try componentBounds(generator)
    #expect(east == LabelPlacement(
      x: bounds.x + bounds.width + 2, y: bounds.y + bounds.height / 2 - 2,
      halign: .left, valign: .bottom))
  }

  // MARK: The four masks that are not AVOID_LEFT

  /// `AVOID_CENTER | AVOID_LEFT`. The `AVOID_CENTER` bit survives the rotation untouched
  /// (`avoid & 0x10`) and is the *only* thing in this family that moves the `LABEL_CENTER` case:
  /// `x = bds.x + (w - 3) / 2` instead of `bds.x + w / 2`, and the same for `y`. On the 20×20
  /// button that is (188, 198) rather than (190, 200).
  ///
  /// East-facing, so the `AVOID_LEFT` half rotates to `AVOID_RIGHT` and nudges EAST: the same
  /// edge `ProgrammableGenerator` nudges, which is why the centre row is the discriminating one.
  @Test("Button — AVOID_CENTER | AVOID_LEFT moves the centred label 3px up and left")
  func buttonPlacement() throws {
    try check(
      Button(),
      [
        Row(loc: .center, x: 188, y: 198, halign: .center, valign: .center),
        Row(loc: .north, x: 190, y: 188, halign: .center, valign: .bottom),
        Row(loc: .south, x: 190, y: 212, halign: .center, valign: .top),
        Row(loc: .east, x: 202, y: 198, halign: .left, valign: .bottom),
        Row(loc: .west, x: 178, y: 200, halign: .right, valign: .center),
      ], "Button")

    // Stated against the geometry too, so the centred row cannot be read as a coincidence of
    // the button's bounds. `Led` is the control: identical 20x20 bounds, mask without the
    // AVOID_CENTER bit, and its centred label sits at the plain midpoint.
    let bounds = try componentBounds(Button())
    let button = try #require(try placement(Button(), labelLoc: .center))
    #expect(bounds.width == 20 && bounds.height == 20)
    #expect(button.x == bounds.x + (bounds.width - 3) / 2)
    #expect(button.y == bounds.y + (bounds.height - 3) / 2)

    let ledBounds = try componentBounds(Led())
    let led = try #require(try placement(Led(), labelLoc: .center))
    #expect(ledBounds.width == 20 && ledBounds.height == 20)
    #expect(led.x == ledBounds.x + ledBounds.width / 2)
    #expect(led.y == ledBounds.y + ledBounds.height / 2)
  }

  /// `AVOID_RIGHT | AVOID_LEFT`: two edges nudged, not one, which is what separates it from
  /// every `AVOID_LEFT` factory. Bounds are (180,185) 20×30, east-facing.
  @Test("Switch — AVOID_RIGHT | AVOID_LEFT nudges both the EAST and the WEST label")
  func switchPlacement() throws {
    try check(
      Switch(),
      [
        Row(loc: .center, x: 190, y: 200, halign: .center, valign: .center),
        Row(loc: .north, x: 190, y: 183, halign: .center, valign: .bottom),
        Row(loc: .south, x: 190, y: 217, halign: .center, valign: .top),
        Row(loc: .east, x: 202, y: 198, halign: .left, valign: .bottom),
        Row(loc: .west, x: 178, y: 198, halign: .right, valign: .bottom),
      ], "Switch")
  }

  /// `AVOID_BOTTOM` (0b0100), and on an east-facing `PortIo` it rotates to `AVOID_TOP`, so the
  /// nudged edge is **NORTH**, which no other factory in the family nudges by default. Bounds
  /// are (200,200) 50×50.
  @Test("PortIo — AVOID_BOTTOM rotates to AVOID_TOP and nudges the NORTH label")
  func portIoPlacement() throws {
    try check(
      PortIo(),
      [
        Row(loc: .center, x: 225, y: 225, halign: .center, valign: .center),
        Row(loc: .north, x: 227, y: 198, halign: .left, valign: .bottom),
        Row(loc: .south, x: 225, y: 252, halign: .center, valign: .top),
        // Neither side is nudged, which is exactly what an AVOID_LEFT or AVOID_SIDES mask
        // would not produce here.
        Row(loc: .east, x: 252, y: 225, halign: .left, valign: .center),
        Row(loc: .west, x: 198, y: 225, halign: .right, valign: .center),
      ], "PortIo")
  }

  /// `AVOID_SIDES` on a factory with **no `StdAttr.FACING`**: the same two bits `Switch` sets,
  /// but nothing rotates them, so EAST and WEST are nudged unconditionally. Bounds are
  /// (170,180) 40×60.
  @Test("Telnet — AVOID_SIDES, unrotated")
  func telnetPlacement() throws {
    try check(
      Telnet(),
      [
        Row(loc: .center, x: 190, y: 210, halign: .center, valign: .center),
        Row(loc: .north, x: 190, y: 178, halign: .center, valign: .bottom),
        Row(loc: .south, x: 190, y: 242, halign: .center, valign: .top),
        Row(loc: .east, x: 212, y: 208, halign: .left, valign: .bottom),
        Row(loc: .west, x: 168, y: 208, halign: .right, valign: .bottom),
      ], "Telnet")
  }

  // MARK: The four explicit setTextField factories

  /// `SevenSegment.computeTextField`: an explicit `setTextField`, and provably *not* the
  /// generic routine: with no `StdAttr.FACING` in its template, `labelLoc == facing` is false
  /// for all five locations and **no** edge is ever nudged. An `AVOID_LEFT` conformance here
  /// would put the WEST label on `V_BOTTOM` two pixels higher. Bounds are (195,200) 40×60.
  @Test("SevenSegment — explicit setTextField, and it never nudges any edge")
  func sevenSegmentPlacement() throws {
    try check(
      SevenSegment(),
      [
        Row(loc: .center, x: 215, y: 230, halign: .center, valign: .center),
        Row(loc: .north, x: 215, y: 198, halign: .center, valign: .bottom),
        Row(loc: .south, x: 215, y: 262, halign: .center, valign: .top),
        Row(loc: .east, x: 237, y: 230, halign: .left, valign: .center),
        // The row that separates it from AVOID_LEFT: V_CENTER at the body's centre-y, not
        // V_BOTTOM two pixels above it.
        Row(loc: .west, x: 193, y: 230, halign: .right, valign: .center),
      ], "SevenSegment")

    let sevenSegment = try #require(try placement(SevenSegment(), labelLoc: .west))
    let avoidLeft = try #require(try placement(DigitalOscilloscope(), labelLoc: .west))
    #expect(sevenSegment.valign == .center && avoidLeft.valign == .bottom)
  }

  /// `b.getY() - 3`, not the `- 2` every generic NORTH arm uses, and no `LABEL_LOC` at all; a
  /// Buzzer's label is always centred above its body. Bounds are (200,180) 40×40.
  ///
  /// Board #25: this asserts geometry only. Nothing here reaches the tone generator, and
  /// `LogisimStd` still must not see `AVFoundation`.
  @Test("Buzzer — explicit setTextField at y - 3, no LABEL_LOC")
  func buzzerPlacement() throws {
    let got = try #require(try placement(Buzzer()))
    #expect(got == LabelPlacement(x: 220, y: 177, halign: .center, valign: .bottom))
    // The `- 3` itself, stated against the bounds rather than against a literal.
    let bounds = try componentBounds(Buzzer())
    #expect(got.y == bounds.y - 3)
    #expect(Buzzer().createAttributeSet().containsAttribute(StdAttr.labelLocation) == false)
  }

  /// `PlaRom` is the one io factory whose label sits **inside** the body: `bds.y + h/3` with
  /// `V_CENTER_OVERALL`, the same anchor its painter uses for the "PLA ROM" placeholder it
  /// draws when the label is empty. Bounds are (200,170) 60×60.
  @Test("PlaRom — explicit setTextField inside the body at height/3")
  func plaRomPlacement() throws {
    let got = try #require(try placement(PlaRom()))
    #expect(got == LabelPlacement(x: 230, y: 190, halign: .center, valign: .centerOverall))
    let bounds = try componentBounds(PlaRom())
    #expect(bounds.contains(got.x, got.y), "PlaRom's label should sit inside its bounds")
  }

  /// The only facing-branching placement in the family, and it branches on `WEST` *alone*
  /// rather than on an axis. East-facing bounds are (-75,185) 275×30, so `x = bds.x - 3` is
  /// negative; the slider extends 275px to the left of its output pin.
  @Test("Slider — explicit setTextField, WEST-only branch")
  func sliderPlacement() throws {
    let east = try #require(try placement(Slider(), facing: .east))
    #expect(east == LabelPlacement(x: -78, y: 199, halign: .right, valign: .centerOverall))

    let west = try #require(try placement(Slider(), facing: .west))
    #expect(west == LabelPlacement(x: 197, y: 185, halign: .right, valign: .baseline))

    // NORTH and SOUTH take the same arm as EAST; the branch is `facing == WEST`, not an axis
    // test, and getting that wrong is the obvious slip.
    for facing in [Direction.north, Direction.south] {
      let got = try #require(try placement(Slider(), facing: facing))
      let bounds = try componentBounds(Slider(), facing: facing)
      #expect(
        got == LabelPlacement(
          x: bounds.x - 3, y: bounds.y + bounds.height / 2 - 1, halign: .right,
          valign: .centerOverall),
        "Slider facing \(facing) should take the non-WEST arm: \(got)")
    }
  }

  // MARK: The editing half

  /// #78's claim is that one conformance closes both drawing and editing. `drawLabel()` reads
  /// `labelPlacement`; `InstanceTextFieldSpec.resolve` recomputes the same six `setTextField`
  /// arguments for the caret. This asserts they agree for every newly-labelled factory rather
  /// than trusting that they must, and that `resolve` returns a spec at all, which is what
  /// makes the label clickable.
  @Test("every new conformance makes the label editable, at the same place it is drawn")
  func editingAgreesWithDrawing() throws {
    var checked = 0
    for factory in ioFactoriesIncludingUnregistered() {
      guard let provider = factory as? InstanceLabelProvider else { continue }
      let attributes = factory.createAttributeSet()
      let component = try factory.createComponent(
        location: Location.create(200, 200, hasToSnap: false), attributes: attributes)
      let std = try #require(component as? StdInstanceComponent, "\(factory.name)")
      let painter = InstancePainter(
        g: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext(),
        component: component)
      let drawn = try #require(provider.labelPlacement(painter), "\(factory.name) draws no label")
      let spec = try #require(
        InstanceTextFieldSpec.resolve(for: std, measurer: NominalTextMeasurer()),
        "\(factory.name) has no editable text field")

      #expect(spec.textAttribute === StdAttr.label, "\(factory.name)")
      #expect(spec.fontAttribute === StdAttr.labelFont, "\(factory.name)")
      let mismatch =
        "\(factory.name): editable field at (\(spec.x), \(spec.y), \(spec.halign), "
        + "\(spec.valign)) but label drawn at (\(drawn.x), \(drawn.y), \(drawn.halign), "
        + "\(drawn.valign))"
      #expect(
        (spec.x, spec.y, spec.halign, spec.valign)
          == (drawn.x, drawn.y, drawn.halign, drawn.valign),
        "\(mismatch)")
      checked += 1
    }
    // 16, not 15: HexDigit joined the labelled set on 2026-09-06. The denominator is
    // asserted rather than left implicit precisely so adding a conformance cannot quietly
    // reduce what this loop covers.
    #expect(checked == 16, "expected 16 labelled io factories, checked \(checked)")
  }
}

// MARK: - Helper

/// The component's absolute bounds at (200, 200); the same thing `painter.bounds` reports,
/// so an assertion can be written against the geometry instead of against a copied literal.
private func componentBounds(
  _ factory: any ComponentFactory, facing: Direction? = nil
) throws -> Bounds {
  let attributes = factory.createAttributeSet()
  if let facing, attributes.containsAttribute(StdAttr.facing) {
    try attributes.setValue(StdAttr.facing, facing)
  }
  return try factory.createComponent(
    location: Location.create(200, 200, hasToSnap: false), attributes: attributes).bounds
}
