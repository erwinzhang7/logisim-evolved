// LedArrayRowScanningHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/LedArrayRowScanningHdlGeneratorFactory.java` and
// `RgbArrayRowScanningHdlGeneratorFactory.java`. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Row-scanned LED matrix drivers: a counter walks the rows, the column outputs carry the
// currently-addressed row's LEDs. Board-level, not component-level: see
// `LedArrayGenericHdlGeneratorFactory.swift`'s header.
//
// ── Three upstream defects reproduced verbatim (standing rule 4) ─────────────────────────────
//
//  1. `LedArrayRowScanning`'s VHDL body writes `{{generate{{` instead of `{{generate}}`. It is
//     not a placeholder (`LineBuffer`'s scanner needs a closing `}}` on the same line), so the
//     literal text `{{generate{{` lands in the generated VHDL. Confirmed in the jar's output.
//  2. `RgbArrayRowScanning`'s VHDL body assigns all three colour channels from
//     `s_maxRedLedInputs`, and drives `s_maxRedLedInputs` three times from the red, green and
//     blue inputs in turn, so green and blue are dropped and the last assignment wins.
//  3. **`RgbArrayRowScanning` cannot generate an architecture at all, in either language.** Its
//     bodies use `{{insR}}`/`{{outsR}}` and friends, and the pairs that would define them live
//     in a `static final LineBuffer.Pairs sharedPairs` field that is **never applied to the
//     buffer**. So `LineBuffer.abort` raises and `getArchitecture` throws: measured from the
//     jar for BOTH VHDL (`#E006: No mapping for 'insR' ...`) and Verilog
//     (`#E006: No mapping for 'outsR' ...`), recorded as `<throws ...>` in
//     `tools/hdlbridge/io-4.1.0.oracle`. The port therefore also leaves the pairs uninstalled;
//     an earlier draft "helpfully" added them and produced VHDL upstream cannot emit, which
//     only the differential gate caught. Its Verilog body additionally ends with a stray
//     `endgenerate" +`, a fragment of an older concatenated string.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.std.io.LedArrayRowScanningHdlGeneratorFactory`.
public class LedArrayRowScanningHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  public static let nrOfLedsId = -1
  public static let nrOfRowsId = -2
  public static let nrOfColumnsId = -3
  public static let nrOfRowAddressBitsId = -4
  public static let activeLowId = -5
  public static let scanningCounterBitsId = -6
  public static let maxNrLedsId = -7
  public static let scanningCounterValueId = -8
  public static let nrOfRowsString = "nrOfRows"
  public static let nrOfColumnsString = "nrOfColumns"
  public static let nrOfLedsString = "nrOfLeds"
  public static let nrOfRowAddressBitsString = "nrOfRowAddressBits"
  public static let activeLowString = "activeLow"
  public static let scanningCounterBitsString = "nrOfScanningCounterBits"
  public static let scanningCounterValueString = "scanningCounterReloadValue"
  public static let maxNrLedsString = "maxNrLedsAddrColumns"
  public class var hdlIdentifier: String { "LedArrayRowScanning" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myParametersList
      .add(Self.activeLowString, Self.activeLowId)
      .add(Self.maxNrLedsString, Self.maxNrLedsId)
      .add(Self.nrOfColumnsString, Self.nrOfColumnsId)
      .add(Self.nrOfLedsString, Self.nrOfLedsId)
      .add(Self.nrOfRowsString, Self.nrOfRowsId)
      .add(Self.nrOfRowAddressBitsString, Self.nrOfRowAddressBitsId)
      .add(Self.scanningCounterBitsString, Self.scanningCounterBitsId)
      .add(Self.scanningCounterValueString, Self.scanningCounterValueId)
    myWires
      .addWire("s_rowCounterNext", Self.nrOfRowAddressBitsId)
      .addWire("s_scanningCounterNext", Self.scanningCounterBitsId)
      .addWire("s_tickNext", 1)
      .addWire("s_maxLedInputs", Self.maxNrLedsId)
      .addRegister("s_rowCounterReg", Self.nrOfRowAddressBitsId)
      .addRegister("s_scanningCounterReg", Self.scanningCounterBitsId)
      .addRegister("s_tickReg", 1)
    myPorts
      .add(
        .input, TickComponentHdlGeneratorFactory.fpgaClock, nrOfBits: 1, componentPinId: 0
      )
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayInputs, nrOfBits: Self.nrOfLedsId,
        componentPinId: 1
      )
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayRowAddress,
        nrOfBits: Self.nrOfRowAddressBitsId, componentPinId: 2
      )
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayColumnOutputs,
        nrOfBits: Self.nrOfColumnsId, componentPinId: 3)
  }

  /// `getGenericMap(int, int, long, boolean)`.
  public static func genericMap(
    nrOfRows: Int, nrOfColumns: Int, fpgaClockFrequency: Int64, activeLow: Bool
  ) -> LineBuffer {
    let nrRowAddrBits = LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(nrOfRows)
    // `(int) (FpgaClockFrequency / 1000)`: a *long* division narrowed to int, so a frequency
    // above 2^31 * 1000 would wrap in Java. Reproduced with the 32-bit truncation intact.
    let scanningReload = Int(Int32(truncatingIfNeeded: fpgaClockFrequency / 1000))
    let nrOfScanningBits = LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(scanningReload)
    let maxNrLeds = Int(Foundation.pow(2.0, Double(nrRowAddrBits))) * nrOfRows
    return LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(
      [
        (key: nrOfLedsString, value: String(nrOfRows * nrOfColumns)),
        (key: nrOfRowsString, value: String(nrOfRows)),
        (key: nrOfColumnsString, value: String(nrOfColumns)),
        (key: nrOfRowAddressBitsString, value: String(nrRowAddrBits)),
        (key: scanningCounterBitsString, value: String(nrOfScanningBits)),
        (key: scanningCounterValueString, value: String(scanningReload - 1)),
        (key: maxNrLedsString, value: String(maxNrLeds)),
        (key: activeLowString, value: activeLow ? "1" : "0"),
      ], isGeneric: true)
  }

  /// `getPortMap(int)`.
  public class func portMap(identifier: Int) -> LineBuffer {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    return generic.genericPortMapAlligned(
      [
        (key: generic.ledArrayRowAddress, value: "\(generic.ledArrayRowAddress)\(identifier)"),
        (
          key: generic.ledArrayColumnOutputs,
          value: "\(generic.ledArrayColumnOutputs)\(identifier)"
        ),
        (
          key: TickComponentHdlGeneratorFactory.fpgaClock,
          value: TickComponentHdlGeneratorFactory.fpgaClock
        ),
        (key: generic.ledArrayInputs, value: "s_\(generic.ledArrayInputs)\(identifier)"),
      ], isGeneric: false)
  }

  /// `getRowCounterCode()`.
  public static func rowCounterCode() -> [String] {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("rowAddress", LedArrayGenericHdlGeneratorFactory.ledArrayRowAddress)
      .pair("bits", scanningCounterBitsString)
      .pair("value", scanningCounterValueString)
      .pair("clock", TickComponentHdlGeneratorFactory.fpgaClock)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """

        {{rowAddress}} <= s_rowCounterReg;

        s_tickNext <= '1' {{when}} s_scanningCounterReg = std_logic_vector(to_unsigned(0, {{bits}})) {{else}} '0';

        s_scanningCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                                 std_logic_vector(to_unsigned({{value}}-1, {{bits}})) {{when}} s_scanningCounterReg = std_logic_vector(to_unsigned(0, {{bits}})) {{else}}
                                 std_logic_vector(unsigned(s_scanningCounterReg)-1);

        s_rowCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                            s_rowCounterReg {{when}} s_tickReg = '0' {{else}}
                            std_logic_vector(to_unsigned(nrOfRows-1,nrOfRowAddressBits))
                               {{when}} s_rowCounterReg = std_logic_vector(to_unsigned(0,nrOfRowAddressBits)) {{else}}
                            std_logic_vector(unsigned(s_rowCounterReg)-1);

        makeFlops : {{process}} ({{clock}}) {{is}}
        {{begin}}
           {{if}} (rising_edge({{clock}})) {{then}}
              s_rowCounterReg      <= s_rowCounterNext;
              s_scanningCounterReg <= s_scanningCounterNext;
              s_tickReg            <= s_tickNext;
           {{end}} {{if}};
        {{end}} {{process}} makeFlops;

        """
      ).empty()
    } else {
      contents.add(
        """

        assign rowAddress = s_rowCounterReg;

        assign s_tickNext = (s_scanningCounterReg == 0) ? 1'b1 : 1'b0;
        assign s_scanningCounterNext = (s_scanningCounterReg == 0) ? {{value}} : s_scanningCounterReg - 1;
        assign s_rowCounterNext = (s_tickReg == 1'b0) ? s_rowCounterReg :
                                  (s_rowCounterReg == 0) ? nrOfRows-1 : s_rowCounterReg-1;

        """
      )
      .addRemarkBlock("Here the simulation only initial is defined")
      .add(
        """
        initial
        begin
           s_rowCounterReg      = 0;
           s_scanningCounterReg = 0;
           s_tickReg            = 1'b0;
        end

        always @(posedge {{clock}})
        begin
            s_rowCounterReg      = s_rowCounterNext;
            s_scanningCounterReg = s_scanningCounterNext;
            s_tickReg            = s_tickNext;
        end

        """
      )
      .empty()
    }
    return contents.get()
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("ins", LedArrayGenericHdlGeneratorFactory.ledArrayInputs)
      .pair("outs", LedArrayGenericHdlGeneratorFactory.ledArrayColumnOutputs)
      .pair("activeLow", Self.activeLowString)
      .pair("nrOfLeds", Self.nrOfLedsString)
      .pair("nrOfColumns", Self.nrOfColumnsString)
      .add(Self.rowCounterCode())
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        makeVirtualInputs : {{process}} ( internalLeds ) {{is}}
        {{begin}}
           s_maxLedInputs <= ({{others}} => '0');
           {{if}} ({{activeLow}} = 1) {{then}}
              s_maxLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{ins}};
           {{else}}
              s_maxLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{ins}};
           {{end}} {{if}};
        {{end}} {{process}} makeVirtualInputs;

        genOutputs : {{for}} n {{in}} {{nrOfColumns}}-1 {{downto}} 0 {{generate{{
           {{outs}}(n) <= s_maxLedInputs({{nrOfColumns}} * to_integer(unsigned(s_rowCounterReg)) + n);
        {{end}} {{generate}} genOutputs;

        """
      ).empty()
    } else {
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < {{nrOfColumns}}; i = i + 1)
           begin:outputs
              assign {{outs}}[i] = (activeLow == 1)
                 ? ~{{ins}}[{{nrOfColumns}} * s_rowCounterReg + i]
                 :  {{ins}}[{{nrOfColumns}} * s_rowCounterReg + i];
           end
        endgenerate

        """
      ).empty()
    }
    return contents
  }
}

