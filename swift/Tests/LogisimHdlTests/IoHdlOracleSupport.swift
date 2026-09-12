// IoHdlOracleSupport: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// synthetic `netlistComponent`/`Netlist` shapes that `com/cburch/logisim/std/io/*HdlGeneratorFactory`
// consume. Copyright by the Logisim-evolution developers. This translation is a derivative work
// and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The Swift half of the io HDL gate. It must build *exactly* the same inputs
// `tools/hdlbridge/IoBridge.java` builds on the Java side, one fresh net per component end,
// registered in end order so `getNetId` is the end index, every bit soldered straight through,
// or the two sides would be measuring different things and agreeing by accident.

import Foundation
import LogisimFile
import LogisimHdl
import LogisimKernel

// The lock that used to live here is now `hdlGlobalStateLock` in `HdlGlobalStateLock.swift`.
// It was scoped to the two io suites, which was not enough: Swift Testing parallelises
// suites, so gates/arith/memory raced the io suites on the very same globals. See that
// file for the two failures that came of it.

// MARK: - Synthetic netlist

/// Mirrors `new Net(loc, width)` in the bridge: `isBus()` is `nrOfBits > 1`.
final class OracleNet: HdlNet {
  let bitWidth: Int
  init(bitWidth: Int) { self.bitWidth = bitWidth }
  var isBus: Bool { bitWidth > 1 }
}

struct OracleSolderPoint: HdlSolderPoint {
  var parentNet: (any HdlNet)?
  var parentNetBitIndex: Int
}

final class OracleConnectionEnd: HdlConnectionEnd {
  let nrOfBits: Int
  let isOutputEnd: Bool
  var points: [OracleSolderPoint]

  init(nrOfBits: Int, isOutputEnd: Bool) {
    self.nrOfBits = nrOfBits
    self.isOutputEnd = isOutputEnd
    self.points = (0..<max(0, nrOfBits)).map { _ in
      OracleSolderPoint(parentNet: nil, parentNetBitIndex: -1)
    }
  }

  func solderPoint(atBit bit: Int) -> any HdlSolderPoint {
    guard bit >= 0, bit < points.count else {
      return OracleSolderPoint(parentNet: nil, parentNetBitIndex: -1)
    }
    return points[bit]
  }
}

final class OracleNetlist: HdlNetlist {
  private(set) var nets: [OracleNet] = []

  func register(_ net: OracleNet) -> OracleNet {
    nets.append(net)
    return net
  }

  /// `Netlist.getNetId(Net)` is `myNets.indexOf(net)`.
  func netId(for net: any HdlNet) -> Int {
    nets.firstIndex { $0 === (net as AnyObject) } ?? -1
  }

  /// `Netlist.isContinuesBus`, transcribed.
  func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool {
    guard endIndex >= 0, endIndex < component.nrOfEnds else { return true }
    let end = component.end(at: endIndex)
    let nrOfBits = end.nrOfBits
    if nrOfBits == 1 { return true }
    var continuesBus = true
    let connectedNet = end.solderPoint(atBit: 0).parentNet
    var connectedNetIndex = end.solderPoint(atBit: 0).parentNetBitIndex
    var bit = 1
    while bit < nrOfBits && continuesBus {
      let point = end.solderPoint(atBit: bit)
      if !((connectedNet as AnyObject?) === (point.parentNet as AnyObject?)) { continuesBus = false }
      if connectedNetIndex + 1 != point.parentNetBitIndex {
        continuesBus = false
      } else {
        connectedNetIndex += 1
      }
      bit += 1
    }
    return continuesBus
  }

  var currentHierarchyLevel: [String]? { nil }
  func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  var circuitName: String { "oracleCircuit" }
  var projName: String { "oracleProject" }
  var requiresGlobalClockConnection: Bool { false }
}

final class OracleNetlistComponent: HdlNetlistComponent, HdlLocalBubbleInformation {
  private var ends: [OracleConnectionEnd]
  let attributeSet: any AttributeSet
  let hdlName: String
  let displayName: String
  var isGatedInstance: Bool { false }

  var localBubbleInputStartId = 0
  var localBubbleInputEndId = 0
  var localBubbleOutputStartId = 0
  var localBubbleOutputEndId = 0
  var localBubbleInOutStartId = 0
  var localBubbleInOutEndId = 0

