// MemoryCounterHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/CounterHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// A loadable up/down counter with a comparison output and four on-goal behaviours (wrap, stay,
// continue, load), the last of which reaches the HDL as the integer generic `mode`.
//
// Two attribute identities this generator needs live in `LogisimStd` and cannot be imported, so
// they are resolved by name off the component's own attribute set at construction time: see
// `MemoryHdlSupport.swift`'s header for why that preserves D4 attribute identity:
//
//   * `Counter.ATTR_MAX` (`"max"`): the comparison value, emitted as the `maxVal` vector
//     generic, whose width comes from `StdAttr.WIDTH` rather than from any offset.
//   * `Counter.ATTR_ON_GOAL` (`"ongoal"`); the `mode` generic.
//
// Note the clock attribute is `StdAttr.EDGE_TRIGGER`, not `StdAttr.TRIGGER`: `CounterAttributes`
// offers only rising/falling (`CounterAttributes.java:35`), so a Counter is always a flip-flop
// as far as `Netlist.isFlipFlop` is concerned.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.CounterHdlGeneratorFactory`.
public final class MemoryCounterHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let nrOfBitsString = "width"
  private static let nrOfBitsId = -1
  private static let maxValueString = "maxVal"
  private static let maxValueId = -2
  private static let invertClockString = "invertClock"
  private static let invertClockId = -3
  private static let modeString = "mode"
  private static let modeId = -4

  private static let loadDataInput = "loadData"
  private static let countDataOutput = "countValue"

  /// `Counter.CK`, `.IN`, `.CLR`, `.LD`, `.UD`, `.EN`, `.OUT`, `.CARRY`: package-private
  /// upstream and unreachable here, restated with their Java names. The indices are the same in
  /// both appearances (`Counter.getPorts`).
  private enum Pin {
    static let out = 0
    static let dataIn = 1
    static let clock = 2
    static let clear = 3
    static let load = 4
    static let upNotDown = 5
    static let enable = 6
    static let carry = 7
  }

  /// - Parameter attrs: the component's own attribute set, used only to resolve the two
  ///   `Counter` attribute identities by name. No value is read from it here.
  public init(attrs: any AttributeSet) {
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)

    myParametersList.add(Self.nrOfBitsString, Self.nrOfBitsId)
    if let maxAttribute = MemoryHdl.attribute(attrs, named: MemoryHdl.AttributeName.counterMax) {
      myParametersList.addVector(
        Self.maxValueString, Self.maxValueId, kind: .intAttribute(maxAttribute, offset: 0))
    }
    myParametersList.add(
      Self.invertClockString, Self.invertClockId,
      kind: .attributeOption(StdAttr.edgeTrigger, MemoryHdl.triggerMap))
    if let onGoalAttribute = MemoryHdl.attribute(
      attrs, named: MemoryHdl.AttributeName.counterOnGoal)
    {
      myParametersList.add(
        Self.modeString, Self.modeId,
        kind: .attributeOption(
          onGoalAttribute,
          [
            MemoryHdl.Option.counterWrap: 0,
            MemoryHdl.Option.counterStay: 1,
            MemoryHdl.Option.counterContinue: 2,
            MemoryHdl.Option.counterLoad: 3,
          ]))
    }
    myWires
      .addWire("s_clock", 1)
      .addWire("s_realEnable", 1)
      .addRegister("s_nextCounterValue", Self.nrOfBitsId)
      .addRegister("s_carry", 1)
      .addRegister("s_counterValue", Self.nrOfBitsId)
    myPorts
      .add(.clock, HdlPorts.clock, nrOfBits: 1, componentPinId: Pin.clock)
      .add(.input, Self.loadDataInput, nrOfBits: Self.nrOfBitsId, componentPinId: Pin.dataIn)
      .add(.input, "clear", nrOfBits: 1, componentPinId: Pin.clear)
      .add(.input, "load", nrOfBits: 1, componentPinId: Pin.load)
      .add(.input, "upNotDown", nrOfBits: 1, componentPinId: Pin.upNotDown)
      .add(.input, "enable", nrOfBits: 1, componentPinId: Pin.enable, pullToZero: false)
      .add(.output, Self.countDataOutput, nrOfBits: Self.nrOfBitsId, componentPinId: Pin.out)
      .add(.output, "compareOut", nrOfBits: 1, componentPinId: Pin.carry)

    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  /// `CounterHdlGeneratorFactory.getPortMap`. Same single-bit VHDL fix-up as `Register`: the
  /// entity always declares the data ports as vectors because their width is a generic, so at
  /// width 1 the scalar net map has to be re-keyed to `loadData(0)` / `countValue(0)`.
  public override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var result = super.getPortMap(netlist: netlist, componentInfo: componentInfo)
    guard let componentInfo, Hdl.isVhdl() else { return result }
    let nrOfBits = componentInfo.attributeSet.getValue(StdAttr.width)?.width ?? 0
    if nrOfBits == 1 {
      let mappedInputData = result[Self.loadDataInput]
      let mappedOutputData = result[Self.countDataOutput]
      result.removeValue(forKey: Self.loadDataInput)
      result.removeValue(forKey: Self.countDataOutput)
      result[LineBuffer.formatHdl("{{1}}{{<}}0{{>}}", Self.loadDataInput)] = mappedInputData
      result[LineBuffer.formatHdl("{{1}}{{<}}0{{>}}", Self.countDataOutput)] = mappedOutputData
    }
    return result
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer()
      .pair("invertClock", Self.invertClockString)
      .pair("clock", HdlPorts.clock)
      .pair("Tick", HdlPorts.tick)
      .empty()
      .addRemarkBlock(
        """
        Functionality of the counter:
          Load Count | mode
          -----------+-------------------
            0    0   | halt
            0    1   | count up (default)
            1    0   | load
            1    1   | count down
        """)
      .empty()
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        compareOut   <= s_carry;
        countValue   <= s_counterValue;
        
        s_clock      <= {{clock}} {{when}} {{invertClock}} = 0 {{else}} {{not}}({{clock}});
        
        makeCarry : {{process}}(upNotDown, s_counterValue) {{is}}
        {{begin}}
           {{if}} (upNotDown = '0') {{then}}
              {{if}} (s_counterValue = std_logic_vector(to_unsigned(0,width))) {{then}}
                 s_carry <= '1';
              {{else}}
                 s_carry <= '0';
              {{end}} {{if}}; -- Down counting
           {{else}}
              {{if}} (s_counterValue = maxVal) {{then}}
                 s_carry <= '1';
              {{else}}
                 s_carry <= '0';
              {{end}} {{if}}; -- Up counting
           {{end}} {{if}};
        {{end}} {{process}} makeCarry;
        
        s_realEnable <= '0' {{when}} (load = '0' {{and}} enable = '0') -- Counter disabled
                               {{or}} (mode = 1 {{and}} s_carry = '1' {{and}} load = '0') -- Stay at value situation
                             {{else}} {{Tick}};
        
        makeNextValue : {{process}}(load ,upNotDown ,s_counterValue ,loadData , s_carry) {{is}}
           {{variable}} v_downcount : std_logic;
        {{begin}}
           v_downcount := {{not}}(upNotDown);
           {{if}} ((load = '1') {{or}} -- load condition
               (mode = 3 {{and}} s_carry = '1')    -- Wrap load condition
              ) {{then}} s_nextCounterValue <= loadData;
           {{else}}
              {{case}} (mode) {{is}}
                 {{when}}  0    => {{if}} (s_carry = '1') {{then}}
                                  {{if}} (v_downcount = '1') {{then}}
                                     s_nextCounterValue <= maxVal;
                                  {{else}}
                                     s_nextCounterValue <= ({{others}} => '0');
                                  {{end}} {{if}};
                               {{else}}
                                  {{if}} (v_downcount = '1') {{then}}
                                     s_nextCounterValue <= std_logic_vector(unsigned(s_counterValue) - 1);
                                  {{else}}
                                     s_nextCounterValue <= std_logic_vector(unsigned(s_counterValue) + 1);
                                  {{end}} {{if}};
                               {{end}} {{if}};
                {{when}} {{others}} => {{if}} (v_downcount = '1') {{then}}
                                   s_nextCounterValue <= std_logic_vector(unsigned(s_counterValue) - 1);
                               {{else}}
                                   s_nextCounterValue <= std_logic_vector(unsigned(s_counterValue) + 1);
                               {{end}} {{if}};
              {{end}} {{case}};
           {{end}} {{if}};
        {{end}} {{process}} makeNextValue;
        
        makeFlops : {{process}}(s_clock, s_realEnable, clear, s_nextCounterValue ) {{is}}
        {{begin}}
           {{if}} (clear = '1') {{then}} s_counterValue <= ({{others}} => '0');
           {{elsif}} (rising_edge(s_clock)) {{then}}
              {{if}} (s_realEnable = '1') {{then}} s_counterValue <= s_nextCounterValue;
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeFlops;
        """)
    } else {
      contents.add(
        """
        assign compareOut = s_carry;
        assign countValue = s_counterValue;
        assign s_clock = ({{invertClock}} == 0) ? {{clock}} : ~{{clock}};
        
        always@(*)
        begin
        if (upNotDown)
           s_carry = (s_counterValue == maxVal) ? 1'b1 : 1'b0;
        else
           s_carry = (s_counterValue == 0) ? 1'b1 : 1'b0;
        end
        
        assign s_realEnable = ((~(load)&~(enable))|
                                ((mode==1)&s_carry&~(load))) ? 1'b0 : {{Tick}};
        
        always @(*)
        begin
           if ((load)|((mode==3)&s_carry))
              s_nextCounterValue = loadData;
           else if ((mode==0)&s_carry&upNotDown)
              s_nextCounterValue = 0;
           else if ((mode==0)&s_carry)
              s_nextCounterValue = maxVal;
           else if (upNotDown)
              s_nextCounterValue = s_counterValue + 1;
           else
              s_nextCounterValue = s_counterValue - 1;
        end
        
        always @(posedge s_clock or posedge clear)
        begin
           if (clear) s_counterValue <= 0;
           else if (s_realEnable) s_counterValue <= s_nextCounterValue;
        end
        """)
    }
    return contents.empty()
  }
}
