// NetlistReport.swift: part of logisim-evolved.
//
// The Swift half of the netlist gate: renders a `Netlist` in exactly the line protocol
// `tools/hdlbridge/NetlistBridge.java` prints for the shipped 4.1.0 jar, so the two can be
// compared byte for byte.
//
// Kept in the test target rather than in `LogisimHdl` because it is a *measuring instrument*,
// not a product feature: nothing in the app renders a netlist as text, and putting it in the
// module would create a public API whose only caller is a test.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdlWiring
import LogisimHdl
import LogisimKernel

enum NetlistReport {

  /// Renders `netlist` the way `NetlistBridge.report` does. `drcStatus` is the value
  /// `designRuleCheckResult` returned.
  static func render(_ netlist: Netlist, drcStatus: NetlistDrcStatus) -> [String] {
    var lines: [String] = []
    lines.append("CIRCUIT \(netlist.circuit.name)")
    lines.append("DRC \(drcStatus.rawValue)")
    guard drcStatus == .passed else { return lines }

    lines.append(
      "NETS \(netlist.nets.count) single=\(netlist.numberOfNets) bus=\(netlist.numberOfBusses)")
    for (index, net) in netlist.nets.enumerated() {
      let points = net.points.map { "\($0.x),\($0.y)" }.sorted()
      lines.append(
        "NET \(index) width=\(net.bitWidth) bus=\(net.isBus ? 1 : 0) "
          + "root=\(net.isRootNet ? 1 : 0) forced=\(net.isForcedRootNet ? 1 : 0) "
          + "points=\(points.joined(separator: ";"))")
    }
    lines.append("CLOCKTREES \(netlist.numberOfClockTrees)")
    for (index, port) in netlist.inputPorts.enumerated() {
      lines.append(contentsOf: ends(of: port, kind: "INPORT", index: index, netlist: netlist))
    }
    for (index, port) in netlist.outputPorts.enumerated() {
      lines.append(contentsOf: ends(of: port, kind: "OUTPORT", index: index, netlist: netlist))
    }
    for (index, sub) in netlist.subCircuits.enumerated() {
      lines.append(contentsOf: ends(of: sub, kind: "SUBCIRC", index: index, netlist: netlist))
    }
    for (index, comp) in netlist.normalComponents.enumerated() {
      lines.append(contentsOf: ends(of: comp, kind: "COMP", index: index, netlist: netlist))
    }
    lines.append(contentsOf: bubbleTree(of: netlist, names: []))
    return lines
  }

  /// Mirrors `NetlistBridge.dumpBubbleTree`: subcircuits first, in `subCircuits` order, then the
  /// map-carrying entries of `normalComponents`.
  private static func bubbleTree(of netlist: Netlist, names: [String]) -> [String] {
    var lines = [
      "BUBBLES \(path(names)) in=\(netlist.numberOfInputBubbles) "
        + "out=\(netlist.numberOfOutputBubbles) io=\(netlist.numberOfInOutBubbles)"
    ]
    for comp in netlist.subCircuits {
      let sub = names + [hierarchyName(of: comp)]
      lines.append(
        "BUB SUB \(path(sub)) \(comp.component.factory.name) "
          + "local=\(localRange(comp)) global=\(globalRange(comp, sub))")
      guard let subNetlist = netlist.subNetlist(of: comp.component) else { continue }
      lines.append(contentsOf: bubbleTree(of: subNetlist, names: sub))
    }
    for comp in netlist.normalComponents {
      guard let map = comp.mapInformation else { continue }
      let sub = names + [hierarchyName(of: comp)]
      lines.append(
        "BUB COMP \(path(sub)) \(comp.component.factory.name) "
          + "n=\(map.numberOfInputBubbles),\(map.numberOfOutputBubbles),"
          + "\(map.numberOfInOutBubbles) "
          + "local=\(localRange(comp)) global=\(globalRange(comp, sub))")
    }
    return lines
  }

  /// `NetlistBridge.hierarchyName`: `CorrectLabel.getCorrectLabel(label)`, with the empty label
  /// shown as `-` so a missing segment is visible rather than collapsing the path.
  private static func hierarchyName(of comp: NetlistComponent) -> String {
    let corrected = CorrectLabel.correctLabel(
      comp.component.attributeSet.getValue(StdAttr.label) ?? "")
    return corrected.isEmpty ? "-" : corrected
  }

