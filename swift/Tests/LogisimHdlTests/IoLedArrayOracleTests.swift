// IoLedArrayOracleTests: part of logisim-evolved.
//
// The differential gate for the board-level LED-array and scanning seven-segment drivers in
// `std/io`, against `tools/hdlbridge/io-4.1.0.oracle`. Same protocol and the same case names as
// `IoBridge.java`'s `ledArrayCases()` / `sevenSegmentScanningCases()`.
//
// GPL-3.0-only; see LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdl
import LogisimKernel
import Testing

/// Cases the port deliberately does not generate, with the reason. Each is asserted below to be
/// exactly what it claims; the point is a documented gap, not a silent one.
private enum LedArrayNotGenerated {
  /// `RgbArrayRowScanning.getModuleFunctionality()` uses `{{insR}}`/`{{outsR}}` and friends in
  /// *both* language branches without ever installing those pairs, the class's `sharedPairs`
  /// field is never applied, so upstream's `LineBuffer.abort` throws for VHDL and for Verilog
  /// alike. The port reproduces the same missing pairs, so calling it would hit `LineBuffer`'s
  /// Swift `preconditionFailure` and kill the test process rather than record a failure. It is
  /// therefore not called; `upstreamThrowsForRgbRowScanningArchitecture` asserts that the oracle
  /// records a throw in both languages, which is the whole of the behaviour being skipped.
  static let keys: Set<String> = [
    "LedArray/RgbRowScanning/architecture\tVHDL",
    "LedArray/RgbRowScanning/architecture\tVerilog",
  ]
}

private final class LedArrayRecorder {
  private(set) var produced: [String: [String]] = [:]
  private(set) var order: [String] = []

  func record(_ name: String, _ lines: [String]) {
    let key = "\(name)\t\(HdlSettings.language == .vhdl ? "VHDL" : "Verilog")"
    produced[key] = IoOracle.render(lines)
    order.append(key)
  }

  func recordText(_ name: String, _ line: String) { record(name, [line]) }
}

@Suite("std/io board-level LED-array drivers vs. the 4.1.0 jar", .serialized)
struct IoLedArrayOracleTests {

  private static let modes: [LedArrayDrivingMode] = [
    .ledDefault, .ledRowScanning, .ledColumnScanning, .rgbDefault, .rgbRowScanning,
    .rgbColumnScanning,
  ]
  private static let shapes = [(1, 1), (2, 3), (4, 8), (8, 16)]
  private static let bitCountProbes = [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 1000, 50000]

