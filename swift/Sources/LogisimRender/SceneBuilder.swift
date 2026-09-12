// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The emitter. THIS IS THE API EVERY `paintInstance` PORT IS WRITTEN AGAINST (D6): 75 of them across 65
// files.
//
// It is shaped to read like the `java.awt.Graphics` / `ComponentDrawContext` pair the ported
// code is being translated from, the same current-colour / current-stroke-width / current-
// font statefulness, the same method names, the same integer arguments, so a port is a
// transliteration rather than a redesign. What it is *not* is a drawing context: nothing here
// rasterises, and there is no way to reach a `CGContext` from a component.
//
// A `final class` rather than a struct on purpose. `paintInstance(_ painter:)` is called
// deep in component code that hands the painter to helpers and superclasses; threading an
// `inout SceneBuilder` through all of that at 109 sites would be pure friction for no gain,
// since the *output*, `RenderScene`, is an immutable `Sendable` value either way.

import Foundation
import LogisimKernel

public final class SceneBuilder {

  // MARK: Output pools

  private var primitives: [ScenePrimitive] = []
  private var points: [ScenePoint] = []
  private var pathOps: [PathOp] = []
  private var texts: [TextRun] = []
  private var images: [SceneImageRef] = []
  private var transforms: [SceneTransform] = [.identity]
  private var transformLookup: [SceneTransform: UInt16] = [:]
  private var groups: [SceneGroup] = []
  private var palette = ScenePalette()
  private var colorSlots: [PaletteIndex] = []
  private var staticSlotLookup: [PaletteIndex: ColorSlot] = [:]
  private var dynamicSlots: Set<ColorSlot> = []

  // MARK: Graphics state (mirrors java.awt.Graphics)

  /// Current pen colour: `g.setColor`. Assigning interns a static slot.
  public var color: SceneColor = .black {
    didSet { currentSlot = internStatic(color) }
  }

  /// Current pen: `g.setStroke`. Cap/join/dash default to `BasicStroke(float)`'s, so a
  /// `switchToWidth` port only has to set `strokeWidth`.
  public var pen: StrokePen = .default

  /// Current pen width; `GraphicsUtil.switchToWidth`. Java's `BasicStroke(float)` implies
  /// `CAP_SQUARE` and `JOIN_MITER`; the backend applies those, so a port only carries the width.
  public var strokeWidth: Int {
    get { Int(pen.width) }
    set { pen.width = UInt8(max(0, min(255, newValue))) }
  }

  /// Current font, `g.setFont`.
  public var font: SceneFont = .default

  /// Bucket size for the spatial index built at `finish()`.
  public var indexCellSize: Int32 = SpatialIndex.defaultCellSize

  private var currentSlot: ColorSlot
  private let measurer: TextMeasurer

  // MARK: Transform stack

  private struct TransformState {
    var dx: Int
    var dy: Int
    var index: UInt16
  }

  private var transformStack: [TransformState] = []
  private var current = TransformState(dx: 0, dy: 0, index: 0)

  // MARK: Group state

  /// One entry per `beginGroup` still open, outermost first.
  ///
  /// A stack, not a single open group: `SubcircuitFactory.paintGhost` wraps a whole subcircuit
  /// , which paints its own children as groups, in one `AlphaComposite(SRC_OVER, 0.5f)`. A
  /// builder that can only hold one open group destroys the outer one the moment the first
  /// child opens, taking the ghost's alpha and its hit-test tag with it.
  private struct GroupFrame {
    /// Caller identity, for hit testing.
    var tag: UInt64
    /// Alpha already composed with every enclosing frame. `AlphaComposite` nests
    /// multiplicatively: 0.5 inside 0.5 covers the background 75%, not 50%.
    var alpha: Double
    /// Index reserved in `groups` for this frame's identity entry. Reserved at open time so
    /// the array stays in painter's order: a frame is painted *under* everything inside it.
    var slot: Int
    /// First primitive of the frame's whole extent, children included.
    var origin: Int
    /// First primitive of the run currently accumulating (a child group splits a frame's own
    /// primitives into several runs).
    var runStart: Int
    /// Union of the run currently accumulating.
    var runBounds: SceneBounds
    /// Union of everything under the frame, children included.
    var totalBounds: SceneBounds
    /// Set once a child group has opened inside this frame.
    var hasChildren: Bool
    /// `false` for the implicit frame that catches primitives emitted outside any `beginGroup`.
    var explicit: Bool
  }

  private var groupStack: [GroupFrame] = []

  // MARK: Init

  public init(measurer: TextMeasurer) {
    self.measurer = measurer
    self.currentSlot = ColorSlot(rawValue: 0)
    // Slot 0 is always opaque black; the colour a component gets if it never sets one, and
    // the same default `Graphics` has.
    self.currentSlot = internStatic(.black)
  }

  // MARK: - Colour slots

  private func internStatic(_ color: SceneColor) -> ColorSlot {
    let index = palette.intern(color)
    if let hit = staticSlotLookup[index] { return hit }
    let slot = ColorSlot(rawValue: UInt32(colorSlots.count))
    colorSlots.append(index)
    staticSlotLookup[index] = slot
    return slot
  }