  private static func path(_ names: [String]) -> String {
    names.isEmpty ? "/" : names.joined(separator: "/")
  }

  private static func localRange(_ comp: NetlistComponent) -> String {
    "\(comp.localBubbleInputStartId)..\(comp.localBubbleInputEndId),"
      + "\(comp.localBubbleOutputStartId)..\(comp.localBubbleOutputEndId),"
      + "\(comp.localBubbleInOutStartId)..\(comp.localBubbleInOutEndId)"
  }

  private static func globalRange(_ comp: NetlistComponent, _ names: [String]) -> String {
    guard let info = comp.globalBubbleId(hierarchyName: names) else { return "-" }
    return "\(info.inputStartIndex)..\(info.inputEndIndex),"
      + "\(info.outputStartIndex)..\(info.outputEndIndex),"
      + "\(info.inOutStartIndex)..\(info.inOutEndIndex)"
  }

  /// Renders one component's `MAPINFO` line the way `NetlistBridge.collectMapInfo` does, or
  /// `nil` when the component declares no container.
  static func mapInfoLine(for component: any Component) -> String? {
    guard HdlGeneratorLookup.shared.declaresMapInformation(component),
      let map = HdlGeneratorLookup.shared.mapInformation(for: component)
    else { return nil }
    func labels(_ count: Int, _ label: (Int) -> String) -> String {
      (0..<count).map(label).joined(separator: "|")
    }
    return "MAPINFO \(component.factory.name) "
      + "n=\(map.numberOfInputBubbles),\(map.numberOfOutputBubbles),\(map.numberOfInOutBubbles) "
      + "in=\(labels(map.numberOfInputBubbles, map.inputPortLabel)) "
      + "out=\(labels(map.numberOfOutputBubbles, map.outputPortLabel)) "
      + "io=\(labels(map.numberOfInOutBubbles, map.inOutPortLabel))"
  }

  private static func ends(
    of comp: NetlistComponent, kind: String, index: Int, netlist: Netlist
  ) -> [String] {
    let raw = comp.component.attributeSet.getValue(StdAttr.label) ?? ""
    let label = raw.isEmpty ? "-" : raw
    // The FACTORY name, matching NetlistBridge: `hdlName` is overridden by the per-component HDL
    // generators, and those are not ported yet.
    var lines = [
      "\(kind) \(index) \(comp.component.factory.name) \(label) ends=\(comp.nrOfEndsValue)"
    ]
    for e in 0..<comp.nrOfEndsValue {
      guard let end = comp.connectionEnd(at: e) else { continue }
      var text =
        "  END \(e) out=\(end.isOutput ? 1 : 0) bits=\(end.nrOfBitsValue) "
        + "cont=\(netlist.isContinuesBus(comp, endIndex: e) ? 1 : 0) ->"
      for b in 0..<end.nrOfBitsValue {
        if let point = end.connection(at: b), let net = point.net {
          text += " \(netlist.netId(of: net)):\(point.netBitIndex)"
        } else {
          text += " -"
        }
      }
      lines.append(text)
    }
    return lines
  }
}

/// Normalises the one thing in a report that is legitimately random on **both** sides.
///
/// `XmlReader.ensureLogisimCompatibility` repairs a label that is not a valid VHDL identifier by
/// appending `UUID.randomUUID().toString().substring(0, 8)`: upstream's own behaviour, ported
/// verbatim in `XmlReader.swift` (see `labelSuffixProvider` there). "A xor B" becomes
/// `A_xor_B_177d2f0c` in the jar and `A_xor_B_32157aa3` here, and neither is reproducible from
/// one run to the next even within the same implementation. So an 8-hex-digit trailing group is
/// folded to a fixed marker before comparing. Nothing else about the label is touched, and a
/// label that genuinely ends in eight hex digits normalises identically on both sides.
///
/// **The delimiter set is wider than "space or end of line", and has to be.** The map-component
/// gate embeds the same repaired label inside larger tokens, `hdl=An_1_1861a131_0`,
/// `disp=/An_1_1861a131#0`, `sig=s_L_t0_Value_99bcc28f(0)`, where the suffix is followed by
/// `_`, `#` or `(`. Widening costs discrimination only for a *real* label ending in eight
/// lowercase hex digits, and even then it folds identically on both sides, so no comparison can
/// silently pass because of it.
private let randomLabelSuffixDelimiters: Set<Character> = [" ", "_", "#", "(", "[", ",", "/"]