  @Test("every LED-array driver case is byte-identical to upstream, VHDL and Verilog")
  func matchesOracle() throws {
    hdlGlobalStateLock.lock()
    defer { hdlGlobalStateLock.unlock() }

    let oracle = try IoOracle.load()
    #expect(oracle.count > 0, "the oracle file parsed to zero cases — the gate is not measuring")

    let recorder = LedArrayRecorder()
    let savedLanguage = HdlSettings.language
    let savedName = HdlBuildInfo.name
    let savedUrl = HdlBuildInfo.url
    HdlBuildInfo.name = "Logisim-evolution"
    HdlBuildInfo.url = "https://github.com/logisim-evolution/"
    defer {
      HdlSettings.language = savedLanguage
      HdlBuildInfo.name = savedName
      HdlBuildInfo.url = savedUrl
    }

    for language in [HdlLanguage.vhdl, HdlLanguage.verilog] {
      HdlSettings.language = language
      emitLedArrayCases(recorder)
      emitSevenSegmentScanningCases(recorder)
    }

    #expect(recorder.produced.count > 0, "the Swift side produced zero cases")

    var missing: [String] = []
    var mismatched: [String] = []
    var firstDiff = ""
    for key in recorder.order {
      guard let expected = oracle[key] else {
        missing.append(key)
        continue
      }
      // Plain equality, no allowances. Two compensations used to live here and both are gone
      // because the framework defects they stood in for were fixed: `Hdl.getExtendedLibrary()`
      // now ends with the newline Java's text block appends (so the seven `/entity VHDL` cases
      // need no repaired blank line), and `LineBuffer.getWithIndent` now splits with `javaSplit`
      // (so the twelve `/architecture` cases carry no extra trailing blank line). Both were
      // verified fixed by this gate failing on its own pins first.
      let actual = recorder.produced[key] ?? []
      if actual != expected {
        mismatched.append(key)
        if firstDiff.isEmpty {
          firstDiff = """
            first mismatch: \(key)
            --- upstream (\(expected.count) lines)
            \(expected.joined(separator: "\n"))
            --- port (\(actual.count) lines)
            \(actual.joined(separator: "\n"))
            """
        }
      }
    }

    #expect(
      missing.isEmpty,
      "case names not present in the oracle (a typo makes a case silently untested): \(missing)")
    #expect(
      recorder.order.count == 582,
      "this suite now generates \(recorder.order.count) cases, not 582 — update the count and the report")
    // The two suites together must cover every case the bridge emitted, minus the two upstream
    // throws. A gate that quietly stops driving a case looks exactly like a passing one.
    #expect(oracle.count == 706, "the oracle file now has \(oracle.count) cases, not 706")
    #expect(
      mismatched.isEmpty,
      "\(mismatched.count) of \(recorder.order.count) cases differ from the 4.1.0 jar.\n\(firstDiff)"
    )
  }

  /// Was a *characterisation* test: it asserted `["a", "b", ""]`, pinning the defect that
  /// `getWithIndent` split with `omittingEmptySubsequences: false` and so kept a trailing empty
  /// field Java's `String.split("\n")` discards. Every architecture case in this family gained
  /// one blank line per generator body from it, and 12 of them were measured with an allowance
  /// instead of plain equality.
  ///
  /// `getWithIndent` now goes through `javaSplit`, so the same test asserts Java's behaviour.
  /// Kept rather than deleted for two reasons: it is the only coverage of the `applyMap: false`
  /// path through the buffer, and a re-introduction of the defect should fail *here*, naming the
  /// cause, rather than 12 architecture cases away.
  @Test("LineBuffer.getWithIndent drops the trailing empty field, as Java's split does")
  func getWithIndentDropsTheTrailingEmptyFieldJavaDrops() {
    let buffer = LineBuffer.getBuffer()
    buffer.add("a\nb\n", applyMap: false)
    // Observed JVM output: "a\nb\n".split("\n") -> len=2 ["a" "b"]. See JavaSplitSemanticsTests.
    #expect(buffer.getWithIndent("") == ["a", "b"])

    // The companion case, and the one the first attempt at this fix got wrong: an empty element
    // must survive, because Java returns [""] when the pattern never matches.
    let empty = LineBuffer.getBuffer()
    empty.add("a", applyMap: false).empty().add("b", applyMap: false)
    #expect(empty.getWithIndent("") == ["a", "", "b"])
  }

  /// Pins the one case the gate deliberately does not generate. See `LedArrayNotGenerated`.
  @Test("upstream itself throws for RgbArrayRowScanning's architecture, in both languages")
  func upstreamThrowsForRgbRowScanningArchitecture() throws {
    let oracle = try IoOracle.load()
    for key in LedArrayNotGenerated.keys.sorted() {
      let recorded = try #require(oracle[key])
      #expect(recorded.count == 1)
      let line = recorded[0]
      #expect(
        line.contains("<throws java.lang.RuntimeException: #E006: No mapping for"),
        "the oracle no longer records a throw for \(key): \(line)")
    }
  }

  // MARK: - cases, mirroring IoBridge.ledArrayCases()

  private func emitLedArrayCases(_ recorder: LedArrayRecorder) {
    let netlist = OracleNetlist()
    let attrs = AttributeSets.empty
    for mode in Self.modes {
      let generator = LedArrayGenericHdlGeneratorFactory.specificHdlGenerator(mode)
      let name = LedArrayGenericHdlGeneratorFactory.specificHdlName(mode)
      recorder.recordText("LedArray/\(mode.token)/name", name)
      recorder.record(
        "LedArray/\(mode.token)/entity",
        generator.getEntity(netlist: netlist, attrs: attrs, componentName: name))
      let architectureKey =
        "LedArray/\(mode.token)/architecture\t\(HdlSettings.language == .vhdl ? "VHDL" : "Verilog")"
      if !LedArrayNotGenerated.keys.contains(architectureKey) {
        recorder.record(
          "LedArray/\(mode.token)/architecture",
          generator.getArchitecture(netlist: netlist, attrs: attrs, componentName: name) ?? [])
      }
      recorder.record(
        "LedArray/\(mode.token)/instantiation",
        generator.getComponentInstantiation(
          netlist: netlist, attrs: attrs, componentName: name
        ).get())
    }
    for (rows, cols) in Self.shapes {
      for activeLow in [false, true] {
        for mode in Self.modes {
          let tag = "\(mode.token)/rows=\(rows)/cols=\(cols)/activeLow=\(activeLow)"
          recorder.record(
            "LedArray/\(tag)/componentMap",
            LedArrayGenericHdlGeneratorFactory.componentMap(
              mode, nrOfRows: rows, nrOfColumns: cols, identifier: 7,
              fpgaClockFrequency: 50_000_000, isActiveLow: activeLow))
          recorder.record(
            "LedArray/\(tag)/externals",
            LedArrayGenericHdlGeneratorFactory.externalSignals(
              mode, nrOfRows: rows, nrOfColumns: cols, identifier: 7
            ).map { "\($0.name) = \($0.bits)" })
          recorder.record(
            "LedArray/\(tag)/internals",
            LedArrayGenericHdlGeneratorFactory.internalSignals(
              mode, nrOfRows: rows, nrOfColumns: cols, identifier: 7
            ).map { "\($0.name) = \($0.bits)" })
          recorder.record(
            "LedArray/\(tag)/pinNames",
            (0..<24).map { pin in
              "\(pin) -> "
                + LedArrayGenericHdlGeneratorFactory.externalSignalName(
                  mode, nrOfRows: rows, nrOfColumns: cols, identifier: 7, pinNr: pin)
            })
          recorder.recordText(
            "LedArray/\(tag)/requiresClock",
            String(LedArrayGenericHdlGeneratorFactory.requiresClock(mode)))
        }
      }
    }
    for value in Self.bitCountProbes {
      recorder.recordText(
        "LedArray/nrOfBitsRequired/\(value)",
        String(LedArrayGenericHdlGeneratorFactory.nrOfBitsRequired(value)))
    }
  }

  // MARK: - cases, mirroring IoBridge.sevenSegmentScanningCases()

  private func emitSevenSegmentScanningCases(_ recorder: LedArrayRecorder) {
    let netlist = OracleNetlist()
    let attrs = AttributeSets.empty
    let generator = SevenSegmentScanningDecodedHdlGeneratorFactory()
    let name = SevenSegmentScanningDecodedHdlGeneratorFactory.hdlIdentifier
    recorder.record(
      "SevenSegmentScanningDecoded/entity",
      generator.getEntity(netlist: netlist, attrs: attrs, componentName: name))
    recorder.record(
      "SevenSegmentScanningDecoded/architecture",
      generator.getArchitecture(netlist: netlist, attrs: attrs, componentName: name) ?? [])
    recorder.record(
      "SevenSegmentScanningDecoded/instantiation",
      generator.getComponentInstantiation(netlist: netlist, attrs: attrs, componentName: name)
        .get())
    for (rows, cols) in [(1, 1), (2, 3), (4, 8)] {
      for activeLow in [false, true] {
        recorder.record(
          "SevenSegmentScanningDecoded/genericMap/rows=\(rows)/cols=\(cols)/activeLow=\(activeLow)",
          SevenSegmentScanningDecodedHdlGeneratorFactory.genericMap(
            nrOfRows: rows, nrOfColumns: cols, fpgaClockFrequency: 50_000_000,
            activeLow: activeLow, selectActiveLow: false
          ).get())
      }
      recorder.recordText(
        "SevenSegmentScanningDecoded/nrOfControlBits/\(rows),\(cols)",
        String(
          SevenSegmentScanningDecodedHdlGeneratorFactory.nrOfControlBits(
            nrOfDigits: rows, nrOfDecodedBits: cols)))
    }
    recorder.record(
      "SevenSegmentScanningDecoded/portMap",
      SevenSegmentScanningDecodedHdlGeneratorFactory.portMap(identifier: 3).get())
  }
}
