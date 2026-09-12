// Location.swift: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.data.Location), GPL-3.0-only. See LICENSE.md.
//
// Java's `Location` is a class with a private interning `Cache` (identity-equality fast path).
// Per docs/decisions.md, that cache is dropped here: `Location` is a Swift `struct`, so identity
// caching buys nothing; value equality is free and correct. See Bounds.swift for a case where
// Java's cache-adjacent identity checks are NOT just an optimization and had to be preserved.

import Foundation

/// Java `int` is 32 bits and its arithmetic wraps silently; Swift `Int` is 64 bits and traps.
/// Coordinates flow from `.circ` `loc=` attributes and from renderer arithmetic, so the width
/// difference is observable: `Location.create(Int32.max, 0).translate(1, 0)` wraps to
/// `Int32.min` in Java and would give 2147483648 here. Every coordinate-producing path funnels
/// through this.
@inline(__always)
public func wrap32(_ v: Int) -> Int { Int(Int32(truncatingIfNeeded: v)) }

/// Java's `Math.round(x / 5)` where `x` is `int`.
///
/// There is no `Math.round(int)`. The argument undergoes widening primitive conversion to
/// `float`, and `Math.round(float)` is `(int) floor(a + 0.5f)`. Above 2^24 a `float` cannot
/// represent every integer, so this is NOT the no-op it looks like: `429496729` becomes
/// `429496736`, and `* 5` then overflows `int`.
///
/// Measured: `Location.create(0, 2147483647, true)` is `(0,-2147483616)` in Java, where exact
/// integer arithmetic would give `(0,2147483645)`.
@inline(__always)
func javaMathRoundOfInt(_ v: Int) -> Int {
  let f = Float(v)
  let rounded = (f + 0.5).rounded(.down)
  // Math.round saturates at the int bounds rather than wrapping.
  if rounded >= Float(Int32.max) { return Int(Int32.max) }
  if rounded <= Float(Int32.min) { return Int(Int32.min) }
  return Int(rounded)
}

/// Java's `String.trim()` removes every character <= U+0020, including `\n`, `\r` and `\t`.
/// Swift's `.whitespaces` character set excludes line terminators, so `"(10,20)\n"` survived
/// trimming and then failed to parse.
@inline(__always)
public func javaTrim(_ s: some StringProtocol) -> String {
  var scalars = Array(s.unicodeScalars)
  while let f = scalars.first, f.value <= 0x20 { scalars.removeFirst() }
  while let l = scalars.last, l.value <= 0x20 { scalars.removeLast() }
  var out = String.UnicodeScalarView()
  out.append(contentsOf: scalars)
  return String(out)
}

/// Java's `Integer.parseInt`: strictly 32-bit, and accepts any Unicode decimal digit via
/// `Character.digit`, not just ASCII. Swift's `Int(_:)` is 64-bit and ASCII-only, so it both
/// accepted values Java rejects (`"3000000000"`) and rejected values Java accepts
/// (Arabic-Indic digits).
public func javaParseInt32(_ s: some StringProtocol) -> Int? {
  var text = Substring(s)
  guard !text.isEmpty else { return nil }
  var negative = false
  if let first = text.first, first == "-" || first == "+" {
    negative = (first == "-")
    text = text.dropFirst()
    guard !text.isEmpty else { return nil }
  }
  // Accumulate in Int64 so the range check is exact rather than itself overflowing.
  var magnitude: Int64 = 0
  for ch in text {
    guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return nil }
    magnitude = magnitude * 10 + Int64(d)
    if magnitude > 2_147_483_648 { return nil }
  }
  let signed = negative ? -magnitude : magnitude
  guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else { return nil }
  return Int(signed)
}

/// An immutable 2-D integer point on the schematic grid, analogous to Java's
/// `com.cburch.logisim.data.Location`.
public struct Location: Hashable, Comparable, CustomStringConvertible, Sendable {

