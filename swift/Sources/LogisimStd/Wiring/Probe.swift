// Probe.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Probe),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What a Probe is ─────────────────────────────────────────────────────────────────────────
//
// A read-only display: one input port, no output, and a `propagate` that stores the incoming
// value and, uniquely among stock components, **mutates its own attribute set** when the
// incoming width changes, so the component resizes itself to fit whatever bus it is attached to.
// That write is the reason `ProbeAttributes` carries a `width` field that is not an attribute.
//
// ── `getOffsetBounds` is shared with `Pin`, and that is load-bearing ────────────────────────
//
// `Probe.getOffsetBounds(dir, width, radix, newLayout, isPin)` is a `static` that `Pin`,
// `ProgrammableGenerator` and `Probe` itself all call. Its output is the component's bounds,
// which decide hit-testing, wire attachment geometry and every placement in a saved circuit, so
// the constants below are transcribed literally, including the `x`-as-scratch-variable swap in
// the NORTH/SOUTH branches.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `implements DynamicElementProvider` / `createDynamicElement` → `new ProbeShape(x, y, path)`.
//     That is the circuit-*appearance* editor (`circuit.appear.DynamicElement`), a separate
//     subsystem no slice of this port owns yet. Reported in the final output.
//   * `isHDLSupportedComponent`; HDL generation is stripped from this port.
//   * `setIconName("probe.gif")`, `setKeyConfigurator(new DirectionConfigurator(…))`; UI.
//   * `instanceAttributeChanged`; every branch is `recomputeBounds()` +
//     `computeLabelTextField(...)`, both of which the chassis does automatically (bounds are
//     derived from `offsetBounds(attributes)` on demand) or defers to M6 (label layout). See
//     `PATTERNS.md` §0.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Probe`.
public final class Probe: InstanceFactoryBase {

  /// `Probe._ID`. Do not change, `.circ` files reference it.
  public static let id = "Probe"

  /// Java's `public static final Probe FACTORY = new Probe()`.
  public static let factory = Probe()

  public init() {
    super.init(Probe.id)
    setFacingAttribute(StdAttr.facing)
    // No `setAttributes`: `createAttributeSet()` builds a bespoke `ProbeAttributes`, which is
    // upstream's `attrs == null` state. See `Constant.swift` for why the template must stay
    // empty when that is so.
  }

  // MARK: State

  /// `Probe.StateData`: the last value seen on the input port.
  final class StateData: InstanceData {
    /// `Value curValue = Value.NIL`.
    var curValue: Value = .nilValue

    init() {}

    func cloneData() -> any InstanceData {
      let copy = StateData()
      copy.curValue = curValue
      return copy
    }
  }

  /// `Probe.getValue(InstanceState)`. `NIL` before the first propagation.
  public static func getValue(_ state: any InstanceState) -> Value {
    (state.data as? StateData)?.curValue ?? .nilValue
  }

  // MARK: Geometry

