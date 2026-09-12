//
//  Value.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
//  specifically `src/main/java/com/cburch/logisim/data/Value.java`.
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  Portions of `fromLogString` / `radixOfLogString` / `compatible` originate in Cornell's
//  version of Logisim (http://www.cs.cornell.edu/courses/cs3410/2015sp/), as noted upstream.
//
//  ===========================================================================================
//  PORT NOTES; read before changing anything here.
//
//  This is a *fidelity* port. Where the Java has a bug, the bug is reproduced and marked
//  `JAVA QUIRK`. Do not "fix" one without a corresponding entry in docs/decisions.md.
//
//  Structural decisions (all forced by docs/decisions.md):
//
//  1. `Value` is a `struct`, and the interning `Cache` at Value.java:309 is dropped. That
//     cache is a Java allocation optimisation; a 24-byte Swift struct makes it moot.
//     Consequence: Java's many `==` *reference* comparisons against the singletons become
//     structural comparisons. This is behaviour-preserving for the real codebase; see the
//     "Reference identity" note below, but it is the one place where an adversarially
//     constructed `create_unsafe` value could diverge.
//
//  2. D9: LogisimKernel is UI-free. `Value.getColor()` and the twelve `java.awt.Color`
//     statics at Value.java:296-307 are NOT ported. `paletteIndex` returns a `ValuePalette`
//     case instead; the renderer owns the index -> colour mapping.
//
//  3. D9: no `AppPreferences` reach-in. Value.java:284-288 reads the five display characters
//     from a global preference store. Here they are an explicit `DisplayCharacters`
//     parameter, defaulting to `.default`, which carries the Java preference defaults
//     ('1', '0', 'U', 'E', '-'). Radix is likewise always an explicit argument.
//
//  4. D1: Swift 5 language mode, no Swift Concurrency, Foundation-free (this file needs
//     nothing outside the standard library).
//
//  Integer semantics. Java `long` is signed 64-bit and `int` is signed 32-bit, both with
//  wrapping arithmetic and shift distances masked (mod 64 / mod 32). Swift's `<<`/`>>` are
//  "smart shifts" that saturate on over-shift and reverse on a negative distance, and its
//  `*`/`+` trap on overflow. Therefore:
//
//      Java `long` <<  ->  jshl(x, n)   (Int64, &<< with the distance masked to 0...63)
//      Java `long` >>  ->  jshr(x, n)   (Int64, arithmetic)
//      Java `long` >>> ->  jushr(x, n)  (via UInt64)
//      Java `int`  <<  ->  Int32 &<<    (distance masked to 0...31)
//      Java arithmetic ->  &* / &+ / &- (wrapping)
//
//  Reference identity. Java compares `this == FALSE`, `v == NIL`, `others == Value.ERROR`
//  and so on by reference. Those comparisons are only meaningful because `create` returns
//  the interned singletons for every width-0 and width-1 result. The one entry point that
//  can produce a *non*-interned narrow value is `create_unsafe`; its only call site in the
//  whole Java codebase is CircuitWires.java:377, which is guarded by an explicit
//  `width == 1` early return at CircuitWires.java:352 and only ever receives already-masked,
//  mutually-disjoint bit fields. So for every `Value` the real program can construct,
//  reference identity and structural equality coincide, and the struct port is exact.
//  ===========================================================================================
//

// MARK: - Java shift helpers

/// Java `long <<`. Java masks the shift distance to its low 6 bits; Swift's `<<` does not.
@inline(__always)
fileprivate func jshl(_ x: Int64, _ n: Int) -> Int64 {
  x &<< Int64(n & 63)
}

/// Java `long >>` (arithmetic), with Java's shift-distance masking.
@inline(__always)
fileprivate func jshr(_ x: Int64, _ n: Int) -> Int64 {
  x &>> Int64(n & 63)
}

/// Java `long >>>` (logical), with Java's shift-distance masking.
@inline(__always)
fileprivate func jushr(_ x: Int64, _ n: Int) -> Int64 {
  Int64(bitPattern: UInt64(bitPattern: x) &>> UInt64(n & 63))
}

/// Reproduces the *int-arithmetic* mask expression `(w == 64 ? -1 : ~(-1 << w))` used at
/// Value.java:383-384, including its widening to `long` by sign extension.
///
/// JAVA QUIRK: those two lines use the `int` literal `-1`, not `-1L`, unlike every other
/// mask in the file (:32, :444, :679, :822 all use `-1L`). Java masks int shift distances to
/// 5 bits, so the mask is wrong for widths 32...63:
///
///     w = 31 -> 0x0000_0000_7FFF_FFFF   (correct)
///     w = 32 -> 0x0000_0000_0000_0000   (should be 0xFFFF_FFFF, so every bit reads "unknown")
///     w = 40 -> 0x0000_0000_0000_00FF   (should be 0xFF_FFFF_FFFF)
///     w = 64 -> 0xFFFF_FFFF_FFFF_FFFF   (correct, special-cased)
///
/// This only affects `combine(_:)`'s mismatched-width branch. It is reproduced verbatim.
@inline(__always)
fileprivate func javaIntWidthMask(_ width: Int) -> Int64 {
  if width == 64 { return -1 }
  let shifted = Int32(-1) &<< Int32(width & 31)
  return Int64(~shifted)  // Java's int -> long widening sign-extends.
}

// MARK: - Display characters

/// The five characters used to render individual bits.
///
/// Value.java:284-288 pulls these out of `AppPreferences` at class-initialisation time,
/// which would drag a 303-member global (and 287 files of transitive dependencies) into the
/// kernel. D9 forbids that, so they are passed in instead.
///
/// `.default` carries the Java preference defaults, i.e. the first character of
/// `SimTrueChar` = "1 ", `SimFalseChar` = "0 ", `SimUnknownChar` = "U ",
/// `SimErrorChar` = "E " and `SimDontCareChar` = "- ".
public struct DisplayCharacters: Equatable, Hashable, Sendable {
  public var trueChar: Character
  public var falseChar: Character
  public var unknownChar: Character
  public var errorChar: Character
  public var dontCareChar: Character

  public init(
    trueChar: Character = "1",
    falseChar: Character = "0",
    unknownChar: Character = "U",
    errorChar: Character = "E",
    dontCareChar: Character = "-"
  ) {
    self.trueChar = trueChar
    self.falseChar = falseChar
    self.unknownChar = unknownChar
    self.errorChar = errorChar
    self.dontCareChar = dontCareChar
  }

  /// Matches logisim-evolution's out-of-the-box preference values.
  public static let `default` = DisplayCharacters()
}

// MARK: - Palette index

/// Replaces the twelve `java.awt.Color` statics at Value.java:296-307. The kernel names a
/// palette slot; `LogisimRender` owns the slot -> colour table, so the kernel stays UI-free
/// (D9) and the per-frame palette stays a small array of indices (D6).
///
/// `Value.paletteIndex` only ever produces `.error`, `.nilValue`, `.unknown`, `.trueValue`,
/// `.falseValue` or `.multi`; the remaining cases exist so the render module has one
/// canonical enumeration of the simulation palette rather than a second, divergent one.
public enum ValuePalette: Int, Hashable, CaseIterable, Sendable {
  /// Java: `Value.falseColor`.
  case falseValue = 0
  /// Java: `Value.trueColor`.
  case trueValue = 1
  /// Java: `Value.unknownColor`.
  case unknown = 2
  /// Java: `Value.errorColor`.
  case error = 3
  /// Java: `Value.nilColor`.
  case nilValue = 4
  /// Java: `Value.strokeColor`.
  case stroke = 5
  /// Java: `Value.multiColor` (a multi-bit bus).
  case multi = 6
  /// Java: `Value.widthErrorColor`.
  case widthError = 7
  /// Java: `Value.widthErrorCaptionColor`.
  case widthErrorCaption = 8
  /// Java: `Value.widthErrorHighlightColor`.
  case widthErrorHighlight = 9
  /// Java: `Value.widthErrorCaptionBgcolor`.
  case widthErrorCaptionBackground = 10
  /// Java: `Value.clockFrequencyColor`.
  case clockFrequency = 11
}

// MARK: - Errors