  /// Thrown by `Location.parse`, mirroring the message Java's `NumberFormatException` carried.
  public struct ParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
  }

  public let x: Int
  public let y: Int

  /// Whether this location was created with grid-snap semantics. Preserved so that locations
  /// *derived* from this one (translate/rotate) keep the same snapping mode, exactly mirroring
  /// Java's private `hasToSnap` field. Deliberately excluded from equality/hashing/ordering:
  /// Java's `Location.equals`/`hashCode`/`compareTo` only ever look at (x, y), never at
  /// `hasToSnap`, so two Locations with the same coordinates but different snap modes are equal.
  fileprivate let hasToSnap: Bool

  private init(x: Int, y: Int, hasToSnap: Bool) {
    self.x = x
    self.y = y
    self.hasToSnap = hasToSnap
  }

  /// Mirrors Java's `Location.create`. When `hasToSnap` is true, coordinates are snapped by
  /// `(v / 5) * 5`.
  ///
  /// This is deliberately NOT "round to nearest multiple of 5". In Java the expression is
  /// `Math.round(x / 5) * 5`, where `x` and `5` are both `int`, so `x / 5` is *integer* division
  /// (truncating toward zero) evaluated first; `Math.round` is then handed an already-integral
  /// value and is a no-op. So e.g. snapping x = -3 gives 0 (not -5), and snapping x = -7 gives -5
  /// (not -5 "nearest", but -5 because -7/5 truncates to -1). Swift's `/` on `Int` also truncates
  /// toward zero (matching Java's `int / int`), so `(x / 5) * 5` reproduces this exactly,
  /// including the asymmetric snapping near zero for negative coordinates. Preserved verbatim per
  /// the fidelity requirement; see the deviation report for this file.
  /// Coordinates are truncated to 32 bits on entry, because Java's parameters are `int`. Every
  /// derived location routes through here, which is what keeps the whole type inside Java's
  /// range rather than silently drifting into 64-bit values Java cannot represent.
  public static func create(_ x: Int, _ y: Int, hasToSnap: Bool) -> Location {
    let x32 = wrap32(x)
    let y32 = wrap32(y)
    // Java: `Math.round(x / 5) * 5`. Integer division first (truncating toward zero, which
    // Swift's `/` matches), then a float-widening Math.round that loses precision above 2^24,
    // then an int multiply that wraps.
    let xRounded = hasToSnap ? wrap32(javaMathRoundOfInt(x32 / 5) &* 5) : x32
    let yRounded = hasToSnap ? wrap32(javaMathRoundOfInt(y32 / 5) &* 5) : y32
    return Location(x: xRounded, y: yRounded, hasToSnap: hasToSnap)
  }

  /// Parses "(x,y)", "x,y", or "x y" (whitespace-trimmed), matching Java's `Location.parse`.
  /// Always snaps the result (Java always calls `Location.create(x, y, true)` here).
  public static func parse(_ value: String) throws -> Location {
    let base = value
    var s = javaTrim(value)
    if s.first == "(" {
      guard s.last == ")" else {
        throw ParseError(message: "invalid point '\(base)'")
      }
      s = String(s.dropFirst().dropLast())
    }
    s = javaTrim(s)

    var sep = s.firstIndex(of: ",")
    if sep == nil {
      sep = s.firstIndex(of: " ")
    }
    guard let sepIndex = sep else {
      throw ParseError(message: "invalid point '\(base)'")
    }

    let xPart = javaTrim(s[s.startIndex..<sepIndex])
    let yPart = javaTrim(s[s.index(after: sepIndex)...])
    guard let x = javaParseInt32(xPart), let y = javaParseInt32(yPart) else {
      throw ParseError(message: "invalid point '\(base)'")
    }
    return Location.create(x, y, hasToSnap: true)
  }

  public func manhattanDistance(toX x: Int, y: Int) -> Int {
    wrap32(wrap32(abs(wrap32(x &- self.x))) &+ wrap32(abs(wrap32(y &- self.y))))
  }

  public func manhattanDistance(to other: Location) -> Int {
    wrap32(wrap32(abs(wrap32(other.x &- x))) &+ wrap32(abs(wrap32(other.y &- y))))
  }

  /// Rotates this point around (xc, yc), assuming this point currently faces `from` and the
  /// result should face `to`. Mirrors Java's `Location.rotate` exactly, including that any
  /// delta other than 90/180/270 degrees (i.e. 0) leaves the point unchanged.
  public func rotate(from: Direction, to: Direction, xc: Int, yc: Int) -> Location {
    var degrees = to.toDegrees() - from.toDegrees()
    while degrees >= 360 { degrees -= 360 }
    while degrees < 0 { degrees += 360 }

    let dx = wrap32(x &- xc)
    let dy = wrap32(y &- yc)
    switch degrees {
    case 90:
      return Location.create(wrap32(xc &+ dy), wrap32(yc &- dx), hasToSnap: hasToSnap)
    case 180:
      return Location.create(wrap32(xc &- dx), wrap32(yc &- dy), hasToSnap: hasToSnap)
    case 270:
      return Location.create(wrap32(xc &- dy), wrap32(yc &+ dx), hasToSnap: hasToSnap)
    default:
      return self
    }
  }

  /// Mirrors Java's two-arg `translate(Direction, int)`, which is `translate(dir, dist, 0)`.
  public func translate(_ dir: Direction, _ dist: Int, _ right: Int = 0) -> Location {
    if dist == 0 && right == 0 { return self }
    switch dir {
    case .east: return Location.create(wrap32(x &+ dist), wrap32(y &+ right), hasToSnap: hasToSnap)
    case .west: return Location.create(wrap32(x &- dist), wrap32(y &- right), hasToSnap: hasToSnap)
    case .south: return Location.create(wrap32(x &- right), wrap32(y &+ dist), hasToSnap: hasToSnap)
    case .north: return Location.create(wrap32(x &+ right), wrap32(y &- dist), hasToSnap: hasToSnap)
    }
  }

  public func translate(_ dx: Int, _ dy: Int) -> Location {
    if dx == 0 && dy == 0 { return self }
    return Location.create(wrap32(x &+ dx), wrap32(y &+ dy), hasToSnap: hasToSnap)
  }

  // MARK: - Comparable / Equatable / Hashable
  //
  // Implemented by hand (rather than synthesized) because `hasToSnap` must NOT participate,
  // exactly matching Java's `Location.equals`/`hashCode`/`compareTo` (all of which read only
  // x and y).

  public static func < (lhs: Location, rhs: Location) -> Bool {
    // Equivalent to Java's `compareTo`'s sign (`x != other.x ? x - other.x : y - other.y`),
    // without replicating its integer-subtraction overflow behavior: Swift's `Int` is 64-bit
    // and these are pixel/grid coordinates, so no in-range value can trigger the difference.
    return (lhs.x != rhs.x) ? (lhs.x < rhs.x) : (lhs.y < rhs.y)
  }

  public static func == (lhs: Location, rhs: Location) -> Bool {
    return lhs.x == rhs.x && lhs.y == rhs.y
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(x)
    hasher.combine(y)
  }

  public var description: String {
    return "(\(x),\(y))"
  }
}

