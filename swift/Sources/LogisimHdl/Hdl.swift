// Hdl: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/Hdl.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// The VHDL/Verilog operator and literal vocabulary every generator builds text from. Every
// function is a pure string computation branching on `HdlSettings.language`, with the
// exception of `writeEntity`/`writeArchitecture`, which perform the actual file write.

/// `com.cburch.logisim.fpga.hdlgenerator.Hdl`: a namespace, mirroring Java's
/// non-instantiable utility class.
public enum Hdl {

  public static let netName = "s_logisimNet"
  public static let busName = "s_logisimBus"

  /// Length of the remark block open/close/line-open/line-close sequences.
  public static let remarkMarkerLength = 3

  public static func isVhdl() -> Bool { HdlSettings.language == .vhdl }
  public static func isVerilog() -> Bool { HdlSettings.language == .verilog }

  public static func bracketOpen() -> String { isVhdl() ? "(" : "[" }
  public static func bracketClose() -> String { isVhdl() ? ")" : "]" }

  public static func getRemarkChar() -> String { isVhdl() ? "-" : "*" }

  /// Comment block opening sequence. Must be `remarkMarkerLength` long.
  public static func getRemarkBlockStart() -> String { isVhdl() ? "---" : "/**" }
  /// Comment block closing sequence. Must be `remarkMarkerLength` long.
  public static func getRemarkBlockEnd() -> String { isVhdl() ? "---" : "**/" }
  /// Comment block line (mid-block) opening sequence. Must be `remarkMarkerLength` long.
  public static func getRemarkBlockLineStart() -> String { isVhdl() ? "-- " : "** " }
  /// Comment block line (mid-block) closing sequence. Must be `remarkMarkerLength` long.
  public static func getRemarkBlockLineEnd() -> String { isVhdl() ? " --" : " **" }

  public static func getLineCommentStart() -> String { isVhdl() ? "-- " : "// " }

  public static func startIf(_ condition: String) -> String {
    isVhdl()
      ? LineBuffer.formatHdl("IF {{1}} THEN", condition)
      : LineBuffer.formatHdl("if ({{1}}) begin", condition)
  }

  public static func elseStatement() -> String {
    isVhdl() ? Vhdl.vhdlKeyword("ELSE") : "end else begin"
  }

  public static func elseIf(_ condition: String) -> String {
    isVhdl()
      ? LineBuffer.formatHdl(
        "{{1}} {{2}} {{3}}", Vhdl.vhdlKeyword("ELSIF"), condition, Vhdl.vhdlKeyword("THEN"))
      : LineBuffer.formatHdl("end else if ({{1}}) begin", condition)
  }

  public static func endIf() -> String {
    isVhdl() ? Vhdl.vhdlKeyword("END ") + Vhdl.vhdlKeyword("IF") : "end"
  }

  public static func assignPreamble() -> String { isVhdl() ? "" : "assign " }
  public static func assignOperator() -> String { isVhdl() ? " <= " : " = " }
  public static func equalOperator() -> String { isVhdl() ? " = " : "==" }
  public static func notEqualOperator() -> String { isVhdl() ? " \\= " : "!=" }

  private static func typecast(_ signal: String, _ signed: Bool) -> String {
    isVhdl()
      ? LineBuffer.formatHdl("{{1}}({{2}})", signed ? "signed" : "unsigned", signal)
      : (signed ? "$signed(" + signal + ")" : signal)
  }

  public static func greaterOperator(
    _ signalOne: String, _ signalTwo: String, signed: Bool, equal: Bool
  ) -> String {
    LineBuffer.formatHdl(
      "{{1}} >{{2}} {{3}}", typecast(signalOne, signed), equal ? "=" : "", typecast(signalTwo, signed))
  }

  public static func lessOperator(
    _ signalOne: String, _ signalTwo: String, signed: Bool, equal: Bool
  ) -> String {
    LineBuffer.formatHdl(
      "{{1}} <{{2}} {{3}}", typecast(signalOne, signed), equal ? "=" : "", typecast(signalTwo, signed))
  }

  public static func leqOperator(_ signalOne: String, _ signalTwo: String, signed: Bool) -> String
  {
    lessOperator(signalOne, signalTwo, signed: signed, equal: true)
  }

