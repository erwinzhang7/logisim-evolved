// ToolOverlayScene.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the `draw(Canvas, ComponentDrawContext)` bodies of
// com.cburch.logisim.tools.{WiringTool, EditTool, SelectTool, AddTool, PokeTool},
// com.cburch.logisim.gui.main.Selection.drawGhostsShifted and
// com.cburch.logisim.comp.AbstractComponentFactory.drawGhost),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// `Tool.swift` deleted `draw(Canvas, ComponentDrawContext)` on D6 grounds, a tool is no more
// entitled to a `Graphics` than a component is, and replaced it with a closed `ToolOverlayItem`
// enum: a tool *describes* what it wants on screen and the render surface draws it. **Nothing
// drew it.** `ToolOverlayItem` had ten cases, `ToolCanvas.setToolOverlay` was called from three
// places in `CanvasToolController`, and no implementation of that method existed anywhere,
// because `ToolCanvas` had no conformer at all.
//
// This is the missing half. It is a **pure function**, `ToolOverlay` in, `RenderScene` out,
// deliberately, for two reasons:
//
//   1. D6. The overlay goes through `SceneBuilder` like everything else, so the same geometry
//      renders to a window, to an offscreen bitmap, and to a primitive count in a test.
//   2. It is the only way this seam can be *measured*. "The overlay is wired" and "the overlay
//      draws nothing" are indistinguishable through an `NSView`; they are one integer apart
//      through `RenderScene.primitives.count`.
//
// The overlay scene is built **separately from the circuit scene** and on a different schedule.
// `CircuitSceneGeometryKey` rebuilds the circuit only when the circuit changes; an overlay moves
// on every mouse event. Merging them would defeat the split that `SpatialIndex` and
// `RenderScene.colorSlots` exist for; the same reasoning `InstancePokerPainting.swift`'s header
// gives for keeping a poke highlight in its own builder. For the same reason the poke highlight
// is kept as a *third* scene rather than spliced into this one: `RenderScene` interns points,
// transforms and colour slots by index, so two scenes cannot be concatenated without remapping
// every index, and the correct place for a multi-scene frame is one more draw call in the
// backend, which `CircuitSceneView` now makes.
//
// ── Ghosts, and Java's fallback that this port lost ─────────────────────────────────────────
//
// `InstanceFactory.drawGhost` (`InstanceFactory.java:257-268`) sets the painter into ghost mode,
// calls `paintGhost`, and then, if `painter.getFactory() == null`, falls through to
// `AbstractComponentFactory.drawGhost`, which strokes the plain offset-bounds rectangle at
// width 2. The sentinel works upstream because Java's *default* `paintGhost` body is literally
// `painter.setFactory(null, null)`.
//
// This port's default `paintGhost` is `{}` (`InstancePainter.swift:723-731`), which is
// behaviourally right for "draw nothing" and destroys the sentinel: nothing ever clears the
// factory, so the fallback rectangle is unreachable and every component without its own ghost
// would drag invisibly. Rather than push a change into `LogisimStd`, the fallback is decided
// here on the observable question the sentinel was a proxy for, *did anything get drawn?*, by
// painting into a scratch builder first and asking whether it emitted a primitive.
// `ghostsFellBackToBounds` counts how often that happens, so the divergence is a number rather
// than a belief.
//
// The two ghost entry points guard on `InstancePaintable`, **not** on `InstanceFactory`. That is
// deliberate and is the difference between a subcircuit previewing as its symbol and previewing
// as an empty rectangle: see `paintFactoryGhost`'s doc comment and
// `docs/experiments/subcircuit-paint.md` §6.3.

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

/// Turns what the active tool wants drawn into scenes the canvas can paint.
enum ToolOverlaySceneBuilder {

  /// Group tag for the whole overlay layer.
  ///
  /// `CircuitRenderer` gives components `1...n` and the wire layer `UInt64.max`;
  /// `PokeOverlayRenderer` took `UInt64.max - 1`. This takes the next one down so all four
  /// layers stay distinguishable if they are ever emitted into one builder.
  static let overlayGroupTag: UInt64 = UInt64.max - 2

