// Comparator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Comparator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Fixed bounds, fixed ports, one bespoke `AttributeOption` pair (`MODE_ATTR`). `Multiplier` and
// `Divider` both read `Comparator.modeAttr`/`unsignedOption` directly, exactly as the Java does
// via `Comparator.MODE_ATTR`/`UNSIGNED_OPTION`; kept public for that cross-reference.
//
// Deviation (mechanism): Java's `AttributeOption` equality inside `propagate` is reference
// comparison (`mode != UNSIGNED_OPTION`); this port's `AttributeOption` is a plain `Hashable`
// struct, so the comparison is structural. Safe here because the file defines exactly two
// options with distinct `name`s and never constructs a third: see PATTERNS.md's "Equality"
// section.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Comparator`.
public final class Comparator: InstanceFactoryBase {

  /// `Comparator._ID`. Do not change, `.circ` files reference it.
  public static let id = "Comparator"

  /// `Comparator.SIGNED_OPTION`: `new AttributeOption("twosComplement", "twosComplement", …)`.
  /// Java's 3-arg constructor passes the same string as both `value` and the serialised `name`;
  /// only `name` (what `.circ` stores and what `==`/`toString` use) matters here.
  public static let signedOption = AttributeOption(name: "twosComplement")
  /// `Comparator.UNSIGNED_OPTION`.
  public static let unsignedOption = AttributeOption(name: "unsigned")
  /// `Comparator.MODE_ATTR`.
  public static let modeAttr: Attribute<AttributeOption> = Attributes.forOption(
    "mode", choices: [signedOption, unsignedOption])

  // Port indices, kept named per the arith-family convention.
  public static let in0 = 0
  public static let in1 = 1
  public static let gt = 2
  public static let eq = 3
  public static let lt = 4

  public init() {
    super.init(Comparator.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Comparator.modeAttr.binding(Comparator.signedOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0
      Port(-40, 10, .input, StdAttr.width),  // IN1
      Port(0, -10, .output, 1),  // GT
      Port(0, 0, .output, 1),  // EQ
      Port(0, 10, .output, 1),  // LT
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .known(8))

    var gt: Value = .falseValue
    var eq: Value = .trueValue
    var lt: Value = .falseValue

    let a = state.portValue(Comparator.in0)
    let b = state.portValue(Comparator.in1)
    let ax = a.getAll()
    let bx = b.getAll()
    let maxlen = max(ax.count, bx.count)

    var pos = maxlen - 1
    while pos >= 0 {
      var ab = pos < ax.count ? ax[pos] : .errorValue
      var bb = pos < bx.count ? bx[pos] : .errorValue

      // Only the position at a's own MSB is candidate for the sign swap; note this reads
      // `ax.count`, not `bx.count`, exactly as upstream; the two only differ for a malformed
      // circuit connecting mismatched-width wires to IN0/IN1.
      if pos == ax.count - 1 && ab != bb {
        let mode = state.attributeValue(Comparator.modeAttr, default: Comparator.signedOption)
        if mode != Comparator.unsignedOption {
          swap(&ab, &bb)
        }
      }

      if ab == .errorValue || bb == .errorValue {
        gt = .errorValue
        eq = .errorValue
        lt = .errorValue
        break
      } else if ab == .unknownValue || bb == .unknownValue {
        gt = .unknownValue
        eq = .unknownValue
        lt = .unknownValue
        break
      } else if ab != bb {
        eq = .falseValue
        if ab == .trueValue { gt = .trueValue } else { lt = .trueValue }
        break
      }
      pos -= 1
    }

    let delay = (dataWidth.width + 2) * Adder.perDelay
    state.setPort(Comparator.gt, gt, delay)
    state.setPort(Comparator.eq, eq, delay)
    state.setPort(Comparator.lt, lt, delay)
  }

  // NOT PORTED: getHDLName (D11); returns "BitComparator" at width 1.

  /// Unlike the other arith glyphs, upstream never switches to the secondary colour here: the
  /// bounds box, the ports, and the ">"/"="/"<" labels are all drawn in the primary colour.
  /// Preserved, not "fixed".
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawPort(painter, state, Comparator.in0)
    ArithPaint.drawPort(painter, state, Comparator.in1)
    ArithPaint.drawPort(painter, state, Comparator.gt, label: ">", direction: .west)
    ArithPaint.drawPort(painter, state, Comparator.eq, label: "=", direction: .west)
    ArithPaint.drawPort(painter, state, Comparator.lt, label: "<", direction: .west)
  }
}
