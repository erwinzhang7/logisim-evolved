// XnorGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.XnorGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.XnorGate`.
public final class XnorGate: AbstractGate {

  /// XnorGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name
  /// string. It must not change: `.circ` files reference it by name.
  public static let id = "XNOR Gate"

  /// Java's `public static final XnorGate FACTORY = new XnorGate()`.
  public static let factory = XnorGate()

  public init() {
    // `isXor: true` is what publishes `ATTR_XOR`, whose default is `XOR_ONE`; see
    // `XorGate.swift`'s header for why that default is gate-visible.
    super.init(XnorGate.id, isXor: true)
    setNegateOutput(true)
    setAdditionalWidth(10)
    setPaintInputLines(true)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    let behaviour = state.attributeValue(GateAttributes.xor)
    if behaviour == GateAttributes.xorOdd {
      return GateFunctions.computeOddParity(inputs, numInputs).not()
    } else {
      return try GateFunctions.computeExactlyOne(inputs, numInputs).not()
    }
  }

  public override var identity: Value { .falseValue }

  /// `computeExpression(Expression[], int)` (`XnorGate.java:47-49`): `XorGate`'s helper,
  /// negated, so it inherits the same refusal above two inputs.
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    algebra.not(try XorGate.xorExpression(inputs, algebra))
  }

  /// `getRectangularLabel(AttributeSet)`: delegated to `XorGate`'s, exactly as upstream does.
  public override func rectangularLabel(_ attributes: any AttributeSet) -> String {
    XorGate.factory.rectangularLabel(attributes)
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.not(XorGate.xorExpression(...))).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  public override func shouldRepairWire(
    _ component: StdInstanceComponent, _ data: WireRepairData
  ) -> Bool {
    data.point != component.location
  }

  /// `paintShape` -> `PainterShaped.paintXor`: the same body as XOR, with the bubble coming
  /// from `setNegateOutput(true)`. XnorGate.java:81-84.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintXor(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintXnor(…, false)`. XnorGate.java:71-74.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintXnor(painter, width, height, false)
  }
}
