// DefaultAppearanceShapes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.appear.DefaultEvolutionAppearance,
// com.cburch.draw.shapes.DrawAttr), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). `DefaultEvolutionAppearance.java:35-183`.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT IS AND IS NOT REBUILT HERE, and why it is not a third copy of the box arithmetic
//
// `DefaultEvolutionAppearance.build` returns ONE list mixing two kinds of object:
//
//   * `AppearancePort` / `AppearanceAnchor`, the netlist half. Already ported, in
//     `LogisimFile/CircuitAppearanceDefaults.swift`, because `computePorts` needed it at M2.
//   * `Rectangle` / `Text` / `Poly`: the drawn half. Never ported, which is the defect.
//
// The obvious way to add the second half is to transcribe `build` again from the Java. That
// would put the width/height/anchor arithmetic in a THIRD place (it is already in
// `CircuitAppearanceDefaults.evolution` and in `DefaultEvolutionAppearanceGeometry.offsetBounds`),
// and a schematic whose drawn box disagreed with its own `getOffsetBounds` by one pixel would be
// wrong in a way no test on either copy alone can see. That is the `LedArrayDriving` duplication
// this project has already collapsed once.
//
// So this file derives instead, from the two public answers the port already computes:
//
//   * the box, from `CircuitSubcircuitFactory.offsetBounds`: un-rotated, i.e. asked in the
//     appearance's own facing;
//   * the ports, from `CircuitAppearance.portOffsets(facing:)` in that same facing.
//
// Everything `build` draws is a function of those two plus per-pin attributes, and the two
// derivations below are the only ones needed:
//
//   | upstream expression                | derived as                                        |
//   |------------------------------------|---------------------------------------------------|
//   | `rx`, `ry` (grid-aligned origin)   | `box.x`, `box.y`, `getOffsetBounds` is the box   |
//   |                                    | translated by `-anchor`, and `ax = rx - box.x`    |
//   | `width`, `height`                  | `box.width`, `box.height`                         |
//   | `thight` (title bar)               | **constant 20**, `((12 + 10) / 10) * 10`, and    |
//   |                                    | `FIXED_FONT_HEIGHT` is a hard-coded 12            |
//   | port x/y                           | `portOffsets` entries                             |
//   | east vs west                       | `Pin.ATTR_TYPE`, which is `build`'s own criterion |
//
// `thight` and `dy` are *literals* in disguise: `DrawAttr.FIXED_FONT_HEIGHT` is 12 and
// `FIXED_FONT_CHAR_WIDTH` is 8, hard-coded integers rather than `FontMetrics` queries
// (`DrawAttr.java:27-30`), so `dy == 20` and `thight == 20` for every circuit that has ever
// existed. They are written as the expressions anyway, so a future upstream font change lands
// where it reads.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE STYLE GAP, STATED RATHER THAN HIDDEN
//
// Only the **evolution** box is built. `DefaultClassicAppearance` (133 lines) and
// `DefaultHolyCrossAppearance` (238 lines) draw different boxes, and their *port* layouts are
// already ported in `CircuitAppearanceDefaults`, but their **bounds are not**:
// `CircuitSubcircuitFactory.offsetBounds` calls `DefaultEvolutionAppearanceGeometry.offsetBounds`
// unconditionally, whatever the style, and that file's own header says so. So a classic-styled
// circuit ALREADY has an evolution-sized box for hit-testing and for the reader's overlap map.
//
// Drawing the true classic box here would therefore make the drawing disagree with the
// component's own `bounds`; the ink would fall outside the rectangle the canvas hit-tests and
// selects with, which is worse than the current mismatch, not better. The evolution box is drawn
// for every default style so that the ink and the bounds agree, and the underlying inconsistency
// is reported as a `LogisimFile` finding rather than patched around from up here.
//
// D9: no AppKit. Shapes in, primitives out.

import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel

