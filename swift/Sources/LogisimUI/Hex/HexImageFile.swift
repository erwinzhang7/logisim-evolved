// HexImageFile.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.hex.HexFile: the `open(MemContents,
// File)`, `save(File, MemContents, String)`, `headerForFormat` and `saveToString` entry points
// only), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ ONE ENCODER, NOT TWO ═══════════════════════════════════════════════════════════════════
//
// The "v2.0 raw" codec is **already ported**, in `LogisimStd/Memory/MemContents.swift`
// (`saveRawToString` / `parseRaw`), because `Rom.contentsAttr` needs it to read and write the
// `contents` attribute of every ROM in every `.circ` file; a path the corpus gate exercises
// byte-exactly over 539 files. This file does not reimplement it and must never start to. Its
// entire job over the format is the eight-character header line `headerForFormat` prepends:
//
//     "v2.0 raw\n" + MemContents.saveRawToString(contents)
//
// `HexImageFileTests.fileBodyIsExactlyTheCircEncoder` asserts that identity directly, so a second
// encoder cannot be introduced here without a red test.
//
// ══ WHAT IS DELIBERATELY NOT PORTED ════════════════════════════════════════════════════════
//
// `HexFile` is 1,807 lines and knows nine formats (raw RLE, hex bytes/words × plain/addressed ×
// big/little-endian, binary, escaped ASCII), a format-guessing heuristic
// (`detectFormatAndDecode`), an interactive `HexFormatDialog` with a live preview pane, and
// `BufferedLineReader`'s three-way file/string/stream abstraction. Reading a v3.0 file needs a
// bit-stream reassembler that regroups a byte stream into arbitrary word widths, with endianness,
// and writing one needs the inverse.
//
// This slice ports **one** format, the one every `.circ` already contains and the one upstream
// itself writes by default. That is an honest subset, not a stub: a file this writes is loadable
// by 4.1.0, and a "v2.0 raw" file 4.1.0 writes is loadable here. Any other header is rejected
// with a message that names what was found and what is understood, rather than being guessed at;
// silently misreading a v3.0 file as raw would fill a ROM with plausible garbage, which is
// strictly worse than refusing it.
//
// ── `open` semantics ────────────────────────────────────────────────────────────────────────
//
// Upstream parses into a *fresh* `MemContents` sized from the destination's own address width and
// word width, then `dst.copyFrom(0, loaded, 0, loaded.getLastOffset() + 1)`. It does not resize
// the destination and it does not clear the tail beyond the file's contents; a short file
// overwrites a prefix and leaves the rest. Both behaviours are preserved: `parseRaw` already
// sizes the result from `dst`'s dimensions, and `copyFrom` is called with exactly upstream's
// four arguments.

import Foundation
import LogisimStd

/// Why a memory-image load or save failed, with enough detail to put in a dialog.
public enum HexImageFileError: Error, LocalizedError, Equatable {
  /// The file's header line names a format this port does not read. Carries the header as found.
  case unsupportedFormat(String)
  /// The file has no recognisable header line at all; it is empty, or entirely comments.
  ///
  /// Upstream would fall through to `detectFormatAndDecode`'s guessing heuristic here. Refusing
  /// is the deliberate difference; see the file header.
  case missingHeader
  /// The bytes are not valid UTF-8. Upstream's `BufferedLineReader` decodes UTF-8 with a
  /// fall-back to ISO-8859-1; this port does the same, so this case is only reachable for input
  /// that is neither, which is to say, for a binary-format file handed to the raw reader.
  case notText

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let header):
      return """
        This memory image is in a format this version cannot read yet: "\(header)". \
        Only "v2.0 raw" images are supported.
        """
    case .missingHeader:
      return """
        This file has no memory-image header. A memory image must begin with a line \
        reading "v2.0 raw".
        """
    case .notText:
      return "This file is not a text memory image."
    }
  }
}

/// `com.cburch.logisim.gui.hex.HexFile`, restricted to the "v2.0 raw" format.
public enum HexImageFile {

  /// `headerForFormat("v2.0 raw")`.
  public static let rawHeader = "v2.0 raw\n"

  // MARK: Save

  /// `HexFile.save(File, MemContents, "v2.0 raw")`, as a string.
  ///
  /// This is `headerForFormat(desc) + HexWriter.saveRaw()`. The body comes from the shared
  /// codec: see the "ONE ENCODER" note in the file header.
  public static func encode(_ contents: MemContents) -> String {
    rawHeader + MemContents.saveRawToString(contents)
  }

  /// `HexFile.save(File, MemContents, "v2.0 raw")`.
  ///
  /// UTF-8, as upstream writes it (`headerForFormat(desc).getBytes(StandardCharsets.UTF_8)`,
  /// and `saveRaw` emits ASCII digits, `*`, spaces and newlines only).
  public static func save(_ contents: MemContents, to url: URL) throws {
    try Data(encode(contents).utf8).write(to: url, options: .atomic)
  }

  // MARK: Load

  /// `HexFile.open(MemContents dst, File src)`.
  ///
  /// Returns the number of words written, which is upstream's `loaded.getLastOffset() + 1`:
  /// the count it hands `copyFrom`, not the number of tokens in the file.
  @discardableResult
  public static func load(from url: URL, into destination: MemContents) throws -> Int {
    let data = try Data(contentsOf: url)
    return try load(text: try decodeText(data), into: destination)
  }

  /// The same, from text already in hand; the path `HexFile.parse(...)` takes for a string, and
  /// the one the tests drive.
  @discardableResult
  public static func load(text: String, into destination: MemContents) throws -> Int {
    try requireRawHeader(text)
    // `parseRaw` skips the version line itself (`findNonemptyLine(skipHeader: true)` drops a
    // first non-empty line beginning with "v"), so the whole text goes in unmodified: exactly
    // as upstream hands the whole `BufferedLineReader` to `HexReader`.
    let loaded = try MemContents.parseRaw(
      text, addrBits: destination.logLength, width: destination.valueWidth)
    let count = Int(loaded.lastOffset + 1)
    try destination.copyFrom(0, loaded, 0, count)
    return count
  }

  /// `HexReader.parseHeader`, narrowed to "is this the one format we read?".
  ///
  /// The scan mirrors `findNonemptyLine`: `#` starts a comment that runs to end of line, and
  /// leading blank lines are skipped. The first line with content is the header.
  private static func requireRawHeader(_ text: String) throws {
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = rawLine.prefix { $0 != "#" }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      // `t[0].equalsIgnoreCase("v2.0")` plus `parseFormat`'s `desc.startsWith("v2.0 raw")`.
      let tokens = trimmed.split(whereSeparator: \.isWhitespace)
      if tokens.count >= 2, tokens[0].lowercased() == "v2.0", tokens[1].lowercased() == "raw" {
        return
      }
      throw HexImageFileError.unsupportedFormat(trimmed)
    }
    throw HexImageFileError.missingHeader
  }

  /// `BufferedLineReader.forFile(File)`'s decoding: UTF-8, falling back to ISO-8859-1 for bytes
  /// that are not valid UTF-8 (Java's `CharsetDecoder` with `REPLACE` never fails outright, and
  /// every byte sequence is valid ISO-8859-1, so the fall-back always succeeds).
  private static func decodeText(_ data: Data) throws -> String {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
    throw HexImageFileError.notText
  }
}
