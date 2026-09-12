// NegatorHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/NegatorHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.NegatorHdlGeneratorFactory`.
public final class NegatorHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1

  public init() {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList.addBusOnly(Self.nrOfBitsString, Self.nrOfBitsId)
    myPorts
      .add(.input, "dataX", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Negator.inPort, bitWidthAttribute: StdAttr.width)
      .add(.output, "minDataX", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Negator.outPort, bitWidthAttribute: StdAttr.width)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
    if Hdl.isVhdl() {
      // Java reads the width only inside this branch; mirrored so a width-less attribute set
      // fails in exactly the same place it would upstream.
      let nrOfBits = attrs.arithHdlWidth
      contents
        .empty()
        .addVhdlKeywords()
        .add(
          nrOfBits == 1
            ? "minDataX <= dataX;"
            : "minDataX <= std_logic_vector(unsigned({{not}}(dataX)) + 1);")
    } else {
      contents.add("assign minDataX = -dataX;")
    }
    return contents.empty()
  }
}