  /// Allocates a slot the caller intends to rewrite every frame.
  ///
  /// This is the mechanism that makes per-instance colour cost one `UInt16` write. A wire,
  /// pin marker, or gate input stub reserves one slot at build time, emits its geometry
  /// against it, and the simulation loop then does
  /// `scene.setColor(slot, to: value.paletteIndex)`; no geometry is rebuilt, no primitive is
  /// touched, and the scene stays valid for a Metal backend that has the vertex buffers
  /// resident on the GPU.
  public func reserveColorSlot(initial: SceneColor = .palette(.nilValue)) -> ColorSlot {
    let slot = ColorSlot(rawValue: UInt32(colorSlots.count))
    colorSlots.append(palette.intern(initial))
    dynamicSlots.insert(slot)
    return slot
  }

  /// Points the pen at an already-allocated slot (typically one from `reserveColorSlot`).
  public func useColorSlot(_ slot: ColorSlot) {
    currentSlot = slot
  }

  /// Runs `body` with the pen colour temporarily set, then restores it. Replaces the
  /// `final var oldColor = g.getColor(); ...; g.setColor(oldColor)` idiom that appears
  /// throughout the painters.
  public func withColor(_ color: SceneColor, _ body: () -> Void) {
    let saved = currentSlot
    let savedColor = self.color
    self.color = color
    body()
    self.color = savedColor
    currentSlot = saved
  }

  public func withColorSlot(_ slot: ColorSlot, _ body: () -> Void) {
    let saved = currentSlot
    currentSlot = slot
    body()
    currentSlot = saved
  }

  /// Runs `body` at a temporary pen width, `GraphicsUtil.switchToWidth` bracketed.
  public func withStrokeWidth(_ width: Int, _ body: () -> Void) {
    let saved = pen
    strokeWidth = width
    body()
    pen = saved
  }

  /// Runs `body` with a whole pen temporarily installed, `g.setStroke(s)` bracketed.
  public func withPen(_ newPen: StrokePen, _ body: () -> Void) {
    let saved = pen
    pen = newPen
    body()
    pen = saved
  }

  // MARK: - Transforms

  /// `g.translate(dx, dy)`. Free: baked into the emitted integer coordinates, so it never
  /// allocates a transform and never leaves the exact-integer path.
  public func pushTranslate(_ dx: Int, _ dy: Int) {
    transformStack.append(current)
    current.dx += dx
    current.dy += dy
  }

  /// A general affine transform: `g.rotate`, `g.scale`, or a composition.
  ///
  /// Composes with whatever translation is in effect. Allocates (and deduplicates) a pool
  /// entry, and the backend applies it as a CTM, exactly as Java2D does, so rotated gates and
  /// the 0.7-scaled radix glyph land where the reference puts them.
  public func pushTransform(_ transform: SceneTransform) {
    transformStack.append(current)
    let base = transforms[Int(current.index)]
    let withTranslation = SceneTransform
      .translation(Double(current.dx), Double(current.dy))
      .concatenating(base)
    let combined = transform.concatenating(withTranslation)
    current = TransformState(dx: 0, dy: 0, index: internTransform(combined))
  }

  /// `g.rotate(theta)` about the current origin.
  public func pushRotate(_ radians: Double) {
    pushTransform(.rotation(radians))
  }

  /// `g.rotate(theta, x, y)`.
  public func pushRotate(_ radians: Double, aroundX x: Int, y: Int) {
    pushTransform(.rotation(radians, aroundX: Double(x), y: Double(y)))
  }

  /// `g.scale(sx, sy)`.
  public func pushScale(_ sx: Double, _ sy: Double) {
    pushTransform(.scale(sx, sy))
  }

  public func popTransform() {
    guard let restored = transformStack.popLast() else { return }
    current = restored
  }

  /// Scoped form; prefer it, since the painters' `rotate(t) ... rotate(-t)` pairs are exactly
  /// the sort of thing an early `return` silently unbalances.
  public func withTranslate(_ dx: Int, _ dy: Int, _ body: () -> Void) {
    pushTranslate(dx, dy)
    body()
    popTransform()
  }

  public func withTransform(_ transform: SceneTransform, _ body: () -> Void) {
    pushTransform(transform)
    body()
    popTransform()
  }

  private func internTransform(_ t: SceneTransform) -> UInt16 {
    if t.isIdentity { return 0 }
    if let hit = transformLookup[t] { return hit }
    guard transforms.count < Int(UInt16.max) else { return 0 }
    let idx = UInt16(transforms.count)
    transforms.append(t)
    transformLookup[t] = idx
    return idx
  }

  // MARK: - Groups

  /// Opens a culling group. One per component, one per wire.
  ///
  /// `tag` is caller-defined identity; pass
  /// `UInt64(UInt(bitPattern: ObjectIdentifier(component)))` to make a hit test resolvable
  /// back to a component without a second index (D4; identity is reference identity).
  /// `opacity` is the group's `AlphaComposite` alpha, 1 = opaque. The subcircuit ghost passes
  /// 0.5, matching `SubcircuitFactory.java:372`.
  ///
  /// **Groups nest.** An inner group does not end an outer one; it splits it. The inner
  /// group's effective alpha is its own times every enclosing group's, exactly as nesting two
  /// `AlphaComposite`s does, and both tags stay resolvable by `hitTest`.
  public func beginGroup(tag: UInt64 = 0, opacity: Double = 1) {
    // An implicit frame is only ever the lone bottom frame, and it is not a parent: stray
    // chrome drawn before the first component must not swallow that component.
    if let top = groupStack.last, !top.explicit { closeTopFrame() }
    let own = max(0, min(1, opacity))
    pushFrame(tag: tag, alpha: own * (groupStack.last?.alpha ?? 1), explicit: true)
  }

