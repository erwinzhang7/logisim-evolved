// XorGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.XorGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The multi-input attribute, and why it is gate-visible ───────────────────────────────────
//
// XOR and XNOR are the only two gates constructed with `isXor = true`, which is what makes
// `GateAttributes` publish `ATTR_XOR` at all (`GateAttributeList` appends it only when
// `attrs.xorBehave != null`). Its default is `XOR_ONE`, the `.circ` token `"1"`, meaning
// *exactly one* input true, **not** odd parity. So a three-input XOR with all three inputs
// true reads FALSE by default, which surprises people but is upstream's behaviour and is what
// the saved bytes encode: `GateAttributes(isXor: true)` sets `xorBehaviour = xorOne`, so a
// file that does not carry `<a name="xor" val="odd"/>` is one-hot.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.XorGate`.
public final class XorGate: AbstractGate {

  /// XorGate has no `_ID` constant in 4.1.0; the `.circ` token is the constructor's name string.
  /// It must not change: `.circ` files reference it by name.
  public static let id = "XOR Gate"

  /// Java's `public static final XorGate FACTORY = new XorGate()`.
  public static let factory = XorGate()

  public init() {
    super.init(XorGate.id, isXor: true)
    // Simulation-visible: `bonusWidth` widens the body, which moves every input port outward.
    setAdditionalWidth(10)
    setPaintInputLines(true)
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    // Java reads the attribute and compares against the `XOR_ODD` singleton by reference;
    // `AttributeOption` is a `Hashable` struct here and the two options have distinct names, so
    // the structural comparison agrees on every input (PATTERNS.md §0, "Equality").
    let behaviour = state.attributeValue(GateAttributes.xor)
    if behaviour == GateAttributes.xorOdd {
      return GateFunctions.computeOddParity(inputs, numInputs)
    } else {
      return try GateFunctions.computeExactlyOne(inputs, numInputs)
    }
  }

  public override var identity: Value { .falseValue }

  /// `protected static Expression xorExpression(Expression[] inputs, int numInputs)`
  /// (`XorGate.java:39-48`). `static` and `internal` because `XnorGate` calls it, exactly as
  /// upstream's `protected static` is called from `XnorGate.computeExpression`.
  ///
  /// **The refusal above two inputs is real, and it is upstream's only use of
  /// `UnsupportedOperationException` on this path.** A 3-input XOR is ambiguous: `ATTR_XOR`
  /// selects between odd-parity and exactly-one, `computeOutput` honours that attribute, and a
  /// two-operand `Expressions.xor` chain can only express the first. Rather than silently
  /// derive the odd-parity reading for a gate that may be in exactly-one mode, upstream throws,
  /// and `Analyze.propagateComponents` converts it into `CannotHandle("XOR Gate")`, which sends
  /// the whole circuit to the truth-table path. Reproduced, including the fact that the refusal
  /// ignores `ATTR_XOR`; a 3-input XOR is refused even when it *is* in odd-parity mode and the
  /// chain would have been correct.
  static func xorExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    if inputs.count > 2 { throw AnalyzeError.unsupported("XOR Gate") }
    return AbstractGate.fold(inputs, algebra.xor)
  }

  /// `computeExpression(Expression[], int)` (`XorGate.java:58-61`).
  public override func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    try XorGate.xorExpression(inputs, algebra)
  }

  /// `getRectangularLabel(AttributeSet)`.
  ///
  /// **Deviation (mechanism).** Java's parameter is nullable and returns `""` for null; the
  /// port's `AbstractGate.rectangularLabel` takes a non-optional `any AttributeSet`, so that
  /// branch is unrepresentable. The only upstream caller that passes null is
  /// `NandGate`/`NorGate`'s constructor, and those call `AndGate`/`OrGate`'s inherited
  /// implementation, which ignores the argument entirely. Nothing reaches XOR's null branch.
  ///
  /// Note the odd label only appears when the input count is *not* 2; a two-input odd-parity
  /// XOR is drawn "=1" because for two inputs odd parity and one-hot coincide.
  public override func rectangularLabel(_ attributes: any AttributeSet) -> String {
    var isOdd = false
    let behaviour = attributes.getValue(GateAttributes.xor)
    if behaviour == GateAttributes.xorOdd {
      let inputs = attributes.getValue(GateAttributes.inputs)
      if inputs == nil || inputs != 2 {
        isOdd = true
      }
    }
    return isOdd ? "2k+1" : "=1"
  }

  // NOT PORTED: computeExpression / xorExpression (analyze path). Note upstream's
  //             `xorExpression` throws `UnsupportedOperationException` for more than two
  //             inputs; `XnorGate` calls it through `Expressions.not`. See XorGate.java:37-46.
  // NOT PORTED: paintIconANSI: the toolbar icon (see AbstractGate's header).

  public override func shouldRepairWire(
    _ component: StdInstanceComponent, _ data: WireRepairData
  ) -> Bool {
    data.point != component.location
  }

  /// `paintShape` -> `PainterShaped.paintXor`. XorGate.java:126-129.
  public override func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    PainterShaped.paintXor(painter, width, height)
  }

  /// `paintDinShape` -> `PainterDin.paintXor(…, false)`. XorGate.java:92-95.
  public override func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    PainterDin.paintXor(painter, width, height, false)
  }
}
