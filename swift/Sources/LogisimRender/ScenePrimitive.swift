// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The primitive record. This is the type every `paintInstance` port ultimately produces,
// and the type both backends consume.
//
// WHY A FLAT STRUCT AND NOT AN ENUM WITH ASSOCIATED VALUES
//
// A Swift enum with payloads would be prettier at the call site, but the scene is walked
// linearly for culling and again for drawing, tens of thousands of records per frame, and it
// has to become GPU buffers at M9. A fixed-size POD record keeps that walk a contiguous
// stride, keeps variable-length data (points, path ops, strings) in side pools shared across
// primitives, and maps directly onto an instance buffer. The ergonomics are recovered in
// `SceneBuilder`, which is what component code actually sees; no component ever constructs a
// `ScenePrimitive` by hand.
//
// The primitive set is derived from what upstream actually calls, counted across the whole
// tree (see the header comment on `Kind`).

// MARK: - StrokePen

/// Everything `java.awt.BasicStroke` carries, packed into six bytes.
///
/// A separate type rather than a bare width because upstream does not only vary the width:
/// `Wire.HIGHLIGHTED_STROKE` is `BasicStroke(3, CAP_BUTT, JOIN_BEVEL, 0, new float[]{7}, 0)`,
/// the dashed outline drawn around a selected wire. That is the *only* dashed stroke in the
/// schematic renderer, but a scene that cannot express it forces the wire layer to reach past
/// the abstraction, which is exactly the failure D6 exists to prevent.
///
/// The defaults are `BasicStroke(float)`'s defaults, `CAP_SQUARE`, `JOIN_MITER`, miter limit
/// 10, because that is what all 253 `switchToWidth` sites produce. A backend that substitutes
/// `CAP_BUTT` shortens every line by half a pen width at both ends.
public struct StrokePen: Hashable, Sendable {

  public enum Cap: UInt8, Sendable, Hashable {
    /// `BasicStroke.CAP_SQUARE`, the Java default.
    case square = 0
    case butt = 1
    case round = 2
  }

  public enum Join: UInt8, Sendable, Hashable {
    /// `BasicStroke.JOIN_MITER`, the Java default.
    case miter = 0
    case bevel = 1
    case round = 2
  }

  /// Pen width in scene units. `0` means Java's `BasicStroke(0)`: the thinnest line the device
  /// can draw, i.e. one device pixel regardless of zoom.
  public var width: UInt8
  public var cap: Cap
  public var join: Join
  /// Dash "on" run, in scene units. `0` = solid.
  public var dashOn: UInt8
  /// Dash "off" run. Java's single-element `float[]{7}` means on and off are both 7.
  public var dashOff: UInt8
  public var dashPhase: UInt8

  public init(
    width: UInt8 = 1,
    cap: Cap = .square,
    join: Join = .miter,
    dashOn: UInt8 = 0,
    dashOff: UInt8 = 0,
    dashPhase: UInt8 = 0
  ) {
    self.width = width
    self.cap = cap
    self.join = join
    self.dashOn = dashOn
    self.dashOff = dashOff
    self.dashPhase = dashPhase
  }

  public var isDashed: Bool { dashOn > 0 }

  /// `GraphicsUtil.switchToWidth(g, w)`: everything else at its Java default.
  public static func width(_ w: Int) -> StrokePen {
    StrokePen(width: UInt8(Swift.max(0, Swift.min(255, w))))
  }

  public static let `default` = StrokePen()

  /// `Wire.HIGHLIGHTED_STROKE`.
  public static let highlightedWire = StrokePen(
    width: 3, cap: .butt, join: .bevel, dashOn: 7, dashOff: 7, dashPhase: 0)

  /// Java's miter limit for `BasicStroke(float)`.
  public static let miterLimit: Double = 10
}

// MARK: - ScenePrimitive

public struct ScenePrimitive: Sendable, Hashable {