  /// What came out, in numbers a test can assert on.
  struct Result {
    /// The `ToolOverlayItem`s.
    var itemScene: RenderScene = .empty
    /// `ToolOverlay.scene`: the poke highlight, carried whole. Kept separate; see the header.
    var pokeScene: RenderScene?
    /// Items that produced at least one primitive. Deliberately not `overlay.items.count`: an
    /// item that is asked to draw and draws nothing is the failure this file exists to expose.
    var itemsDrawn = 0
    /// Ghosts painted through a factory's own `paintGhost`.
    var ghostsPainted = 0
    /// Ghosts that fell back to the offset-bounds rectangle, see the header.
    var ghostsFellBackToBounds = 0

    /// Every primitive the canvas will draw for this overlay, across both scenes.
    var primitiveCount: Int {
      itemScene.primitives.count + (pokeScene?.primitives.count ?? 0)
    }

    var isEmpty: Bool { primitiveCount == 0 }
  }

  /// `selectionComponents` is what `ToolOverlayItem.selectionGhost(dx:dy:)` is missing: the case
  /// carries only the drag delta, because the components live in the canvas's `Selection` and a
  /// closed `Hashable` enum cannot carry them. `Selection.drawGhostsShifted(context, dx, dy)`
  /// iterates `unionSet`, so the canvas passes `selection.components` and the geometry matches.
  @MainActor
  static func build(
    _ overlay: ToolOverlay,
    selectionComponents: [any Component],
    appearance: CanvasAppearance
  ) -> Result {
    var result = Result()
    result.pokeScene = overlay.scene.flatMap { $0.isEmpty ? nil : $0 }
    guard !overlay.items.isEmpty else { return result }

    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    let context = CircuitSceneSource.paintContext(for: appearance)
    let palette = appearance.palette

    // `AppPreferences.COMPONENT_GHOST_COLOR` is a frozen 0x555555 upstream. Resolved from the
    // chrome palette instead, so a dark canvas gets a light ghost; the same #2661 argument the
    // rest of the palette makes.
    let ghostInk = palette[.componentStroke].opacity(0.55).sceneRGBA
    let ink = palette[.componentStroke].sceneRGBA
    let grey = palette[.componentStroke].opacity(0.45).sceneRGBA
    let marqueeStroke = palette[.marqueeStroke].sceneRGBA
    let marqueeFill = palette[.marqueeFill].sceneRGBA
    // `SelectTool.COLOR_UNMATCHED` is `new Color(192, 0, 0)`.
    let unmatched = LogisimRender.RGBA(r: 192, g: 0, b: 0)

    builder.beginGroup(tag: overlayGroupTag, opacity: 1.0)

    for item in overlay.items {
      var drew = false
      switch item {

      // `WiringTool.draw`; the two `drawLine` calls at width 3.
      case let .pendingWire(start, elbow, end):
        builder.color = .rgba(ink)
        builder.strokeWidth = 3
        if let elbow {
          if elbow != start {
            builder.drawLine(from: start, to: elbow)
            drew = true
          }
          if elbow != end {
            builder.drawLine(from: elbow, to: end)
            drew = true
          }
        } else if start != end {
          builder.drawLine(from: start, to: end)
          drew = true
        }

      // `WiringTool.draw`'s `ADD_SHOW_GHOSTS` dot: `fillOval(x - 2, y - 2, 5, 5)` in grey.
      case let .cursorDot(location):
        builder.color = .rgba(grey)
        builder.strokeWidth = 1
        builder.fillOval(location.x - 2, location.y - 2, 5, 5)
        drew = true

      // `EditTool.draw`: `drawOval(x - 5, y - 5, 10, 10)` at width 2 in `Value.trueColor`.
      case let .wiringPointIndicator(location):
        builder.color = .palette(.trueValue)
        builder.strokeWidth = 2
        builder.drawOval(location.x - 5, location.y - 5, 10, 10)
        drew = true

      // `SelectTool.draw`'s RECT_SELECT arm: a filled interior inset by one, then the outline at
      // width 2. The inset is upstream's, and is why a 1-unit marquee shows only its border.
      case let .marquee(bounds):
        let w = bounds.width
        let h = bounds.height
        if w > 2 && h > 2 {
          builder.color = .rgba(marqueeFill)
          builder.fillRect(bounds.x + 1, bounds.y + 1, w - 1, h - 1)
        }
        builder.color = .rgba(marqueeStroke)
        builder.strokeWidth = 2
        builder.drawRect(bounds.x, bounds.y, max(w, 0), max(h, 0))
        drew = true

      // `SelectTool.draw`: `factory.drawGhost(context, COLOR_RECT_SELECT, x, y, attrs)` for
      // everything the rectangle currently crosses.
      case let .marqueeGhost(component):
        let ghost = drawGhost(
          component.component, dx: 0, dy: 0, ink: marqueeStroke,
          into: builder, context: context)
        tally(ghost, into: &result)
        drew = true

      // `Selection.drawGhostsShifted(context, dx, dy)`.
      case let .selectionGhost(dx, dy):
        for component in selectionComponents {
          let ghost = drawGhost(
            component, dx: dx, dy: dy, ink: ghostInk, into: builder, context: context)
          tally(ghost, into: &result)
          drew = true
        }

      // `SelectTool.draw`: the move engine's proposed wires, grey at width 3.
      case let .proposedWire(start, end):
        builder.color = .rgba(grey)
        builder.strokeWidth = 3
        builder.drawLine(from: start, to: end)
        drew = true

      // `SelectTool.draw`: `COLOR_UNMATCHED`, drawn at BOTH the old and the shifted position.
      case let .unsatisfiedConnection(location, dx, dy):
        builder.color = .rgba(unmatched)
        builder.strokeWidth = 1
        builder.fillOval(location.x - 3, location.y - 3, 6, 6)
        builder.fillOval(location.x &+ dx - 3, location.y &+ dy - 3, 6, 6)
        drew = true

      // `AddTool.draw`: `SHOW_GHOST` (grey) versus `SHOW_ADD` (ink), with the auto-labeller
      // tint on top. There is no component yet, so this is always the factory ghost path.
      case let .placementGhost(factory, at, isCommitted, needsLabel):
        let colour: LogisimRender.RGBA =
          needsLabel
          ? LogisimRender.RGBA(r: 255, g: 0, b: 255)
          : (isCommitted ? ink : ghostInk)
        let ghost = drawFactoryGhost(
          factory.factory, at: at, ink: colour, into: builder, context: context)
        tally(ghost, into: &result)
        drew = true

      // `PokeTool.WireCaret.draw`; the value callout. Upstream is fifty lines of polygon
      // arithmetic that flips the balloon above or below the cursor depending on how close it is
      // to the viewport edge; the caret reports *what* and *where* and this decides how, as
      // `WireCaret`'s doc comment says it should. Flipping at the viewport edge needs the
      // camera, which `ToolCanvas` deliberately does not carry, so the callout always sits above
      // and right of the point. Stated, bounded divergence.
      case let .valueCallout(at, text):
        // Qualified: `LogisimStd/Io/IoPainter.swift` adds a same-named extension member to a
        // protocol `SceneBuilder` also satisfies, so the bare call is ambiguous.
        let width = (builder as SceneBuilder).textBounds(text, x: 0, y: 0).width + 8
        let boxX = at.x + 6
        let boxY = at.y - 18
        builder.color = .rgba(LogisimRender.RGBA(r: 255, g: 255, b: 190))
        builder.fillRect(boxX, boxY, width, 16)
        builder.color = .rgba(ink)
        builder.strokeWidth = 1
        builder.drawRect(boxX, boxY, width, 16)
        _ = builder.drawString(text, x: boxX + 4, y: boxY + 12)
        drew = true
      }

      if drew { result.itemsDrawn += 1 }
    }

    builder.endGroup()
    result.itemScene = builder.finish()
    return result
  }

