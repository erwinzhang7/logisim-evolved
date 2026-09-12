// ClockHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/wiring/ClockHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// The per-`Clock`-component generator: a divider off the global FPGA clock producing the 5-bit
// clock bus every other component taps (`logisimClockTree<n>`), whose bit indices are already
// declared as `HdlGeneratorNames.ClockTreeIndex`.
//
// Its subdirectory is `base`, not `wiring`; upstream passes it explicitly, because the clock
// generator is emitted once per design alongside the tick generator rather than per component
// family.
//
// ── The seam this generator used to be unable to close, now closed ──────────────────────────
//
// `getPortMap` needs `Netlist.getClockSourceId(Component)`: the *component*-keyed overload,
// which answers "which clock tree does this Clock component drive". It is a DIFFERENT lookup
// from the net-keyed `clockSourceId(hierarchyLevel:net:bitIndex:)`, not a convenience over it,
// and only the net-keyed one had been ported. This generator therefore took the lookup as an
// injected closure defaulting to `-1` ("no clock tree"), which maps `clockBus` to the empty
// string, so a real clock in a real netlist could never resolve its own source id, and the
// default made that look deliberate.
//
// `HdlNetlist` now declares the overload, with a `-1` default extension so the synthetic
// netlists the oracle harnesses build need no change, and `Netlist` forwards it to
// `ClockTreeFactory.clockSourceId(for:)` (which was already ported and unreachable). The
// injection point is kept for tests that want to force an id, but it now DEFAULTS to asking the
// netlist rather than to answering -1.

import LogisimKernel

