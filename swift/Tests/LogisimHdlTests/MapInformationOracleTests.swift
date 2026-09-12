// MapInformationOracleTests.swift: part of logisim-evolved.
//
// Checks `FpgaMapInformationBindings`, the injected `StdAttr.MAPINFO` answer that
// `Netlist.constructHierarchyTree` counts bubbles from, against the shipped 4.1.0 jar, over the
// harvested corpus.
//
// ── Why this exists separately from the netlist gate ────────────────────────────────────────
//
// The netlist gate compares the bubble *tree*: the walk, the ordering, the local and global id
// assignment. It takes the per-component container as an input. So if the container were wrong,
// the tree would be consistently wrong on both sides of nothing at all; the gate would still be
// comparing the port against the port. This suite closes that: the container is compared against
// the jar's own, label by label.
//
// The oracle is `MAPINFO` lines in `tools/hdlbridge/netlist-4.1.0.oracle`, emitted by
// `NetlistBridge.collectMapInfo` for every circuit including the DRC-failing ones; the container
// is a fact about the std library, not about whether a particular sheet passes DRC, and the
// wider net is where `DotMatrix`, `LedBar`, `PortIO` and `Hex Digit Display` coverage comes from.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdlWiring
import LogisimHdl
import LogisimKernel
import LogisimStd
import Testing

/// `.serialized` for the same reason as the other corpus suites: `HdlGeneratorLookup.shared` and
/// `StdLibraries.registerAll()` are process-wide mutable state and this suite writes both.
@Suite("FPGA map information — the 4.1.0 jar oracle", .serialized)
struct MapInformationOracleTests {

  // An explicit skip, not a silent `return`: a gate that returns early still reports as a
  // PASS, and the corpus is not published, so in a clean clone there is nothing to compare.
  @Test("every component's StdAttr.MAPINFO matches the jar's, label for label",
    .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] != nil,
      "needs LOGISIM_CORPUS: the corpus is coursework and is not in this repository"))
  func mapInformationMatchesTheJar() throws {
    // Held for the whole comparison. Without it this suite passes alone and fails in a full run:
    // the netlist gate's `removeAll()` lands mid-test and every binding vanishes. See
    // `HdlGlobalStateLock.swift`, where that was found and is written down.
    try withHdlGeneratorLookup { try compareEveryContainerToTheJar() }
  }

  private func compareEveryContainerToTheJar() throws {
    // A corpus IS configured, so the operator asked for this gate to run. Data it then cannot
    // find is a miscalibration, not an absence of coursework: `#require` fails here rather than
    // returning a pass over zero comparisons. The intentional-absence case is the trait above.
    let oracleURL = try #require(
      NetlistGateTests.oracleURL(), "LOGISIM_CORPUS is set but the netlist oracle is absent")
    let oracleText = try String(contentsOf: oracleURL, encoding: .utf8)

    StdLibraries.registerAll()
    FpgaMapInformationBindings.install(into: HdlGeneratorLookup.shared)

    var comparedFiles = 0
    var comparedLines = 0
    var missing: [String] = []
    var unexpected: [String] = []

    for entry in OracleEntry.parse(oracleText) {
      let expected = entry.mapInfoLines
      let url = URL(fileURLWithPath: entry.path)
      guard FileManager.default.fileExists(atPath: url.path),
        let loaded = try? Loader().openLogisimFile(url)
      else { continue }
      guard let circuitName = entry.lines.first(where: { $0.hasPrefix("CIRCUIT ") })?
        .dropFirst("CIRCUIT ".count),
        let circuit = loaded.circuits.first(where: { $0.name == String(circuitName) })
      else { continue }

      var actual: Set<String> = []
      for component in circuit.nonWires {
        if let line = NetlistReport.mapInfoLine(for: component) { actual.insert(line) }
      }
      // A file the port cannot load the same way is not evidence about MAPINFO; only compare
      // where at least one side has something to say.
      if expected.isEmpty && actual.isEmpty { continue }
      comparedFiles += 1
      comparedLines += expected.count
      let name = url.lastPathComponent
      for line in expected.subtracting(actual) { missing.append("\(name): jar has   \(line)") }
      for line in actual.subtracting(expected) { unexpected.append("\(name): port has \(line)") }
    }

    // Non-vacuity, in both directions: a binding that answered `nil` for everything, or an oracle
    // with no MAPINFO rows in it, would otherwise report a clean pass.
    #expect(comparedFiles > 0, "no corpus circuit produced a MAPINFO row on either side")
    #expect(comparedLines > 0, "the oracle carries no MAPINFO rows — regenerate it")

    #expect(
      missing.isEmpty,
      """
      \(missing.count) container(s) the jar produces and the port does not:
      \(missing.prefix(8).joined(separator: "\n"))
      """)
    #expect(
      unexpected.isEmpty,
      """
      \(unexpected.count) container(s) the port produces and the jar does not:
      \(unexpected.prefix(8).joined(separator: "\n"))
      """)
  }
}
