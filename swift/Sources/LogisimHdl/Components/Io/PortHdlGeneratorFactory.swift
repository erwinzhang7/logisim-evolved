// PortHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/PortHdlGeneratorFactory.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The only io generator that emits tri-state logic, and the only one that writes raw `assign`
// text rather than going through `{{assign}}` in the bidirectional branches; upstream hand-rolls
// the Verilog there because the conditional form has no `{{…}}` spelling. Both spellings are
// reproduced literally, including the fact that the VHDL and Verilog INOUT branches pass the
// enable and data signals in the **opposite order** to one another (VHDL: data `when` enable;
// Verilog: `(enable) ? data`), which is upstream's and is why the two look transposed.
//
// One genuine upstream bug preserved (standing rule 4): the multi-enable per-bit VHDL branch
// reads `getBusEntryName(componentInfo, 1, …)` as the *value* and `…, 0, …` as the *enable*,
// while the Verilog branch of the very same `else` reads them the other way round. Only one of
// the two can be right; both are emitted verbatim.

import LogisimKernel

/// `com.cburch.logisim.std.io.PortHdlGeneratorFactory`.
public final class PortHdlGeneratorFactory: InlinedHdlGeneratorFactory {
  private let attributes: IoHdlAttributes

  public init(attributes: IoHdlAttributes = IoHdlAttributes()) {
    self.attributes = attributes
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    let attrs = componentInfo.attributeSet
    let portType = attributes.portDirection(attrs)
    let nrOfPins = attributes.portSize(attrs)
    let startIndex = componentInfo.localBubbleInputStart
    let endIndex = startIndex + nrOfPins - 1

    func netName(_ end: Int) -> String {
      Hdl.getNetName(componentInfo, endIndex: end, floatingNetTiedToGround: true, netlist: netlist)
    }
    func busName(_ end: Int) -> String {
      Hdl.getBusName(componentInfo, endIndex: end, netlist: netlist) ?? ""
    }
    func busEntry(_ end: Int, _ bit: Int) -> String {
      Hdl.getBusEntryName(
        componentInfo, endIndex: end, floatingNetTiedToGround: true, bitIndex: bit,
        netlist: netlist)
    }

    switch portType {
    case .input:
      if nrOfPins == 1 {
        contents.add(
          "{{assign}} {{1}}{{=}}{{2}}{{<}}{{3}}{{>}};", netName(0),
          HdlGeneratorNames.localInputBubbleBusName, endIndex)
      } else {
        contents.add(
          "{{assign}} {{1}}{{=}}{{2}}{{<}}{{3}}{{4}}{{5}}{{>}};", busName(0),
          HdlGeneratorNames.localInputBubbleBusName, endIndex, Hdl.vectorLoopId(), startIndex)
      }

    case .output:
      if nrOfPins == 1 {
        contents.add(
          "{{assign}} {{1}}{{<}}{{2}}{{>}}{{=}}{{3}};",
          HdlGeneratorNames.localOutputBubbleBusName, endIndex, netName(0))
      } else {
        contents.add(
          "{{assign}} {{1}}{{<}}{{2}}{{3}}{{4}}{{>}}{{=}}{{5}};",
          HdlGeneratorNames.localOutputBubbleBusName, endIndex, Hdl.vectorLoopId(), startIndex,
          busName(0))
      }

    case .inOutSingleEnable, .inOutMultiEnable:
      // first we handle the input connections, and after that the output connections
      if nrOfPins == 1 {
        contents.add(
          "{{assign}} {{1}}{{=}}{{2}}{{<}}{{3}}{{>}};", netName(2),
          HdlGeneratorNames.localInOutBubbleBusName, endIndex)
      } else {
        contents.add(
          "{{assign}} {{1}}{{=}}{{2}}{{<}}{{3}}{{4}}{{5}}{{>}};", busName(2),
          HdlGeneratorNames.localInOutBubbleBusName, endIndex, Hdl.vectorLoopId(), startIndex)
      }
      // simple case first, we have a single output enable
      if portType == .inOutSingleEnable || nrOfPins == 1 {
        if Hdl.isVhdl() {
          if nrOfPins == 1 {
            contents.addVhdlKeywords().add(
              "{{1}}({{2}}) <= {{3}} {{when}} {{4}} = '1' {{else}} ({{others}} => 'Z');",
              HdlGeneratorNames.localInOutBubbleBusName, startIndex, netName(1), netName(0))
          } else {
            contents.addVhdlKeywords().add(
              "{{1}}({{2}} {{downto}} {{3}}) <= {{4}} {{when}} {{5}} = '1' {{else}} ({{others}} => 'Z');",
              HdlGeneratorNames.localInOutBubbleBusName, endIndex, startIndex, busName(1),
              netName(0))
          }
        } else {
          if nrOfPins == 1 {
            contents.add(
              "assign {{1}}[{{2}}] = ({{3}}) ? {{4}} : {{5}}'bZ;",
              HdlGeneratorNames.localInOutBubbleBusName, startIndex, netName(0), netName(1),
              nrOfPins)
          } else {
            contents.add(
              "assign {{1}}[{{2}}:{{3}}] = ({{4}}) ? {{5}} : {{6}}'bZ;",
              HdlGeneratorNames.localInOutBubbleBusName, endIndex, startIndex, netName(0),
              busName(1), nrOfPins)
          }
        }
      } else {
        // we have to enumerate over each and every bit
        for busBitIndex in 0..<max(0, nrOfPins) {
          if Hdl.isVhdl() {
            contents.addVhdlKeywords().add(
              "{{1}}({{2}}) <= {{3}} {{when}} {{4}} = '1' {{else}} 'Z';",
              HdlGeneratorNames.localInOutBubbleBusName, startIndex + busBitIndex,
              busEntry(1, busBitIndex), busEntry(0, busBitIndex))
          } else {
            contents.add(
              "assign {{1}}[{{2}}] = ({{3}}) ? {{4}} : 1'bZ;",
              HdlGeneratorNames.localInOutBubbleBusName, startIndex + busBitIndex,
              busEntry(0, busBitIndex), busEntry(1, busBitIndex))
          }
        }
      }
    }
    return contents
  }
}
