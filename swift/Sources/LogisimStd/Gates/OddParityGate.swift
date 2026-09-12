// OddParityGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.OddParityGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.OddParityGate`.
///
/// Note this gate is built *without* `isXor`, so it carries no `ATTR_XOR`: parity is always
/// parity here, whereas an XOR gate has to be told which of the two behaviours it means.
public final class OddParityGate: AbstractGate {

  /// OddParityGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name
  /// string. It must not change: `.circ` files reference it by name.
  public static let id = "Odd Parity"

  /// Java's `private final String ODD_PARITY_LABEL = "2k+1"`: an instance field rather than a
  /// constant, unlike `EvenParityGate.LABEL`, but used identically.
  private static let oddParityLabel = "2k+1"

  /// Java's `public static final OddParityGate FACTORY = new OddParityGate()`.
  public static let factory = OddParityGate()

  public init() {
    super.init(OddParityGate.id)
    setRectangularLabel(OddParityGate.oddParityLabel)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeOddParity(inputs, numInputs)
  }

  public override var identity: Value { .falseValue }

  /// `computeExpression(Expression[], int)` (`OddParityGate.java:39-45`).
  ///
  /// Unlike `XorGate` this accepts any input count: an odd-parity gate *is* a chain of XORs by
  /// definition, so there is nothing for it to refuse.
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    AbstractGate.fold(inputs, algebra.xor)
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.xor folded over the inputs).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  /// `paintShape` -> `paintRectangular`. See `EvenParityGate.paintShape`.
  /// OddParityGate.java:62-65.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    paintRectangular(painter, width, height)
  }

  /// `paintDinShape` -> `paintRectangular`, likewise. OddParityGate.java:57-60.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    paintRectangular(painter, width, height)
  }
}
