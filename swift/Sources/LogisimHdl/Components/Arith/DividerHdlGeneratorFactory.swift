// DividerHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/DividerHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── DO NOT REGISTER THIS AGAINST THE "Divider" FACTORY NAME ──────────────────────────────────
//
// **In 4.1.0 this class is dead code.** `Divider`'s constructor is
// `super(_ID, S.getter("dividerComponent"))`: the two-argument `InstanceFactory` overload, with
// no HDL generator, while every other arith component passes one
// (`Adder.java:105`, `Subtractor.java:49`, `Multiplier.java:130`, `Negator.java:45`,
// `Comparator.java:61`, `Shifter.java:72`). Verified by grep over the whole 4.1.0 tree:
// `DividerHdlGeneratorFactory` is named nowhere except its own declaration.
//
// The consequence is behavioural, not cosmetic: `Divider.getHDLGenerator(attrs)` returns null,
// so a `Divider` is **excluded from `Netlist.getNormalComponents()`** and fails the DRC's
// `isHDLSupportedComponent` check. Registering this generator would make the port emit HDL for
// a circuit that upstream refuses, which is a worse divergence than the missing feature.
//
// It is ported anyway because the file is part of the assigned tranche, because the omission
// looks far more like an upstream oversight than a decision (the class is complete, correct and
// covered by the oracle), and because leaving a documented dead port is cheaper than
// rediscovering the asymmetry later. If upstream ever wires it up, registration is a one-line
// change and the behaviour is already verified byte-for-byte.
//
// Note also `isHdlSupportedTarget` returns false for Verilog; there is no Verilog body at all,
// only the VHDL one. That is upstream's own guard and is preserved.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.DividerHdlGeneratorFactory`.
public final class DividerHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let calcBitsString = "calcBits"
  private static let calcBitsId = -2
  private static let unsignedString = "unsignedDivider"
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
      .addWire("s_divResult", Self.calcBitsId)
      .addWire("s_modResult", Self.nrOfBitsId)
      .addWire("s_extendedDividend", Self.calcBitsId)
    myPorts
      .add(.input, "inputA", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Divider.in0)
      .add(.input, "inputB", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Divider.in1)
      .add(.input, "upper", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Divider.upper)
      .add(.output, "quotient", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Divider.out)
      .add(.output, "remainder", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Divider.rem)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer()
      .pair("nrOfBits", Self.nrOfBitsString)
      .pair("unsigned", Self.unsignedString)
      .pair("calcBits", Self.calcBitsString)
    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        s_extendedDividend({{calcBits}}-1 {{downto}} {{nrOfBits}}) <= upper;
        s_extendedDividend({{nrOfBits}}-1 {{downto}} 0) <= inputA;
        s_divResult <= std_logic_vector(unsigned(s_extendedDividend) / unsigned(inputB))
                           {{when}} {{unsigned}} = 1 {{else}}
                        std_logic_vector(signed(s_extendedDividend) / signed(inputB));
        s_modResult <= std_logic_vector(unsigned(s_extendedDividend) {{mod}} unsigned(inputB))
                           {{when}} {{unsigned}} = 1 {{else}}
                        std_logic_vector(signed(s_extendedDividend) {{mod}} signed(inputB));
        quotient  <= s_divResult({{nrOfBits}}-1 {{downto}} 0);
        remainder <= s_modResult({{nrOfBits}}-1 {{downto}} 0);
        """ + "\n")
    }
    return contents.empty()
  }

  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    Hdl.isVhdl()
  }
}