  public static func geqOperator(_ signalOne: String, _ signalTwo: String, signed: Bool) -> String
  {
    greaterOperator(signalOne, signalTwo, signed: signed, equal: true)
  }

  public static func risingEdge(_ signal: String) -> String {
    isVhdl() ? "rising_edge(\(signal))" : "posedge \(signal)"
  }

  public static func notOperator() -> String { isVhdl() ? Vhdl.vhdlKeyword(" NOT ") : "~" }
  public static func andOperator() -> String { isVhdl() ? Vhdl.vhdlKeyword(" AND ") : "&" }
  public static func orOperator() -> String { isVhdl() ? Vhdl.vhdlKeyword(" OR ") : "|" }
  public static func xorOperator() -> String { isVhdl() ? Vhdl.vhdlKeyword(" XOR ") : "^" }

  public static func addOperator(_ signalOne: String, _ signalTwo: String, signed: Bool) -> String
  {
    (isVhdl() ? "std_logic_vector(" : "") + typecast(signalOne, signed) + " + "
      + typecast(signalTwo, signed) + (isVhdl() ? ")" : "")
  }

  public static func subOperator(_ signalOne: String, _ signalTwo: String, signed: Bool) -> String
  {
    (isVhdl() ? "std_logic_vector(" : "") + typecast(signalOne, signed) + " - "
      + typecast(signalTwo, signed) + (isVhdl() ? ")" : "")
  }

  public static func shiftlOperator(
    _ signal: String, width: Int, distance: Int, arithmetic: Bool
  ) -> String {
    guard distance != 0 else { return signal }
    return isVhdl()
      ? LineBuffer.formatHdl(
        "{{1}}{{2}} & {{4}}{{3}}{{4}}", signal, splitVector(width - 1 - distance, 0),
        String(repeating: "0", count: distance), distance == 1 ? "'" : "\"")
      : LineBuffer.formatHdl(
        "{ {{{1}}{{2}},{{{3}}{1'b0}}}", signal, splitVector(width - 1 - distance, 0), distance)
  }

  public static func shiftrOperator(
    _ signal: String, width: Int, distance: Int, arithmetic: Bool
  ) -> String {
    guard distance != 0 else { return signal }
    if arithmetic {
      return isVhdl()
        ? LineBuffer.formatHdl(
          "({{1}}{{2}}0 => {{3}}({{1}})) & {{3}}{{4}}", width - 1, vectorLoopId(), signal,
          splitVector(width - 1, width - distance))
        : LineBuffer.formatHdl(
          "{ {{{1}}{{{2}}[{{1}}-1]}},{{2}}{{3}}}", width, signal,
          splitVector(width - 1, width - distance))
    } else {
      return isVhdl()
        ? LineBuffer.formatHdl(
          "{{1}}{{2}}{{1}} & {{3}}{{4}", (distance == 1 ? "'" : "\""),
          String(repeating: "0", count: distance), signal, splitVector(width - 1, width - distance))
        : LineBuffer.formatHdl(
          "{ {{{1}}{1'b0}},{{2}}{{3}}}", width, signal, splitVector(width - 1, width - distance))
    }
  }

  public static func sllOperator(_ signal: String, width: Int, distance: Int) -> String {
    shiftlOperator(signal, width: width, distance: distance, arithmetic: false)
  }

  public static func slaOperator(_ signal: String, width: Int, distance: Int) -> String {
    shiftlOperator(signal, width: width, distance: distance, arithmetic: true)
  }

  public static func srlOperator(_ signal: String, width: Int, distance: Int) -> String {
    shiftrOperator(signal, width: width, distance: distance, arithmetic: false)
  }

  public static func sraOperator(_ signal: String, width: Int, distance: Int) -> String {
    shiftrOperator(signal, width: width, distance: distance, arithmetic: true)
  }

  public static func rolOperator(_ signal: String, width: Int, distance: Int) -> String {
    LineBuffer.formatHdl(
      "{{1}}{{2}}{{3}}{{1}}{{4}}", signal, splitVector(width - 1 - distance, 0),
      isVhdl() ? " & " : ",", splitVector(width - 1, width - distance))
  }

  public static func rorOperator(_ signal: String, width: Int, distance: Int) -> String {
    LineBuffer.formatHdl(
      "{{1}}{{2}}{{3}}{{1}}{{4}}", signal, splitVector(distance, 0), isVhdl() ? " & " : ",",
      splitVector(width - 1, distance))
  }

