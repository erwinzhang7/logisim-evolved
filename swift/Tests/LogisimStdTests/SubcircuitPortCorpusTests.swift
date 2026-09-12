// SubcircuitPortCorpusTests.swift: part of logisim-evolved.
//
// `computePorts` over the whole harvested corpus, at load time.
//
// ── Why this exists next to the hand-built suite ────────────────────────────────────────────
//
// `SubcircuitPortsTests` proves the arithmetic on circuits it builds itself. It cannot prove the
// thing that actually went wrong for a milestone: that *real files* reach `computePorts` with the
// inputs it expects. Three of the four appearance styles only occur in the wild,
//
//     classic 146   custom 222   evolution (APPEAR_FPGA) 13   logisim_evolution 405
//
// , and the `custom` ones exercise the `<appear>` parse against 222 hand-drawn symbols that no
// synthetic fixture would reproduce. A circuit whose ports silently came back empty would still
// load, still save byte-identically, and still pass every round-trip test; the only symptom is
// `UUUU` in a simulation, one gate run and several minutes away from the cause.
//
// So the invariant asserted here is the cheap, total one: **no subcircuit placement anywhere in
// the corpus is portless, and every placement has exactly one port per pin in the circuit it
// instantiates.** It is not a claim that the ports are in the right *places*, the sibling suite
// and the `-tty table` gate cover that, it is a claim that none were lost.
//
// Skips itself when `LOGISIM_CORPUS` is unset, like every other corpus-backed suite (the corpus
// is private coursework and lives outside the repo; see docs/decisions.md).
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("Subcircuit ports — the harvested corpus")
struct SubcircuitPortCorpusTests {

  /// One placement that did not get the ports it should have.
  private struct Finding: CustomStringConvertible {
    let file: String
    let parent: String
    let child: String
    let style: String
    let pins: Int
    let ends: Int

    var description: String {
      "\(file) :: \(parent) instantiates \(child) [\(style)] — \(pins) pins, \(ends) ends"
    }
  }

  // An explicit skip, not a silent `return`: a gate that returns early still reports as a
  // PASS, and the corpus is not published, so in a clean clone there is nothing to compare.
  @Test("no subcircuit placement in the corpus is portless",
    .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] != nil,
      "needs LOGISIM_CORPUS: the corpus is coursework and is not in this repository"))
  func everyPlacementHasOnePortPerPin() throws {
    // A corpus IS configured, so the operator asked for this gate to run. Data it then cannot
    // find is a miscalibration, not an absence of coursework: `#require` fails here rather than
    // returning a pass over zero comparisons. The intentional-absence case is the trait above.
    let root = try #require(ProcessInfo.processInfo.environment["LOGISIM_CORPUS"])
    let harvested = URL(fileURLWithPath: root).appendingPathComponent("harvested")
    let files =
      ((try? FileManager.default.contentsOfDirectory(
        at: harvested, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path }
    #expect(!files.isEmpty, "LOGISIM_CORPUS is set but \(harvested.path) holds no .circ files")
    if files.isEmpty { return }

    var placements = 0
    var findings: [Finding] = []

    for file in files {
      // A file the loader rejects is not this suite's business; the round-trip and `-tty table`
      // gates own load failures and would double-count them here.
      guard let loaded = try? Loader().openLogisimFile(file) else { continue }
      for parent in loaded.circuits {
        for component in parent.nonWires {
          guard let factory = component.factory as? CircuitSubcircuitFactory,
            let placement = component as? InstanceComponent,
            let child = factory.subcircuit as? Circuit
          else { continue }
          placements += 1

          let pins = child.nonWires.filter(\.factory.isPin).count
          guard placement.ends.count != pins else { continue }
          findings.append(
            Finding(
              file: file.lastPathComponent,
              parent: parent.name,
              child: child.name,
              style: child.staticAttributes[CircuitAttributes.appearance]?.name ?? "(absent)",
              pins: pins,
              ends: placement.ends.count))
        }
      }
    }

    // The corpus is the fixture, so a run that found no placements at all is a broken fixture,
    // not a pass. Measured at the time of writing: 786.
    #expect(placements > 500, "expected the corpus to contain hundreds of subcircuit placements")

    #expect(
      findings.isEmpty,
      """
      \(findings.count) of \(placements) subcircuit placements did not get one port per pin:
      \(findings.prefix(20).map(\.description).joined(separator: "\n"))
      """)
  }
}