/// Thrown by `Value.fromLogString(_:_:)`, which is the only `Value` method that raises a
/// *checked* exception in the Java (`throws Exception`). Every other Java throw in this file
/// is an unchecked `RuntimeException` / `IllegalArgumentException` and is reproduced here as
/// a trap, since those signal programmer error rather than bad data.
///
/// The associated string is byte-identical to the Java exception message.
public enum ValueLogStringError: Error, Equatable, CustomStringConvertible, Sendable {
  case message(String)

  public var description: String {
    switch self {
    case .message(let m): return m
    }
  }
}

// MARK: - Value

/// A tri-state-plus-error signal of width `0...64`, packed into three 64-bit planes.
///
/// A bit is in exactly one state, resolved with the precedence error > unknown > true/false:
/// bit *i* is an error if `error[i]`, otherwise unknown if `unknown[i]`, otherwise the
/// boolean `value[i]`. `create(width:error:unknown:value:)` enforces both that precedence
/// and that no plane has bits set at or above `width`.
// MARK: - Errors

/// Failures the Java raises as *catchable* exceptions (decisions.md D13).
///
/// `Simulator.java:520/533/556` wraps propagation in `catch (Exception err)` →
/// `recordException(err)`, so in the Java each of these surfaces as a circuit error the user
/// sees. Trapping instead would terminate the app and lose unsaved work, turning a recoverable
/// simulation fault into data loss. Every case below is reachable from an ordinary `.circ`
/// file, an over-wide bus, mismatched wire widths, a malformed `PullResistor` attribute,
/// so none of them is a programmer error that a `precondition` would be right to catch.
public enum ValueError: Error, CustomStringConvertible, Sendable {
  /// Java: `RuntimeException("Cannot have more than 64 bits in a value")`.
  case tooManyBits(count: Int, max: Int)
  /// Java: `RuntimeException("unrecognized value …")`; an element that is not a one-bit singleton.
  case unrecognizedValue(Value)
  /// Java: `IllegalArgumentException("first parameter must be one bit")`.
  case notOneBit(width: Int)
  /// Java: `NegativeArraySizeException` from `new Value[bits]`.
  case negativeRepeatCount(Int)
  /// Java: `IllegalArgumentException("INTERNAL ERROR: mismatched widths …")`.
  case mismatchedWidths(expected: Int, found: Int)
  /// Java: `IllegalArgumentException("pull value must be 1, 0, X, or E")`.
  case invalidPullValue(Value)
  /// Java: `RuntimeException("Cannot set multiple values")`.
  case cannotSetMultipleValues(width: Int)
  /// Java: `RuntimeException("Attempt to set outside value's width")`.
  case setOutsideWidth(index: Int, width: Int)

  public var description: String {
    switch self {
    case let .tooManyBits(count, max): "Cannot have more than \(max) bits in a value (got \(count))"
    case let .unrecognizedValue(v): "unrecognized value \(v)"
    case let .notOneBit(width): "first parameter must be one bit (got width \(width))"
    case let .negativeRepeatCount(n): "negative repeat count \(n)"
    case let .mismatchedWidths(expected, found):
      "INTERNAL ERROR: mismatched widths in Value.combineLikeWidths (expected \(expected), found \(found))"
    case let .invalidPullValue(v): "pull value must be 1, 0, X, or E (got \(v))"
    case let .cannotSetMultipleValues(width): "Cannot set multiple values (val width \(width))"
    case let .setOutsideWidth(index, width):
      "Attempt to set outside value's width (index \(index), width \(width))"
    }
  }
}

public struct Value: Hashable, CustomStringConvertible, Sendable {

  // MARK: Stored state

  /// Java: `private final int width`.
  public let width: Int
  /// Java: `private final long error`.
  public let error: Int64
  /// Java: `private final long unknown`.
  public let unknown: Int64
  /// Java: `private final long value`.
  public let value: Int64

  /// Java: the private `Value(int, long, long, long)` constructor. Kept private for the same
  /// reason: it performs no masking and no canonicalisation.
  private init(width: Int, error: Int64, unknown: Int64, value: Int64) {
    self.width = width
    self.error = error
    self.unknown = unknown
    self.value = value
  }

  // MARK: Constants

  /// Java: `Value.MAX_WIDTH`.
  public static let maxWidth: Int = 64

  /// Java: `Value.FALSE`.
  public static let falseValue = Value(width: 1, error: 0, unknown: 0, value: 0)
  /// Java: `Value.TRUE`.
  public static let trueValue = Value(width: 1, error: 0, unknown: 0, value: 1)
  /// Java: `Value.UNKNOWN`.
  public static let unknownValue = Value(width: 1, error: 0, unknown: 1, value: 0)
  /// Java: `Value.ERROR`.
  public static let errorValue = Value(width: 1, error: 1, unknown: 0, value: 0)
  /// Java: `Value.NIL`, the zero-width value.
  public static let nilValue = Value(width: 0, error: 0, unknown: 0, value: 0)

  // MARK: Factories

  /// Java: the *private* `Value.create(int, long, long, long)` at Value.java:23.
  ///
  /// Made `public` here because the task brief lists it as part of the ported surface and
  /// because Swift has no exact analogue of Java's package-private-plus-nested-access rules.
  /// It is the canonicalising constructor: width 0 collapses to `.nilValue`, width 1 to one
  /// of the four singletons, and wider values are masked so that (a) no plane carries bits
  /// at or above `width` and (b) the planes are mutually disjoint under the precedence
  /// error > unknown > value.
  public static func create(width: Int, error: Int64, unknown: Int64, value: Int64) -> Value {
    if width == 0 {
      return .nilValue
    } else if width == 1 {
      if (error & 1) != 0 { return .errorValue }
      else if (unknown & 1) != 0 { return .unknownValue }
      else if (value & 1) != 0 { return .trueValue }
      else { return .falseValue }
    } else {
      let mask: Int64 = (width == 64 ? -1 : ~jshl(-1, width))
      let e = error & mask
      let u = unknown & mask & ~e
      let v = value & mask & ~u & ~e
      // The Java consults `cache` here (Value.java:37-48). Dropped by decision: interning is
      // a Java allocation optimisation and this is a struct.
      return Value(width: width, error: e, unknown: u, value: v)
    }
  }

  /// Java: `Value.create_unsafe(int, long, long, long)`.
  ///
  /// Performs no masking and no canonicalisation; the caller promises the planes are
  /// already masked to `width` and mutually disjoint. Its sole Java caller
  /// (CircuitWires.State.recalculate) satisfies that by construction and is additionally
  /// guarded so `width >= 2`.
  ///
  /// In the Java this exists purely to skip the cache lookup; here it is retained for
  /// surface fidelity and because it documents the caller's contract. It is *not* an
  /// optimisation in Swift.
  public static func createUnsafe(width: Int, error: Int64, unknown: Int64, value: Int64) -> Value {
    Value(width: width, error: error, unknown: unknown, value: value)
  }

  /// Java: `Value.create(Value[])`. Bit *i* of the result comes from `values[i]`, i.e.
  /// index 0 is the least significant bit.
  ///
  /// The Java throws `RuntimeException` for an over-wide array or an element that is not one
  /// of the four one-bit singletons. Those are catchable and reach `recordException`, so this
  /// throws rather than trapping (D13).
  public static func create(_ values: [Value]) throws -> Value {
    if values.isEmpty { return .nilValue }
    // JAVA QUIRK: a one-element array is returned as-is, without any check that the element
    // is one bit wide. `create([someWidth8Value])` yields that width-8 value unchanged.
    if values.count == 1 { return values[0] }
    if values.count > maxWidth {
      throw ValueError.tooManyBits(count: values.count, max: maxWidth)
    }

    let width = values.count
    var value: Int64 = 0
    var unknown: Int64 = 0
    var error: Int64 = 0
    for i in 0..<values.count {
      let mask = jshl(1, i)
      let v = values[i]
      if v == .trueValue { value |= mask }
      else if v == .falseValue { /* do nothing */ }
      else if v == .unknownValue { unknown |= mask }
      else if v == .errorValue { error |= mask }
      else {
        throw ValueError.unrecognizedValue(v)
      }
    }
    return Value.create(width: width, error: error, unknown: unknown, value: value)
  }

