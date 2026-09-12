// SubcircuitPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SubcircuitFactory's paint half and
// com.cburch.logisim.circuit.appear.CircuitAppearance.paintSubcircuit),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). `SubcircuitFactory.java:145-171, 209-268, 349-385`,
// `CircuitAppearance.java:297-329`.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE DEFECT THIS FILE CLOSES
//
// Measured before the fix, on a parent circuit holding one subcircuit placement:
//
//     PROBE parent components: 1
//     PROBE painted: 0
//     PROBE primitives: 0
//     PROBE contentBounds: (230.0, 290.0, 70.0, 60.0)
//     PROBE factory is InstancePaintable: false
//     PROBE comp is ComponentPaintable: false
//
// **The bounds were right and nothing drew.** `CircuitRenderer.render` dispatches on exactly two
// casts: `component as? any ComponentPaintable`, then `component.factory as? any
// InstancePaintable`, and `CircuitSubcircuitFactory` matched neither, so every placement fell
// out of the walk in silence. Every hierarchical schematic showed blank space where its
// subcircuits were.
//
// `CircuitSubcircuitFactory.swift`'s own header says so plainly: "`SubcircuitFactory.java` is 515
// lines and roughly 400 of them are painting … None of that is ported here." This is that half,
// and it is the same shape as seams #9, #10, #15 and the `Text` painter: both sides existed and
// nothing owned the join.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY IT IS A RETROACTIVE CONFORMANCE, AND WHY IT LIVES HERE
//
// `CircuitSubcircuitFactory` lives in `LogisimFile`, which is BELOW `LogisimStd`, so it cannot
// name `InstancePaintable`; the protocol is declared in `LogisimStd/Instance/InstancePainter`.
// An extension one module up can, and that is exactly the move `TextPainter` makes for `Text`.
// Nothing in `LogisimFile` changes.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT IS NOT REPRODUCED, ENUMERATED RATHER THAN GLOSSED
//
//   * **`paintIcon` and its three icon renderers** (`paintClasicIcon`, `paintHCIcon`,
//     `paintEvolutionIcon`, `SubcircuitFactory.java:413-514`). Those draw into the explorer's
//     toolbar cell, not the canvas, and the icon seam is a separate protocol.
//   * **`CircuitFeature`**: the popup-menu extender. M7.
//   * **`DynamicElement`** (`visible-*` shapes: `LedShape`, `RegisterShape`, …). The reader keeps
//     those verbatim under D8 and never builds a `CanvasObject` for them, so `paintSubcircuit`'s
//     `instanceof DynamicElement` arm has nothing to match. A custom appearance that used them
//     draws its static shapes and omits the live ones. Stated, not hidden.
//   * **The classic and FPGA default boxes.** See `DefaultAppearanceShapes`' header: the port's
//     `offsetBounds` is evolution-only for every style, so drawing the true classic box would put
//     ink outside the component's own bounds. Reported as a `LogisimFile` finding instead.

import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - The dispatch arm

extension CircuitSubcircuitFactory: InstancePaintable {

  /// `paintInstance(InstancePainter)` (`SubcircuitFactory.java:381-385`):
  ///
  /// ```java
  /// paintBase(painter, painter.getGraphics());
  /// painter.drawPorts();
  /// ```
  public func paintInstance(_ painter: InstancePainter) {
    paintBase(painter)
    painter.drawPorts()
  }

  /// `paintGhost(InstancePainter)` (`SubcircuitFactory.java:364-379`).
  ///
  /// ```java
  /// int v = fg.getRed() + fg.getGreen() + fg.getBlue();
  /// if (g instanceof Graphics2D g2d && v > 50) { …AlphaComposite.SRC_OVER, 0.5f… }
  /// paintBase(painter, g);
  /// ```
  ///
  /// The `v > 50` guard is upstream's and is kept: against a *dark* pen the ghost is drawn at
  /// full opacity, because a 50% alpha on an already-dim colour would vanish. `SceneBuilder`
  /// expresses the composite as a group opacity rather than a graphics state, which is the
  /// retained-scene equivalent; `RenderScene` groups carry an opacity and the backend applies it
  /// to the whole group, which is what `SRC_OVER` at 0.5 does to a `Graphics2D` clone.
  public func paintGhost(_ painter: InstancePainter) {
    let ink = painter.g.color
    let brightness: Int
    switch ink {
    case .rgba(let rgba): brightness = Int(rgba.r) + Int(rgba.g) + Int(rgba.b)
    // A palette colour is a simulation value, which a ghost never carries; treat it as bright so
    // the ghost is translucent, matching what the default black-on-white pen would do.
    case .palette: brightness = 255 * 3
    }

    if brightness > 50 {
      painter.g.beginGroup(tag: 0, opacity: 0.5)
      paintBase(painter)
      painter.g.endGroup()
    } else {
      paintBase(painter)
    }
  }

