// SRFlipFlop.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.SRFlipFlop),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `SRFFHDLGeneratorFactory` (HDL, D11), `FlipFlopIcon` (drawing, D6/D9).

import LogisimKernel

/// `com.cburch.logisim.std.memory.SRFlipFlop`.
public final class SRFlipFlop: AbstractFlipFlop {
  /// `SRFlipFlop._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "S-R Flip-Flop"

  public init() {
    super.init(SRFlipFlop.id, numInputs: 2, allowLevelTriggers: true)
  }

  public override func computeValue(_ inputs: [Value], _ curValue: Value) -> Value {
    if inputs[0] == .falseValue {
      if inputs[1] == .falseValue { return curValue }
      if inputs[1] == .trueValue { return .falseValue }
    } else if inputs[0] == .trueValue {
      if inputs[1] == .falseValue { return .trueValue }
      // Unlike JKFlipFlop, S=R=1 is a genuine error state for an S-R latch, not "toggle".
      if inputs[1] == .trueValue { return .errorValue }
    }
    return .unknownValue
  }

  public override func getInputName(_ index: Int) -> String {
    index == 0 ? "S" : "R"
  }
}