  /// Java: `Value.createError(BitWidth)`.
  public static func createError(_ bits: BitWidth) -> Value {
    Value.create(width: bits.width, error: -1, unknown: 0, value: 0)
  }

  /// Java: `Value.createUnknown(BitWidth)`.
  public static func createUnknown(_ bits: BitWidth) -> Value {
    Value.create(width: bits.width, error: 0, unknown: -1, value: 0)
  }

  /// Java: `Value.createKnown(BitWidth, long)`.
  public static func createKnown(_ bits: BitWidth, _ value: Int64) -> Value {
    Value.create(width: bits.width, error: 0, unknown: 0, value: value)
  }

  /// Java: `Value.createKnown(int, long)`: "Added to test", per the upstream comment.
  public static func createKnown(_ bits: Int, _ value: Int64) -> Value {
    Value.create(width: bits, error: 0, unknown: 0, value: value)
  }

  /// Java: `Value.createKnown(float)`; a 32-bit value holding the IEEE-754 binary32 bits.
  ///
  /// Java uses `Float.floatToIntBits`, *not* the raw variant, so every NaN collapses to the
  /// canonical quiet NaN `0x7FC00000`.
  public static func createKnownFloat(_ value: Float) -> Value {
    Value.create(width: 32, error: 0, unknown: 0,
                 value: Int64(Int32(bitPattern: JavaFloatBits.floatToIntBits(value))))
  }

  /// Java: `Value.createKnown(double)`; a 64-bit value holding the IEEE-754 binary64 bits.
  ///
  /// Java uses `Double.doubleToLongBits`, so every NaN collapses to `0x7FF8000000000000`.
  public static func createKnownFloat(_ value: Double) -> Value {
    Value.create(width: 64, error: 0, unknown: 0,
                 value: JavaFloatBits.doubleToLongBits(value))
  }

  /// Java: `Value.createKnown(BitWidth, double)`.
  public static func createKnownFloat(_ bits: BitWidth, _ value: Double) -> Value {
    createKnownFloat(bits.width, value)
  }

  /// Java: `Value.createKnown(int, double)`: encodes `value` in the floating-point format
  /// of the requested width.
  ///
  /// JAVA QUIRK: the default arm returns `Value.ERROR`, the *one-bit* error singleton, not
  /// an error value of width `bits`.
  public static func createKnownFloat(_ bits: Int, _ value: Double) -> Value {
    switch bits {
    case 8:
      // byte -> long in Java widens with sign extension; `create` masks it back down.
      return Value.createKnown(8, Int64(MiniFloat.floatToMiniFloat143(JavaFloatBits.doubleToFloat(value))))
    case 16:
      // short -> long likewise sign-extends before `create` masks.
      return Value.createKnown(16, Int64(JavaFloatBits.floatToFloat16(JavaFloatBits.doubleToFloat(value))))
    case 32:
      return Value.createKnownFloat(JavaFloatBits.doubleToFloat(value))
    case 64:
      return Value.createKnownFloat(value)
    default:
      return .errorValue
    }
  }

  // MARK: Log-string parsing

  /// Java: `Value.fromLogString(BitWidth, String)`.
  ///
  /// Accepts `0x…` hex, `0o…` octal, `0b…` binary, bare binary when the digit count equals
  /// the bit width, and signed decimal otherwise. `x` denotes an unknown digit in every
  /// radix except 10. Underscores are stripped first, for readability.
  ///
  /// The Java declares `throws Exception`; the messages are reproduced verbatim because they
  /// surface in the test-vector loader (TestVector.java:176).
  public static func fromLogString(_ width: BitWidth, _ t: String) throws -> Value {
    // Strip underscores (e.g. 0x0000_1111 -> 0x00001111). Must happen before radix
    // detection, since radixOfLogString compares against the string length.
    let cleanedChars = Array(t).filter { $0 != "_" }
    let cleaned = String(cleanedChars)

    let radix = radixOfLogString(width, cleaned)
    let offset: Int
    if radix == 16 && cleaned.hasPrefix("0x") { offset = 2 }
    else if radix == 8 && cleaned.hasPrefix("0o") { offset = 2 }
    else if radix == 2 && cleaned.hasPrefix("0b") { offset = 2 }
    else if radix == 10 && cleaned.hasPrefix("-") { offset = 1 }
    else { offset = 0 }

    let n = cleanedChars.count
    if n <= offset {
      throw ValueLogStringError.message("expected digits")
    }

    let w = width.width
    var value: Int64 = 0
    var unknown: Int64 = 0

    for i in offset..<n {
      let c = cleanedChars[i]
      let d: Int64

      if c == "x" && radix != 10 { d = -1 }
      else if let a = c.asciiValue, a >= 0x30, a <= 0x39 { d = Int64(a - 0x30) }          // '0'...'9'
      else if let a = c.asciiValue, a >= 0x61, a <= 0x66 { d = Int64(0xa + (a - 0x61)) }  // 'a'...'f'
      else if let a = c.asciiValue, a >= 0x41, a <= 0x46 { d = Int64(0xA + (a - 0x41)) }  // 'A'...'F'
      else {
        throw ValueLogStringError.message("Unexpected character '\(c)' in \"\(t)\"")
      }

      if d >= Int64(radix) {
        throw ValueLogStringError.message("Unexpected character '\(c)' in \"\(t)\"")
      }

      value = value &* Int64(radix)
      unknown = unknown &* Int64(radix)

      if radix != 10 {
        if d == -1 { unknown |= Int64(radix - 1) } else { value |= d }
      } else {
        if d == -1 { unknown = unknown &+ Int64(radix - 1) } else { value = value &+ d }
      }
    }
    if radix == 10 && cleanedChars[0] == "-" {
      value = 0 &- value
    }

    // Bit-width check. For signed values the range is checked instead of using a shift.
    if w == 64 {
      // JAVA QUIRK: dead code. Clearing the sign bit makes the operand non-negative, so
      // `>> 63` is always 0 and this branch can never throw. Reproduced as-is.
      if jshr(value & 0x7FFF_FFFF_FFFF_FFFF, w - 1) != 0 {
        let actualBits = 64 - (value & 0x7FFF_FFFF_FFFF_FFFF).leadingZeroBitCount
        throw ValueLogStringError.message(
          "Too many bits in \"\(t)\" expected \(w) bit\(w != 1 ? "s" : "")"
            + (actualBits > 0 ? " did you mean [\(actualBits)]?" : ""))
      }
    } else {
      if radix == 10 {
        // Does the value fit the w-bit signed range?
        let maxPositive = jshl(1, w - 1) &- 1
        let minNegative = 0 &- jshl(1, w - 1)
        if value > maxPositive || value < minNegative {
          let absValue = value < 0 ? (0 &- value) : value
          let actualBits = absValue == 0 ? 1 : 64 - absValue.leadingZeroBitCount + 1  // +1 for the sign bit
          throw ValueLogStringError.message(
            "Too many bits in \"\(t)\" expected \(w) bit\(w != 1 ? "s" : "")"
              + (actualBits > 0 ? " did you mean [\(actualBits)]?" : ""))
        }
        // Mask to width (two's complement representation).
        let mask = jshl(1, w) &- 1
        value &= mask
      } else {
        // Unsigned (hex, octal, binary): a plain shift check suffices.
        if jshr(value, w) != 0 {
          var actualBits = value == 0 ? 1 : 64 - value.leadingZeroBitCount
          var reminder = ""

          if radix == 16 && cleanedChars.count > 2 {
            // Each hex digit is 4 bits.
            actualBits = (cleanedChars.count - 2) * 4
            reminder = " Remember that 0x means hex and each hex digit is 4 bits"
          } else if radix == 2 && cleanedChars.count > 0 {
            // Each binary digit is 1 bit.
            actualBits = cleanedChars.count - (cleaned.hasPrefix("0b") ? 2 : 0)
            reminder = " Remember that 0b means binary and each binary digit is 1 bit"
          } else if radix == 8 && cleanedChars.count > 2 {
            // Each octal digit is 3 bits.
            actualBits = (cleanedChars.count - 2) * 3
            reminder = " Remember that 0o means octal and each octal digit is 3 bits"
          }

          throw ValueLogStringError.message(
            "Too many bits in \"\(t)\" expected \(w) bit\(w != 1 ? "s" : "")"
              + (actualBits > 0 ? " did you mean [\(actualBits)]?" : "") + reminder)
        }
      }
    }

    // JAVA QUIRK: for w == 64 this is `(1L << 64) - 1`, and Java masks the shift distance to
    // 0, giving `1 - 1 == 0`. Every unknown bit of a 64-bit log string is therefore silently
    // discarded. Reproduced.
    unknown &= jshl(1, w) &- 1
    return create(width: w, error: 0, unknown: unknown, value: value)
  }

