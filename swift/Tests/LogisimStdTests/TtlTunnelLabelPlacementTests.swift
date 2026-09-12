// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// BOARD #78, THE ttl-tunnel FAMILY: LABEL PLACEMENT, MEASURED
//
// Two factories, and neither is a rotation of the other:
//
//   * `AbstractTtlGate` (`AbstractTtlGate.java:141-160`) is **facing-dependent** and covers all
//     65 74xx chips by inheritance. Its two arms are different placements, not one placement
//     rotated: E/W puts the label to the right of the DIP package (`H_LEFT`), N/S puts it
//     centred above it (`H_CENTER`). A suite that only exercised the default facing (EAST)
//     would pass against an implementation whose N/S arm was completely wrong, so **every test
//     below names its facing and all four are covered**.
//   * `Tunnel` (`Tunnel.java:90-101`) is **attribute-driven**: `loc + (labelX, labelY)` with the
//     h/v aligns also read from `TunnelAttributes`, which derives all four from FACING in
//     `configureLabel()`. Nothing about the bounds enters it, which is exactly why the tunnel
//     tests below assert placements that do NOT move when the label text (and therefore the
//     arrow the tunnel draws) changes size.
//
// EXPECTED VALUES ARE LITERALS, DERIVED FROM JAVA, NOT FROM THIS PORT. Each one is the upstream
// arithmetic applied by hand to a package whose geometry is `Bounds.create(0, -30, pins * 10,
// height).rotate(EAST, facing, 0, 0)`: e.g. a 14-pin 7400 at (100, 200) facing NORTH occupies
// (70, 60, 60, 140), so its label sits at (70 + 60/2, 60 - 3) = (100, 57). Recomputing them from
// `painter.bounds` inside the test would make the assertions tautological.
//
// BOTH HALVES. Drawing asks `InstanceLabelProvider.labelPlacement`; editing asks
// `InstanceTextFieldSpec.resolve`, which recomputes the six upstream `setTextField` arguments
// from that same function. `editingSeesTheSamePlacement` asserts the two agree for every case in
// the table, which is what makes "one conformance closes both halves" a measurement instead of a
// claim.
//
// RED PROBE. Each applied alone and reverted before the next; the suite was re-run green in
// between and `git status` was clean after every revert. Counts are the ones actually printed.
//
//   probe                                     | tests reddened (issues)
//   ------------------------------------------|---------------------------------------------
//   Ttl `bds.y - 3` → `bds.y - 4`             | 4 (8): ttlNorthArm, ttlSouthArm,
//                                             |   ttlOtherChipsUseTheirOwnBounds,
//                                             |   editingSeesTheSamePlacement
//   Ttl: delete the E/W arm, so every facing   | 5 (9): + ttlEastArm, ttlWestArm,
//     takes the N/S one                       |   ttlFamilyIsCoveredByInheritance (0 of 61),
//                                             |   − the two N/S tests
//   Ttl `labelPlacement` → `nil`              | 7 (17): every TTL test; both tunnel-only
//                                             |   tests stayed green, as they must
//   Tunnel: `loc.x + labelX` → `labelX`       | 4 (10): tunnelIsAttributeDriven,
//                                             |   tunnelAnchorIsIndependentOfTheArrow,
//                                             |   tunnelIsEditable, editingSeesTheSamePlacement
//   Tunnel `labelPlacement` → `nil`           | 4 (10): the same four, and `resolve` itself
//                                             |   returned nil, i.e. the caret disappears
//
// Every probe built with **zero errors**, which is the whole reason this file asserts
// coordinates rather than conformance.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// A placed component of `factory` at `location`, facing `facing`.
private func place(
  _ factory: any ComponentFactory, at location: Location, facing: Direction
) throws -> any Component {
  let attributes = factory.createAttributeSet()
  try attributes.setValue(StdAttr.facing, facing)
  return try factory.createComponent(location: location, attributes: attributes)
}

/// The placement the *painter* would use: `InstancePainter.drawLabel`'s own first step.
private func drawnPlacement(of component: any Component) -> LabelPlacement? {
  guard let provider = component.factory as? InstanceLabelProvider else { return nil }
  let painter = InstancePainter(
    g: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext(),
    component: component)
  return provider.labelPlacement(painter)
}

/// The placement the *caret* would use: the six `setTextField` arguments, recomputed.
private func editedPlacement(of component: any Component) -> LabelPlacement? {
  guard let std = component as? StdInstanceComponent,
    let spec = InstanceTextFieldSpec.resolve(for: std, measurer: NominalTextMeasurer())
  else { return nil }
  return LabelPlacement(x: spec.x, y: spec.y, halign: spec.halign, valign: spec.valign)
}

/// One expected row: a factory, a facing, and the six upstream arguments.
private struct Case {
  let name: String
  let factory: () -> any ComponentFactory
  let location: Location
  let facing: Direction
  let expected: LabelPlacement
}

