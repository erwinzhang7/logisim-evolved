// Tunnel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Tunnel),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is one of the four builtin tools the M2 migration gate is blocked on ──────────────
//
// See `decisions.md`'s `WHY THIS FAMILY MATTERS MORE` block: `WiringLibrary` adds
// `Tunnel.FACTORY` to the toolbar, so `XmlWriter` needs this file's `defaultAttributeValue`
// answers (inherited, unmodified, from `AbstractComponentFactory`/`InstanceFactoryBase`: Tunnel
// declares no bespoke defaults of its own) to decide whether a placed tunnel's `<tool
// name="Tunnel">` block needs an `<a>` element at all.
//
// ── Tunnel connectivity itself is out of scope for this file ───────────────────────────────
//
// See `TunnelAttributes.swift`'s header: label matching (case-sensitive, trimmed) is
// `CircuitWires.connectTunnels`'s job, not this factory's. `isTunnel` below is the only hook
// this file contributes to that machinery; it is `ComponentFactory`'s `instanceof Tunnel`
// stand-in (`ComponentFactory.swift`'s header), and `Circuit.swift` already calls it for
// label-uniqueness exemption (`factory.isTunnel`), so setting it `true` here is what turns that
// call site on with no other edits, exactly as documented.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Tunnel`.
public final class Tunnel: InstanceFactoryBase {

  /// `Tunnel._ID`. Do not change, `.circ` files reference it.
  public static let id = "Tunnel"

  /// `Tunnel.MARGIN`.
  static let margin = 3
  /// `Tunnel.ARROW_MARGIN`.
  static let arrowMargin = 5
  /// `Tunnel.ARROW_DEPTH`.
  static let arrowDepth = 4
  /// `Tunnel.ARROW_MIN_WIDTH`.
  static let arrowMinWidth = 16
  /// `Tunnel.ARROW_MAX_WIDTH`.
  static let arrowMaxWidth = 20

  // `TextField.H_LEFT`/`H_RIGHT`/`H_CENTER`, `V_TOP`/`V_BOTTOM`/`V_CENTER_OVERALL`: see
  // `TunnelAttributes.swift`'s header for the exact values (all aliases of `GraphicsUtil`'s).
  static let hLeft = -1
  static let hCenter = 0
  static let hRight = 1
  static let vTop = -1
  static let vBottom = 2
  static let vCenterOverall = 3

  /// Java's `public static final Tunnel FACTORY = new Tunnel()`.
  public static let factory = Tunnel()

  public init() {
    super.init(Tunnel.id)
    setFacingAttribute(StdAttr.facing)
    // No `setAttributes`: `createAttributeSet()` builds a bespoke `TunnelAttributes`, which is
    // exactly what upstream's `attrs == null` state means (see `InstanceFactoryBase`'s header).
  }

  public override var isTunnel: Bool { true }

