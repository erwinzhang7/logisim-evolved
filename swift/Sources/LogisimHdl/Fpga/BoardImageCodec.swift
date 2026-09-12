// BoardImageCodec.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/file/ImageXmlFactory.java` (254
// lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// ══ What this is ════════════════════════════════════════════════════════════════════════════
//
// A board file embeds the board's photograph as **text**, because the whole board lives in one
// XML attribute. The encoding is a byte-to-symbol substitution with a per-file code table:
//
//   * 256 symbols, one per byte value. 64 of them are one character (`a…z A…Z 0…9 ( )`) and 192
//     are two (the same 64 prefixed with `+`, `-`, `=`), so the stream is self-delimiting:
//     if a character is `+`, `-` or `=` the symbol is two characters long, otherwise one.
//   * The mapping is *frequency-ordered*. `createCodeTable` counts occurrences, sorts byte
//     values by descending count, and hands the shortest symbols to the commonest bytes. The
//     resulting table is written into the file as `CompressionCodeTable/@TableData`, 256
//     space-separated symbols.
//   * A leading `@` (`V2_Identifier`) marks the newer format, whose decoded bytes are a **JPEG
//     file**. Without it the stream is raw 8-bit RGB, three symbols per pixel, row-major.
//
// ══ D9 ══════════════════════════════════════════════════════════════════════════════════════
//
// Upstream's `getPicture` returns a `BufferedImage`: it either hands the decoded bytes to
// `ImageIO.read`, or paints pixel-by-pixel with `Graphics2D.fillRect`. Neither is available to
// this module and neither needs to be; the decode above is a byte transform, and what comes out
// is either a JPEG file or an RGB buffer. `BoardImage` is exactly that, and the UI turns it into
// a `CGImage`. See `BoardInformation.swift` for the seam statement.
//
// One consequence worth being explicit about: **this port does not decode JPEG**, so it cannot
// answer "how many pixels wide is this board photo" the way `BufferedImage.getWidth()` does.
// `BoardImage.jpeg` carries the dimensions the file *declares* in `<PictureDimension>`, and
// `BoardImage.jpegFrameSize` reads the real ones straight out of the JPEG SOF marker: enough
// for `BoardGateTests` to check the decode against the jar's `BufferedImage`, and enough for a
// UI to lay out before decoding.

import Foundation

/// A board photograph, as data.
public enum BoardImage: Equatable {
  /// The newer encoding: `bytes` is a complete JPEG file. `declaredWidth`/`declaredHeight` are
  /// what `<PictureDimension>` said, which upstream ignores on this path (`ImageIO.read` gets
  /// the real size from the JPEG itself) and which every shipped board sets consistently.
  case jpeg(bytes: [UInt8], declaredWidth: Int, declaredHeight: Int)
  /// The older encoding: `bytes` is `width * height * 3` bytes of 8-bit RGB, row-major.
  case rgb(bytes: [UInt8], width: Int, height: Int)

  public var declaredSize: (width: Int, height: Int) {
    switch self {
    case let .jpeg(_, w, h): (w, h)
    case let .rgb(_, w, h): (w, h)
    }
  }

  public var bytes: [UInt8] {
    switch self {
    case let .jpeg(bytes, _, _): bytes
    case let .rgb(bytes, _, _): bytes
    }
  }

  /// The width and height in the JPEG's own start-of-frame marker, or `nil` if this is not a
  /// JPEG or the marker cannot be found.
  ///
  /// Marker walk only: no entropy decoding, no colour transform, no external library. Used by
  /// `BoardGateTests` to prove the ASCII decode produced the same picture the jar's
  /// `ImageIO.read` did, without this module gaining an image decoder.
  public var jpegFrameSize: (width: Int, height: Int)? {
    guard case let .jpeg(bytes, _, _) = self else { return nil }
    return BoardImageCodec.jpegFrameSize(bytes)
  }
}

