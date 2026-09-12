// MultiplierHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/MultiplierHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// D15 note: the width-independence here is real and worth stating, because the simulation-side
// multiplier genuinely cannot use a machine word above 64 bits. This generator never computes a
// product: it emits `unsigned(inputA)*unsigned(inputB)` and lets the synthesiser size it, with
// `calcBits = 2 * width` as a generic. So a 64-bit multiplier's 128-bit intermediate is the
// target toolchain's problem, and nothing in this file overflows at any width `BitWidth` allows.
//
// The generic is named `unsignedMultiplier` but its value is `1` for the **signed**
// (`twosComplement`) option and `0` for `unsigned`: `ComparatorHdlGeneratorFactory.SIGNED_MAP`
// maps `UNSIGNED_OPTION -> 0`, `SIGNED_OPTION -> 1`, while every use reads
// `WHEN unsignedMultiplier = 1` to select the *unsigned* arm. That inversion is upstream's, it
// is shared verbatim with `Divider`, and it is preserved (standing rule 4).

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.MultiplierHdlGeneratorFactory`.
public final class MultiplierHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let calcBitsString = "calcBits"
  private static let calcBitsId = -2
  private static let unsignedString = "unsignedMultiplier"
  private static let unsignedId = -3

  /// `Comparator.MODE_ATTR`, injected: see `ArithHdlSupport.swift`'s header.
  public init(modeAttribute: AnyAttribute) {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList
      .add(Self.nrOfBitsString, Self.nrOfBitsId)
      .add(Self.calcBitsString, Self.calcBitsId, kind: .widthFormula(multiplier: 2))
      .add(
        Self.unsignedString, Self.unsignedId,
        kind: .attributeOption(modeAttribute, ArithHdlOptions.signedMap))
    myWires
      .addWire("s_multResult", Self.calcBitsId)
      .addWire("s_extendedcarryIn", Self.calcBitsId)
      .addWire("s_newResult", Self.calcBitsId)
    myPorts
      .add(.input, "inputA", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Multiplier.in0)
      .add(.input, "inputB", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Multiplier.in1)
      .add(.input, "carryIn", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Multiplier.carryIn)
      .add(.output, "multLow", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Multiplier.out)
      .add(.output, "multHigh", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Multiplier.carryOut)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer()
      .pair("nrOfBits", Self.nrOfBitsString)
      .pair("unsigned", Self.unsignedString)
      .pair("calcBits", Self.calcBitsString)
    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        s_multResult <= std_logic_vector(unsigned(inputA)*unsigned(inputB))
                            {{when}} {{unsigned}}= 1 {{else}}
                         std_logic_vector(signed(inputA)*signed(inputB));
        s_extendedcarryIn({{calcBits}}-1 {{downto}} {{nrOfBits}}) <= ({{others}} => '0') {{when}} {{unsigned}} = 1 {{else}} ({{others}} => carryIn({{nrOfBits}}-1));
        s_extendedcarryIn({{nrOfBits}}-1 {{downto}} 0) <= carryIn;
        s_newResult  <= std_logic_vector(unsigned(s_multResult) + unsigned(s_extendedcarryIn))
                            {{when}} {{unsigned}}= 1 {{else}}
                         std_logic_vector(signed(s_multResult) + signed(s_extendedcarryIn));
        multHigh     <= s_newResult({{calcBits}}-1 {{downto}} {{nrOfBits}});
        multLow      <= s_newResult({{nrOfBits}}-1 {{downto}} 0);
        """ + "\n")
    } else {
      contents.add(
        """
        reg[{{calcBits}}-1:0] s_carryIn;
        reg[{{calcBits}}-1:0] s_multUnsigned;
        reg[{{calcBits}}-1:0] s_intermediateResult;
        reg signed[{{calcBits}}-1:0] s_multSigned;

        always @(*)
        begin
           s_carryIn[{{nrOfBits}}-1:0] = carryIn;
           if ({{unsigned}}== 1)
              begin
                 s_carryIn[{{calcBits}}-1:{{nrOfBits}}] = 0;
                 s_multUnsigned = $unsigned(inputA) * $unsigned(inputB);
                 s_intermediateResult = $unsigned(s_multUnsigned) + $unsigned(s_carryIn);
               end
            else
              begin
                 if (carryIn[{{nrOfBits}}-1] == 1)
                    s_carryIn[{{calcBits}}-1:{{nrOfBits}}] = -1;
                 else
                    s_carryIn[{{calcBits}}-1:{{nrOfBits}}] = 0;
                 s_multSigned = $signed(inputA) * $signed(inputB);
                 s_intermediateResult = $signed(s_multSigned) + $signed(s_carryIn);
               end
        end

        assign multHigh = s_intermediateResult[{{calcBits}}-1:{{nrOfBits}}];
        assign multLow  = s_intermediateResult[{{nrOfBits}}-1:0];
        """ + "\n")
    }
    return contents.empty()
  }
}