  /// Closes the innermost open `beginGroup`. An unbalanced call is a no-op; it will not eat
  /// the implicit frame, and it will not close a caller's enclosing group.
  public func endGroup() {
    guard let top = groupStack.last, top.explicit else { return }
    closeTopFrame()
  }

  /// Scoped form.
  public func group(tag: UInt64 = 0, opacity: Double = 1, _ body: () -> Void) {
    beginGroup(tag: tag, opacity: opacity)
    body()
    endGroup()
  }

  /// Nesting depth, counting the implicit frame. Diagnostics and tests.
  public var openGroupDepth: Int { groupStack.count }

  private static func opacityByte(_ alpha: Double) -> UInt8 {
    UInt8(max(0, min(255, (alpha * 255).rounded())))
  }

  private func pushFrame(tag: UInt64, alpha: Double, explicit: Bool) {
    if !groupStack.isEmpty {
      // The parent's primitives so far are painted *under* the child, so its pending run has
      // to be sealed before the child's groups are appended; `groups` is in painter's order.
      flushRun(&groupStack[groupStack.count - 1])
      groupStack[groupStack.count - 1].hasChildren = true
    }
    let slot = groups.count
    groups.append(
      SceneGroup(start: Int32(primitives.count), count: 0, bounds: .empty, tag: tag))
    groupStack.append(
      GroupFrame(
        tag: tag, alpha: alpha, slot: slot,
        origin: primitives.count, runStart: primitives.count,
        runBounds: .empty, totalBounds: .empty,
        hasChildren: false, explicit: explicit))
  }

  /// Seals the frame's pending own-primitive run as its own group.
  ///
  /// The run carries tag `0`, never the frame's: the frame's identity entry already covers
  /// this range, and two groups with one tag would report the same component twice from a
  /// single `hitTest`.
  private func flushRun(_ frame: inout GroupFrame) {
    let count = primitives.count - frame.runStart
    guard count > 0 else { return }
    groups.append(
      SceneGroup(
        start: Int32(frame.runStart), count: Int32(count), bounds: frame.runBounds,
        tag: 0, opacity: Self.opacityByte(frame.alpha)))
    frame.totalBounds.formUnion(frame.runBounds)
    frame.runStart = primitives.count
    frame.runBounds = .empty
  }

  private func closeTopFrame() {
    guard var frame = groupStack.popLast() else { return }
    let tail = primitives.count - frame.runStart

    if !frame.hasChildren {
      // The overwhelmingly common case: one component, one contiguous run, one group. Byte
      // for byte what the builder produced before nesting existed.
      if tail > 0 {
        frame.totalBounds = frame.runBounds
        groups[frame.slot] = SceneGroup(
          start: Int32(frame.runStart), count: Int32(tail), bounds: frame.runBounds,
          tag: frame.tag, opacity: Self.opacityByte(frame.alpha))
      } else if frame.slot == groups.count - 1 {
        // Nothing was drawn and nothing was appended after the reservation: drop it.
        groups.removeLast()
      } else {
        groups[frame.slot] = SceneGroup(
          start: Int32(frame.origin), count: 0, bounds: .empty, tag: frame.tag)
      }
    } else {
      flushRun(&frame)
      // A parent's identity entry draws nothing; its primitives live in the runs and in its
      // children, and a group whose range overlapped theirs would paint them twice. It exists
      // so the parent stays hittable (the ghost's tag) and so its extent is in the index.
      //
      // Its `opacity` is therefore left opaque and the *composed* alpha rides on the runs,
      // where the backend actually applies it. A transparent empty group would cost a
      // full-clip transparency layer per frame for nothing.
      groups[frame.slot] = SceneGroup(
        start: Int32(frame.origin), count: 0, bounds: frame.totalBounds, tag: frame.tag)
    }

    if !groupStack.isEmpty {
      let parent = groupStack.count - 1
      groupStack[parent].totalBounds.formUnion(frame.totalBounds)
      // The parent resumes *after* the child. Leaving its run cursor where the child started
      // would make the parent's next run re-cover the child's primitives, and the backend
      // paints every group it is given: the overlap would be drawn twice.
      groupStack[parent].runStart = primitives.count
      groupStack[parent].runBounds = .empty
    }
  }

  // MARK: - Emission

  private func emit(_ prim: ScenePrimitive) {
    if groupStack.isEmpty {
      // Primitives emitted outside an explicit group land in an implicit one, so nothing can
      // fall out of the spatial index and vanish from the frame.
      pushFrame(tag: 0, alpha: 1, explicit: false)
    }
    var prim = prim
    // Stamped HERE and in no other place, deliberately. Every one of the six
    // `ScenePrimitive(...)` sites in this file funnels through `emit`, so a marker carries its
    // role whatever kind it is drawn as; the point of `ScenePrimitive.Role` is that it must
    // survive `drawPinMarker` being restyled from a disc to a ring to whatever comes next, and
    // a role stamped per-kind at `emitBoxed` would only survive restyles that stayed an oval.
    prim.role = currentRole
    primitives.append(prim)
    groupStack[groupStack.count - 1].runBounds.formUnion(prim.bounds)
  }

