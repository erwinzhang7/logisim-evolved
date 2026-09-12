// JavaStringSupport.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/util/StringUtil.java` and the handful of
// `java.lang.String` / `java.util.regex` behaviours the `.circ` reader depends on.
// logisim-evolution is free software released under the GNU GPLv3; this translation is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Everything here exists because a "reasonable" Swift equivalent is NOT equivalent:
//
//   * `String.trim()` strips every char <= U+0020 (kernel `javaTrim`, reused, not reimplemented).
//   * `Integer.parseInt` is 32-bit (kernel `javaParseInt32`, likewise).
//   * `String.equalsIgnoreCase` uses Java's *simple* case mapping per UTF-16 unit, not ICU
//     full case folding, and requires equal UTF-16 length.
//   * Java's `\w` / `\W` / `\d` are ASCII-only unless UNICODE_CHARACTER_CLASS is set (it never
//     is here), while NSRegularExpression's are Unicode-aware. Every label regex in
//     XmlReader.java is therefore hand-expanded below instead of being handed to ICU.

import Foundation
import LogisimKernel

/// Port of `com.cburch.logisim.util.StringUtil`, restricted to the members the reader uses.
///
/// The Java methods are null-safe over `String`/`CharSequence`. Swift models "Java null" as
/// `nil`, and the DOM accessors in `XmlDom.swift` model the *other* Java convention,
/// `Element.getAttribute` returning `""`, never null, so both overloads are needed.
public enum StringUtil {

  /// Java: `StringUtil.isNullOrEmpty(CharSequence)`.
  public static func isNullOrEmpty(_ str: String?) -> Bool {
    guard let str else { return true }
    return str.isEmpty
  }

  /// Java: `StringUtil.isNotEmpty(CharSequence)`.
  public static func isNotEmpty(_ seq: String?) -> Bool {
    guard let seq else { return false }
    return !seq.isEmpty
  }

  /// Java: `StringUtil.startsWith(String, String)`: the null-safe `String.startsWith`.
  public static func startsWith(_ seq: String?, _ prefix: String) -> Bool {
    guard let seq else { return false }
    return seq.hasPrefix(prefix)
  }
}

/// Java's `String.equalsIgnoreCase`.
///
/// Java compares UTF-16 code unit by code unit: equal, or equal after `Character.toUpperCase`,
/// or equal after `toLowerCase(toUpperCase(c))`. Those are *simple* (1:1) case mappings.
/// Swift's `caseInsensitiveCompare` and `lowercased()` apply full Unicode case mapping, which
/// is 1:many and locale-sensitive in ways Java's is not (`"ß"` folds to `"ss"`, `"ﬃ"` to
/// `"ffi"`), so two strings Java calls different would compare equal.
///
/// Used only for `.circ` attribute names (`output`, `tristate`, `pull`, `type`, `behavior`,
/// and the values `true` / `up` / `down`), which are ASCII in every file that exists. The
/// non-ASCII path below approximates Java's simple mapping by taking Unicode's full mapping
/// and keeping it only when it stays a single scalar, which is exactly the set of characters
/// for which the simple and full mappings agree.
public func javaEqualsIgnoreCase(_ a: String, _ b: String) -> Bool {
  let ua = Array(a.utf16)
  let ub = Array(b.utf16)
  guard ua.count == ub.count else { return false }
  for i in 0..<ua.count {
    let c1 = ua[i]
    let c2 = ub[i]
    if c1 == c2 { continue }
    let u1 = javaSimpleUppercase(c1)
    let u2 = javaSimpleUppercase(c2)
    if u1 == u2 { continue }
    if javaSimpleLowercase(u1) == javaSimpleLowercase(u2) { continue }
    return false
  }
  return true
}

@inline(__always)
private func javaSimpleUppercase(_ unit: UInt16) -> UInt16 {
  if unit < 128 {
    return (unit >= 97 && unit <= 122) ? unit - 32 : unit
  }
  guard let scalar = Unicode.Scalar(unit) else { return unit }
  let mapped = scalar.properties.uppercaseMapping
  let scalars = Array(mapped.unicodeScalars)
  guard scalars.count == 1, scalars[0].value <= 0xFFFF else { return unit }
  return UInt16(scalars[0].value)
}

@inline(__always)
private func javaSimpleLowercase(_ unit: UInt16) -> UInt16 {
  if unit < 128 {
    return (unit >= 65 && unit <= 90) ? unit + 32 : unit
  }
  guard let scalar = Unicode.Scalar(unit) else { return unit }
  let mapped = scalar.properties.lowercaseMapping
  let scalars = Array(mapped.unicodeScalars)
  guard scalars.count == 1, scalars[0].value <= 0xFFFF else { return unit }
  return UInt16(scalars[0].value)
}

// MARK: - Java regex character classes, hand-expanded

/// Java's `\w` without `UNICODE_CHARACTER_CLASS`: exactly `[a-zA-Z_0-9]`.
@inline(__always)
func isJavaWordScalar(_ s: Unicode.Scalar) -> Bool {
  switch s.value {
  case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
  default: return false
  }
}

/// Java's `\d` without `UNICODE_CHARACTER_CLASS`: exactly `[0-9]`.
@inline(__always)
func isJavaDigitScalar(_ s: Unicode.Scalar) -> Bool {
  s.value >= 0x30 && s.value <= 0x39
}

/// ASCII `[A-Za-z]`; what Java's `[a-z]` with `CASE_INSENSITIVE` (but *not* `UNICODE_CASE`)
/// matches. With only `CASE_INSENSITIVE`, Java restricts case-insensitive matching to US-ASCII.
@inline(__always)
func isAsciiLetterScalar(_ s: Unicode.Scalar) -> Bool {
  (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
}

/// The characters Java's `.` does NOT match when neither DOTALL nor UNIX_LINES is set:
/// `\n`, `\r`, U+0085, U+2028, U+2029.
///
/// This matters for `^(\d+.\d+.\d+)(.*)$` in `LogisimVersion` and for `^[A-Za-z].*$` in
/// `generateValidVHDLLabel`: a `source=` or `label=` value containing a newline fails to
/// match in Java, where an ICU translation with default flags would behave the same for `.`
/// but differ on `$`. Expanding the class by hand removes the question.
@inline(__always)
func isJavaLineTerminatorScalar(_ s: Unicode.Scalar) -> Bool {
  switch s.value {
  case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: return true
  default: return false
  }
}