  /// Java: `Value.radixOfLogString(BitWidth, String)`.
  ///
  /// Note the bare-binary rule: a string whose length happens to equal the bit width is read
  /// as binary regardless of its digits, so with a 3-bit width `"123"` parses as binary and
  /// then fails on the digit check.
  public static func radixOfLogString(_ width: BitWidth, _ t: String) -> Int {
    if t.hasPrefix("0x") { return 16 }
    if t.hasPrefix("0o") { return 8 }
    if t.hasPrefix("0b") { return 2 }
    if t.count == width.width { return 2 }
    return 10
  }

  // MARK: Replication

  /// Java: `Value.repeat(Value, BitWidth)`.
  public static func `repeat`(_ base: Value, _ width: BitWidth) throws -> Value {
    try Value.repeat(base, width.width)
  }

  /// Java: `Value.repeat(Value, int)`; widen a one-bit value by replication.
  ///
  /// The Java throws `IllegalArgumentException` when `base` is not one bit, and
  /// `NegativeArraySizeException` from `new Value[bits]` for a negative count. Both are
  /// catchable, so this throws rather than trapping (D13).
  public static func `repeat`(_ base: Value, _ bits: Int) throws -> Value {
    if base.width != 1 {
      throw ValueError.notOneBit(width: base.width)
    }
    if bits == 1 {
      return base
    } else {
      guard bits >= 0 else { throw ValueError.negativeRepeatCount(bits) }
      return try create(Array(repeating: base, count: bits))
    }
  }

  // MARK: Logic

  /// Java: `Value.and(Value)`.
  ///
  /// JAVA QUIRK (the wide branch): the result's width is `max` of the two widths, but the
  /// operands' planes are never masked to their own widths first. `false0`/`false1` therefore
  /// have every bit above their operand's width set, which is what makes the narrower operand
  /// contribute "false", and hence a hard 0, in the extra bit positions.
  public func and(_ other: Value?) -> Value {
    guard let other else { return self }
    if self.width == 1 && other.width == 1 {
      if self == .falseValue || other == .falseValue { return .falseValue }
      if self == .trueValue && other == .trueValue { return .trueValue }
      return .errorValue
    } else {
      let false0 = ~self.value & ~self.error & ~self.unknown
      let false1 = ~other.value & ~other.error & ~other.unknown
      let falses = false0 | false1
      return Value.create(
        width: max(self.width, other.width),
        error: (self.error | other.error | self.unknown | other.unknown) & ~falses,
        unknown: 0,
        value: self.value & other.value)
    }
  }

  /// Java: `Value.or(Value)`.
  public func or(_ other: Value?) -> Value {
    guard let other else { return self }
    if self.width == 1 && other.width == 1 {
      if self == .trueValue || other == .trueValue { return .trueValue }
      if self == .falseValue && other == .falseValue { return .falseValue }
      return .errorValue
    } else {
      let true0 = self.value & ~self.error & ~self.unknown
      let true1 = other.value & ~other.error & ~other.unknown
      let trues = true0 | true1
      return Value.create(
        width: max(self.width, other.width),
        error: (self.error | other.error | self.unknown | other.unknown) & ~trues,
        unknown: 0,
        value: self.value | other.value)
    }
  }

  /// Java: `Value.xor(Value)`.
  ///
  /// Note that the narrow branch tests `width <= 1` on *both* operands, so `NIL` reaches it
  /// and yields `ERROR`; `and`/`or` test `width == 1` instead and send `NIL` down the wide
  /// branch. That asymmetry is upstream's, and is preserved.
  public func xor(_ other: Value?) -> Value {
    guard let other else { return self }
    if self.width <= 1 && other.width <= 1 {
      if self == .errorValue || other == .errorValue { return .errorValue }
      if self == .unknownValue || other == .unknownValue { return .errorValue }
      if self == .nilValue || other == .nilValue { return .errorValue }
      if (self == .trueValue) == (other == .trueValue) { return .falseValue }
      return .trueValue
    } else {
      return Value.create(
        width: max(self.width, other.width),
        error: self.error | other.error | self.unknown | other.unknown,
        unknown: 0,
        value: self.value ^ other.value)
    }
  }

  /// Java: `Value.not()`.
  ///
  /// JAVA QUIRK: the narrow branch is `width <= 1`, so `NIL.not()` is `ERROR`, not `NIL`.
  public func not() -> Value {
    if width <= 1 {
      if self == .trueValue { return .falseValue }
      if self == .falseValue { return .trueValue }
      return .errorValue
    } else {
      return Value.create(width: self.width,
                          error: self.error | self.unknown,
                          unknown: 0,
                          value: ~self.value)
    }
  }

  /// Java: `Value.controls(Value)`; a tri-state buffer: `self` is the enable, `other` the
  /// data.
  ///
  /// Returns `nil` when `other` is `nil`, exactly as the Java returns `null`. (This is the
  /// only method in the file that propagates null rather than absorbing it.)
  public func controls(_ other: Value?) -> Value? {
    guard let other else { return nil }
    if self.width == 1 {
      if self == .falseValue {
        return Value.create(width: other.width, error: 0, unknown: -1, value: 0)
      }
      // An unknown enable passes the data through unchanged, same as a true enable.
      if self == .trueValue || self == .unknownValue { return other }
      return Value.create(width: other.width, error: -1, unknown: 0, value: 0)
    } else if self.width != other.width {
      return Value.create(width: other.width, error: -1, unknown: 0, value: 0)
    } else {
      let enabled = (self.value | self.unknown) & ~self.error
      let disabled = ~self.value & ~self.unknown & ~self.error
      return Value.create(
        width: other.width,
        error: self.error | (other.error & ~disabled),
        unknown: disabled | other.unknown,
        value: enabled & other.value)
    }
  }

  /// Java: `Value.combine(Value)`; resolve two drivers onto the same wire.
  ///
  /// Equal widths: bits where both drivers are known and disagree become errors, a bit is
  /// unknown only if both drivers leave it unknown, and any existing error propagates.
  ///
  /// Mismatched widths take a separate branch that computes per-operand "known" masks. That
  /// branch carries the int-shift defect described on `javaIntWidthMask`.
  public func combine(_ other: Value?) -> Value {
    guard let other else { return self }
    if self == .nilValue { return other }
    if other == .nilValue { return self }
    if self.width == 1 && other.width == 1 {
      if self == other { return self }
      if self == .unknownValue { return other }
      if other == .unknownValue { return self }
      return .errorValue
    } else if self.width == other.width {
      let disagree = (self.value ^ other.value) & ~(self.unknown | other.unknown)
      return Value.create(
        width: width,
        error: self.error | other.error | disagree,
        unknown: self.unknown & other.unknown,
        value: self.value | other.value)
    } else {
      let thisKnown = ~self.unknown & javaIntWidthMask(self.width)
      let otherKnown = ~other.unknown & javaIntWidthMask(other.width)
      let disagree = (self.value ^ other.value) & thisKnown & otherKnown
      return Value.create(
        width: max(self.width, other.width),
        error: self.error | other.error | disagree,
        unknown: ~thisKnown & ~otherKnown,
        value: self.value | other.value)
    }
  }

