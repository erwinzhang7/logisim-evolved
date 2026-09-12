// HdlFile: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/file/HdlFile.java. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The one thing that is easy to get wrong here ─────────────────────────────────────────
//
// `HdlFile.load` is not "read the file". It is a `BufferedReader.readLine()` loop that appends
// `System.getProperty("line.separator")` after **every** line, including the last. So loading is
// lossy and normalising in three separate ways, all observable:
//
//   1. every CRLF and every lone CR becomes the platform separator (`\n` on macOS);
//   2. a file that does not end in a newline gains one;
//   3. a file that ends in *several* newlines keeps them all, `readLine` yields the empty
//      lines between them, but a single trailing newline is indistinguishable from none.
//
// This is the same trap that already cost this port a byte in `VhdlContent.template`
// (`loadTemplate()` is character-for-character this same loop) and it is asserted by
// `HdlFileTests` rather than left to be rediscovered a third time.
//
// D13: every failure path throws. Java throws `IOException` with a localised message; the port
// throws `HdlFileError`, which carries upstream's English text verbatim (D9: no localisation
// in the kernel). Note Java's `catch (IOException ex) { throw new IOException(S.get(...)); }`
// *discards* the original exception, so the user only ever sees "Error reading file."; the
// port keeps the underlying error attached instead of dropping it, since nothing observable
// depends on it being lost and a swallowed cause is a debugging cost with no upside.

import Foundation

/// `HdlFile`'s two failure modes, as `hdl.properties` words them.
public struct HdlFileError: Error, CustomStringConvertible {
  public enum Kind: String {
    /// `hdlFileReaderError`.
    case read = "Error reading file."
    /// `hdlFileWriterError`.
    case write = "Error writing file."
  }

  public let kind: Kind
  /// The error Java threw away (see the file header). Informational only.
  public let underlying: Error?

  public var message: String { kind.rawValue }
  public var description: String { message }
}

/// `com.cburch.logisim.vhdl.file.HdlFile`.
public enum HdlFile {

  /// `HdlFile.load(File)`.
  ///
  /// - Throws: `HdlFileError` with `.read` for any I/O or decoding failure.
  public static func load(contentsOf url: URL) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw HdlFileError(kind: .read, underlying: error)
    }
    // Java's `new FileReader(file)` decodes with the JVM default charset, which is UTF-8 from
    // JDK 18 on (JEP 400) and therefore on the Java 21 this port targets. Malformed input is
    // *replaced*, not rejected, `InputStreamReader`'s default `CodingErrorAction.REPLACE`,
    // so decoding never throws here, and neither does this.
    let text = decodeUtf8Replacing(data)
    return normalizeLines(text)
  }

  /// `HdlFile.save(File, String)`. Writes `text` verbatim: no line-separator rewriting on the
  /// way out, unlike `load`.
  ///
  /// - Throws: `HdlFileError` with `.write` for any I/O failure.
  public static func save(_ text: String, to url: URL) throws {
    do {
      try Data(text.utf8).write(to: url)
    } catch {
      throw HdlFileError(kind: .write, underlying: error)
    }
  }

  // MARK: The `readLine()` loop, factored out so it is testable without touching a filesystem

  /// The pure part of `load`: `BufferedReader.readLine()` in a loop, each line followed by
  /// `System.getProperty("line.separator")`.
  ///
  /// `readLine` treats `\n`, `\r\n` and a lone `\r` as terminators, returns the terminator-less
  /// line, and returns null at end of input, so a final line with no terminator is still
  /// returned, and an empty input yields no lines at all (hence `""`, not `"\n"`).
  ///
  /// Deliberately *not* `text.components(separatedBy: .newlines)` and not `enumerateLines`:
  /// those split on Unicode line separators Java's `readLine` does not recognise (U+2028,
  /// U+2029, U+0085, U+000B, U+000C), which would silently insert newlines into VHDL source
  /// that happened to contain one.
  ///
  /// It also iterates **unicode scalars, not `Character`s.** Swift's grapheme breaking makes
  /// `"\r\n"` a single `Character` that compares equal to neither `"\r"` nor `"\n"`, so a
  /// `Character`-based scan silently passes every CRLF straight through unconverted, which is
  /// precisely the normalisation this function exists to perform.
  public static func normalizeLines(_ text: String, separator: String = "\n") -> String {
    let separatorScalars = Array(separator.unicodeScalars)
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    out.reserveCapacity(scalars.count + separatorScalars.count)

    var lineStart = 0
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\n" || scalar == "\r" {
        out.append(contentsOf: scalars[lineStart..<index])
        out.append(contentsOf: separatorScalars)
        index += 1
        // `\r\n` is one terminator, not two.
        if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
        lineStart = index
      } else {
        index += 1
      }
    }
    // A trailing line with no terminator is still a line; an input that ended on a terminator
    // leaves nothing behind, which is why `""` loads as `""` and not as `"\n"`.
    if lineStart < scalars.count {
      out.append(contentsOf: scalars[lineStart...])
      out.append(contentsOf: separatorScalars)
    }
    return String(out)
  }

  /// `InputStreamReader`'s default malformed-input handling: replace, never throw.
  private static func decodeUtf8Replacing(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    return String(decoding: data, as: UTF8.self)
  }
}
