// JKFlipFlop.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.JKFlipFlop),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `JKFFHDLGeneratorFactory` (HDL, D11), `FlipFlopIcon` (drawing, D6/D9).

import LogisimKernel

/// `com.cburch.logisim.std.memory.JKFlipFlop`.
public final class JKFlipFlop: AbstractFlipFlop {
  /// `JKFlipFlop._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "J-K Flip-Flop"

  public init() {
    super.init(JKFlipFlop.id, numInputs: 2, allowLevelTriggers: false)
  }

  public override func computeValue(_ inputs: [Value], _ curValue: Value) -> Value {
    if inputs[0] == .falseValue {
      if inputs[1] == .falseValue { return curValue }
      if inputs[1] == .trueValue { return .falseValue }
    } else if inputs[0] == .trueValue {
      if inputs[1] == .falseValue { return .trueValue }
      if inputs[1] == .trueValue { return curValue.not() }
    }
    return .unknownValue
  }

  public override func getInputName(_ index: Int) -> String {
    index == 0 ? "J" : "K"
  }
}
