// CircuitAppearanceDefaults.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.appear.{DefaultAppearance,
// DefaultEvolutionAppearance, DefaultClassicAppearance, DefaultHolyCrossAppearance,
// DefaultCustomAppearance}), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// ── What this file is, and what it deliberately is not ──────────────────────────────────────
//
// Upstream's four `Default*Appearance.build` methods return a `List<CanvasObject>`: rectangles,
// curves, text labels, clock-indicator polygons, *and* the two `AppearanceElement` subclasses
// that carry no ink at all; `AppearancePort` and `AppearanceAnchor`.
//
// Only those last two are netlist-bearing. `CircuitAppearance.getPortOffsets` filters
// `getObjectsFromBottom()` down to exactly `AppearancePort` and `AppearanceAnchor` and ignores
// every drawn shape; `SubcircuitFactory.computePorts` then turns the result into the component's
// ends. So this file ports the *placement arithmetic* of all four builders and drops the ink.
//
// That is a faithful port rather than an approximation, because the placement arithmetic never
// touches a `Graphics` or a `FontMetrics`. `DrawAttr.FIXED_FONT_CHAR_WIDTH = 8` and
// `FIXED_FONT_HEIGHT = 12` are hard-coded integers (`DrawAttr.java:27-30`), and
// `DefaultHolyCrossAppearance` carries its own `asciiWidths` table for precisely the reason its
// comment gives: "Precise font dimensions vary based on the platform. We need component widths
// to be stable, so we approximate the widths when sizing components." Every port coordinate
// below is therefore integer arithmetic over the circuit's own pins, and it is exact.
//
// D9: no AppKit, no CoreText, no LogisimRender. This is the inert-model module and it stays so.

import Foundation
import LogisimKernel

// MARK: - The netlist-bearing half of a built appearance

/// `com.cburch.logisim.circuit.appear.AppearancePort`, reduced to the two fields
/// `getPortOffsets` reads: where the port sits, and which `Pin` component it stands for.
struct AppearancePortShape {
  let location: Location
  /// The `Pin` component inside the circuit. `unowned`-like by construction: the layout is a
  /// short-lived value computed inside `computePorts` and dropped before it returns, so it never
  /// outlives the circuit that owns the component.
  let pin: any Component
}

/// The `AppearancePort` + `AppearanceAnchor` content of a `CircuitAppearance`'s object list.
///
/// `anchor` is optional because `CircuitAppearance.getPortOffsets` treats a missing anchor as
/// "do not translate" (`if (anchor != null)`), which is reachable for a hand-written `<appear>`
/// with no `circ-anchor` element. Every *default* appearance always emits one.
struct AppearanceLayout {
  var ports: [AppearancePortShape] = []
  var anchor: Location?
  /// `AppearanceAnchor.getFacingDirection()`. The constructor assigns `Direction.EAST`
  /// (`AppearanceAnchor.java:41`), so every default appearance answers east; only a custom
  /// `<circ-anchor facing="…">` can say otherwise.
  var anchorFacing: Direction = .east
}

// MARK: - Sorting

/// `DefaultAppearance.sortPinList(List<Instance>, Direction)`.
///
/// ```java
/// if (facing == Direction.NORTH || facing == Direction.SOUTH) Location.sortHorizontal(pins);
/// else Location.sortVertical(pins);
/// ```
///
/// **This is the ordering the whole port list hangs off, so it is transcribed rather than
/// assumed.** `sortVertical` is *top before bottom, ties broken left before right*; not
/// left-to-right. Getting it backwards transposes a pin pair and silently miswires every
/// instantiation of the circuit, which no build error and no round-trip test would catch.
///
/// The final tiebreak differs from Java and cannot not: upstream falls back to
/// `a.hashCode() - b.hashCode()`, an identity hash that is not stable across runs, let alone
/// across languages (this is the divergence `Location.swift` already documents). Two pins at the
/// *exact same* location is the only case that reaches it, and `Circuit`'s overlap map makes that
/// unreachable from a loaded file. The port keeps the original list index as the tiebreak, which
/// makes the sort stable and deterministic instead of arbitrary.
enum AppearancePinSort {

  /// `Location.sortVertical`: top before bottom, then left before right.
  static func vertical(_ pins: [any Component]) -> [any Component] {
    stableSort(pins) { a, b in
      let al = a.location
      let bl = b.location
      if al.y != bl.y { return al.y < bl.y }
      return al.x < bl.x
    }
  }