  /// `new netlistComponent(Component)`: one `ConnectionEnd` per component end, taking its
  /// width and direction from the placed component.
  init(component: any Component) {
    ends = component.ends.map {
      OracleConnectionEnd(nrOfBits: Int($0.width.width), isOutputEnd: $0.isOutput)
    }
    attributeSet = component.attributeSet
    hdlName = component.factory.name
    displayName = component.factory.displayName
  }

  var nrOfEnds: Int { ends.count }

  func end(at index: Int) -> any HdlConnectionEnd {
    guard index >= 0, index < ends.count else {
      return OracleConnectionEnd(nrOfBits: 0, isOutputEnd: false)
    }
    return ends[index]
  }

  func isEndConnected(_ index: Int) -> Bool {
    guard index >= 0, index < ends.count else { return false }
    let end = ends[index]
    for bit in 0..<end.nrOfBits where end.points[bit].parentNet != nil { return true }
    return false
  }

  /// `IoBridge.connectEnd`: one fresh net of the end's own width, bit `b` to net bit `b`.
  func connectEnd(_ index: Int, in netlist: OracleNetlist) {
    guard index >= 0, index < ends.count else { return }
    let end = ends[index]
    let net = netlist.register(OracleNet(bitWidth: end.nrOfBits))
    for bit in 0..<end.nrOfBits {
      end.points[bit] = OracleSolderPoint(parentNet: net, parentNetBitIndex: bit)
    }
  }

  /// `IoBridge.connectAll`.
  func connectAll(in netlist: OracleNetlist) {
    for index in 0..<ends.count { connectEnd(index, in: netlist) }
  }

  /// `netlistComponent.setLocalBubbleID`.
  func setLocalBubbleId(
    inputStart: Int, nrOfInput: Int, outputStart: Int, nrOfOutput: Int, inOutStart: Int,
    nrOfInOut: Int
  ) {
    if nrOfInput > 0 {
      localBubbleInputStartId = inputStart
      localBubbleInputEndId = inputStart + nrOfInput - 1
    }
    if nrOfInOut > 0 {
      localBubbleInOutStartId = inOutStart
      localBubbleInOutEndId = inOutStart + nrOfInOut - 1
    }
    if nrOfOutput > 0 {
      localBubbleOutputStartId = outputStart
      localBubbleOutputEndId = outputStart + nrOfOutput - 1
    }
  }
}

// MARK: - Oracle file parsing

/// One `CASE <name> <language>` block from `tools/hdlbridge/io-4.1.0.oracle`.
struct IoOracleCase {
  let name: String
  let language: String
  let body: [String]

  var key: String { "\(name)\t\(language)" }
}

enum IoOracle {
  /// The committed oracle, located relative to this source file so the test needs no
  /// environment variable and no corpus.
  static func load() throws -> [String: [String]] {
    let here = URL(fileURLWithPath: #filePath)
    let repoRoot = here
      .deletingLastPathComponent()  // .../swift/Tests/LogisimHdlTests
      .deletingLastPathComponent()  // .../swift/Tests
      .deletingLastPathComponent()  // .../swift
      .deletingLastPathComponent()  // repository root
    let path = repoRoot.appendingPathComponent("tools/hdlbridge/io-4.1.0.oracle")
    let text = try String(contentsOf: path, encoding: .utf8)

    var cases: [String: [String]] = [:]
    var currentKey: String?
    var currentBody: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let raw = String(line)
      if raw.hasPrefix("CASE\t") {
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        currentKey = "\(parts[1])\t\(parts[2])"
        currentBody = []
      } else if raw == "ENDCASE" {
        if let key = currentKey { cases[key] = currentBody }
        currentKey = nil
      } else if currentKey != nil {
        // Kept VERBATIM, including the bridge's two-space prefix. Stripping it would be wrong:
        // `body()` prefixes only the first physical line of a multi-line element, and several
        // continuation lines (e.g. ReptarLocalBus's `  IOBUF_Addresse_Data : IOBUF`) genuinely
        // begin with two spaces of their own. The Swift side renders the same way instead,
        // see `IoOracle.render`.
        currentBody.append(raw)
      }
    }
    return cases
  }

  /// The bridge's `body(List<String>)`: each element printed as `"  " + element`, so a
  /// multi-line element yields one prefixed line followed by verbatim continuation lines.
  static func render(_ lines: [String]) -> [String] {
    var out: [String] = []
    for element in lines {
      let physical = ("  " + element).split(separator: "\n", omittingEmptySubsequences: false)
      out.append(contentsOf: physical.map(String.init))
    }
    return out
  }
}
