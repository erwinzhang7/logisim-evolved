// Adder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Adder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The arithmetic template, and the simplest chassis shape in the module: fixed bounds, fixed
// ports, one attribute. The interesting part is entirely inside `computeSum`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Adder`.
public final class Adder: InstanceFactoryBase {

  /// `Adder._ID`. Do not change, `.circ` files reference it.
  public static let id = "Adder"

  /// `PER_DELAY`. The propagation delay is `(width + 2) * PER_DELAY`, i.e. a ripple-carry model.
  static let perDelay = 1

  // Port indices. Upstream names them, and the names are worth keeping: `propagate` is unreadable
  // with bare integers and the whole arith family follows this convention.
  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let cIn = 3
  public static let cOut = 4

  public init() {
    super.init(Adder.id)
    // Java: `BitWidth.create(8)`: a literal, so the non-throwing `known` (D13).
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0
      Port(-40, 10, .input, StdAttr.width),  // IN1
      Port(0, 0, .output, StdAttr.width),  // OUT
      Port(-20, -20, .input, 1),  // C_IN
      Port(-20, 20, .output, 1),  // C_OUT
    ])
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  /// `computeSum(BitWidth, Value a, Value b, Value cIn)` → `(sum, carryOut)`.
  ///
  /// Upstream returns a two-element array; a tuple is the same thing with the indices named.
  ///
  /// Three things to keep exactly:
  ///
  ///   * **Java integer arithmetic wraps; Swift's `+` traps.** Every `+` on a `long` here is
  ///     `&+`. This is not theoretical: the width-64 branch adds two full-range values on
  ///     purpose and *relies* on the wrap to compute the carry.
  ///   * **The width-64 branch is a separate algorithm**, because `sum >> 64` would not give a
  ///     carry (Java masks the shift distance by 63, so `>> 64` is `>> 0`). It instead masks off
  ///     the sign bits, adds, and reconstructs the carry from the three top bits.
  ///   * **The `else` branch is bit-serial** and reached whenever any input has an X or E bit.
  ///     Once the carry goes unknown or error, every higher bit inherits it; that is the
  ///     `if carry == …` test at the top of the loop, before the operands are even looked at.
  ///
  /// D13: `Value.create([Value])` throws, so this throws.
  static func computeSum(
    _ width: BitWidth, _ valueA: Value, _ valueB: Value, _ carryIn: Value
  ) throws -> (sum: Value, carryOut: Value) {
    let w = width.width
    var cIn = carryIn
    if cIn == .unknownValue || cIn == .nilValue { cIn = .falseValue }

    if valueA.isFullyDefined() && valueB.isFullyDefined() && cIn.isFullyDefined() {
      if w == 64 {
        let ax = valueA.toLongValue()
        let bx = valueB.toLongValue()
        let cx = cIn.toLongValue()
        let mask = ~((1 as Int64) << 63)
        let aLast = ax < 0
        let bLast = bx < 0
        let cInLast = ((ax & mask) &+ (bx & mask) &+ cx) < 0
        let carry = (aLast && bLast) || (aLast && cInLast) || (bLast && cInLast)
        let sum = ax &+ bx &+ cx
        return (Value.createKnown(width, sum), carry ? .trueValue : .falseValue)
      } else {
        let sum = valueA.toLongValue() &+ valueB.toLongValue() &+ cIn.toLongValue()
        return (
          Value.createKnown(width, sum),
          ((sum >> Int64(w)) & 1) == 0 ? .falseValue : .trueValue
        )
      }
    }

    var bits = [Value]()
    bits.reserveCapacity(max(w, 0))
    var carry = cIn
    for i in 0..<max(w, 0) {
      if carry == .errorValue {
        bits.append(.errorValue)
      } else if carry == .unknownValue {
        bits.append(.unknownValue)
      } else {
        let ab = valueA.get(i)
        let bb = valueB.get(i)
        if ab == .errorValue || bb == .errorValue {
          bits.append(.errorValue)
          carry = .errorValue
        } else if ab == .unknownValue || bb == .unknownValue {
          bits.append(.unknownValue)
          carry = .unknownValue
        } else {
          let sum =
            (ab == .trueValue ? 1 : 0) + (bb == .trueValue ? 1 : 0)
            + (carry == .trueValue ? 1 : 0)
          bits.append((sum & 1) == 1 ? .trueValue : .falseValue)
          carry = sum >= 2 ? .trueValue : .falseValue
        }
      }
    }
    return (try Value.create(bits), carry)
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)

    let a = state.portValue(Adder.in0)
    let b = state.portValue(Adder.in1)
    let carryIn = state.portValue(Adder.cIn)
    let outs = try Adder.computeSum(dataWidth, a, b, carryIn)

    let delay = (dataWidth.width + 2) * Adder.perDelay
    state.setPort(Adder.out, outs.sum, delay)
    state.setPort(Adder.cOut, outs.carryOut, delay)
  }

  // NOT PORTED: getHDLName (D11); returns "FullAdder" at width 1.

  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, Adder.in0)
    ArithPaint.drawPort(painter, state, Adder.in1)
    ArithPaint.drawPort(painter, state, Adder.out)
    ArithPaint.drawPort(painter, state, Adder.cIn, label: "c in", direction: .north)
    ArithPaint.drawPort(painter, state, Adder.cOut, label: "c out", direction: .south)

    let loc = state.component.location
    painter.color = ArithPaint.componentColor
    painter.withStrokeWidth(2) {
      painter.drawLine(loc.x - 15, loc.y, loc.x - 5, loc.y)
      painter.drawLine(loc.x - 10, loc.y - 5, loc.x - 10, loc.y + 5)
    }
  }
}