  /// `Location.sortHorizontal`: left before right, then top before bottom.
  static func horizontal(_ pins: [any Component]) -> [any Component] {
    stableSort(pins) { a, b in
      let al = a.location
      let bl = b.location
      if al.x != bl.x { return al.x < bl.x }
      return al.y < bl.y
    }
  }

  /// `DefaultAppearance.sortPinList`, dispatching on the edge the list belongs to.
  static func byEdge(_ pins: [any Component], facing: Direction) -> [any Component] {
    (facing == .north || facing == .south) ? horizontal(pins) : vertical(pins)
  }

  /// Swift's `sort(by:)` is not documented stable; `List.sort` in Java is. Decorating with the
  /// original index restores that, and doubles as the deterministic replacement for Java's
  /// `hashCode` tiebreak.
  private static func stableSort(
    _ pins: [any Component], _ isBefore: (any Component, any Component) -> Bool
  ) -> [any Component] {
    pins.enumerated()
      .sorted { lhs, rhs in
        if isBefore(lhs.element, rhs.element) { return true }
        if isBefore(rhs.element, lhs.element) { return false }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }
}

// MARK: - The four builders

/// `DefaultAppearance.build(Collection<Instance>, AttributeOption, boolean, String)`, restricted
/// to the ports and the anchor.
enum CircuitAppearanceDefaults {

  /// `DrawAttr.FIXED_FONT_CHAR_WIDTH`.
  static let fixedFontCharWidth = 8
  /// `DrawAttr.FIXED_FONT_HEIGHT`.
  static let fixedFontHeight = 12

  /// ```java
  /// if (style == APPEAR_CLASSIC)   return DefaultClassicAppearance.build(pins);
  /// if (style == APPEAR_FPGA)      return DefaultHolyCrossAppearance.build(pins, circuitName);
  /// return DefaultEvolutionAppearance.build(pins, circuitName, isFixed);
  /// ```
  ///
  /// Note the fall-through: an unrecognised style, including `APPEAR_CUSTOM`, which never
  /// reaches here because `isDefaultAppearance()` diverts it, builds the evolution shape.
  static func build(
    style: AttributeOption?,
    pins: [any Component],
    circuitName: String,
    isFixedSize: Bool
  ) -> AppearanceLayout {
    if style == CircuitAttributes.appearClassic { return classic(pins: pins) }
    if style == CircuitAttributes.appearFpga {
      return holyCross(pins: pins, circuitName: circuitName)
    }
    return evolution(pins: pins, circuitName: circuitName, isFixedSize: isFixedSize)
  }

  // MARK: Evolution

  /// `DefaultEvolutionAppearance.build(pins, circuitName, fixedSize)`.
  ///
  /// `OFFS = 50`. Pins split east (output) / west (everything else), each edge sorted, then laid
  /// down the two vertical sides at `dy` spacing starting `10` below the box top.
  static func evolution(
    pins: [any Component], circuitName: String, isFixedSize: Bool
  ) -> AppearanceLayout {
    let split = splitEastWest(pins)
    let east = AppearancePinSort.byEdge(split.east, facing: .east)
    let west = AppearancePinSort.byEdge(split.west, facing: .west)

    // `TitleWidth`. The `circuitName == null` branch (14 characters) belongs to `VhdlEntity`;
    // a `Circuit` always has a name attribute and `Circuit.name` substitutes "" for the null.
    let titleWidth = circuitName.utf16.count * fixedFontCharWidth

    let numEast = east.count
    let numWest = west.count
    let maxVert = max(numEast, numWest)

    let dy = ((fixedFontHeight + (fixedFontHeight >> 2) + 5) / 10) * 10
    let textWidth =
      isFixedSize
      ? 25 * fixedFontCharWidth
      : max(split.maxLeftLabelLength + split.maxRightLabelLength + 35, titleWidth + 15)
    let titleBarHeight = ((fixedFontHeight + 10) / 10) * 10
    let width = (textWidth / 10) * 10 + 20
    let height = (maxVert > 0) ? maxVert * dy + titleBarHeight : 10 + titleBarHeight

    let anchorOffset = eastWestAnchorOffset(numEast: numEast, numWest: numWest, width: width)
    let origin = gridAlignedOrigin(ax: anchorOffset.ax, ay: anchorOffset.ay)

    var layout = AppearanceLayout()
    placeColumn(&layout, west, x: origin.x, y: origin.y + 10, dy: dy)
    placeColumn(&layout, east, x: origin.x + width, y: origin.y + 10, dy: dy)
    layout.anchor = Location.create(
      origin.x + anchorOffset.ax, origin.y + anchorOffset.ay, hasToSnap: true)
    return layout
  }