  /// `paintBase(InstancePainter, Graphics)` (`SubcircuitFactory.java:349-359`):
  ///
  /// ```java
  /// final var facing = attrs.getFacing();
  /// final var defaultFacing = source.getAppearance().getFacing();
  /// final var loc = painter.getLocation();
  /// g.translate(loc.getX(), loc.getY());
  /// source.getAppearance().paintSubcircuit(painter, g, facing);
  /// drawCircuitLabel(painter, getOffsetBounds(attrs), facing, defaultFacing);
  /// g.translate(-loc.getX(), -loc.getY());
  /// painter.drawLabel();
  /// ```
  ///
  /// Note the ordering that is easy to lose: `drawLabel()` is OUTSIDE the translate, because the
  /// instance label's placement is already in circuit coordinates (`configureLabel` reads
  /// `instance.getBounds()`, not the offset bounds), while `drawCircuitLabel` is INSIDE it,
  /// because it reads `getOffsetBounds`. Swapping them puts one of the two labels at twice the
  /// component's location.
  func paintBase(_ painter: InstancePainter) {
    let attributes = painter.attributeSet
    let facing = attributes[StdAttr.facing] ?? .east
    let defaultFacing = appearance.facing

    // `InstancePainter.getLocation()` (`InstancePainter.java:169-171`):
    //
    //     return comp == null ? Location.create(0, 0, false) : comp.getLocation();
    //
    // **A ghost translates by (0, 0), and that is load-bearing rather than incidental.**
    // `InstanceFactory.drawGhost` has *already* done `gfx.translate(x, y)` before calling
    // `paintGhost`, so a `paintBase` that translated again would draw every drag preview at
    // twice the cursor's offset. Upstream is safe because its `getLocation()` returns the origin
    // for a ghost; this port's `InstancePainter.location` deliberately returns the ghost's real
    // location instead (`setFactory(_:_:at:)`), so the Java behaviour has to be restored here.
    // `ToolOverlayScene.paint` is the caller that pushes that outer translate.
    let location = painter.isGhost ? Location.create(0, 0, hasToSnap: false) : painter.location

    painter.g.pushTranslate(location.x, location.y)
    paintSubcircuit(painter, facing: facing)
    drawCircuitLabel(
      painter, bounds: offsetBounds(attributes), facing: facing, defaultFacing: defaultFacing)
    painter.g.popTransform()

    drawInstanceLabel(painter)
  }

  /// `CircuitAppearance.paintSubcircuit(InstancePainter, Graphics, Direction)`
  /// (`CircuitAppearance.java:297-329`):
  ///
  /// ```java
  /// final var defaultFacing = getFacing();
  /// var rotate = 0.0D;
  /// if (facing != defaultFacing && g instanceof Graphics2D g2d) {
  ///   rotate = defaultFacing.toRadians() - facing.toRadians();
  ///   g2d.rotate(rotate);
  /// }
  /// final var offset = findAnchorLocation();
  /// g.translate(-offset.getX(), -offset.getY());
  /// for (final var shape : getObjectsFromBottom())
  ///   if (!(shape instanceof AppearanceElement)) shape.paint(g.create(), null);
  /// g.translate(offset.getX(), offset.getY());
  /// if (rotate != 0.0) g2d.rotate(-rotate);
  /// ```
  ///
  /// The rotation is about the *current origin*, which after `paintBase`'s translate is the
  /// component's location; that is why the anchor translate has to come second.
  func paintSubcircuit(_ painter: InstancePainter, facing: Direction) {
    let g = painter.g
    let defaultFacing = appearance.facing

    let rotate = (facing != defaultFacing) ? defaultFacing.toRadians() - facing.toRadians() : 0
    if rotate != 0 { g.pushRotate(rotate) }
    defer { if rotate != 0 { g.popTransform() } }

    let plan = appearancePlan(for: painter)
    // `findAnchorLocation()` returns `Location.create(0, 0)` when the appearance has no anchor
    // (`CircuitAppearance.java:252-263`), so a missing anchor means "do not translate".
    let offset = plan.anchor
    if offset.x != 0 || offset.y != 0 { g.pushTranslate(-offset.x, -offset.y) }
    defer { if offset.x != 0 || offset.y != 0 { g.popTransform() } }

    AppearanceShapePainter.paint(plan.shapes, into: g)
  }

