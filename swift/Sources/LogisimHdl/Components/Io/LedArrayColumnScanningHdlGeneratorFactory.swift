// LedArrayColumnScanningHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/LedArrayColumnScanningHdlGeneratorFactory.java` and
// `RgbArrayColumnScanningHdlGeneratorFactory.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Column-scanned LED matrix drivers, the transpose of the row-scanned pair. Board-level, not
// component-level: see `LedArrayGenericHdlGeneratorFactory.swift`'s header.
//
// Upstream oddities reproduced verbatim (standing rule 4):
//   * the VHDL column counter writes a bare `ELSE` where every neighbouring line uses
//     `{{else}}`, and misspells the generic as `nrOfcolumnAddressBits` (lower-case `c`) in the
//     `to_unsigned(nrOfColumns-1, …)` argument, so the generated VHDL references an undeclared
//     generic;
//   * `RgbArrayColumnScanning`'s Verilog body writes `{{insR }}` with a trailing space inside
//     the placeholder. `LineBuffer` trims placeholder keys, so it resolves, but the port must
//     keep the spelling, because a key that failed to trim would abort instead.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.std.io.LedArrayColumnScanningHdlGeneratorFactory`.
public class LedArrayColumnScanningHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  public static let nrOfLedsId = -1
  public static let nrOfRowsId = -2
  public static let nrOfColumnsId = -3
  public static let nrOfColumnAddressBitsId = -4
  public static let activeLowId = -5
  public static let scanningCounterBitsId = -6
  public static let maxNrLedsId = -7
  public static let scanningCounterValueId = -8
  public static let nrOfRowsString = "nrOfRows"
  public static let nrOfColumnsString = "nrOfColumns"
  public static let nrOfLedsString = "nrOfLeds"
  public static let nrOfColumnAddressBitsString = "nrOfColumnAddressBits"
  public static let scanningCounterBitsString = "nrOfScanningCounterBits"
  public static let scanningCounterValueString = "scanningCounterReloadValue"
  public static let maxNrLedsString = "maxNrLedsAddrColumns"
  public static let activeLowString = "activeLow"
  public class var hdlIdentifier: String { "LedArrayColumnScanning" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myParametersList
      .add(Self.activeLowString, Self.activeLowId)
      .add(Self.maxNrLedsString, Self.maxNrLedsId)
      .add(Self.nrOfColumnsString, Self.nrOfColumnsId)
      .add(Self.nrOfColumnAddressBitsString, Self.nrOfColumnAddressBitsId)
      .add(Self.nrOfLedsString, Self.nrOfLedsId)
      .add(Self.nrOfRowsString, Self.nrOfRowsId)
      .add(Self.scanningCounterBitsString, Self.scanningCounterBitsId)
      .add(Self.scanningCounterValueString, Self.scanningCounterValueId)
    myWires
      .addWire("s_columnCounterNext", Self.nrOfColumnAddressBitsId)
      .addWire("s_scanningCounterNext", Self.scanningCounterBitsId)
      .addWire("s_tickNext", 1)
      .addWire("s_maxLedInputs", Self.maxNrLedsId)
      .addRegister("s_columnCounterReg", Self.nrOfColumnAddressBitsId)
      .addRegister("s_scanningCounterReg", Self.scanningCounterBitsId)
      .addRegister("s_tickReg", 1)
    myPorts
      .add(.input, TickComponentHdlGeneratorFactory.fpgaClock, nrOfBits: 1, componentPinId: 0)
      .add(
        .input, LedArrayGenericHdlGeneratorFactory.ledArrayInputs, nrOfBits: Self.nrOfLedsId,
        componentPinId: 1
      )
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayColumnAddress,
        nrOfBits: Self.nrOfColumnAddressBitsId, componentPinId: 2
      )
      .add(
        .output, LedArrayGenericHdlGeneratorFactory.ledArrayRowOutputs,
        nrOfBits: Self.nrOfRowsId, componentPinId: 3)
  }

  /// `getGenericMap(int, int, long, boolean)`.
  public static func genericMap(
    nrOfRows: Int, nrOfColumns: Int, fpgaClockFrequency: Int64, activeLow: Bool
  ) -> LineBuffer {
    let nrColAddrBits = LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(nrOfColumns)
    let scanningReload = Int(Int32(truncatingIfNeeded: fpgaClockFrequency / 1000))
    let nrOfScanningBitsCount = LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(scanningReload)
    let maxNrLeds = Int(pow(2.0, Double(nrColAddrBits))) * nrOfRows
    return LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(
      [
        (key: nrOfLedsString, value: String(nrOfRows * nrOfColumns)),
        (key: maxNrLedsString, value: String(maxNrLeds)),
        (key: nrOfRowsString, value: String(nrOfRows)),
        (key: nrOfColumnsString, value: String(nrOfColumns)),
        (key: activeLowString, value: activeLow ? "1" : "0"),
        (key: nrOfColumnAddressBitsString, value: String(nrColAddrBits)),
        (key: scanningCounterBitsString, value: String(nrOfScanningBitsCount)),
        (key: scanningCounterValueString, value: String(scanningReload - 1)),
      ], isGeneric: true)
  }

  /// `getPortMap(int)`.
  public class func portMap(identifier: Int) -> LineBuffer {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    return generic.genericPortMapAlligned(
      [
        (
          key: generic.ledArrayColumnAddress,
          value: "\(generic.ledArrayColumnAddress)\(identifier)"
        ),
        (key: generic.ledArrayRowOutputs, value: "\(generic.ledArrayRowOutputs)\(identifier)"),
        (
          key: TickComponentHdlGeneratorFactory.fpgaClock,
          value: TickComponentHdlGeneratorFactory.fpgaClock
        ),
        (key: generic.ledArrayInputs, value: "s_\(generic.ledArrayInputs)\(identifier)"),
      ], isGeneric: false)
  }

  /// `getColumnCounterCode()`.
  public static func columnCounterCode() -> [String] {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("columnAddress", LedArrayGenericHdlGeneratorFactory.ledArrayColumnAddress)
      .pair("clock", TickComponentHdlGeneratorFactory.fpgaClock)
      .pair("counterBits", scanningCounterBitsString)
      .pair("counterValue", scanningCounterValueString)

    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """

        {{columnAddress}} <= s_columnCounterReg;

        s_tickNext <= '1' {{when}} s_scanningCounterReg = std_logic_vector(to_unsigned(0, {{counterBits}})) {{else}} '0';

        s_scanningCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                                 std_logic_vector(to_unsigned({{counterValue}}-1, {{counterBits}}))
                                    {{when}} s_scanningCounterReg = std_logic_vector(to_unsigned(0, {{counterBits}})) {{else}}
                                 std_logic_vector(unsigned(s_scanningCounterReg)-1);

        s_columnCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                               s_columnCounterReg {{when}} s_tickReg = '0' ELSE
                               std_logic_vector(to_unsigned(nrOfColumns-1,nrOfcolumnAddressBits))
                                  {{when}} s_columnCounterReg = std_logic_vector(to_unsigned(0,nrOfColumnAddressBits)) {{else}}
                               std_logic_vector(unsigned(s_columnCounterReg)-1);

        makeFlops : {{process}} ({{clock}}) {{is}}
        {{begin}}
           {{if}} (rising_edge({{clock}})) {{then}}
              s_columnCounterReg   <= s_columnCounterNext;
              s_scanningCounterReg <= s_scanningCounterNext;
              s_tickReg            <= s_tickNext;
           {{end}} {{if}};
        {{end}} {{process}} makeFlops;

        """
      ).empty()
    } else {
      contents
        .add(
          """

          assign columnAddress = s_columnCounterReg;

          assign s_tickNext = (s_scanningCounterReg == 0) ? 1'b1 : 1'b0;
          assign s_scanningCounterNext = (s_scanningCounterReg == 0) ? {{counterValue}} : s_scanningCounterReg - 1;
          assign s_columnCounterNext = (s_tickReg == 1'b0) ? s_columnCounterReg :
                                       (s_columnCounterReg == 0) ? nrOfColumns-1 : s_columnCounterReg-1;

          """
        )
        .addRemarkBlock("Here the simulation only initial is defined")
        .add(
          """
          initial
          begin
             s_columnCounterReg   = 0;
             s_scanningCounterReg = 0;
             s_tickReg            = 1'b0;
          end

          always @(posedge {{clock}})
          begin
              s_columnCounterReg   = s_columnCounterNext;
              s_scanningCounterReg = s_scanningCounterNext;
              s_tickReg            = s_tickNext;
          end

          """
        )
      // NB: upstream's Verilog branch has **no** trailing `.empty()`, unlike the VHDL branch
      // and unlike the row-scanning class. Adding one would insert a blank line the jar does
      // not emit.
    }
    return contents.get()
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("ins", LedArrayGenericHdlGeneratorFactory.ledArrayInputs)
      .pair("outs", LedArrayGenericHdlGeneratorFactory.ledArrayRowOutputs)
      .pair("nrOfLeds", Self.nrOfLedsString)
      .pair("nrOfRows", Self.nrOfRowsString)
      .pair("activeLow", Self.activeLowString)
      .add(Self.columnCounterCode())
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        makeVirtualInputs : {{process}} ( internalLeds ) {{is}}
        {{begin}}
           s_maxLedInputs <= ({{others}} => '0');
           {{if}} ({{activeLow}} = 1) {{then}}
              s_maxLedInputs( {{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{ins}};
           {{else}}
              s_maxLedInputs( {{nrOfLeds}}-1 {{downto}} 0) <= {{ins}};
           {{end}} {{if}};
        {{end}} {{process}} makeVirtualInputs;

        genOutputs : {{for}} n {{in}} {{nrOfRows}}-1 {{downto}} 0 {{generate}}
           {{outs}}(n) <= s_maxLedInputs(to_integer(unsigned(s_columnCounterReg)) + n*nrOfColumns);
        {{end}} {{generate}} genOutputs;

        """
      ).empty()
    } else {
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < {{nrOfRows}}; i = i + 1)
           begin: outputs
              assign {{outs}}[i] = (activeLow == 1)
                  ? ~{{ins}}[i * nrOfColumns + s_columnCounterReg]
                  :  {{ins}}[i * nrOfColumns + s_columnCounterReg];
           end
        endgenerate

        """
      ).empty()
    }
    return contents
  }
}

