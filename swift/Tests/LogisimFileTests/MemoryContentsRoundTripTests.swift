// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

/// Exercises the real CLI load/save path because the memory codec lives in LogisimStd, while
/// Package.swift intentionally keeps this test target below LogisimStd in the dependency graph.
@Test func adjacentAndTrailingMemoryRunsRoundTripByteExactly() throws {
  let source = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      This file is intended to be loaded by Logisim-evolution v4.1.0(https://github.com/logisim-evolution/).

      <lib desc="#Memory" name="0"/>
      <main name="main"/>
      <options>
        <a name="gateUndefined" val="ignore"/>
        <a name="simlimit" val="1000"/>
        <a name="simrand" val="0"/>
      </options>
      <mappings/>
      <toolbar/>
      <circuit name="main">
        <a name="circuit" val="main"/>
        <a name="clabelfont" val="SansSerif plain 12"/>
        <comp lib="0" loc="(100,100)" name="ROM">
          <a name="appearance" val="logisim_evolution"/>
          <a name="contents">addr/data: 8 16
    18*0 19*11
    </a>
          <a name="dataWidth" val="16"/>
        </comp>
        <comp lib="0" loc="(100,200)" name="ROM">
          <a name="appearance" val="logisim_evolution"/>
          <a name="contents">addr/data: 8 16
    18*ffff 18*3
    </a>
          <a name="dataWidth" val="16"/>
        </comp>
      </circuit>
    </project>
    """ + "\n"

  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let executable = packageRoot.appendingPathComponent(".build/debug/logisim-cli")
  let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("memory-contents-roundtrip-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }

  let input = temporary.appendingPathComponent("input.circ")
  let output = temporary.appendingPathComponent("output.circ")
  try source.write(to: input, atomically: true, encoding: .utf8)

  let process = Process()
  process.executableURL = executable
  process.arguments = ["--convert", input.path, output.path]
  let errors = Pipe()
  process.standardError = errors
  try process.run()
  process.waitUntilExit()
  let stderr = String(
    data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  #expect(process.terminationStatus == 0, "logisim-cli failed: \(stderr)")

  let roundTripped = try String(contentsOf: output, encoding: .utf8)
  #expect(roundTripped == source)
}
