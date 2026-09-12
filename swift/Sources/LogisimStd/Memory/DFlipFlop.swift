// DFlipFlop.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.DFlipFlop),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `DFFHDLGeneratorFactory` (HDL, D11), `FlipFlopIcon` (drawing, D6/D9).

import LogisimKernel

/// `com.cburch.logisim.std.memory.DFlipFlop`.
public final class DFlipFlop: AbstractFlipFlop {
  /// `DFlipFlop._ID`. Do NOT change; it is the `.circ` factory-name token.
  public static let id = "D Flip-Flop"

  public init() {
    super.init(DFlipFlop.id, numInputs: 1, allowLevelTriggers: true)
  }

  public override func computeValue(_ inputs: [Value], _ curValue: Value) -> Value {
    inputs[0]
  }

  public override func getInputName(_ index: Int) -> String {
    "D"
  }
}
