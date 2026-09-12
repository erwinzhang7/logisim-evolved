// ReptarLocalBusHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/ReptarLocalBusHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The one io component that becomes its own VHDL entity: the local bus of the Reptar/Spartan-6
// board. It is Xilinx-specific (`Library UNISIM`, `IOBUF` primitives), which is why
// `isHdlSupportedTarget` is `Hdl.isVhdl()`; there is no Verilog form at all, and
// `AbstractComponentFactory.getHDLGenerator` therefore answers **null** for this component when
// the target language is Verilog. Confirmed against the jar.
//
// The entity/architecture/component text is a hand-written literal upstream, not built from
// `myPorts`, and it does not agree with itself: the architecture's `generic map` is missing a
// comma after `IOSTANDARD => "LVCMOS18"`, so the emitted VHDL does not compile. That is 4.1.0's
// output and it is reproduced byte-for-byte (standing rule 4) rather than quietly repaired;
// the port's job here is to match, and a "fix" would be an undetectable divergence.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.ReptarLocalBusHdlGeneratorFactory`.
public final class ReptarLocalBusHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  /// `ReptarLocalBus`'s port indices.
  public enum PortIndex {
    public static let cs3Out = 0
    public static let advAleOut = 1
    public static let reOeOut = 2
    public static let weOut = 3
    public static let wait3In = 4
    public static let addrDataOut = 5
    public static let addrDataIn = 6
    public static let addrDataTrisIn = 7
    public static let addrOut = 8
    public static let irqIn = 9
  }

  /// `StdAttr.LABEL`, injected: `AbstractHdlGeneratorFactory.getInstanceIdentifier` needs it to
  /// name the instance `LocalBus` rather than falling back to `IO_<id>`. See
  /// `AbstractHdlGeneratorFactory.swift`'s header on the two StdAttr-shaped seams.
  public init(labelAttribute: AnyAttribute? = StdAttr.label) {
    super.init(subDirectory: IoHdl.subDirectory, widthAttribute: IoHdl.unusedWidthAttribute)
    self.labelAttribute = labelAttribute
    myPorts
      .add(.inout_, "Addr_Data_LB_io", nrOfBits: 16, componentPinId: 0)
      .add(.input, "SP6_LB_WAIT3_i", nrOfBits: 1, componentPinId: PortIndex.wait3In)
      .add(.input, "IRQ_i", nrOfBits: 1, componentPinId: PortIndex.irqIn)
      .add(.output, "SP6_LB_nCS3_o", nrOfBits: 1, componentPinId: PortIndex.cs3Out)
      .add(.output, "SP6_LB_nADV_ALE_o", nrOfBits: 1, componentPinId: PortIndex.advAleOut)
      .add(.output, "SP6_LB_RE_nOE_o", nrOfBits: 1, componentPinId: PortIndex.reOeOut)
      .add(.output, "SP6_LB_nWE_o", nrOfBits: 1, componentPinId: PortIndex.weOut)
      .add(.output, "Addr_LB_o", nrOfBits: 9, componentPinId: PortIndex.addrOut)
  }

  public override func getArchitecture(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> [String]? {
    let contents = LineBuffer.getBuffer()
    guard Hdl.isVhdl() else { return contents.get() }
    contents
      .pair("compName", componentName)
      .add(HdlFileWriter.generateRemark(componentName: componentName, projName: netlist.projName))
      .add(
        """

        ARCHITECTURE PlatformIndependent OF {{compName}} IS

        BEGIN

        FPGA_out(0) <= NOT SP6_LB_WAIT3_i;
        FPGA_out(1) <= NOT IRQ_i;
        SP6_LB_nCS3_o       <= FPGA_in(0);
        SP6_LB_nADV_ALE_o   <= FPGA_in(1);
        SP6_LB_RE_nOE_o     <= FPGA_in(2);
        SP6_LB_nWE_o        <= FPGA_in(3);
        Addr_LB_o           <= FPGA_in(11 DOWNTO 4);

        IOBUF_Addresses_Datas : for i in 0 to Addr_Data_LB_io'length-1 generate
          IOBUF_Addresse_Data : IOBUF
          generic map (
            DRIVE => 12,
            IOSTANDARD => "LVCMOS18"
            SLEW => "FAST"
          )
          port map (
            O => Addr_Data_LB_o(i), -- Buffer output
            IO => Addr_Data_LB_io(i), -- Buffer inout port (connect directly to top-level port)
            I => Addr_Data_LB_i(i), -- Buffer input
            T => Addr_Data_LB_tris_i -- 3-state enable input, high=input, low=output
          );
        end generate;

        END PlatformIndependent;

        """)
    return contents.get()
  }

  public override func getComponentInstantiation(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> LineBuffer {
    LineBuffer.getBuffer()
      .add(
        """
        COMPONENT LocalBus
           PORT ( SP6_LB_WAIT3_i     : IN  std_logic;
                  IRQ_i              : IN  std_logic;
                  Addr_Data_LB_io    : INOUT  std_logic_vector( 15 DOWNTO 0 );
                  Addr_LB_o          : OUT std_logic_vector( 8 DOWNTO 0 );
                  SP6_LB_RE_nOE_o    : OUT std_logic;
                  SP6_LB_nADV_ALE_o  : OUT std_logic;
                  SP6_LB_nCS3_o      : OUT std_logic;
                  SP6_LB_nWE_o       : OUT std_logic;
                  FPGA_in            : IN std_logic_vector(12 downto 0);
                  FPGA_out           : OUT std_logic_vector(1 downto 0);
                 Addr_Data_LB_i      : IN std_logic_vector(15 downto 0);
                 Addr_Data_LB_o      : OUT std_logic_vector(15 downto 0);
                 Addr_Data_LB_tris_i : IN std_logic);
        END COMPONENT;

        """)
  }

  public override func getEntity(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> [String] {
    LineBuffer.getBuffer()
      .pair("compName", componentName)
      .add(HdlFileWriter.generateRemark(componentName: componentName, projName: netlist.projName))
      .add(Hdl.getExtendedLibrary())
      .add(
        """
        Library UNISIM;
        use UNISIM.vcomponents.all;

        ENTITY {{compName}} IS
           PORT ( Addr_Data_LB_io     : INOUT std_logic_vector(15 downto 0);
                  SP6_LB_nCS3_o       : OUT std_logic;
                  SP6_LB_nADV_ALE_o   : OUT std_logic;
                  SP6_LB_RE_nOE_o     : OUT std_logic;
                  SP6_LB_nWE_o        : OUT std_logic;
                  SP6_LB_WAIT3_i      : IN std_logic;
                  IRQ_i               : IN std_logic;
                  FPGA_in             : IN std_logic_vector(12 downto 0);
                  FPGA_out            : OUT std_logic_vector(1 downto 0);
                  Addr_LB_o           : OUT std_logic_vector(8 downto 0);
                  Addr_Data_LB_o      : OUT std_logic_vector(15 downto 0);
                  Addr_Data_LB_i      : IN std_logic_vector(15 downto 0);
                  Addr_Data_LB_tris_i : IN std_logic);
        END {{compName}};

        """)
      .get()
  }

  public override func getPortMap(
    netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?
  ) -> [String: String] {
    var map: [String: String] = [:]
    guard let componentInfo else { return map }
    for (key, value) in super.getPortMap(netlist: netlist, componentInfo: componentInfo) {
      map[key] = value
    }
    map["Addr_Data_LB_io"] =
      "\(HdlGeneratorNames.localInOutBubbleBusName)(\(componentInfo.localBubbleInOutEnd) DOWNTO \(componentInfo.localBubbleInOutStart))"
    map["FPGA_in"] =
      "\(HdlGeneratorNames.localInputBubbleBusName)(\(componentInfo.localBubbleInputEnd) DOWNTO \(componentInfo.localBubbleInputStart))"
    map["FPGA_out"] =
      "\(HdlGeneratorNames.localOutputBubbleBusName)(\(componentInfo.localBubbleOutputEnd) DOWNTO \(componentInfo.localBubbleOutputStart))"
    for (key, value) in Hdl.getNetMap(
      sourceName: "Addr_Data_LB_o", floatingPinTiedToGround: true, comp: componentInfo,
      endIndex: PortIndex.addrDataOut, netlist: netlist)
    {
      map[key] = value
    }
    for (key, value) in Hdl.getNetMap(
      sourceName: "Addr_Data_LB_i", floatingPinTiedToGround: true, comp: componentInfo,
      endIndex: PortIndex.addrDataIn, netlist: netlist)
    {
      map[key] = value
    }
    for (key, value) in Hdl.getNetMap(
      sourceName: "Addr_Data_LB_tris_i", floatingPinTiedToGround: true, comp: componentInfo,
      endIndex: PortIndex.addrDataTrisIn, netlist: netlist)
    {
      map[key] = value
    }
    return map
  }

  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool { Hdl.isVhdl() }
}