/// `DefaultEvolutionAppearance.build`, drawn half only.
enum DefaultAppearanceShapes {

  // MARK: - `DrawAttr` constants that have no Swift home yet

  /// `DrawAttr.FIXED_FONT_HEIGHT`.
  static let fixedFontHeight = 12
  /// `DrawAttr.FIXED_FONT_ASCENT`.
  static let fixedFontAscent = 9
  /// `DrawAttr.FIXED_FONT_DESCENT`.
  static let fixedFontDescent = 1

  /// `DrawAttr.DEFAULT_NAME_FONT = new Font("Courier 10 Pitch", Font.BOLD, 14)`.
  ///
  /// The family name is transcribed verbatim rather than mapped to a macOS face. "Courier 10
  /// Pitch" is a URW/Linux font that is not installed on macOS, so `SceneFont.Family.named`
  /// resolves it through the platform's fallback; the same treatment every other unresolvable
  /// family in the corpus gets, and the reason the migration gate carries a `font-unresolved`
  /// bucket. Substituting a lookalike here would hide the substitution instead of recording it.
  static let defaultNameFont = FontSpec(family: "Courier 10 Pitch", style: .bold, size: 14)

  /// `DrawAttr.DEFAULT_FIXED_PICH_FONT = new Font("Courier 10 Pitch", Font.PLAIN, 12)`.
  /// (Upstream's spelling of "pitch"; kept so the constant is greppable against the Java.)
  static let defaultFixedPitchFont = FontSpec(family: "Courier 10 Pitch", style: .plain, size: 12)

  /// `java.awt.Color.DARK_GRAY`, `(64, 64, 64)`. The colour every pin label is drawn in.
  static let darkGray = ColorSpec(red: 64, green: 64, blue: 64)

  /// `com.cburch.logisim.circuit.Wire.WIDTH` / `.WIDTH_BUS`; 3 and 4. A pin stub is drawn as
  /// thick as the wire that will attach to it, so a bus stub is one pixel fatter.
  static let wireWidth = 3
  static let wireWidthBus = 4

  // MARK: - The build

  /// One `AppearancePort`-relative pin, as `placePins` sees it.
  struct PortPin {
    /// Anchor-relative port location, where the wire attaches.
    let location: Location
    let pin: any Component
    /// `pinEdge == Direction.WEST`, i.e. `placePins(..., isLeftSide: true, ...)`.
    let isLeftSide: Bool
  }

