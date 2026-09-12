// MemoryAbstractFlipFlopHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/AbstractFlipFlopHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// The shared body of the D, T, J-K and S-R flip-flop generators: an asynchronous reset/preset
// pair, a `s_currentState` register clocked by a possibly-inverted clock, and a subclass hook
// (`updateLogic`) supplying the one expression that computes `s_nextState`.
//
// ── Java text blocks vs Swift multi-line literals ───────────────────────────────────────────
//
// Java's `"""…"""` terminates **every** content line including the last, so a text block passed
// to `LineBuffer.add` is one buffer entry ending in `\n`. Swift's multi-line literal does not.
// The difference is invisible wherever the entry is later split; Java's `getWithIndent` uses
// `String.split("\n")`, which drops the trailing empty field, and that is the path every entry
// below takes. So the literals here deliberately carry no trailing newline, and the oracle test
// (`MemoryHdlOracleTests`) checks the resulting entry lists against the real jar rather than
// leaving that reasoning unverified. Where an entry *is* returned raw by `get()` and therefore
// keeps its terminator, the port appends one explicitly and says so at the site.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.AbstractFlipFlopHdlGeneratorFactory`.
open class MemoryAbstractFlipFlopHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let invertClockString = "invertClockEnable"
  private static let invertClockId = -1

  /// `AbstractFlipFlopHdlGeneratorFactory.nrOfInputs`.
  public let nrOfInputs: Int

  /// - Parameter triggerAttribute: `StdAttr.TRIGGER` for the level-capable flip-flops
  ///   (D, S-R) and `StdAttr.EDGE_TRIGGER` for the edge-only ones (T, J-K), exactly as each
  ///   subclass passes upstream.
  public init(numInputs: Int, triggerAttribute: AnyAttribute) {
    nrOfInputs = numInputs
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)

    myParametersList.add(
      Self.invertClockString, Self.invertClockId,
      kind: .attributeOption(triggerAttribute, MemoryHdl.triggerMap))
    myWires
      .addWire("s_clock", 1)
      .addWire("s_nextState", 1)
      .addRegister("s_currentState", 1)
    myPorts
      .add(.input, "reset", nrOfBits: 1, componentPinId: numInputs + 3)
      .add(.input, "preset", nrOfBits: 1, componentPinId: numInputs + 4)
      .add(.clock, HdlPorts.clock, nrOfBits: 1, componentPinId: numInputs)
      .add(.output, "q", nrOfBits: 1, componentPinId: numInputs + 1)
      .add(.output, "qBar", nrOfBits: 1, componentPinId: numInputs + 2)

    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  open override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer()
    contents
      .pair("invertClock", Self.invertClockString)
      .pair("Clock", HdlPorts.clock)
      .pair("Tick", HdlPorts.tick)
      .empty()
      .addRemarkBlock("Here the output signals are defined")
      .add(
        """
        {{assign}}q       {{=}}s_currentState;
        {{assign}}qBar    {{=}}{{not}}(s_currentState);
        """)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords()
        .add("s_clock {{=}}{{Clock}} {{when}} {{invertClock}} = 0 {{else}} {{not}}({{Clock}});")
        .empty()
    } else {
      contents
        .add("assign s_clock {{=}}({{invertClock}} == 0) ? {{Clock}} : ~{{Clock}};")
        .empty()
        .addRemarkBlock("Here the initial register value is defined; for simulation only")
        .add(
          """
          initial
          begin
             s_currentState = 0;
          end
          """)
        .empty()
    }
    contents
      .addRemarkBlock("Here the update logic is defined")
      .add(updateLogic())
      .empty()
      .addRemarkBlock("Here the actual state register is defined")
    if Hdl.isVhdl() {
      contents.add(
        """
        makeMemory : {{process}}( s_clock , reset , preset , {{Tick}} , s_nextState ) {{is}}
        {{begin}}
           {{if}} (reset = '1') {{then}} s_currentState <= '0';
           {{elsif}} (preset = '1') {{then}} s_currentState <= '1';
        """)
      if MemoryHdl.isFlipFlop(attrs) {
        contents.add("   {{elsif}} (rising_edge(s_clock)) {{then}}")
      } else {
        contents.add("   {{elsif}} (s_clock = '1') {{then}}")
      }
      contents.add(
        """
              {{if}} ({{Tick}} = '1') {{then}}
                 s_currentState <= s_nextState;
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeMemory;
        """)
    } else {
      if MemoryHdl.isFlipFlop(attrs) {
        contents.add(
          """
          always @(posedge reset or posedge preset or posedge s_clock)
          begin
             if (reset) s_currentState <= 1'b0;
             else if (preset) s_currentState <= 1'b1;
             else if ({{Tick}}) s_currentState <= s_nextState;
          end
          """)
      } else {
        contents.add(
          """
          always @(*)
          begin
             if (reset) s_currentState <= 1'b0;
             else if (preset) s_currentState <= 1'b1;
             else if ({{Tick}} & (s_clock == 1'b1)) s_currentState <= s_nextState;
          end
          """)
      }
    }
    return contents.empty()
  }

  /// `AbstractFlipFlopHdlGeneratorFactory.getUpdateLogic()`. Upstream's base implementation
  /// returns an empty buffer; every concrete flip-flop overrides it.
  open func updateLogic() -> LineBuffer {
    LineBuffer.getHdlBuffer()
  }
}