  public static func zeroBit() -> String { isVhdl() ? "'0'" : "1'b0" }
  public static func oneBit() -> String { isVhdl() ? "'1'" : "1'b1" }

  public static func unconnected(empty: Bool) -> String {
    isVhdl() ? Vhdl.vhdlKeyword("OPEN") : (empty ? "" : "'bz")
  }

  public static func vectorLoopId() -> String { isVhdl() ? Vhdl.vhdlKeyword(" DOWNTO ") : ":" }

  /// `Hdl.splitVector(int, int)`.
  ///
  /// Upstream's `start == end` branch is `LineBuffer.formatHdl("{{<}}{{2}}{{>}}", start)`: a
  /// positional placeholder `{{2}}` fed a *single* argument, so `Pairs.fromArgs` only ever
  /// defines key `"1"`. Every other call site double-checked against this file's callers uses
  /// consistent 1-based numbering, which makes this one line read as a stray off-by-one
  /// (`{{1}}` was surely intended) rather than an intentional behaviour: and the numbering
  /// mismatch trips `LineBuffer`'s own placeholder validator, which would abort on every
  /// single-bit index. This port implements the evident intent, a single-bit index in the
  /// target HDL's own bracket syntax, directly, rather than encoding an unverified guess about
  /// what upstream's abort path does at runtime.
  public static func splitVector(_ start: Int, _ end: Int) -> String {
    if start == end { return "\(bracketOpen())\(start)\(bracketClose())" }
    return isVhdl()
      ? LineBuffer.formatHdl("({{1}}{{2}}{{3}})", start, vectorLoopId(), end)
      : LineBuffer.formatHdl("[{{1}}:{{2}}]", start, end)
  }

  /// `Hdl.getZeroVector(int, boolean)`.
  public static func getZeroVector(nrOfBits: Int, floatingPinTiedToGround: Bool) -> String {
    var contents = ""
    if isVhdl() {
      let fillValue = floatingPinTiedToGround ? "0" : "1"
      let hexFillValue = floatingPinTiedToGround ? "0" : "F"
      if nrOfBits == 1 {
        contents += "'" + fillValue + "'"
      } else {
        if nrOfBits % 4 > 0 {
          contents += "\""
          contents += String(repeating: fillValue, count: nrOfBits % 4)
          contents += "\""
          if nrOfBits > 3 { contents += "&" }
        }
        if nrOfBits / 4 > 0 {
          contents += "X\""
          contents += String(repeating: hexFillValue, count: max(0, nrOfBits / 4))
          contents += "\""
        }
      }
    } else {
      contents += "\(nrOfBits)'d"
      contents += floatingPinTiedToGround ? "0" : "-1"
    }
    return contents
  }

  /// `Hdl.getConstantVector(long, int)`.
  public static func getConstantVector(_ value: Int64, nrOfBits: Int) -> String {
    let nrHexDigits = nrOfBits / 4
    let nrSingleBits = nrOfBits % 4
    var hexDigits = [String](repeating: "", count: max(0, nrHexDigits))
    var singleBits = ""
    var shiftValue = value
    var hexIndex = nrHexDigits - 1
    while hexIndex >= 0 {
      let hexValue = shiftValue & 0xF
      shiftValue >>= 4
      hexDigits[hexIndex] = String(format1X: hexValue)
      hexIndex -= 1
    }
    var hexValue = ""
    for index in 0..<nrHexDigits { hexValue += hexDigits[index] }

    var mask: Int64 = nrSingleBits == 0 ? 0 : (1 << Int64(nrSingleBits - 1))
    while mask > 0 {
      singleBits += (shiftValue & mask) == 0 ? "0" : "1"
      mask >>= 1
    }

    if nrHexDigits > 0 && nrSingleBits > 0 {
      return isVhdl()
        ? LineBuffer.format("\"{{1}}\"&X\"{{2}}\"", singleBits, hexValue)
        : LineBuffer.format(
          "{{{1}}'b{{2}}, {{3}}'h{{4}}}", nrSingleBits, singleBits, nrHexDigits * 4, hexValue)
    }
    if nrHexDigits > 0 {
      return isVhdl()
        ? LineBuffer.format("X\"{{1}}\"", hexValue)
        : LineBuffer.format("{{1}}'h{{2}}", nrHexDigits * 4, hexValue)
    }
    if isVhdl() {
      let vhdlTicks = nrOfBits == 1 ? "'" : "\""
      return LineBuffer.format("{{1}}{{2}}{{1}}", vhdlTicks, singleBits)
    }
    return LineBuffer.format("{{1}}'b{{2}}", nrSingleBits, singleBits)
  }

