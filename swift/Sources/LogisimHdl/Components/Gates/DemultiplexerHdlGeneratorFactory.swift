// DemultiplexerHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/plexers/DemultiplexerHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.

import LogisimKernel

/// `com.cburch.logisim.std.plexers.DemultiplexerHdlGeneratorFactory`.
public final class DemultiplexerHdlGeneratorFactory: AbstractHdlGeneratorFactory {

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
    let nrOfBits =
      attrs.hdlBitWidth(named: GatesHdlAttributeNames.width) == 1 ? 1 : Self.nrOfBitsId
    let selectInputIndex = 1 << nrOfSelectBits
    let hasEnable = attrs.hdlBoolean(named: GatesHdlAttributeNames.plexerEnable, default: false)
    for output in 0..<selectInputIndex {
      myPorts.add(
        .output, "demuxOut_\(output)", nrOfBits: nrOfBits, componentPinId: output,
        bitWidthAttribute: bindings.width)
    }
    myPorts
      .add(.input, "sel", nrOfBits: nrOfSelectBits, componentPinId: selectInputIndex)
      .add(
        .input, "demuxIn", nrOfBits: nrOfBits,
        componentPinId: hasEnable ? selectInputIndex + 2 : selectInputIndex + 1)
    if hasEnable {
      myPorts.add(
        .input, "enable", nrOfBits: 1, componentPinId: selectInputIndex + 1, pullToZero: false)
    } else {
      myPorts.add(.input, "enable", nrOfBits: 1, fixedMap: Hdl.oneBit())
    }
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
    var space = "  "
    let nrOfSelectBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.plexerSelect)
    let numOutputs = 1 << nrOfSelectBits
    let width = attrs.hdlBitWidth(named: GatesHdlAttributeNames.width)
    for index in 0..<numOutputs {
      if index == 10 { space = " " }
      let binValue = Hdl.getConstantVector(Int64(index), nrOfBits: nrOfSelectBits)
      if Hdl.isVhdl() {
        contents
          .empty()
          .addVhdlKeywords()
          .add(
            "demuxOut_{{1}}{{2}}<= demuxIn {{when}} sel = {{3}} {{and}}", index, space, binValue)
        if width > 1 {
          contents.add("                            enable = '1' {{else}} ({{others}} => '0');")
        } else {
          contents.add("                            enable = '1' {{else}} '0';")
        }
      } else {
        contents.add(
          "assign demuxOut_{{1}}{{2}} = (enable&(sel == {{3}} )) ? demuxIn : 0;",
          index, space, binValue)
      }
    }
    return contents
  }
}
