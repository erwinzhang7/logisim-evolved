// MemoryRegisterHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/RegisterHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// An `nrOfBits`-wide register with asynchronous reset and a clock enable. Two upstream details
// are reproduced verbatim rather than tidied (standing rule 4):
//
//   * `rising_Edge(s_clock)`; capital E. VHDL is case-insensitive so it compiles, but the text
//     must match byte-for-byte.
//   * `s_Clock` in the Verilog *latch* branch, where the declared signal is `s_clock`. Verilog
//     *is* case-sensitive, so that branch references an undeclared identifier. It is an upstream
//     bug; reproducing it is the port's job, fixing it is not.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RegisterHdlGeneratorFactory`.
public final class MemoryRegisterHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let invertClockString = "invertClock"
  private static let invertClockId = -2

  /// `Register.OUT`, `.IN`, `.CK`, `.CLR`, `.EN`: the port indices `Register.getPorts` assigns,
  /// identical in both appearances. Private to `Register` upstream and unreachable from this
  /// module, so they are restated with their Java names.
  private enum Pin {
    static let out = 0
    static let dataIn = 1
    static let clock = 2
    static let clear = 3
    static let enable = 4
  }

  public init() {
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)

    myParametersList
      .add(Self.nrOfBitsString, Self.nrOfBitsId)
      .add(
        Self.invertClockString, Self.invertClockId,
        kind: .attributeOption(StdAttr.trigger, MemoryHdl.triggerMap))
    myWires
      .addWire("s_clock", 1)
      .addRegister("s_currentState", Self.nrOfBitsId)
    myPorts
      .add(.clock, HdlPorts.getClockName(1), nrOfBits: 1, componentPinId: Pin.clock)
      .add(.input, "reset", nrOfBits: 1, componentPinId: Pin.clear)
      .add(.input, "clockEnable", nrOfBits: 1, componentPinId: Pin.enable, pullToZero: false)
      .add(.input, "d", nrOfBits: Self.nrOfBitsId, componentPinId: Pin.dataIn)
      .add(.output, "q", nrOfBits: Self.nrOfBitsId, componentPinId: Pin.out)

    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  /// `RegisterHdlGeneratorFactory.getPortMap`.
  ///
  /// At width 1 the VHDL entity still declares `d`/`q` as `std_logic_vector(0 downto 0)` (the
  /// generic makes the width unknowable at declaration time), while the net map produced for a
  /// single-bit end is a scalar. Upstream patches that up by renaming the two keys to `d(0)` /
  /// `q(0)`. Verilog needs no such fix-up, hence the `Hdl.isVhdl()` guard.
  public override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var map = super.getPortMap(netlist: netlist, componentInfo: componentInfo)
    guard let componentInfo, Hdl.isVhdl() else { return map }
    let nrOfBits = componentInfo.attributeSet.getValue(StdAttr.width)?.width ?? 0
    if nrOfBits == 1 {
      let inMap = map["d"]
      let outMap = map["q"]
      map.removeValue(forKey: "d")
      map.removeValue(forKey: "q")
      map["d(0)"] = inMap
      map["q(0)"] = outMap
    }
    return map
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    // NB: `getBuffer()`, not `getHdlBuffer()`; upstream deliberately leaves `{{assign}}`/`{{=}}`
    // unpaired here and writes the VHDL `<=` / Verilog `assign` forms out longhand in each
    // branch. Using an HDL buffer would resolve nothing differently today but would silently
    // start substituting if a future edit introduced one of those placeholders.
    let contents = LineBuffer.getBuffer()
      .pair("invertClock", Self.invertClockString)
      .pair("clock", HdlPorts.getClockName(1))
      .pair("Tick", HdlPorts.getTickName(1))
    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        q       <= s_currentState;
        s_clock <= {{clock}} {{when}} {{invertClock}} = 0 {{else}} {{not}}({{clock}});

        makeMemory : {{process}}(s_clock, reset, clockEnable, {{Tick}}, d) {{is}}
        {{begin}}
           {{if}} (reset = '1') {{then}} s_currentState <= ({{others}} => '0');
        """)
      if MemoryHdl.isFlipFlop(attrs) {
        contents.add(
          """
          {{elsif}} (rising_Edge(s_clock)) {{then}}
             {{if}} (clockEnable = '1' {{and}} {{Tick}} = '1') {{then}}
                s_currentState <= d;
             {{end}} {{if}};
          """)
      } else {
        contents.add(
          """
          {{elsif}} (s_clock = '1') {{then}}
             {{if}} (clockEnable = '1' {{and}} {{Tick}} = '1') {{then}}
                s_currentState <= d;
             {{end}} {{if}};
          """)
      }
      contents.add(
        """
           {{end}} {{if}};
        {{end}} {{process}} makeMemory;
        """)
    } else {
      contents.empty().add(
        """
        assign q = s_currentState;
        assign s_clock = {{invertClock}} == 0 ? {{clock}} : ~{{clock}};
        """)
        .empty()
      if MemoryHdl.isFlipFlop(attrs) {
        contents.add(
          """
          always @(posedge s_clock or posedge reset)
          begin
             if (reset) s_currentState <= 0;
             else if (clockEnable&{{Tick}}) s_currentState <= d;
          end
          """)
      } else {
        contents.add(
          """
          always @(*)
          begin
             if (reset) s_currentState <= 0;
             else if (s_Clock&clockEnable&{{Tick}}) s_currentState <= d;
          end
          """)
      }
    }
    return contents.empty()
  }
}
