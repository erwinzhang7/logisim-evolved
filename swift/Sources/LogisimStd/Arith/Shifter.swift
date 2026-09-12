// Shifter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Shifter),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Fixed bounds, computed ports (the distance port's width tracks the data width), one bespoke
// `AttributeOption` pick-one attribute (`ATTR_SHIFT`).
//
// NOT PORTED: `SHIFT_BITS_ATTR` (`Attributes.forNoSave()`). Upstream writes the computed
// distance-port width into it from `configurePorts` purely so `ShifterHdlGeneratorFactory` can
// read it back later; nothing in propagation or the port list consults it (`configurePorts`
// recomputes `shift` locally every time). Since HDL generation is out of scope for this port
// (per the porting brief) and the chassis's `ports(_:)` is a pure function of the attribute set
// with no side channel to stash a value in anyway, the attribute has no remaining consumer.
// Dropping it changes nothing observable: it was never persisted (`forNoSave`) and never read
// by anything this module implements.
//
// Bound used throughout `computeOutput`, argued once here rather than at every shift site:
// `shift` (the distance port's width) is defined as the smallest integer with `2^shift >= data`,
// starting from `shift = 1`. Since `data` (the WIDTH attribute) is always `<= 64` (`BitWidth`'s
// own ceiling), `shift <= 6` always (`2^6 = 64` already covers every possible `data`), so the
// distance value `d` read off that port is always in `0...63`. Every native Swift `<<`/`>>` below
// operates on a `d` already in that range (after the branch-specific clamps upstream applies,
// which only ever *reduce* `d`), so Swift's smart-shift and Java's shift-distance-mod-64 masking
// agree everywhere in this file and no `JavaBits` helper is needed.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Shifter`.
public final class Shifter: InstanceFactoryBase {

  /// `Shifter._ID`. Do not change, `.circ` files reference it.
  public static let id = "Shifter"

  /// `Shifter.SHIFT_LOGICAL_LEFT`: `new AttributeOption("ll", …)`. Only `name` matters here
  /// (D5: localisation is UI).
  public static let shiftLogicalLeft = AttributeOption(name: "ll")
  /// `Shifter.SHIFT_LOGICAL_RIGHT`.
  public static let shiftLogicalRight = AttributeOption(name: "lr")
  /// `Shifter.SHIFT_ARITHMETIC_RIGHT`.
  public static let shiftArithmeticRight = AttributeOption(name: "ar")
  /// `Shifter.SHIFT_ROLL_LEFT`.
  public static let shiftRollLeft = AttributeOption(name: "rl")
  /// `Shifter.SHIFT_ROLL_RIGHT`.
  public static let shiftRollRight = AttributeOption(name: "rr")
  /// `Shifter.ATTR_SHIFT`.
  public static let attrShift: Attribute<AttributeOption> = Attributes.forOption(
    "shift",
    choices: [
      shiftLogicalLeft, shiftLogicalRight, shiftArithmeticRight, shiftRollLeft, shiftRollRight,
    ])

  // Port indices, kept named per the arith-family convention.
  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2

  public init() {
    super.init(Shifter.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Shifter.attrShift.binding(Shifter.shiftLogicalLeft),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
  }

  /// `configurePorts(Instance)`. Ports are attribute-dependent (the distance port's width
  /// tracks the data width), so this is `ports(_:)` rather than a fixed `setPorts` call.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    // Java: `dataWid == null ? 32 : dataWid.getWidth()`. The null case cannot arise once the
    // attribute set is constructed from `attributeTemplate` above, but the fallback is kept for
    // fidelity: same convention as the rest of this family (see `Adder`'s `default: .one`).
    let data = attributes.getValue(StdAttr.width)?.width ?? 32
    var shift = 1
    while (1 << shift) < data { shift += 1 }

    return [
      Port(-40, -10, .input, data),  // IN0
      Port(-40, 10, .input, shift),  // IN1 (shift distance)
      Port(0, 0, .output, data),  // OUT
    ]
  }

  /// Java `arraycopy`-style bulk copy between two distinct `[Value]` arrays. Every call site in
  /// `computeOutput` copies between `x` (`vx.getAll()`) and a freshly allocated `y`, which never
  /// alias, so a plain element-wise loop reproduces `System.arraycopy` exactly (no overlap to
  /// worry about, unlike `memmove`).
  private static func arraycopy(
    _ src: [Value], _ srcPos: Int, _ dst: inout [Value], _ dstPos: Int, _ length: Int
  ) {
    guard length > 0 else { return }
    for i in 0..<length { dst[dstPos + i] = src[srcPos + i] }
  }