  // MARK: - Ghosts

  private struct GhostOutcome {
    var painted = false
    var fellBack = false
  }

  private static func tally(_ outcome: GhostOutcome, into result: inout Result) {
    if outcome.painted { result.ghostsPainted += 1 }
    if outcome.fellBack { result.ghostsFellBackToBounds += 1 }
  }

  /// `comp.getFactory().drawGhost(context, colour, x + dx, y + dy, comp.getAttributeSet())`.
  @MainActor
  private static func drawGhost(
    _ component: any Component, dx: Int, dy: Int, ink: LogisimRender.RGBA,
    into builder: SceneBuilder, context: any PaintContext
  ) -> GhostOutcome {
    // A `Wire`'s factory ghost upstream is `AbstractComponentFactory`'s, and a wire's offset
    // bounds are the line itself, so the rectangle degenerates to the segment. Drawn directly:
    // stroking the degenerate rect would emit a zero-area shape some backends drop.
    if let wire = component as? Wire {
      builder.color = .rgba(ink)
      builder.strokeWidth = 2
      builder.drawLine(
        wire.end0.x &+ dx, wire.end0.y &+ dy, wire.end1.x &+ dx, wire.end1.y &+ dy)
      return GhostOutcome(painted: true, fellBack: false)
    }

    let location = component.location
    let shifted = Location.create(location.x &+ dx, location.y &+ dy, hasToSnap: false)
    let factory = component.factory
    guard let paintable = factory as? any InstancePaintable else {
      // A D8 placeholder, or a factory with no ghost implementation. Upstream still strokes the
      // offset box, and so does this: a component the port cannot draw must still drag visibly.
      strokeOffsetBounds(component.bounds.translate(dx, dy), ink: ink, into: builder)
      return GhostOutcome(painted: false, fellBack: true)
    }
    return paintFactoryGhost(
      paintable, instanceFactory: factory as? any InstanceFactory,
      attributes: component.attributeSet, at: shifted,
      offsetBounds: component.bounds.translate(dx, dy),
      ink: ink, into: builder, context: context)
  }