/// `com.cburch.logisim.std.io.RgbArrayRowScanningHdlGeneratorFactory`.
public final class RgbArrayRowScanningHdlGeneratorFactory: LedArrayRowScanningHdlGeneratorFactory
{
  public override class var hdlIdentifier: String { "RGBArrayRowScanning" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myWires
      .addWire("s_maxRedLedInputs", Self.maxNrLedsId)
      .addWire("s_maxBlueLedInputs", Self.maxNrLedsId)
      .addWire("s_maxGreenLedInputs", Self.maxNrLedsId)
    myPorts.removePorts()  // remove the ports of the super class
    let generic = LedArrayGenericHdlGeneratorFactory.self
    myPorts
      .add(.input, TickComponentHdlGeneratorFactory.fpgaClock, nrOfBits: 1, componentPinId: 0)
      .add(.input, generic.ledArrayRedInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 1)
      .add(.input, generic.ledArrayGreenInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 2)
      .add(.input, generic.ledArrayBlueInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 3)
      .add(
        .output, generic.ledArrayRowAddress, nrOfBits: Self.nrOfRowAddressBitsId,
        componentPinId: 4
      )
      .add(
        .output, generic.ledArrayColumnRedOutputs, nrOfBits: Self.nrOfColumnsId, componentPinId: 5
      )
      .add(
        .output, generic.ledArrayColumnGreenOutputs, nrOfBits: Self.nrOfColumnsId,
        componentPinId: 6
      )
      .add(
        .output, generic.ledArrayColumnBlueOutputs, nrOfBits: Self.nrOfColumnsId, componentPinId: 7
      )
  }

