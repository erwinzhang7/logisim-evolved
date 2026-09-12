// MemoryRandomHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/RandomHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// A multicycle hardware implementation of `java.util.Random`'s 48-bit linear congruential
// generator: a shift-and-add multiplier pipeline that reproduces `seed * 0x5DEECE66D + 0xB` a
// bit at a time, so it needs no hardware multiplier.
//
// `Random.ATTR_SEED` (`"seed"`) lives in `LogisimStd`, so it is resolved by name off the
// component's attribute set; see `MemoryHdlSupport.swift`. It is declared with an explicit
// 32-bit vector width (`HdlParameters.addVector(..., 32)`), *not* the component's data width;
// upstream's comment says so and the `s_initSeed` comparison against `x"00000000"` depends on
// it.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RandomHdlGeneratorFactory`.
public final class MemoryRandomHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -1
  private static let seedString = "seed"
  private static let seedId = -2

  /// `Random.OUT`, `.CK`, `.NXT`, `.RST`: private upstream, restated with their Java names.
  /// Note `NXT` is 2 and `RST` is 3, which is the reverse of the order the ports are declared
  /// in; the values are pinned by the 4.1.0 jar's own `myPorts` dump, not read off the source.
  private enum Pin {
    static let out = 0
    static let clock = 1
    static let next = 2
    static let reset = 3
  }

  public init(attrs: any AttributeSet) {
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)

    myParametersList.add(Self.nrOfBitsString, Self.nrOfBitsId)
    if let seedAttribute = MemoryHdl.attribute(attrs, named: MemoryHdl.AttributeName.randomSeed) {
      // `HdlParameters.MAP_INT_ATTRIBUTE` with a trailing `32`: upstream's comment says "the
      // seed parameter has 32 bits fixed", and `HdlParameters.java:94-102` stores that 32 in
      // `offsetValue`; the SAME field the value formula adds at `:196-198`. So the generic's
      // value is `seed + 32`, not `seed`: with the default seed the jar emits
      // `seed => X"00000020"`. That is an upstream bug, pinned by the oracle, and reproducing
      // it is the port's job (standing rule 4).
      myParametersList.addVector(
        Self.seedString, Self.seedId, kind: .intAttribute(seedAttribute, offset: 32))
    }
    myWires
      .addWire("s_initSeed", 48)
      .addWire("s_reset", 1)
      .addWire("s_resetNext", 3)
      .addWire("s_multShiftNext", 36)
      .addWire("s_seedShiftNext", 48)
      .addWire("s_multBusy", 1)
      .addWire("s_start", 1)
      .addWire("s_macLowIn1", 25)
      .addWire("s_macLowIn2", 25)
      .addWire("s_macHigh1Next", 24)
      .addWire("s_macHighIn2", 24)
      .addWire("s_busyPipeNext", 2)
      .addRegister("s_currentSeed", 48)
      .addRegister("s_resetReg", 3)
      .addRegister("s_multShiftReg", 36)
      .addRegister("s_seedShiftReg", 48)
      .addRegister("s_startReg", 1)
      .addRegister("s_macLowReg", 25)
      .addRegister("s_macHighReg", 24)
      .addRegister("s_macHighReg1", 24)
      .addRegister("s_busyPipeReg", 2)
      .addRegister("s_outputReg", Self.nrOfBitsId)
    myPorts
      .add(.clock, HdlPorts.getClockName(1), nrOfBits: 1, componentPinId: Pin.clock)
      .add(.input, "clear", nrOfBits: 1, componentPinId: Pin.reset)
      .add(.input, "enable", nrOfBits: 1, componentPinId: Pin.next, pullToZero: false)
      .add(.output, "q", nrOfBits: Self.nrOfBitsId, componentPinId: Pin.out)

    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  /// `RandomHdlGeneratorFactory.getPortMap`. Only the output needs the single-bit VHDL fix-up
  /// here; there is no data input.
  public override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var map = super.getPortMap(netlist: netlist, componentInfo: componentInfo)
    guard let componentInfo, Hdl.isVhdl() else { return map }
    let nrOfBits = componentInfo.attributeSet.getValue(StdAttr.width)?.width ?? 0
    if nrOfBits == 1 {
      let outMap = map["q"]
      map.removeValue(forKey: "q")
      map["q(0)"] = outMap
    }
    return map
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    // `getBuffer()`, not `getHdlBuffer()`: upstream writes both languages' assignment syntax
    // out longhand here rather than through `{{assign}}`/`{{=}}`.
    let contents = LineBuffer.getBuffer()
      .pair("seed", Self.seedString)
      .pair("nrOfBits", Self.nrOfBitsString)
      .pair("GlobalClock", HdlPorts.getClockName(1))
      .pair("ClockEnable", HdlPorts.getTickName(1))
      .addRemarkBlock("This is a multicycle implementation of the Random Component")
      .empty()

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        q               <= s_outputReg;
        s_initSeed      <= x"0005DEECE66D" {{when}} {{seed}} = x"00000000" {{else}}
                           x"0000"&seed;
        s_reset         <= '1' {{when}} s_resetReg /= "010" {{else}} '0';
        s_resetNext     <= "010" {{when}} (s_resetReg = "101" {{or}}
                                       s_resetReg = "010") {{and}}
                                       clear = '0' {{else}}
                           "101" {{when}} s_resetReg = "001" {{else}}
                           "001";
        s_start         <= '1' {{when}} ({{ClockEnable}} = '1' {{and}} enable = '1') {{or}}
                                 (s_resetReg = "101" {{and}} clear = '0') {{else}} '0';
        s_multShiftNext <= ({{others}} => '0') {{when}} s_reset = '1' {{else}}
                           X"5DEECE66D" {{when}} s_startReg = '1' {{else}}
                           '0'&s_multShiftReg(35 {{downto}} 1);
        s_seedShiftNext <= ({{others}} => '0') {{when}} s_reset = '1' {{else}}
                           s_currentSeed {{when}} s_startReg = '1' {{else}}
                           s_seedShiftReg(46 {{downto}} 0)&'0';
        s_multBusy      <= '0' {{when}} s_multShiftReg = X"000000000" {{else}} '1';
        
        s_macLowIn1     <= ({{others}} => '0') {{when}} s_startReg = '1' {{or}}
                                                  s_reset = '1' {{else}}
                           '0'&s_macLowReg(23 {{downto}} 0);
        s_macLowIn2     <= '0'&X"00000B"
                                {{when}} s_startReg = '1' {{else}}
                           '0'&s_seedShiftReg(23 {{downto}} 0)
                                {{when}} s_multShiftReg(0) = '1' {{else}}
                           ({{others}} => '0');
        s_macHighIn2    <= ({{others}} => '0') {{when}} s_startReg = '1' {{else}}
                           s_macHighReg;
        s_macHigh1Next  <= s_seedShiftReg(47 {{downto}} 24)
                              {{when}} s_multShiftReg(0) = '1' {{else}}
                           ({{others}} => '0');
        s_busyPipeNext  <= "00" {{when}} s_reset = '1' {{else}}
                           s_busyPipeReg(0)&s_multBusy;
        
        makeCurrentSeed : {{process}}({{GlobalClock}}, s_busyPipeReg, s_reset) {{is}}
        {{begin}}
           {{if}} (rising_edge({{GlobalClock}})) {{then}}
              {{if}} (s_reset = '1') {{then}} s_currentSeed <= s_initSeed;
              {{elsif}} (s_busyPipeReg = "10") {{then}}
                 s_currentSeed <= s_macHighReg&s_macLowReg(23 {{downto}} 0);
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeCurrentSeed;
        
        makeShiftRegs : {{process}}({{GlobalClock}}, s_multShiftNext, s_seedShiftNext,
                                s_macLowIn1, s_macLowIn2) {{is}}
        {{begin}}
           {{if}} (rising_edge({{GlobalClock}})) {{then}}
              s_multShiftReg <= s_multShiftNext;
              s_seedShiftReg <= s_seedShiftNext;
              s_macLowReg    <= std_logic_vector( unsigned(s_macLowIn1) + unsigned(s_macLowIn2) );
              s_macHighReg1  <= s_macHigh1Next;
              s_macHighReg   <= std_logic_vector( unsigned(s_macHighReg1) + unsigned(s_macHighIn2) +
                                unsigned(s_macLowReg(24 {{downto}} 24)) );
              s_busyPipeReg  <= s_busyPipeNext;
           {{end}} {{if}};
        {{end}} {{process}} makeShiftRegs;
        
        makeStartReg : {{process}}({{GlobalClock}}, s_start) {{is}}
        {{begin}}
           {{if}} (rising_edge({{GlobalClock}})) {{then}}
              s_startReg <= s_start;
           {{end}} {{if}};
        {{end}} {{process}} makeStartReg;
        
        makeResetReg : {{process}}({{GlobalClock}}, s_resetNext) {{is}}
        {{begin}}
           {{if}} (rising_edge({{GlobalClock}})) {{then}}
              s_resetReg <= s_resetNext;
           {{end}} {{if}};
        {{end}} {{process}} makeResetReg;
        
        makeOutput : {{process}}({{GlobalClock}}, s_reset, s_initSeed) {{is}}
        {{begin}}
           {{if}} (rising_edge({{GlobalClock}})) {{then}}
              {{if}} (s_reset = '1') {{then}} s_outputReg <= s_initSeed( ({{nrOfBits}}-1) {{downto}} 0 );
              {{elsif}} ({{ClockEnable}} = '1' {{and}} enable = '1') {{then}}
                 s_outputReg <= s_currentSeed(({{nrOfBits}}+11) {{downto}} 12);
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeOutput;
        """)
    } else {
      contents.add(
        """
        assign q = s_outputReg;
        assign s_initSeed      = ({{seed}} == 0) ? 48'h5DEECE66D : {{seed}};
        assign s_reset         = (s_resetReg==3'b010) ? 1'b1 : 1'b0;
        assign s_resetNext     = (( (s_resetReg == 3'b101) | (s_resetReg == 3'b010)) & clear)
                                    ? 3'b010
                                    : (s_resetReg==3'b001) ? 3'b101 : 3'b001;
        assign s_start         = (({{ClockEnable}}&enable)|((s_resetReg == 3'b101)&clear)) ? 1'b1 : 1'b0;
        assign s_multShiftNext = (s_reset)
                                    ? 36'd0
                                    : (s_startReg) ? 36'h5DEECE66D : {1'b0,s_multShiftReg[35:1]};
        assign s_seedShiftNext = (s_reset)
                                    ? 48'd0
                                    : (s_startReg) ? s_currentSeed : {s_seedShiftReg[46:0],1'b0};
        assign s_multBusy      = (s_multShiftReg == 0) ? 1'b0 : 1'b1;
        assign s_macLowIn1     = (s_startReg|s_reset) ? 25'd0 : {1'b0,s_macLowReg[23:0]};
        assign s_macLowIn2     = (s_startReg) ? 25'hB
                                    : (s_multShiftReg[0])
                                    ? {1'b0,s_seedShiftReg[23:0]} : 25'd0;
        assign s_macHighIn2    = (s_startReg) ? 0 : s_macHighReg;
        assign s_macHigh1Next  = (s_multShiftReg[0]) ? s_seedShiftReg[47:24] : 0;
        assign s_busyPipeNext  = (s_reset) ? 2'd0 : {s_busyPipeReg[0],s_multBusy};
        
        always @(posedge {{GlobalClock}})
        begin
           if (s_reset) s_currentSeed <= s_initSeed;
           else if (s_busyPipeReg == 2'b10) s_currentSeed <= {s_macHighReg,s_macLowReg[23:0]};
        end
        
        always @(posedge {{GlobalClock}})
        begin
              s_multShiftReg <= s_multShiftNext;
              s_seedShiftReg <= s_seedShiftNext;
              s_macLowReg    <= s_macLowIn1+s_macLowIn2;
              s_macHighReg1  <= s_macHigh1Next;
              s_macHighReg   <= s_macHighReg1+s_macHighIn2+s_macLowReg[24];
              s_busyPipeReg  <= s_busyPipeNext;
              s_startReg     <= s_start;
              s_resetReg     <= s_resetNext;
        end
        
        always @(posedge {{GlobalClock}})
        begin
           if (s_reset) s_outputReg <= s_initSeed[({{nrOfBits}}-1):0];
           else if ({{ClockEnable}}&enable) s_outputReg <= s_currentSeed[({{nrOfBits}}+11):12];
        end
        """)
    }
    return contents.empty()
  }
}
