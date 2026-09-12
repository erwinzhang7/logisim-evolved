// SevenSegmentScanningDecodedHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/SevenSegmentScanningDecodedHdlGeneratorFactory.java`, plus the
// constants it reads from `SevenSegmentScanningGenericHdlGenerator.java` and `SevenSegment.java`.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The board-level driver for a multiplexed seven-segment display whose digit select is decoded
// (one-hot-per-digit becomes a binary column counter). Board-level, not component-level: see
// `LedArrayGenericHdlGeneratorFactory.swift`'s header. No `ComponentFactory` names it.
//
// **Not ported here:** `SevenSegmentScanningGenericHdlGenerator` itself and
// `SevenSegmendScanningSelectedHdlGenerator` (upstream's spelling). The former is the board-side
// dispatcher, parallel to `LedArrayGenericHdlGeneratorFactory` and equally dependent on the
// board model; the latter is the *other* drive mode. Neither file matches the task's
// `*HdlGeneratorFactory.java` scope, and both are reported rather than half-ported.

import LogisimKernel

/// The `SevenSegmentScanningGenericHdlGenerator` string constants this driver needs, and the
/// segment labels `SevenSegment.getLabels()` returns.
public enum SevenSegmentScanningNames {
  /// `SevenSegmentScanningGenericHdlGenerator.InternalSignalName`.
  public static let internalSignalName = "scanningSevenSegSegments"
  /// `SevenSegmentScanningGenericHdlGenerator.SevenSegmentSegmenInputs` (upstream's spelling).
  public static let segmentInputs = "allSegments"
  /// `SevenSegmentScanningGenericHdlGenerator.SevenSegmentControlOutput`.
  public static let controlOutput = "digitDecodedSelect"
  /// `SevenSegmentScanningGenericHdlGenerator.SevenSegmentSegmentOutput`.
  public static let segmentOutput = "scannedSegments";

  /// `SevenSegment.getLabels()`; index order is `Segment_A … Segment_G`, then `DP`.
  public static let labels = [
    "Segment_A", "Segment_B", "Segment_C", "Segment_D", "Segment_E", "Segment_F", "Segment_G",
    "DecimalPoint",
  ]

  public static let segmentA = 0
  public static let segmentB = 1
  public static let segmentC = 2
  public static let segmentD = 3
  public static let segmentE = 4
  public static let segmentF = 5
  public static let segmentG = 6
  public static let decimalPoint = 7
}

/// `com.cburch.logisim.std.io.SevenSegmentScanningDecodedHdlGeneratorFactory`.
public class SevenSegmentScanningDecodedHdlGeneratorFactory: AbstractHdlGeneratorFactory {
  public static let nrOfSegmentsId = -1
  public static let nrOfDigitsId = -2
  public static let nrOfControlId = -3
  public static let activeLowId = -4
  public static let scanningCounterBitsId = -5
  public static let scanningCounterValueId = -6
  public static let nrOfSegmentsString = "nrOfSegments"
  public static let nrOfDigitsString = "nrOfDigits"
  public static let nrOfControlString = "nrOfControl"
  public static let activeLowString = "activeLow"
  public static let scanningCounterBitsString = "nrOfScanningCounterBits"
  public static let scanningCounterValueString = "scanningCounterReloadValue"
  public class var hdlIdentifier: String { "SevenSegmentScanningDecoded" }

  public override init(
    subDirectory: String = IoHdl.subDirectory,
    widthAttribute: Attribute<BitWidth> = IoHdl.unusedWidthAttribute
  ) {
    super.init(subDirectory: subDirectory, widthAttribute: widthAttribute)
    myParametersList
      .add(Self.nrOfSegmentsString, Self.nrOfSegmentsId)
      .add(Self.nrOfDigitsString, Self.nrOfDigitsId)
      .add(Self.nrOfControlString, Self.nrOfControlId)
      .add(Self.activeLowString, Self.activeLowId)
      .add(Self.scanningCounterBitsString, Self.scanningCounterBitsId)
      .add(Self.scanningCounterValueString, Self.scanningCounterValueId)
    myWires
      .addWire("s_columnCounterNext", Self.nrOfControlId)
      .addWire("s_scanningCounterNext", Self.scanningCounterBitsId)
      .addWire("s_tickNext", 1)
      .addRegister("s_columnCounterReg", Self.nrOfControlId)
      .addRegister("s_scanningCounterReg", Self.scanningCounterBitsId)
      .addRegister("s_tickReg", 1)
    myPorts
      .add(
        .input, SevenSegmentScanningNames.segmentInputs, nrOfBits: Self.nrOfSegmentsId,
        componentPinId: 9
      )
      .add(
        .output, SevenSegmentScanningNames.controlOutput, nrOfBits: Self.nrOfControlId,
        componentPinId: 10
      )
      .add(.input, TickComponentHdlGeneratorFactory.fpgaClock, nrOfBits: 1, componentPinId: 11)
    var id = 0
    for segmentName in SevenSegmentScanningNames.labels {
      myPorts.add(.output, segmentName, nrOfBits: 1, componentPinId: id)
      id += 1
    }
  }

