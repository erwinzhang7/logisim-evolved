// PriorityEncoderHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/plexers/PriorityEncoderHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// A 64-to-6 binary-search priority encoder. It is the one generator in these three families that
// overrides `getPortMap`; the input vector is a *bundle* of `nrOfEnds - 4` single-bit component
// pins that has to be mapped bit by bit in VHDL and concatenated into one `{...}` literal in
// Verilog, which the generic port-map machinery cannot express.
//
// ── UPSTREAM BUGS, PRESERVED ────────────────────────────────────────────────────────────────
//
// Two in the Verilog body, both real and both reproduced verbatim under standing rule 4:
//
//   1. `assign s_selectVector0[63:{{selBits}}] = 0;` and the line after it use the *select* bit
//      count where the VHDL body uses the *input* bit count (`{{inBits}}`). With the default
//      3-bit select that zeroes bits 63:3 and drives 2:0 from an 8-bit input vector, so five of
//      the eight inputs are silently discarded.
//   2. `assign s_selectVector4 = … ? s_selectVector3[3:0] : s_selectVector2[7:4];` reads
//      `s_selectVector2` in the else arm where every other stage reads the stage above it
//      (`s_selectVector3[7:4]`). The VHDL body has neither bug.

import LogisimKernel

/// `com.cburch.logisim.std.plexers.PriorityEncoderHdlGeneratorFactory`.
public final class PriorityEncoderHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let nrOfSelectBitsString = "nrOfSelectBits"
  private static let nrOfSelectBitsId = -1
  private static let nrOfInputBitsString = "nrOfInputBits"
  private static let nrOfInputBitsId = -2

  /// `PriorityEncoder.EN_IN` / `GS` / `EN_OUT` / `OUT`: the four fixed pins that follow the
  /// variable-length input bundle. `PriorityEncoder` lives in `LogisimStd`, so the indices are
  /// restated here rather than imported; they are part of the component's wire format and cannot
  /// change without breaking every saved file.
  private static let enableInOffset = 0
  private static let groupSelectOffset = 1
  private static let enableOutOffset = 2
  private static let addressOffset = 3

  public init(bindings: GatesHdlBindings) {
    super.init(subDirectory: "plexers", widthAttribute: bindings.width)
    myParametersList
      .add(
        Self.nrOfInputBitsString, Self.nrOfInputBitsId,
        kind: .power2(attributes: [bindings.plexerSelect], offset: 0))
      .add(
        Self.nrOfSelectBitsString, Self.nrOfSelectBitsId,
        kind: .intAttribute(bindings.plexerSelect, offset: 0))
    myWires
      .addWire("s_inIsZero", 1)
      .addWire("s_address", 6)
      .addWire("s_selectVector0", 64)
      .addWire("s_selectVector1", 32)
      .addWire("s_selectVector2", 16)
      .addWire("s_selectVector3", 8)
      .addWire("s_selectVector4", 4)
    myPorts
      .add(.input, "enable", nrOfBits: 1, componentPinId: 0)
      .add(.input, "inputVector", nrOfBits: Self.nrOfInputBitsId, componentPinId: 0)
      .add(.output, "groupSelect", nrOfBits: 1, componentPinId: 0)
      .add(.output, "enableOut", nrOfBits: 1, componentPinId: 0)
      .add(.output, "address", nrOfBits: Self.nrOfSelectBitsId, componentPinId: 0)
  }

  public override func getPortMap(
    netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?
  ) -> [String: String] {
    var map: [String: String] = [:]
    guard let comp = componentInfo else { return map }
    let nrOfBits = comp.nrOfEnds - 4
    for (key, value) in Hdl.getNetMap(
      sourceName: "enable", floatingPinTiedToGround: false, comp: comp,
      endIndex: nrOfBits + Self.enableInOffset, netlist: netlist)
    {
      map[key] = value
    }
    var vectorList = ""
    var index = nrOfBits - 1
    while index >= 0 {
      if Hdl.isVhdl() {
        for (key, value) in Hdl.getNetMap(
          sourceName: "inputVector(\(index))", floatingPinTiedToGround: true, comp: comp,
          endIndex: index, netlist: netlist)
        {
          map[key] = value
        }
      } else {
        if !vectorList.isEmpty { vectorList += "," }
        vectorList += Hdl.getNetName(
          comp, endIndex: index, floatingNetTiedToGround: true, netlist: netlist)
      }
      index -= 1
    }
    if Hdl.isVerilog() { map["inputVector"] = vectorList }
    for (name, offset) in [
      ("groupSelect", Self.groupSelectOffset),
      ("enableOut", Self.enableOutOffset),
      ("address", Self.addressOffset),
    ] {
      for (key, value) in Hdl.getNetMap(
        sourceName: name, floatingPinTiedToGround: true, comp: comp,
        endIndex: nrOfBits + offset, netlist: netlist)
      {
        map[key] = value
      }
    }
    return map
  }

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    let contents =
      LineBuffer.getBuffer()
      .pair("selBits", Self.nrOfSelectBitsString)
      .pair("inBits", Self.nrOfInputBitsString)

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().add(
        """
        -- Output Signals
        groupSelect <= {{not}}(s_inIsZero) {{and}} enable;
        enableOut   <= s_inIsZero {{and}} enable;
        address     <= ({{others}} => '0') {{when}} enable = '0' {{else}}
                       s_address({{selBits}}-1 {{downto}} 0);

        -- Control Signals
        s_inIsZero  <= '1' {{when}} inputVector = std_logic_vector(to_unsigned(0,{{inBits}})) {{else}} '0';

        -- Processes
        makeAddr : {{process}}(inputVector, s_selectVector0, s_selectVector1, s_selectVector2, s_selectVector3, s_selectVector4) {{is}}
        {{begin}}
           s_selectVector0(63 {{downto}} {{inBits}})  <= ({{others}} => '0');
           s_selectVector0({{inBits}}-1 {{downto}} 0) <= inputVector;
           {{if}} (s_selectVector0(63 {{downto}} 32) = X"00000000") {{then}} s_address(5)      <= '0';
                                                                 s_selectVector1 <= s_selectVector0(31 {{downto}} 0);
                                                            {{else}} s_address(5)      <= '1';
                                                                 s_selectVector1 <= s_selectVector0(63 {{downto}} 32);
           {{end}} {{if}};
           {{if}} (s_selectVector1(31 {{downto}} 16) = X"0000") {{then}} s_address(4)      <= '0';
                                                             s_selectVector2 <= s_selectVector1(15 {{downto}} 0);
                                                        {{else}} s_address(4)      <= '1';
                                                             s_selectVector2 <= s_selectVector1(31 {{downto}} 16);
           {{end}} {{if}};
           {{if}} (s_selectVector2(15 {{downto}} 8) = X"00") {{then}} s_address(3)      <= '0';
                                                          s_selectVector3 <= s_selectVector2(7 {{downto}} 0);
                                                     {{else}} s_address(3)      <= '1';
                                                          s_selectVector3 <= s_selectVector2(15 {{downto}} 8);
           {{end}} {{if}};
           {{if}} (s_selectVector3(7 {{downto}} 4) = X"0") {{then}} s_address(2)      <= '0';
                                                        s_selectVector4 <= s_selectVector3(3 {{downto}} 0);
                                                   {{else}} s_address(2)      <= '1';
                                                        s_selectVector4 <= s_selectVector3(7 {{downto}} 4);
           {{end}} {{if}};
           {{if}} (s_selectVector4(3 {{downto}} 2) = "00") {{then}} s_address(1) <= '0';
                                                        s_address(0) <= s_selectVector4(1);
                                                   {{else}} s_address(1) <= '1';
                                                        s_address(0) <= s_selectVector4(3);
           {{end}} {{if}};
        {{end}} {{process}} makeAddr;
        """)
    } else {
      contents.add(
        """
        assign groupSelect = ~s_inIsZero&enable;
        assign enableOut = s_inIsZero&enable;
        assign address = (~enable) ? 0 : s_address[{{selBits}}-1:0];
        assign s_inIsZero = (inputVector == 0) ? 1'b1 : 1'b0;

        assign s_selectVector0[63:{{selBits}}] = 0;
        assign s_selectVector0[{{selBits}}-1:0] = inputVector;
        assign s_address[5] = (s_selectVector0[63:32] == 0) ? 1'b0 : 1'b1;
        assign s_selectVector1 = (s_selectVector0[63:32] == 0) ? s_selectVector0[31:0] : s_selectVector0[63:32];
        assign s_address[4] = (s_selectVector1[31:16] == 0) ? 1'b0 : 1'b1;
        assign s_selectVector2 = (s_selectVector1[31:16] == 0) ? s_selectVector1[15:0] : s_selectVector1[31:16];
        assign s_address[3] = (s_selectVector2[15:8] == 0) ? 1'b0 : 1'b1;
        assign s_selectVector3 = (s_selectVector2[15:8] == 0) ? s_selectVector2[7:0] : s_selectVector2[15:8];
        assign s_address[2] = (s_selectVector3[7:4] == 0) ? 1'b0 : 1'b1;
        assign s_selectVector4 = (s_selectVector3[7:4] == 0) ? s_selectVector3[3:0] : s_selectVector2[7:4];
        assign s_address[1] = (s_selectVector4[3:2] == 0) ? 1'b0 : 1'b1;
        assign s_address[0] = (s_selectVector4[3:2] == 0) ? s_selectVector4[1] : s_selectVector4[3];
        """)
    }
    return contents.empty()
  }
}