  /// The complete primitive set.
  ///
  /// Call-site counts from a grep of `upstream-java-4.1.0/src/main/java/com/cburch`:
  ///
  /// | kind       | upstream calls                                                   |
  /// |------------|------------------------------------------------------------------|
  /// | `line`     | 638 `drawLine`                                                   |
  /// | `polyline` | 175 `drawPolyline` (+ `drawArrow`, `drawArrow2`, `drawClockSymbol`)|
  /// | `polygon`  | 44 `fillPolygon`, 37 `drawPolygon`                               |
  /// | `rect`     | 170 `fillRect`, 145 `drawRect`, 60 `drawBounds`, 1 `fill3DRect`  |
  /// | `roundRect`| 34 `drawRoundRect`, 18 `fillRoundRect`, 6 `drawRoundBounds`      |
  /// | `oval`     | 109 `fillOval`, 98 `drawOval`, 6 `drawDongle`                    |
  /// | `arc`      | 15 `drawCenteredArc`, 13 `drawArc`, 7 `fillArc`                  |
  /// | `path`     | 71 `draw(Shape)`, 45 `fill(Shape)`, the shaped/DIN gate painters |
  /// | `text`     | 173 `drawCenteredText`, 105 `drawString`, 94 `drawText`          |
  /// | `image`    | 9 `drawImage`                                                    |
  ///
  /// Everything else in that grep (`drawPort`, `drawPin`, `drawHandle`, `drawTrapezoid`,
  /// `drawHexReg`, ...) is a *composite* built from these, upstream's own helpers on
  /// `ComponentDrawContext`. They belong on `SceneBuilder`, not in the primitive set, because
  /// a backend gains nothing from knowing what a dongle is.
  public enum Kind: UInt8, Sendable, Hashable {
    /// `a,b` -> `c,d` = `(x0,y0) -> (x1,y1)`.
    case line
    /// Open run through `points[poolOffset ..< poolOffset+poolCount]`. `n-1` segments.
    case polyline
    /// Closed run through the same pool. Java's `Polygon` fills **even-odd**.
    case polygon
    /// `a,b,c,d` = `x, y, width, height`.
    case rect
    /// `a,b,c,d` = `x, y, width, height`; `e,f` = `arcWidth, arcHeight` (diameters, as Java).
    case roundRect
    /// `a,b,c,d` = the bounding box the ellipse is inscribed in.
    case oval
    /// `a,b,c,d` = bounding box; `e,f` = `startAngle, arcAngle` in whole degrees, Java's
    /// convention (0 at 3 o'clock, counter-clockwise, skewed by the box aspect ratio).
    /// Stroked = `Arc2D.OPEN`; filled = `Arc2D.PIE`, matching `drawArc`/`fillArc`.
    case arc
    /// `pathOps[poolOffset ..< poolOffset+poolCount]`.
    case path
    /// `texts[poolOffset]`.
    case text
    /// `images[poolOffset]`, drawn into `a,b,c,d` = `x, y, width, height`.
    case image
  }

  public enum Style: UInt8, Sendable, Hashable {
    case stroke
    case fill
  }

  /// What part of a component a primitive *is*: as opposed to what shape it happens to be.
  ///
  /// ── WHY THIS EXISTS, AND WHAT IT COST TO LEARN ─────────────────────────────────────────────
  ///
  /// `SelectionSilhouette` (LogisimUI) traces a selected component's real outline out of these
  /// primitives, and has to reject the port markers: a marker is where the component *connects*,
  /// not where it *ends*, and outlining one draws a little ring on every pin. It used to reject
  /// them with "stroked shapes only", justified by the observation that port markers were
  /// `fillOval`. That was never the rule; it was a proxy that happened to hold, and it stopped
  /// holding the moment `SceneBuilder.drawPinMarker` became a ring (a fill *and* a stroke). Seven
  /// tests went red at once.
  ///
  /// The replacement is this: the emitter, which is the only thing that actually knows, says so.
  /// A marker is a marker whatever shape it is drawn in, disc, ring, diamond, cross, so the
  /// silhouette rule survives the next restyle, which was the whole lesson.
  ///
  /// ── WHY NOT A SIZE RULE ────────────────────────────────────────────────────────────────────
  ///
  /// The obvious alternative was "small round things are markers", thresholded at the largest
  /// marker footprint (`dot-bigger`, radius 10, grown to 12). It does not survive contact with
  /// the corpus: `ComponentDrawContext.drawDongle`, a NOT gate's inversion bubble, and every
  /// negated gate input, is `drawOval(x - 4, y - 4, 9, 9)`, i.e. **9 units, inside 12**. The two
  /// populations overlap, so no threshold separates them, and the bubble is precisely the shape
  /// `SelectionSilhouette` clause 1 exists to keep. A size rule would trade one incidental
  /// criterion for another and break a different test.
  ///
  /// ── COST ───────────────────────────────────────────────────────────────────────────────────
  ///
  /// None. Declared where it is, it lands in the padding byte between `pen` (6 bytes, 1-aligned)
  /// and `transform` (2-aligned), so `ScenePrimitive` stays 64 bytes; asserted by
  /// `SceneBuilderTests.theRoleFieldIsFreeInTheRecordLayout`, because a field that silently grew
  /// the record would cost a cache line per two primitives on the walk this struct's whole shape
  /// exists to keep fast.
  public enum Role: UInt8, Sendable, Hashable {
    /// Anything a component draws as itself. The default, and the overwhelming majority.
    case body = 0
    /// A port/pin marker: `SceneBuilder.drawPinMarker`, and nothing else emits it.
    case connectionMarker = 1
  }