  /// `getGenericMap(int, int, long, boolean, boolean)`. `selectActiveLow` is accepted and
  /// ignored, exactly as upstream does.
  public static func genericMap(
    nrOfRows: Int, nrOfColumns: Int, fpgaClockFrequency: Int64, activeLow: Bool,
    selectActiveLow: Bool
  ) -> LineBuffer {
    let scanningReload = Int(Int32(truncatingIfNeeded: fpgaClockFrequency / 1000))
    let nrOfScanningBitsCount = LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(scanningReload)
    let nrOfControl = nrOfControlBits(nrOfDigits: nrOfRows, nrOfDecodedBits: nrOfColumns)
    return LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(
      [
        (key: nrOfSegmentsString, value: String(nrOfRows * 8)),
        (key: nrOfDigitsString, value: String(nrOfRows)),
        (key: nrOfControlString, value: String(nrOfControl)),
        (key: activeLowString, value: activeLow ? "1" : "0"),
        (key: scanningCounterBitsString, value: String(nrOfScanningBitsCount)),
        (key: scanningCounterValueString, value: String(scanningReload - 1)),
      ], isGeneric: true)
  }

  /// `nrOfControlBits(int, int)`: `max(ceil(log(nrOfDigits)/log(2)), nrOfDecodedBits)`.
  public static func nrOfControlBits(nrOfDigits: Int, nrOfDecodedBits: Int) -> Int {
    max(LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(nrOfDigits), nrOfDecodedBits)
  }

  /// `getPortMap(int)`.
  public static func portMap(identifier: Int) -> LineBuffer {
    var ports: [(key: String, value: String)] = [
      (
        key: SevenSegmentScanningNames.segmentInputs,
        value: "s_\(SevenSegmentScanningNames.internalSignalName)\(identifier)"
      ),
      (
        key: TickComponentHdlGeneratorFactory.fpgaClock,
        value: TickComponentHdlGeneratorFactory.fpgaClock
      ),
      (key: SevenSegmentScanningNames.controlOutput, value: "Displ\(identifier)Select"),
    ]
    for segmentName in SevenSegmentScanningNames.labels {
      ports.append((key: segmentName, value: "Displ\(identifier)_\(segmentName)"))
    }
    return LedArrayGenericHdlGeneratorFactory.genericPortMapAlligned(ports, isGeneric: false)
  }