  /// The whole of `propagate`'s output computation. Upstream inlines this; a static function
  /// keeps `propagate` itself to the port plumbing, matching the rest of the family.
  ///
  /// D13: `Value.create([Value])` throws, so this throws.
  static func computeOutput(
    _ width: BitWidth, _ vx: Value, _ vd: Value, _ shiftMode: AttributeOption
  ) throws -> Value {
    let bits = width.width

    guard vd.isFullyDefined(), vx.width == bits else {
      return Value.createError(width)
    }
    let d = Int(vd.toLongValue())

    if d == 0 {
      return vx
    }

    if vx.isFullyDefined() {
      let x = vx.toLongValue()
      let y: Int64
      switch shiftMode {
      case Shifter.shiftLogicalRight:
        // `x >>> d`, unsigned right shift.
        y = Int64(bitPattern: UInt64(bitPattern: x) >> UInt64(d))
      case Shifter.shiftArithmeticRight:
        var dd = d
        if dd >= bits { dd = bits - 1 }
        y = (x >> Int64(dd)) | ((x << Int64(64 - bits)) >> Int64(64 - bits + dd))
      case Shifter.shiftRollRight:
        var dd = d
        if dd >= bits { dd -= bits }
        y =
          Int64(bitPattern: UInt64(bitPattern: x) >> UInt64(dd)) | (x << Int64(bits - dd))
      case Shifter.shiftRollLeft:
        var dd = d
        if dd >= bits { dd -= bits }
        y =
          (x << Int64(dd)) | Int64(bitPattern: UInt64(bitPattern: x) >> UInt64(bits - dd))
      default:  // shiftLogicalLeft
        y = x << Int64(d)
      }
      return Value.createKnown(width, y)
    }

    // Bit-serial fallback: `vx` carries at least one X/E bit.
    let x = vx.getAll()
    var y = [Value](repeating: .falseValue, count: bits)
    switch shiftMode {
    case Shifter.shiftLogicalRight:
      var dd = d
      if dd >= bits { dd = bits }
      arraycopy(x, dd, &y, 0, bits - dd)
      // `Arrays.fill(y, bits - d, bits, Value.FALSE)`; `y` is already false-initialised.
    case Shifter.shiftArithmeticRight:
      var dd = d
      if dd >= bits { dd = bits }
      arraycopy(x, dd, &y, 0, bits - dd)  // Java: `x.length - d`; `x.length == bits` here.
      let signBit = x[bits - 1]
      for i in (bits - dd)..<bits { y[i] = signBit }
    case Shifter.shiftRollRight:
      var dd = d
      if dd >= bits { dd -= bits }
      arraycopy(x, dd, &y, 0, bits - dd)
      arraycopy(x, 0, &y, bits - dd, dd)
    case Shifter.shiftRollLeft:
      var dd = d
      if dd >= bits { dd -= bits }
      arraycopy(x, bits - dd, &y, 0, dd)  // Java: `x.length - d`.
      arraycopy(x, 0, &y, dd, bits - dd)
    default:  // shiftLogicalLeft
      var dd = d
      if dd >= bits { dd = bits }
      for i in 0..<dd { y[i] = .falseValue }
      arraycopy(x, 0, &y, dd, bits - dd)
    }
    return try Value.create(y)
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)
    let shiftMode = state.attributeValue(Shifter.attrShift, default: Shifter.shiftLogicalLeft)

    let vx = state.portValue(Shifter.in0)
    let vd = state.portValue(Shifter.in1)
    let vy = try Shifter.computeOutput(dataWidth, vx, vd, shiftMode)

    let delay = dataWidth.width * (3 * Adder.perDelay)
    state.setPort(Shifter.out, vy, delay)
  }

  // NOT PORTED: getHDLName (D11); returns "Shifter_<width>_bit".

  /// `drawArrow(Graphics, int, int, int)`: a filled triangle pointing in the shift direction.
  private func drawArrow(_ painter: SceneBuilder, x: Int, y: Int, d: Int) {
    painter.color = ArithPaint.componentColor
    painter.fillPolygon([x + d, x, x + d], [y + d, y, y - d])
  }

  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawAllPorts(painter, state)

    let loc = state.component.location
    let x = loc.x - 15
    let y = loc.y
    let shift = state.attributeValue(Shifter.attrShift, default: Shifter.shiftLogicalLeft)
    painter.color = ArithPaint.componentColor
    switch shift {
    case Shifter.shiftLogicalRight:
      painter.fillRect(x, y - 1, 8, 3)
      drawArrow(painter, x: x + 10, y: y, d: -4)
    case Shifter.shiftArithmeticRight:
      painter.fillRect(x, y - 1, 2, 3)
      painter.fillRect(x + 3, y - 1, 5, 3)
      drawArrow(painter, x: x + 10, y: y, d: -4)
    case Shifter.shiftRollRight:
      painter.fillRect(x, y - 1, 5, 3)
      painter.fillRect(x + 8, y - 7, 2, 8)
      painter.fillRect(x, y - 7, 2, 8)
      painter.fillRect(x, y - 7, 10, 2)
      drawArrow(painter, x: x + 8, y: y, d: -4)
    case Shifter.shiftRollLeft:
      painter.fillRect(x + 6, y - 1, 4, 3)
      painter.fillRect(x + 8, y - 7, 2, 8)
      painter.fillRect(x, y - 7, 2, 8)
      painter.fillRect(x, y - 7, 10, 2)
      drawArrow(painter, x: x + 3, y: y, d: 4)
    default:  // shiftLogicalLeft
      painter.fillRect(x + 2, y - 1, 8, 3)
      drawArrow(painter, x: x, y: y, d: 4)
    }
  }
}
