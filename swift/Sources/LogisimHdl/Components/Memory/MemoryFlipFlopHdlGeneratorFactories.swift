// MemoryFlipFlopHdlGeneratorFactories: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// four private inner `*HDLGeneratorFactory` classes of
// `com/cburch/logisim/std/memory/{DFlipFlop,TFlipFlop,JKFlipFlop,SRFlipFlop}.java`. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Upstream nests each of these inside its component class, so they are not separate files there
// and there is no `std/memory/DFlipFlopHdlGeneratorFactory.java` to mirror. They are gathered
// here because each is a constructor plus one `getUpdateLogic` override, and splitting four
// twelve-line classes across four files would obscure that they differ only in that expression.
//
// Two things a reader will want to check against the Java and that are easy to get wrong:
//
//   * **Which trigger attribute each passes.** D and S-R take `StdAttr.TRIGGER` (they allow
//     level triggers, so `AbstractFlipFlop` gives them the four-option attribute); T and J-K
//     take `StdAttr.EDGE_TRIGGER`. That choice reaches the generated text twice: through the
//     `invertClockEnable` generic's value map, and through `Netlist.isFlipFlop`, which decides
//     `rising_edge(s_clock)` versus `s_clock = '1'`.
//   * **The extra input ports are added after `super`**, so they land *before* nothing and
//     after the base class's five; port order in `myPorts` is insertion order, and the
//     entity's port list is sorted by name afterwards, so this only shows up in `getPortMap`.

import LogisimFile

/// `DFlipFlop.DFFHDLGeneratorFactory`.
public final class MemoryDFlipFlopHdlGeneratorFactory: MemoryAbstractFlipFlopHdlGeneratorFactory {
  public init() {
    super.init(numInputs: 1, triggerAttribute: StdAttr.trigger)
    myPorts.add(.input, "d", nrOfBits: 1, componentPinId: 0)
  }

  public override func updateLogic() -> LineBuffer {
    LineBuffer.getHdlBuffer().add("{{assign}}s_nextState {{=}} d;")
  }
}

/// `TFlipFlop.TFFHDLGeneratorFactory`.
public final class MemoryTFlipFlopHdlGeneratorFactory: MemoryAbstractFlipFlopHdlGeneratorFactory {
  public init() {
    super.init(numInputs: 1, triggerAttribute: StdAttr.edgeTrigger)
    myPorts.add(.input, "t", nrOfBits: 1, componentPinId: 0)
  }

  public override func updateLogic() -> LineBuffer {
    LineBuffer.getHdlBuffer().add("{{assign}}s_nextState{{=}}s_currentState{{xor}}t;")
  }
}

/// `JKFlipFlop.JKFFHDLGeneratorFactory`.
public final class MemoryJKFlipFlopHdlGeneratorFactory: MemoryAbstractFlipFlopHdlGeneratorFactory {
  public init() {
    super.init(numInputs: 2, triggerAttribute: StdAttr.edgeTrigger)
    myPorts
      .add(.input, "j", nrOfBits: 1, componentPinId: 0)
      .add(.input, "k", nrOfBits: 1, componentPinId: 1)
  }

  public override func updateLogic() -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    // The second line is indented to the *resolved* width of the first line's assignment
    // preamble, which differs between VHDL (`""`, since VHDL has no `assign`) and Verilog
    // (`"assign "`). So the padding has to be measured after substitution, exactly as upstream
    // does with `LineBuffer.formatHdl` followed by `" ".repeat(preamble.length())`.
    let preamble = LineBuffer.formatHdl("{{assign}}s_nextState{{=}}")
    contents
      .add("{{1}}({{not}}(s_currentState){{and}}j){{or}}", preamble)
      .add("{{1}}(s_currentState{{and}}{{not}}(k));", String(repeating: " ", count: preamble.count))
    return contents
  }
}

/// `SRFlipFlop.SRFFHDLGeneratorFactory`.
public final class MemorySRFlipFlopHdlGeneratorFactory: MemoryAbstractFlipFlopHdlGeneratorFactory {
  public init() {
    super.init(numInputs: 2, triggerAttribute: StdAttr.trigger)
    myPorts
      .add(.input, "s", nrOfBits: 1, componentPinId: 0)
      .add(.input, "r", nrOfBits: 1, componentPinId: 1)
  }

  public override func updateLogic() -> LineBuffer {
    LineBuffer.getHdlBuffer().add(
      "{{assign}} s_nextState{{=}}(s_currentState{{and}}s){{or}}({{not}}(r){{and}}s){{or}}(s_currentState{{and}}{{not}}(r));"
    )
  }
}