  /// Java: `Value.combineLikeWidths(int, BusConnection[])`.
  ///
  /// DEVIATION (signature). The Java takes `CircuitWires.BusConnection[]` and reads exactly
  /// one field from each element, the nullable `drivenValue` (`null` for sinks). Nothing else
  /// about `BusConnection`, its component, location, `isSink` or `isBidirectional`, is
  /// touched. `CircuitWires` is not ported yet, so rather than forward-declare a type this
  /// method takes the driven values directly. The call site (CircuitWires.java:1234) becomes
  /// `Value.combineLikeWidths(width: vb.width, drivenValues: vb.connections.map(\.drivenValue))`
  /// or, better, a loop that avoids the intermediate array.
  ///
  /// Semantics preserved exactly, including that only the first non-nil, non-NIL entry starts
  /// the fold (so the outer scan runs at most once) and that the *first* entry's width is
  /// never checked; only later ones are.
  ///
  /// The Java throws `IllegalArgumentException` on a width mismatch. Despite the "INTERNAL
  /// ERROR" wording it is reachable from an ordinary circuit that connects wires of differing
  /// widths, and it is catchable, so this throws (D13).
  public static func combineLikeWidths(width: Int, drivenValues vals: [Value?]) throws -> Value {
    let n = vals.count
    for i in 0..<n {
      guard let first = vals[i], first != .nilValue else { continue }
      var error = first.error
      var unknown = first.unknown
      var value = first.value
      for j in (i + 1)..<n {
        guard let v = vals[j], v != .nilValue else { continue }
        if v.width != width {
          throw ValueError.mismatchedWidths(expected: width, found: v.width)
        }
        let disagree = (value ^ v.value) & ~(unknown | v.unknown)
        error |= v.error | disagree
        unknown &= v.unknown
        value |= v.value
      }
      return Value.create(width: width, error: error, unknown: unknown, value: value)
    }
    return Value.createUnknown(try BitWidth.create(width))
  }

  /// Java: `Value.pullTowardsBits(Value)`; wherever `self` is unknown, take `other`'s bit.
  public func pullTowardsBits(_ other: Value) -> Value {
    if width <= 0 || unknown == 0 || other.width <= 0 { return self }
    let e = error | (unknown & other.error)
    let v = value | (unknown & other.value)
    let u = unknown & (other.unknown | (other.width == 64 ? 0 : jshl(-1, other.width)))
    return Value.create(width: width, error: e, unknown: u, value: v)
  }

  /// Java: `Value.pullEachBitTowards(Value)`; wherever `self` is unknown, take the single
  /// bit `bit`.
  ///
  /// The Java throws `IllegalArgumentException` for anything that is not one of the four
  /// one-bit singletons; unchecked, so this traps.
  public func pullEachBitTowards(_ bit: Value) throws -> Value {
    if width <= 0 || unknown == 0 || bit.width <= 0 { return self }
    if bit == .errorValue {
      return Value.create(width: width, error: error | unknown, unknown: 0, value: value)
    } else if bit == .trueValue {
      return Value.create(width: width, error: error, unknown: 0, value: value | unknown)
    } else if bit == .falseValue {
      return Value.create(width: width, error: error, unknown: 0, value: value | 0)
    } else if bit == .unknownValue {
      return self
    } else {
      throw ValueError.invalidPullValue(bit)
    }
  }

  // MARK: Comparison

  /// Java: `Value.compatible(Value)`.
  ///
  /// Where `self` is defined, `other` must match; where `self` is unknown, `other` may be
  /// anything; where `self` is an error, `other` must have the same error bits.
  public func compatible(_ other: Value) -> Bool {
    self.width == other.width
      && self.error == other.error
      && self.value == (other.value & ~self.unknown)
      && self.unknown == (other.unknown | self.unknown)
  }

  /// Java: `Value.equals(Object)`: a field-by-field comparison of all four members.
  public static func == (lhs: Value, rhs: Value) -> Bool {
    lhs.width == rhs.width
      && lhs.error == rhs.error
      && lhs.unknown == rhs.unknown
      && lhs.value == rhs.value
  }

  /// Java: `Value.hashcode(int, long, long, long)` / `Value.hashCode()`. Reproduced exactly,
  /// including Java's wrapping 32-bit arithmetic, so hashes can be compared across the
  /// differential harness.
  public var javaHashCode: Int32 {
    var h = Int32(truncatingIfNeeded: width)
    h = 31 &* h &+ Int32(truncatingIfNeeded: error ^ jushr(error, 32))
    h = 31 &* h &+ Int32(truncatingIfNeeded: unknown ^ jushr(unknown, 32))
    h = 31 &* h &+ Int32(truncatingIfNeeded: value ^ jushr(value, 32))
    return h
  }