  // MARK: - Which appearance

  /// The shape list and anchor to draw, chosen the way `CircuitAppearance.getObjectsFromBottom()`
  /// chooses:
  ///
  /// ```java
  /// public boolean isDefaultAppearance() {
  ///   return (circuit == null)
  ///       || !circuit.getStaticAttributes().getValue(APPEARANCE_ATTR).equals(APPEAR_CUSTOM);
  /// }
  /// public List<CanvasObject> getObjectsFromBottom() {
  ///   return isDefaultAppearance() ? defaultCanvasObjects : super.getObjectsFromBottom();
  /// }
  /// ```
  ///
  /// Note the polarity, which `CircuitAppearance.swift` already records for the port half:
  /// *anything other than* `custom` is a default appearance, so a `classic` circuit's `<appear>`
  /// shapes are ignored for drawing exactly as they are ignored for ports.
  ///
  /// **The custom arm depends on a seam being installed.** `CircuitAppearanceSeam.install()` is
  /// what populates `CircuitAppearanceStore`; without it the reader keeps `<appear>` verbatim
  /// (D8) and there are no `CanvasObject`s to draw. `StdLibraries.registerAll()` installs it, and
  /// an empty list here falls back to the default box rather than drawing nothing; a
  /// custom-appearance circuit rendered by a caller that skipped registration gets the default
  /// symbol, not a hole in the schematic.
  func appearancePlan(for painter: InstancePainter) -> (shapes: [AppearanceShape], anchor: Location)
  {
    if !appearance.isDefaultAppearance {
      let shapes = CircuitAppearanceSeam.shapes(for: source)
      if !shapes.isEmpty {
        var anchor = Location.create(0, 0, hasToSnap: false)
        for shape in shapes {
          if let element = shape as? AppearanceAnchor { anchor = element.location }
        }
        return (shapes, anchor)
      }
    }
    return (defaultShapes(for: painter), Location.create(0, 0, hasToSnap: false))
  }

  /// `DefaultEvolutionAppearance.build`'s drawn half, in the anchor-relative frame.
  ///
  /// Built fresh on each paint rather than cached. Upstream caches (`defaultCanvasObjects`,
  /// rebuilt from `recomputeDefaultAppearance`), but its cache has an invalidation chain this
  /// module cannot reach into; `CircuitAppearance.invalidate()` is called from
  /// `CircuitSubcircuitFactory`'s own circuit listener, in `LogisimFile`. Rebuilding costs a
  /// handful of small objects per placement per frame, against the two `Graphics2D` clones
  /// upstream makes *per component* per frame (D6's note on `Circuit.java:540`), so it is not the
  /// expensive thing on this path. Recorded as the deliberate trade it is.
  func defaultShapes(for painter: InstancePainter) -> [AppearanceShape] {
    // The box in the appearance's OWN facing. `offsetBounds(attrs)` has already rotated into the
    // instance's facing, and `paintSubcircuit` applies that same rotation to the graphics, so
    // asking for the box in the default facing is what keeps the two from compounding.
    let box = offsetBounds(defaultFacingAttributes(painter.attributeSet))

    let ports = appearance.portOffsets(facing: appearance.facing).map { entry in
      DefaultAppearanceShapes.PortPin(
        location: entry.location,
        pin: entry.pin,
        // `DefaultEvolutionAppearance.build`'s own criterion:
        // `if (pin.getAttributeValue(Pin.ATTR_TYPE) == Pin.OUTPUT) pinEdge = EAST; else WEST;`
        // Read from the pin rather than inferred from the port's x, so a hand-built circuit whose
        // pins land in unexpected places still puts each stub on the side upstream would.
        isLeftSide: Pin.isInputPin(entry.pin.attributeSet))
    }

    // `isNamedBoxShapedFixedSize()`: note the `true` default, which is NOT the attribute's own
    // default of `false`: `CircuitAppearance.java:331-337` returns `true` when the static set
    // lacks the attribute entirely.
    let isFixedSize =
      source.staticAttributes[CircuitAttributes.namedCircuitBoxFixedSize] ?? true

    return DefaultAppearanceShapes.build(
      box: box, ports: ports, circuitName: source.name, isFixedSize: isFixedSize)
  }

