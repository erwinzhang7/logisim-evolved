// AttributeTextFormat: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically the parsing/formatting behaviour relied on by
// `com/cburch/logisim/data/Attributes.java` and `com/cburch/logisim/data/BitWidth.java`.
// Copyright by the Logisim-evolution developers. This translation is a derivative work
// and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// The Java attribute codecs lean directly on JDK behaviour: `Integer.parseInt`,
// `Integer.parseUnsignedInt`, `Integer.decode`, `Double.toString`, `Font.decode` and
// `String.replaceAll`. `.circ` round-tripping has to be byte-exact (M2), so those routines
// are reimplemented here rather than approximated with Foundation equivalents, which differ
// in several observable ways (Swift prints `1e+22`, Java prints `1.0E22`; Swift's
// `Int32(_:radix:)` rejects the unsigned range Java's `parseUnsignedInt` accepts; and so on).
//
// Everything here is pure text/number manipulation. No Foundation types leak into the
// semantics, keeping D9 (kernel is UI-free) trivially satisfied.

import Foundation

public enum AttributeTextFormat {

  // MARK: - Java character classification

  /// `java.lang.Character.digit(char, int)`, restricted to ASCII.
  ///
  /// The JDK also accepts non-ASCII decimal digits (Arabic-Indic, fullwidth, …). Logisim
  /// never writes those, and accepting them would let a `.circ` file round-trip to a
  /// different byte sequence, so they are deliberately rejected here.
  public static func digitValue(_ scalar: Unicode.Scalar, radix: Int) -> Int? {
    let value: Int
    switch scalar.value {
    case 0x30...0x39: value = Int(scalar.value - 0x30)          // '0'...'9'
    case 0x61...0x7A: value = Int(scalar.value - 0x61) + 10     // 'a'...'z'
    case 0x41...0x5A: value = Int(scalar.value - 0x41) + 10     // 'A'...'Z'
    default: return nil
    }
    return value < radix ? value : nil
  }

