// MultiplexerHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/plexers/MultiplexerHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Java writes the VHDL body with text blocks, whose incidental-indentation stripping is a
// compile-time transformation with no Swift equivalent. Every multi-line literal here is
// therefore written with its *final* indentation, taken from what the shipped jar actually
// emits rather than re-derived from the source's visual layout: see
// `tools/hdlbridge/GatesBridge.java`.

import LogisimKernel

/// `com.cburch.logisim.std.plexers.MultiplexerHdlGeneratorFactory`.
public final class MultiplexerHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1

  private let bindings: GatesHdlBindings

  public init(bindings: GatesHdlBindings) {
    self.bindings = bindings
    super.init(subDirectory: "plexers", widthAttribute: bindings.width)
    myParametersList.addBusOnly(Self.nrOfBitsString, Self.nrOfBitsId)
    getWiresPortsDuringHdlWriting = true
  }

  public override func getGenerationTimeWiresPorts(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) {
    let nrOfSelectBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.plexerSelect)
    let selectInputIndex = 1 << nrOfSelectBits
    let hasEnable = attrs.hdlBoolean(named: GatesHdlAttributeNames.plexerEnable, default: false)
    for input in 0..<selectInputIndex {
      myPorts.add(
        .input, "muxIn_\(input)", nrOfBits: Self.nrOfBitsId, componentPinId: input,
        bitWidthAttribute: bindings.width)
    }
    myPorts
      .add(.input, "sel", nrOfBits: nrOfSelectBits, componentPinId: selectInputIndex)
      .add(
        .output, "muxOut", nrOfBits: Self.nrOfBitsId,
        componentPinId: hasEnable ? selectInputIndex + 2 : selectInputIndex + 1,
        bitWidthAttribute: bindings.width)
    if hasEnable {
      myPorts.add(.input, "enable", nrOfBits: 1, componentPinId: selectInputIndex + 1)
    } else {
      myPorts.add(.input, "enable", nrOfBits: 1, fixedMap: Hdl.oneBit())
    }
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
    let nrOfSelectBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.plexerSelect)
    let nrOfBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    let inputs = 1 << nrOfSelectBits

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add("makeMux : {{process}}(enable,")
      for index in 0..<inputs {
        contents.add("                  muxIn_{{1}},", index)
      }
      // Leading spaces below are exact, taken from what the jar emits (18 / 0 / 3), not from the
      // Java source's visual layout: a Java text block strips the *minimum* indentation across
      // its lines and its closing delimiter, which is not what the source columns look like.
      contents.add(
        """
                          sel) {{is}}
        {{begin}}
           {{if}} (enable = '0') {{then}}
        """)
      contents.add(
        nrOfBits > 1
          ? "{{2u}}muxOut <= ({{others}} => '0');"
          : "{{2u}}muxOut <= '0';")
      contents.add(
        """
                             {{else}}
              {{case}} (sel) IS
        """)
      for index in 0..<(inputs - 1) {
        contents.add(
          "         {{when}} {{1}} => muxOut <= muxIn_{{2}};",
          Hdl.getConstantVector(Int64(index), nrOfBits: nrOfSelectBits), index)
      }
      contents.add(
        "         {{when}} {{others}}  => muxOut <= muxIn_{{1}};", inputs - 1)
      contents.add(
        """
              {{end}} {{case}};
           {{end}} {{if}};
        {{end}} {{process}} makeMux;
        """)
    } else {
      if nrOfBits == 1 {
        contents.add("reg s_selected_vector;")
      } else {
        contents.add("reg [{{1}}:0] s_selected_vector;", Self.nrOfBitsString)
      }
      contents.add(
        """
        assign muxOut = s_selected_vector;

        always @(*)
        begin
           if (~enable) s_selected_vector <= 0;
           else case (sel)
        """)
      for index in 0..<(inputs - 1) {
        contents
          .add("      {{1}}:", Hdl.getConstantVector(Int64(index), nrOfBits: nrOfSelectBits))
          .add("         s_selected_vector <= muxIn_{{1}};", index)
      }
      contents
        .add("     default:")
        .add("        s_selected_vector <= muxIn_{{1}};", inputs - 1)
        .add("   endcase")
        .add("end")
    }
    return contents.empty()
  }
}