  // MARK: - Netlist-facing helpers

  /// `Hdl.getNetName(netlistComponent, int, boolean, Netlist)`.
  public static func getNetName(
    _ comp: any HdlNetlistComponent, endIndex: Int, floatingNetTiedToGround: Bool,
    netlist: any HdlNetlist
  ) -> String {
    guard endIndex >= 0, endIndex < comp.nrOfEnds else { return "" }
    let floatingValue = floatingNetTiedToGround ? zeroBit() : oneBit()
    let thisEnd = comp.end(at: endIndex)
    let isOutput = thisEnd.isOutputEnd
    guard thisEnd.nrOfBits == 1 else { return "" }

    let solderPoint = thisEnd.solderPoint(atBit: 0)
    guard let parentNet = solderPoint.parentNet else {
      return LineBuffer.formatHdl(isOutput ? unconnected(empty: true) : floatingValue)
    }
    return parentNet.bitWidth == 1
      ? LineBuffer.formatHdl("{{1}}{{2}}", netName, netlist.netId(for: parentNet))
      : LineBuffer.formatHdl(
        "{{1}}{{2}}{{<}}{{3}}{{>}}", busName, netlist.netId(for: parentNet),
        solderPoint.parentNetBitIndex)
  }

  /// `Hdl.getBusEntryName(netlistComponent, int, boolean, int, Netlist)`.
  public static func getBusEntryName(
    _ comp: any HdlNetlistComponent, endIndex: Int, floatingNetTiedToGround: Bool, bitIndex: Int,
    netlist: any HdlNetlist
  ) -> String {
    guard endIndex >= 0, endIndex < comp.nrOfEnds else { return "" }
    let thisEnd = comp.end(at: endIndex)
    let isOutput = thisEnd.isOutputEnd
    let nrOfBits = thisEnd.nrOfBits
    guard nrOfBits > 1, bitIndex >= 0, bitIndex < nrOfBits else { return "" }

    let solderPoint = thisEnd.solderPoint(atBit: bitIndex)
    guard let connectedNet = solderPoint.parentNet else {
      return LineBuffer.formatHdl(
        isOutput ? unconnected(empty: false) : getZeroVector(
          nrOfBits: 1, floatingPinTiedToGround: floatingNetTiedToGround))
    }
    let connectedNetBitIndex = solderPoint.parentNetBitIndex
    return !connectedNet.isBus
      ? LineBuffer.formatHdl("{{1}}{{2}}", netName, netlist.netId(for: connectedNet))
      : LineBuffer.formatHdl(
        "{{1}}{{2}}{{<}}{{3}}{{>}}", busName, netlist.netId(for: connectedNet),
        connectedNetBitIndex)
  }

  /// `Hdl.getBusNameContinues(netlistComponent, int, Netlist)`.
  public static func getBusNameContinues(
    _ comp: any HdlNetlistComponent, endIndex: Int, netlist: any HdlNetlist
  ) -> String? {
    guard endIndex >= 0, endIndex < comp.nrOfEnds else { return nil }
    let connectionInformation = comp.end(at: endIndex)
    let nrOfBits = connectionInformation.nrOfBits
    if nrOfBits == 1 { return getNetName(comp, endIndex: endIndex, floatingNetTiedToGround: true, netlist: netlist) }
    guard netlist.isContinuesBus(comp, endIndex: endIndex) else { return nil }
    let first = connectionInformation.solderPoint(atBit: 0)
    guard let connectedNet = first.parentNet else { return nil }
    let last = connectionInformation.solderPoint(atBit: connectionInformation.nrOfBits - 1)
    return LineBuffer.formatHdl(
      "{{1}}{{2}}{{3}}", busName, netlist.netId(for: connectedNet),
      splitVector(last.parentNetBitIndex, first.parentNetBitIndex))
  }