private func ttlCase(
  _ name: String, _ factory: @escaping @autoclosure () -> any ComponentFactory,
  _ facing: Direction, _ x: Int, _ y: Int, _ halign: HAlign
) -> Case {
  Case(
    name: name, factory: factory,
    location: Location.create(100, 200, hasToSnap: false), facing: facing,
    expected: LabelPlacement(x: x, y: y, halign: halign, valign: .centerOverall))
}

/// Every case in one table, so `editingSeesTheSamePlacement` can walk exactly the set the
/// drawing tests assert on and no row can be covered by one half only.
private let allCases: [Case] = [
  // 7400: 14 pins, DEFAULT_HEIGHT 60. Unrotated package (0, -30, 140, 60).
  ttlCase("7400 EAST", Ttl7400(), .east, 243, 200, .left),  // bounds (100, 170, 140, 60)
  ttlCase("7400 WEST", Ttl7400(), .west, 103, 200, .left),  // bounds (-40, 170, 140, 60)
  ttlCase("7400 NORTH", Ttl7400(), .north, 100, 57, .center),  // bounds (70, 60, 60, 140)
  ttlCase("7400 SOUTH", Ttl7400(), .south, 100, 197, .center),  // bounds (70, 200, 60, 140)
  // 74165: 16 pins, height 60: a wider package, so the E/W arm must move and the N/S arm
  // must not.
  ttlCase("74165 EAST", Ttl74165(), .east, 263, 200, .left),  // bounds (100, 170, 160, 60)
  ttlCase("74165 NORTH", Ttl74165(), .north, 100, 37, .center),  // bounds (70, 40, 60, 160)
  // 74273: 20 pins AND height 80; the only case where the E/W arm's `height / 2` is not 30.
  ttlCase("74273 EAST", Ttl74273(), .east, 303, 210, .left),  // bounds (100, 170, 200, 80)
  ttlCase("74273 NORTH", Ttl74273(), .north, 110, -3, .center),  // bounds (70, 0, 80, 200)
  // Tunnel: ARROW_MARGIN is 5, and the aligns come from the attributes, not the bounds.
  Case(
    name: "Tunnel WEST", factory: { Tunnel() },
    location: Location.create(30, 40, hasToSnap: false), facing: .west,
    expected: LabelPlacement(x: 35, y: 40, halign: .left, valign: .centerOverall)),
  Case(
    name: "Tunnel EAST", factory: { Tunnel() },
    location: Location.create(30, 40, hasToSnap: false), facing: .east,
    expected: LabelPlacement(x: 25, y: 40, halign: .right, valign: .centerOverall)),
  Case(
    name: "Tunnel NORTH", factory: { Tunnel() },
    location: Location.create(30, 40, hasToSnap: false), facing: .north,
    expected: LabelPlacement(x: 30, y: 45, halign: .center, valign: .top)),
  Case(
    name: "Tunnel SOUTH", factory: { Tunnel() },
    location: Location.create(30, 40, hasToSnap: false), facing: .south,
    expected: LabelPlacement(x: 30, y: 35, halign: .center, valign: .bottom)),
]

// MARK: - The suite

@Suite("Label placement: the TTL family and Tunnel")
struct TtlTunnelLabelPlacementTests {

  // MARK: AbstractTtlGate — the E/W arm

