// NandGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.NandGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.NandGate`.
public final class NandGate: AbstractGate {

  /// NandGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name
  /// string. It must not change: `.circ` files reference it by name.
  public static let id = "NAND Gate"

  /// Java's `public static final NandGate FACTORY = new NandGate()`.
  public static let factory = NandGate()

  public init() {
    super.init(NandGate.id)
    // `setNegateOutput(true)` is simulation-visible, not decoration: it adds 10 to the axis
    // length in `AbstractGate.getOffsetBounds`/`getInputOffset`, which moves every input port.
    setNegateOutput(true)
    // Java: `setRectangularLabel(AndGate.FACTORY.getRectangularLabel(null))`. `AbstractGate`'s
    // implementation ignores its argument and returns the stored label, so this is "&".
    // Transcribed as the call rather than the literal so the two cannot drift apart.
    setRectangularLabel(AndGate.factory.rectangularLabel(AttributeSets.empty))
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeAnd(inputs, numInputs).not()
  }

  /// Note this is the AND identity (TRUE), not the negated one: `getIdentity` describes what an
  /// *absent input* contributes to the inner function, before the output bubble.
  public override var identity: Value { .trueValue }

  /// `computeExpression(Expression[], int)` (`NandGate.java:70-76`): AND, then negate once.
  /// Note it is *not* a negation per input; the whole fold is wrapped.
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    algebra.not(AbstractGate.fold(inputs, algebra.and))
  }

  // NOT PORTED: computeExpression (analyze path: Expressions.not(Expressions.and(...))).
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  /// `paintShape` -> `PainterShaped.paintAnd`. NAND draws the *same* body as AND; the
  /// difference is entirely `setNegateOutput(true)`, which `AbstractGate.paintBase` turns into
  /// a ten-narrower body plus a bubble. NandGate.java:98-101.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintAnd(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintAnd(…, true)`. NandGate.java:87-90.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintAnd(painter, width, height, true)
  }
}