  /// `Hdl.getBusName(netlistComponent, int, Netlist)`.
  public static func getBusName(
    _ comp: any HdlNetlistComponent, endIndex: Int, netlist: any HdlNetlist
  ) -> String? {
    guard endIndex >= 0, endIndex < comp.nrOfEnds else { return nil }
    let connectionInformation = comp.end(at: endIndex)
    let nrOfBits = connectionInformation.nrOfBits
    if nrOfBits == 1 { return getNetName(comp, endIndex: endIndex, floatingNetTiedToGround: true, netlist: netlist) }
    guard netlist.isContinuesBus(comp, endIndex: endIndex) else { return nil }
    let first = connectionInformation.solderPoint(atBit: 0)
    guard let connectedNet = first.parentNet else { return nil }
    if connectedNet.bitWidth != nrOfBits {
      return getBusNameContinues(comp, endIndex: endIndex, netlist: netlist)
    }
    return LineBuffer.format("{{1}}{{2}}", busName, netlist.netId(for: connectedNet))
  }

  /// `Hdl.getClockNetName(netlistComponent, int, Netlist)`.
  public static func getClockNetName(
    _ comp: any HdlNetlistComponent, endIndex: Int, netlist: any HdlNetlist
  ) -> String {
    guard let hierarchyLevel = netlist.currentHierarchyLevel, endIndex >= 0,
      endIndex < comp.nrOfEnds
    else { return "" }
    let endData = comp.end(at: endIndex)
    guard endData.nrOfBits == 1 else { return "" }
    let solderPoint = endData.solderPoint(atBit: 0)
    guard let connectedNet = solderPoint.parentNet else { return "" }
    let clockSourceId = netlist.clockSourceId(
      hierarchyLevel: hierarchyLevel, net: connectedNet, bitIndex: solderPoint.parentNetBitIndex)
    guard clockSourceId >= 0 else { return "" }
    return "\(HdlGeneratorNames.clockTreeName)\(clockSourceId)"
  }

  // MARK: - File output

  /// `Hdl.writeEntity(String, List<String>, String)`.
  public static func writeEntity(targetDirectory: String, contents: [String], componentName: String)
    -> Bool
  {
    guard isVhdl() else { return true }
    guard !contents.isEmpty else {
      Reporter.shared.addFatalError(
        "INTERNAL ERROR: Empty entity description received for '\(componentName)'!")
      return false
    }
    guard let outFile = HdlFileWriter.filePointer(
      targetDirectory: targetDirectory, componentName: componentName, isEntity: true)
    else { return false }
    return HdlFileWriter.writeContents(path: outFile, contents: contents)
  }

  /// `Hdl.writeArchitecture(String, List<String>, String)`.
  public static func writeArchitecture(
    targetDirectory: String, contents: [String], componentName: String
  ) -> Bool {
    guard !contents.isEmpty else {
      Reporter.shared.addFatalErrorFmt(
        "INTERNAL ERROR: Empty behavior description for Component '%s' received!", componentName)
      return false
    }
    guard let outFile = HdlFileWriter.filePointer(
      targetDirectory: targetDirectory, componentName: componentName, isEntity: false)
    else { return false }
    return HdlFileWriter.writeContents(path: outFile, contents: contents)
  }

  // MARK: - Net maps

