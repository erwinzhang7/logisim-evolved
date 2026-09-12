// Negator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Negator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Fixed bounds, fixed ports, one attribute: the simplest arith shape after Adder itself.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Negator`.
public final class Negator: InstanceFactoryBase {

  /// `Negator._ID`. Do not change, `.circ` files reference it.
  public static let id = "Negator"

  public static let inPort = 0
  public static let outPort = 1

  public init() {
    super.init(Negator.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, StdAttr.width),  // IN
      Port(0, 0, .output, StdAttr.width),  // OUT
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)

    let inVal = state.portValue(Negator.inPort)
    var out: Value
    if inVal.isFullyDefined() {
      // Java: `Value.createKnown(in.getBitWidth(), -in.toLongValue())`. `-x` on a Java `long`
      // wraps at `Long.MIN_VALUE`; `Value.createKnown` masks the result back to width anyway,
      // so the wrap is unobservable, but `&-` is used for fidelity with the arith family's rule.
      out = Value.createKnown(try inVal.getBitWidth(), 0 &- inVal.toLongValue())
    } else {
      // Bit-serial two's-complement negation: copy bits below the lowest set bit unchanged,
      // keep the lowest set bit, then complement everything above it. `fill` tracks what an
      // as-yet-unresolved (X/E) low bit would propagate as, until the first genuine 1 is found.
      //
      // Deviation (mechanism): reference-identity comparisons against the one-bit singletons
      // (`Value.FALSE`/`TRUE`/`ERROR`) become structural `==`; safe per PATTERNS.md's
      // "Equality" note (width-1 values are always one of the four interned singletons).
      var bits = inVal.getAll()
      var fill: Value = .falseValue
      var pos = 0
      while pos < bits.count {
        if bits[pos] == .falseValue {
          bits[pos] = fill
        } else if bits[pos] == .trueValue {
          if fill != .falseValue { bits[pos] = fill }
          pos += 1
          break
        } else if bits[pos] == .errorValue {
          fill = .errorValue
        } else {
          if fill == .falseValue { fill = bits[pos] } else { bits[pos] = fill }
        }
        pos += 1
      }
      while pos < bits.count {
        if bits[pos] == .trueValue {
          bits[pos] = .falseValue
        } else if bits[pos] == .falseValue {
          bits[pos] = .trueValue
        }
        pos += 1
      }
      out = try Value.create(bits)
    }

    let delay = (dataWidth.width + 2) * Adder.perDelay
    state.setPort(Negator.outPort, out, delay)
  }

  // NOT PORTED: getHDLName (D11); returns "BitNegator" at width 1.

  /// Upstream never switches to the secondary colour here; the "-x" label is drawn in the
  /// primary colour, unlike `Adder`/`Subtractor`/etc.'s carry labels. Preserved.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    ArithPaint.drawPort(painter, state, Negator.inPort)
    ArithPaint.drawPort(painter, state, Negator.outPort, label: "-x", direction: .west)
  }
}
