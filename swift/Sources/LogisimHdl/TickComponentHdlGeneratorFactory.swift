// TickComponentHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/TickComponentHdlGeneratorFactory.java`. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Generates the FPGA-clock-to-simulation-tick divider: a free-running counter that reloads at
// `fpgaClockFrequency / tickFrequency` and pulses `FPGATick` once per reload, which is what the
// rest of the generated design synchronises its "one simulated propagation step" to.

import LogisimKernel

open class TickComponentHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let reloadValueString = "reloadValue"
  private static let reloadValueId = -1
  private static let nrOfCounterBitsString = "nrOfBits"
  private static let nrOfCounterBitsId = -2

  public static let fpgaClock = "fpgaGlobalClock"
  public static let fpgaTick = "s_fpgaTick"
  public static let hdlIdentifier = "logisimTickGenerator"
  public static let hdlDirectory = "base"

  public init(fpgaClockFrequency: Int64, tickFrequency: Double, widthAttribute: Attribute<BitWidth>) {
    super.init(subDirectory: Self.hdlDirectory, widthAttribute: widthAttribute)

    let reloadValueAcc = Double(fpgaClockFrequency) / tickFrequency
    var reloadValue = Int64(reloadValueAcc)
    if reloadValue > 0x7FFF_FFFF || reloadValue < 0 { reloadValue = 0x7FFF_FFFF }
    var nrOfBits = 0
    var calcValue = reloadValue
    while calcValue != 0 {
      nrOfBits += 1
      calcValue /= 2
    }

    myParametersList
      .add(Self.reloadValueString, Self.reloadValueId, kind: .constant(reloadValue))
      .add(Self.nrOfCounterBitsString, Self.nrOfCounterBitsId, kind: .constant(Int64(nrOfBits)))
    myWires
      .addWire("s_tickNext", 1)
      .addWire("s_countNext", Self.nrOfCounterBitsId)
      .addRegister("s_tickReg", 1)
      .addRegister("s_countReg", Self.nrOfCounterBitsId)
    myPorts
      .add(.input, "FPGAClock", nrOfBits: 1, fixedMap: SynthesizedClockHdlGeneratorFactory.synthesizedClock)
      .add(.output, "FPGATick", nrOfBits: 1, fixedMap: Self.fpgaTick)
  }

  open override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var result: [String: String] = [:]
    for port in myPorts.keySet() { result[port] = myPorts.getFixedMap(port) }
    return result
  }

  open override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("nrOfCounterBits", Self.nrOfCounterBitsString)
      .add("")
      .addRemarkBlock("Here the output is defined")
      .add(
        netlist.requiresGlobalClockConnection
          ? "{{assign}} FPGATick {{=}} '1';"
          : "{{assign}} FPGATick {{=}} s_tickReg;"
      )
      .add("")
      .addRemarkBlock("Here the update logic is defined")

    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        s_tickNext   <= '1' {{when}} s_countReg = std_logic_vector(to_unsigned(0, {{nrOfCounterBits}})) {{else}} '0';
        s_countNext  <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- For simulation only!
                        std_logic_vector(to_unsigned((reloadValue-1), {{nrOfCounterBits}})) {{when}} s_tickNext = '1' {{else}}
                        std_logic_vector(unsigned(s_countReg)-1);

        """
      ).empty()
    } else {
      contents.add(
        """
            assign s_tickNext  = (s_countReg == 0) ? 1'b1 : 1'b0;
            assign s_countNext = (s_countReg == 0) ? reloadValue-1 : s_countReg-1;

        """
      )
      .empty()
      .addRemarkBlock("Here the simulation only initial is defined")
      .add(
        """
        initial
        begin
           s_countReg = 0;
           s_tickReg  = 1'b0;
        end

        """
      ).empty()
    }
    contents.addRemarkBlock("Here the flipflops are defined")
    if Hdl.isVhdl() {
      contents.add(
        """
        makeFlipFlops : {{process}}(FPGAClock) {{is}}
        {{begin}}
           {{if}} (rising_edge(FPGAClock)) {{then}}
              s_tickReg  <= s_tickNext;
              s_countReg <= s_countNext;
           {{end}} {{if}};
        {{end}} {{process}} makeFlipFlops;

        """
      ).empty()
    } else {
      contents.add(
        """
        always @(posedge FPGAClock)
        begin
            s_countReg <= s_countNext;
            s_tickReg  <= s_tickNext;
        end

        """
      ).empty()
    }
    return contents
  }
}
