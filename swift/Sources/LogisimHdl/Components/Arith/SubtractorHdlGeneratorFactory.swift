// SubtractorHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/SubtractorHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Note the parameter declaration order is the *reverse* of `Adder`'s (`nrOfBits` first here,
// `extendedBits` first there). It is preserved because `myParametersList.keySet(attrs)` is
// declaration-ordered; the emitted generic map is sorted by name, so the difference is not
// visible in the HDL, but reversing it would still be a silent divergence from upstream in a
// list other code may come to read.
//
// `n_bIn` and `s_carry` are declared as wires in both languages even though only the Verilog
// body uses `n_bIn` and only the VHDL body uses `s_carry`; upstream declares both
// unconditionally, so both appear in every generated architecture. Preserved verbatim
// (standing rule 4).

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.SubtractorHdlGeneratorFactory`.
public final class SubtractorHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let extendedBitsString = "extendedBits"
  private static let extendedBitsId = -2

  public init() {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList
      .addBusOnly(Self.nrOfBitsString, Self.nrOfBitsId)
      .add(Self.extendedBitsString, Self.extendedBitsId, kind: .widthFormula(offset: 1))
    myWires
      .addWire("s_extendeddataA", Self.extendedBitsId)
      .addWire("s_extendeddataB", Self.extendedBitsId)
      .addWire("s_sumresult", Self.extendedBitsId)
      .addWire("n_bIn", 1)
      .addWire("s_carry", 1)
    myPorts
      .add(.input, "dataA", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Subtractor.in0, bitWidthAttribute: StdAttr.width)
      .add(.input, "dataB", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Subtractor.in1, bitWidthAttribute: StdAttr.width)
      .add(.input, "borrowIn", nrOfBits: 1, componentPinId: ArithPortIds.Subtractor.borrowIn)
      .add(.output, "result", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Subtractor.out, bitWidthAttribute: StdAttr.width)
      .add(.output, "borrowOut", nrOfBits: 1, componentPinId: ArithPortIds.Subtractor.borrowOut)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
    let nrOfBits = attrs.arithHdlWidth
    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        s_extendeddataA <= "0"&dataA;
        s_extendeddataB <= "0"&({{not}}(dataB));
        s_carry         <= {{not}}(borrowIn);
        s_sumresult     <= std_logic_vector(unsigned(s_extendeddataA) +
                           unsigned(s_extendeddataB) +
                           (""&s_carry));
        """ + "\n")
      contents.add(
        nrOfBits == 1
          ? "result    <= s_sumresult(0);"
          : "result    <= s_sumresult( (" + Self.nrOfBitsString + "-1) {{downto}} 0 );")
      contents.add("borrowOut <= {{not}}(s_sumresult(" + Self.extendedBitsString + "-1));")
    } else {
      contents.add(
        """
        assign n_bIn = ~borrowIn;
        assign {s_carry,result} = dataA + ~(dataB) + n_bIn;
        assign borrowOut        = ~s_carry;
        """ + "\n")
    }
    return contents.empty()
  }
}