/// Raised when a board file's pixel data cannot be decoded.
///
/// D13: upstream's failures here are a `NullPointerException` (an unknown symbol, because
/// `CodeLookupTable.get` returns null and is immediately unboxed) or a
/// `StringIndexOutOfBoundsException` (a two-character symbol at the very end of the stream).
/// Both are caught by `BoardReaderClass`'s blanket `catch (Exception)` and reported as "this
/// board did not load", so they are recoverable errors in the Java too; exactly the case D13
/// says must throw rather than trap.
public struct BoardImageDecodeError: Error, CustomStringConvertible {
  public enum Reason: Equatable {
    case codeTableWrongLength(Int)
    case unknownSymbol(String)
    case truncatedSymbol
    case pixelDataExhausted(atPixel: Int)
  }
  public let reason: Reason
  public var description: String {
    switch reason {
    case let .codeTableWrongLength(count):
      "board picture: compression code table has \(count) entries, expected 256"
    case let .unknownSymbol(symbol):
      "board picture: pixel data contains symbol \"\(symbol)\", which is not in the code table"
    case .truncatedSymbol:
      "board picture: pixel data ends inside a two-character symbol"
    case let .pixelDataExhausted(pixel):
      "board picture: pixel data ran out at pixel \(pixel)"
    }
  }
}

/// `com.cburch.logisim.fpga.file.ImageXmlFactory`, minus the AWT.
public enum BoardImageCodec {

  /// `V2_Identifier`.
  public static let jpegIdentifier: Character = "@"

  /// The three prefixes that introduce a two-character symbol.
  static let twoCharacterPrefixes: Set<Character> = ["-", "+", "="]

  /// `InitialCodeTable`: 256 symbols in *rank* order, shortest first.
  public static let initialCodeTable: [String] = {
    let singles = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()")
      .map(String.init)
    var table = singles
    for prefix in ["+", "-", "="] {
      table.append(contentsOf: singles.map { prefix + $0 })
    }
    return table
  }()

  // MARK: - Decoding

  /// `setCodeTable(String[])` fed from `CompressionCodeTable/@TableData`.
  ///
  /// Upstream splits on a single space with `String.split(" ")`, so a table with a double space
  /// yields an empty entry and a table with a trailing space loses it. Same split here.
  public static func codeTable(from tableData: String) -> [String] {
    javaSplitBoardList(tableData, separator: " ")
  }