  @Test("a 7400 facing EAST labels to the right of the package, H_LEFT/V_CENTER_OVERALL")
  func ttlEastArm() throws {
    let component = try place(Ttl7400(), at: Location.create(100, 200, hasToSnap: false), facing: .east)
    #expect(component.bounds == Bounds.create(100, 170, 140, 60))
    #expect(
      drawnPlacement(of: component)
        == LabelPlacement(x: 243, y: 200, halign: .left, valign: .centerOverall))
  }

  /// WEST is the arm most easily lost: it shares the *formula* with EAST but not the bounds,
  /// because `getOffsetBounds` rotates the package 180° so its origin lands left of the
  /// location. The label still hangs off the package's right edge, which is now near the anchor.
  @Test("a 7400 facing WEST uses the same arm over 180°-rotated bounds")
  func ttlWestArm() throws {
    let component = try place(Ttl7400(), at: Location.create(100, 200, hasToSnap: false), facing: .west)
    #expect(component.bounds == Bounds.create(-40, 170, 140, 60))
    #expect(
      drawnPlacement(of: component)
        == LabelPlacement(x: 103, y: 200, halign: .left, valign: .centerOverall))
  }

  // MARK: AbstractTtlGate — the N/S arm

  @Test("a 7400 facing NORTH labels 3px above the top edge, H_CENTER/V_CENTER_OVERALL")
  func ttlNorthArm() throws {
    let component = try place(Ttl7400(), at: Location.create(100, 200, hasToSnap: false), facing: .north)
    #expect(component.bounds == Bounds.create(70, 60, 60, 140))
    #expect(
      drawnPlacement(of: component)
        == LabelPlacement(x: 100, y: 57, halign: .center, valign: .centerOverall))
  }

  @Test("a 7400 facing SOUTH takes the same arm as NORTH")
  func ttlSouthArm() throws {
    let component = try place(Ttl7400(), at: Location.create(100, 200, hasToSnap: false), facing: .south)
    #expect(component.bounds == Bounds.create(70, 200, 60, 140))
    #expect(
      drawnPlacement(of: component)
        == LabelPlacement(x: 100, y: 197, halign: .center, valign: .centerOverall))
  }

  /// The arithmetic reads the chip's own package, not the 14-pin default: a 16-pin chip is 20px
  /// wider and a 20-pin/80-tall one moves in both arms.
  @Test("chips of other pin counts and heights place from their own bounds")
  func ttlOtherChipsUseTheirOwnBounds() throws {
    for testCase in allCases where testCase.name.hasPrefix("74165") || testCase.name.hasPrefix("74273") {
      let component = try place(
        testCase.factory(), at: testCase.location, facing: testCase.facing)
      #expect(drawnPlacement(of: component) == testCase.expected, "\(testCase.name)")
    }
  }

  /// One conformance, 65 chips. Upstream's only `setTextField` call for the whole family is
  /// `AbstractTtlGate.configureNewInstance`, and no chip overrides `computeTextField`.
  @Test("every 74xx factory in TtlLibrary inherits the conformance")
  func ttlFamilyIsCoveredByInheritance() throws {
    let factories = TtlLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
    #expect(factories.count >= 60, "only \(factories.count) TTL factories found")
    var conforming = 0
    var placing = 0
    for factory in factories {
      guard factory is InstanceLabelProvider else { continue }
      conforming += 1
      let component = try place(
        factory, at: Location.create(100, 200, hasToSnap: false), facing: .east)
      // The E/W arm, expressed without re-deriving it: the label's anchor is 3px past the
      // package's right edge and level with its vertical centre, whatever the package is.
      let bds = component.bounds
      if drawnPlacement(of: component)
        == LabelPlacement(
          x: bds.x + bds.width + 3, y: bds.y + bds.height / 2, halign: .left,
          valign: .centerOverall)
      {
        placing += 1
      }
    }
    #expect(conforming == factories.count)
    #expect(placing == factories.count)
  }

  // MARK: Tunnel

  @Test("a tunnel's label is placed by its attributes, one arm per facing")
  func tunnelIsAttributeDriven() throws {
    for testCase in allCases where testCase.name.hasPrefix("Tunnel") {
      let component = try place(
        testCase.factory(), at: testCase.location, facing: testCase.facing)
      #expect(drawnPlacement(of: component) == testCase.expected, "\(testCase.name)")
    }
  }

  /// The tunnel placement is *not* bounds-driven, and this is the test that proves the
  /// difference is real rather than incidental: a longer label grows the arrow (and therefore
  /// `getOffsetBounds`) while the label anchor stays exactly where it was.
  @Test("a tunnel's label anchor does not move when its text — and its arrow — grows")
  func tunnelAnchorIsIndependentOfTheArrow() throws {
    let factory = Tunnel()
    let short = factory.createAttributeSet()
    try short.setValue(StdAttr.label, "a")
    let long = factory.createAttributeSet()
    try long.setValue(StdAttr.label, "a_very_long_tunnel_name")
    let location = Location.create(30, 40, hasToSnap: false)
    let shortComponent = try factory.createComponent(location: location, attributes: short)
    let longComponent = try factory.createComponent(location: location, attributes: long)
    #expect(shortComponent.bounds.width < longComponent.bounds.width)
    #expect(
      drawnPlacement(of: shortComponent)
        == LabelPlacement(x: 35, y: 40, halign: .left, valign: .centerOverall))
    #expect(drawnPlacement(of: shortComponent) == drawnPlacement(of: longComponent))
  }

  @Test("a tunnel offers an editable label field")
  func tunnelIsEditable() throws {
    let component = try place(
      Tunnel(), at: Location.create(30, 40, hasToSnap: false), facing: .west)
    let std = try #require(component as? StdInstanceComponent)
    let spec = try #require(InstanceTextFieldSpec.resolve(for: std, measurer: NominalTextMeasurer()))
    #expect(spec.textAttribute.name == StdAttr.label.name)
    #expect(spec.fontAttribute?.name == StdAttr.labelFont.name)
    #expect((spec.x, spec.y) == (35, 40))
    #expect(spec.halign == .left)
    #expect(spec.valign == .centerOverall)
  }

  // MARK: Both halves at once

  /// Drawing and editing recompute from the same function, so they cannot drift; asserted over
  /// the whole table rather than assumed from the shared call.
  @Test("the caret's six setTextField arguments equal the drawn placement, every case")
  func editingSeesTheSamePlacement() throws {
    var checked = 0
    for testCase in allCases {
      let component = try place(
        testCase.factory(), at: testCase.location, facing: testCase.facing)
      #expect(editedPlacement(of: component) == testCase.expected, "\(testCase.name)")
      #expect(editedPlacement(of: component) == drawnPlacement(of: component), "\(testCase.name)")
      checked += 1
    }
    #expect(checked == 12)
  }
}