  /// `Probe.getOffsetBounds(Direction, BitWidth, RadixOption, boolean NewLayout, boolean IsPin)`.
  ///
  /// Shared by `Probe`, `Pin` and `ProgrammableGenerator`. `radix` is optional because upstream
  /// guards with `radix == null || radix == RADIX_2`, and callers really do pass null (a
  /// component whose attribute set has no radix attribute).
  ///
  /// Shape, in order:
  ///   1. `len`; how many characters the value occupies. Binary counts *bits*, not the grouped
  ///      string `RadixOption.RADIX_2.getMaxLength` would return, so the two disagree here on
  ///      purpose.
  ///   2. binary lays out up to 8 bits per row and up to 8 rows, at 10×20 px per cell; every
  ///      other radix is one row of `len` × `Pin.DIGIT_WIDTH`.
  ///   3. the new-pins layout adds a fixed 20 (single bit) or 25 (anything wider) for the arrow
  ///      and the radix index character.
  ///   4. the width is rounded *up* to a multiple of 10 so the component still lands on the grid.
  ///   5. the origin is placed so that the port sits at (0, 0).
  public static func getOffsetBounds(
    _ dir: Direction,
    _ width: BitWidth,
    _ radix: RadixOption?,
    _ newLayout: Bool,
    _ isPin: Bool
  ) -> Bounds {
    let len =
      (radix == nil || radix == .radix2)
      ? width.width
      : radix!.maxLength(width)
    var bwidth: Int
    var bheight: Int
    var x: Int
    var y: Int
    if radix == .radix2 {
      let maxBitsPerRow = 8
      let maxRows = 8
      var rows = len / maxBitsPerRow
      if len > rows * maxBitsPerRow { rows += 1 }
      bwidth = (len < 2) ? 20 : (len >= maxBitsPerRow) ? maxBitsPerRow * 10 : len * 10
      bheight = (rows < 2) ? 20 : (rows >= maxRows) ? maxRows * 20 : rows * 20
    } else {
      // Note this arm is also taken when `radix == nil`, where `len` was computed as the *bit*
      // count above, so a null radix is laid out as a single row of `width` digits.
      if len < 2 {
        bwidth = 20
      } else {
        bwidth = len * Pin.digitWidth
      }
      bheight = 20
    }
    if newLayout { bwidth += (len == 1) ? 20 : 25 }
    bwidth = ((bwidth + 9) / 10) * 10
    if dir == .east {
      x = -bwidth
      y = -(bheight / 2)
    } else if dir == .west {
      x = 0
      y = -(bheight / 2)
    } else if dir == .south {
      // `x` is reused as a scratch register to swap width and height, then immediately
      // overwritten. Transcribed exactly; the swap happens only for a *pin* in the new layout,
      // because only then is the body drawn rotated.
      if newLayout && isPin {
        x = bwidth
        bwidth = bheight
        bheight = x
      }
      x = -(bwidth / 2)
      y = -bheight
    } else {
      if newLayout && isPin {
        x = bwidth
        bwidth = bheight
        bheight = x
      }
      x = -(bwidth / 2)
      y = 0
    }
    return Bounds.create(x, y, bwidth, bheight)
  }

  // MARK: InstanceFactory