  /// Consistent with `==` (which compares exactly the four stored fields), and seeded from
  /// `javaHashCode` so the bucket distribution matches Java's.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(javaHashCode)
  }

  /// Java: the static `Value.equal(Value, Value)`; nil and `NIL` are treated as the same
  /// thing.
  public static func equal(_ a: Value?, _ b: Value?) -> Bool {
    if (a == nil || a == .nilValue) && (b == nil || b == .nilValue) {
      return true  // both are effectively NIL
    }
    if let a, let b, a == b {
      return true  // both are the same non-NIL value
    }
    return false
  }

  // MARK: Accessors

  /// Java: `Value.extendWidth(int, Value)`: widen, filling the new high bits from `others`.
  ///
  /// JAVA QUIRK: `newWidth` is never checked against `width`; "extending" to a *narrower*
  /// width just truncates, because `create` masks. Also, anything other than ERROR/FALSE/TRUE
  /// for `others`, including `NIL` and any multi-bit value, takes the "unknown" arm.
  public func extendWidth(_ newWidth: Int, _ others: Value) -> Value {
    if width == newWidth { return self }
    let maskInverse: Int64 = (width == 64 ? 0 : jshl(-1, width))
    if others == .errorValue {
      return Value.create(width: newWidth, error: error | maskInverse, unknown: unknown, value: value)
    } else if others == .falseValue {
      return Value.create(width: newWidth, error: error, unknown: unknown, value: value)
    } else if others == .trueValue {
      return Value.create(width: newWidth, error: error, unknown: unknown, value: value | maskInverse)
    } else {
      return Value.create(width: newWidth, error: error, unknown: unknown | maskInverse, value: value)
    }
  }

  /// Java: `Value.get(int)`: bit `which` as a one-bit value. Out-of-range indices yield
  /// `ERROR` rather than trapping, which several callers rely on.
  public func get(_ which: Int) -> Value {
    if which < 0 || which >= width { return .errorValue }
    let mask = jshl(1, which)
    if (error & mask) != 0 { return .errorValue }
    else if (unknown & mask) != 0 { return .unknownValue }
    else if (value & mask) != 0 { return .trueValue }
    else { return .falseValue }
  }

  /// Java: `Value.getAll()`; index 0 is the least significant bit.
  public func getAll() -> [Value] {
    var ret = [Value]()
    ret.reserveCapacity(max(width, 0))
    for i in 0..<max(width, 0) {
      ret.append(get(i))
    }
    return ret
  }

  /// Java: `Value.getBitWidth()`: `BitWidth.create(width)`, which throws
  /// `IllegalArgumentException` when `width` is outside `0...64`.
  ///
  /// That is reachable: `createUnsafe` accepts any width (Java does too, and renders a
  /// 100-bit binary string for one), so a value built that way has no valid `BitWidth`.
  /// Throws rather than traps, matching Java (D13).
  public func getBitWidth() throws -> BitWidth {
    try BitWidth.create(width)
  }

  /// Java: `Value.getWidth()`. (`width` is also exposed directly as a stored property.)
  public func getWidth() -> Int { width }

  /// Replaces Java's `Value.getColor()`, which returns a `java.awt.Color`. D9 forbids the
  /// kernel from knowing about colours, so this names a palette slot instead. The branch
  /// structure is identical to the Java's.
  public var paletteIndex: ValuePalette {
    if error != 0 {
      return .error
    } else if width == 0 {
      return .nilValue
    } else if width == 1 {
      if self == .unknownValue { return .unknown }
      else if self == .trueValue { return .trueValue }
      else { return .falseValue }
    } else {
      return .multi
    }
  }

  /// Java: `Value.isErrorValue()`; true if *any* bit is an error.
  public func isErrorValue() -> Bool { error != 0 }

  /// Java: `Value.isFullyDefined()`.
  public func isFullyDefined() -> Bool { width > 0 && error == 0 && unknown == 0 }

  /// Java: `Value.isUnknown()`; every bit unknown and none in error.
  ///
  /// JAVA QUIRK: `NIL.isUnknown()` is `true`, because for width 0 the mask `(1 << 0) - 1`
  /// is 0 and NIL's `unknown` plane is 0.
  public func isUnknown() -> Bool {
    if width == 64 {
      return error == 0 && unknown == -1
    } else {
      return error == 0 && unknown == (jshl(1, width) &- 1)
    }
  }

  /// Java: `Value.set(int, Value)`; replace bit `which`.
  ///
  /// The Java throws `RuntimeException` for a multi-bit `val` or an out-of-range index. Both
  /// are catchable and reach `recordException`, so this throws (D13).
  ///
  /// Note the deliberate asymmetry with `get`, which returns `ERROR` for an out-of-range index
  /// rather than throwing. That is Java's behaviour and is preserved.
  public func set(_ which: Int, _ val: Value) throws -> Value {
    if val.width != 1 {
      throw ValueError.cannotSetMultipleValues(width: val.width)
    } else if which < 0 || which >= width {
      throw ValueError.setOutsideWidth(index: which, width: width)
    } else if width == 1 {
      return val
    } else {
      let mask = ~jshl(1, which)
      return Value.create(
        width: self.width,
        error: (self.error & mask) | jshl(val.error, which),
        unknown: (self.unknown & mask) | jshl(val.unknown, which),
        value: (self.value & mask) | jshl(val.value, which))
    }
  }

  // MARK: String rendering

  /// The single character for a one-bit (or NIL) value, shared by `toString`,
  /// `toBinaryString` and `toDisplayString`.
  @inline(__always)
  private func singleBitCharacter(_ chars: DisplayCharacters) -> Character {
    if width == 0 { return chars.dontCareChar }
    if error != 0 { return chars.errorChar }
    if unknown != 0 { return chars.unknownChar }
    if value != 0 { return chars.trueChar }
    return chars.falseChar
  }

  /// Java: `Value.toBinaryString()`: like `toDisplayString()` but with no nibble spacing.
  public func toBinaryString(chars: DisplayCharacters = .default) -> String {
    switch width {
    case 0:
      return String(chars.dontCareChar)
    case 1:
      return String(singleBitCharacter(chars))
    default:
      var ret = ""
      ret.reserveCapacity(width)
      for i in stride(from: width - 1, through: 0, by: -1) {
        ret.append(get(i).singleBitCharacter(chars))
      }
      return ret
    }
  }

  /// Java: `Value.toDecimalString(boolean)`.
  public func toDecimalString(signed: Bool, chars: DisplayCharacters = .default) -> String {
    if width == 0 { return String(chars.dontCareChar) }
    if isErrorValue() { return String(chars.errorChar) }
    if !isFullyDefined() { return String(chars.unknownChar) }

    // Keep only valid bits, zeroing bits above the value's width.
    let mask = jushr(-1, 64 - width)
    var val = toLongValue() & mask

    if signed {
      // Copy the sign bit into the upper bits.
      let isNegative = jshr(val, width - 1) != 0
      if isNegative {
        val |= ~mask
      }
      return String(val)
    } else {
      return JavaLongText.toUnsignedString(val)
    }
  }

  /// Java: `Value.toDisplayString()`: binary, with a space between nibbles. Identical to
  /// Java's `toString()`.
  public func toDisplayString(chars: DisplayCharacters = .default) -> String {
    switch width {
    case 0:
      return String(chars.dontCareChar)
    case 1:
      return String(singleBitCharacter(chars))
    default:
      var ret = ""
      ret.reserveCapacity(width + width / 4)
      for i in stride(from: width - 1, through: 0, by: -1) {
        ret.append(get(i).singleBitCharacter(chars))
        if i % 4 == 0 && i != 0 { ret.append(" ") }
      }
      return ret
    }
  }

  /// Java: `Value.toDisplayString(int)`.
  ///
  /// Radix 2/8/16 route to the grouped renderers, which can show partially-unknown digits.
  /// Every other radix requires the value to be fully defined and falls through to
  /// `Long.toString(long, int)` semantics.
  public func toDisplayString(radix: Int, chars: DisplayCharacters = .default) -> String {
    switch radix {
    case 2:
      return toDisplayString(chars: chars)
    case 8:
      return toOctalString(chars: chars)
    case 16:
      return toHexString(chars: chars)
    default:
      if width == 0 { return String(chars.dontCareChar) }
      if isErrorValue() { return String(chars.errorChar) }
      if !isFullyDefined() { return String(chars.unknownChar) }
      return JavaLongText.toString(toLongValue(), radix: radix)
    }
  }

  /// Java: `Value.toHexString()`. A nibble containing any error or unknown bit renders as
  /// the error/unknown character instead of a hex digit; scanning stops at the first such
  /// bit, from the most significant bit of the nibble downwards.
  public func toHexString(chars: DisplayCharacters = .default) -> String {
    groupedRadixString(bitsPerDigit: 4, digitRadix: 16, chars: chars)
  }

  /// Java: `Value.toOctalString()`.
  public func toOctalString(chars: DisplayCharacters = .default) -> String {
    groupedRadixString(bitsPerDigit: 3, digitRadix: 8, chars: chars)
  }

  /// Shared body of Java's `toHexString()` and `toOctalString()`, which are the same routine
  /// with 4/16 substituted for 3/8.
  private func groupedRadixString(bitsPerDigit: Int, digitRadix: Int32, chars: DisplayCharacters) -> String {
    if width <= 1 {
      return toDisplayString(chars: chars)
    }
    let vals = getAll()
    let count = (vals.count + bitsPerDigit - 1) / bitsPerDigit
    var c = [Character](repeating: " ", count: count)
    for i in 0..<count {
      let k = count - 1 - i
      let frst = bitsPerDigit * k
      let last = min(vals.count, bitsPerDigit * (k + 1))
      var v: Int32 = 0
      c[i] = " "
      var j = last - 1
      while j >= frst {
        if vals[j] == .errorValue {
          c[i] = chars.errorChar
          break
        }
        if vals[j] == .unknownValue {
          c[i] = chars.unknownChar
          break
        }
        v = 2 &* v
        if vals[j] == .trueValue { v &+= 1 }
        j -= 1
      }
      if c[i] == " " {
        c[i] = JavaLongText.forDigit(v, radix: digitRadix)
      }
    }
    return String(c)
  }

  /// Java: `Value.toString()`. Identical in body to `toDisplayString()`.
  ///
  /// Uses `DisplayCharacters.default`, since `CustomStringConvertible` cannot take a
  /// parameter. Call `toDisplayString(chars:)` explicitly whenever the user's configured
  /// characters matter; this property is for diagnostics and interpolation.
  public var description: String {
    toDisplayString(chars: .default)
  }

  // MARK: Numeric conversion

  /// Java: `Value.toLongValue()`; returns -1 if any bit is unknown or in error.
  ///
  /// JAVA QUIRK: -1 is also a perfectly ordinary 64-bit value, so the sentinel is
  /// ambiguous at width 64. Callers are expected to have checked `isFullyDefined()` first.
  public func toLongValue() -> Int64 {
    if error != 0 { return -1 }
    if unknown != 0 { return -1 }
    return value
  }

  /// Java: `Value.toSignExtendedLongValue()`; replicate bit `width - 1` through bit 63.
  ///
  /// For NIL the shift distance is 64, which Java masks to 0, so the (zero) value is
  /// returned unshifted.
  public func toSignExtendedLongValue() -> Int64 {
    if error != 0 { return -1 }
    if unknown != 0 { return -1 }
    let shift = 64 - width
    return jshr(jshl(value, shift), shift)
  }

  /// Java: `Value.toBigInteger(boolean)`.
  ///
  /// DEVIATION (return type). The Java returns `java.math.BigInteger`; Swift's standard
  /// library has no arbitrary-precision integer and Foundation has no equivalent. Every
  /// result *this method* can produce is bounded by 64 bits of magnitude, so `Int128`
  /// represents both cases losslessly: including the unsigned one, where a set bit 63 would
  /// not fit an `Int64`.
  ///
  /// **`Int128` is NOT wide enough for what the arithmetic components then do with it.** An
  /// earlier version of this comment claimed "a 64x64 product still fits"; it does not, and
  /// that sentence would have led straight to a trapping multiply:
  ///
  /// - `Multiplier.java:72` does `aa.multiply(bb)`. For two full-width values that is
  ///   `(2^64 - 1)^2` ~= 3.4e38, past `Int128.max` ~= 1.7e38. `*` traps;
  ///   `multipliedReportingOverflow` reports overflow.
  /// - `Divider.java:68` does `upper.toBigInteger(unsigned).shiftLeft(w)` with `w == 64`,
  ///   needing 128 *unsigned* bits when bit 63 is set.
  /// - `Exponentiator.java:73` does `aa.pow(b)`, which is unbounded; 3^100 alone is 5.15e47.
  ///
  /// So when those three are ported (M5), do NOT write `a.toBigInteger(true) * b.toBigInteger(true)`.
  /// Use `magnitudeUInt64` with `multipliedFullWidth(by:)` / `dividingFullWidth(_:)` for
  /// Multiplier and Divider, and expect Exponentiator to need a real arbitrary-precision
  /// integer. See docs/decisions.md D15.
  ///
  /// The unsigned path in the Java builds a positive `BigInteger` from the eight big-endian
  /// magnitude bytes of the masked value, which is exactly a zero-extended `UInt64`.
  public func toBigInteger(unsigned: Bool) -> Int128 {
    let mask: Int64 = (width == 64 ? -1 : ~jshl(-1, width))
    var v = self.value & mask
    if unsigned {
      return Int128(UInt64(bitPattern: v))
    }
    if jshr(v, width - 1) != 0 { v |= ~mask }
    return Int128(v)
  }

  /// The masked value as a bare 64-bit magnitude.
  ///
  /// This is the entry point Multiplier and Divider should use, because
  /// `UInt64.multipliedFullWidth(by:)` and `dividingFullWidth(_:)` give exact 128-bit results
  /// where `toBigInteger(unsigned:) * toBigInteger(unsigned:)` overflows `Int128`.
  public var magnitudeUInt64: UInt64 {
    let mask: Int64 = (width == 64 ? -1 : ~jshl(-1, width))
    return UInt64(bitPattern: self.value & mask)
  }

  /// Java: `Value.toFloatValue()`: reinterpret a 32-bit value as binary32.
  public func toFloatValue() -> Float {
    if error != 0 || unknown != 0 || width != 32 { return Float.nan }
    return Float(bitPattern: UInt32(truncatingIfNeeded: value))
  }

  /// Java: `Value.toDoubleValue()`: reinterpret a 64-bit value as binary64.
  public func toDoubleValue() -> Double {
    if error != 0 || unknown != 0 || width != 64 { return Double.nan }
    return Double(bitPattern: UInt64(bitPattern: value))
  }

  /// Java: `Value.toFloatValueFromFP16()`.
  public func toFloatValueFromFP16() -> Float {
    if error != 0 || unknown != 0 || width != 16 { return Float.nan }
    return JavaFloatBits.float16ToFloat(Int16(truncatingIfNeeded: value))
  }

  /// Java: `Value.toFloatValueFromFP8()`.
  public func toFloatValueFromFP8() -> Float {
    if error != 0 || unknown != 0 || width != 8 { return Float.nan }
    return MiniFloat.miniFloat143ToFloat(Int8(truncatingIfNeeded: value))
  }

  /// Java: `Value.toDoubleValueFromAnyFloat()`.
  public func toDoubleValueFromAnyFloat() -> Double {
    switch width {
    case 8: return Double(toFloatValueFromFP8())
    case 16: return Double(toFloatValueFromFP16())
    case 32: return Double(toFloatValue())
    case 64: return toDoubleValue()
    default: return Double.nan
    }
  }

  /// Java: `Value.toStringFromFloatValue()`.
  ///
  /// The text follows `java.lang.Float.toString` / `Double.toString`, not Swift's
  /// `description`: "NaN", "Infinity", "-0.0", "1.0E-4" rather than "nan", "inf", "-0.0",
  /// "1e-04". See `JavaFloatingPointText`.
  public func toStringFromFloatValue() -> String {
    switch getWidth() {
    case 8: return JavaFloatingPointText.floatToString(toFloatValueFromFP8())
    case 16: return JavaFloatingPointText.floatToString(toFloatValueFromFP16())
    case 32: return JavaFloatingPointText.floatToString(toFloatValue())
    case 64: return JavaFloatingPointText.doubleToString(toDoubleValue())
    default: return "NaN"
    }
  }
}

