// BitSelectorHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/plexers/BitSelectorHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Two of its four generics come from `Attributes.forNoSave()` attributes (`SELECT_ATTR`,
// `EXTENDED_ATTR`) whose `getName()` is `null` upstream, so they cannot be found by `.circ` name
// and must be injected; see `GatesHdlBindings`. Their values are maintained by
// `BitSelector.updatePorts`, not by the user, which is why they are unsaved.
//
// The Verilog bus path hard-codes a 514-bit scratch vector and unrolls the selector 15 ways;
// that is upstream's own bound (`Value.MAX_WIDTH` groups), reproduced verbatim.

import LogisimKernel

/// `com.cburch.logisim.std.plexers.BitSelectorHdlGeneratorFactory`.
public final class BitSelectorHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let inputBitsString = "nrOfInputBits"
  private static let inputBitsId = -1
  private static let outputBitsString = "nrOfOutputBits"
  private static let outputBitsId = -2
  private static let selectBitsString = "nrOfselBits"
  private static let selectBitsId = -3
  private static let extendedBitsString = "nrOfExtendedBits"
  private static let extendedBitsId = -4

  public init(bindings: GatesHdlBindings) {
    super.init(subDirectory: "plexers", widthAttribute: bindings.width)
    myParametersList
      .add(
        Self.selectBitsString, Self.selectBitsId,
        kind: .intAttribute(bindings.bitSelectorSelect, offset: 0))
      .add(Self.inputBitsString, Self.inputBitsId)
      .add(
        Self.extendedBitsString, Self.extendedBitsId,
        kind: .intAttribute(bindings.bitSelectorExtended, offset: 0))
      .addBusOnly(bindings.bitSelectorGroup, Self.outputBitsString, Self.outputBitsId)
    myWires.addWire("s_extendedVector", Self.extendedBitsId)
    myPorts
      .add(.input, "dataIn", nrOfBits: Self.inputBitsId, componentPinId: 1)
      .add(.input, "sel", nrOfBits: Self.selectBitsId, componentPinId: 2)
      .add(
        .output, "dataOut", nrOfBits: Self.outputBitsId, componentPinId: 0,
        bitWidthAttribute: bindings.bitSelectorGroup)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getBuffer()
      .pair("extBits", Self.extendedBitsString)
      .pair("inBits", Self.inputBitsString)
      .pair("outBits", Self.outputBitsString)
    let outputBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.bitSelectorGroup)

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords()
        .add(
          """
          s_extendedVector(({{extBits}}-1) {{downto}} {{inBits}}) <= ({{others}} => '0');
          s_extendedVector(({{inBits}}-1) {{downto}} 0) <= dataIn;
          """)
        .add(
          outputBits > 1
            ? "dataOut <= s_extendedVector( ((to_integer(unsigned(sel))+1) * {{outBits}})-1 {{downto}} to_integer(unsigned(sel))*{{outBits}} );"
            : "dataOut <= s_extendedVector( to_integer(unsigned(sel)) );")
    } else {
      contents.add(
        """
        assign s_extendedVector[{{extBits}}-1:{{inBits}}] = 0;
        assign s_extendedVector[{{inBits}}-1:0] = dataIn;
        """)
      if outputBits > 1 {
        contents.add(
          """
          wire[513:0] s_selectVector;
          reg[{{outBits}}-1:0] s_selected_slice;
          assign s_selectVector[513:{{extBits}}] = 0;
          assign s_selectVector[{{extBits}}-1:0] = s_extendedVector;
          assign dataOut = s_selected_slice;

          always @(*)
          begin
             case (sel)
          """)
        var index = 15
        while index > 0 {
          contents.add(
            "{{1}}{{2}} : s_selected_slice <= s_selectVector[({{3}}*{{outBits}})-1:{{2}}*{{outBits}}];",
            LineBuffer.getIndent(2), index, index + 1)
          index -= 1
        }
        contents.add(
          """
                default : s_selected_slice <= s_selectVector[{{outBits}}-1:0];
             endcase
          end
          """)
      } else {
        contents.add("assign dataOut = s_extendedVector[sel];")
      }
    }
    return contents.empty()
  }
}
