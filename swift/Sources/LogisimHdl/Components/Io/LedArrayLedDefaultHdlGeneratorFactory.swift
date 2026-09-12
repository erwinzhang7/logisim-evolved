// LedArrayLedDefaultHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/LedArrayLedDefaultHdlGeneratorFactory.java` and
// `RgbArrayLedDefaultHdlGeneratorFactory.java`. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The unscanned drivers: every LED has its own wire, so the whole body is one `generate` loop
// that optionally inverts. Board-level, not component-level: see
// `LedArrayGenericHdlGeneratorFactory.swift`'s header.
//
// **Upstream bug preserved (standing rule 4).** `RgbArrayLedDefault`'s *Verilog* body indexes
// `[n]` inside a loop whose variable is `i`, so the generated Verilog references an undeclared
// identifier. The VHDL body of the same class is correct. Reproduced verbatim and pinned by the
// gate; "fixing" it would be an undetectable divergence from the jar.

import LogisimKernel

/// `com.cburch.logisim.std.io.LedArrayLedDefaultHdlGeneratorFactory`.
public class LedArrayLedDefaultHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  public static let nrOfLedsId = -1
  public static let activeLowId = -2
  public static let nrOfLedsString = "nrOfLeds"
  public static let activeLowString = "activeLow"
  public class var hdlIdentifier: String { "LedArrayLedDefault" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myParametersList
      .add(Self.nrOfLedsString, Self.nrOfLedsId)
      .add(Self.activeLowString, Self.activeLowId)
    myPorts
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayInputs, nrOfBits: Self.nrOfLedsId,
        componentPinId: 0)
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayOutputs, nrOfBits: Self.nrOfLedsId,
        componentPinId: 1)
  }

  /// `getGenericMap(int, int, long, boolean)`. The pairs are supplied in Java's *insertion*
  /// order; `genericPortMapAlligned` re-orders them the way `HashMap.keySet()` would.
  public static func genericMap(
    nrOfRows: Int, nrOfColumns: Int, fpgaClockFrequency: Int64, activeLow: Bool
  ) -> LineBuffer {
    LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(
      [
        (key: nrOfLedsString, value: String(nrOfRows * nrOfColumns)),
        (key: activeLowString, value: activeLow ? "1" : "0"),
      ], isGeneric: true)
  }

  /// `getPortMap(int)`.
  public class func portMap(identifier: Int) -> LineBuffer {
    LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(
      [
        (
          key: LedArrayGenericHdlGeneratorFactory.ledArrayOutputs,
          value: "\(LedArrayGenericHdlGeneratorFactory.ledArrayOutputs)\(identifier)"
        ),
        (
          key: LedArrayGenericHdlGeneratorFactory.ledArrayInputs,
          value: "s_\(LedArrayGenericHdlGeneratorFactory.ledArrayInputs)\(identifier)"
        ),
      ], isGeneric: false)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("ins", LedArrayGenericHdlGeneratorFactory.ledArrayInputs)
      .pair("outs", LedArrayGenericHdlGeneratorFactory.ledArrayOutputs)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        genLeds : {{for}} n {{in}} (nrOfLeds-1) {{downto}} 0 {{generate}}
           {{outs}}(n) <= {{not}}({{ins}}(n)) {{when}} activeLow = 1 {{else}} {{ins}}(n);
        {{end}} {{generate}};

        """
      ).empty()
    } else {
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < nrOfLeds; i = i + 1)
           begin:outputs
              assign {{outs}}[i] = (activeLow == 1) ? ~{{ins}}[i] : {{ins}}[i];
           end
        endgenerate

        """
      ).empty()
    }
    return contents
  }
}

/// `com.cburch.logisim.std.io.RgbArrayLedDefaultHdlGeneratorFactory`.
public final class RgbArrayLedDefaultHdlGeneratorFactory: LedArrayLedDefaultHdlGeneratorFactory {
  public override class var hdlIdentifier: String { "RGBArrayLedDefault" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myPorts.removePorts()  // remove the ports from the super class
    myPorts
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayRedInputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 0)
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayGreenInputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 1)
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayBlueInputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 2)
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayRedOutputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 3)
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayGreenOutputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 4)
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayBlueOutputs,
        nrOfBits: Self.nrOfLedsId, componentPinId: 5)
  }

  public override class func portMap(identifier: Int) -> LineBuffer {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    return generic.genericPortMapAlligned(
      [
        (key: generic.ledArrayRedOutputs, value: "\(generic.ledArrayRedOutputs)\(identifier)"),
        (key: generic.ledArrayGreenOutputs, value: "\(generic.ledArrayGreenOutputs)\(identifier)"),
        (key: generic.ledArrayBlueOutputs, value: "\(generic.ledArrayBlueOutputs)\(identifier)"),
        (key: generic.ledArrayRedInputs, value: "s_\(generic.ledArrayRedInputs)\(identifier)"),
        (key: generic.ledArrayGreenInputs, value: "s_\(generic.ledArrayGreenInputs)\(identifier)"),
        (key: generic.ledArrayBlueInputs, value: "s_\(generic.ledArrayBlueInputs)\(identifier)"),
      ], isGeneric: false)
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("outsR", generic.ledArrayRedOutputs)
      .pair("outsG", generic.ledArrayGreenOutputs)
      .pair("outsB", generic.ledArrayBlueOutputs)
      .pair("insR", generic.ledArrayRedInputs)
      .pair("insG", generic.ledArrayGreenInputs)
      .pair("insB", generic.ledArrayBlueInputs)
      .pair("clock", TickComponentHdlGeneratorFactory.fpgaClock)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        genLeds : {{for}} n {{in}} (nrOfLeds-1) {{downto}} 0 {{generate}}
           {{outsR}}(n) <= {{not}}({{insR}}(n)) {{when}} activeLow = 1 {{else}} {{insR}}(n);
           {{outsG}}(n) <= {{not}}({{insG}}(n)) {{when}} activeLow = 1 {{else}} {{insG}}(n);
           {{outsB}}(n) <= {{not}}({{insB}}(n)) {{when}} activeLow = 1 {{else}} {{insB}}(n);
        {{end}} {{generate}};

        """
      ).empty()
    } else {
      // `[n]` inside a loop over `i` is upstream's bug, not a transcription slip, see the file
      // header.
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < nrOfLeds; i = i + 1)
           begin:outputs
              assign {{outsR}}[i] = (activeLow == 1) ? ~{{insR}}[n] : {{insR}}[n];
              assign {{outsG}}[i] = (activeLow == 1) ? ~{{insG}}[n] : {{insG}}[n];
              assign {{outsB}}[i] = (activeLow == 1) ? ~{{insB}}[n] : {{insB}}[n];
           end
        endgenerate

        """
      ).empty()
    }
    return contents
  }
}