  /// The decode half of `getPicture(int, int)`.
  ///
  /// - Parameters:
  ///   - stream: the `PixelData/@PixelRGB` attribute verbatim.
  ///   - codeTable: 256 symbols, index = byte value (V1) or byte value + 128 (V2).
  ///   - width/height: `<PictureDimension>`; used only by the V1 path, which needs to know how
  ///     many pixels to read, and carried through on the V2 path for the caller's convenience.
  public static func decode(
    stream: String, codeTable: [String], width: Int, height: Int
  ) throws -> BoardImage {
    guard codeTable.count == 256 else {
      throw BoardImageDecodeError(reason: .codeTableWrongLength(codeTable.count))
    }
    // Java builds a HashMap<String,Integer>; a later duplicate overwrites an earlier one, and
    // `put` returns the old value unexamined. A Swift dictionary literal would trap on the
    // duplicate key, so the loop is written out.
    var lookup: [String: Int] = [:]
    lookup.reserveCapacity(256)
    for (index, symbol) in codeTable.enumerated() { lookup[symbol] = index }

    // ASCII throughout: every symbol is one or two characters from a 67-character alphabet, and
    // Java indexes the attribute by UTF-16 code unit. Working over `Character` matches for any
    // input that is valid; for input that is not, the two disagree only about how the garbage is
    // reported, and both report it.
    let characters = Array(stream)
    guard let first = characters.first else {
      // Upstream: `AsciiStream.charAt(0)` on an empty stream throws
      // StringIndexOutOfBoundsException, caught by the reader. Here it is a decode error, and
      // the reader treats it identically.
      throw BoardImageDecodeError(reason: .truncatedSymbol)
    }

    if first == jpegIdentifier {
      var bytes: [UInt8] = []
      bytes.reserveCapacity(characters.count)
      var index = 1
      while index < characters.count {
        let value = try symbolValue(characters, &index, lookup)
        // `(byte)(value - 128)`: a narrowing cast in Java, so 0 becomes -128 and 255 becomes
        // 127. As an unsigned byte that is exactly `value ^ 0x80`.
        bytes.append(UInt8(truncatingIfNeeded: value - 128))
      }
      return .jpeg(bytes: bytes, declaredWidth: width, declaredHeight: height)
    }

    // The V1 path. Note it does NOT subtract 128: the lookup index *is* the colour component.
    guard width > 0, height > 0 else {
      throw BoardImageDecodeError(reason: .pixelDataExhausted(atPixel: 0))
    }
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 3)
    var index = 0
    for pixel in 0..<(width * height) {
      for _ in 0..<3 {
        guard index < characters.count else {
          throw BoardImageDecodeError(reason: .pixelDataExhausted(atPixel: pixel))
        }
        let value = try symbolValue(characters, &index, lookup)
        bytes.append(UInt8(truncatingIfNeeded: value))
      }
    }
    return .rgb(bytes: bytes, width: width, height: height)
  }

  /// One symbol: two characters if it starts with `-`, `+` or `=`, otherwise one.
  private static func symbolValue(
    _ characters: [Character], _ index: inout Int, _ lookup: [String: Int]
  ) throws -> Int {
    let length = twoCharacterPrefixes.contains(characters[index]) ? 2 : 1
    guard index + length <= characters.count else {
      throw BoardImageDecodeError(reason: .truncatedSymbol)
    }
    let symbol = String(characters[index..<(index + length)])
    index += length
    guard let value = lookup[symbol] else {
      throw BoardImageDecodeError(reason: .unknownSymbol(symbol))
    }
    return value
  }

  // MARK: - Encoding

  /// `createCodeTable(byte[])`.
  ///
  /// The sort is upstream's bubble sort, kept literally. It matters: it is **stable** (it swaps
  /// only on a strict `<`, so byte values with equal counts keep ascending order), and the code
  /// table is part of the file's bytes. Any "equivalent" sort that reorders ties would produce a
  /// different, still valid, but different, board file.
  public static func createCodeTable(for stream: [UInt8]) -> [String] {
    var occurrences = [Int64](repeating: 0, count: 256)
    var index = Array(0..<256)
    // `ocurances[b + 128]++` with a signed Java byte; as an unsigned byte that is `b ^ 0x80`.
    for byte in stream { occurrences[Int(byte ^ 0x80)] += 1 }

    var swapped = true
    while swapped {
      swapped = false
      for i in 0..<255 where occurrences[i] < occurrences[i + 1] {
        swapped = true
        index.swapAt(i, i + 1)
        occurrences.swapAt(i, i + 1)
      }
    }

    var result = [String](repeating: "", count: 256)
    for i in 0..<256 { result[index[i]] = initialCodeTable[i] }
    return result
  }

  /// The tail of `createStream(Image)`; everything after the JPEG bytes exist.
  ///
  /// Returns the pair of attribute values a `<BoardPicture>` section needs:
  /// `CompressionCodeTable/@TableData` and `PixelData/@PixelRGB`.
  public static func encodeJpeg(_ jpeg: [UInt8]) -> (codeTable: String, pixelData: String) {
    let table = createCodeTable(for: jpeg)
    var stream = String(jpegIdentifier)
    stream.reserveCapacity(jpeg.count + 1)
    for byte in jpeg { stream += table[Int(byte ^ 0x80)] }
    return (table.joined(separator: " "), stream)
  }

  // MARK: - JPEG frame size

  /// Width and height from a JPEG's start-of-frame marker.
  ///
  /// Walks the marker chain: `FFD8`, then segments `FF xx <len:2> …`. Any `SOFn` other than the
  /// four that are not frame headers (`C4` DHT, `C8` JPG, `CC` DAC) carries height then width as
  /// big-endian 16-bit at offsets 3 and 5 of its payload. Standalone markers (`D0…D9`, `01`)
  /// have no length field.
  ///
  /// Not a decoder and not a validator; its only job is to let a test compare this port's
  /// decode against the jar's `BufferedImage.getWidth()/getHeight()`.
  public static func jpegFrameSize(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var index = 2
    while index + 1 < bytes.count {
      guard bytes[index] == 0xFF else {
        index += 1
        continue
      }
      // Fill bytes: any number of 0xFF may precede the marker id.
      var cursor = index + 1
      while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
      guard cursor < bytes.count else { return nil }
      let marker = bytes[cursor]
      let payload = cursor + 1
      if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
        index = payload
        continue
      }
      guard payload + 1 < bytes.count else { return nil }
      let length = Int(bytes[payload]) << 8 | Int(bytes[payload + 1])
      let isFrameHeader =
        marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
      if isFrameHeader {
        guard payload + 6 < bytes.count else { return nil }
        let height = Int(bytes[payload + 3]) << 8 | Int(bytes[payload + 4])
        let width = Int(bytes[payload + 5]) << 8 | Int(bytes[payload + 6])
        return (width, height)
      }
      guard length >= 2 else { return nil }
      index = payload + length
    }
    return nil
  }
}
