// AbstractSimpleIoHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/AbstractSimpleIoHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The generator behind five components: `Button` and `DipSwitch` (inputs), `Led`, `RgbLed` and
// `SevenSegment` (outputs). Each is a straight wire between the component's pins and the top
// level's bubble vector, one pin per bubble, in pin order.
//
// The `Button.ATTR_PRESS` read is deliberately unconditional in Java, and is performed on
// `DipSwitch` too, which has no such attribute; `getValue` answers null there and the
// `== BUTTON_PRESS_PASSIVE` comparison is false. `IoHdlAttributes.isButtonPressPassive` must
// reproduce that, see its documentation.

import LogisimKernel

/// `com.cburch.logisim.std.io.AbstractSimpleIoHdlGeneratorFactory`.
public final class AbstractSimpleIoHdlGeneratorFactory: InlinedHdlGeneratorFactory {
  private let isInputComponent: Bool
  private let attributes: IoHdlAttributes

  public init(isInputComponent: Bool, attributes: IoHdlAttributes = IoHdlAttributes()) {
    self.isInputComponent = isInputComponent
    self.attributes = attributes
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    var wires: [String: String] = [:]
    for index in 0..<componentInfo.nrOfEnds {
      if componentInfo.isEndConnected(index) && isInputComponent {
        let pressPassive = attributes.isButtonPressPassive(componentInfo.attributeSet)
        let destination = Hdl.getNetName(
          componentInfo, endIndex: index, floatingNetTiedToGround: true, netlist: netlist)
        let source = LineBuffer.formatHdl(
          "{{1}}{{2}}{{<}}{{3}}{{>}}",
          pressPassive ? Hdl.notOperator() : "",
          HdlGeneratorNames.localInputBubbleBusName,
          componentInfo.localBubbleInputStart + index)
        wires[destination] = source
      }
      if !isInputComponent {
        wires[
          LineBuffer.formatHdl(
            "{{1}}{{<}}{{2}}{{>}}", HdlGeneratorNames.localOutputBubbleBusName,
            componentInfo.localBubbleOutputStart + index)
        ] = Hdl.getNetName(
          componentInfo, endIndex: index, floatingNetTiedToGround: true, netlist: netlist)
      }
    }
    Hdl.addAllWiresSorted(contents, wires: &wires)
    return contents
  }
}
