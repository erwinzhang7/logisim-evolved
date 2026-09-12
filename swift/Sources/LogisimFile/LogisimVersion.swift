// LogisimVersion.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/LogisimVersion.java`.
// logisim-evolution is free software released under the GNU GPLv3; this translation is
// therefore GPL-3.0-only. See LICENSE.md.
//
// This type exists in `LogisimFile` rather than `LogisimKernel` because its only consumer in
// the port is `XmlReader.considerRepairs`, which gates every `.circ` migration pass on it.
// Getting it wrong silently mis-migrates files, so the parsing below was validated case by
// case against the shipped 4.1.0 jar (see the table in the doc comment on `fromString`).

import Foundation
import LogisimKernel

/// A parsed `X.Y.Z[-]suffix` version, as produced by the `source=` attribute of a `.circ`
/// file and by the literals in `XmlReader.considerRepairs`.
///
/// Java models this as a mutable class whose fields are filled by `initFromVersionString`;
/// nothing mutates an instance after construction, so a `struct` is exact here.
public struct LogisimVersion: Hashable, CustomStringConvertible, Sendable {

  public let major: Int
  public let minor: Int
  public let patch: Int

  /// `"-"` when the source string separated the suffix with a dash, `""` otherwise.
  /// Carried only so `description` round-trips; `compareTo` ignores it, exactly as Java does.
  public let separator: String

  /// `""` for a stable release. Any non-empty suffix marks an unstable build and orders
  /// *before* the otherwise-identical stable version.
  public let suffix: String

