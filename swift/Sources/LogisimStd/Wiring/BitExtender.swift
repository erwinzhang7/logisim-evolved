// BitExtender.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.BitExtender),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). `BitExtenderHdlGeneratorFactory.java` is the
// component's embedded HDL generator; per the task's HDL-stripping rule it is not ported.
//
// ── UPSTREAM BUG, PRESERVED: `setFacingAttribute` names an attribute the set does not carry ──
//
// Java's constructor calls `setFacingAttribute(StdAttr.FACING)`, but the three attributes
// actually registered (`ATTR_IN_WIDTH`, `ATTR_OUT_WIDTH`, `ATTR_TYPE`) do not include
// `StdAttr.FACING` at all; this component has no facing attribute in its `.circ`-serialised
// set, only a fixed, non-rotatable footprint (`setOffsetBounds`, unconditional). Declaring a
// facing attribute the set cannot answer is dead upstream (nothing calls
// `feature(FACING_ATTRIBUTE_KEY)` on a factory whose attribute set does not carry the answer
// without misbehaving), but it is exactly what Java does, so `setFacingAttribute` is called here
// too rather than "fixed" by omitting it.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `BitExtender.ATTR_TYPE`'s choice list, as the native-enum shape D5 prefers for new component
/// ports. Raw values are the exact `.circ` tokens (`Attributes.forOption("type", …)`'s choice
/// names), matching Java's declaration order (`zero, one, sign, input`).
public enum BitExtenderType: String, AttributeOptionValue, CaseIterable, Sendable {
  case zero, one, sign, input
}

/// `com.cburch.logisim.std.wiring.BitExtender`.
public final class BitExtender: InstanceFactoryBase {

  /// `BitExtender._ID`. Do not change, `.circ` files reference it.
  public static let id = "Bit Extender"

  /// `BitExtender.ATTR_IN_WIDTH`.
  private static let attrInWidth: Attribute<BitWidth> = Attributes.forBitWidth("in_width")
  /// `BitExtender.ATTR_OUT_WIDTH`.
  private static let attrOutWidth: Attribute<BitWidth> = Attributes.forBitWidth("out_width")
  /// `BitExtender.ATTR_TYPE`.
  static let attrType: Attribute<BitExtenderType> = Attributes.forOption("type")

  /// Java's `public static final BitExtender FACTORY = new BitExtender()`.
  public static let factory = BitExtender()

  public init() {
    super.init(BitExtender.id)
    setAttributes([
      BitExtender.attrInWidth.binding(BitWidth.known(8)),
      BitExtender.attrOutWidth.binding(BitWidth.known(16)),
      BitExtender.attrType.binding(.sign),
    ])
    // See the file header: kept even though FACING is not one of the three attributes above;
    // Java calls it unconditionally too.
    setFacingAttribute(StdAttr.facing)
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
  }

  /// `updatePorts(Instance)` (`BitExtender.java:85-94`), as a pure function of `attributes`
  /// (`PATTERNS.md` §0). Port 2 (the sign-select input) only exists when `ATTR_TYPE == input`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let type = attributes[BitExtender.attrType, default: .sign]
    var ports = [
      Port(0, 0, .output, BitExtender.attrOutWidth),
      Port(-40, 0, .input, BitExtender.attrInWidth),
    ]
    if type == .input {
      ports.append(Port(-20, -20, .input, 1))
    }
    return ports
  }

  /// `BitExtender.propagate(InstanceState)` (`:145-167`).
  public override func propagate(_ state: any InstanceState) throws {
    let inValue = state.portValue(1)
    let outWidth = state.attributeValue(BitExtender.attrOutWidth, default: .one)
    let type = state.attributeValue(BitExtender.attrType, default: .sign)

    let extend: Value
    switch type {
    case .one:
      extend = .trueValue
    case .sign:
      let inWidth = inValue.width
      extend = inWidth > 0 ? inValue.get(inWidth - 1) : .errorValue
    case .input:
      let selector = state.portValue(2)
      extend = selector.width != 1 ? .errorValue : selector
    case .zero:
      extend = .falseValue
    }

    let out = inValue.extendWidth(outWidth.width, extend)
    state.setPort(0, out, 1)
  }

  // NOT PORTED: `instanceAttributeChanged`; Java's only branch (`ATTR_TYPE` -> recompute ports)
  // plus the unconditional `fireInvalidated()` are both automatic under this chassis: `ports(_:)`
  // is already recomputed and diffed on every attribute write (`PATTERNS.md` §0), and a repaint
  // request is M6.
  //
  // MARK: Painting (BitExtender.java:112-143)

  /// `paintInstance(InstancePainter)`.
  ///
  /// The two label baselines are `(h/2 + asc)/2` and `(3h/2 + asc)/2` from the top, thirds of
  /// the box biased by the ascent, not halves, so the pair stays optically centred at any
  /// font size. `asc` is read once, before anything is drawn, exactly as upstream reads it.
  ///
  /// The two localised strings are inlined at their English values (D5's precedent):
  /// `extenderZeroLabel = 0`, `extenderOneLabel = 1`, `extenderSignLabel = sign`,
  /// `extenderInputLabel = input`, `extenderMainLabel = extend`.
  public func paintInstance(_ painter: InstancePainter) {
    let g = painter.g
    let fm = g.fontMetrics()
    let asc = fm.ascent

    g.color = painter.componentColor
    painter.drawBounds()

    let type = painter.attributeValue(BitExtender.attrType, default: .sign)
    let s0: String
    switch type {
    case .zero: s0 = "0"
    case .one: s0 = "1"
    case .sign: s0 = "sign"
    case .input: s0 = "input"
    }
    let s1 = "extend"
    let bds = painter.bounds
    let x = bds.x + bds.width / 2
    let y0 = bds.y + (bds.height / 2 + asc) / 2
    let y1 = bds.y + (3 * bds.height / 2 + asc) / 2
    g.drawText(s0, x: x, y: y0, halign: .center, valign: .baseline)
    g.drawText(s1, x: x, y: y1, halign: .center, valign: .baseline)

    let w0 = painter.attributeValue(BitExtender.attrOutWidth, default: BitWidth.known(16))
    let w1 = painter.attributeValue(BitExtender.attrInWidth, default: BitWidth.known(8))
    painter.drawPort(0, "\(w0.width)", .west)
    painter.drawPort(1, "\(w1.width)", .east)
    if type == .input { painter.drawPort(2) }
  }
}

extension BitExtender: InstancePaintable {}