  /// `AddTool`'s pending placement, which has no component yet.
  @MainActor
  private static func drawFactoryGhost(
    _ factory: any ComponentFactory, at location: Location, ink: LogisimRender.RGBA,
    into builder: SceneBuilder, context: any PaintContext
  ) -> GhostOutcome {
    let attributes = factory.createAttributeSet()
    let offset = factory.offsetBounds(attributes)
    let box = Bounds.create(
      location.x &+ offset.x, location.y &+ offset.y, offset.width, offset.height)
    guard let paintable = factory as? any InstancePaintable else {
      strokeOffsetBounds(box, ink: ink, into: builder)
      return GhostOutcome(painted: false, fellBack: true)
    }
    return paintFactoryGhost(
      paintable, instanceFactory: factory as? any InstanceFactory,
      attributes: attributes, at: location, offsetBounds: box,
      ink: ink, into: builder, context: context)
  }

  /// The shared body, including the "did anything draw?" probe the header explains.
  ///
  /// **`instanceFactory` is optional, and that is the whole reach to a subcircuit.** Both callers
  /// used to guard on `factory as? any InstanceFactory` *before* they would paint anything, and
  /// `CircuitSubcircuitFactory` descends from `AbstractComponentFactory` in `LogisimFile`, so
  /// the cast failed and every subcircuit drag, from the explorer and across the canvas, fell
  /// back to `strokeOffsetBounds`: a bare rectangle where upstream previews the symbol, its
  /// ports and its name. (Upstream has no such split; its `SubcircuitFactory extends
  /// InstanceFactory`.) `paintGhost` needs only `InstancePaintable`, and
  /// `InstancePainter.setFactory` already takes an optional factory, so the guard moved to the
  /// protocol that is actually required and the concrete type is passed through when there is
  /// one. Recorded in `docs/experiments/subcircuit-paint.md` §6.3; measured by
  /// `SubcircuitGhostReachTests`, which counts primitives out of a real pointer gesture.
  ///
  /// What a `nil` factory costs: `InstancePainter.bounds` and `.offsetBounds` fall to
  /// `Bounds.empty` for a ghost, because both read `ghostFactory.offsetBounds`. Bounded rather
  /// than assumed; `CircuitSubcircuitFactory` is the only `InstancePaintable` in the port that
  /// is not an `InstanceFactory`, and its `paintBase` reads its own `offsetBounds(_:)` and never
  /// the painter's. Any future non-`InstanceFactory` paintable that reads `painter.bounds` in a
  /// ghost needs that hole closed in `LogisimStd` first.
  @MainActor
  private static func paintFactoryGhost(
    _ paintable: any InstancePaintable, instanceFactory: (any InstanceFactory)?,
    attributes: any AttributeSet, at location: Location,
    offsetBounds: Bounds, ink: LogisimRender.RGBA,
    into builder: SceneBuilder, context: any PaintContext
  ) -> GhostOutcome {
    // The probe. `paintGhost` is pure drawing, so running it twice is safe; the second run is
    // the one that lands in the frame.
    let scratch = SceneBuilder(measurer: CoreTextMeasurer())
    paint(
      paintable, instanceFactory, attributes, at: location, ink: ink, into: scratch,
      context: context)
    if scratch.finish().isEmpty {
      strokeOffsetBounds(offsetBounds, ink: ink, into: builder)
      return GhostOutcome(painted: false, fellBack: true)
    }

    paint(
      paintable, instanceFactory, attributes, at: location, ink: ink, into: builder,
      context: context)
    return GhostOutcome(painted: true, fellBack: false)
  }

