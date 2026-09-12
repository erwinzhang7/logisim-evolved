// JavaNumberParsing.swift: part of logisim-evolved.
//
// Small number-parsing helpers that mirror Java's `Integer`/`Long` static parse methods
// exactly, for the pieces `javaParseInt32` (LogisimKernel/Location.swift) does not cover:
// unsigned parsing with an explicit radix (`Integer.parseUnsignedInt(s, 16)`,
// `Long.parseUnsignedLong(s, 16)`) and signed 64-bit parsing (`Long.parseLong`).
//
// The assembler's number literals (`AssemblerToken.getNumberValue`/`getLongValue`) route
// through these, and the port brief calls out `Integer.parseInt` divergence by name as a
// known hazard class; the same reasoning applies to every sibling `parseXxx` overload Java
// exposes, so each one gets its own faithful helper rather than reaching for `Int(_:)`/
// `Int(_:radix:)`, which are 64-bit, ASCII-only, and silently accept out-of-range magnitudes.
//
// Reference tree: upstream-java-4.1.0 (D16).

/// Mirrors Java's `String.split(regex)` with the default `limit == 0`: trailing empty strings
/// are removed from the result. `AssemblerToken`'s constructor relies on this exact behaviour;
/// `"0X".split("X")` is `["0"]` (length 1, so the hex literal is marked invalid), not `["0", ""]`
/// (length 2) the way a naive `components(separatedBy:)` would produce.
func javaSplitTrailingEmptyRemoved(_ s: String, on separator: Character) -> [String] {
  var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
  while let last = parts.last, last.isEmpty {
    parts.removeLast()
    if parts.isEmpty { break }
  }
  return parts
}

/// Mirrors Java's `Integer.parseUnsignedInt(String, int radix)`: no sign character other than an
/// optional leading `+`, digits validated against `radix` (`Character.digit`, so it also accepts
/// Unicode digits the way `javaParseInt32` does for decimal), magnitude checked against
/// `0xFFFFFFFF` unsigned. Returns the Java `int` bit pattern (i.e. may be negative once
/// reinterpreted as signed), matching what `Integer.parseUnsignedInt` returns as `int`.
func javaParseUnsignedInt32(_ s: some StringProtocol, radix: Int) -> Int? {
  guard let magnitude = javaParseUnsignedMagnitude(s, radix: radix) else { return nil }
  guard magnitude <= 0xFFFF_FFFF else { return nil }
  return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: magnitude)))
}

/// Mirrors Java's `Long.parseUnsignedLong(String, int radix)`. Returns the Java `long` bit
/// pattern as a Swift `Int64` (may be negative once reinterpreted as signed).
func javaParseUnsignedInt64(_ s: some StringProtocol, radix: Int) -> Int64? {
  guard let magnitude = javaParseUnsignedMagnitude(s, radix: radix) else { return nil }
  guard magnitude <= UInt64.max else { return nil }
  return Int64(bitPattern: UInt64(truncatingIfNeeded: magnitude))
}

/// Mirrors Java's `Long.parseLong(String)`: optional `+`/`-`, decimal digits only, 64-bit
/// signed range check.
func javaParseInt64(_ s: some StringProtocol) -> Int64? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  var negative = false
  if let first = text.first, first == "-" || first == "+" {
    negative = (first == "-")
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  var magnitude: UInt128 = 0
  for ch in text {
    guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return nil }
    magnitude = magnitude * 10 + UInt128(d)
    if magnitude > UInt128(UInt64.max) + 1 { return nil }
  }
  if negative {
    guard magnitude <= UInt128(Int64.max) + 1 else { return nil }
    if magnitude == UInt128(Int64.max) + 1 { return Int64.min }
    return -Int64(magnitude)
  } else {
    guard magnitude <= UInt128(Int64.max) else { return nil }
    return Int64(magnitude)
  }
}

/// Shared magnitude accumulator for the two unsigned parsers above. `radix` follows Java's
/// `Character.digit(ch, radix)`: 0-9 then a-z/A-Z, up to radix 36. An optional leading `+` is
/// accepted (Java's unsigned parsers accept it); `-` is rejected, matching
/// `NumberFormatException` on a signed literal passed to `parseUnsignedInt`.
private func javaParseUnsignedMagnitude(_ s: some StringProtocol, radix: Int) -> UInt128? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  if text.first == "+" {
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  guard text.first != "-" else { return nil }
  var magnitude: UInt128 = 0
  for ch in text {
    guard let d = ch.hexDigitOrRadixValue, d < radix else { return nil }
    magnitude = magnitude * UInt128(radix) + UInt128(d)
    // A 32/64-bit unsigned magnitude comfortably fits in 128 bits with room to spare before
    // this bound, so this only trips on pathological input (extremely long digit runs).
    if magnitude > UInt128(UInt64.max) * 2 { return nil }
  }
  return magnitude
}

extension Character {
  /// `Character.digit(ch, radix)` for radix up to 36: '0'-'9', then 'a'-'z'/'A'-'Z'.
  fileprivate var hexDigitOrRadixValue: Int? {
    if let v = wholeNumberValue, v >= 0, v <= 9, isASCII { return v }
    guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return nil }
    switch scalar.value {
    case 0x41...0x5A: return Int(scalar.value - 0x41) + 10  // A-Z
    case 0x61...0x7A: return Int(scalar.value - 0x61) + 10  // a-z
    default: return nil
    }
  }
}
