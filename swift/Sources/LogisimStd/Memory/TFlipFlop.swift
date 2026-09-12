// TFlipFlop.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.TFlipFlop),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `TFFHDLGeneratorFactory` (HDL, D11), `FlipFlopIcon` (drawing, D6/D9).

import LogisimKernel

/// `com.cburch.logisim.std.memory.TFlipFlop`.
public final class TFlipFlop: AbstractFlipFlop {
  /// `TFlipFlop._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "T Flip-Flop"

  public init() {
    super.init(TFlipFlop.id, numInputs: 1, allowLevelTriggers: false)
  }

  public override func computeValue(_ inputs: [Value], _ curValue: Value) -> Value {
    // Java: `if (curValue == Value.UNKNOWN) curValue = Value.FALSE;`: reassigns the parameter,
    // not `data.curValue`; transcribed as a local rebinding to keep the same one-branch shape.
    let base = curValue == .unknownValue ? Value.falseValue : curValue
    return inputs[0] == .trueValue ? base.not() : base
  }

  public override func getInputName(_ index: Int) -> String {
    "T"
  }
}
