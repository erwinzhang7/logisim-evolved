// MemoryRamHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/memory/RamHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// ── Two memory implementations, deliberately not collapsed ──────────────────────────────────
//
// `Mem.ENABLES_ATTR` selects between two structurally different designs, and every one of the
// four methods below (`getGenerationTimeWiresPorts`, `getModuleFunctionality`) forks on it:
//
//   * **`Mem.USELINEENABLES`**: a semi-dual-ported block RAM driven at several FPGA clocks per
//     Logisim tick, so that Logisim's *asynchronous read, write-after-read* simulation semantics
//     can be reproduced on synchronous FPGA memory. Its state machine has `dataLines + 1` tick
//     pipeline stages and an address offset register one bit wider than the address bus.
//     Upstream's own comment warns this needs the tick frequency to be ≥5× slower than the FPGA
//     clock and that it does not work at all behind a gated clock; that comment is reproduced.
//
//   * **anything else (byte enables)**: a plain synchronous RAM with a three-stage tick delay
//     line, optionally split into one 8-bit sub-memory per byte-enable port, with a narrower
//     "truncated" sub-memory at the top when the data width is not a multiple of 8.
//
// The generated text differs in wire names, register widths, port lists and process structure,
// so the two must be reproduced separately. Sharing one path would produce plausible HDL for
// one configuration and silently wrong HDL for the other.
//
// ── Why the ports are built at generation time ──────────────────────────────────────────────
//
// The port list depends on the data width (byte-enable count), the address width, the line size
// and the trigger, so it cannot exist at construction. `getWiresPortsDuringHdlWriting = true`
// makes the framework call `getGenerationTimeWiresPorts` from inside `getArchitecture`,
// `getPortMap` and `getVHDLBlackBox`.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RamHdlGeneratorFactory`.
public final class MemoryRamHdlGeneratorFactory: AbstractHdlGeneratorFactory {

  private static let byteArrayString = "byteArray"
  private static let byteArrayId = -1
  private static let restArrayString = "restArray"
  private static let restArrayId = -2
  private static let memArrayString = "memoryArray"
  private static let memArrayId = -3

  public init() {
    super.init(subDirectory: MemoryHdl.subdirectory, widthAttribute: StdAttr.width)
    getWiresPortsDuringHdlWriting = true
    clockAttributes = MemoryHdl.clockAttributes
    labelAttribute = StdAttr.label
  }

  // MARK: - Attribute reads shared by both implementations