  // MARK: - Primitive role

  /// The role stamped onto everything `emit` appends. See `ScenePrimitive.Role`.
  private var currentRole: ScenePrimitive.Role = .body

  /// Runs `body` with every primitive it emits stamped `role`.
  ///
  /// **Deliberately `private`, and that is the guarantee, not an oversight.** `Role` is only
  /// worth trusting if there is exactly one producer of `.connectionMarker`, so the only way to
  /// emit one is to call `drawPinMarker`; the same choke point every port marker in the app
  /// already goes through (`InstancePainter.drawPinMarker` and `ArithPaint`, both of which
  /// delegate here). Making this `public` would let any caller assert "this is a marker" and
  /// turn a fact about the emitter back into a convention. If a second genuine producer ever
  /// appears, widen this on purpose and say why; do not reach around it.
  private func withRole(_ role: ScenePrimitive.Role, _ body: () -> Void) {
    let saved = currentRole
    currentRole = role
    body()
    currentRole = saved
  }

  /// Applies the baked translation, then the transform, then stroke inflation.
  private func finalBounds(_ raw: SceneBounds, inflate: Int32) -> SceneBounds {
    var b = raw
    if current.dx != 0 || current.dy != 0 {
      b = SceneBounds(
        minX: clampToInt32(Int(b.minX) + current.dx),
        minY: clampToInt32(Int(b.minY) + current.dy),
        maxX: clampToInt32(Int(b.maxX) + current.dx),
        maxY: clampToInt32(Int(b.maxY) + current.dy))
    }
    if current.index != 0 {
      b = transforms[Int(current.index)].transform(b)
    }
    return inflate > 0 ? b.inset(by: inflate) : b
  }

  /// Half the pen width plus a pixel, which is what a `CAP_SQUARE` end and a perpendicular
  /// half-width both need. Culling only has to be conservative, never tight.
  private var strokeInflation: Int32 {
    Int32(pen.width) / 2 + 1
  }

  /// Miter joins can push a corner past half the pen width, so joined geometry gets the full
  /// width rather than half.
  private var joinInflation: Int32 {
    Int32(pen.width) + 1
  }

  private func tx(_ v: Int) -> Int32 { clampToInt32(v + current.dx) }
  private func ty(_ v: Int) -> Int32 { clampToInt32(v + current.dy) }

  // MARK: - Lines