func normalizeRandomLabelSuffix(_ line: String) -> String {
  guard line.count > 9 else { return line }
  let characters = Array(line)
  var index = characters.count - 1
  // The label is the third space-separated field, so the suffix can only be mid-line; walk every
  // "_" + 8 hex run.
  var out = ""
  var pending: [Character] = []
  index = 0
  while index < characters.count {
    if characters[index] == "_", index + 8 < characters.count,
      (1...8).allSatisfy({ characters[index + $0].isHexDigit && !characters[index + $0].isUppercase
      }),
      index + 9 == characters.count
        || randomLabelSuffixDelimiters.contains(characters[index + 9])
    {
      out += String(pending) + "_XXXXXXXX"
      pending = []
      index += 9
    } else {
      pending.append(characters[index])
      index += 1
    }
  }
  return out + String(pending)
}

/// One `BEGIN`/`END` block of the oracle file.
struct OracleEntry {
  let path: String
  let lines: [String]

  /// The `SYNTH <factory> <0|1>` lines: which factories the jar has an HDL generator for.
  var synthesizableFactories: Set<String> {
    var result: Set<String> = []
    for line in lines where line.hasPrefix("SYNTH ") && line.hasSuffix(" 1") {
      let body = line.dropFirst("SYNTH ".count).dropLast(2)
      result.insert(String(body))
    }
    return result
  }

  /// The `SUPP <factory> <0|1>` lines: `isHDLSupportedComponent`, a different question from the
  /// one above, see `HdlGeneratorLookup.upstreamSupportedFactoryNames`.
  var supportedFactories: Set<String> {
    var result: Set<String> = []
    for line in lines where line.hasPrefix("SUPP ") && line.hasSuffix(" 1") {
      result.insert(String(line.dropFirst("SUPP ".count).dropLast(2)))
    }
    return result
  }

  /// The `MAPINFO <factory> n=… in=… out=… io=…` lines: what `StdAttr.MAPINFO` holds for every
  /// map-carrying component in the file, deduplicated by the bridge exactly as it is here.
  ///
  /// Data, not report, but data of a different kind from `SYNTH`. `SYNTH` is *fed into* the
  /// port, because the port has no generators to answer with. These are *compared against* what
  /// `FpgaMapInformationBindings` computes, because that binding is real code and this is the
  /// only thing that can show it right. Feeding them in instead would turn the gate into a
  /// mirror.
  var mapInfoLines: Set<String> {
    Set(lines.filter { $0.hasPrefix("MAPINFO ") })
  }

  /// The `MAPPABLE` / `MAP` / `MAPPIN` block: the real `MapComponent`, built inside the jar for
  /// every mappable resource. Compared by `MapComponentGateTests`, which owns
  /// `FpgaMapComponent`; `NetlistReport.render` deliberately does not produce these, so they are
  /// excluded from `reportLines` below.
  var mapComponentLines: [String] {
    lines.filter(OracleEntry.isMapComponentLine)
  }

  /// One predicate, used by both the filter and the selector above. Two copies of "which lines
  /// belong to the map block" is precisely the seam shape this project keeps finding.
  static func isMapComponentLine(_ line: String) -> Bool {
    line.hasPrefix("MAPPABLE ") || line.hasPrefix("MAP ") || line.hasPrefix("  MAPPIN ")
  }

  /// The report proper: everything except the `SYNTH`/`SUPP`/`MAPINFO` and map blocks, which
  /// are data for a different comparison rather than part of this one.
  var reportLines: [String] {
    lines.filter {
      !$0.hasPrefix("SYNTH ") && !$0.hasPrefix("SUPP ") && !$0.hasPrefix("MAPINFO ")
        && !OracleEntry.isMapComponentLine($0)
    }
  }

  /// Splits the oracle produced by `NetlistBridge` into per-file blocks, dropping `FAIL`s.
  static func parse(_ text: String) -> [OracleEntry] {
    var entries: [OracleEntry] = []
    var current: (path: String, lines: [String])?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let raw = String(line)
      if raw.hasPrefix("BEGIN\t") {
        current = (String(raw.dropFirst("BEGIN\t".count)), [])
      } else if raw.hasPrefix("END\t") {
        if let done = current { entries.append(OracleEntry(path: done.path, lines: done.lines)) }
        current = nil
      } else if current != nil, !raw.isEmpty {
        current?.lines.append(raw)
      }
    }
    return entries
  }
}