  /// `createAttributeSet()`.
  ///
  /// Upstream builds the set and then calls
  /// `attrs.setValue(PROBEAPPEARANCE, getDefaultProbeAppearance())`. That write cannot fail (the
  /// value is one of the attribute's own two options) and cannot be observed (the set has no
  /// listeners yet), and `createAttributeSet` is not allowed to throw, so it is folded into a
  /// direct field assignment.
  ///
  /// **This is not the same as `Pin.createAttributeSet()`**, which does *not* do this; see the
  /// header of `ProbeAttributes.swift` for why that asymmetry is what puts `<tool name="Pin">`
  /// blocks into saved files.
  public override func createAttributeSet() -> any AttributeSet {
    let attrs = ProbeAttributes()
    attrs.appearance = ProbeAttributes.defaultProbeAppearance
    return attrs
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is ProbeAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Probe.id)
    }
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// The appearance default comes from the preference, not from the attribute set, which is
  /// exactly the disagreement that makes the attribute serialize. Everything else falls through
  /// to the cached-clone behaviour in `AbstractComponentFactory`.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === ProbeAttributes.probeAppearance {
      return ProbeAttributes.probeAppearance.encode(ProbeAttributes.defaultProbeAppearance)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Note `isPin: false`, so a Probe never gets the NORTH/SOUTH width/height swap however it is
  /// facing.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let attrs = attributes as? ProbeAttributes else { return .empty }
    return Probe.getOffsetBounds(
      attrs.facing,
      attrs.width,
      attrs.radix,
      attrs.appearance == ProbeAttributes.appearEvolutionNew,
      false)
  }

  /// `configureNewInstance`'s `instance.setPorts(new Port[] {new Port(0, 0, Port.INPUT,
  /// BitWidth.UNKNOWN)})`.
  ///
  /// `BitWidth.UNKNOWN` (width 0) means "accept whatever arrives": the probe adapts instead of
  /// constraining the net.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    [Port(0, 0, .input, BitWidth.unknown)]
  }

  /// `propagate(InstanceState)`.
  ///
  /// The only stock component that writes its own attribute set from `propagate`. `attrs.width`
  /// is the private `ProbeAttributes` field, not `StdAttr.WIDTH` (which a `ProbeAttributes` does
  /// not carry), so nothing is serialized and no attribute event fires; the width is pure
  /// display state that happens to live on the attribute object.
  public override func propagate(_ state: any InstanceState) throws {
    let oldData = state.data as? StateData
    let oldValue = oldData?.curValue ?? .nilValue
    let newValue = state.portValue(0)
    // `Objects.equals(oldValue, newValue)`: `Value.equals` compares width and the three bit
    // planes, which is what the Swift `==` does.
    let same = oldValue == newValue
    if !same {
      if let oldData {
        oldData.curValue = newValue
      } else {
        let fresh = StateData()
        fresh.curValue = newValue
        state.setData(fresh)
      }
      // `oldValue == null ? 1 : …` is dead; `oldValue` is `Value.NIL` (width 0) when there was
      // no data, never null. Transcribed as the live branch only.
      let oldWidth = try oldValue.getBitWidth().width
      let newWidth = try newValue.getBitWidth().width
      if oldWidth != newWidth {
        if let attrs = state.attributeSet as? ProbeAttributes {
          attrs.width = try newValue.getBitWidth()
        }
        // `state.getInstance().recomputeBounds()` is automatic here; it is a pure
        // `bounds = factory.getOffsetBounds(attrs).translate(loc)` assignment upstream
        // (`InstanceComponent.java:419-422`) that fires *nothing*, and this port derives bounds
        // from `offsetBounds(attributes)` on demand. `computeLabelTextField(AVOID_LEFT)` is label
        // layout, M6. Deliberately no `fireInvalidated()` here: upstream does not, and adding one
        // would put an extra repaint request on the propagation path.
      }
    }
  }

  // MARK: Logger

  /// `Probe.ProbeLogger`: the value-log window's view of a probe.
  ///
  /// Ported as plain functions rather than a class: upstream's `InstanceLogger` is instantiated
  /// reflectively from a `Class<?>` (`setInstanceLogger(ProbeLogger.class)`), which has no AOT
  /// Swift equivalent, and the logging window is M6+ work.
  public enum Logger {
    /// `getLogName(InstanceState, Object)`: the label, or `null` when there is none, which the
    /// log window renders as the component's position instead.
    public static func logName(_ state: any InstanceState) -> String? {
      let ret = state.attributeValue(StdAttr.label)
      return (ret != nil && ret != "") ? ret : nil
    }

    /// `getBitWidth(InstanceState, Object)`: the *cached* width, not `StdAttr.WIDTH`.
    public static func bitWidth(_ state: any InstanceState) -> BitWidth {
      (state.attributeSet as? ProbeAttributes)?.width ?? .one
    }

    /// `getLogValue(InstanceState, Object)`.
    public static func logValue(_ state: any InstanceState) -> Value {
      Probe.getValue(state)
    }
  }

  // MARK: Painting (Probe.java:137-271, 331-380)
  //
  // `paintValue` and `paintOldStyleValue` are **shared with `Pin`**: Java declares them
  // package-private on `Probe` and `Pin.drawInputShape`/`drawOutputShape` call straight into
  // them. They stay here for the same reason: the value rendering is the probe's, and a pin
  // that shows a value is showing a probe's.

  /// `Probe.paintOldStyleValue(InstancePainter, Value)`; the classic appearance.
  ///
  /// Binary lays the bits out **right to left, bottom row up**, eight per row, stepping 10 left
  /// per bit and 14 up per row. A zero-width value (nothing connected) draws a short dash
  /// instead, which is how an unconnected probe reads as "no bits" rather than "zero".
  ///
  /// `compWidth < bds.width - 3` recentres a value narrower than its box; otherwise the bits
  /// are flushed right. The `- 5` is the half-cell offset to the first glyph's centre.
  static func paintOldStyleValue(_ painter: InstancePainter, _ value: Value) {
    let g = painter.g
    let bds = painter.bounds  // intentionally without the label

    let radix = painter.attributeValue(RadixOption.attribute, default: .radix2)
    if radix == .radix2 {
      var x = bds.x
      var y = bds.y
      let wid = value.width
      if wid == 0 {
        x += bds.width / 2
        y += bds.height / 2
        g.strokeWidth = 2
        g.drawLine(x - 4, y, x + 4, y)
        return
      }
      var x0 = bds.x + bds.width - 5
      let compWidth = wid * 10
      if compWidth < bds.width - 3 {
        x0 = bds.x + (bds.width + compWidth) / 2 - 5
      }
      var cx = x0
      var cy = bds.y + bds.height - 10
      var cur = 0
      for k in 0..<wid {
        g.drawCenteredText(value.get(k).toDisplayString(), x: cx, y: cy)
        cur += 1
        if cur == 8 {
          cur = 0
          cx = x0
          cy -= 14
        } else {
          cx -= 10
        }
      }
    } else {
      let text = radix.toString(value)
      g.drawCenteredText(text, x: bds.x + bds.width / 2, y: bds.y + bds.height / 2 - 2)
    }
  }

  /// `Probe.paintValue(InstancePainter, Value)`, the two-appearance dispatcher.
  static func paintValue(_ painter: InstancePainter, _ value: Value) {
    if painter.attributeValue(ProbeAttributes.probeAppearance)
      == ProbeAttributes.appearEvolutionNew
    {
      paintValue(painter, value, colored: false)
    } else {
      paintOldStyleValue(painter, value)
    }
  }

  /// `Probe.paintValue(InstancePainter, Value, boolean colored)`.
  ///
  /// Three things here are worth stating plainly, because they are the parts most likely to
  /// drift:
  ///
  ///   * **The `colored` argument only matters on the classic appearance.** With
  ///     `colored == true` (which only `Pin` passes, for an *input* pin) the single bit is
  ///     drawn as a filled oval in the value's colour with a white glyph on top; with
  ///     `colored == false` this delegates to `paintOldStyleValue` and returns.
  ///   * **The radix index character is drawn at 0.7 scale**, in blue, with its position
  ///     divided by 0.7 so that it lands where the unscaled coordinates say. That is the only
  ///     non-integral transform in the whole wiring family.
  ///   * **Non-binary radices are drawn one glyph at a time, right to left**, stepping
  ///     `Pin.DIGIT_WIDTH`, rather than as one string: so the digits align on a fixed pitch
  ///     regardless of the font's advance widths.
  ///
  /// Upstream's `GraphicsUtil.H_CENTER` in the last `drawText`'s *vertical* slot is preserved:
  /// `H_CENTER` and `V_CENTER` are both `0`, so it is a harmless naming slip and the alignment
  /// is centre either way.
  static func paintValue(_ painter: InstancePainter, _ value: Value, colored: Bool) {
    let g = painter.g
    let bds = painter.bounds  // intentionally without the label
    let savedFont = g.font
    g.font = Pin.defaultFont
    defer { g.font = savedFont }

    let isOutput =
      painter.attributeSet.containsAttribute(Pin.attrType)
      ? painter.attributeValue(Pin.attrType) == Pin.output
      : false

    if painter.attributeValue(ProbeAttributes.probeAppearance)
      != ProbeAttributes.appearEvolutionNew
    {
      if colored {
        let x = bds.x
        let y = bds.y
        if !isOutput {
          g.color = painter.color(of: value.get(0))
          g.fillOval(x + 5, y + 4, 11, 13)
          g.color = .white
        }
        g.drawCenteredText(value.get(0).toDisplayString(), x: x + 10, y: y + 9)
      } else {
        paintOldStyleValue(painter, value)
      }
      return
    }

    let radix = painter.attributeValue(RadixOption.attribute, default: .radix2)
    var labelValueXOffset = 15
    if radix != .radix2 { labelValueXOffset += 3 }
    g.color = .rgba(.blue)
    g.pushScale(0.7, 0.7)
    g.drawString(
      radix.indexChar,
      x: Int(Double(bds.x + bds.width - labelValueXOffset) / 0.7),
      y: Int(Double(bds.y + bds.height - 2) / 0.7))
    g.popTransform()
    g.color = .black
    if radix == .radix2 {
      var x = bds.x
      var y = bds.y
      let wid = value.width
      if wid == 0 {
        x += bds.width / 2
        y += bds.height / 2
        g.strokeWidth = 2
        g.drawLine(x - 4, y, x + 4, y)
        return
      }
      let yoffset = 12
      let x0 = bds.x + bds.width - 20
      var cx = x0
      var cy = bds.y + bds.height - yoffset
      var cur = 0
      for k in 0..<wid {
        g.drawCenteredText(value.get(k).toDisplayString(), x: cx, y: cy)
        cur += 1
        if cur == 8 {
          cur = 0
          cx = x0
          cy -= 20
        } else {
          cx -= 10
        }
      }
    } else {
      let text = radix.toString(value)
      var cx = bds.x + bds.width - labelValueXOffset - 2
      for ch in text.reversed() {
        g.drawText(
          String(ch), x: cx, y: bds.y + bds.height / 2 - 1, halign: .right, valign: .center)
        cx -= Pin.digitWidth
      }
    }
  }

  /// `Instance.computeLabelTextField(AVOID_LEFT)`, Probe.java:284.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }

  /// `paintGhost(InstancePainter)`: a bare oval over the offset bounds.
  ///
  /// Note the asymmetry with `paintInstance`, which insets by 1 on each side (`width - 2`);
  /// this one insets only the origin (`width - 1`), so a ghost is a pixel wider than the
  /// component it becomes. Upstream, verbatim.
  public func paintGhost(_ painter: InstancePainter) {
    let bds = painter.offsetBounds
    painter.g.drawOval(bds.x + 1, bds.y + 1, bds.width - 1, bds.height - 1)
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// The pale-yellow body is `0xFFF099`. A one-bit probe is an oval, a bus is a round rect with
  /// a 20-diameter arc; both are outlined in light grey. When state is not being shown the
  /// probe reads `x<width>` instead of a value, which is what a printed schematic shows.
  public func paintInstance(_ painter: InstancePainter) {
    let value = Probe.getValueForPaint(painter)

    let g = painter.g
    let bds = painter.bounds  // intentionally without the label
    let x = bds.x
    let y = bds.y
    let back = SceneColor.rgba(RGBA(r: 0xFF, g: 0xF0, b: 0x99))
    if value.width <= 1 {
      g.color = back
      g.fillOval(x + 1, y + 1, bds.width - 2, bds.height - 2)
      g.color = .rgba(.lightGray)
      g.drawOval(x + 1, y + 1, bds.width - 2, bds.height - 2)
    } else {
      g.color = back
      g.fillRoundRect(x + 1, y + 1, bds.width - 2, bds.height - 2, 20, 20)
      g.color = .rgba(.lightGray)
      g.drawRoundRect(x + 1, y + 1, bds.width - 2, bds.height - 2, 20, 20)
    }

    g.color = .rgba(.gray)
    painter.drawLabel()
    g.color = .rgba(RGBA(javaRGB: 0x40_4040))  // Color.DARK_GRAY

    if !painter.showState {
      if value.width > 0 {
        g.drawCenteredText(
          "x\(value.width)", x: bds.x + bds.width / 2, y: bds.y + bds.height / 2)
      }
    } else {
      Probe.paintValue(painter, value)
    }

    painter.drawPorts()
  }

  /// `Probe.getValue(InstanceState)` reached through a painter. Java shares one method because
  /// `InstancePainter implements InstanceState`; see `Transistor.paintOutput` for why this port
  /// splits them.
  static func getValueForPaint(_ painter: InstancePainter) -> Value {
    (painter.data as? StateData)?.curValue ?? .nilValue
  }
}

extension Probe: InstancePaintable {}
extension Probe: InstanceLabelProvider {}
