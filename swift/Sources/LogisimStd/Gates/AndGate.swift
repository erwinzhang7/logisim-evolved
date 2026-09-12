// AndGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.AndGate),
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

/// `com.cburch.logisim.std.gates.AndGate`.
public final class AndGate: AbstractGate {

  /// AndGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name string,
  /// spaces and capitals included. It must not change: `.circ` files reference it by name.
  public static let id = "AND Gate"

  /// Java's `public static final AndGate FACTORY = new AndGate()` with a private constructor.
  /// The port keeps the shared instance (component factories are stateless and are compared by
  /// identity all over `LogisimFile`) but leaves the initialiser public, since Swift has no
  /// static-initialisation ordering hazard to protect against.
  public static let factory = AndGate()

  public init() {
    super.init(AndGate.id)
    setRectangularLabel("&")
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeAnd(inputs, numInputs)
  }

  public override var identity: Value { .trueValue }

  /// `computeExpression(Expression[], int)` (`AndGate.java:64-70`).
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    AbstractGate.fold(inputs, algebra.and)
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.and over the inputs).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  /// `paintShape` -> `PainterShaped.paintAnd`. AndGate.java:110-113.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintAnd(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintAnd(…, false)`. AndGate.java:82-85. Unreachable in
  /// 4.1.0; see `PainterDin`.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintAnd(painter, width, height, false)
  }
}