// MARK: - Location.At / CompareHorizontal / CompareVertical
//
// Java nests `At` and the two `Comparator<At>` singletons inside `Location`. Swift does not
// allow nested protocol declarations, so `LocationAt` is top-level here. It is constrained to
// `AnyObject` because Java's tiebreak, when two elements sit at the exact same point, falls back
// to `Object.hashCode()`; an identity hash. `ObjectIdentifier` is the closest Swift analogue of
// that fallback; the *resulting order* will not match Java's (identity hashes are
// runtime-assigned and were never meant to be stable across processes, let alone languages);
// only the role of "deterministic-but-arbitrary tiebreak among exact ties" is preserved, which is
// all this was ever used for (stable display/paint ordering), never simulation-affecting logic.

/// Anything with an associated `Location`, mirroring Java's `Location.At` interface.
public protocol LocationAt: AnyObject {
  var location: Location { get }
}

extension Location {
  /// Left before right; ties broken top before bottom; remaining ties broken by identity.
  /// Mirrors Java's `Location.CompareHorizontal`.
  public static func compareHorizontal(_ a: LocationAt, _ b: LocationAt) -> Int {
    let aloc = a.location
    let bloc = b.location
    if aloc.x != bloc.x { return wrap32(aloc.x &- bloc.x) }
    if aloc.y != bloc.y { return wrap32(aloc.y &- bloc.y) }
    return ObjectIdentifier(a).hashValue &- ObjectIdentifier(b).hashValue
  }

  /// Top before bottom; ties broken left before right; remaining ties broken by identity.
  /// Mirrors Java's `Location.CompareVertical`.
  public static func compareVertical(_ a: LocationAt, _ b: LocationAt) -> Int {
    let aloc = a.location
    let bloc = b.location
    if aloc.y != bloc.y { return wrap32(aloc.y &- bloc.y) }
    if aloc.x != bloc.x { return wrap32(aloc.x &- bloc.x) }
    return ObjectIdentifier(a).hashValue &- ObjectIdentifier(b).hashValue
  }

  /// Mirrors Java's `Location.sortHorizontal`.
  public static func sortHorizontal<T: LocationAt>(_ list: inout [T]) {
    list.sort { compareHorizontal($0, $1) < 0 }
  }

  /// Mirrors Java's `Location.sortVertical`.
  public static func sortVertical<T: LocationAt>(_ list: inout [T]) {
    list.sort { compareVertical($0, $1) < 0 }
  }
}