  /// `Hdl.getNetMap(String, boolean, netlistComponent, int, Netlist)`.
  public static func getNetMap(
    sourceName: String, floatingPinTiedToGround: Bool, comp: any HdlNetlistComponent,
    endIndex: Int, netlist: any HdlNetlist
  ) -> [String: String] {
    var netMap: [String: String] = [:]
    guard endIndex >= 0, endIndex < comp.nrOfEnds else {
      Reporter.shared.addFatalError("INTERNAL ERROR: Component tried to index non-existing SolderPoint")
      return netMap
    }
    let connectionInformation = comp.end(at: endIndex)
    let isOutput = connectionInformation.isOutputEnd
    let nrOfBits = connectionInformation.nrOfBits

    if nrOfBits == 1 {
      netMap[sourceName] = getNetName(
        comp, endIndex: endIndex, floatingNetTiedToGround: floatingPinTiedToGround, netlist: netlist)
      return netMap
    }

    var connected = false
    for bit in 0..<nrOfBits {
      if connectionInformation.solderPoint(atBit: bit).parentNet != nil { connected = true }
    }
    guard connected else {
      netMap[sourceName] =
        isOutput
        ? unconnected(empty: true)
        : getZeroVector(nrOfBits: nrOfBits, floatingPinTiedToGround: floatingPinTiedToGround)
      return netMap
    }

    if netlist.isContinuesBus(comp, endIndex: endIndex) {
      netMap[sourceName] = getBusNameContinues(comp, endIndex: endIndex, netlist: netlist) ?? ""
      return netMap
    }

    if isVhdl() {
      for bit in 0..<nrOfBits {
        let key = "\(sourceName)(\(bit)) "
        let solderPoint = connectionInformation.solderPoint(atBit: bit)
        guard let parentNet = solderPoint.parentNet else {
          netMap[key] =
            isOutput
            ? unconnected(empty: false)
            : getZeroVector(nrOfBits: 1, floatingPinTiedToGround: floatingPinTiedToGround)
          continue
        }
        netMap[key] =
          parentNet.bitWidth == 1
          ? "\(netName)\(netlist.netId(for: parentNet))"
          : "\(busName)\(netlist.netId(for: parentNet))(\(solderPoint.parentNetBitIndex))"
      }
    } else {
      var separateSignals: [String] = []
      for bit in 0..<nrOfBits {
        let solderPoint = connectionInformation.solderPoint(atBit: bit)
        guard let parentNet = solderPoint.parentNet else {
          separateSignals.append(
            isOutput ? "1'bZ" : getZeroVector(nrOfBits: 1, floatingPinTiedToGround: floatingPinTiedToGround))
          continue
        }
        separateSignals.append(
          parentNet.bitWidth == 1
            ? "\(netName)\(netlist.netId(for: parentNet))"
            : "\(busName)\(netlist.netId(for: parentNet))[\(solderPoint.parentNetBitIndex)]")
      }
      var vector = "{"
      var bit = nrOfBits
      while bit > 0 {
        vector += separateSignals[bit - 1]
        if bit != 1 { vector += "," }
        bit -= 1
      }
      vector += "}"
      netMap[sourceName] = vector
    }
    return netMap
  }

  /// `Hdl.addAllWiresSorted(LineBuffer, Map<String, String>)`. Java clears the caller's map as
  /// a side effect (it is called with a scratch map that is about to be reused); the `inout`
  /// parameter here reproduces that.
  public static func addAllWiresSorted(_ contents: LineBuffer, wires: inout [String: String]) {
    var maxNameLength = 0
    for wire in wires.keys { maxNameLength = max(maxNameLength, wire.count) }
    for wire in wires.keys.sorted() {
      contents.add(
        "{{assign}}{{1}}{{2}}{{=}}{{3}};", wire, String(repeating: " ", count: maxNameLength - wire.count),
        wires[wire] ?? "")
    }
    wires.removeAll()
  }

  // ── The trailing `"\n"` on both literals is not cosmetic ────────────────────────────────────
  //
  // A Java text block terminates its LAST content line; a Swift multi-line literal does not. So
  // upstream's block ends `…numeric_std.all;\n\n` where the Swift literal ends `…\n`, and every
  // VHDL entity in every component family came out one blank line short between the USE clauses
  // and ENTITY. All four families measured it independently; in the gates family alone it
  // accounted for 443 differing lines.
  //
  // ORDER MATTERS: this must land WITH `LineBuffer.getWithIndent`'s trailing-empty-field fix, not
  // before it. Without that fix the extra newline is preserved as an extra blank line and makes
  // the output worse rather than better: the memory family flagged exactly this dependency.

  public static func getExtendedLibrary() -> [String] {
    let lines = LineBuffer.getBuffer()
    lines.addVhdlKeywords().add(
      """

      {{library}} ieee;
      {{use}} ieee.std_logic_1164.all;
      {{use}} ieee.numeric_std.all;

      """ + "\n")
    return lines.get()
  }

  public static func getStandardLibrary() -> [String] {
    let lines = LineBuffer.getBuffer()
    lines.addVhdlKeywords().add(
      """

      {{library}} ieee;
      {{use}} ieee.std_logic_1164.all;

      """ + "\n")
    return lines.get()
  }
}

/// Java's `String.format("%1X", long)`: a single uppercase hex digit for a value known to be
/// `0...15` (the mask in `getConstantVector` guarantees this).
extension String {
  fileprivate init(format1X value: Int64) {
    self = String(value & 0xF, radix: 16, uppercase: true)
  }
}
