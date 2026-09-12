// CliStatsTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS PROVES ════════════════════════════════════════════════════════════════════════
//
// `--tty stats` byte-matches `java -jar logisim-evolution-4.1.0-all.jar -tty stats` on fixtures
// checked into this file. The corpus-wide version of the same comparison is
// `tools/difftest/ttybridge/statsgate.py`; this suite is the part that runs with no private
// corpus present, so a regression in the formatter cannot wait for someone to remember to run
// the gate.
//
// `stats` is not a cosmetic format. It is the cheapest structural check a grader has on a
// submitted `.circ`: "built from NAND only", "no Adder primitive", "exactly four full_adder
// subcircuits", and none of it needs the circuit simulated.
//
// ── The three ways this output can be subtly wrong ──────────────────────────────────────────
//
//  1. **The apostrophe in `TOTAL (without project’s sub circuits)` is U+2019**, not U+0027.
//     Nothing in a terminal distinguishes them and every row of the gate fails on it, so it is
//     asserted by codepoint below rather than only implicitly through the byte comparison.
//  2. **The column widths come from the WITH-subcircuits total**, and are applied to every row
//     including the without-subcircuits one (`TtyInterface:89-95` computes `fmt` once from
//     `total`). Using each row's own digit count would look right on any single-digit file.
//  3. **`unique` is not `recursive` and neither is `simple`.** `combinational` has all three
//     equal, so `hierarchical` carries the real check: two `leaf` instances make Pin 6 unique /
//     9 recursive, and the totals 8/12 without and 10/14 with.

import Foundation
import Testing

@Suite("logisim-cli --tty stats vs the 4.1.0 jar")
struct CliStatsTests {