  /// The drawn shapes of the default box, in `build`'s own bottom-to-top order: pin stubs and
  /// their labels, then the filled title bar, then the outline, then the title.
  ///
  /// `box` is the **anchor-relative, un-rotated** offset bounds; every coordinate below is in
  /// that same frame, which is exactly the frame `paintSubcircuit` draws in after its
  /// `g.translate(-anchor)`.
  static func build(
    box: Bounds, ports: [PortPin], circuitName: String, isFixedSize: Bool
  ) -> [CanvasObject] {
    var shapes: [CanvasObject] = []

    // `final var thight = ((DrawAttr.FIXED_FONT_HEIGHT + 10) / 10) * 10;`
    let titleBarHeight = ((fixedFontHeight + 10) / 10) * 10
    // `final var sdy = (DrawAttr.FIXED_FONT_ASCENT - DrawAttr.FIXED_FONT_DESCENT) >> 1;`
    let sdy = (fixedFontAscent - fixedFontDescent) >> 1

    // `placePins(ret, edge.get(WEST), rx, ry + 10, 0, dy, true, sdy, fixedSize)` and the east
    // twin. The two loops walk their own edge lists placing shapes at a running (x, y); here the
    // running position has already been computed by the port layout, so each pin is placed at
    // its own port location and the loop is over ports rather than over an edge list. Same
    // shapes, same coordinates, and it cannot drift from the port geometry.
    for port in ports {
      shapes.append(contentsOf: placePin(port, sdy: sdy, isFixedSize: isFixedSize))
    }

    // ── The title bar ────────────────────────────────────────────────────────────────────────
    //
    // ```java
    // var rect = new Rectangle(rx + 10, ry + height - thight, width - 20, thight);
    // rect.setValue(STROKE_WIDTH, 1);
    // rect.setValue(PAINT_TYPE, PAINT_FILL);
    // rect.setValue(FILL_COLOR, Color.BLACK);
    // ```
    let titleBar = DrawRectangle(
      x: box.x + 10, y: box.y + box.height - titleBarHeight,
      w: box.width - 20, h: titleBarHeight)
    try? titleBar.setValue(DrawAttr.strokeWidth, 1)
    try? titleBar.setValue(DrawAttr.paintType, DrawAttr.paintFill)
    try? titleBar.setValue(DrawAttr.fillColor, ColorSpec(red: 0, green: 0, blue: 0))
    shapes.append(titleBar)

    // ── The outline ──────────────────────────────────────────────────────────────────────────
    //
    // `rect = new Rectangle(rx + 10, ry, width - 20, height); rect.setValue(STROKE_WIDTH, 2);`
    // No paint type and no fill colour: `FillableCanvasObject`'s defaults are `PAINT_STROKE` and
    // black, which is what makes this the outline and the one above the fill.
    let outline = DrawRectangle(x: box.x + 10, y: box.y, w: box.width - 20, h: box.height)
    try? outline.setValue(DrawAttr.strokeWidth, 2)
    shapes.append(outline)

    // ── The title ────────────────────────────────────────────────────────────────────────────
    //
    // ```java
    // var label = circuitName == null ? "VHDL Component" : circuitName;
    // if (fixedSize && label.length() > 23) label = label.substring(0, 20).concat("...");
    // final var textLabel = new Text(rx + (width >> 1), ry + (height - FIXED_FONT_DESCENT - 5), label);
    // ...setHorizontalAlignment(CENTER); ...setColor(Color.WHITE); ...setFont(DEFAULT_NAME_FONT);
    // ```
    //
    // The `circuitName == null` arm belongs to `VhdlEntity`; a `Circuit` always has a name.
    // `width >> 1` is an arithmetic shift on a non-negative width, i.e. `width / 2`, but is kept
    // as the shift so it reads against the Java.
    let title = truncate(circuitName, to: 23, when: isFixedSize)
    let titleText = DrawText(
      x: box.x + (box.width >> 1),
      y: box.y + (box.height - fixedFontDescent - 5),
      text: title)
    try? titleText.setValue(DrawAttr.halignment, DrawAttr.halignCenter)
    try? titleText.setValue(DrawAttr.fillColor, ColorSpec(red: 255, green: 255, blue: 255))
    try? titleText.setValue(DrawAttr.font, defaultNameFont)
    shapes.append(titleText)

    return shapes
  }