  public override func createAttributeSet() -> any AttributeSet { TunnelAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is TunnelAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Tunnel.id)
    }
  }

  /// `Tunnel.computeBounds` (`Tunnel.java:57-86`), minus the `Graphics g`/`label` draw branch;
  /// that half is `GraphicsUtil.drawText`, M6 (D6/D9). `getOffsetBounds` below is the only
  /// caller in scope, and it always passes `g = null`, so nothing observable is lost.
  private static func computeBounds(_ attrs: TunnelAttributes, textWidth: Int, textHeight: Int)
    -> Bounds
  {
    let x = attrs.labelX
    let y = attrs.labelY
    let halign = attrs.labelHAlign
    let valign = attrs.labelVAlign

    let minDim = arrowMinWidth - 2 * margin
    let bw = max(minDim, textWidth)
    let bh = max(minDim, textHeight)
    let bx: Int
    switch halign {
    case hLeft: bx = x
    case hRight: bx = x - bw
    default: bx = x - (bw / 2)
    }
    let by: Int
    switch valign {
    case vTop: by = y
    case vBottom: by = y - bh
    default: by = y - (bh / 2)
    }

    return Bounds.create(bx, by, bw, bh).expand(margin).add(0, 0)
  }

  /// `getOffsetBounds(AttributeSet)` (`Tunnel.java:118-129`).
  ///
  /// The width/height estimate here is Java's own approximation
  /// (`ht = font.getSize(); wd = ht * label.length() / 2`); it does not need real font metrics,
  /// which only the (unported, M6) `paintGhost`'s real `FontMetrics` would refine. See
  /// `computeBounds`'s header.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let attrs = attributes as? TunnelAttributes else { return Bounds.empty }
    if let cached = attrs.offsetBounds { return cached }
    let height = attrs.labelFont.size
    let width = Int(height) * attrs.label.count / 2
    let bounds = Tunnel.computeBounds(attrs, textWidth: width, textHeight: Int(height))
    attrs.setOffsetBoundsCache(bounds)
    return bounds
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    [Port(0, 0, .inout_, StdAttr.width)]
  }

  public override func propagate(_ state: any InstanceState) throws {
    // `Tunnel.propagate`: "nothing to do - handled by circuit". Connectivity across a tunnel's
    // label group is `CircuitWires.connectTunnels`'s job (see this file's header).
  }

  /// `Tunnel.configureLabel(Instance)`; `Tunnel.java:90-101`.
  ///
  /// The one attribute-driven placement in this family: it reads none of the bounds, only the
  /// location and the four label fields `TunnelAttributes.configureLabel()` derives from
  /// `FACING`. That indirection is upstream's and is load-bearing: the same four fields drive
  /// `computeBounds`, so the label the caret edits and the arrow drawn around it are placed by
  /// one computation and cannot disagree.
  ///
  /// The `Int` codes stored on the attributes are `TextField.H_*`/`V_*`, whose raw values are
  /// `HAlign`/`VAlign`'s by construction (`SceneText.swift:23-38`), so the mapping is the
  /// identity rather than a switch. `nil` on an unmappable code would mean a value upstream
  /// cannot produce either.
  ///
  /// **This conformance adds editing, not a second drawing.** Upstream's Tunnel never calls
  /// `painter.drawLabel()`: it paints the label itself inside `computeBounds`'s `g != null`
  /// branch (`Tunnel.java:81-84`), because the text has to be centred inside the arrow it also
  /// sizes. `paintGhost` below does the same, and deliberately still does not call
  /// `drawLabel()`; conforming here would otherwise double-draw every tunnel label.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    guard let attrs = painter.attributeSet as? TunnelAttributes,
      let halign = HAlign(rawValue: attrs.labelHAlign),
      let valign = VAlign(rawValue: attrs.labelVAlign)
    else { return nil }
    let loc = painter.location
    return LabelPlacement(
      x: loc.x + attrs.labelX,
      y: loc.y + attrs.labelY,
      halign: halign,
      valign: valign)
  }

  // NOT PORTED: `instanceAttributeChanged`; Java's two branches only call `configureLabel`
  // (which `TunnelAttributes.setRawValue` already does internally on every FACING write) and
  // `recomputeBounds()`/nothing else; both are automatic under this chassis (`PATTERNS.md` §0):
  // bounds are derived fresh from `offsetBounds(attributes)` on every read, so there is no stale
  // cache besides `TunnelAttributes.offsetBounds` itself, which every `setRawValue` already
  // clears.
  //
  // MARK: Painting (Tunnel.java:149-224)

  /// The drawing half of `computeBounds`: the `g != null` branch this file's `computeBounds`
  /// deliberately omits, because the geometry-only caller always passes `null`.
  ///
  /// `V_CENTER_OVERALL`, not `V_CENTER`: the label is centred on the whole line box
  /// (ascent + descent), which is what keeps a tunnel's text optically centred inside an arrow
  /// whose height came from those same metrics.
  private static func computeBoundsDrawing(
    _ painter: InstancePainter, _ attrs: TunnelAttributes,
    textWidth: Int, textHeight: Int, label: String
  ) -> Bounds {
    let x = attrs.labelX
    let y = attrs.labelY
    let halign = attrs.labelHAlign
    let valign = attrs.labelVAlign

    let minDim = arrowMinWidth - 2 * margin
    let bw = max(minDim, textWidth)
    let bh = max(minDim, textHeight)
    let bx: Int
    switch halign {
    case hLeft: bx = x
    case hRight: bx = x - bw
    default: bx = x - (bw / 2)
    }
    let by: Int
    switch valign {
    case vTop: by = y
    case vBottom: by = y - bh
    default: by = y - (bh / 2)
    }

    painter.g.drawText(
      label, x: bx + bw / 2, y: by + bh / 2, halign: .center, valign: .centerOverall)

    return Bounds.create(bx, by, bw, bh).expand(margin).add(0, 0)
  }

  /// `paintGhost(InstancePainter)`; the label plus the arrow outline around it.
  ///
  /// The arrow has two forms per facing: a plain five-point pennant when the body is no wider
  /// than `ARROW_MAX_WIDTH`, and a seven-point form with a flat shoulder either side of the tip
  /// when it is wider. Every coordinate below is transcribed rather than derived.
  ///
  /// This is also where the *real* offset bounds are established. `getOffsetBounds` can only
  /// estimate (`ht * label.length() / 2`) because it has no font metrics; the first paint has
  /// them, recomputes, and writes the cache back, which is why upstream calls
  /// `instance.recomputeBounds()` from inside a paint method.
  public func paintGhost(_ painter: InstancePainter) {
    guard let attrs = painter.attributeSet as? TunnelAttributes else { return }
    let facing = attrs.facing
    let label = attrs.label

    let g = painter.g
    let savedFont = g.font
    g.font = InstancePainter.sceneFont(attrs.labelFont)
    let fm = g.fontMetrics()
    let textWidth = label.isEmpty ? 0 : g.textBoundsInUserSpace(label, x: 0, y: 0).width
    let bds = Tunnel.computeBoundsDrawing(
      painter, attrs,
      textWidth: textWidth, textHeight: fm.ascent + fm.descent, label: label)
    attrs.setOffsetBoundsCache(bds)

    let x0 = bds.x
    let y0 = bds.y
    let x1 = x0 + bds.width
    let y1 = y0 + bds.height
    let mw = Tunnel.arrowMaxWidth / 2
    let xp: [Int]
    let yp: [Int]
    switch facing {
    case .north:
      let yb = y0 + Tunnel.arrowDepth
      if x1 - x0 <= Tunnel.arrowMaxWidth {
        xp = [x0, 0, x1, x1, x0]
        yp = [yb, y0, yb, y1, y1]
      } else {
        xp = [x0, -mw, 0, mw, x1, x1, x0]
        yp = [yb, yb, y0, yb, yb, y1, y1]
      }
    case .south:
      let yb = y1 - Tunnel.arrowDepth
      if x1 - x0 <= Tunnel.arrowMaxWidth {
        xp = [x0, x1, x1, 0, x0]
        yp = [y0, y0, yb, y1, yb]
      } else {
        xp = [x0, x1, x1, mw, 0, -mw, x0]
        yp = [y0, y0, yb, yb, y1, yb, yb]
      }
    case .east:
      let xb = x1 - Tunnel.arrowDepth
      if y1 - y0 <= Tunnel.arrowMaxWidth {
        xp = [x0, xb, x1, xb, x0]
        yp = [y0, y0, 0, y1, y1]
      } else {
        xp = [x0, xb, xb, x1, xb, xb, x0]
        yp = [y0, y0, -mw, 0, mw, y1, y1]
      }
    case .west:
      let xb = x0 + Tunnel.arrowDepth
      if y1 - y0 <= Tunnel.arrowMaxWidth {
        xp = [xb, x1, x1, xb, x0]
        yp = [y0, y0, y1, y1, 0]
      } else {
        xp = [xb, x1, x1, xb, xb, x0, xb]
        yp = [y0, y0, y1, y1, mw, 0, -mw]
      }
    }
    g.strokeWidth = 2
    g.drawPolygon(xp, yp)
    g.font = savedFont
  }

  /// `paintInstance(InstancePainter)`.
  public func paintInstance(_ painter: InstancePainter) {
    let loc = painter.location
    let g = painter.g
    g.pushTranslate(loc.x, loc.y)
    g.color = painter.componentColor
    paintGhost(painter)
    g.popTransform()
    painter.drawPorts()
  }
}

extension Tunnel: InstancePaintable {}
extension Tunnel: InstanceLabelProvider {}
