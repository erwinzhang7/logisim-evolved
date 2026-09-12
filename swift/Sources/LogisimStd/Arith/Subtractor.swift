// Subtractor.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Subtractor),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A - B via `Adder.computeSum(A, ~B, ~Bin)`, exactly as upstream: borrow-out is the complement
// of the adder's carry-out. Fixed bounds, fixed ports, one attribute.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Subtractor`.
public final class Subtractor: InstanceFactoryBase {

  /// `Subtractor._ID`. Do not change, `.circ` files reference it.
  public static let id = "Subtractor"

  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let bIn = 3
  public static let bOut = 4

  public init() {
    super.init(Subtractor.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0 (minuend)
      Port(-40, 10, .input, StdAttr.width),  // IN1 (subtrahend)
      Port(0, 0, .output, StdAttr.width),  // OUT
      Port(-20, -20, .input, 1),  // B_IN
      Port(-20, 20, .output, 1),  // B_OUT
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)

    let a = state.portValue(Subtractor.in0)
    let b = state.portValue(Subtractor.in1)
    var bIn = state.portValue(Subtractor.bIn)
    if bIn == .unknownValue || bIn == .nilValue { bIn = .falseValue }

    let outs = try Adder.computeSum(dataWidth, a, b.not(), bIn.not())

    let delay = (dataWidth.width + 4) * Adder.perDelay
    state.setPort(Subtractor.out, outs.sum, delay)
    state.setPort(Subtractor.bOut, outs.carryOut.not(), delay)
  }

  // NOT PORTED: getHDLName (D11); returns "FullSubtractor" at width 1.

  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, Subtractor.in0)
    ArithPaint.drawPort(painter, state, Subtractor.in1)
    ArithPaint.drawPort(painter, state, Subtractor.out)
    ArithPaint.drawPort(painter, state, Subtractor.bIn, label: "b in", direction: .north)
    ArithPaint.drawPort(painter, state, Subtractor.bOut, label: "b out", direction: .south)

    let loc = state.component.location
    painter.color = ArithPaint.componentColor
    painter.withStrokeWidth(2) {
      painter.drawLine(loc.x - 15, loc.y, loc.x - 5, loc.y)
    }
  }
}
