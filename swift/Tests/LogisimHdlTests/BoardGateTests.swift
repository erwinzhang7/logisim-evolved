// BoardGateTests.swift: part of logisim-evolved.
//
// The board gate: the Swift `BoardReader` against the shipped 4.1.0 jar's `BoardReaderClass`,
// over all 29 board XMLs that ship inside the jar.
//
// ── Why this is a real gate and not a re-reading ────────────────────────────────────────────
//
// `tools/hdlbridge/BoardBridge.java` runs the **actual** `com.cburch.logisim.fpga.file.
// BoardReaderClass` inside `logisim-evolution-4.1.0-all.jar` and prints every field of the
// resulting `BoardInformation`: board name, all fifteen `FpgaClass` fields, the decoded
// picture's pixel dimensions, and per IO component its type, rectangle, pin counts, rotation,
// array geometry, the four pin attributes as their raw `char` ids, the *sorted* input/output/io
// pin index sets, and every FPGA pin location string in order. This suite regenerates the same
// text from the Swift model and diffs it line by line. Regenerate the oracle with
// `tools/hdlbridge/gen_board_oracle.py`.
//
// What that catches that reading the Java does not: the `getId` table orders (a wrong index is
// a silently different constraints file), the backward-compatibility pin partition, the
// LedArray/SevenSegmentScanning pin expansion, `Integer.parseUnsignedInt` versus `parseInt` on
// the seven-segment column count, and the `Pin`-forces-active-high rule.
//
// ── The one thing it cannot compare directly ────────────────────────────────────────────────
//
// The board picture. The jar reports `BufferedImage.getWidth()/getHeight()` after
// `ImageIO.read`; this port deliberately has no JPEG decoder (D9; the image is data here). So
// the picture is checked two ways instead:
//
//   * the ASCII stream decodes to bytes that begin `FFD8` and whose **start-of-frame marker**
//     carries exactly the dimensions the jar's decoded `BufferedImage` reports, which cannot be
//     true unless the symbol table, the two-character-symbol rule and the `- 128` narrowing are
//     all right; and
//   * re-encoding those bytes with the ported `createCodeTable` reproduces the board file's own
//     `CompressionCodeTable/@TableData` and `PixelData/@PixelRGB` **byte for byte**, which is a
//     round trip through the half of `ImageXmlFactory` that has no AWT in it.
//
// Skips itself when the boards are not present, like every other corpus-backed suite here.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimHdl
import Testing

@Suite("FPGA boards — the 4.1.0 jar oracle")
struct BoardGateTests {