  private init(major: Int, minor: Int, patch: Int, separator: String, suffix: String) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.separator = separator
    self.suffix = suffix
  }

  /// Java: `LogisimVersion.fromString(String)` → `initFromVersionString`.
  ///
  /// Two distinct outcomes that are easy to conflate, and both are load-bearing:
  ///
  /// * A string that does **not** match `^(\d+.\d+.\d+)(.*)$` yields `0.0.0` silently. That
  ///   includes the empty string, which is what `Element.getAttribute("source")` returns when
  ///   a `.circ` has no `source=` at all. `0.0.0` sits below the `2.3.0` and `2.6.3` gates
  ///   *and* triggers the `== 0.0.0` early return, so it is a genuine, reachable path; it is
  ///   how `tools/difftest/fixtures.py` synthesises coverage for the `<2.3.0` gate.
  /// * A string that matches but whose captured segments are not parseable `int`s, or whose
  ///   suffix is malformed, throws `IllegalArgumentException` in Java. That is an unchecked
  ///   exception on the file-loading path, so per D13 it becomes a Swift `throw` rather than
  ///   a trap.
  ///
  /// Verified against `logisim-evolution-4.1.0-all.jar`:
  ///
  /// | input | result |
  /// |---|---|
  /// | `""`, `"1.2"`, `"1234"`, `"١.٢.٣"`, `" 1.2.3"`, `"2.7.1\n"` | `0.0.0` |
  /// | `"01.02.03"` | `1.2.3` |
  /// | `"1.2.34"` | `1.2.34` (patch 34, not a suffix) |
  /// | `"1.2.3x4"`, `"1.2.3a"`, `"1.2.3-DEV"` | suffix accepted |
  /// | `"1.2.3.4"` | throws; suffix `".4"` |
  /// | `"1.2.3 "` | throws: suffix `" "` |
  /// | `"1a2b3"`, `"99999999999.1.2"` | throws: segments not integers |
  ///
  /// The regex subtleties that produce those results, none of which survive a naive
  /// translation to `NSRegularExpression`:
  ///
  /// * The dots in `\d+.\d+.\d+` are **unescaped**, so they match any character. `"1a2b3"`
  ///   therefore *matches*, captures `"1a2b3"` as the version part, splits on literal `.`
  ///   into one segment, and then fails in `Integer.parseInt`, which is why that input
  ///   throws instead of yielding `0.0.0`.
  /// * `\d` is ASCII-only (no `UNICODE_CHARACTER_CLASS`), so Arabic-Indic digits do not match,
  ///   even though `Integer.parseInt` would happily accept them.
  /// * `.` never matches a line terminator, and `matches()` anchors both ends, so any input
  ///   containing `\n`, `\r`, U+0085, U+2028 or U+2029 cannot match at all.
  /// * `Integer.parseInt` is 32-bit, so an 11-digit major segment throws.
  public static func fromString(_ versionString: String) throws -> LogisimVersion {
    guard let (versionPart, suffixPart) = matchVersionPattern(versionString) else {
      // No match: every field keeps its zero initialiser and no exception is raised.
      return LogisimVersion(major: 0, minor: 0, patch: 0, separator: "", suffix: "")
    }

    var major = 0
    var minor = 0
    var patch = 0

    // Java: `m.group(1).split("\\.")`: a *literal* dot split, which is why a version part
    // captured through a non-dot separator collapses into a single unparseable segment.
    let parts = javaSplitOnLiteralDot(versionPart)
    var parsed: [Int] = []
    for part in parts.prefix(3) {
      guard let value = javaParseInt32(part) else {
        throw LogisimVersionError.invalidSegments(versionPart)
      }
      parsed.append(value)
    }
    if parsed.count >= 1 { major = parsed[0] }
    if parsed.count >= 2 { minor = parsed[1] }
    if parsed.count >= 3 { patch = parsed[2] }

    var separator = ""
    var suffix = ""
    let suffixScalars = Array(suffixPart.unicodeScalars)
    if suffixScalars.count == 1 {
      // Java: `^[a-z]+$` with CASE_INSENSITIVE (but not UNICODE_CASE), ASCII letters only.
      guard isAsciiLetterScalar(suffixScalars[0]) else {
        throw LogisimVersionError.suffixMustStartWithLetter(suffixPart)
      }
      suffix = suffixPart
    } else if suffixScalars.count > 1 {
      // Java: `^(-)?([a-z][a-z\d]*)$`, again ASCII-only.
      var index = 0
      if suffixScalars[0] == "-" {
        separator = "-"
        index = 1
      }
      guard index < suffixScalars.count, isAsciiLetterScalar(suffixScalars[index]) else {
        throw LogisimVersionError.invalidSuffixFormat(suffixPart)
      }
      index += 1
      while index < suffixScalars.count {
        let s = suffixScalars[index]
        guard isAsciiLetterScalar(s) || isJavaDigitScalar(s) else {
          throw LogisimVersionError.invalidSuffixFormat(suffixPart)
        }
        index += 1
      }
      suffix = String(String.UnicodeScalarView(suffixScalars[(separator.isEmpty ? 0 : 1)...]))
    }

    return LogisimVersion(
      major: major, minor: minor, patch: patch, separator: separator, suffix: suffix)
  }

  /// Java: `new LogisimVersion(major, minor, patch)` / `(major, minor, patch, suffix)`.
  ///
  /// Java formats `"%d.%d.%d%s"` and then runs the *same* parser over it, so the constructor
  /// arguments are normalised rather than stored directly (`new LogisimVersion(1, 2, 3)` and
  /// `fromString("01.02.03")` produce identical objects). This reproduces that.
  ///
  /// D13 carve-out: this initialiser traps on unparseable input rather than throwing. Every
  /// call site in the port passes compile-time literals, `2.3.0`, `2.6.3`, `2.7.2`,
  /// `4.1.0dev`, `0.0.0`, so a failure here is a programmer error that no `.circ` file can
  /// reach. File input goes through `fromString`, which throws.
  public init(_ major: Int, _ minor: Int, _ patch: Int, _ suffix: String = "") {
    let versionString = "\(major).\(minor).\(patch)\(suffix)"
    guard let parsed = try? LogisimVersion.fromString(versionString) else {
      preconditionFailure("LogisimVersion literal '\(versionString)' is not a valid version")
    }
    self = parsed
  }

  /// Java: `compareTo`. Negative when `self` is older, positive when newer.
  ///
  /// The magnitude is Java's raw `int` difference, not `-1/0/1`, and the arithmetic is 32-bit
  /// and wrapping. Callers only ever test the sign, but the magnitude is reproduced anyway so
  /// a differential harness can compare the number directly.
  ///
  /// The suffix rule is Java's, comment and all: a version with *no* suffix is considered
  /// newer than the same version with one. So `4.1.0` > `4.1.0-dev`, and, the case that
  /// actually matters, `0.0.0dev` compares `-1` against `0.0.0`, so it does **not** take
  /// `considerRepairs`'s `== 0.0.0` early return.
  public func compare(to other: LogisimVersion) -> Int {
    var result = wrap32(major &- other.major)
    if result == 0 {
      result = wrap32(minor &- other.minor)
      if result == 0 {
        result = wrap32(patch &- other.patch)
      }
    }
    if result == 0 {
      if suffix.isEmpty && !other.suffix.isEmpty {
        result = 1
      } else if !suffix.isEmpty && other.suffix.isEmpty {
        result = -1
      }
    }
    return result
  }

  /// Java: `isStable()`; "no suffix" is the entire test.
  public var isStable: Bool { suffix.isEmpty }

  /// Java: `toString()`. The separator is re-emitted only when a suffix is present, so
  /// `fromString("4.1.0-dev")` round-trips as `"4.1.0-dev"` while `new LogisimVersion(4, 1, 0,
  /// "dev")` renders as `"4.1.0dev"`.
  public var description: String {
    var sfx = ""
    if !suffix.isEmpty {
      sfx = separator + suffix
    }
    return LogisimVersion.format(major, minor, patch, sfx)
  }

  /// Java: `LogisimVersion.format(int, int, int[, String])`. The suffix is appended verbatim,
  /// separator included: the caller supplies it already joined.
  public static func format(_ major: Int, _ minor: Int, _ patch: Int, _ suffix: String = "")
    -> String
  {
    var result = "\(major).\(minor).\(patch)"
    if !suffix.isEmpty { result += suffix }
    return result
  }

  // MARK: - Pattern matching

  /// Java's `^(\d+.\d+.\d+)(.*)$` under `Matcher.matches()`, hand-expanded.
  ///
  /// Returns `(group1, group2)` or `nil` when the pattern does not match. Reproduces Java's
  /// leftmost-greedy-with-backtracking search order, which decides how a string like
  /// `"1234.5.6"` is carved up: the first `\d+` takes as much as it can and gives characters
  /// back only when the rest of the pattern cannot proceed.
  private static func matchVersionPattern(_ input: String) -> (String, String)? {
    let scalars = Array(input.unicodeScalars)
    // `.` and `.*` never match a line terminator, and `matches()` requires the whole input to
    // be consumed, so a single line terminator anywhere makes the match impossible.
    if scalars.contains(where: isJavaLineTerminatorScalar) { return nil }

    let n = scalars.count

    @inline(__always)
    func digitRunLength(from start: Int) -> Int {
      var i = start
      while i < n, isJavaDigitScalar(scalars[i]) { i += 1 }
      return i - start
    }

    let firstRun = digitRunLength(from: 0)
    guard firstRun >= 1 else { return nil }

    // Greedy: longest first `\d+` that still lets the remainder match.
    var len1 = firstRun
    while len1 >= 1 {
      // One arbitrary (non-line-terminator) character for the unescaped `.`.
      let afterSep1 = len1 + 1
      if afterSep1 <= n {
        let secondRun = digitRunLength(from: afterSep1)
        var len2 = secondRun
        while len2 >= 1 {
          let afterSep2 = afterSep1 + len2 + 1
          if afterSep2 <= n {
            let thirdRun = digitRunLength(from: afterSep2)
            if thirdRun >= 1 {
              // `(.*)` is greedy and unconstrained, so the third `\d+` also takes its
              // maximum and the match succeeds immediately.
              let end = afterSep2 + thirdRun
              let group1 = String(String.UnicodeScalarView(scalars[0..<end]))
              let group2 = String(String.UnicodeScalarView(scalars[end...]))
              return (group1, group2)
            }
          }
          len2 -= 1
        }
      }
      len1 -= 1
    }
    return nil
  }

  /// Java's `String.split("\\.")` for this specific pattern: split on literal `.`, then drop
  /// trailing empty segments (Java's zero-limit behaviour). Leading and interior empties are
  /// kept, which is what makes `".1.2"` parse its first segment as `""` and throw.
  private static func javaSplitOnLiteralDot(_ s: String) -> [String] {
    var parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    while let last = parts.last, last.isEmpty { parts.removeLast() }
    return parts
  }
}

/// Java throws `IllegalArgumentException` from `initFromVersionString`. It is unchecked, so
/// upstream lets it escape `XmlReader.readLibrary` and abort the load; D13 makes it a thrown
/// Swift error so the caller can report a file error instead of dying.
public enum LogisimVersionError: Error, Equatable, CustomStringConvertible, Sendable {
  /// Java: `"Version segments must be non-negative integers, '%s' found."`
  case invalidSegments(String)
  /// Java: `"Suffix must start with a letter, '%s' found."`
  case suffixMustStartWithLetter(String)
  /// Java: `"Invalid version suffix format. '%s' found."`
  case invalidSuffixFormat(String)

  public var description: String {
    switch self {
    case .invalidSegments(let s):
      return "Version segments must be non-negative integers, '\(s)' found."
    case .suffixMustStartWithLetter(let s):
      return "Suffix must start with a letter, '\(s)' found."
    case .invalidSuffixFormat(let s):
      return "Invalid version suffix format. '\(s)' found."
    }
  }
}