// MARK: - java.lang.Float / java.lang.Double bit conversions

/// The `java.lang.Float` / `java.lang.Double` bit-level intrinsics that `Value` depends on.
/// These are JDK methods rather than Logisim code, so they live here rather than in a ported
/// Logisim file.
enum JavaFloatBits {

  /// Java: `Float.floatToIntBits(float)`. Unlike `floatToRawIntBits`, every NaN collapses to
  /// the canonical quiet NaN.
  @inline(__always)
  static func floatToIntBits(_ f: Float) -> UInt32 {
    f.isNaN ? 0x7fc0_0000 : f.bitPattern
  }

  /// Java: `Double.doubleToLongBits(double)`. Canonicalises NaN.
  @inline(__always)
  static func doubleToLongBits(_ d: Double) -> Int64 {
    Int64(bitPattern: d.isNaN ? 0x7ff8_0000_0000_0000 : d.bitPattern)
  }

  /// Java's narrowing primitive conversion `(float) someDouble`.
  ///
  /// Swift's `Float.init(_: Double)` deliberately preserves a NaN's payload *and* its
  /// signaling bit; the JVM emits a hardware `fcvt`, which keeps only the top 23 significand
  /// bits and forces the result quiet. They therefore disagree on every signaling NaN: e.g.
  /// `0x7FF8000020000000` narrows to `0x7FC00001` on the JVM but to `0x7F800001` in Swift,
  /// which changes the FP16 encoding produced by `createKnown(_:_:)`. Finite values are
  /// identical (both round to nearest, ties to even), so only the NaN case is special-cased.
  @inline(__always)
  static func doubleToFloat(_ d: Double) -> Float {
    guard d.isNaN else { return Float(d) }
    let bits = d.bitPattern
    let sign = UInt32(truncatingIfNeeded: bits &>> 32) & 0x8000_0000
    let payload = UInt32(truncatingIfNeeded: (bits & 0x000F_FFFF_FFFF_FFFF) &>> 29)
    return Float(bitPattern: sign | 0x7F80_0000 | payload | 0x0040_0000)
  }

  /// Java: `Float.float16ToFloat(short)` (JDK 20+).
  ///
  /// Delegates to `Float16`, which lowers to the same AArch64 `fcvt s, h` instruction that
  /// HotSpot's intrinsic for this method emits. On Apple Silicon, the only target, per D0,
  /// that intrinsic is what actually runs, and it is *not* bit-identical to the pure-Java
  /// fallback in the JDK source for signaling NaNs: the hardware forces the result quiet,
  /// the Java source does not. Verified bit-for-bit against openjdk 21 over all 65536
  /// binary16 encodings.
  @inline(__always)
  static func float16ToFloat(_ floatBinary16: Int16) -> Float {
    Float(Float16(bitPattern: UInt16(bitPattern: floatBinary16)))
  }

  /// Java: `Float.floatToFloat16(float)` (JDK 20+), round to nearest even.
  ///
  /// Same reasoning as `float16ToFloat`: this is HotSpot's `fcvt h, s` intrinsic, verified
  /// bit-for-bit against openjdk 21 across a sweep of the whole 2^32 float space.
  @inline(__always)
  static func floatToFloat16(_ f: Float) -> Int16 {
    Int16(bitPattern: Float16(f).bitPattern)
  }
}

// MARK: - java.lang.Long text formatting

/// The `java.lang.Long` / `java.lang.Character` text helpers `Value` depends on.
enum JavaLongText {

  /// Java: `Character.forDigit(int, int)`, restricted to the radices `Value` uses (8 and 16).
  /// Digits above 9 are lower case, matching the JDK.
  static func forDigit(_ digit: Int32, radix: Int32) -> Character {
    guard radix >= 2, radix <= 36, digit >= 0, digit < radix else {
      // Java's Character.forDigit returns the null character U+0000 for an
      // invalid digit or radix; reproduced rather than substituting a space.
      return "\0"
    }
    if digit < 10 {
      return Character(UnicodeScalar(UInt8(0x30 + digit)))
    }
    return Character(UnicodeScalar(UInt8(0x61 + digit - 10)))
  }