  // MARK: Classic

  /// `DefaultClassicAppearance.build(pins)`.
  ///
  /// The one builder that uses all four edges, and the one whose bucket key is the pin's own
  /// `StdAttr.FACING` **reversed**; a pin facing east is drawn on the box's west side, because
  /// the pin's facing is the direction its wire leaves in.
  static func classic(pins: [any Component]) -> AppearanceLayout {
    var edge: [Direction: [any Component]] = [.north: [], .south: [], .east: [], .west: []]
    for pin in pins {
      let pinEdge = AppearancePinReader.facing(pin).reverse()
      // Java indexes a `HashMap` seeded with exactly the four cardinals; `Direction` has no
      // fifth case, so the lookup cannot miss.
      edge[pinEdge, default: []].append(pin)
    }
    for (direction, list) in edge {
      edge[direction] = AppearancePinSort.byEdge(list, facing: direction)
    }

    let north = edge[.north] ?? []
    let south = edge[.south] ?? []
    let east = edge[.east] ?? []
    let west = edge[.west] ?? []
    let numNorth = north.count
    let numSouth = south.count
    let numEast = east.count
    let numWest = west.count
    let maxVert = max(numNorth, numSouth)
    let maxHorz = max(numEast, numWest)

    let offsNorth = classicOffset(numFacing: numNorth, numOpposite: numSouth, maxOthers: maxHorz)
    let offsSouth = classicOffset(numFacing: numSouth, numOpposite: numNorth, maxOthers: maxHorz)
    let offsEast = classicOffset(numFacing: numEast, numOpposite: numWest, maxOthers: maxVert)
    let offsWest = classicOffset(numFacing: numWest, numOpposite: numEast, maxOthers: maxVert)

    let width = classicDimension(maxThis: maxVert, maxOthers: maxHorz)
    let height = classicDimension(maxThis: maxHorz, maxOthers: maxVert)

    // "compute position of anchor relative to top left corner of box", verbatim: note the
    // four-way cascade, which is Classic's alone; the other builders only test east then west.
    let ax: Int
    let ay: Int
    if numEast > 0 {
      ax = width
      ay = offsEast
    } else if numNorth > 0 {
      ax = offsNorth
      ay = 0
    } else if numWest > 0 {
      ax = 0
      ay = offsWest
    } else if numSouth > 0 {
      ax = offsSouth
      ay = height
    } else {
      ax = 0
      ay = 0
    }

    // `Math.round((OFFS + ax) / 10) * 10`. The division is *integer* division, `Math.round`
    // then receives an `int` widened to `float` and returns it unchanged, so this is a floor to
    // the multiple of 10 below, not a round-to-nearest. `ax` is never negative, so Swift's `/`
    // and Java's agree.
    let rx = ((50 + ax) / 10) * 10
    let ry = ((50 + ay) / 10) * 10

    var layout = AppearanceLayout()
    placeRun(&layout, west, x: rx, y: ry + offsWest, dx: 0, dy: 10)
    placeRun(&layout, east, x: rx + width, y: ry + offsEast, dx: 0, dy: 10)
    placeRun(&layout, north, x: rx + offsNorth, y: ry, dx: 10, dy: 0)
    placeRun(&layout, south, x: rx + offsSouth, y: ry + height, dx: 10, dy: 0)
    layout.anchor = Location.create(rx + ax, ry + ay, hasToSnap: true)
    return layout
  }

  /// `DefaultClassicAppearance.computeDimension(int maxThis, int maxOthers)`.
  private static func classicDimension(maxThis: Int, maxOthers: Int) -> Int {
    if maxThis < 3 { return 30 }
    if maxOthers == 0 { return 10 * maxThis }
    return 10 * maxThis + 10
  }

  /// `DefaultClassicAppearance.computeOffset(int numFacing, int numOpposite, int maxOthers)`.
  private static func classicOffset(numFacing: Int, numOpposite: Int, maxOthers: Int) -> Int {
    let maxThis = max(numFacing, numOpposite)
    let maxOffs: Int
    switch maxThis {
    case 0, 1: maxOffs = (maxOthers == 0) ? 15 : 10
    case 2: maxOffs = 10
    default: maxOffs = (maxOthers == 0) ? 5 : 10
    }
    return maxOffs + 10 * ((maxThis - numFacing) / 2)
  }

