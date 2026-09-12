// LogCaptureMode.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.Model's mode constants and
// formatDuration, and com.cburch.logisim.gui.log.ClockSource.CycleInfo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation

/// `Model.STEP` … `Model.CLOCK_LOW`, when the log takes a sample.
///
/// The raw values are upstream's integers, kept because `Model` compares them ordinally
/// (`mode >= CLOCKED`, where `CLOCKED == 30`) and because a differential test can then quote the
/// same number as the Java. `isClocked` replaces the bare comparison so the ordering is stated
/// once rather than at six call sites.
public enum LogCaptureMode: Int, CaseIterable, Hashable, Sendable, Codable {
  /// `STEP`: one sample per propagation, durations measured in `timeScale` units.
  case step = 10
  /// `REAL`: sample durations scaled from wall-clock time.
  case realTime = 20
  /// `CLOCK_DUAL`: sample on both clock edges.
  case clockDual = 30
  /// `CLOCK_RISING`.
  case clockRising = 40
  /// `CLOCK_FALLING`.
  case clockFalling = 50
  /// `CLOCK_HIGH`, level-sensitive, active high.
  case clockHigh = 60
  /// `CLOCK_LOW`, level-sensitive, active low.
  case clockLow = 70

  /// `Model.CLOCKED`; "above this are all clocked modes".
  static let clockedThreshold = 30

  /// `isClockMode()`.
  public var isClocked: Bool { rawValue >= LogCaptureMode.clockedThreshold }

  /// `isStepMode()`.
  public var isStep: Bool { self == .step }

  /// `isRealMode()`.
  public var isRealTime: Bool { self == .realTime }

  /// Whether this mode watches a clock *level* rather than an edge.
  public var isLevelSensitive: Bool { self == .clockHigh || self == .clockLow }

  /// `getClockDiscipline()`: the mode itself when clocked, 0 otherwise.
  public var clockDiscipline: Int { isClocked ? rawValue : 0 }

  /// The word the log file's `# mode:` line carries. Exact; a marking script reads it.
  public var fileKeyword: String {
    switch self {
    case .step: "step"
    case .realTime: "real-time"
    default: "clocked"
    }
  }

  /// English UI label. See `LogRadix.displayName` on why this is not localised.
  public var displayName: String {
    switch self {
    case .step: "Each propagation step"
    case .realTime: "Real time"
    case .clockDual: "Both clock edges"
    case .clockRising: "Rising clock edge"
    case .clockFalling: "Falling clock edge"
    case .clockHigh: "Clock high"
    case .clockLow: "Clock low"
    }
  }
}

/// `Model.COARSE` / `Model.FINE`.
///
/// Coarse discards transients inside a stable period and back-dates the settled value over the
/// whole period; fine records every propagation as its own `gateDelay`-long run.
public enum LogGranularity: Int, CaseIterable, Hashable, Sendable, Codable {
  case coarse = 1
  case fine = 2

  /// The word the log file's `granularity:` field carries. Exact.
  public var fileKeyword: String { self == .fine ? "fine" : "coarse" }

  public var displayName: String { self == .fine ? "Fine (every step)" : "Coarse (settled only)" }
}

/// `ClockSource.CycleInfo`; a clock component's high/low tick counts and phase.
public struct LogClockCycle: Equatable, Sendable {
  public let high: Int
  public let low: Int
  public let phase: Int

  /// `ticks`: the full period, in ticks.
  public var ticks: Int { high + low }

  public init(high: Int, low: Int, phase: Int) {
    self.high = high
    self.low = low
    self.phase = phase
  }

  /// `ClockSource.DEFAULT_CYCLE_INFO`; what upstream uses for anything that is not a `Clock`.
  public static let `default` = LogClockCycle(high: 1, low: 1, phase: 0)
}

/// `Model.formatDuration(long)`.
///
/// Byte-exact with the Java, because it appears in the `# <duration>` comment on every row of an
/// exported log and a marking script may match on it. Upstream's four format strings live in
/// `gui.properties` as `nsFormat = %s ns`, `usFormat = %s µs` (U+00B5, MICRO SIGN: *not* the
/// Greek mu U+03BC), `msFormat = %s ms`, `sFormat = %s s`.
///
/// Note the thresholds are upstream's, oddities included: the middle two branches test
/// `t < 1_000_000` against a `% 100_000` remainder and `t < 100_000_000` against a
/// `% 100_000_000` remainder. The mismatch is deliberate on their part or not, but it is
/// observable in the output, so it is preserved rather than tidied.
public enum LogDurationFormat {
  /// U+00B5 MICRO SIGN, as in `gui.properties`.
  public static let microSign = "\u{00B5}"

  public static func string(for t: Int64) -> String {
    if t < 1000 || (t % 100) != 0 {
      return "\(t) ns"
    } else if t < 1_000_000 || (t % 100_000) != 0 {
      return "\(javaOneDecimal(Double(t) / 1000.0)) \(microSign)s"
    } else if t < 100_000_000 || (t % 100_000_000) != 0 {
      return "\(javaOneDecimal(Double(t) / 1_000_000.0)) ms"
    } else {
      return "\(javaOneDecimal(Double(t) / 1_000_000_000.0)) s"
    }
  }

  /// Java's `String.format("%.1f", x)` under the root locale: HALF_UP rounding and a `.`
  /// separator. `String(format:)` in Foundation uses the C locale here (no locale argument), so
  /// the separator matches, but C's `printf` rounds half-to-even; `2.25` prints `2.2` there and
  /// `2.3` in Java. Rounding explicitly removes the difference.
  private static func javaOneDecimal(_ x: Double) -> String {
    let scaled = (x * 10.0).rounded(.toNearestOrAwayFromZero) / 10.0
    return String(format: "%.1f", scaled)
  }
}
