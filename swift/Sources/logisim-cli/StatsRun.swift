// StatsRun.swift: part of logisim-evolved.
//
// Derived from logisim-evolution
// (com.cburch.logisim.gui.start.TtyInterface.displayStatistics / countDigits),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is for ────────────────────────────────────────────────────────────────────────
//
// The port of the exact code path this runs on the Java side:
//
//     java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar \
//          [--toplevel-circuit <name>] -tty stats <file.circ>
//
// Unlike `-tty table`, this one already works headlessly in the shipped jar; `Startup.parseArgs`
// sets `Main.headless = true` for any `-t`/`--tty` invocation (Startup.java:357-360), so D17's
// dialog switch is already thrown and no bridge is needed. The oracle is therefore the jar
// itself, invoked exactly as a user would (`tools/difftest/ttybridge/statsgate.py`).
//
// ── Why a grader wants it ───────────────────────────────────────────────────────────────────
//
// It is the cheapest structural check there is on a submitted `.circ`: "this lab must be built
// from NAND gates only", "this must contain no Adder primitive", "this must instantiate exactly
// four full_adder subcircuits". All of those are one line of grep over this output, and none of
// them require simulating anything.
//
// The shared `FileStatistics` algorithm lives where upstream puts it, in `LogisimFile`. This
// file is only the CLI formatter over that result.

import Foundation
import LogisimFile

/// The port of `TtyInterface`'s `-tty stats` path.
enum StatsRun {

  enum Failure: Error, CustomStringConvertible {
    /// `--toplevel-circuit` named a circuit the file does not have. Upstream reaches
    /// `FileStatistics.compute(file, null)` and dies with an NPE at
    /// `FileStatistics.doSimpleCount:114`, which `Startup.run`'s `catch (Exception)` turns into
    /// exit 255. D13: a `.circ` file (and a CLI argument) can reach this, so it throws.
    case noSuchCircuit(String)

    var description: String {
      switch self {
      case let .noSuchCircuit(name): return "no circuit named \(name)"
      }
    }
  }

  /// `TtyInterface.countDigits(int)`.
  static func countDigits(_ num: Int) -> Int {
    var digits = 1
    var lessThan = 10
    while num >= lessThan {
      digits += 1
      // Java `int` overflow: `lessThan *= 10` wraps. Reproduced so a pathological count cannot
      // loop here where upstream terminates.
      lessThan = Int(Int32(truncatingIfNeeded: Int64(lessThan) * 10))
      if lessThan <= 0 { break }
    }
    return digits
  }

  /// `TtyInterface.displayStatistics(LogisimFile, Circuit)`, returning the text upstream prints
  /// to stdout rather than printing it, so a caller can compare it byte-for-byte.
  static func render(file: LogisimFile, circuit: Circuit) -> String {
    let stats = FileStatistics.compute(file: file, circuit: circuit)
    let total = stats.totalWithSubcircuits

    // `maxName` is measured in Java `String.length()`, i.e. UTF-16 code units, and so is the
    // `%-Ns` padding that consumes it. Swift's `String.count` is grapheme clusters and would
    // disagree on any display name outside the BMP-single-unit range.
    var maxName = 0
    for count in stats.counts {
      let nameLength = (count.factory?.displayName ?? "").utf16.count
      if nameLength > maxName { maxName = nameLength }
    }

    // fmt        = "%<u>d\t%<r>d\t"
    // fmtNormal  = fmt + "%-<maxName>s\t%s\n"
    let uniqueWidth = countDigits(total.uniqueCount)
    let recursiveWidth = countDigits(total.recursiveCount)

    var out = ""
    for count in stats.counts {
      let libName = count.library?.displayName ?? "-"
      out += padLeft(String(count.uniqueCount), uniqueWidth)
      out += "\t"
      out += padLeft(String(count.recursiveCount), recursiveWidth)
      out += "\t"
      out += padRight(count.factory?.displayName ?? "", maxName)
      out += "\t"
      out += libName
      out += "\n"
    }

    let without = stats.totalWithoutSubcircuits
    out += padLeft(String(without.uniqueCount), uniqueWidth)
    out += "\t"
    out += padLeft(String(without.recursiveCount), recursiveWidth)
    out += "\t"
    out += TtyStrings.statsTotalWithout
    out += "\n"
    out += padLeft(String(total.uniqueCount), uniqueWidth)
    out += "\t"
    out += padLeft(String(total.recursiveCount), recursiveWidth)
    out += "\t"
    out += TtyStrings.statsTotalWith
    out += "\n"
    return out
  }

  /// The whole of `[--toplevel-circuit <name>] -tty stats <file>`, from a loaded file.
  ///
  /// Circuit selection is `TtyInterface.run`'s: an absent or empty name means the main circuit.
  static func run(file: LogisimFile, circuitName: String?) throws -> String {
    let circuit: Circuit?
    if let circuitName, !circuitName.isEmpty {
      circuit = file.circuit(named: circuitName)
    } else {
      circuit = file.mainCircuit
    }
    guard let circuit else { throw Failure.noSuchCircuit(circuitName ?? "<main>") }
    return render(file: file, circuit: circuit)
  }

  /// `System.out.printf("%<w>d", n)`, right-align, never truncate.
  private static func padLeft(_ s: String, _ width: Int) -> String {
    let n = s.utf16.count
    return n >= width ? s : String(repeating: " ", count: width - n) + s
  }

  /// `System.out.printf("%-<w>s", s)`: left-align, never truncate.
  ///
  /// Java throws `IllegalFormatWidthException` on a width of 0 with the `-` flag, which is
  /// reachable upstream when the count list is empty (`maxName` stays 0). It is not reachable
  /// here for the same input, because an empty count list also means the two total rows are the
  /// only output and this function is never called. Guarded anyway rather than trusting that.
  private static func padRight(_ s: String, _ width: Int) -> String {
    let n = s.utf16.count
    return n >= width ? s : s + String(repeating: " ", count: width - n)
  }
}

/// The two localised strings `displayStatistics` prints, from `gui.properties`, the resource the
/// oracle runs with (the jar is invoked with no `-o`/`--locale`, so the default English bundle is
/// what produced every golden row).
///
/// **The apostrophe is U+2019 RIGHT SINGLE QUOTATION MARK, not U+0027.** It is a one-byte-class
/// difference that no reader would spot in a diff and that fails every row of the gate.
enum TtyStrings {
  static let statsTotalWithout = "TOTAL (without project\u{2019}s sub circuits)"
  static let statsTotalWith = "TOTAL (with sub circuits)"
}