  // MARK: HolyCross (the `APPEAR_FPGA` style, spelled `evolution` in the file)

  /// `DefaultHolyCrossAppearance.build(pins, name)`.
  ///
  /// Note `computeOffset` upstream ignores both its arguments and returns `TOP_MARGIN`; that is
  /// reproduced as the constant rather than "simplified away", because the two call sites read
  /// as if they could differ and a future upstream change would land there.
  static func holyCross(pins: [any Component], circuitName: String) -> AppearanceLayout {
    let labelOutside = 5
    let labelGap = 15
    let portGap = 10
    let topMargin = 30
    let bottomMargin = 5
    let minWidth = 100
    let minHeight = 40

    let split = splitEastWest(pins, labelWidth: holyCrossTextWidth)
    let east = AppearancePinSort.byEdge(split.east, facing: .east)
    let west = AppearancePinSort.byEdge(split.west, facing: .west)
    let numEast = east.count
    let numWest = west.count
    let maxHorz = max(numEast, numWest)

    let offsEast = topMargin
    let offsWest = topMargin

    var width = 2 * labelOutside + split.maxLeftLabelLength + split.maxRightLabelLength + labelGap
    width = max(minWidth, (width + 9) / 10 * 10)

    var height = portGap * maxHorz + topMargin + bottomMargin
    height = max(minHeight, height)

    let anchorOffset = eastWestAnchorOffset(
      numEast: numEast, numWest: numWest, width: width,
      eastY: offsEast, westY: offsWest)
    let origin = gridAlignedOrigin(ax: anchorOffset.ax, ay: anchorOffset.ay)

    var layout = AppearanceLayout()
    placeColumn(&layout, west, x: origin.x, y: origin.y + offsWest, dy: portGap)
    placeColumn(&layout, east, x: origin.x + width, y: origin.y + offsEast, dy: portGap)
    layout.anchor = Location.create(
      origin.x + anchorOffset.ax, origin.y + anchorOffset.ay, hasToSnap: true)
    _ = circuitName  // only the (undrawn) title text uses it
    return layout
  }

  /// `DefaultHolyCrossAppearance.asciiWidths`; the 10-point-font table upstream bakes in so
  /// that box widths do not vary with the host's fonts. Index 0 is `' '`; the table stops at
  /// `'}'` (0x7D), and `textWidth` charges 8 for anything outside `' '…'~'`.
  ///
  /// Note the off-by-one that follows from that: `'~'` (0x7E) is inside the `c >= ' ' && c <= '~'`
  /// guard but past the end of the 94-entry table, so upstream throws
  /// `ArrayIndexOutOfBoundsException` on a pin label containing a tilde. **That trap is not
  /// reproduced**; D13: a `.circ` file is untrusted input and a tilde in a pin label must not
  /// take the process down. It is charged 8, the same as any other out-of-table character.
  private static let asciiWidths: [Int] = [
    3, 4, 5, 8, 6, 10, 9, 3,
    4, 4, 5, 8, 3, 4, 3, 3,
    6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 3, 3, 8, 8, 8, 5,
    11, 7, 7, 8, 8, 7, 6, 8,
    8, 3, 3, 7, 6, 9, 8, 8,
    7, 8, 7, 7, 5, 8, 7, 9,
    6, 7, 6, 4, 3, 4, 8, 5,
    5, 6, 6, 5, 6, 6, 4, 6,
    6, 2, 2, 5, 2, 10, 6, 6,
    6, 6, 4, 5, 4, 6, 6, 8,
    6, 6, 5, 6, 3, 6,
  ]

  /// `DefaultHolyCrossAppearance.textWidth(String)`.
  ///
  /// Java walks `charAt`, i.e. UTF-16 code units, so a surrogate pair is charged 8 twice.
  /// `utf16` reproduces that exactly; `Character` would charge it once.
  private static func holyCrossTextWidth(_ text: String) -> Int {
    var total = 0
    for unit in text.utf16 {
      let index = Int(unit) - 32
      if index >= 0 && index < asciiWidths.count {
        total += asciiWidths[index]
      } else {
        total += 8
      }
    }
    return total
  }

  // MARK: The custom-appearance fallback

