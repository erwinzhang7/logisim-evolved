// EvenParityGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.EvenParityGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.EvenParityGate`.
///
/// Note upstream does **not** call `setNegateOutput(true)` here even though the function is an
/// inverted odd parity; the inversion lives entirely in `computeOutput`. That matters: had it
/// been set, every input port would sit 10 units further out. Transcribed as written.
public final class EvenParityGate: AbstractGate {

  /// EvenParityGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name
  /// string. It must not change: `.circ` files reference it by name.
  public static let id = "Even Parity"

  /// Java's `private static final String LABEL = "2k"`.
  private static let label = "2k"

  /// Java's `public static final EvenParityGate FACTORY = new EvenParityGate()`.
  public static let factory = EvenParityGate()

  public init() {
    super.init(EvenParityGate.id)
    setRectangularLabel(EvenParityGate.label)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeOddParity(inputs, numInputs).not()
  }

  public override var identity: Value { .falseValue }

  /// `computeExpression(Expression[], int)` (`EvenParityGate.java:39-45`).
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    algebra.not(AbstractGate.fold(inputs, algebra.xor))
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.not of the xor fold).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  /// `paintShape` -> `paintRectangular`. The parity gates have no ANSI silhouette: they draw
  /// the IEC box under *every* shape setting, labelled `2k`. EvenParityGate.java:67-70.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    paintRectangular(painter, width, height)
  }

  /// `paintDinShape` -> `paintRectangular`, likewise. EvenParityGate.java:57-60.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    paintRectangular(painter, width, height)
  }
}