  /// The instance's attribute set with `StdAttr.FACING` forced to the appearance's own facing, so
  /// `offsetBounds` returns the un-rotated box.
  ///
  /// A copy, never a mutation of the live set: writing to the component's own attributes during a
  /// paint would fire listeners, recompute ports and invalidate the parent circuit: from inside
  /// a render. That is a repaint loop, not a bug you find in a unit test.
  private func defaultFacingAttributes(_ attributes: any AttributeSet) -> any AttributeSet {
    let facing = attributes[StdAttr.facing] ?? .east
    guard facing != appearance.facing else { return attributes }
    let copy = attributes.copy()
    try? copy.setValue(StdAttr.facing, appearance.facing)
    return copy
  }
}

// MARK: - The circuit's own label (`clabel`)

extension CircuitSubcircuitFactory {

  /// `drawCircuitLabel(InstancePainter, Bounds, Direction, Direction)`
  /// (`SubcircuitFactory.java:209-265`).
  ///
  /// This is the circuit-wide label, `CIRCUIT_LABEL_ATTR`, spelled `clabel` in a `.circ`, drawn
  /// in the middle of the box, rotated by `CIRCUIT_LABEL_FACING_ATTR`. It is NOT the placement's
  /// own `StdAttr.LABEL`; that one is `drawInstanceLabel` below, and upstream draws both.
  ///
  /// The escape handling is upstream's and is transcribed rather than replaced with a
  /// `split(separator:)`: the label is scanned for a literal backslash followed by `n` (a
  /// two-character sequence in the stored string, not a newline), `\\` collapses to one
  /// backslash, and any other backslash is left alone and skipped over. A `split` on `"\\n"`
  /// would mis-handle `"a\\\\nb"`, which upstream renders as one line reading `a\nb`.
  func drawCircuitLabel(
    _ painter: InstancePainter, bounds: Bounds, facing: Direction, defaultFacing: Direction
  ) {
    let staticAttributes = source.staticAttributes
    let label = staticAttributes[CircuitAttributes.circuitLabelAttribute] ?? ""
    guard !label.isEmpty else { return }

    let up = staticAttributes[CircuitAttributes.circuitLabelFacingAttribute] ?? .east
    let font = staticAttributes[CircuitAttributes.circuitLabelFontAttribute]
      ?? StdAttr.defaultLabelFont

    // ```java
    // var back = label.indexOf('\\');
    // var lines = 1; var backs = false;
    // while (back >= 0 && back <= label.length() - 2) {
    //   final var c = label.charAt(back + 1);
    //   if (c == 'n') lines++; else if (c == '\\') backs = true;
    //   back = label.indexOf('\\', back + 2);
    // }
    // ```
    var lines = 1
    var backs = false
    let units = Array(label.utf16)
    var index = units.firstIndex(of: UInt16(UInt8(ascii: "\\"))) ?? -1
    while index >= 0 && index <= units.count - 2 {
      let next = units[index + 1]
      if next == UInt16(UInt8(ascii: "n")) {
        lines += 1
      } else if next == UInt16(UInt8(ascii: "\\")) {
        backs = true
      }
      index = nextBackslash(units, from: index + 2)
    }

    let x = bounds.x + bounds.width / 2
    var y = bounds.y + bounds.height / 2

    let g = painter.g
    // `final var angle = Math.PI / 2 - (up.toRadians() - defaultFacing.toRadians()) - facing.toRadians();`
    let angle = Double.pi / 2 - (up.toRadians() - defaultFacing.toRadians()) - facing.toRadians()
    let rotated = abs(angle) > 0.01
    if rotated { g.pushRotate(angle, aroundX: x, y: y) }
    defer { if rotated { g.popTransform() } }

    let savedFont = g.font
    g.font = InstancePainter.sceneFont(font)
    defer { g.font = savedFont }

    if lines == 1 && !backs {
      g.drawCenteredText(label, x: x, y: y)
      return
    }

    // ```java
    // final var fm = g.getFontMetrics();
    // final var height = fm.getHeight();
    // y = y - (height * lines - fm.getLeading()) / 2 + fm.getAscent();
    // ```
    let metrics = g.fontMetrics()
    let height = metrics.height
    y = y - (height * lines - metrics.leading) / 2 + metrics.ascent

    var remaining = label
    var back = firstBackslash(remaining)
    while back >= 0 && back <= remaining.utf16.count - 2 {
      let c = utf16Unit(remaining, at: back + 1)
      if c == UInt16(UInt8(ascii: "n")) {
        g.drawText(
          utf16Prefix(remaining, back), x: x, y: y, halign: .center, valign: .baseline)
        y += height
        remaining = utf16Suffix(remaining, from: back + 2)
        back = firstBackslash(remaining)
      } else if c == UInt16(UInt8(ascii: "\\")) {
        // `label = label.substring(0, back) + label.substring(back + 1)`: drop ONE of the two
        // backslashes, then resume the search at `back + 1`, i.e. just past the survivor.
        remaining = utf16Prefix(remaining, back) + utf16Suffix(remaining, from: back + 1)
        back = nextBackslash(Array(remaining.utf16), from: back + 1)
      } else {
        back = nextBackslash(Array(remaining.utf16), from: back + 2)
      }
    }
    // Java's final `GraphicsUtil.drawText(g, label, ...)` outside the loop: the tail after the
    // last `\n`, which is `label` there because the loop reassigns it.
    g.drawText(remaining, x: x, y: y, halign: .center, valign: .baseline)
  }