  /// `getTickCounterCode()`.
  public static func tickCounterCode() -> [String] {
    let names = SevenSegmentScanningNames.self
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("clock", TickComponentHdlGeneratorFactory.fpgaClock)
      .pair("counterBits", scanningCounterBitsString)
      .pair("counterValue", scanningCounterValueString)
      .pair("digitReload", nrOfDigitsString)
      .pair("nrControlBits", nrOfControlString)
      .pair("nrOfRows", nrOfDigitsString)
      .pair("controlOutput", names.controlOutput)
      .pair("seg_a", names.labels[names.segmentA])
      .pair("seg_b", names.labels[names.segmentB])
      .pair("seg_c", names.labels[names.segmentC])
      .pair("seg_d", names.labels[names.segmentD])
      .pair("seg_e", names.labels[names.segmentE])
      .pair("seg_f", names.labels[names.segmentF])
      .pair("seg_g", names.labels[names.segmentG])
      .pair("dp", names.labels[names.decimalPoint])
      .pair("seg_a_id", names.segmentA)
      .pair("seg_b_id", names.segmentB)
      .pair("seg_c_id", names.segmentC)
      .pair("seg_d_id", names.segmentD)
      .pair("seg_e_id", names.segmentE)
      .pair("seg_f_id", names.segmentF)
      .pair("seg_g_id", names.segmentG)
      .pair("dp_id", names.decimalPoint)
      .pair("activeLow", activeLowString)
      .pair("segmentInputs", names.segmentInputs)

    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        s_tickNext <= '1' {{when}} s_scanningCounterReg = std_logic_vector(to_unsigned(0, {{counterBits}})) {{else}} '0';

        s_scanningCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                                 std_logic_vector(to_unsigned({{counterValue}}-1, {{counterBits}}))
                                    {{when}} s_tickNext = '1' {{else}}
                                 std_logic_vector(unsigned(s_scanningCounterReg)-1);

        s_columnCounterNext <= ({{others}} => '0') {{when}} s_tickReg /= '0' {{and}} s_tickReg /= '1' {{else}} -- for simulation
                               s_columnCounterReg {{when}} s_tickReg = '0' {{else}}
                               std_logic_vector(to_unsigned({{digitReload}} - 1, {{nrControlBits}}))
                                 {{when}} s_columnCounterReg = std_logic_vector(to_unsigned(0, {{nrControlBits}})) {{else}}
                               std_logic_vector(unsigned(s_columnCounterReg)-1);

        makeFlops : {{process}} ({{clock}}) {{is}}
        {{begin}}
           {{if}} (rising_edge({{clock}})) {{then}}
              s_scanningCounterReg <= s_scanningCounterNext;
              s_columnCounterReg   <= s_columnCounterNext;
              s_tickReg            <= s_tickNext;
           {{end}} {{if}};
        {{end}} {{process}} makeFlops;

        {{seg_a}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_a_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_a_id}});
        {{seg_b}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_b_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_b_id}});
        {{seg_c}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_c_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_c_id}});
        {{seg_d}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_d_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_d_id}});
        {{seg_e}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_e_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_e_id}});
        {{seg_f}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_f_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_f_id}});
        {{seg_g}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_g_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{seg_g_id}});
        {{dp}} <= {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{dp_id}}) {{when}} {{activeLow}} = 0 {{else}} {{not}} {{segmentInputs}}(to_integer(unsigned(s_columnCounterReg))*8 + {{dp_id}});

        """
      ).empty()
    } else {
      contents.add(
        """

        assign s_tickNext = (s_scanningCounterReg == 0) ? 1'b1 : 1'b0;
        assign s_scanningCounterNext = (s_scanningCounterReg == 0) ? {{counterValue}} : s_scanningCounterReg - 1;
        assign s_columnCounterNext =  (s_tickReg == 1'b0) ? s_columnCounterReg : (s_columnCounterReg == 0) ? {{digitReload}} - 1 : s_columnCounterReg - 1;

        assign {{seg_a}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_a_id}}] ^ activeLow;
        assign {{seg_b}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_b_id}}] ^ activeLow;
        assign {{seg_c}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_c_id}}] ^ activeLow;
        assign {{seg_d}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_d_id}}] ^ activeLow;
        assign {{seg_e}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_e_id}}] ^ activeLow;
        assign {{seg_f}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_f_id}}] ^ activeLow;
        assign {{seg_g}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{seg_g_id}}] ^ activeLow;
        assign {{dp}} = {{segmentInputs}}[s_columnCounterReg * 8 + {{dp_id}}] ^ activeLow;

        """
      )
      .addRemarkBlock("Here the simulation only initial is defined")
      .add(
        """
        initial
        begin
           s_scanningCounterReg = 0;
           s_columnCounterReg   = 0;
           s_tickReg            = 1'b0;
        end

        always @(posedge {{clock}})
        begin
            s_scanningCounterReg = s_scanningCounterNext;
            s_columnCounterReg   = s_columnCounterNext;
            s_tickReg            = s_tickNext;
        end

        """
      ).empty()
    }
    return contents.get()
  }

  /// `getDecoderCounterCode()`.
  public static func decoderCounterCode() -> [String] {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("controlOutput", SevenSegmentScanningNames.controlOutput)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        {{controlOutput}} <= s_columnCounterReg;

        """
      ).empty()
    } else {
      contents.add(
        """
        assign {{controlOutput}} = s_columnCounterReg;

        """
      ).empty()
    }
    return contents.get()
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    LineBuffer.getHdlBuffer()
      .add(Self.tickCounterCode())
      .add(Self.decoderCounterCode())
  }
}