  private func withFixtures<T>(_ body: (URL, URL) throws -> T) throws -> T {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; the binary under test is missing, which is not the same as it being correct")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(CliTtyHarness.combinational, named: "fixture.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.hierarchical, named: "hier.circ", into: dir)
    return try body(cli, dir)
  }

  /// `displayStatistics` always ends with these two rows. Used as a shape assertion, so an empty
  /// or truncated capture can never be compared equal to another empty one: the failure mode
  /// that once scored an md5 of two EMPTY outputs as OK in this project.
  private static let totalWithout = "TOTAL (without project\u{2019}s sub circuits)"
  private static let totalWith = "TOTAL (with sub circuits)"

  private static func isStatsShaped(_ text: String) -> Bool {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    guard lines.count >= 2 else { return false }
    return lines[lines.count - 2].hasSuffix(totalWithout)
      && lines[lines.count - 1].hasSuffix(totalWith)
  }

  // MARK: - The differential

  @Test("stats byte-matches the jar on both fixtures, for every circuit in them")
  func statsMatchesTheJar() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the stats differential is skipped")
      return
    }
    try withFixtures { cli, dir in
      let cases: [(file: String, circuit: String?)] = [
        ("fixture.circ", nil),
        ("fixture.circ", "main"),
        ("hier.circ", nil),
        ("hier.circ", "top"),
        ("hier.circ", "leaf"),
      ]
      for (file, circuit) in cases {
        let common = (circuit.map { ["--toplevel-circuit", $0] } ?? [])
        let swift = try CliTtyHarness.run(cli, common + ["--tty", "stats", file], cwd: dir)
        let java = try #require(try CliTtyHarness.runJar(common + ["-tty", "stats", file], cwd: dir))
        let label = "\(file)::\(circuit ?? "<main>")"

        #expect(java.status == 0, "\(label): the ORACLE failed (\(java.status)): \(java.stderr)")
        // ASSERT THE ORACLE PRODUCED OUTPUT before comparing anything to it. A jar run that
        // wrote nothing and exited 0 would otherwise be indistinguishable from agreement.
        #expect(
          Self.isStatsShaped(java.stdout),
          "\(label): the oracle produced no well-formed stats output, so there is nothing to compare against")

        #expect(swift.status == 0, "\(label): the CLI failed (\(swift.status)): \(swift.stderr)")
        #expect(
          Self.isStatsShaped(swift.stdout),
          "\(label): the CLI produced no well-formed stats output")
        #expect(
          swift.stdout == java.stdout,
          """
          \(label): stats output differs.
          java:
          \(java.stdout)
          swift:
          \(swift.stdout)
          """)
      }
    }
  }

  // MARK: - The parts a byte comparison would not localise

  @Test("the totals row uses U+2019, not an ASCII apostrophe")
  func totalsRowUsesTheTypographicApostrophe() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "stats", "fixture.circ"], cwd: dir)
      #expect(r.status == 0, "\(r.stderr)")
      #expect(
        r.stdout.contains("TOTAL (without project\u{2019}s sub circuits)"),
        "gui.properties spells this with U+2019 RIGHT SINGLE QUOTATION MARK; an ASCII ' fails every row of the gate and looks identical in a terminal")
      #expect(
        !r.stdout.contains("project's"),
        "the ASCII apostrophe is present, so the string was retyped rather than copied from gui.properties")
    }
  }

  @Test("the hierarchical fixture separates simple, unique and recursive counts")
  func hierarchicalCountsAreDistinct() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(
        cli, ["--toplevel-circuit", "top", "--tty", "stats", "hier.circ"], cwd: dir)
      #expect(r.status == 0, "\(r.stderr)")
      let rows = r.stdout.split(separator: "\n").map(String.init)

      // These are the jar's own numbers for this fixture, transcribed from a verified run. They
      // are asserted individually as well as byte-compared above, because a byte comparison says
      // "different" without saying which column, and this is the file that documents what the
      // columns mean.
      //
      //    2   2  leaf      hier      <- the subcircuit itself, placed twice
      //    6   9  Pin       Wiring    <- 3 in top + 3 in leaf unique; 3 + 2*3 recursive
      //    1   2  AND Gate  Gates     <- 0 in top, 1 in leaf; 2*1 recursive
      //    1   1  OR Gate   Gates
      //    8  12  TOTAL (without …)   <- `leaf` excluded, being a project subcircuit
      //   10  14  TOTAL (with …)
      #expect(rows.count == 6, "expected 4 component rows and 2 totals, got \(rows.count): \(rows)")
      #expect(rows.contains { $0.hasPrefix(" 6\t 9\tPin") }, "Pin row wrong: \(rows)")
      #expect(rows.contains { $0.hasPrefix(" 1\t 2\tAND Gate") }, "AND Gate row wrong: \(rows)")
      #expect(rows.contains { $0.hasPrefix(" 2\t 2\tleaf") }, "leaf row wrong: \(rows)")
      #expect(
        rows.contains { $0.hasPrefix(" 8\t12\t\(Self.totalWithout)") },
        "without-subcircuits total wrong — `leaf` must be excluded from it: \(rows)")
      #expect(
        rows.contains { $0.hasPrefix("10\t14\t\(Self.totalWith)") },
        "with-subcircuits total wrong: \(rows)")
    }
  }

  @Test("column widths come from the with-subcircuits total, not from each row")
  func columnWidthsComeFromTheGrandTotal() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(
        cli, ["--toplevel-circuit", "top", "--tty", "stats", "hier.circ"], cwd: dir)
      #expect(r.status == 0, "\(r.stderr)")
      // `total.uniqueCount` is 10 and `total.recursiveCount` is 14, so both columns are two
      // characters wide and every single-digit entry is space-padded: including on the
      // WITHOUT-subcircuits row, whose own values (8, 12) would have given widths 1 and 2.
      // Computing the format per row instead would print "8\t12" there and " 2\t 2" nowhere.
      #expect(
        r.stdout.contains(" 2\t 2\t"),
        "single-digit counts are not padded to the grand total's width: \(r.stdout)")
      #expect(
        r.stdout.contains(" 8\t12\t\(Self.totalWithout)"),
        "the without-subcircuits row is not using the grand total's column widths: \(r.stdout)")
    }
  }

  @Test("the component name column is padded to the widest display name")
  func nameColumnIsPaddedToTheWidestName() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "stats", "fixture.circ"], cwd: dir)
      #expect(r.status == 0, "\(r.stderr)")
      // maxName is len("AND Gate") == 8, so "Pin" is padded to 8 and "AND Gate" is not padded.
      #expect(r.stdout.contains("\tPin     \t"), "name column not left-padded to 8: \(r.stdout)")
      #expect(r.stdout.contains("\tAND Gate\t"), "widest name must not gain padding: \(r.stdout)")
    }
  }
}