  /// `DefaultCustomAppearance.build(pins)`.
  ///
  /// What a `custom` circuit shows before anyone has drawn anything: the evolution box's port
  /// arithmetic with the fixed-size width (`25 * 8`) and a flat `10` spacing instead of `dy`.
  /// It is the list `CircuitAppearance`'s constructor installs, and therefore what
  /// `getPortOffsets` reads for a circuit whose `<appear>` declared no `circ-port` at all.
  static func customFallback(pins: [any Component]) -> AppearanceLayout {
    let split = splitEastWest(pins)
    let east = AppearancePinSort.byEdge(split.east, facing: .east)
    let west = AppearancePinSort.byEdge(split.west, facing: .west)
    let numEast = east.count
    let numWest = west.count

    let textWidth = 25 * fixedFontCharWidth
    let width = (textWidth / 10) * 10 + 20

    let anchorOffset = eastWestAnchorOffset(numEast: numEast, numWest: numWest, width: width)
    let origin = gridAlignedOrigin(ax: anchorOffset.ax, ay: anchorOffset.ay)

    var layout = AppearanceLayout()
    placeColumn(&layout, west, x: origin.x, y: origin.y + 10, dy: 10)
    placeColumn(&layout, east, x: origin.x + width, y: origin.y + 10, dy: 10)
    layout.anchor = Location.create(
      origin.x + anchorOffset.ax, origin.y + anchorOffset.ay, hasToSnap: true)
    return layout
  }

  // MARK: Shared arithmetic

  /// The east/west split three of the four builders open with, plus the widest label on each
  /// side. Only the label *metric* differs between them, so it is a parameter.
  ///
  /// `PinAttributes.type` defaults to `Pin.INPUT`, so an absent or unrecognised type is west,
  /// which is upstream's `else` branch, not a guess.
  private static func splitEastWest(
    _ pins: [any Component],
    labelWidth metric: (String) -> Int = { $0.utf16.count * fixedFontCharWidth }
  ) -> (east: [any Component], west: [any Component], maxLeftLabelLength: Int,
    maxRightLabelLength: Int)
  {
    var east: [any Component] = []
    var west: [any Component] = []
    var maxLeft = 0
    var maxRight = 0
    for pin in pins {
      let width = metric(AppearancePinReader.label(pin))
      if AppearancePinReader.isOutput(pin) {
        east.append(pin)
        if width > maxRight { maxRight = width }
      } else {
        west.append(pin)
        if width > maxLeft { maxLeft = width }
      }
    }
    return (east, west, maxLeft, maxRight)
  }

  /// "compute position of anchor relative to top left corner of box" for the three east/west
  /// builders. `eastY`/`westY` are 10 for evolution and the custom fallback, `TOP_MARGIN` for
  /// HolyCross.
  private static func eastWestAnchorOffset(
    numEast: Int, numWest: Int, width: Int, eastY: Int = 10, westY: Int = 10
  ) -> (ax: Int, ay: Int) {
    if numEast > 0 { return (width, eastY) }
    if numWest > 0 { return (0, westY) }
    return (0, 0)
  }

  /// "place rectangle so anchor is on the grid": `rx = OFFS + (9 - (ax + 9) % 10)`.
  ///
  /// `OFFS` is 50 in all three east/west builders. `ax`/`ay` are non-negative, so `%` agrees
  /// between Java and Swift (they differ only in sign for negative left operands).
  private static func gridAlignedOrigin(ax: Int, ay: Int) -> (x: Int, y: Int) {
    (50 + (9 - (ax + 9) % 10), 50 + (9 - (ay + 9) % 10))
  }

  /// `placePins(dest, pins, x, y, 0, dY, …)`: the vertical-run case, which is all three
  /// east/west builders.
  private static func placeColumn(
    _ layout: inout AppearanceLayout, _ pins: [any Component], x: Int, y: Int, dy: Int
  ) {
    placeRun(&layout, pins, x: x, y: y, dx: 0, dy: dy)
  }

  /// `placePins(dest, pins, x, y, dX, dY, …)` reduced to its one netlist-bearing statement,
  /// `dest.add(new AppearancePort(Location.create(x, y, true), pin))`.
  private static func placeRun(
    _ layout: inout AppearanceLayout, _ pins: [any Component], x: Int, y: Int, dx: Int, dy: Int
  ) {
    var px = x
    var py = y
    for pin in pins {
      layout.ports.append(
        AppearancePortShape(location: Location.create(px, py, hasToSnap: true), pin: pin))
      px += dx
      py += dy
    }
  }
}