  /// One iteration of `DefaultEvolutionAppearance.placePins`, minus the `AppearancePort` it also
  /// emits (the ports are the netlist half and are drawn by `InstancePainter.drawPorts`).
  private static func placePin(
    _ port: PortPin, sdy: Int, isFixedSize: Bool
  ) -> [CanvasObject] {
    var shapes: [CanvasObject] = []
    let x = port.location.x
    let y = port.location.y
    let attributes = port.pin.attributeSet

    // ```java
    // final var offset = (WIDTH > 1) ? Wire.WIDTH_BUS >> 1 : Wire.WIDTH >> 1;
    // final var height = (WIDTH > 1) ? Wire.WIDTH_BUS : Wire.WIDTH;
    // ```
    let isBus = (attributes[StdAttr.width]?.width ?? 1) > 1
    let offset = isBus ? (wireWidthBus >> 1) : (wireWidth >> 1)
    let stubHeight = isBus ? wireWidthBus : wireWidth

    // `isLeftSide ? new Rectangle(x, y - offset, 10, height) : new Rectangle(x - 10, ...)`.
    let stub = DrawRectangle(
      x: port.isLeftSide ? x : x - 10, y: y - offset, w: 10, h: stubHeight)
    try? stub.setValue(DrawAttr.strokeWidth, 1)
    try? stub.setValue(DrawAttr.paintType, DrawAttr.paintFill)
    try? stub.setValue(DrawAttr.fillColor, ColorSpec(red: 0, green: 0, blue: 0))
    shapes.append(stub)

    // ```java
    // Location[] pts = { (x + 11, y - 4), (x + 18, y), (x + 11, y + 4) };
    // final var clk = new Poly(false, locs); clk.updateValue(STROKE_WIDTH, 2);
    // ```
    //
    // Transcribed including the side asymmetry: the triangle is placed at `x + 10 + …`
    // regardless of which edge the pin is on, so a *clock output*, unusual but legal, draws its
    // indicator outside the box to the right. That is upstream's behaviour, not an oversight
    // here, and "fixing" it would be a silent divergence.
    let isClock = Pin.isClockPin(attributes)
    if isClock,
      let clock = try? Poly(
        closed: false,
        locations: [
          Location.create(x + 10 + 1, y - 4, hasToSnap: false),
          Location.create(x + 10 + 8, y, hasToSnap: false),
          Location.create(x + 10 + 1, y + 4, hasToSnap: false),
        ])
    {
      try? clock.setValue(DrawAttr.strokeWidth, 2)
      shapes.append(clock)
    }

    // ```java
    // var label = pin.getAttributeValue(StdAttr.LABEL);
    // final var maxLength = isClockPin ? 11 : 12;
    // if (isFixedSize && label.length() > maxLength) label = label.substring(0, maxLength - 3) + "...";
    // int textX = x + ldX; if (isClockPin) textX += 8;
    // final var textLabel = new Text(textX, y + ldy, label);
    // ...setHorizontalAlignment(hAlign); ...setColor(DARK_GRAY); ...setFont(DEFAULT_FIXED_PICH_FONT);
    // ```
    let rawLabel = attributes[StdAttr.label] ?? ""
    let label = truncate(rawLabel, to: isClock ? 11 : 12, when: isFixedSize)
    if !label.isEmpty {
      // `ldX = 15` on the left side, `-15` on the right.
      var textX = x + (port.isLeftSide ? 15 : -15)
      if isClock { textX += 8 }
      let text = DrawText(x: textX, y: y + sdy, text: label)
      try? text.setValue(
        DrawAttr.halignment, port.isLeftSide ? DrawAttr.halignLeft : DrawAttr.halignRight)
      try? text.setValue(DrawAttr.fillColor, darkGray)
      try? text.setValue(DrawAttr.font, defaultFixedPitchFont)
      shapes.append(text)
    }

    return shapes
  }

  /// `if (fixedSize && label.length() > maxLength) label.substring(0, maxLength - 3) + "..."`.
  ///
  /// Java's `length()`/`substring` are UTF-16 code-unit operations, so the cut can land inside a
  /// surrogate pair and produce a lone surrogate. `String.UTF16View` reproduces the *count*
  /// exactly; the cut is taken on a `Character` boundary at or before the same index, which is
  /// the one place this deliberately declines to reproduce a Java bug; a lone surrogate is not
  /// representable in a Swift `String` at all.
  static func truncate(_ text: String, to maxLength: Int, when isFixedSize: Bool) -> String {
    guard isFixedSize, text.utf16.count > maxLength else { return text }
    let ellipsis = "..."
    let keep = maxLength - ellipsis.utf16.count
    guard keep > 0 else { return ellipsis }
    guard let index = text.utf16.index(text.utf16.startIndex, offsetBy: keep, limitedBy: text.utf16.endIndex),
      let scalarIndex = String.Index(index, within: text)
    else { return text }
    return String(text[text.startIndex..<scalarIndex]) + ellipsis
  }
}
