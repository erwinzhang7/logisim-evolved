// ComparatorHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/arith/ComparatorHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the first of the two generators in the family that declare their ports and wires at
// generation time rather than at construction (`getWiresPortsDuringHDLWriting = true`), because
// the four comparison wires only exist for a bus: at width 1 the comparison is three gate
// expressions with nothing to name. The framework clears `myPorts`/`myWires`/`myTypedWires`
// before each call, so `getGenerationTimeWiresPorts` may append unconditionally.
//
// `SIGNED_MAP` is declared here in Java (`public static`) and shared by `Multiplier` and
// `Divider`; in this port it lives on `ArithHdlOptions` so all three can reach it without a
// dependency between generators.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.ComparatorHdlGeneratorFactory`.
public final class ComparatorHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let twosComplementString = "twosComplement"
  private static let twosComplementId = -2

  /// `Comparator.MODE_ATTR`, injected: see `ArithHdlSupport.swift`'s header.
  public init(modeAttribute: AnyAttribute) {
    super.init(subDirectory: ArithHdlSubdirectory.name, widthAttribute: StdAttr.width)
    myParametersList
      .addBusOnly(Self.nrOfBitsString, Self.nrOfBitsId)
      .add(
        Self.twosComplementString, Self.twosComplementId,
        kind: .attributeOption(modeAttribute, ArithHdlOptions.signedMap))
    getWiresPortsDuringHdlWriting = true
  }

  public override func getGenerationTimeWiresPorts(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) {
    myPorts
      .add(.input, "dataA", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Comparator.in0, bitWidthAttribute: StdAttr.width)
      .add(.input, "dataB", nrOfBits: Self.nrOfBitsId, componentPinId: ArithPortIds.Comparator.in1, bitWidthAttribute: StdAttr.width)
      .add(.output, "aGreaterThanB", nrOfBits: 1, componentPinId: ArithPortIds.Comparator.greaterThan)
      .add(.output, "aEqualsB", nrOfBits: 1, componentPinId: ArithPortIds.Comparator.equal)
      .add(.output, "aLessThanB", nrOfBits: 1, componentPinId: ArithPortIds.Comparator.lessThan)
    if attrs.arithHdlWidth > 1 {
      myWires
        .addWire("s_signedLess", 1)
        .addWire("s_unsignedLess", 1)
        .addWire("s_signedGreater", 1)
        .addWire("s_unsignedGreater", 1)
    }
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getBuffer().pair("twosComplement", Self.twosComplementString)
    let nrOfBits = attrs.arithHdlWidth
    if Hdl.isVhdl() {
      if nrOfBits == 1 {
        contents.empty().addVhdlKeywords().add(
          """
          aEqualsB <= dataA {{xnor}} dataB;
          aLessThanB <= dataA {{and}} {{not}}(dataB) {{when}} {{twosComplement}} = 1 {{else}} {{not}}(dataA) {{and}} dataB;
          aGreaterThanB <= {{not}}(dataA) {{and}} dataB {{when}} {{twosComplement}} = 1 {{else}} dataA {{and}} {{not}}(dataB);
          """ + "\n")
      } else {
        // `aEqualsB` spells ELSE in literal capitals rather than `{{else}}`: harmless with
        // upper-case keywords on, and preserved verbatim so the two spellings stay identical
        // to upstream if the keyword-case preference is ever flipped.
        contents.empty().addVhdlKeywords().add(
          """
          s_signedLess      <= '1' {{when}} signed(dataA) < signed(dataB) {{else}} '0';
          s_unsignedLess    <= '1' {{when}} unsigned(dataA) < unsigned(dataB) {{else}} '0';
          s_signedGreater   <= '1' {{when}} signed(dataA) > signed(dataB) {{else}} '0';
          s_unsignedGreater <= '1' {{when}} unsigned(dataA) > unsigned(dataB) {{else}} '0';

          aEqualsB      <= '1' {{when}} dataA = dataB ELSE '0';
          aGreaterThanB <= s_signedGreater {{when}} {{twosComplement}} = 1 {{else}} s_unsignedGreater;
          aLessThanB    <= s_signedLess {{when}} {{twosComplement}} = 1 {{else}} s_unsignedLess;
          """ + "\n")
      }
    } else {
      if nrOfBits == 1 {
        contents.add(
          """
          assign aEqualsB      = (dataA == dataB);
          assign aLessThanB    = (dataA < dataB);
          assign aGreaterThanB = (dataA > dataB);
          """ + "\n")
      } else {
        contents.add(
          """
          assign s_signedLess      = ($signed(dataA) < $signed(dataB));
          assign s_unsignedLess    = (dataA < dataB);
          assign s_signedGreater   = ($signed(dataA) > $signed(dataB));
          assign s_unsignedGreater = (dataA > dataB);

          assign aEqualsB      = (dataA == dataB);
          assign aGreaterThanB = ({{twosComplement}}==1) ? s_signedGreater : s_unsignedGreater;
          assign aLessThanB    = ({{twosComplement}}==1) ? s_signedLess : s_unsignedLess;
          """ + "\n")
      }
    }
    return contents.empty()
  }
}