/// `com.cburch.logisim.std.io.RgbArrayColumnScanningHdlGeneratorFactory`.
public final class RgbArrayColumnScanningHdlGeneratorFactory:
  LedArrayColumnScanningHdlGeneratorFactory
{
  public override class var hdlIdentifier: String { "RGBArrayColumnScanning" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myWires
      .addWire("s_maxRedLedInputs", Self.maxNrLedsId)
      .addWire("s_maxBlueLedInputs", Self.maxNrLedsId)
      .addWire("s_maxGreenLedInputs", Self.maxNrLedsId)
    myPorts.removePorts()  // remove the ports from the super class
    let generic = LedArrayGenericHdlGeneratorFactory.self
    myPorts
      .add(.input, TickComponentHdlGeneratorFactory.fpgaClock, nrOfBits: 1, componentPinId: 0)
      .add(.input, generic.ledArrayRedInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 1)
      .add(.input, generic.ledArrayGreenInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 2)
      .add(.input, generic.ledArrayBlueInputs, nrOfBits: Self.nrOfLedsId, componentPinId: 3)
      .add(
        .output, generic.ledArrayColumnAddress, nrOfBits: Self.nrOfColumnAddressBitsId,
        componentPinId: 4
      )
      .add(.output, generic.ledArrayRowRedOutputs, nrOfBits: Self.nrOfRowsId, componentPinId: 5)
      .add(.output, generic.ledArrayRowGreenOutputs, nrOfBits: Self.nrOfRowsId, componentPinId: 6)
      .add(.output, generic.ledArrayRowBlueOutputs, nrOfBits: Self.nrOfRowsId, componentPinId: 7)
  }

  public override class func portMap(identifier: Int) -> LineBuffer {
    let generic = LedArrayGenericHdlGeneratorFactory.self
    return generic.genericPortMapAlligned(
      [
        (
          key: generic.ledArrayColumnAddress,
          value: "\(generic.ledArrayColumnAddress)\(identifier)"
        ),
        (
          key: TickComponentHdlGeneratorFactory.fpgaClock,
          value: TickComponentHdlGeneratorFactory.fpgaClock
        ),
        (
          key: generic.ledArrayRowRedOutputs, value: "\(generic.ledArrayRowRedOutputs)\(identifier)"
        ),
        (
          key: generic.ledArrayRowGreenOutputs,
          value: "\(generic.ledArrayRowGreenOutputs)\(identifier)"
        ),
        (
          key: generic.ledArrayRowBlueOutputs,
          value: "\(generic.ledArrayRowBlueOutputs)\(identifier)"
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
      .pair("nrOfLeds", Self.nrOfLedsString)
      .pair("nrOfRows", Self.nrOfRowsString)
      .pair("activeLow", Self.activeLowString)
      .pair("insR", generic.ledArrayRedInputs)
      .pair("insG", generic.ledArrayGreenInputs)
      .pair("insB", generic.ledArrayBlueInputs)
      .pair("outsR", generic.ledArrayRowRedOutputs)
      .pair("outsG", generic.ledArrayRowGreenOutputs)
      .pair("outsB", generic.ledArrayRowBlueOutputs)

    contents.add(Self.columnCounterCode())
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        makeVirtualInputs : {{process}} ( internalRedLeds, internalGreenLeds, internalBlueLeds ) {{is}}
        {{begin}}
           s_maxRedLedInputs <= ({{others}} => '0');
           s_maxGreenLedInputs <= ({{others}} => '0');
           s_maxBlueLedInputs <= ({{others}} => '0');
           {{if}} ({{activeLow}} = 1) {{then}}
              s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0)   <= {{not}} {{insR}};
              s_maxGreenLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{not}} {{insG}};
              s_maxBlueLedInputs({{nrOfLeds}}-1 {{downto}} 0)  <= {{not}} {{insB}};
           {{else}}
              s_maxRedLedInputs({{nrOfLeds}}-1 {{downto}} 0)   <= {{insR}};
              s_maxGreenLedInputs({{nrOfLeds}}-1 {{downto}} 0) <= {{insG}};
              s_maxBlueLedInputs({{nrOfLeds}}-1 {{downto}} 0)  <= {{insB}};
           {{end}} {{if}};
        {{end}} {{process}} makeVirtualInputs;

        genOutputs : {{for}} n {{in}} {{nrOfRows}}-1 {{downto}} 0 {{generate}}
           {{outsR}}(n) <= s_maxRedLedInputs(to_integer(unsigned(s_columnCounterReg)) + n*nrOfColumns);
           {{outsG}}(n) <= s_maxGreenLedInputs(to_integer(unsigned(s_columnCounterReg)) + n*nrOfColumns);
           {{outsB}}(n) <= s_maxBlueLedInputs(to_integer(unsigned(s_columnCounterReg)) + n*nrOfColumns);
        {{end}} {{generate}} genOutputs;

        """
      ).empty()
    } else {
      contents.add(
        """
        genvar i;
        generate
           for (i = 0; i < {{nrOfRows}}; i = i + 1)
           begin:outputs
              assign {{outsR}}[i] = (activeLow == 1)
                  ? ~{{insR }}[i*nrOfColumns+s_columnCounterReg]
                  :  {{insR }}[i*nrOfColumns+s_columnCounterReg];
              assign {{outsG}}[i] = (activeLow == 1)
                  ? ~{{insG }}[i*nrOfColumns+s_columnCounterReg]
                  :  {{insG }}[i*nrOfColumns+s_columnCounterReg];
              assign {{outsB}}[i] = (activeLow == 1)
                  ? ~{{insB }}[i*nrOfColumns+s_columnCounterReg]
                  :  {{insB }}[i*nrOfColumns+s_columnCounterReg];
           end
        endgenerate

        """
      ).empty()
    }
    return contents
  }
}