  public enum FillRule: UInt8, Sendable, Hashable {
    case nonZero
    case evenOdd
  }

  public var kind: Kind
  public var style: Style
  public var fillRule: FillRule
  /// The pen. Ignored when `style == .fill`.
  public var pen: StrokePen
  /// What part of a component this is. See `Role`, and note the declaration position is
  /// load-bearing: here it occupies padding and the record stays 64 bytes.
  public var role: Role
  /// Index into `RenderScene.transforms`. `0` is always identity, and is the overwhelmingly
  /// common case because the builder bakes integer translation into the coordinates.
  public var transform: UInt16
  public var color: ColorSlot
  /// Precomputed, already transformed, already stroke-inflated. Culling never touches the
  /// payload.
  public var bounds: SceneBounds

  public var a: Int32
  public var b: Int32
  public var c: Int32
  public var d: Int32
  public var e: Int32
  public var f: Int32

  public var poolOffset: UInt32
  public var poolCount: UInt32

  public init(
    kind: Kind,
    style: Style,
    fillRule: FillRule = .nonZero,
    pen: StrokePen = .default,
    role: Role = .body,
    transform: UInt16 = 0,
    color: ColorSlot,
    bounds: SceneBounds,
    a: Int32 = 0, b: Int32 = 0, c: Int32 = 0, d: Int32 = 0, e: Int32 = 0, f: Int32 = 0,
    poolOffset: UInt32 = 0,
    poolCount: UInt32 = 0
  ) {
    self.kind = kind
    self.style = style
    self.fillRule = fillRule
    self.pen = pen
    self.role = role
    self.transform = transform
    self.color = color
    self.bounds = bounds
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.e = e
    self.f = f
    self.poolOffset = poolOffset
    self.poolCount = poolCount
  }

  public var pointRange: Range<Int> {
    Int(poolOffset) ..< Int(poolOffset) + Int(poolCount)
  }

  /// Convenience for the common case; `GraphicsUtil.switchToWidth`'s argument.
  public var strokeWidth: Int { Int(pen.width) }
}

// MARK: - SceneGroup

/// A contiguous run of primitives that belong to one component (or one wire, or one piece of
/// canvas chrome), with a union bounds.
///
/// This is the unit of culling. Upstream has no equivalent and no spatial index anywhere in
/// the codebase, so its repaint is O(all components) regardless of what is on screen, which
/// is why `CanvasPaintCoordinator` has to cap the frame rate at 20 fps. Rejecting a whole
/// component with one box test is the entire difference.
public struct SceneGroup: Sendable, Hashable {
  /// Range into `RenderScene.primitives`.
  public var start: Int32
  public var count: Int32
  public var bounds: SceneBounds
  /// Caller-supplied identity: `UInt64(UInt(bitPattern: ObjectIdentifier(component)))` in
  /// practice. Lets the UI map a hit back to a component without a second structure. `0` for
  /// chrome that has no component behind it.
  public var tag: UInt64
  /// Group alpha, 255 = opaque. Reproduces `AlphaComposite.getInstance(SRC_OVER, 0.5f)`, which
  /// `SubcircuitFactory.java:372` applies around a whole subcircuit ghost. It lives on the
  /// group, not on the primitive, because Java applies it to the composite as a unit: two
  /// overlapping half-transparent shapes must not darken where they cross, and per-primitive
  /// alpha would make them.
  public var opacity: UInt8

  public init(start: Int32, count: Int32, bounds: SceneBounds, tag: UInt64, opacity: UInt8 = 255) {
    self.start = start
    self.count = count
    self.bounds = bounds
    self.tag = tag
    self.opacity = opacity
  }

  public var range: Range<Int> { Int(start) ..< Int(start) + Int(count) }
}
