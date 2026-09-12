// NorGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.NorGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.NorGate`.
public final class NorGate: AbstractGate {

  /// NorGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name string.
  /// It must not change: `.circ` files reference it by name.
  public static let id = "NOR Gate"

  /// Java's `public static final NorGate FACTORY = new NorGate()`.
  public static let factory = NorGate()

  public init() {
    super.init(NorGate.id)
    // Simulation-visible: the output bubble adds 10 to the axis length, moving every input port.
    setNegateOutput(true)
    // Java: `setRectangularLabel(OrGate.FACTORY.getRectangularLabel(null))`, i.e. "≥1".
    setRectangularLabel(OrGate.factory.rectangularLabel(AttributeSets.empty))
    setPaintInputLines(true)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeOr(inputs, numInputs).not()
  }

  /// The OR identity (FALSE), before the output bubble: see `NandGate.identity` for the same
  /// point.
  public override var identity: Value { .falseValue }

  /// `computeExpression(Expression[], int)` (`NorGate.java:67-73`).
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    algebra.not(AbstractGate.fold(inputs, algebra.or))
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.not(Expressions.or(...))).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  public override func shouldRepairWire(
    _ component: StdInstanceComponent, _ data: WireRepairData
  ) -> Bool {
    data.point != component.location
  }

  /// `paintShape` -> `PainterShaped.paintOr`. NorGate.java:95-98.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintOr(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintOr(…, true)`. NorGate.java:85-88.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintOr(painter, width, height, true)
  }
}