  /// Java: `Long.toString(long, int)`. A radix outside `2...36` falls back to 10, and
  /// negative values are rendered with a leading '-' followed by the magnitude's digits,
  /// which is exactly Swift's `String(_:radix:)` behaviour once the radix is validated.
  static func toString(_ v: Int64, radix: Int) -> String {
    let r = (radix < 2 || radix > 36) ? 10 : radix
    return String(v, radix: r)
  }

  /// Java: `Long.toUnsignedString(long)`.
  static func toUnsignedString(_ v: Int64) -> String {
    String(UInt64(bitPattern: v))
  }
}

// MARK: - java.lang.Float / Double text formatting

/// Reproduces `java.lang.Float.toString` / `java.lang.Double.toString` layout.
///
/// Both the JDK (since 19, via Raffaello Giulietti's algorithm) and the Swift standard
/// library print the shortest decimal that round-trips, so the *digits* agree. Only the
/// *layout* differs, and that is what this type fixes up:
///
///   * "NaN" / "Infinity" / "-Infinity" instead of "nan" / "inf" / "-inf".
///   * Plain decimal with at least one fractional digit when 10^-3 <= |v| < 10^7,
///     e.g. "0.001", "9999999.0".
///   * Otherwise scientific notation as `d.dddEn`: capital E, no '+', no zero-padded
///     exponent: "1.0E-4", "1.0E7".
///   * At least two significant digits. The JDK spec is *not* "shortest": when the shortest
///     round-tripping decimal has length 1 it widens the candidate set to lengths 1 *and* 2
///     and picks whichever is closest to the exact value. That is why
///     `Float.toString(Float.MIN_VALUE)` is "1.4E-45" and not "1E-45": and Swift, which is
///     purely shortest, prints "1e-45". See `refineToTwoDigits`.
enum JavaFloatingPointText {

  /// Exact powers of ten. 10^22 is the largest power of ten exactly representable as a
  /// `Double`, so scaling is done in chunks of at most 22 to keep every step correctly
  /// rounded.
  private static let pow10: [Double] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
  ]

  static func floatToString(_ f: Float) -> String {
    if f.isNaN { return "NaN" }
    if f.isInfinite { return f < 0 ? "-Infinity" : "Infinity" }
    if f == 0 { return f.sign == .minus ? "-0.0" : "0.0" }
    return layout(shortest: "\(f)",
                  magnitude: Double(abs(f)),
                  negative: f.sign == .minus,
                  roundTrips: { Float($0) == abs(f) })
  }

  static func doubleToString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    return layout(shortest: "\(d)",
                  magnitude: abs(d),
                  negative: d.sign == .minus,
                  roundTrips: { Double($0) == abs(d) })
  }

  /// Re-lays-out Swift's shortest round-trip description in Java's format. `shortest` is one
  /// of the forms Swift emits for a finite nonzero value: "1.5", "-0.001", "1e-05",
  /// "-1.5e+20". `magnitude` is the exact absolute value and `roundTrips` re-parses a
  /// candidate at the original precision; both exist only for the two-digit rule.
  private static func layout(
    shortest: String,
    magnitude: Double,
    negative: Bool,
    roundTrips: (String) -> Bool
  ) -> String {
    var s = Substring(shortest)
    if s.hasPrefix("-") { s = s.dropFirst() }

    // Split off any exponent.
    var expPart = 0
    if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      expPart = Int(s[s.index(after: eIdx)...]) ?? 0
      s = s[..<eIdx]
    }

    // Split at the decimal point.
    var intPart = s
    var fracPart = Substring("")
    if let dot = s.firstIndex(of: ".") {
      intPart = s[..<dot]
      fracPart = s[s.index(after: dot)...]
    }

    var digits = Array(intPart) + Array(fracPart)
    let fracLen = fracPart.count

    // Drop leading zeros, remembering how many, so the decimal exponent of the first
    // surviving digit can be computed.
    var lead = 0
    while lead < digits.count - 1 && digits[lead] == "0" { lead += 1 }
    var e = digits.count - lead - 1 - fracLen + expPart
    digits.removeFirst(lead)

    // Drop trailing zeros, keeping at least one digit.
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }

    if digits == ["0"] { return negative ? "-0.0" : "0.0" }

    // The JDK's two-digit rule (see the type comment). Note that this can move the decimal
    // exponent as well as add a digit: `Double(bitPattern: 2)` is 9.88...e-324, whose
    // shortest form is "1e-323" but whose two-digit form is "9.9E-324".
    if digits.count == 1 {
      (digits, e) = refineToTwoDigits(digits, exponent: e, magnitude: magnitude,
                                      roundTrips: roundTrips)
      // A trailing zero adds no information: 5e-1 and 50e-2 are the same decimal, and Java
      // renders it "0.5". Re-strip so the refinement can only ever *add* a meaningful digit.
      while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    }

    let sign = negative ? "-" : ""

    // Java: plain notation when 10^-3 <= magnitude < 10^7, i.e. -3 <= e <= 6.
    if e >= -3 && e <= 6 {
      if e >= 0 {
        let intDigits: String
        let fracDigits: String
        if digits.count > e + 1 {
          intDigits = String(digits[0...e])
          fracDigits = String(digits[(e + 1)...])
        } else {
          intDigits = String(digits) + String(repeating: "0", count: e + 1 - digits.count)
          fracDigits = "0"
        }
        return sign + intDigits + "." + fracDigits
      } else {
        let zeros: String = String(repeating: "0", count: -e - 1)
        let body: String = String(digits)
        return sign + "0." + zeros + body
      }
    }

    let head = String(digits[0])
    let tail = digits.count > 1 ? String(digits[1...]) : "0"
    return sign + head + "." + tail + "E" + String(e)
  }

  /// The JDK admits decimals of length 1 *or* 2 when the shortest round-tripping decimal has
  /// length 1, and picks the one closest to the exact value. Swift only ever produces the
  /// length-1 form, so recover the second significant digit here.
  ///
  /// Returns the original single digit and exponent unchanged when the two-digit candidate
  /// does not re-parse to the same value, or when the scaling cannot be carried out. In the
  /// overwhelmingly common case the second digit is 0 and both renderings coincide anyway;
  /// the rule only visibly bites where the rounding interval is wide relative to the value,
  /// i.e. near the subnormal floor.
  private static func refineToTwoDigits(
    _ digits: [Character],
    exponent e: Int,
    magnitude: Double,
    roundTrips: (String) -> Bool
  ) -> ([Character], Int) {
    // The shortest one-digit decimal need not sit in the value's own decade, 9.88e-324
    // shortens to "1e-323": so re-derive the decade before rounding to two digits.
    var exp10 = e
    var x = scaled(magnitude, byPowerOfTen: 1 - exp10)
    if x >= 100 {
      exp10 += 1
      x = scaled(magnitude, byPowerOfTen: 1 - exp10)
    } else if x < 10 {
      exp10 -= 1
      x = scaled(magnitude, byPowerOfTen: 1 - exp10)
    }
    guard x.isFinite, x >= 10 else { return (digits, e) }

    // The JDK breaks a tie by preferring the even last digit.
    var r = Int(x.rounded(.toNearestOrEven))
    if r >= 100 {
      r = 10
      exp10 += 1
    }
    let d1 = r / 10
    let d2 = r % 10

    let candidate = "\(d1).\(d2)e\(exp10)"
    guard roundTrips(candidate) else { return (digits, e) }
    return ([Character(String(d1)), Character(String(d2))], exp10)
  }

  /// `magnitude * 10^k`, applied in chunks of at most 10^22 (the largest power of ten that
  /// is exact as a `Double`) so that every individual step is correctly rounded.
  private static func scaled(_ magnitude: Double, byPowerOfTen k: Int) -> Double {
    var x = magnitude
    var remaining = k
    while remaining > 0 {
      let step = min(remaining, 22)
      x *= pow10[step]
      remaining -= step
    }
    while remaining < 0 {
      let step = min(-remaining, 22)
      x /= pow10[step]
      remaining += step
    }
    return x
  }
}
