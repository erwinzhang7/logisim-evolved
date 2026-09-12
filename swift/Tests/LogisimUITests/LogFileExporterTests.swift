// LogFileExporterTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The exported log is read by scripts, so its layout is a contract. These tests pin it byte for
// byte against `LogThread.writeSignals` (4.1.0): the `# mode:` line, the tab-separated header,
// the tab-separated value rows, and the trailing `\t# <duration>` comment.

import Foundation
import LogisimKernel
import Testing

@testable import LogisimUI

private func stepModel() -> (LogModel, ManualProbe, ManualProbe) {
  let clk = ManualProbe(name: "clk", width: 1, value: .falseValue)
  let bus = ManualProbe(name: "q", width: 4, value: Value.createKnown(BitWidth.known(4), 0))
  let model = LogModel(signals: [LogSignalInfo(probe: clk), LogSignalInfo(probe: bus)])
  return (model, clk, bus)
}

@Suite("Log file export — LogThread's format, exactly")
struct LogFileExporterTests {

  @Test("The first chunk is the mode line, the header, and one row per interval")
  func firstChunkLayout() throws {
    let (model, clk, bus) = stepModel()
    let exporter = LogFileExporter()

    clk.currentValue = .trueValue
    bus.currentValue = Value.createKnown(BitWidth.known(4), 5)
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)

    let text = exporter.nextChunk(for: model)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()

    #expect(lines[0] == "# mode: step granularity: coarse")
    #expect(lines[1] == "clk\tq[3..0]")
    // Two 5000 ns intervals: the seed and the sample.
    #expect(lines[2] == "0\t0000\t# 5.0 \(LogDurationFormat.microSign)s")
    #expect(lines[3] == "1\t0101\t# 5.0 \(LogDurationFormat.microSign)s")
    #expect(lines.count == 4)
  }

  @Test("The header is omitted when fileHeader is off, but the mode line is not")
  func headerCanBeOmitted() {
    let (model, _, _) = stepModel()
    model.setFileHeader(false)
    let text = LogFileExporter().nextChunk(for: model)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    #expect(lines[0] == "# mode: step granularity: coarse")
    #expect(lines[1].hasPrefix("0\t"))
  }

  @Test("A second pass writes only what is new — no mode line, no header, no repeated rows")
  func incrementalPasses() throws {
    let (model, clk, _) = stepModel()
    let exporter = LogFileExporter()
    _ = exporter.nextChunk(for: model)

    clk.currentValue = .trueValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    let second = exporter.nextChunk(for: model)
    let lines = second.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("1\t"))
  }

  @Test("A mode change re-emits the mode line; a selection change re-emits the header")
  func dirtyFlags() throws {
    let (model, clk, _) = stepModel()
    let exporter = LogFileExporter()
    let token = model.addListener(exporter)
    _ = exporter.nextChunk(for: model)

    exporter.logModeChanged(model)
    clk.currentValue = .trueValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    #expect(exporter.nextChunk(for: model).hasPrefix("# mode:"))

    exporter.logSelectionChanged(model)
    clk.currentValue = .falseValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    #expect(exporter.nextChunk(for: model).hasPrefix("clk\tq[3..0]\n"))
    token.cancel()
  }

  @Test("The radix chosen for a signal is the radix written to the file")
  func radixReachesTheFile() {
    let (model, _, _) = stepModel()
    model.setRadix(.hexadecimal, for: model.rows[1].info)
    let text = LogFileExporter().nextChunk(for: model)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    // Width 4, value 0 in hex is a single "0", not "0000".
    #expect(lines[2] == "0\t0\t# 5.0 \(LogDurationFormat.microSign)s")
  }

  @Test("The row interval is the shortest remaining run across all signals")
  func intervalIsTheMinimum() throws {
    // Give the two signals different run lengths by sampling at different granularities.
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let b = ManualProbe(name: "b", width: 1, value: .falseValue)
    let model = LogModel(signals: [LogSignalInfo(probe: a), LogSignalInfo(probe: b)])
    // `a` toggles every step, `b` stays put, so `b`'s runs coalesce and `a`'s do not.
    for step in 0..<3 {
      a.currentValue = step.isMultiple(of: 2) ? .trueValue : .falseValue
      try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    }
    let text = LogFileExporter().nextChunk(for: model)
    let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast()
      .filter { !$0.hasPrefix("#") && $0.contains("\t#") }
    // Every row must be one timeScale long: `a` changes that often.
    for row in rows {
      #expect(row.hasSuffix("# 5.0 \(LogDurationFormat.microSign)s"))
    }
    #expect(rows.count == 4)
  }

  @Test("Adding a signal mid-run keeps the writer progressing — Java's hang, pinned")
  func lateSignalDoesNotStallTheWriter() throws {
    // Every pass leaves its cursors exhausted, and a signal added mid-run starts at
    // `endTime - 1`, so the cached cursors are both stale and out of step. Java reuses them
    // unconditionally and spins forever; see LogFileExporter's header. If the rebuild is
    // removed this test hangs rather than failing, which is itself the signal.
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let model = LogModel(signals: [LogSignalInfo(probe: a)])
    let exporter = LogFileExporter()
    _ = exporter.nextChunk(for: model)

    model.add([LogSignalInfo(probe: ManualProbe(name: "late", width: 1, value: .trueValue))])
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    exporter.logSelectionChanged(model)

    let text = exporter.nextChunk(for: model)
    #expect(text.count < 100_000)
    // And it must actually make progress, not merely stop.
    #expect(text.contains("\t#"))
  }

  @Test("write() appends to the file and never truncates it")
  func appendsToDisk() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("logisim-log-test-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }

    let (model, clk, _) = stepModel()
    let exporter = LogFileExporter()
    let token = model.addListener(exporter)
    model.setSelected(true)
    model.setFileURL(url)

    clk.currentValue = .trueValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    clk.currentValue = .falseValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    exporter.closeFile()

    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.hasPrefix("# mode: step granularity: coarse\n"))
    #expect(contents.contains("clk\tq[3..0]\n"))
    #expect(exporter.lastError == nil)
    // Three intervals: the seed and two samples.
    let dataRows = contents.split(separator: "\n").filter { $0.contains("\t#") }
    #expect(dataRows.count == 3)
    token.cancel()
  }

  @Test("A write to an unwritable path records the error instead of trapping (D13)")
  func unwritablePathIsReported() throws {
    let url = URL(fileURLWithPath: "/this/path/does/not/exist/log.txt")
    let (model, _, _) = stepModel()
    let exporter = LogFileExporter()
    model.setSelected(true)
    model.setFileURL(url)
    exporter.write(model)
    #expect(exporter.lastError != nil)
  }

  @Test("The table on screen and the file agree, row for row")
  func tableMatchesFile() throws {
    let (model, clk, bus) = stepModel()
    clk.currentValue = .trueValue
    bus.currentValue = Value.createKnown(BitWidth.known(4), 9)
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)

    let fileRows = LogFileExporter().nextChunk(for: model)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.contains("\t#") }
      .map { String($0.split(separator: "\t#")[0]) }

    let tableRows = LogSampleTable.rows(of: model).map { $0.values.joined(separator: "\t") }
    #expect(fileRows == tableRows)
  }
}
