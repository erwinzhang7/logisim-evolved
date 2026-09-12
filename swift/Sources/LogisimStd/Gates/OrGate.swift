// OrGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.OrGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The whole of a concrete gate. Everything else, bounds, ports, hit testing, the negation
// bubbles, the 0/Z output pull, the undefined-input rule, is `AbstractGate`.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.OrGate`.
public final class OrGate: AbstractGate {

  /// OrGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name string,
  /// spaces and capitals included. It must not change: `.circ` files reference it by name.
  public static let id = "OR Gate"

  /// Java's `public static final OrGate FACTORY = new OrGate()` with a private constructor.
  public static let factory = OrGate()

  public init() {
    super.init(OrGate.id)
    // Java writes `"≥" + "1"`, i.e. "≥1".
    setRectangularLabel("\u{2265}1")
    setPaintInputLines(true)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeOr(inputs, numInputs)
  }

  /// The identity for OR is FALSE: an unconnected input contributes nothing. Contrast AND,
  /// whose identity is TRUE. Taken from `getIdentity()`, not re-derived.
  public override var identity: Value { .falseValue }

  /// `computeExpression(Expression[], int)` (`OrGate.java:62-68`).
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    AbstractGate.fold(inputs, algebra.or)
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.or over the inputs).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  public override func shouldRepairWire(
    _ component: StdInstanceComponent, _ data: WireRepairData
  ) -> Bool {
    data.point != component.location
  }

  /// `paintShape` -> `PainterShaped.paintOr`. OrGate.java:109-112.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintOr(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintOr(…, false)`. OrGate.java:80-83.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintOr(painter, width, height, false)
  }
}