  /// True for the characters Java's regex engine excludes from `.` when `UNIX_LINES` is off.
  static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: return true
    default: return false
    }
  }

  // MARK: - Java integer parsing

  /// Accumulate `text` as an unsigned magnitude in `radix`, mirroring the JDK's overflow
  /// detection. `text` must be non-empty and contain digits only (no sign).
  private static func magnitude(
    _ text: Substring, radix: Int, original: String
  ) throws -> UInt64 {
    guard !text.isEmpty else {
      throw AttributeParseError.numberFormat("For input string: \"\(original)\"")
    }
    var accumulator: UInt64 = 0
    for scalar in text.unicodeScalars {
      guard let digit = digitValue(scalar, radix: radix) else {
        throw AttributeParseError.numberFormat("For input string: \"\(original)\"")
      }
      let (scaled, mulOverflow) = accumulator.multipliedReportingOverflow(by: UInt64(radix))
      if mulOverflow {
        throw AttributeParseError.numberFormat("For input string: \"\(original)\"")
      }
      let (summed, addOverflow) = scaled.addingReportingOverflow(UInt64(digit))
      if addOverflow {
        throw AttributeParseError.numberFormat("For input string: \"\(original)\"")
      }
      accumulator = summed
    }
    return accumulator
  }

  /// `Integer.parseInt(s, radix)` (`bits == 32`) or `Long.parseLong(s, radix)` (`bits == 64`).
  public static func parseSigned(
    _ text: String, radix: Int = 10, bits: Int = 32
  ) throws -> Int64 {
    precondition(bits == 32 || bits == 64, "only 32- and 64-bit Java integers exist")
    guard !text.isEmpty else {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    var body = Substring(text)
    var negative = false
    if let first = body.first {
      if first == "-" {
        negative = true
        body = body.dropFirst()
      } else if first == "+" {
        body = body.dropFirst()
      }
    }
    let value = try magnitude(body, radix: radix, original: text)
    let limit: UInt64 = negative
      ? (UInt64(1) << UInt64(bits - 1))
      : (UInt64(1) << UInt64(bits - 1)) - 1
    guard value <= limit else {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    if negative {
      // `-Int64(1 << 63)` is not representable as a positive Int64, so special-case it.
      if value == (UInt64(1) << 63) { return Int64.min }
      return -Int64(value)
    }
    return Int64(value)
  }

  /// `Integer.parseUnsignedInt(s, radix)` (`bits == 32`) or `Long.parseUnsignedLong(s, radix)`.
  ///
  /// Returns the raw magnitude; callers narrow it themselves. A leading `-` is rejected,
  /// exactly as the JDK does.
  public static func parseUnsigned(
    _ text: String, radix: Int = 10, bits: Int = 32
  ) throws -> UInt64 {
    precondition(bits == 32 || bits == 64, "only 32- and 64-bit Java integers exist")
    guard !text.isEmpty else {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    var body = Substring(text)
    if let first = body.first {
      if first == "-" {
        throw AttributeParseError.numberFormat(
          "Illegal leading minus sign on unsigned string \(text).")
      }
      if first == "+" { body = body.dropFirst() }
    }
    let value = try magnitude(body, radix: radix, original: text)
    if bits == 32 && value > 0xFFFF_FFFF {
      throw AttributeParseError.numberFormat(
        "String value \(text) exceeds range of unsigned int.")
    }
    return value
  }

  /// `java.lang.Integer.decode(String)` (`bits == 32`) / `Long.decode` (`bits == 64`).
  ///
  /// Accepts an optional sign followed by `0x`/`0X`/`#` (hex), a leading `0` (octal, only when
  /// more characters follow) or plain decimal. Backs `Color.decode`, which `ColorAttribute`
  /// uses for every `<a name="color" val="…"/>` that is not the 9-character `#rrggbbaa` form.
  public static func decodeSigned(_ text: String, bits: Int = 32) throws -> Int64 {
    guard !text.isEmpty else {
      throw AttributeParseError.numberFormat("Zero length string")
    }
    let scalars = Array(text.unicodeScalars)
    var index = 0
    var negative = false
    if scalars[0] == "-" {
      negative = true
      index = 1
    } else if scalars[0] == "+" {
      index = 1
    }

    var radix = 10
    func matches(_ prefix: [Unicode.Scalar]) -> Bool {
      guard index + prefix.count <= scalars.count else { return false }
      for (offset, scalar) in prefix.enumerated() where scalars[index + offset] != scalar {
        return false
      }
      return true
    }
    if matches(["0", "x"]) || matches(["0", "X"]) {
      index += 2
      radix = 16
    } else if matches(["#"]) {
      index += 1
      radix = 16
    } else if matches(["0"]) && scalars.count > 1 + index {
      index += 1
      radix = 8
    }

    guard index < scalars.count else {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    if scalars[index] == "-" || scalars[index] == "+" {
      throw AttributeParseError.numberFormat("Sign character in wrong position")
    }

    let digits = String(String.UnicodeScalarView(scalars[index...]))
    let value = try parseSigned(
      (negative ? "-" : "") + digits, radix: radix, bits: bits)
    return value
  }

  // MARK: - Java integer formatting

  /// `Integer.toHexString(int)`, unsigned, lowercase, unpadded.
  public static func javaHexString(int32 value: Int32) -> String {
    String(UInt32(bitPattern: value), radix: 16)
  }

  /// `Long.toHexString(long)`, unsigned, lowercase, unpadded.
  public static func javaHexString(int64 value: Int64) -> String {
    String(UInt64(bitPattern: value), radix: 16)
  }

  // MARK: - Java floating-point parsing and formatting

  /// Java trims with `c <= ' '`, which is wider than `CharacterSet.whitespaces`.
  private static func javaTrim(_ text: String) -> String {
    var scalars = Array(text.unicodeScalars)
    while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
    while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
    return String(String.UnicodeScalarView(scalars))
  }

  /// `java.lang.Double.valueOf(String)`.
  public static func parseDouble(_ text: String) throws -> Double {
    var body = javaTrim(text)
    guard !body.isEmpty else {
      throw AttributeParseError.numberFormat("empty String")
    }
    // Java permits a trailing `f`/`F`/`d`/`D` type suffix on a decimal literal.
    if let last = body.last, "fFdD".contains(last), body.count > 1 {
      let stripped = String(body.dropLast())
      // Only strip when what remains still looks numeric; "Infinity" must survive intact.
      let numericish = stripped.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 0x30...0x39,  // 0-9
             0x2E, 0x2B, 0x2D,  // . + -
             0x41...0x46, 0x61...0x66,  // A-F a-f (hex literals)
             0x50, 0x70,  // P p (hex exponent)
             0x58, 0x78:  // X x
          return true
        default:
          return false
        }
      }
      if numericish { body = stripped }
    }
    // Java's floating-point grammar makes the binary exponent MANDATORY on a hex literal:
    // `(0[xX]HexDigits(\.)?|...)[pP][+-]?Digits`. Swift's `Double(String)` accepts a hex
    // significand without one, so `"0x10"` yielded 16.0 here and threw in Java; a value the
    // upstream would have rejected at load silently became valid.
    let unsigned = body.hasPrefix("-") || body.hasPrefix("+") ? String(body.dropFirst()) : body
    if unsigned.lowercased().hasPrefix("0x"),
       !unsigned.contains(where: { $0 == "p" || $0 == "P" }) {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }

    switch body {
    case "NaN": return Double.nan
    case "Infinity", "+Infinity": return Double.infinity
    case "-Infinity": return -Double.infinity
    default: break
    }
    // Reject the spellings Swift accepts but Java does not, so a malformed file is not
    // silently "repaired" into a value that then round-trips differently.
    let lowered = body.lowercased()
    if lowered.contains("inf") || lowered.contains("nan") {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    guard let value = Double(body) else {
      throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
    }
    return value
  }

  /// Decompose `magnitude` (finite, > 0) into its shortest round-tripping decimal digits and
  /// the exponent `p` such that the value is `d₁.d₂d₃… × 10^p`.
  ///
  /// Swift's `Double` description already produces the shortest digit string that round-trips,
  /// which is the same digit string the JDK produces since JDK 19. Only the *layout* differs,
  /// so this reads Swift's digits back out and Java re-lays them below.
  private static func shortestDecimalDigits(_ magnitude: Double) -> (digits: [Character], exponent: Int) {
    let repr = "\(magnitude)"
    var mantissa = repr
    var exponent = 0
    if let marker = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      mantissa = String(repr[repr.startIndex..<marker])
      let tail = repr[repr.index(after: marker)...]
      exponent = Int(tail.replacingOccurrences(of: "+", with: "")) ?? 0
    }

    var integerDigitCount = mantissa.count
    var digitCharacters = Array(mantissa)
    if let dot = mantissa.firstIndex(of: ".") {
      integerDigitCount = mantissa.distance(from: mantissa.startIndex, to: dot)
      digitCharacters.removeAll { $0 == "." }
    }

    var firstSignificant = 0
    while firstSignificant < digitCharacters.count - 1
      && digitCharacters[firstSignificant] == "0" {
      firstSignificant += 1
    }
    let p = (integerDigitCount - 1 - firstSignificant) + exponent
    var significant = Array(digitCharacters[firstSignificant...])
    while significant.count > 1 && significant.last == "0" { significant.removeLast() }

    // SUBNORMALS: the JDK emits two significant digits where Swift's shortest
    // round-tripping form has one.
    //
    //     Double.toString(Double.MIN_VALUE)        Java "4.9E-324"   Swift "5e-324"
    //     Double.toString(bitPattern 2)            Java "9.9E-324"   Swift "1e-323"
    //
    // Both forms round-trip, so "pick whichever is numerically closer" cannot decide it;
    // parsed back they are the *same* double and the difference is exactly zero. The
    // discriminator that actually holds across every failing case is subnormality: for
    // magnitudes below leastNormalMagnitude the JDK renders two digits, and for normal
    // values a one-digit shortest form is kept (Double.toString(1e10) is "1.0E10").
    //
    // Derived empirically from JDK 21 rather than from a spec reading, and pinned by the
    // `D str` golden cases so a future change is caught rather than argued about.
    if significant.count == 1, magnitude > 0, magnitude < Double.leastNormalMagnitude {
      let twoDigit = String(format: "%.1e", magnitude)  // e.g. "4.9e-324"
      if let marker = twoDigit.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        let mant = twoDigit[twoDigit.startIndex..<marker]
        let exp = Int(twoDigit[twoDigit.index(after: marker)...]
          .replacingOccurrences(of: "+", with: "")) ?? p
        let digits = Array(mant.filter { $0.isNumber })
        if digits.count == 2 {
          return (digits, exp)
        }
      }
    }
    return (significant, p)
  }

  /// `java.lang.Double.toString(double)`.
  ///
  /// Plain decimal for `1e-3 <= |d| < 1e7`, computerized scientific notation otherwise,
  /// always with at least one digit after the point.
  public static func javaDoubleString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }

    let negative = value < 0
    let (digits, p) = shortestDecimalDigits(abs(value))
    var body: String
    if p >= -3 && p <= 6 {
      if p >= 0 {
        if digits.count > p + 1 {
          body = String(digits.prefix(p + 1)) + "." + String(digits.dropFirst(p + 1))
        } else {
          let padding = String(repeating: "0", count: p + 1 - digits.count)
          body = String(digits) + padding + ".0"
        }
      } else {
        body = "0." + String(repeating: "0", count: -p - 1) + String(digits)
      }
    } else {
      let head = String(digits.prefix(1))
      let tail = digits.count > 1 ? String(digits.dropFirst()) : "0"
      body = head + "." + tail + "E" + String(p)
    }
    return negative ? "-" + body : body
  }

  // MARK: - Java string scrubbing

  /// `s.replaceAll("[\u{0}-\u{1f}]", "")`.
  public static func stripControlCharacters(_ text: String) -> String {
    var view = String.UnicodeScalarView()
    for scalar in text.unicodeScalars where scalar.value > 0x1F {
      view.append(scalar)
    }
    return String(view)
  }

  /// `s.replaceAll("&#.*?;", "")`.
  ///
  /// Reluctant `.*?`, and `.` does not match a line terminator, so a `&#…;` run that spans a
  /// newline is *not* removed. That asymmetry is observable in multi-line text attributes,
  /// so it is reproduced exactly.
  public static func stripNumericEntities(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
      if scalars[index] == "&", index + 1 < scalars.count, scalars[index + 1] == "#" {
        var probe = index + 2
        var terminator = -1
        while probe < scalars.count {
          if isLineTerminator(scalars[probe]) { break }
          if scalars[probe] == ";" {
            terminator = probe
            break
          }
          probe += 1
        }
        if terminator >= 0 {
          index = terminator + 1
          continue
        }
      }
      output.append(scalars[index])
      index += 1
    }
    return String(output)
  }

  /// `Attribute.toStandardString`'s default body: strip control characters, then entities.
  /// Order matters; the control-character pass removes the newlines that would otherwise
  /// stop the entity pass.
  public static func standardScrub(_ text: String) -> String {
    stripNumericEntities(stripControlCharacters(text))
  }

  /// `Attributes.MultilineStringAttribute.toStandardString`: CRLF/CR are folded to LF, then
  /// everything below `' '` other than LF is dropped, then entities are stripped.
  public static func multilineScrub(_ text: String) -> String {
    var normalized = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\r" {
        normalized.append("\n")
        if index + 1 < scalars.count && scalars[index + 1] == "\n" { index += 1 }
      } else {
        normalized.append(scalar)
      }
      index += 1
    }
    var kept = String.UnicodeScalarView()
    for scalar in normalized where scalar == "\n" || scalar.value >= 0x20 {
      kept.append(scalar)
    }
    return stripNumericEntities(String(kept))
  }

  // MARK: - java.awt.Font.decode

  private static func lastIndex(
    of needle: Unicode.Scalar, in scalars: [Unicode.Scalar], from: Int
  ) -> Int {
    var index = min(from, scalars.count - 1)
    while index >= 0 {
      if scalars[index] == needle { return index }
      index -= 1
    }
    return -1
  }

  /// `java.awt.Font.decode(String)`, transcribed.
  ///
  /// Accepts `family-style-size`, `family style size`, and every truncation of those the JDK
  /// accepts. Unparsable sizes fall back to 12 and unrecognised style words fold back into the
  /// family name.
  ///
  /// The two index computations that can run off the end of the string (reached by inputs such
  /// as `"Foo bar"`, where the trailing word is neither a size nor a style) are clamped.
  /// Verified against `java.awt.Font.decode` on OpenJDK 21 for
  /// `SansSerif bold 16`, `Monospaced-bolditalic-12`, `Serif`, `SansSerif plain 12`,
  /// `Dialog-plain-10`, `Foo bar`, `SansSerif-16`, `SansSerif bold`,
  /// `Times New Roman italic 14` and `""`: same name, style and size in every case.
  public static func decodeFont(_ text: String) -> FontSpec {
    let scalars = Array(text.unicodeScalars)
    let length = scalars.count
    if length == 0 { return FontSpec(family: "", style: .plain, size: 12) }

    var fontName = text
    var fontSize: Int32 = 12
    var fontStyle: FontStyle = .plain

    let lastHyphen = lastIndex(of: "-", in: scalars, from: length - 1)
    let lastSpace = lastIndex(of: " ", in: scalars, from: length - 1)
    let separator: Unicode.Scalar = (lastHyphen > lastSpace) ? "-" : " "

    var sizeIndex = lastIndex(of: separator, in: scalars, from: length - 1)
    var styleIndex = sizeIndex >= 1
      ? lastIndex(of: separator, in: scalars, from: sizeIndex - 1)
      : -1

    func substring(_ range: Range<Int>) -> String {
      String(String.UnicodeScalarView(scalars[range]))
    }

    if sizeIndex > 0 && sizeIndex + 1 < length {
      if let parsed = try? parseSigned(substring((sizeIndex + 1)..<length), radix: 10, bits: 32) {
        fontSize = Int32(truncatingIfNeeded: parsed)
        if fontSize <= 0 { fontSize = 12 }
      } else {
        // Not a size after all; treat that trailing word as the style instead.
        styleIndex = sizeIndex
        sizeIndex = length
        if scalars[sizeIndex - 1] == separator { sizeIndex -= 1 }
      }
    }

    if styleIndex >= 0 && styleIndex + 1 < length {
      let styleEnd = Swift.max(styleIndex + 1, Swift.min(sizeIndex, length))
      let styleName = substring((styleIndex + 1)..<styleEnd).lowercased()
      switch styleName {
      case "bolditalic": fontStyle = [.bold, .italic]
      case "italic": fontStyle = .italic
      case "bold": fontStyle = .bold
      case "plain": fontStyle = .plain
      default:
        // Java: `fontStyleIndex = fontSizeIndex; if (str.charAt(fontStyleIndex - 1) == sepChar)
        // fontStyleIndex--;`: it tests the character BEFORE the index, not the one at it.
        // Testing at the index truncated the family name by one character, so
        // "Comic Sans MS 12" decoded as family "Comic Sans M" and was then written back to
        // the file that way.
        styleIndex = sizeIndex
        if styleIndex >= 1 && styleIndex - 1 < length && scalars[styleIndex - 1] == separator {
          styleIndex -= 1
        }
      }
      fontName = substring(0..<Swift.max(0, Swift.min(styleIndex, length)))
    } else {
      var fontEnd = length
      if styleIndex > 0 {
        fontEnd = styleIndex
      } else if sizeIndex > 0 {
        fontEnd = sizeIndex
      }
      if fontEnd > 0 && scalars[fontEnd - 1] == separator { fontEnd -= 1 }
      fontName = substring(0..<fontEnd)
    }

    return FontSpec(family: fontName, style: fontStyle, size: fontSize)
  }
}