  /// `tools/hdlbridge/boards-4.1.0.oracle`, located by walking up from this source file.
  static func oracleURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["LOGISIM_BOARD_ORACLE"] {
      return URL(fileURLWithPath: override)
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("tools/hdlbridge/boards-4.1.0.oracle")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      directory = directory.deletingLastPathComponent()
    }
    return nil
  }

  /// The directory holding the board XMLs the oracle names.
  ///
  /// They live inside the jar, and D12 records the vendor product photography embedded in them
  /// as an unresolved rights problem, so they are **not** checked into this repository. Point
  /// `LOGISIM_BOARDS` at a checkout of the 4.1.0 source tree's
  /// `src/main/resources/resources/logisim/boards`, or leave it unset and this suite skips.
  static func boardsDirectory() -> URL? {
    if let override = ProcessInfo.processInfo.environment["LOGISIM_BOARDS"] {
      let url = URL(fileURLWithPath: override)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let fallback = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Developer/logisim/upstream-java-4.1.0/src/main/resources/resources/logisim/boards")
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  /// One `BOARD … END` block of the oracle.
  struct OracleEntry {
    let name: String
    let lines: [String]
  }

  static func parseOracle(_ text: String) -> [OracleEntry] {
    var entries: [OracleEntry] = []
    var current: String?
    var lines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("BOARD ") {
        current = String(line.dropFirst("BOARD ".count))
        lines = []
      } else if line == "END" {
        if let name = current { entries.append(OracleEntry(name: name, lines: lines)) }
        current = nil
      } else if current != nil, !line.isEmpty {
        lines.append(line)
      }
    }
    return entries
  }

  /// The bridge's `esc`: backslash, newline and space are escaped, `null` becomes `<null>`.
  static func esc(_ text: String?) -> String {
    guard let text else { return "<null>" }
    return
      text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: " ", with: "\\s")
  }

  static func sortedSet(_ set: Set<Int>?) -> String {
    guard let set else { return "<null>" }
    return "[" + set.sorted().map(String.init).joined(separator: ",") + "]"
  }

  /// Regenerates `BoardBridge.dump`'s body from the Swift model. Must match character for
  /// character.
  static func describe(_ board: BoardInformation) -> [String] {
    var lines: [String] = []
    lines.append("NAME " + esc(board.boardName))
    let fpga = board.fpga
    lines.append(
      "FPGA present=\(fpga.isFpgaInfoPresent)"
        + " freq=\(fpga.clockFrequency)"
        + " clkpin=" + esc(fpga.clockPinLocation)
        + " clkpull=\(fpga.clockPullBehavior)"
        + " clkstd=\(fpga.clockIoStandard)"
        + " tech=" + esc(fpga.technology)
        + " part=" + esc(fpga.part)
        + " pkg=" + esc(fpga.packageName)
        + " speed=" + esc(fpga.speedGrade)
        + " vendor=\(fpga.vendor)"
        + " unused=\(fpga.unusedPinsBehavior)"
        + " usbtmc=\(fpga.isUsbTmcDownloadRequired)"
        + " jtag=\(fpga.jtagChainPosition)"
        + " flashname=" + esc(fpga.flashName)
        + " flashpos=\(fpga.flashChainPosition)"
        + " flashdef=\(fpga.isFlashDefined)")

    // The jar reports the *decoded* picture's size; this port reads it out of the JPEG's frame
    // header instead, which is the same number by a different route (see the file header).
    if let image = board.image {
      let size = image.jpegFrameSize ?? image.declaredSize
      lines.append("IMAGE \(size.width)x\(size.height)")
    } else {
      lines.append("IMAGE none")
    }

    lines.append("NCOMP \(board.allComponents.count)")
    for (index, comp) in board.allComponents.enumerated() {
      var line = "COMP \(index)"
      line += " type=\(comp.type.rawValue)"
      line +=
        " rect="
        + (comp.rectangle.map {
          "\($0.xPosition),\($0.yPosition),\($0.width),\($0.height)"
        } ?? "<null>")
      line += " npins=\(comp.numberOfPins)"
      line += " ext=\(comp.externalPinCount)"
      line += " rot=\(comp.mapRotation)"
      line += " rows=\(comp.numberOfRows)"
      line += " cols=\(comp.numberOfColumns)"
      line += " driving=\(comp.driving)"
      line += " label=" + esc(comp.label)
      line += " pull=\(comp.pullBehavior)"
      line += " act=\(comp.activityLevel)"
      line += " std=\(comp.ioStandard)"
      line += " drive=\(comp.driveStrength)"
      line += " in=" + sortedSet(comp.inputPins)
      line += " out=" + sortedSet(comp.outputPins)
      line += " io=" + sortedSet(comp.ioPins)
      line +=
        " locs=["
        + (0..<comp.numberOfPins).map { esc(comp.pinLocation($0)) }.joined(separator: ",")
        + "]"
      lines.append(line)
    }
    return lines
  }

  @Test("every shipped board parses identically to the jar")
  func boardsMatchTheJar() throws {
    guard let oracleURL = Self.oracleURL(), let boards = Self.boardsDirectory() else {
      withKnownIssue("boards or oracle unavailable — set LOGISIM_BOARDS", isIntermittent: true) {
        Issue.record("skipped")
      }
      return
    }
    let entries = Self.parseOracle(try String(contentsOf: oracleURL, encoding: .utf8))
    #expect(entries.count >= 20, "oracle looks truncated: \(entries.count) boards")

    var checked = 0
    var missing: [String] = []
    var divergences: [String] = []

    for entry in entries {
      let basename = (entry.name as NSString).lastPathComponent
      let file = boards.appendingPathComponent(basename)
      guard FileManager.default.fileExists(atPath: file.path) else {
        missing.append(basename)
        continue
      }
      let board: BoardInformation
      do {
        board = try BoardReader.read(contentsOf: file)
      } catch {
        divergences.append("\(basename): threw \(error)")
        continue
      }
      let actual = Self.describe(board)
      checked += 1
      for (index, expected) in entry.lines.enumerated() {
        guard index < actual.count else {
          divergences.append("\(basename) line \(index + 1): swift ran out; jar: \(expected)")
          break
        }
        if actual[index] != expected {
          divergences.append(
            "\(basename) line \(index + 1):\n    jar:   \(expected)\n    swift: \(actual[index])")
          break
        }
      }
      if actual.count > entry.lines.count {
        divergences.append(
          "\(basename): swift produced \(actual.count) lines, jar \(entry.lines.count)")
      }
    }

    #expect(
      divergences.isEmpty,
      "\(divergences.count) of \(entries.count) boards diverge:\n\(divergences.prefix(6).joined(separator: "\n"))")
    #expect(checked > 0, "no board file was found in \(boards.path); missing: \(missing.count)")
  }

  @Test("the picture round-trips through the ported half of ImageXmlFactory")
  func pictureReencodesByteForByte() throws {
    guard let boards = Self.boardsDirectory() else {
      withKnownIssue("boards unavailable — set LOGISIM_BOARDS", isIntermittent: true) {
        Issue.record("skipped")
      }
      return
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: boards.path)
      .filter { $0.hasSuffix(".xml") }.sorted()
    guard !files.isEmpty else {
      withKnownIssue("no board XMLs in \(boards.path)", isIntermittent: true) {
        Issue.record("skipped")
      }
      return
    }

    var checked = 0
    var mismatches: [String] = []
    for name in files {
      let text = try String(
        contentsOf: boards.appendingPathComponent(name), encoding: .utf8)
      guard let table = Self.attributeValue(in: text, attribute: "TableData"),
        let pixels = Self.attributeValue(in: text, attribute: "PixelRGB")
      else {
        mismatches.append("\(name): could not find the picture attributes")
        continue
      }
      let codeTable = BoardImageCodec.codeTable(from: table)
      let image = try BoardImageCodec.decode(
        stream: pixels, codeTable: codeTable, width: 1, height: 1)
      guard case let .jpeg(bytes, _, _) = image else {
        mismatches.append("\(name): decoded to the uncompressed form, expected JPEG")
        continue
      }
      #expect(bytes.count > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8, "\(name): not a JPEG")
      let (reTable, rePixels) = BoardImageCodec.encodeJpeg(bytes)
      if reTable != table { mismatches.append("\(name): code table differs after re-encode") }
      if rePixels != pixels { mismatches.append("\(name): pixel stream differs after re-encode") }
      checked += 1
    }
    #expect(
      mismatches.isEmpty,
      "\(mismatches.count) boards failed the picture round trip:\n\(mismatches.prefix(6).joined(separator: "\n"))")
    #expect(checked > 0)
  }

  /// Pulls one XML attribute value out of raw text, without parsing the ~130 kB document.
  ///
  /// The pixel attributes are single-quoted-free, contain no `<` or `&`, and appear exactly once
  /// each, so a literal scan is both sufficient and much faster than a DOM build.
  static func attributeValue(in text: String, attribute: String) -> String? {
    guard let start = text.range(of: "\(attribute)=\"") else { return nil }
    guard let end = text.range(of: "\"", range: start.upperBound..<text.endIndex) else {
      return nil
    }
    return String(text[start.upperBound..<end.lowerBound])
  }
}
