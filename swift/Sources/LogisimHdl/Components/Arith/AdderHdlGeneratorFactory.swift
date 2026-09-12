// AdderHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/AdderHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── A Java text block is not a Swift multi-line literal ──────────────────────────────────────
//
// `"""\n a;\n b;\n """` in Java yields `"a;\nb;\n"`: every content line, including the last,
// is newline-terminated. Swift's `"""…"""` yields `"a;\nb;"` with no trailing newline. The
// difference is one blank line in every generated architecture, which the oracle transcript
// catches immediately, so every block below appends `"\n"` explicitly rather than relying on
// the reader to notice.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.AdderHdlGeneratorFactory`.
public final class AdderHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let extendedBitsString = "extendedBits"
  private static let extendedBitsId = -2

  public init() {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList
      .add(Self.extendedBitsString, Self.extendedBitsId, kind: .widthFormula(offset: 1))
      .addBusOnly(Self.nrOfBitsString, Self.nrOfBitsId)
    myWires
      .addWire("s_extendedDataA", Self.extendedBitsId)
      .addWire("s_extendedDataB", Self.extendedBitsId)
      .addWire("s_sumResult", Self.extendedBitsId)
    myPorts
      .add(.input, "dataA", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Adder.in0, bitWidthAttribute: StdAttr.width)
      .add(.input, "dataB", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Adder.in1, bitWidthAttribute: StdAttr.width)
      .add(.input, "carryIn", nrOfBits: 1, componentPinId: ArithPortIds.Adder.carryIn)
      .add(.output, "result", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Adder.out, bitWidthAttribute: StdAttr.width)
      .add(.output, "carryOut", nrOfBits: 1, componentPinId: ArithPortIds.Adder.carryOut)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
    let nrOfBits = attrs.arithHdlWidth
    if Hdl.isVhdl() {
      contents.empty().add(
        """
        s_extendedDataA <= "0"&dataA;
        s_extendedDataB <= "0"&dataB;
        s_sumResult     <= std_logic_vector(unsigned(s_extendedDataA) +
                                             unsigned(s_extendedDataB) +
                                             (""&carryIn));
        """ + "\n")
      if nrOfBits == 1 {
        contents.add("result   <= s_sumResult(0);")
      } else {
        contents.add("result   <= s_sumResult( ({{1}}-1) DOWNTO 0 );", Self.nrOfBitsString)
      }
      contents.add("carryOut <= s_sumResult({{1}}-1);", Self.extendedBitsString)
    } else {
      contents.add("assign   {carryOut, result} = dataA + dataB + carryIn;")
    }
    return contents.empty()
  }
}