  /// `InstanceComponent.drawLabel()` for a factory that is not an `InstanceFactory`.
  ///
  /// **Why this is not `painter.drawLabel()`.** That method resolves the placement through
  /// `painter.factory as? InstanceLabelProvider`, and `painter.factory` is
  /// `component.factory as? any InstanceFactory`, which is `nil` here, because
  /// `CircuitSubcircuitFactory` descends from `AbstractComponentFactory` (in `LogisimFile`) and
  /// `InstanceFactory` is a `LogisimStd` protocol it does not conform to. Calling
  /// `painter.drawLabel()` compiles, runs, and silently draws nothing; precisely the failure
  /// class this ticket is about, arriving one layer down.
  ///
  /// The body is `InstancePainter.drawLabel`'s, with the placement taken from `labelPlacement`
  /// directly. The conformance to `InstanceLabelProvider` below is still declared, so that if the
  /// factory ever becomes an `InstanceFactory` the generic path takes over and this becomes
  /// redundant rather than wrong.
  func drawInstanceLabel(_ painter: InstancePainter) {
    // `InstancePainter.drawLabel()` is `if (comp instanceof InstanceComponent c) c.drawLabel(...)`
    // : a no-op for a ghost, because a ghost has no component and therefore no label. Without
    // this guard `labelPlacement` would run on `painter.bounds`, which for a ghost of a factory
    // that is not an `InstanceFactory` is `Bounds.empty`, and the label would be drawn at (0, 0).
    guard !painter.isGhost else { return }
    guard let placement = labelPlacement(painter) else { return }
    guard painter.attributeValue(StdAttr.labelVisibility, default: true) else { return }
    let text = painter.attributeValue(StdAttr.label, default: "")
    guard !text.isEmpty else { return }

    let g = painter.g
    let savedColor = g.color
    let savedFont = g.font
    defer {
      g.color = savedColor
      g.font = savedFont
    }

    g.font = InstancePainter.sceneFont(
      painter.attributeValue(StdAttr.labelFont, default: StdAttr.defaultLabelFont))
    if !painter.isPrintView {
      let spec = painter.attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor)
      g.color = .rgba(RGBA(r: spec.red, g: spec.green, b: spec.blue))
    }
    g.drawText(
      text, x: placement.x, y: placement.y, halign: placement.halign, valign: placement.valign)
  }

  // MARK: UTF-16 helpers
  //
  // Java's `indexOf`/`substring`/`charAt` are all UTF-16 code-unit operations. A label containing
  // an emoji would make a `Character`-based transcription disagree about every index after it, so
  // the arithmetic is done in `utf16` and converted back once. Every conversion is bounds-checked
  // and returns the original string on failure; D13: a `.circ` label is untrusted input and must
  // not be able to trap.

  private func firstBackslash(_ text: String) -> Int {
    nextBackslash(Array(text.utf16), from: 0)
  }

  private func nextBackslash(_ units: [UInt16], from start: Int) -> Int {
    guard start >= 0, start < units.count else { return -1 }
    let backslash = UInt16(UInt8(ascii: "\\"))
    for index in start..<units.count where units[index] == backslash { return index }
    return -1
  }

  private func utf16Unit(_ text: String, at offset: Int) -> UInt16 {
    let units = Array(text.utf16)
    guard offset >= 0, offset < units.count else { return 0 }
    return units[offset]
  }

  /// `text.substring(0, offset)`.
  private func utf16Prefix(_ text: String, _ offset: Int) -> String {
    guard offset >= 0 else { return "" }
    guard
      let end = text.utf16.index(text.utf16.startIndex, offsetBy: offset, limitedBy: text.utf16.endIndex),
      let scalar = String.Index(end, within: text)
    else { return text }
    return String(text[text.startIndex..<scalar])
  }

  /// `text.substring(offset)`.
  private func utf16Suffix(_ text: String, from offset: Int) -> String {
    guard offset >= 0 else { return text }
    guard
      let start = text.utf16.index(text.utf16.startIndex, offsetBy: offset, limitedBy: text.utf16.endIndex),
      let scalar = String.Index(start, within: text)
    else { return "" }
    return String(text[scalar...])
  }
}