  /// **The ghost's anchor, and the one number that must not be applied twice.**
  ///
  /// A ghost paints in *offset* coordinates and the caller positions it, exactly once, with the
  /// translate below. `InstanceFactory.drawGhost` (4.1.0, `javap -c` on
  /// `logisim-evolution-4.1.0-all.jar`) is
  ///
  ///     g.setColor(color); g.translate(x, y); painter.setFactory(this, attrs);
  ///     paintGhost(painter); g.translate(-x, -y);
  ///     if (painter.getFactory() == null) super.drawGhost(...);
  ///
  /// ; note that `setFactory` takes **no location**, and `InstancePainter.getLocation()` is
  /// `comp == null ? Location.create(0, 0, false) : comp.getLocation()`. During `paintGhost`
  /// upstream's painter therefore reports the ORIGIN, and every painter that positions itself
  /// from `getLocation()` contributes a translate of zero.
  ///
  /// This port's `InstancePainter.setFactory(_:_:at:)` can carry a real ghost location, and this
  /// call used to pass one. That made `painter.location` answer the ghost's true position while
  /// the outer translate was still applied, so every ghost whose painter positions itself from
  /// `painter.location`, `AbstractGate.paintBase` (all the gates), `NotGate`, `Buffer`, `Pin`,
  /// `Clock`, `Probe`, the TTL chips, landed at `2 * location + offsetBounds`. Measured through
  /// the real canvas: an `AndGate` at (200,150) dragged +30/+20 painted its ghost at
  /// x 408...462 / y 312...368 while the component dropped at x 180...230 / y 145...195: out by
  /// (228, 167), which is the component's own post-drop location less the pen overhang. Ghosts
  /// that read `painter.bounds` instead (`Led`, the io family; `bounds` is the *offset* box for
  /// a ghost, upstream and here) were unaffected, so the canvas showed some previews in the right
  /// place and some a whole component-position away. `SubcircuitPainter.paintBase` had already
  /// hard-coded the compensation locally and its comment predicted this for everyone else.
  ///
  /// So the location is deliberately NOT passed on: it stays the parameter of the translate and
  /// nothing else, which is upstream's arrangement exactly. `DragGhostAnchorTests` gates it at
  /// two zooms, three painters, and both grab positions.
  @MainActor
  private static func paint(
    _ paintable: any InstancePaintable, _ factory: (any InstanceFactory)?,
    _ attributes: any AttributeSet, at location: Location, ink: LogisimRender.RGBA,
    into builder: SceneBuilder, context: any PaintContext
  ) {
    let painter = InstancePainter(g: builder, context: context)
    painter.setFactory(factory, attributes)
    builder.color = .rgba(ink)
    // `gfx.translate(x, y)` / `gfx.translate(-x, -y)` around the call, exactly as
    // `InstanceFactory.drawGhost` does; a ghost paints in offset coordinates.
    builder.pushTranslate(location.x, location.y)
    paintable.paintGhost(painter)
    builder.popTransform()
  }

  /// `AbstractComponentFactory.drawGhost`, `switchToWidth(g, 2); drawRect(...)`.
  private static func strokeOffsetBounds(
    _ bounds: Bounds, ink: LogisimRender.RGBA, into builder: SceneBuilder
  ) {
    guard bounds.width > 0 || bounds.height > 0 else { return }
    builder.color = .rgba(ink)
    builder.strokeWidth = 2
    builder.drawRect(bounds.x, bounds.y, bounds.width, bounds.height)
  }
}
