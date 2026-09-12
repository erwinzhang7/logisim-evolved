// MemoryShiftRegisterHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/ShiftRegisterHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// The most structurally unusual generator in the memory family: it emits a **second** design
// unit, `singleBitShiftReg`, alongside its own, and instantiates one per data bit with a
// generate loop. That is why it overrides `getEntity`, `getArchitecture` and
// `getComponentDeclarationSection` as well as `getModuleFunctionality`; the extra unit has to
// be declared in three different places depending on the language and on whether the caller
// wants an entity or a component declaration.
//
// ── Why `getWiresPortsDuringHdlWriting` is set ──────────────────────────────────────────────
//
// The `parLoad` port is mapped to a real component pin when the component has parallel load and
// to a **fixed constant** `'0'`/`1'b0` when it does not. That depends on an attribute, so the
// port list cannot be built in the constructor; upstream sets the flag and builds it in
// `getGenerationTimeWiresPorts`, which the framework calls from inside `getArchitecture`,
// `getPortMap` and `getVHDLBlackBox`.
//
// ── Two upstream details preserved verbatim (standing rule 4) ───────────────────────────────
//
//   * The generated Verilog module declares `input[nrOfStages:0] d;` and
//     `output[nrOfStages:0] q;`; one bit too wide; the VHDL declares
//     `((nrOfStages-1) downto 0)`. Reproduced as-is.
//   * `getPortMap`'s VHDL parallel-load path writes `map.put("q(nrOfStages-1)", "OPEN")` *after*
//     the loop that already filled `q(0)…q(nrOfOutStages-1)`, so in the CLASSIC appearance,
//     where `nrOfOutStages == nrOfStages`, the last entry is overwritten with `OPEN`, and in
//     the EVOLUTION appearance it fills the one the loop deliberately skipped. Both behaviours
//     come from the same two lines and are kept.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.ShiftRegisterHdlGeneratorFactory`.
public final class MemoryShiftRegisterHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let negateClockString = "negateClock"
  private static let negateClockId = -1
  private static let nrOfBitsString = "nrOfBits"
  private static let nrOfBitsId = -2
  private static let nrOfStagesString = "nrOfStages"
  private static let nrOfStagesId = -3
  private static let nrOfParBitsString = "nrOfParBits"
  private static let nrOfParBitsId = -4

  /// `ShiftRegister.IN`, `.SH`, `.CK`, `.CLR`, `.OUT`, `.LD`; private upstream. The values are
  /// pinned by the 4.1.0 jar's own `myPorts` dump rather than read off the source.
  private enum Pin {
    static let dataIn = 0
    static let shift = 1
    static let clock = 2
    static let clear = 3
    static let out = 4
    static let load = 5
  }

  /// The `ShiftRegister` attributes this generator reads, resolved by name because they live in
  /// `LogisimStd` (see `MemoryHdlSupport.swift`).
  private let lengthAttribute: AnyAttribute?
  private let loadAttribute: AnyAttribute?

  public init(attrs: any AttributeSet) {
    lengthAttribute = MemoryHdl.attribute(
      attrs, named: MemoryHdl.AttributeName.shiftRegisterLength)
    loadAttribute = MemoryHdl.attribute(attrs, named: MemoryHdl.AttributeName.shiftRegisterLoad)
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)

    myParametersList.add(
      Self.negateClockString, Self.negateClockId,
      kind: .attributeOption(StdAttr.edgeTrigger, MemoryHdl.triggerMap))
    myParametersList.add(Self.nrOfBitsString, Self.nrOfBitsId)
    if let lengthAttribute {
      myParametersList
        .add(
          Self.nrOfParBitsString, Self.nrOfParBitsId,
          kind: .productOfAttributes([StdAttr.width, lengthAttribute]))
        .add(
          Self.nrOfStagesString, Self.nrOfStagesId,
          kind: .intAttribute(lengthAttribute, offset: 0))
    }
    getWiresPortsDuringHdlWriting = true

    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  public override func getGenerationTimeWiresPorts(netlist: any HdlNetlist, attrs: any AttributeSet)
  {
    let hasParallelLoad = loadAttribute.map {
      if case .boolean(let value)? = attrs.rawValue($0) { return value }
      return false
    } ?? false
    myPorts
      .add(.clock, HdlPorts.getClockName(1), nrOfBits: 1, componentPinId: Pin.clock)
      .add(.input, "reset", nrOfBits: 1, componentPinId: Pin.clear)
      .add(.input, "shiftEnable", nrOfBits: 1, componentPinId: Pin.shift)
      .add(.input, "shiftIn", nrOfBits: Self.nrOfBitsId, componentPinId: Pin.dataIn)
      .add(.input, "d", nrOfBits: Self.nrOfParBitsId, fixedMap: "DUMMY_MAP")
      .add(.output, "shiftOut", nrOfBits: Self.nrOfBitsId, componentPinId: Pin.out)
      .add(.output, "q", nrOfBits: Self.nrOfParBitsId, fixedMap: "DUMMY_MAP")
    if hasParallelLoad {
      myPorts.add(.input, "parLoad", nrOfBits: 1, componentPinId: Pin.load)
    } else {
      myPorts.add(.input, "parLoad", nrOfBits: 1, fixedMap: Hdl.zeroBit())
    }
  }

  /// `ShiftRegisterHdlGeneratorFactory.getPortMap`.
  ///
  /// The `d`/`q` ports are declared with `DUMMY_MAP` as their fixed map precisely so the base
  /// class produces *something* for them and this override can throw it away and rebuild the
  /// mapping bit by bit: a shift register's parallel taps are `2 * stage` apart in the
  /// component's end list, which no generic port declaration can express.
  public override func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var map = super.getPortMap(netlist: netlist, componentInfo: componentInfo)
    guard let comp = componentInfo else { return map }
    let attrs = comp.attributeSet
    let nrOfBits = attrs.getValue(StdAttr.width)?.width ?? 0
    let nrOfStages = Int(
      MemoryHdl.integerValue(attrs, named: MemoryHdl.AttributeName.shiftRegisterLength, default: 0))
    let hasParallelLoad = MemoryHdl.booleanValue(
      attrs, named: MemoryHdl.AttributeName.shiftRegisterLoad, default: false)
    var vector = ""
    if Hdl.isVhdl() && nrOfBits == 1 {
      let shiftMap = map["shiftIn"]
      let outMap = map["shiftOut"]
      map.removeValue(forKey: "shiftIn")
      map.removeValue(forKey: "shiftOut")
      map["shiftIn(0)"] = shiftMap
      map["shiftOut(0)"] = outMap
    }
    map.removeValue(forKey: "d")
    map.removeValue(forKey: "q")
    if hasParallelLoad {
      if nrOfBits == 1 {
        if Hdl.isVhdl() {
          for stage in 0..<nrOfStages {
            for (key, value) in Hdl.getNetMap(
              sourceName: "d(\(stage))", floatingPinTiedToGround: true, comp: comp,
              endIndex: 6 + (2 * stage), netlist: netlist)
            {
              map[key] = value
            }
          }
          let nrOfOutStages =
            attrs.getValue(StdAttr.appearance) == StdAttr.appearClassic
            ? nrOfStages : nrOfStages - 1
          for stage in 0..<max(0, nrOfOutStages) {
            for (key, value) in Hdl.getNetMap(
              sourceName: "q(\(stage))", floatingPinTiedToGround: true, comp: comp,
              endIndex: 7 + (2 * stage), netlist: netlist)
            {
              map[key] = value
            }
          }
          map["q(\(nrOfStages - 1))"] = "OPEN"
        } else {
          var stage = nrOfStages - 1
          while stage >= 0 {
            if !vector.isEmpty { vector += "," }
            vector += Hdl.getNetName(
              comp, endIndex: 6 + (2 * stage), floatingNetTiedToGround: true, netlist: netlist)
            stage -= 1
          }
          map["d"] = vector
          vector = "open"
          stage = nrOfStages - 2
          while stage >= 0 {
            if !vector.isEmpty { vector += "," }
            vector += Hdl.getNetName(
              comp, endIndex: 7 + (2 * stage), floatingNetTiedToGround: true, netlist: netlist)
            stage -= 1
          }
          map["q"] = vector
        }
      } else {
        if Hdl.isVhdl() {
          for bit in 0..<nrOfBits {
            for stage in 0..<nrOfStages {
              let index = (bit * nrOfStages) + stage
              let id = 6 + (2 * stage)
              map["d(\(index))"] = Hdl.getBusEntryName(
                comp, endIndex: id, floatingNetTiedToGround: true, bitIndex: bit, netlist: netlist)
              if stage == nrOfStages - 1 { continue }
              map["q(\(index))"] = Hdl.getBusEntryName(
                comp, endIndex: id + 1, floatingNetTiedToGround: true, bitIndex: bit,
                netlist: netlist)
            }
            map["q(\(((bit + 1) * nrOfStages) - 1))"] = "OPEN"
          }
        } else {
          vector = ""
          var bit = nrOfBits - 1
          while bit >= 0 {
            var stage = nrOfStages - 1
            while stage >= 0 {
              if !vector.isEmpty { vector += "," }
              vector += Hdl.getBusEntryName(
                comp, endIndex: 6 + (2 * stage), floatingNetTiedToGround: true, bitIndex: bit,
                netlist: netlist)
              stage -= 1
            }
            bit -= 1
          }
          map["d"] = vector
          vector = ""
          bit = nrOfBits - 1
          while bit >= 0 {
            if !vector.isEmpty { vector += "," }
            vector += "open"
            var stage = nrOfStages - 2
            while stage >= 0 {
              if !vector.isEmpty { vector += "," }
              vector += Hdl.getBusEntryName(
                comp, endIndex: 7 + (2 * stage), floatingNetTiedToGround: true, bitIndex: bit,
                netlist: netlist)
              stage -= 1
            }
            bit -= 1
          }
          map["q"] = vector
        }
      }
    } else {
      map["d"] = Hdl.getConstantVector(0, nrOfBits: nrOfBits * nrOfStages)
      map["q"] = Hdl.unconnected(empty: true)
    }
    return map
  }

  public override func getArchitecture(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> [String]? {
    let contents = LineBuffer.getHdlBuffer()
      .pair("clock", HdlPorts.getClockName(1))
      .pair("tick", HdlPorts.getTickName(1))
      .pair("nrOfStages", Self.nrOfStagesString)
      .pair("invertClock", Self.negateClockString)
    guard
      let base = super.getArchitecture(netlist: netlist, attrs: attrs, componentName: componentName)
    else { return nil }
    contents.add(base).empty(3)
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        """
        {{architecture}} noPlatformSpecific {{of}} singleBitShiftReg {{is}}
        
           {{signal}} s_stateReg  : std_logic_vector( ({{nrOfStages}}-1) {{downto}} 0 );
           {{signal}} s_stateNext : std_logic_vector( ({{nrOfStages}}-1) {{downto}} 0 );
           {{signal}} s_clock     : std_logic;
        
        {{begin}}
           q        <= s_stateReg;
           shiftOut <= s_stateReg({{nrOfStages}}-1);
           s_clock  <= {{clock}} {{when}} {{invertClock}} = 0 {{else}} {{not}}({{clock}});
        
           s_stateNext <= d {{when}} parLoad = '1' {{else}} s_stateReg(({{nrOfStages}}-2) {{downto}} 0)&shiftIn;
        
           makeState : {{process}}(s_clock, shiftEnable, {{tick}}, reset, s_stateNext, parLoad) {{is}}
           {{begin}}
              {{if}} (reset = '1') {{then}} s_stateReg <= ({{others}} => '0');
              {{elsif}} (rising_edge(s_clock)) {{then}}
                 {{if}} (((shiftEnable = '1') {{or}} (parLoad = '1')) {{and}} ({{tick}} = '1')) {{then}}
                    s_stateReg <= s_stateNext;
                 {{end}} {{if}};
              {{end}} {{if}};
           {{end}} {{process}} makeState;
        {{end}} noPlatformSpecific;
        
        """ + "\n")
    } else {
      contents.add(
        """
        module singleBitShiftReg ( reset,
                                   {{tick}},
                                   {{clock}},
                                   shiftEnable,
                                   parLoad,
                                   shiftIn,
                                   d,
                                   shiftOut,
                                   q);
        
           parameter {{nrOfStages}} = 1;
           parameter {{invertClock}} = 1;
        
           input reset;
           input {{tick}};
           input {{clock}};
           input shiftEnable;
           input parLoad;
           input shiftIn;
           input[{{nrOfStages}}:0] d;
           output shiftOut;
           output[{{nrOfStages}}:0] q;
        
           wire[{{nrOfStages}}:0] s_stateNext;
           wire s_clock;
           reg[{{nrOfStages}}:0] s_stateReg;
        
           assign q        = s_stateReg;
           assign shiftOut = s_stateReg[{{nrOfStages}}-1];
           assign s_clock  = {{invertClock}} == 0 ? {{clock}} : ~{{clock}};
           assign s_stateNext = (parLoad) ? d : {s_stateReg[{{nrOfStages}}-2:0],shiftIn};
        
           always @(posedge s_clock or posedge reset)
           begin
              if (reset) s_stateReg <= 0;
              else if ((shiftEnable|parLoad)&{{tick}}) s_stateReg <= s_stateNext;
           end
        
        endmodule
        """ + "\n")
    }
    contents.empty()
    return contents.get()
  }

  public override func getComponentDeclarationSection(
    netlist: any HdlNetlist, attrs: any AttributeSet
  ) -> LineBuffer {
    extraComponent(isEntity: false)
  }

  /// `ShiftRegisterHdlGeneratorFactory.getExtraComp(boolean)`.
  private func extraComponent(isEntity: Bool) -> LineBuffer {
    LineBuffer.getHdlBuffer().addVhdlKeywords()
      .pair("clock", Self.clockName)
      .pair("tick", Self.tickName)
      .pair("nrOfStages", Self.nrOfStagesString)
      .pair("invertClock", Self.negateClockString)
      .add(isEntity ? "{{entity}} singleBitShiftReg {{is}}" : "{{component}} singleBitShiftReg")
      .add(
        """
           {{generic}} ( {{invertClock}} : {{integer}};
                     {{nrOfStages}}  : {{integer}} );
           {{port}} ( reset       : {{in}}  std_logic;
                  {{tick}}        : {{in}}  std_logic;
                  {{clock}}       : {{in}}  std_logic;
                  shiftEnable : {{in}}  std_logic;
                  parLoad     : {{in}}  std_logic;
                  shiftIn     : {{in}}  std_logic;
                  d           : {{in}}  std_logic_vector( ({{nrOfStages}}-1) {{downto}} 0 );
                  shiftOut    : {{out}} std_logic;
                  q           : {{out}} std_logic_vector( ({{nrOfStages}}-1) {{downto}} 0 ) );
        """ + "\n")
      .add(isEntity ? "{{end}} {{entity}} singleBitShiftReg;" : "{{end}} {{component}};")
  }

  private static let clockName = HdlPorts.getClockName(1)
  private static let tickName = HdlPorts.getTickName(1)

  public override func getEntity(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> [String] {
    let contents = LineBuffer.getHdlBuffer()
    if Hdl.isVhdl() {
      contents
        .add(super.getEntity(netlist: netlist, attrs: attrs, componentName: componentName))
        .empty()
        .add(Hdl.getExtendedLibrary())
        .add(extraComponent(isEntity: true))
    }
    return contents.get()
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents = LineBuffer.getHdlBuffer()
      .pair("clock", Self.clockName)
      .pair("tick", Self.tickName)
      .pair("nrOfStages", Self.nrOfStagesString)
      .pair("invertClock", Self.negateClockString)
      .pair("nrOfBits", Self.nrOfBitsString)
    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        genBits : {{for}} n {{in}} ({{nrOfBits}}-1) {{downto}} 0 {{generate}}
           OneBit : singleBitShiftReg
           {{generic}} {{map}} ( {{invertClock}} => {{invertClock}},
                         {{nrOfStages}} => {{nrOfStages}} )
           {{port}} {{map}} ( reset       => reset,
                      {{tick}}        => {{tick}},
                      {{clock}}       => {{clock}},
                      shiftEnable => shiftEnable,
                      parLoad     => parLoad,
                      shiftIn     => shiftIn(n),
                      d           => d( ((n+1) * {{nrOfStages}})-1 {{downto}} (n*{{nrOfStages}})),
                      shiftOut    => shiftOut(n),
                      q           => q( ((n+1) * {{nrOfStages}})-1 {{downto}} (n*{{nrOfStages}})) );
        {{end}} {{generate}} genBits;
        """)
    } else {
      contents.add(
        """
        genvar n;
        generate
           for (n = 0 ; n < {{nrOfBits}}; n=n+1)
           begin:Bit
              singleBitShiftReg #(.{{invertClock}}({{invertClock}}),
                                  .{{nrOfStages}}({{nrOfStages}}))
                 OneBit (.reset(reset),
                         .{{tick}}({{tick}}),
                         .{{clock}}({{clock}}),
                         .shiftEnable(shiftEnable),
                         .parLoad(parLoad),
                         .shiftIn(shiftIn[n]),
                         .d(d[((n+1)*{{nrOfStages}})-1:(n*{{nrOfStages}})]),
                         .shiftOut(shiftOut[n]),
                         .q(q[((n+1)*{{nrOfStages}})-1:(n*{{nrOfStages}})]) );
           end
        endgenerate
        """)
    }
    return contents.empty()
  }
}
