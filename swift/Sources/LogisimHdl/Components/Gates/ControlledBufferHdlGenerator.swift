// ControlledBufferHdlGenerator: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/gates/ControlledBufferHdlGenerator.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Controlled Buffer and Controlled Inverter: a tri-state driver, emitted inline.
//
// Upstream reads the invert flag off the *factory*
// (`((ControlledBuffer) componentInfo.getComponent().getFactory()).isInverter()`), not off an
// attribute. `LogisimHdl` cannot name `ControlledBuffer`, and it does not need to: the two
// factories are separate registry entries, so the flag is a constructor argument and each name
// registers the instance that matches it.

import LogisimKernel

/// `com.cburch.logisim.std.gates.ControlledBufferHdlGenerator`.
public final class ControlledBufferHdlGenerator: InlinedHdlGeneratorFactory {

  private let isInverter: Bool

  public init(isInverter: Bool) {
    self.isInverter = isInverter
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    // A plain buffer, not an HDL one: upstream builds this with `LineBuffer.getBuffer()` and
    // adds `{{...}}` keys only through the VHDL-keyword pass below.
    let contents = LineBuffer.getBuffer()
    let triName = Hdl.getNetName(
      componentInfo, endIndex: 2, floatingNetTiedToGround: true, netlist: netlist)
    let inputName: String
    let outputName: String
    let triState: String
    let nrBits = componentInfo.attributeSet.hdlBitWidth(named: GatesHdlAttributeNames.width)
    if nrBits > 1 {
      inputName = Hdl.getBusName(componentInfo, endIndex: 1, netlist: netlist) ?? ""
      outputName = Hdl.getBusName(componentInfo, endIndex: 0, netlist: netlist) ?? ""
      triState = Hdl.isVhdl() ? "({{others}} => 'Z')" : "\(nrBits)'bZ"
    } else {
      inputName = Hdl.getNetName(
        componentInfo, endIndex: 1, floatingNetTiedToGround: true, netlist: netlist)
      outputName = Hdl.getNetName(
        componentInfo, endIndex: 0, floatingNetTiedToGround: true, netlist: netlist)
      triState = Hdl.isVhdl() ? "'Z'" : "1'bZ"
    }
    if componentInfo.isEndConnected(2) && componentInfo.isEndConnected(0) {
      let invert = isInverter ? Hdl.notOperator() : ""
      if Hdl.isVhdl() {
        contents.addVhdlKeywords().add(
          "{{1}}<= {{2}}{{3}} {{when}} {{4}} = '1' {{else}} {{5}};",
          outputName, invert, inputName, triName, triState)
      } else {
        contents.add(
          "assign {{1}} = ({{2}}) ? {{3}}{{4}} : {{5}};",
          outputName, triName, invert, inputName, triState)
      }
    }
    return contents
  }
}