  /// `g.drawLine(x0, y0, x1, y1)`.
  public func drawLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    let raw = SceneBounds(
      minX: clampToInt32(min(x0, x1)), minY: clampToInt32(min(y0, y1)),
      maxX: clampToInt32(max(x0, x1)), maxY: clampToInt32(max(y0, y1)))
    emit(
      ScenePrimitive(
        kind: .line, style: .stroke, pen: pen,
        transform: current.index, color: currentSlot,
        bounds: finalBounds(raw, inflate: strokeInflation),
        a: tx(x0), b: ty(y0), c: tx(x1), d: ty(y1)))
  }

  public func drawLine(from a: Location, to b: Location) {
    drawLine(a.x, a.y, b.x, b.y)
  }

  /// `g.drawPolyline(xs, ys, n)`, open, `n-1` segments.
  public func drawPolyline(_ pts: [ScenePoint]) {
    guard pts.count >= 2 else {
      if let p = pts.first { drawLine(Int(p.x), Int(p.y), Int(p.x), Int(p.y)) }
      return
    }
    emitPointRun(pts, kind: .polyline, style: .stroke, fillRule: .nonZero)
  }

  public func drawPolyline(_ xs: [Int], _ ys: [Int]) {
    drawPolyline(zip(xs, ys).map { ScenePoint($0, $1) })
  }

  /// `g.drawPolygon(xs, ys, n)`, closed outline.
  public func drawPolygon(_ pts: [ScenePoint]) {
    guard !pts.isEmpty else { return }
    emitPointRun(pts, kind: .polygon, style: .stroke, fillRule: .evenOdd)
  }

  public func drawPolygon(_ xs: [Int], _ ys: [Int]) {
    drawPolygon(zip(xs, ys).map { ScenePoint($0, $1) })
  }

  /// `g.fillPolygon(xs, ys, n)`. `java.awt.Polygon` fills **even-odd**, not non-zero.
  public func fillPolygon(_ pts: [ScenePoint]) {
    guard !pts.isEmpty else { return }
    emitPointRun(pts, kind: .polygon, style: .fill, fillRule: .evenOdd)
  }

  public func fillPolygon(_ xs: [Int], _ ys: [Int]) {
    fillPolygon(zip(xs, ys).map { ScenePoint($0, $1) })
  }

  private func emitPointRun(
    _ pts: [ScenePoint], kind: ScenePrimitive.Kind, style: ScenePrimitive.Style,
    fillRule: ScenePrimitive.FillRule
  ) {
    let offset = points.count
    points.reserveCapacity(points.count + pts.count)
    var raw = SceneBounds.empty
    for p in pts {
      let moved = ScenePoint(x: tx(Int(p.x)), y: ty(Int(p.y)))
      points.append(moved)
      raw.formUnion(point: ScenePoint(x: p.x, y: p.y))
    }
    let inflate: Int32 = style == .fill ? 1 : joinInflation
    emit(
      ScenePrimitive(
        kind: kind, style: style, fillRule: fillRule,
        pen: pen, transform: current.index, color: currentSlot,
        bounds: finalBounds(raw, inflate: inflate),
        poolOffset: UInt32(offset), poolCount: UInt32(pts.count)))
  }

  // MARK: - Rectangles

  /// `g.drawRect(x, y, width, height)`: outline spanning `x ... x+width` inclusive.
  public func drawRect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
    emitBoxed(.rect, .stroke, x, y, width, height, inflate: strokeInflation)
  }

  /// `g.fillRect(x, y, width, height)`: fills exactly `width x height` pixels.
  public func fillRect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
    emitBoxed(.rect, .fill, x, y, width, height, inflate: 0)
  }

  public func drawRect(_ bounds: Bounds) {
    drawRect(bounds.x, bounds.y, bounds.width, bounds.height)
  }

  public func fillRect(_ bounds: Bounds) {
    fillRect(bounds.x, bounds.y, bounds.width, bounds.height)
  }

  /// `g.drawRoundRect(x, y, w, h, arcWidth, arcHeight)`. Arc arguments are *diameters*, as in
  /// Java; the backend halves them for CoreGraphics' radii.
  public func drawRoundRect(
    _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ arcWidth: Int, _ arcHeight: Int
  ) {
    emitBoxed(
      .roundRect, .stroke, x, y, width, height, e: arcWidth, f: arcHeight,
      inflate: strokeInflation)
  }

  public func fillRoundRect(
    _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ arcWidth: Int, _ arcHeight: Int
  ) {
    emitBoxed(.roundRect, .fill, x, y, width, height, e: arcWidth, f: arcHeight, inflate: 0)
  }

  // MARK: - Ovals

  /// `g.drawOval(x, y, width, height)`: the ellipse inscribed in that box.
  public func drawOval(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
    emitBoxed(.oval, .stroke, x, y, width, height, inflate: strokeInflation)
  }

  public func fillOval(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
    emitBoxed(.oval, .fill, x, y, width, height, inflate: 0)
  }

  // MARK: - Arcs

  /// `g.drawArc(x, y, w, h, startAngle, arcAngle)`: an OPEN arc, degrees, 0 at 3 o'clock,
  /// counter-clockwise, skewed by the box aspect exactly as `Arc2D` defines it.
  public func drawArc(
    _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ startAngle: Int, _ arcAngle: Int
  ) {
    emitBoxed(
      .arc, .stroke, x, y, width, height, e: startAngle, f: arcAngle,
      inflate: strokeInflation)
  }

  /// `g.fillArc(...)`: a PIE slice, matching Java.
  public func fillArc(
    _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ startAngle: Int, _ arcAngle: Int
  ) {
    emitBoxed(.arc, .fill, x, y, width, height, e: startAngle, f: arcAngle, inflate: 0)
  }

  /// `GraphicsUtil.drawCenteredArc(g, x, y, r, start, dist)`.
  public func drawCenteredArc(_ x: Int, _ y: Int, _ r: Int, _ start: Int, _ dist: Int) {
    drawArc(x - r, y - r, 2 * r, 2 * r, start, dist)
  }

  private func emitBoxed(
    _ kind: ScenePrimitive.Kind, _ style: ScenePrimitive.Style,
    _ x: Int, _ y: Int, _ width: Int, _ height: Int,
    e: Int = 0, f: Int = 0, inflate: Int32
  ) {
    let raw = SceneBounds(x: x, y: y, width: width, height: height)
    emit(
      ScenePrimitive(
        kind: kind, style: style, pen: pen,
        transform: current.index, color: currentSlot,
        bounds: finalBounds(raw, inflate: inflate),
        a: tx(x), b: ty(y), c: clampToInt32(width), d: clampToInt32(height),
        e: clampToInt32(e), f: clampToInt32(f)))
  }

  // MARK: - Paths

  /// `Graphics2D.draw(shape)` for a `GeneralPath`, the shaped-gate outlines.
  public func strokePath(_ path: ScenePath) {
    emitPath(path, style: .stroke, fillRule: .nonZero)
  }

  /// `Graphics2D.fill(shape)`. `GeneralPath`'s default winding rule is non-zero.
  public func fillPath(_ path: ScenePath, rule: ScenePrimitive.FillRule = .nonZero) {
    emitPath(path, style: .fill, fillRule: rule)
  }

  private func emitPath(
    _ path: ScenePath, style: ScenePrimitive.Style, fillRule: ScenePrimitive.FillRule
  ) {
    guard !path.isEmpty else { return }
    let offset = pathOps.count
    // The baked translation has to reach the path ops, exactly as it reaches every other
    // primitive's coordinates. `PainterShaped.paintShield` is
    // `g.translate(xlate, 0); draw(computeShield(...)); g.translate(-xlate, 0)`, so a path that
    // ignores the translation puts every shielded XOR gate's shield at the component origin.
    if current.dx != 0 || current.dy != 0 {
      let dx = Float(current.dx)
      let dy = Float(current.dy)
      pathOps.reserveCapacity(pathOps.count + path.ops.count)
      for op in path.ops {
        switch op {
        case .move(let x, let y):
          pathOps.append(.move(x + dx, y + dy))
        case .line(let x, let y):
          pathOps.append(.line(x + dx, y + dy))
        case .quad(let cx, let cy, let x, let y):
          pathOps.append(.quad(cx + dx, cy + dy, x + dx, y + dy))
        case .cubic(let a, let b, let c, let d, let x, let y):
          pathOps.append(.cubic(a + dx, b + dy, c + dx, d + dy, x + dx, y + dy))
        case .close:
          pathOps.append(.close)
        }
      }
    } else {
      pathOps.append(contentsOf: path.ops)
    }
    let inflate: Int32 = style == .fill ? 1 : joinInflation
    emit(
      ScenePrimitive(
        kind: .path, style: style, fillRule: fillRule,
        pen: pen, transform: current.index, color: currentSlot,
        bounds: finalBounds(path.controlBounds, inflate: inflate),
        poolOffset: UInt32(offset), poolCount: UInt32(path.ops.count)))
  }

  // MARK: - Text

  /// `GraphicsUtil.drawText(g, text, x, y, halign, valign)`.
  ///
  /// Measured once, here. The resolved baseline and box go into the `TextRun`, so the backend
  /// does no layout and, with `CoreTextMeasurer`, no re-shaping. Upstream measures the same
  /// string twice per draw and re-shapes every frame (`GraphicsUtil.java:166-167`, `:201`).
  @discardableResult
  public func drawText(
    _ text: String, x: Int, y: Int,
    halign: HAlign = .left, valign: VAlign = .baseline,
    background: SceneColor? = nil
  ) -> SceneBounds {
    guard !text.isEmpty else { return .empty }

    let metrics = measurer.metrics(for: font)
    let width = measurer.width(of: text, font: font)
    let box = TextLayout.textBox(
      width: width, metrics: metrics, x: x, y: y, halign: halign, valign: valign)
    let baseline = TextLayout.baselineOrigin(box: box, metrics: metrics)

    let run = TextRun(
      string: text,
      font: font,
      baselineX: tx(baseline.x),
      baselineY: ty(baseline.y),
      boxX: tx(box.x),
      boxY: ty(box.y),
      boxWidth: clampToInt32(box.width),
      boxHeight: clampToInt32(box.height),
      halign: halign,
      valign: valign,
      background: background.map { internStatic($0) })

    let offset = texts.count
    texts.append(run)

    let raw = SceneBounds(x: box.x, y: box.y, width: box.width, height: box.height)
    let bounds = finalBounds(raw, inflate: 1)
    emit(
      ScenePrimitive(
        kind: .text, style: .fill, pen: StrokePen(width: 0),
        transform: current.index, color: currentSlot, bounds: bounds,
        poolOffset: UInt32(offset), poolCount: 1))
    return bounds
  }

  /// `GraphicsUtil.drawCenteredText(g, text, x, y)`.
  @discardableResult
  public func drawCenteredText(_ text: String, x: Int, y: Int) -> SceneBounds {
    drawText(text, x: x, y: y, halign: .center, valign: .center)
  }

  /// `g.drawString(text, x, y)`: pen at the baseline, no alignment adjustment.
  @discardableResult
  public func drawString(_ text: String, x: Int, y: Int) -> SceneBounds {
    drawText(text, x: x, y: y, halign: .left, valign: .baseline)
  }

  /// The box `drawText` would occupy, without emitting anything:
  /// `GraphicsUtil.getTextBounds`. Layout code (label placement, `Text` tool carets) needs it.
  ///
  /// **In scene coordinates**, i.e. with the baked translation applied, exactly as every
  /// emitter applies it. Java gets away with not doing this because `getTextBounds` and the
  /// `fillRect` after it share one CTM; here the translation is baked into the emitted
  /// coordinates instead, so a measurement that skipped it would be off by the full
  /// translation against the run `drawText` actually emits.
  ///
  /// If you are going to hand the result straight back to another emitter, the Java
  /// `getTextBounds` + `g.fillRect(bds)` idiom, use ``textBoundsInUserSpace(_:x:y:halign:valign:)``
  /// instead, or the translation gets applied twice.
  /// The advance width of `text` in the current font, in scene units.
  ///
  /// Java's idiom is `g.getFontMetrics().stringWidth(s)`, which appears wherever upstream lays
  /// text out by hand: stepping a cursor across a Tty line, or centring one run against
  /// another. Those call sites want a single number and have no use for a box, so this exists
  /// rather than making each of them build a `Bounds` and read `.width` off it.
  ///
  /// Translation-invariant by construction: a width is a difference between two coordinates, so
  /// the baked translation cancels. That is why this can be answered from either bounds helper
  /// and why there is no user-space counterpart: unlike ``textBounds(_:x:y:halign:valign:)``
  /// and ``textBoundsInUserSpace(_:x:y:halign:valign:)``, where the frame genuinely matters.
  public func measuredWidth(of text: String) -> Int {
    textBox(text, x: 0, y: 0, halign: .left, valign: .baseline).width
  }

  public func textBounds(
    _ text: String, x: Int, y: Int, halign: HAlign = .left, valign: VAlign = .baseline
  ) -> Bounds {
    let box = textBox(text, x: x, y: y, halign: halign, valign: valign)
    return Bounds.create(Int(tx(box.x)), Int(ty(box.y)), box.width, box.height)
  }

  /// The same box in the coordinates the caller passes *in*: the space `fillRect`, `drawRect`
  /// and `drawText` take their arguments in.
  ///
  /// This is the one to measure with when the box is going back into a drawing call under the
  /// same translation (`TextFieldCaret.java:129`, `Text.java:156`, `GraphicsUtil.java:159`);
  /// ``textBounds(_:x:y:halign:valign:)`` is the one to measure with when the box is being
  /// compared against scene-space geometry, such as a hit test or a damage rect.
  public func textBoundsInUserSpace(
    _ text: String, x: Int, y: Int, halign: HAlign = .left, valign: VAlign = .baseline
  ) -> Bounds {
    let box = textBox(text, x: x, y: y, halign: halign, valign: valign)
    return Bounds.create(box.x, box.y, box.width, box.height)
  }

  private func textBox(
    _ text: String, x: Int, y: Int, halign: HAlign, valign: VAlign
  ) -> (x: Int, y: Int, width: Int, height: Int) {
    let metrics = measurer.metrics(for: font)
    let width = text.isEmpty ? 0 : measurer.width(of: text, font: font)
    return TextLayout.textBox(
      width: width, metrics: metrics, x: x, y: y, halign: halign, valign: valign)
  }

  public func fontMetrics() -> FontMetrics {
    measurer.metrics(for: font)
  }

  // MARK: - Images

  public func drawImage(_ ref: SceneImageRef, x: Int, y: Int, width: Int, height: Int) {
    let offset = images.count
    images.append(ref)
    let raw = SceneBounds(x: x, y: y, width: width, height: height)
    emit(
      ScenePrimitive(
        kind: .image, style: .fill, pen: StrokePen(width: 0),
        transform: current.index, color: currentSlot,
        bounds: finalBounds(raw, inflate: 0),
        a: tx(x), b: ty(y), c: clampToInt32(width), d: clampToInt32(height),
        poolOffset: UInt32(offset), poolCount: 1))
  }

  // MARK: - Composites (ComponentDrawContext / GraphicsUtil helpers)
  //
  // Upstream's own convenience layer. These stay on the builder rather than becoming
  // primitives: a backend gains nothing from knowing what a dongle is, and keeping them here
  // means a ported call site still reads `painter.drawDongle(x, y)`.

  /// `ComponentDrawContext.drawBounds(comp)`.
  public func drawBounds(_ bounds: Bounds) {
    withStrokeWidth(2) {
      drawRect(bounds.x, bounds.y, bounds.width, bounds.height)
    }
  }

  /// `ComponentDrawContext.drawDongle(x, y)`, the negation bubble.
  public func drawDongle(_ x: Int, _ y: Int) {
    withStrokeWidth(2) {
      drawOval(x - 4, y - 4, 9, 9)
    }
  }

  /// `ComponentDrawContext.drawHandle(x, y)`.
  public func drawHandle(_ x: Int, _ y: Int) {
    withColor(.white) { fillRect(x - 3, y - 3, 7, 7) }
    withColor(.black) { drawRect(x - 3, y - 3, 7, 7) }
  }

  /// `ComponentDrawContext.drawClockSymbol(comp, x, y)`.
  public func drawClockSymbol(x: Int, y: Int) {
    withStrokeWidth(2) {
      drawPolyline([
        ScenePoint(x + 1, y - 4), ScenePoint(x + 8, y), ScenePoint(x + 1, y + 4),
      ])
    }
  }

  /// `GraphicsUtil.drawArrow(g, x0, y0, x1, y1, headLength, headAngle)`.
  ///
  /// The `(int)` truncation of each head coordinate is Java's and is reproduced: rounding
  /// instead would move arrowheads by a pixel on roughly half of all angles.
  public func drawArrow(
    _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, headLength: Int, headAngle: Int
  ) {
    let offs = Double(headAngle) * Double.pi / 180.0
    let angle = atan2(Double(y0 - y1), Double(x0 - x1))
    let len = Double(headLength)
    let xs = [
      x1 + Int(len * cos(angle + offs)),
      x1,
      x1 + Int(len * cos(angle - offs)),
    ]
    let ys = [
      y1 + Int(len * sin(angle + offs)),
      y1,
      y1 + Int(len * sin(angle - offs)),
    ]
    drawLine(x0, y0, x1, y1)
    drawPolyline(xs, ys)
  }

  /// `GraphicsUtil.drawArrow2(g, x0, y0, x1, y1, x2, y2)`: a wide dark stroke with a white
  /// core.
  public func drawArrow2(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
    let pts = [ScenePoint(x0, y0), ScenePoint(x1, y1), ScenePoint(x2, y2)]
    withStrokeWidth(7) { drawPolyline(pts) }
    withColor(.white) {
      withStrokeWidth(3) { drawPolyline(pts) }
    }
    strokeWidth = 1
  }

  /// `ComponentDrawContext.drawRoundBounds(comp, bds, color)`.
  public func drawRoundBounds(_ bounds: Bounds, fill: SceneColor?, outline: SceneColor = .black) {
    withStrokeWidth(2) {
      if let fill, fill != .rgba(.white) {
        withColor(fill) {
          fillRoundRect(bounds.x, bounds.y, bounds.width, bounds.height, 10, 10)
        }
      }
      withColor(outline) {
        drawRoundRect(bounds.x, bounds.y, bounds.width, bounds.height, 10, 10)
      }
    }
  }

  /// `ComponentDrawContext.drawPinMarker(x, y)` at the given appearance radius.
  ///
  /// ── DELIBERATE DIVERGENCE: RING, NOT DISC ────────────────────────────────────────────────
  ///
  /// 4.1.0 fills the marker solid. `javap -c com.cburch.logisim.comp.ComponentDrawContext`
  /// against `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`
  /// gives `drawPinMarker` as, verbatim, a lookup on `AppPreferences.PinAppearance` producing
  /// `(rad, offs)` = `(4,2)` default / `(6,3)` `dot-medium` / `(8,4)` `dot-big` /
  /// `(10,5)` `dot-bigger`, then one call: `g.fillOval(x - offs, y - offs, rad, rad)`
  /// (offsets 12-16 for the defaults, 163-179 for the call).
  ///
  /// Here the same marker is drawn as an ANNULUS: the centre is knocked out in `hole` and only
  /// the rim is stroked in the caller's colour. Requested from real use: "those joints between
  /// wire and whatnot, id make it white donut instead of black dot. white ring so its clear its
  /// not the wire itself". A solid disc in the wire's own colour reads as a blob *on* the wire;
  /// a ring reads as a marker *about* the wire.
  ///
  /// **The rim keeps the caller's colour, which is the load-bearing part.** `drawPin` sets that
  /// colour from the live value when `getShowState()` (`Value.getColor()`), so flattening the
  /// marker to a flat white ring would have destroyed the high/low/error/unknown signal at every
  /// port. Only the fill is replaced; the colour still says what it always said.
  ///
  /// Geometry: the box is upstream's grown by one unit on each side, which keeps it exactly
  /// integer-centred on `(x, y)` for all four appearance sizes (`(4,2)` → `(6,3)`, `(6,3)` →
  /// `(8,4)`, and so on: i.e. each size now occupies the footprint of the next size up). At the
  /// default `dot-small` that is a 6-unit outer circle stroked at width 1 around a ~5-unit hole,
  /// against a wire this renderer strokes at width 1: six times the wire's thickness across, so
  /// the ring cannot be mistaken for a swelling of the wire, and still inside the 10-unit grid
  /// pitch so two adjacent ports never touch.
  ///
  /// ── AND IT IS TAGGED `.connectionMarker` ───────────────────────────────────────────────────
  ///
  /// Both halves, and this is the only place in the app that emits that role. `SelectionSilhouette`
  /// has to tell a component's *boundary* from the points where it *connects*, and it used to do
  /// that by "markers are fills, boundaries are strokes", which was true only for as long as the
  /// marker was a disc. The moment it became a ring, every port grew its own little blue outline
  /// and seven tests went red. See `ScenePrimitive.Role`: the emitter is the only thing that
  /// actually knows, so the emitter says so, and the answer no longer depends on the shape.
  public func drawPinMarker(
    _ x: Int, _ y: Int, radius: Int = 4, offset: Int = 2, hole: SceneColor = .white
  ) {
    let outer = radius + 2
    let corner = offset + 1
    withRole(.connectionMarker) {
      withColor(hole) { fillOval(x - corner, y - corner, outer, outer) }
      withStrokeWidth(1) { drawOval(x - corner, y - corner, outer, outer) }
    }
  }

  // MARK: - Finish

  /// Seals the scene: closes any open group, builds the spatial index, and hands back an
  /// immutable `Sendable` value. The builder is reusable afterwards only via `reset()`.
  public func finish() -> RenderScene {
    // Outermost last, so each frame's extent reaches its parent before the parent is sealed.
    while !groupStack.isEmpty { closeTopFrame() }
    // Identity entries that carry neither a tag nor an extent are pure bookkeeping; nothing
    // downstream references a group by index, so dropping them is free.
    let sealed = groups.filter { $0.count > 0 || ($0.tag != 0 && !$0.bounds.isEmpty) }
    return RenderScene(
      primitives: primitives,
      points: points,
      pathOps: pathOps,
      texts: texts,
      images: images,
      transforms: transforms,
      groups: sealed,
      palette: palette,
      colorSlots: colorSlots,
      dynamicSlots: dynamicSlots,
      cellSize: indexCellSize)
  }

  /// Clears everything, keeping the measurer. Lets a canvas reuse one builder across rebuilds
  /// without re-allocating the pools.
  public func reset() {
    primitives.removeAll(keepingCapacity: true)
    points.removeAll(keepingCapacity: true)
    pathOps.removeAll(keepingCapacity: true)
    texts.removeAll(keepingCapacity: true)
    images.removeAll(keepingCapacity: true)
    transforms = [.identity]
    transformLookup.removeAll(keepingCapacity: true)
    groups.removeAll(keepingCapacity: true)
    palette = ScenePalette()
    colorSlots.removeAll(keepingCapacity: true)
    staticSlotLookup.removeAll(keepingCapacity: true)
    dynamicSlots.removeAll(keepingCapacity: true)
    transformStack.removeAll(keepingCapacity: true)
    current = TransformState(dx: 0, dy: 0, index: 0)
    groupStack.removeAll(keepingCapacity: true)
    // The WHOLE pen, not just its width: `strokeWidth = 1` leaves cap, join and the dash
    // pattern behind, so a builder reused after drawing one highlighted wire
    // (`Wire.HIGHLIGHTED_STROKE`; the only dashed stroke in the app) draws every wire in the
    // next frame dashed. `reset()` exists precisely to be reused across frames.
    pen = .default
    font = .default
    color = .black
  }
}