// MARK: - configureLabel

extension CircuitSubcircuitFactory: InstanceLabelProvider {

  /// `configureLabel(Instance)` (`SubcircuitFactory.java:145-167`):
  ///
  /// ```java
  /// final var bds = instance.getBounds();
  /// final var loc = instance.getAttributeValue(CircuitAttributes.LABEL_LOCATION_ATTR);
  /// var x = bds.getX() + bds.getWidth() / 2;
  /// var y = bds.getY() + bds.getHeight() / 2;
  /// var ha = GraphicsUtil.H_CENTER;
  /// var va = GraphicsUtil.V_CENTER;
  /// if (loc == Direction.EAST)       { x = bds.getX() + bds.getWidth() + 2; ha = H_LEFT; }
  /// else if (loc == Direction.WEST)  { x = bds.getX() - 2; ha = H_RIGHT; }
  /// else if (loc == Direction.SOUTH) { y = bds.getY() + bds.getHeight() + 2; va = V_TOP; }
  /// else                             { y = bds.getY() - 2; va = V_BASELINE; }
  /// instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, x, y, ha, va);
  /// ```
  ///
  /// Three things about that cascade are load-bearing and were taken from the Java rather than
  /// eyeballed:
  ///
  ///   * **The final `else` is NORTH *and* everything else.** There is no `if (loc == NORTH)`; a
  ///     `LABEL_LOCATION_ATTR` the option list does not recognise gets the north placement, not
  ///     the centred default the first two lines set up. Those two lines are only reachable if
  ///     the cascade is never entered, which it always is.
  ///   * **The bounds are the INSTANCE's**, i.e. already translated to the component's location
  ///     and already rotated by facing, so the returned placement is in circuit coordinates, and
  ///     `paintBase` must draw it *outside* its translate.
  ///   * **`±2`, not a font-derived gap.** Upstream's margin is two pixels flat on all four
  ///     sides.
  ///
  /// `LabelPlacement` replaces `setTextField` because `StdInstanceComponent` has no text field;
  /// the placement is recomputed on demand, which is sound for the same reason upstream has to
  /// re-run `configureLabel` from `instanceAttributeChanged`; it is a pure function of the
  /// bounds and one attribute.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bounds = painter.bounds
    let location = painter.attributeSet[CircuitAttributes.labelLocationAttribute]

    var x = bounds.x + bounds.width / 2
    var y = bounds.y + bounds.height / 2
    var halign = HAlign.center
    var valign = VAlign.center

    if location == .east {
      x = bounds.x + bounds.width + 2
      halign = .left
    } else if location == .west {
      x = bounds.x - 2
      halign = .right
    } else if location == .south {
      y = bounds.y + bounds.height + 2
      valign = .top
    } else {
      y = bounds.y - 2
      valign = .baseline
    }

    return LabelPlacement(x: x, y: y, halign: halign, valign: valign)
  }
}