  public override class func portMap(identifier: Int) -> LineBuffer {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    return generic.genericPortMapAlligned(
      [
        (key: generic.ledArrayRowAddress, value: "\(generic.ledArrayRowAddress)\(identifier)"),
        (
          key: generic.ledArrayColumnRedOutputs,
          value: "\(generic.ledArrayColumnRedOutputs)\(identifier)"
        ),
        (
          key: generic.ledArrayColumnGreenOutputs,
          value: "\(generic.ledArrayColumnGreenOutputs)\(identifier)"
        ),
        (
          key: generic.ledArrayColumnBlueOutputs,
          value: "\(generic.ledArrayColumnBlueOutputs)\(identifier)"
        ),
        (
          key: TickComponentHdlGeneratorFactory.fpgaClock,
          value: TickComponentHdlGeneratorFactory.fpgaClock
        ),
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
      .pair("activeLow", Self.activeLowString)
      .pair("nrOfLeds", Self.nrOfLedsString)
      .pair("nrOfColumns", Self.nrOfColumnsString)
    contents.add(Self.rowCounterCode())
    if Hdl.isVhdl() {
      // **The pairs are deliberately NOT installed**; see the file header. Upstream declares
      // `sharedPairs` and never applies it, so `{{insR}}` and friends are unmapped and
      // `LineBuffer.abort` raises. Measured from the jar: the VHDL branch throws
      // `#E006: No mapping for 'insR' …`, exactly as the Verilog branch does. Installing them
      // here (which an earlier draft of this port did) makes the port emit VHDL that upstream
      // cannot produce: a divergence invisible to anything but this gate.
      contents.addVhdlKeywords()
        .add(
          """
          makeVirtualInputs : {{process}} ( internalRedLeds, internalGreenLeds, internalBlueLeds ) {{is}}
          {{begin}}
             s_maxRedLedInputs <= ({{others}} => '0');
             s_maxGreenLedInputs <= ({{others}} => '0');
             s_maxBlueLedInputs <= ({{others}} => '0');
             {{if}} ({{activeLow}} = 1) {{then}}
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{insR}};
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{insG}};
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{insB}};
             {{else}}
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{insR}};
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{insG}};
                s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{insB}};
             {{end}} {{if}};
          {{end}} {{process}} makeVirtualInputs;

          genOutputs : {{for}} n {{in}} {{nrOfColumns}}-1 {{downto}} 0 {{generate}}
             {{outsR}}(n) <= s_maxRedLedInputs({{nrOfColumns}} * to_integer(unsigned(s_rowCounterReg)) + n);
             {{outsG}}(n) <= s_maxRedLedInputs({{nrOfColumns}} * to_integer(unsigned(s_rowCounterReg)) + n);
             {{outsB}}(n) <= s_maxRedLedInputs({{nrOfColumns}} * to_integer(unsigned(s_rowCounterReg)) + n);
          {{end}} {{generate}} genOutputs;

          """
        ).empty()
    } else {
      // **Upstream throws here.** The Verilog body references `{{outsR}}`, `{{insR}}` and the
      // rest, and this method never installs them (the class's `sharedPairs` field is dead
      // code), so `LineBuffer.abort` raises `#E006: No mapping for 'outsR' …`. The pairs are
      // deliberately NOT installed here either: the port must fail the same way rather than
      // emit text upstream cannot produce. `LineBuffer`'s Swift port turns that abort into a
      // `preconditionFailure`, which is correct under D13; it is a defect in a generator's own
      // source, not something a `.circ` file can reach.
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < {{nrOfColumns}}; i = i + 1)
           begin:outputs
              assign {{outsR}}[i] = (activeLow == 1)
                 ? ~{{insR}}[{{nrOfColumns}} * s_rowCounterReg + i]
                 :  {{insR}}[{{nrOfColumns}} * s_rowCounterReg + i];
              assign {{outsG}}[i] = (activeLow == 1)
                 ? ~{{insG}}[{{nrOfColumns}} * s_rowCounterReg + i]
                 :  {{insG}}[{{nrOfColumns}} * s_rowCounterReg + i];
              assign {{outsB}}[i] = (activeLow == 1)
                 ? ~{{insB}}[{{nrOfColumns}} * s_rowCounterReg + i]
                 :  {{insB}}[{{nrOfColumns}} * s_rowCounterReg + i];
           end
        endgenerate" +

        """
      ).empty()
    }
    return contents
  }
}
