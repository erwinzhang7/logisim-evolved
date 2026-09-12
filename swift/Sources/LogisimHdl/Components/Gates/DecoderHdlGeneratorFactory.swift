// DecoderHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/plexers/DecoderHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Note the `space` variable: upstream pads the output name with one space until output 10, then
// stops, so the `<=` column stays aligned as the index goes from one digit to two. It is a
// cosmetic detail of the emitted text and therefore part of what a byte-exact port must match.

import LogisimKernel

/// `com.cburch.logisim.std.plexers.DecoderHdlGeneratorFactory`.
public final class DecoderHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private let bindings: GatesHdlBindings

  public init(bindings: GatesHdlBindings) {
    self.bindings = bindings
    super.init(subDirectory: "plexers", widthAttribute: bindings.width)
    getWiresPortsDuringHdlWriting = true
  }

  public override func getGenerationTimeWiresPorts(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) {
    let nrOfSelectBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.plexerSelect)
    let selectInputIndex = 1 << nrOfSelectBits
    for output in 0..<selectInputIndex {
      myPorts.add(.output, "decoderOut_\(output)", nrOfBits: 1, componentPinId: output)
    }
    myPorts.add(.input, "sel", nrOfBits: nrOfSelectBits, componentPinId: selectInputIndex)
    if attrs.hdlBoolean(named: GatesHdlAttributeNames.plexerEnable, default: false) {
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
    let nrOfSelectBits = attrs.hdlBitWidth(named: GatesHdlAttributeNames.plexerSelect)
    let numOutputs = 1 << nrOfSelectBits
    var space = " "
    for index in 0..<numOutputs {
      if index == 10 { space = "" }
      contents
        .pair("bin", Hdl.getConstantVector(Int64(index), nrOfBits: nrOfSelectBits))
        .pair("i", index)
      if Hdl.isVhdl() {
        contents.empty().addVhdlKeywords().add(
          """
          decoderOut_{{i}}{{1}}<= '1' {{when}} sel = {{bin}} {{and}}
          {{1}}                        enable = '1' {{else}} '0';
          """, space)
      } else {
        contents.add(
          "assign decoderOut_{{i}}{{1}} = (enable&(sel == {{bin}})) ? 1'b1 : 1'b0;", space)
      }
    }
    return contents
  }
}