  private func usesLineEnables(_ attrs: any AttributeSet) -> Bool {
    MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memEnables)
      == MemoryHdl.Option.memUseLineEnables
  }

  private func dataWidth(_ attrs: any AttributeSet) -> Int {
    MemoryHdl.widthValue(attrs, named: MemoryHdl.AttributeName.memData, default: 0)
  }

  private func addressWidth(_ attrs: any AttributeSet) -> Int {
    MemoryHdl.widthValue(attrs, named: MemoryHdl.AttributeName.memAddress, default: 0)
  }

  private func hasByteEnables(_ attrs: any AttributeSet) -> Bool {
    MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.ramByteEnables)
      == MemoryHdl.Option.ramWithByteEnables
  }

  // MARK: - Ports and wires

  public override func getGenerationTimeWiresPorts(netlist: any HdlNetlist, attrs: any AttributeSet)
  {
    if usesLineEnables(attrs) {
      generationTimeWiresPortsLineEnables(attrs)
    } else {
      generationTimeWiresPortsByteEnables(attrs)
    }
  }

  /// `RamHdlGeneratorFactory.getGenerationTimeWiresPortsLineEnables`.
  private func generationTimeWiresPortsLineEnables(_ attrs: any AttributeSet) {
    let nrOfBits = dataWidth(attrs)
    let nrOfAddressLines = addressWidth(attrs)
    let ramEntries = 1 << nrOfAddressLines
    let dataLines = max(1, MemoryRamPortIndices.nrLePorts(attrs))
    myWires
      .addRegister("s_writeAddressReg", nrOfAddressLines)
      .addRegister("s_readAddressReg", nrOfAddressLines)
      .addWire("s_ramWriteAddress", nrOfAddressLines)
      .addWire("s_ramReadAddress", nrOfAddressLines)
      .addRegister("s_ramDataOut", nrOfBits)
      .addWire("s_ramWe", 1)
      .addRegister("s_weReg", 1)
      .addRegister("s_tickDelayReg", dataLines + 1)
      .addRegister("s_addressOffsetReg", nrOfAddressLines + 1)
    if dataLines == 1 {
      myWires.addWire("s_ramDataIn", nrOfBits)
    } else {
      myWires.addRegister("s_ramDataIn", nrOfBits)
    }
    if dataLines > 1 {
      for index in 0..<dataLines {
        myWires
          .addRegister("s_dataIn\(index)Reg", nrOfBits)
          .addRegister("s_dataOut\(index)Reg", nrOfBits)
          .addRegister("s_lineEnable\(index)Reg", 1)
        myPorts
          .add(
            .input, "data\(index)In", nrOfBits: nrOfBits,
            componentPinId: MemoryRamPortIndices.dataInIndex(index, attrs))
          .add(
            .output, "data\(index)Out", nrOfBits: nrOfBits,
            componentPinId: MemoryRamPortIndices.dataOutIndex(index, attrs))
          .add(
            .input, "lineEnable\(index)In", nrOfBits: 1,
            componentPinId: MemoryRamPortIndices.leIndex(index, attrs))
      }
    } else {
      myWires
        .addRegister("s_dataInReg", nrOfBits)
        .addRegister("s_dataOutReg", nrOfBits)
      myPorts
        .add(
          .input, "dataIn", nrOfBits: nrOfBits,
          componentPinId: MemoryRamPortIndices.dataInIndex(0, attrs))
        .add(
          .output, "dataOut", nrOfBits: nrOfBits,
          componentPinId: MemoryRamPortIndices.dataOutIndex(0, attrs))
    }
    myTypedWires
      .addArray(Self.memArrayId, Self.memArrayString, nrOfBits: nrOfBits, nrOfEntries: ramEntries)
      .addWire("s_memContents", typeIdentifier: Self.memArrayId)
    myPorts
      .add(
        .input, "address", nrOfBits: nrOfAddressLines,
        componentPinId: MemoryRamPortIndices.addrIndex(0, attrs))
      .add(.input, "we", nrOfBits: 1, componentPinId: MemoryRamPortIndices.weIndex(0, attrs))
      .add(
        .clock, HdlPorts.getClockName(1), nrOfBits: 1,
        componentPinId: MemoryRamPortIndices.clkIndex(0, attrs))
  }

  /// `RamHdlGeneratorFactory.getGenerationTimeWiresPortsByteEnables`.
  private func generationTimeWiresPortsByteEnables(_ attrs: any AttributeSet) {
    let nrOfBits = dataWidth(attrs)
    let byteEnables = hasByteEnables(attrs)
    let byteEnableOffset = MemoryRamPortIndices.beIndex(0, attrs)
    let nrBePorts = MemoryRamPortIndices.nrBePorts(attrs)
    let nrOfAddressLines = addressWidth(attrs)
    let ramEntries = 1 << nrOfAddressLines
    let truncated = (nrOfBits % 8) != 0
    myWires
      .addRegister("s_ramDataOut", nrOfBits)
      .addRegister("s_tickDelayLine", 3)
      .addRegister("s_dataInReg", nrOfBits)
      .addRegister("s_writeAddressReg", nrOfAddressLines)
      .addRegister("s_readAddressReg", nrOfAddressLines)
      .addRegister("s_weReg", 1)
      .addRegister("s_oeReg", 1)
      .addRegister("s_dataOutReg", nrOfBits)
      .addWire("s_ramAddress", nrOfAddressLines)
    if byteEnables {
      myWires.addRegister("s_byteEnableReg", nrBePorts)
      for index in 0..<nrBePorts {
        myWires
          .addWire("s_byteEnable\(index)", 1)
          .addWire("s_we\(index)", 1)
        myPorts.add(
          .input, "byteEnable\(index)", nrOfBits: 1,
          componentPinId: byteEnableOffset + nrBePorts - index - 1)
      }
      myPorts.add(
        .input, "oe", nrOfBits: 1, componentPinId: MemoryRamPortIndices.oeIndex(0, attrs))
      var nrOfMems = nrBePorts
      if truncated {
        myTypedWires
          .addArray(
            Self.restArrayId, Self.restArrayString, nrOfBits: nrOfBits % 8,
            nrOfEntries: ramEntries)
          .addWire("s_truncMemContents", typeIdentifier: Self.restArrayId)
        nrOfMems -= 1
      }
      myTypedWires.addArray(
        Self.byteArrayId, Self.byteArrayString, nrOfBits: 8, nrOfEntries: ramEntries)
      for mem in 0..<max(0, nrOfMems) {
        myTypedWires.addWire("s_byteMem\(mem)Contents", typeIdentifier: Self.byteArrayId)
      }
    } else {
      myPorts.add(.input, "oe", nrOfBits: 1, fixedMap: Hdl.oneBit())
      myTypedWires
        .addArray(Self.memArrayId, Self.memArrayString, nrOfBits: nrOfBits, nrOfEntries: ramEntries)
        .addWire("s_memContents", typeIdentifier: Self.memArrayId)
      myWires
        .addWire("s_we", 1)
        .addWire("s_oe", 1)
    }
    myPorts
      .add(
        .input, "address", nrOfBits: nrOfAddressLines,
        componentPinId: MemoryRamPortIndices.addrIndex(0, attrs))
      .add(
        .input, "dataIn", nrOfBits: nrOfBits,
        componentPinId: MemoryRamPortIndices.dataInIndex(0, attrs))
      .add(.input, "we", nrOfBits: 1, componentPinId: MemoryRamPortIndices.weIndex(0, attrs))
      .add(
        .output, "dataOut", nrOfBits: nrOfBits,
        componentPinId: MemoryRamPortIndices.dataOutIndex(0, attrs))
      .add(
        .clock, HdlPorts.getClockName(1), nrOfBits: 1,
        componentPinId: MemoryRamPortIndices.clkIndex(0, attrs))
  }

  // MARK: - Module functionality

  public override func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    usesLineEnables(attrs)
      ? moduleFunctionalityLineEnables(attrs) : moduleFunctionalityByteEnables(attrs)
  }

  /// `RamHdlGeneratorFactory.getModuleFunctionalityByteEnables`.
  private func moduleFunctionalityByteEnables(_ attrs: any AttributeSet) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
      .pair("clock", HdlPorts.getClockName(1))
      .pair("tick", HdlPorts.getTickName(1))
    let byteEnables = hasByteEnables(attrs)
    let syncRead = !MemoryHdl.booleanValue(
      attrs, named: MemoryHdl.AttributeName.memAsyncRead, default: false)
    // Java uses non-short-circuiting `&` here; both operands are side-effect free, so `&&` is
    // equivalent, but note `getValue(READ_ATTR)` is evaluated even when the attribute is
    // absent upstream, which `RamAttributes` answers from a field rather than the list.
    let readAfterWrite =
      MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.memReadBehavior)
      == MemoryHdl.Option.memReadAfterWrite
    let writeTick = readAfterWrite ? 0 : 2
    let nrBePorts = MemoryRamPortIndices.nrBePorts(attrs)
    let nrOfBits = dataWidth(attrs)

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords().addRemarkBlock("The control signals are defined here")
      if byteEnables {
        for index in 0..<nrBePorts {
          contents
            .add(
              "s_byteEnable{{1}} <= s_byteEnableReg({{1}}) {{and}} s_tickDelayLine(2) {{and}} s_oeReg;",
              index)
            .add(
              "s_we{{1}}         <= s_byteEnableReg({{1}}) {{and}} s_tickDelayLine({{2}}) {{and}} s_weReg;",
              index, writeTick)
        }
      } else {
        contents
          .add("s_oe <= s_tickDelayLine(2) {{and}} s_oeReg;")
          .add("s_we <= s_tickDelayLine({{1}}) {{and}} s_weReg;", writeTick)
      }
      contents
        .empty()
        .addRemarkBlock("The input registers are defined here")
        .add(
          """
          inputRegs : {{process}}({{clock}}, {{tick}}, address, dataIn, we, oe) {{is}}
          {{begin}}
             {{if}} (rising_edge({{clock}})) {{then}}
          """)
      if !syncRead {
        contents.add(
          """
                {{if}} (s_tickDelayLine(0) = '1') {{then}}
                   s_readAddressReg  <= address;
                {{end}} {{if}};
          """)
      }
      contents.add(
        """
                {{if}} ({{tick}} = '1') {{then}}
                  s_dataInReg       <= dataIn;
                  s_writeAddressReg <= address;
        """)
      if syncRead {
        contents.add("          s_readAddressReg  <= address;")
      }
      contents.add(
        """
                  s_weReg           <= we;
                  s_oeReg           <= oe;
        """)
      if byteEnables {
        for index in 0..<nrBePorts {
          contents.add("         s_byteEnableReg({{1}}) <= byteEnable{{1}};", index)
        }
      }
      contents
        .add(
          """
                {{end}} {{if}};
             {{end}} {{if}};
          {{end}} {{process}} inputRegs;
          """)
        .empty()
        .add(
          """
          tickPipeReg : {{process}}({{clock}}) {{is}}
          {{begin}}
             {{if}} (rising_edge({{clock}})) {{then}}
                 s_tickDelayLine(0)          <= {{tick}};
                 s_tickDelayLine(2 {{downto}} 1) <= s_tickDelayLine(1 {{downto}} 0);
             {{end}} {{if}};
          {{end}} {{process}} tickPipeReg;
          """)
        .empty()
        .addRemarkBlock("The actual memorie(s) is(are) defined here")
      contents
        .add(
          "s_ramAddress <= s_writeAddressReg {{when}} s_tickDelayLine({{1}}) = '1' {{else}} s_readAddressReg;",
          writeTick)
        .empty()
      if byteEnables {
        let truncated = (nrOfBits % 8) != 0
        for index in 0..<nrBePorts {
          contents
            .add("mem{{1}} : {{process}}({{clock}}, s_we{{1}}, s_dataInReg, s_ramAddress) {{is}}", index)
            .add("{{begin}}")
            .add("   {{if}} (rising_edge({{clock}})) {{then}}")
            .add("      {{if}} (s_we{{1}} = '1') {{then}}", index)
          let startIndex = index * 8
          let endIndex = (index == nrBePorts - 1) ? nrOfBits - 1 : (index + 1) * 8 - 1
          let memName =
            (index == nrBePorts - 1 && truncated)
            ? "s_truncMemContents" : "s_byteMem\(index)Contents"
          contents
            .add(
              "         {{1}}(to_integer(unsigned(s_ramAddress))) <= s_dataInReg({{2}} {{downto}} {{3}});",
              memName, endIndex, startIndex)
            .add("      {{end}} {{if}};")
            .add(
              "      s_ramDataOut({{1}} {{downto}} {{2}}) <= {{3}}(to_integer(unsigned(s_ramAddress)));",
              endIndex, startIndex, memName)
            .add("   {{end}} {{if}};")
            .add("{{end}} {{process}} mem{{1}};", index)
            .add("")
        }
      } else {
        contents.add(
          """
          mem : {{process}}({{clock}} , s_we, s_dataInReg, s_ramAddress) {{is}}
          {{begin}}
             {{if}} (rising_edge({{clock}})) {{then}}
                {{if}} (s_we = '1') {{then}}
                   s_memContents(to_integer(unsigned(s_ramAddress))) <= s_dataInReg;
                {{end}} {{if}};
                s_ramDataOut <= s_memContents(to_integer(unsigned(s_ramAddress)));
             {{end}} {{if}};
          {{end}} {{process}} mem;
          """)
      }
      contents.empty().addRemarkBlock("The output register is defined here")
      if byteEnables {
        for index in 0..<nrBePorts {
          contents
            .add("res{{1}} : {{process}}({{clock}}, s_byteEnable{{1}}, s_ramDataOut) {{is}}", index)
            .add("{{begin}}")
            .add("   {{if}} (rising_edge({{clock}})) {{then}}")
            .add("      {{if}} (s_byteEnable{{1}} = '1') {{then}}", index)
          let startIndex = index * 8
          let endIndex = (index == nrBePorts - 1) ? nrOfBits - 1 : (index + 1) * 8 - 1
          contents
            .add(
              "         dataOut({{1}} {{downto}} {{2}}) <= s_ramDataOut({{1}} {{downto}} {{2}});",
              endIndex, startIndex)
            .add("      {{end}} {{if}};")
            .add("   {{end}} {{if}};")
            .add("{{end}} {{process}} res{{1}};", index)
        }
      } else {
        contents.add(
          """
          res : {{process}}({{clock}}, s_oe, s_ramDataOut) {{is}}
          {{begin}}
             {{if}} (rising_edge({{clock}})) {{then}}
                {{if}} (s_oe = '1') {{then}}
                  dataOut <= s_ramDataOut;
                {{end}} {{if}};
             {{end}} {{if}};
          {{end}} {{process}} res;
          """)
      }
    } else {
      contents.empty().addVhdlKeywords().addRemarkBlock("The control signals are defined here")
      if byteEnables {
        for index in 0..<nrBePorts {
          contents
            .add(
              "assign s_byteEnable{{1}} = s_byteEnableReg[{{1}}] & s_tickDelayLine[2] & s_oeReg;",
              index)
            .add(
              "assign s_we{{1}}         = s_byteEnableReg[{{1}}] & s_tickDelayLine[{{2}}] & s_weReg;",
              index, writeTick)
        }
      } else {
        contents
          .add("assign s_oe = s_tickDelayLine[2] & s_oeReg;")
          .add("assign s_we = s_tickDelayLine[{{1}}] & s_weReg;", writeTick)
      }
      contents
        .empty()
        .addRemarkBlock("The input registers are defined here")
        .add(
          """
          always @(posedge {{clock}})
          begin
          """)
      if !syncRead {
        contents.add(
          "  s_readAddressReg <= (s_tickDelayLine[0] == 1'b1) ? address : s_readAddressReg;")
      }
      contents.add(
        """
           if ({{tick}} == 1'b1)
             begin
               s_dataInReg       <= dataIn;
               s_writeAddressReg <= address;
        """)
      if syncRead {
        contents.add("       s_readAddressReg  <= address;")
      }
      contents.add(
        """
               s_weReg           <= we;
               s_oeReg           <= oe;
        """)
      if byteEnables {
        for index in 0..<nrBePorts {
          contents.add("       s_byteEnableReg[{{1}}] <= byteEnable{{1}};", index)
        }
      }
      contents
        .add(
          """
            end
          end
          """)
        .empty()
        .add(
          """
          always @(posedge {{clock}})
            s_tickDelayLine <= {s_tickDelayLine[1:0], tick};
          """)
        .empty()
        .addRemarkBlock("The actual memorie(s) is(are) defined here")
      contents
        .add(
          "assign s_ramAddress = (s_tickDelayLine[{{1}}] == 1'b1) ? s_writeAddressReg : s_readAddressReg;",
          writeTick)
        .empty()
      if byteEnables {
        let truncated = (nrOfBits % 8) != 0
        for index in 0..<nrBePorts {
          // Upstream's source has four trailing spaces after `begin`, but a Java text block
          // strips incidental *trailing* white space from every line (JLS 3.10.6), so they
          // never reach the generated output. A Swift multi-line literal does not strip them,
          // so they must simply not be written.
          contents.add(
            """
            always @(posedge {{clock}})
              begin
            """)
          contents.add("    if (s_we{{1}} == 1'b1)", index)
          let startIndex = index * 8
          let endIndex = (index == nrBePorts - 1) ? nrOfBits - 1 : (index + 1) * 8 - 1
          let memName =
            (index == nrBePorts - 1 && truncated)
            ? "s_truncMemContents" : "s_byteMem\(index)Contents"
          contents
            .add("      {{1}}[s_ramAddress] <= s_dataInReg[{{2}}:{{3}}];", memName, endIndex, startIndex)
            .add("    s_ramDataOut[{{1}}:{{2}}] <= {{3}}[s_ramAddress];", endIndex, startIndex, memName)
            .add("  end")
            .empty()
        }
      } else {
        contents.add(
          """
          always @(posedge clock)
            begin
              if (s_we == 1'b1)
                s_memContents[s_ramAddress] <= s_dataInReg;
              s_ramDataOut <= s_memContents[s_ramAddress];
            end
          """)
      }
      contents
        .empty()
        .addRemarkBlock("The output register is defined here")
        .add("assign dataOut = s_dataOutReg;")
      if byteEnables {
        for index in 0..<nrBePorts {
          contents
            .add("always @(posedge {{clock}})")
            .add("  if (s_byteEnable{{1}} == 1'b1)", index)
          let startIndex = index * 8
          let endIndex = (index == nrBePorts - 1) ? nrOfBits - 1 : (index + 1) * 8 - 1
          contents
            .add("    s_dataOutReg[{{1}}:{{2}}] <= s_ramDataOut[{{1}}:{{2}}];", endIndex, startIndex)
            .empty()
        }
      } else {
        contents.add(
          """
          always @(posedge {{clock}})
            if (s_oe == 1'b1)
              s_dataOutReg <= s_ramDataOut;
          """)
      }
    }
    return contents.empty()
  }

  /// `RamHdlGeneratorFactory.getModuleFunctionalityLineEnables`.
  ///
  /// Upstream's own warning, kept because it is the reason the design looks the way it does:
  /// in the Logisim simulation a line-enabled RAM has asynchronous read and write-after-read;
  /// on an FPGA that is reproduced with semi-dual-ported synchronous memory over multiple
  /// cycles, up to nine FPGA clocks in the worst case, so the tick frequency has to be about
  /// five times slower than the FPGA clock. With a gated clock (a RAM not connected to a Clock
  /// component) this description does **not** work on hardware, and the two simulations will
  /// certainly differ. The module also uses SystemVerilog features.
  private func moduleFunctionalityLineEnables(_ attrs: any AttributeSet) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
      .pair("clock", HdlPorts.getClockName(1))
      .pair("tick", HdlPorts.getTickName(1))
    let dataLines = max(1, MemoryRamPortIndices.nrLePorts(attrs))
    let nrOfAddressLines = addressWidth(attrs)

    if Hdl.isVhdl() {
      contents.empty().addVhdlKeywords()
        .addRemarkBlock("The synchronous semi-dual-ported memory is defined here")
      contents.add(
        "s_ramWriteAddress <= std_logic_vector(unsigned(s_writeAddressReg) + unsigned(s_addressOffsetReg(\(nrOfAddressLines - 1) {{downto}} 0)));"
      )
      contents.add(
        "s_ramReadAddress <= std_logic_vector(unsigned(s_readAddressReg) + unsigned(s_addressOffsetReg(\(nrOfAddressLines - 1) {{downto}} 0)));"
      )
      contents.add(
        """

        blockramwrite : {{process}}({{clock}}) {{is}}
        {{begin}}
          {{if}} (rising_edge({{clock}})) {{then}}
            {{if}} (s_ramWe = '1') {{then}}
              s_memContents(to_integer(unsigned(s_ramWriteAddress))) <= s_ramDataIn;
            {{end}} {{if}};
          {{end}} {{if}};
        {{end}} {{process}} blockramwrite;

        blockramread : {{process}}({{clock}}) {{is}}
        {{begin}}
          {{if}} (falling_edge({{clock}})) {{then}}
            s_ramDataOut <= s_memContents(to_integer(unsigned(s_ramReadAddress)));
          {{end}} {{if}};
        {{end}} {{process}} blockramread;
        """)
      contents.empty().addRemarkBlock("The input registers are defined here")
      contents.add(
        """
        inputRegs : {{process}}({{clock}}) {{is}}
        {{begin}}
          {{if}} (rising_edge({{clock}})) {{then}}
            {{if}} (s_tickDelayReg(0) = '1') {{then}}
              s_readAddressReg <= address;
            {{end}} {{if}};
            {{if}} ({{tick}} = '1') {{then}}
              s_writeAddressReg <= address;
              s_weReg           <= we;
        """)
      if dataLines == 1 {
        contents.add("      s_dataInReg <= dataIn;")
      } else {
        for index in 0..<dataLines {
          contents.add("      s_dataIn\(index)Reg <= data\(index)In;")
          contents.add("      s_lineEnable\(index)Reg <= lineEnable\(index)In;")
        }
      }
      contents.add(
        """
            {{end}} {{if}};
          {{end}} {{if}};
        {{end}} {{process}} inputRegs;
        """)
      contents.empty().addRemarkBlock("The FSM's are defined here")
      contents.add(
        """
        fsms : {{process}}({{clock}}) {{is}}
        {{begin}}
           {{if}} (rising_edge({{clock}})) {{then}}
              s_tickDelayReg(0)  <= {{tick}};
        """)
      if dataLines == 1 {
        contents.add("      s_tickDelayReg(1)  <= s_tickDelayReg(0);")
      } else {
        contents.add(
          "      s_tickDelayReg(\(dataLines) {{downto}} 1) <= s_tickDelayReg(\(dataLines - 1) {{downto}} 0);"
        )
      }
      contents.add(
        """
              {{if}} (s_tickDelayReg(0) = '1') {{then}}
                s_addressOffsetReg <= (OTHERS => '0');
        """)
      contents.add(
        "      {{elsif}} (unsigned(s_addressOffsetReg) < to_unsigned(\(dataLines),\(nrOfAddressLines + 1))) {{then}}"
      )
      contents.add(
        "       s_addressOffsetReg <= std_logic_vector(unsigned(s_addressOffsetReg) + to_unsigned(1,\(nrOfAddressLines + 1)));"
      )
      contents.add(
        """
              {{end}} {{if}};
           {{end}} {{if}};
        {{end}} {{process}} fsms;
        """)
      contents.empty().addRemarkBlock("Here the RamDatIn is defined")
      if dataLines == 1 {
        contents.add("s_ramDataIn <= s_dataInReg;")
      } else {
        contents.add("{{with}} (s_addressOffsetReg) {{select}} s_ramDataIn <=")
        var index = dataLines - 1
        while index > 0 {
          // Java: `Integer.toBinaryString(idx)` padded to `nrOfaddressLines + 1` with a loop
          // whose bound is `nrOfaddressLines + 1 - binValue.length()`; note that is the
          // *length* the padding StringBuffer is grown to, not the number of zeros added, so
          // the result is `nrOfaddressLines + 1 - len` zeros followed by the digits.
          let binValue = String(index, radix: 2)
          var extendedBinValue = ""
          while extendedBinValue.count < (nrOfAddressLines + 1 - binValue.count) {
            extendedBinValue += "0"
          }
          extendedBinValue += binValue
          contents.add("  s_dataIn\(index)Reg {{when}} \"\(extendedBinValue)\",")
          index -= 1
        }
        contents.add("               s_dataIn0Reg {{when}} {{others}};")
      }
      contents.empty().addRemarkBlock("Here the RamDataOut is defined")
      if dataLines == 1 {
        contents.add(
          """
          dataOut <= s_dataOutReg;

          dataOutReg : {{process}} ({{clock}}) {{is}}
          {{begin}}
            {{if}} (rising_edge({{clock}})) {{then}}
              {{if}} (s_tickDelayReg(1) = '1') {{then}}
                s_dataOutReg <= s_ramDataOut;
              {{end}} {{if}};
            {{end}} {{if}};
          {{end}} {{process}} dataOutReg;
          """)
      } else {
        for index in 0..<dataLines {
          contents.add("data\(index)Out <= s_dataOut\(index)Reg;")
        }
        contents.add(
          """

          dataOutRegs : {{process}} ({{clock}}) {{is}}
          {{begin}}
            {{if}} (rising_edge({{clock}})) {{then}}
          """)
        for index in 0..<dataLines {
          contents.add("    {{if}} (s_tickDelayReg(\(index + 1)) = '1') {{then}}")
          contents.add("      s_dataOut\(index)Reg <= s_ramDataOut;")
          contents.add("    {{end}} {{if}};")
        }
        contents.add(
          """
            {{end}} {{if}};
          {{end}} {{process}} dataOutRegs;
          """)
      }
      contents.empty().addRemarkBlock("Here the Ram write enable is defined")
      if dataLines == 1 {
        contents.add("s_ramWe <= s_weReg {{and}} s_tickDelayReg(1);")
      } else {
        contents.add("s_ramWe <= s_weReg {{and}} (")
        for index in 0..<dataLines {
          contents.add(
            "          (s_lineEnable\(index)Reg {{and}} s_tickDelayReg(\(index + 1)))"
              + (index == dataLines - 1 ? ");" : " {{or}}"))
        }
      }
    } else {
      contents.empty()
        .addRemarkBlock("The synchronous semi-dual-ported memory is defined here")
      contents.add(
        "assign s_ramWriteAddress = s_writeAddressReg + s_addressOffsetReg[\(nrOfAddressLines - 1):0];"
      )
      contents.add(
        "assign s_ramReadAddress = s_readAddressReg + s_addressOffsetReg[\(nrOfAddressLines - 1):0];"
      )
      contents.empty()
      contents.add(
        """
        always @(posedge clock)
          if (s_ramWe == 1'b1) s_memContents[s_ramWriteAddress] <= s_ramDataIn;

        always @(negedge clock)
          s_ramDataOut <= s_memContents[s_ramReadAddress];
        """)
      contents.empty().addRemarkBlock("The input registers are defined here")
      contents.add(
        """
        always @(posedge clock)
          begin
            if (s_tickDelayReg[0] == 1'b1)
              s_readAddressReg <= address;
            if ({{tick}} == 1'b1)
              begin
                s_writeAddressReg     <= address;
                s_weReg               <= we;
        """)
      if dataLines == 1 {
        contents.add("        s_dataInReg      <= dataIn;")
      } else {
        for index in 0..<dataLines {
          contents.add("        s_dataIn\(index)Reg     <= data\(index)In;")
          contents.add("        s_lineEnable\(index)Reg <= lineEnable\(index)In;")
        }
      }
      contents.add(
        """
              end
            end
        """)
      contents.empty().addRemarkBlock("The FSM's are defined here")
      contents.add(
        """
        always @(posedge clock)
          begin
            s_tickDelayReg[0] <= {{tick}};
        """)
      if dataLines == 1 {
        contents.add("    s_tickDelayReg[1] <= s_tickDelayReg[0];")
      } else {
        contents.add("    s_tickDelayReg[\(dataLines):1] <= s_tickDelayReg[\(dataLines - 1):0];")
      }
      contents.add(
        "    s_addressOffsetReg <= (s_tickDelayReg[0] == 1'b1) ? \(nrOfAddressLines + 1)'d0 :")
      contents.add(
        "                          s_addressOffsetReg != \(nrOfAddressLines + 1)'d\(dataLines) ? s_addressOffsetReg + \(nrOfAddressLines + 1)'d1 :"
      )
      contents.add(
        """
                                  s_addressOffsetReg;
          end
        """)
      contents.empty().addRemarkBlock("Here the RamDatIn is defined")
      if dataLines == 1 {
        contents.add("assign s_ramDataIn = s_dataInReg;")
      } else {
        contents.add(
          """
          always @*
            case (s_addressOffsetReg)
          """)
        var index = dataLines - 1
        while index > 0 {
          contents.add(
            "    \(nrOfAddressLines + 1)'d\(index)    : s_ramDataIn <= s_dataIn\(index)Reg;")
          index -= 1
        }
        contents.add(
          """
              default : s_ramDataIn <= s_dataIn0Reg;
            endcase;
          """)
      }
      contents.empty().addRemarkBlock("Here the RamDatout is defined")
      if dataLines == 1 {
        contents.add(
          """
          assign dataOut = s_dataOutReg;

          always @(posedge clock)
            s_dataOutReg <= (s_tickDelayReg[1] == 1'b1) ? s_ramDataOut : s_dataOutReg;
          """)
      } else {
        for index in 0..<dataLines {
          contents.add("assign data\(index)Out = s_dataOut\(index)Reg;")
        }
        contents.add(
          """

          always @(posedge clock)
            begin
          """)
        for index in 0..<dataLines {
          contents.add(
            "    s_dataOut\(index)Reg <= (s_tickDelayReg[\(index + 1)] == 1'b1) ? s_ramDataOut : s_dataOut\(index)Reg;"
          )
        }
        contents.add(
          """
            end
          """)
      }
      contents.empty().addRemarkBlock("Here the Ram write enable is defined")
      if dataLines == 1 {
        contents.add("assign s_ramWe = s_weReg & s_tickDelayReg[1];")
      } else {
        contents.add("assign s_ramWe = s_weReg & (")
        for index in 0..<dataLines {
          contents.add(
            "                 (s_lineEnable\(index)Reg & s_tickDelayReg[\(index + 1)])"
              + (index == dataLines - 1 ? ");" : "|"))
        }
      }
    }
    return contents.empty()
  }

  /// `RamHdlGeneratorFactory.isHdlSupportedTarget(AttributeSet)`.
  ///
  /// A `null` attribute set answers `false` upstream; in this port the parameter is
  /// non-optional, so that arm has no equivalent. The rest is transcribed exactly, including
  /// `asynch` being true when the trigger attribute is *absent*.
  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    let separate =
      MemoryHdl.optionValue(attrs, named: MemoryHdl.AttributeName.ramDataBus)
      == MemoryHdl.Option.ramBusSeparate
    let trigger = attrs.containsAttribute(StdAttr.trigger) ? attrs.getValue(StdAttr.trigger) : nil
    let asynch = trigger == nil || trigger == StdAttr.triggerHigh || trigger == StdAttr.triggerLow
    let clearPin = MemoryHdl.booleanValue(
      attrs, named: MemoryHdl.AttributeName.ramClearPin, default: false)
    let isLineControlled = usesLineEnables(attrs)
    return (separate && !asynch && !clearPin) || (isLineControlled && !clearPin)
  }
}