/// `com.cburch.logisim.std.wiring.ClockHdlGeneratorFactory`.
public final class ClockHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  /// The clock bus is 5 bits wide; the individual indices live on
  /// `HdlGeneratorNames.ClockTreeIndex`, which the rest of the framework already uses.
  public static let nrOfClockBits = 5

  private static let highTickString = "highTicks"
  private static let highTickId = -1
  private static let lowTickString = "lowTicks"
  private static let lowTickId = -2
  private static let phaseString = "phase"
  private static let phaseId = -3
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -4

  /// `Netlist.getClockSourceId(Component)`. Defaults to asking the netlist, which is what
  /// upstream does; overridable so a test can force an id without building a clock tree.
  private let clockSourceId: (any HdlNetlistComponent, any HdlNetlist) -> Int

  public init(
    bindings: ClockHdlBindings,
    clockSourceId: @escaping (any HdlNetlistComponent, any HdlNetlist) -> Int = {
      component, netlist in netlist.clockSourceId(for: component)
    }
  ) {
    self.clockSourceId = clockSourceId
    super.init(subDirectory: "base", widthAttribute: bindings.width)
    myParametersList
      .add(
        Self.highTickString, Self.highTickId,
        kind: .intAttribute(bindings.high, offset: 0))
      .add(
        Self.lowTickString, Self.lowTickId,
        kind: .intAttribute(bindings.low, offset: 0))
      // The trailing `1` in Java's varargs call is `MAP_INT_ATTRIBUTE`'s *offset*, not a second
      // attribute: the phase generic is `phaseOffset + 1`.
      .add(
        Self.phaseString, Self.phaseId,
        kind: .intAttribute(bindings.phase, offset: 1))
      .add(
        Self.nrOfBitsString, Self.nrOfBitsId,
        kind: .log2(attributes: [bindings.high, bindings.low], offset: 0))
    myWires
      .addWire("s_counterNext", Self.nrOfBitsId)
      .addWire("s_counterIsZero", 1)
      .addRegister("s_outputRegs", Self.nrOfClockBits - 1)
      .addRegister("s_bufferRegs", 2)
      .addRegister("s_counterValue", Self.nrOfBitsId)
      .addRegister("s_derivedClock", Self.phaseId)
    myPorts
      .add(.input, "globalClock", nrOfBits: 1, componentPinId: 0)
      .add(.input, "clockTick", nrOfBits: 1, componentPinId: 1)
      .add(.output, "clockBus", nrOfBits: Self.nrOfClockBits, componentPinId: 2)
  }

  public override func getPortMap(
    netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?
  ) -> [String: String] {
    var map: [String: String] = [:]
    guard let componentInfo else { return map }
    map["globalClock"] = SynthesizedClockHdlGeneratorFactory.synthesizedClock
    map["clockTick"] = TickComponentHdlGeneratorFactory.fpgaTick
    let sourceId = clockSourceId(componentInfo, netlist)
    map["clockBus"] = sourceId >= 0 ? "s_\(HdlGeneratorNames.clockTreeName)\(sourceId)" : ""
    return map
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getHdlBuffer()
      .pair("phase", Self.phaseString)
      .pair("nrOfBits", Self.nrOfBitsString)
      .pair("lowTick", Self.lowTickString)
      .pair("highTick", Self.highTickString)
      .addRemarkBlock(
        "The output signals are defined here; we synchronize them all on the main clock")
      .empty()

    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        clockBus <= globalClock&s_outputRegs;

        makeOutputs : {{process}}(globalClock) {{is}}
        {{begin}}
           {{if}} (rising_edge(globalClock)) {{then}}
              s_bufferRegs(0)  <= s_derivedClock({{phase}} - 1);
              s_bufferRegs(1)  <= {{not}}(s_derivedClock({{phase}} - 1));
              s_outputRegs(0)  <= s_bufferRegs(0);
              s_outputRegs(1)  <= s_bufferRegs(1);
              s_outputRegs(2)  <= {{not}}(s_bufferRegs(0)) {{and}} s_derivedClock({{phase}} - 1);
              s_outputRegs(3)  <= s_bufferRegs(0) {{and}} {{not}}(s_derivedClock({{phase}} - 1));
           {{end}} {{if}};
        {{end}} {{process}} makeOutputs;
        """)
    } else {
      // ── UPSTREAM BUG, PRESERVED ───────────────────────────────────────────────────────────
      // `s_outputRegs[1] <= s_outputRegs[1];` self-assigns where the VHDL body assigns
      // `s_bufferRegs(1)`, so the inverted derived clock never reaches output bit 1 in Verilog.
      // Bits 2 and 3 are also written in the opposite operand order to the VHDL, which is
      // harmless. Reproduced verbatim (standing rule 4).
      contents.add(
        """
        assign clockBus = {globalClock,s_outputRegs};
        always @(posedge globalClock)
        begin
           s_bufferRegs[0] <= s_derivedClock[{{phase}} - 1];
           s_bufferRegs[1] <= ~s_derivedClock[{{phase}} - 1];
           s_outputRegs[0] <= s_bufferRegs[0];
           s_outputRegs[1] <= s_outputRegs[1];
           s_outputRegs[2] <= ~s_bufferRegs[0] & s_derivedClock[{{phase}} - 1];
           s_outputRegs[3] <= ~s_derivedClock[{{phase}} - 1] & s_bufferRegs[0];
        end
        """)
    }

    contents.empty().addRemarkBlock("The control signals are defined here")
    if Hdl.isVhdl() {
      contents.add(
        """
        s_counterIsZero <= '1' {{when}} s_counterValue = std_logic_vector(to_unsigned(0,{{nrOfBits}})) {{else}} '0';
        s_counterNext   <= std_logic_vector(unsigned(s_counterValue) - 1)
                              {{when}} s_counterIsZero = '0' {{else}}
                           std_logic_vector(to_unsigned(({{lowTick}}-1), {{nrOfBits}}))
                              {{when}} s_derivedClock(0) = '1' {{else}}
                           std_logic_vector(to_unsigned(({{highTick}}-1), {{nrOfBits}}));
        """)
    } else {
      contents.add(
        """
        assign s_counterIsZero = (s_counterValue == 0) ? 1'b1 : 1'b0;
        assign s_counterNext = (s_counterIsZero == 1'b0)
                               ? s_counterValue - 1
                               : (s_derivedClock[0] == 1'b1)
                                  ? {{lowTick}} - 1
                                  : {{highTick}} - 1;
        """)
        .empty()
        .addRemarkBlock("The initial values are defined here (for simulation only)")
        .add(
          """
          initial
          begin
             s_outputRegs = 0;
             s_derivedClock = 0;
             s_counterValue = 0;
          end
          """)
    }

    contents.empty().addRemarkBlock("The state registers are defined here")
    if Hdl.isVhdl() {
      contents.add(
        """
        makeDerivedClock : {{process}}(globalClock, clockTick, s_counterIsZero, s_derivedClock) {{is}}
        {{begin}}
           {{if}} (rising_edge(globalClock)) {{then}}
              {{if}} (s_derivedClock(0) /= '0' {{and}} s_derivedClock(0) /= '1') {{then}} --For simulation only
                 s_derivedClock <= ({{others}} => '1');
              {{elsif}} (clockTick = '1') {{then}}
                 {{for}} n IN {{phase}}-1 {{downto}} 1 {{loop}}
                   s_derivedClock(n) <= s_derivedClock(n-1);
                 {{end}} {{loop}};
                 s_derivedClock(0) <= s_derivedClock(0) {{xor}} s_counterIsZero;
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeDerivedClock;

        makeCounter : {{process}}(globalClock, clockTick, s_counterNext, s_derivedClock) {{is}}
        {{begin}}
           {{if}} (rising_edge(globalClock)) {{then}}
              {{if}} (s_derivedClock(0) /= '0' {{and}} s_derivedClock(0) /= '1') {{then}} --For simulation only
                 s_counterValue <= ({{others}} => '0');
              {{elsif}} (clockTick = '1') {{then}}
                 s_counterValue <= s_counterNext;
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} makeCounter;
        """)
    } else {
      contents.add(
        """
        integer n;
        always @(posedge globalClock)
        begin
           if (clockTick)
           begin
              s_derivedClock[0] <= s_derivedClock[0] ^ s_counterIsZero;
              for (n = 1; n < {{phase}}; n = n+1) begin
                 s_derivedClock[n] <= s_derivedClock[n-1];
              end
           end
        end

        always @(posedge globalClock)
        begin
           if (clockTick)
           begin
              s_counterValue <= s_counterNext;
           end
        end
        """)
    }
    return contents.empty()
  }
}

/// The `Clock` attribute constants `ClockHdlGeneratorFactory` needs by identity, injected for the
/// same reason as `GatesHdlBindings`; `LogisimHdl` cannot name `LogisimStd`.
public struct ClockHdlBindings {
  /// `StdAttr.WIDTH`. Not read by this generator, but `HdlParameters` needs a width attribute for
  /// its bus-only bookkeeping; pass the same one every other generator gets.
  public let width: Attribute<BitWidth>
  /// `Clock.ATTR_HIGH`, `.circ` name `highDuration`.
  public let high: AnyAttribute
  /// `Clock.ATTR_LOW`, `.circ` name `lowDuration`.
  public let low: AnyAttribute
  /// `Clock.ATTR_PHASE`, `.circ` name `phaseOffset`.
  public let phase: AnyAttribute

  public init(
    width: Attribute<BitWidth>, high: AnyAttribute, low: AnyAttribute, phase: AnyAttribute
  ) {
    self.width = width
    self.high = high
    self.low = low
    self.phase = phase
  }
}
