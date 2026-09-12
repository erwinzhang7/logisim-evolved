// CliTableFormatTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS PROVES ════════════════════════════════════════════════════════════════════════
//
// `--tty table` plus each of upstream's four modifiers, `binary`, `hex`, `csv`, `tabs`,
// byte-matches `java -jar logisim-evolution-4.1.0-all.jar -tty <same>` on fixtures checked into
// this repo. The corpus-wide version is `tools/difftest/ttybridge/tablefmtgate.py`; this suite is
// the part that runs with no private corpus present, so a regression cannot wait for someone to
// remember to run the gate.
//
// `csv` is the one that earns its keep. The owner TAs CSC258 and grades lab submissions, and a
// CSV truth table diffs directly against a solution: `--tty table,csv student.circ` next to the
// same for the reference, and `diff` is the whole grader.
//
// ── The claim that was checked before it was believed ───────────────────────────────────────
//
// The note handing this work over said the four modifiers were "one `switch` inside
// `TruthTableRun.valueFormat`". Read against `TtyInterface.java` that is HALF right, and the
// wrong half is the one that would have shipped broken:
//
//   * `binary` / `hex` ARE `valueFormat` (`:189-200`).
//   * `csv` / `tabs` are NOT in `valueFormat` at all. They are in `displayTableRow` (`:158-186`)
//     and change TWO things: the separator, and the per-column format string, which becomes
//     `"%s"` instead of `"%" + w + "s"`. **A csv or tabs table is not padded**, and the header
//     row's width computation is skipped entirely.
//
// A `valueFormat`-only implementation would have emitted padded, space-separated rows for
// `--tty table,csv`, and every row would have differed from the jar.
//
// ── Three more measured facts, each with its own test below ─────────────────────────────────
//
//   -tty table,binary        `000 0000`     FORMAT_TABLE_BIN is `Value.toString()`, which puts a
//                                           space every four bits. NOT `toBinaryString()`.
//   -tty table,csv,binary    `0,000 0000`   so a CSV field can contain a space. Reproduced,
//                                           because nothing upstream can render a comma.
//   -tty table,csv,tabs      tab wins       TABBED is tested first (`:160`)
//   -tty table,binary,hex    binary wins    BIN is tested first (`:190`)
//
// ── Why every test here uses `wide`, not `combinational` ────────────────────────────────────
//
// At width 1 all three value styles render the same single character, so on `combinational` the
// jar produces byte-identical output for `table`, `table,binary` and `table,hex`. A suite built
// on it would pass against an implementation that ignored the modifiers entirely. `wide` has two
// 7-bit columns; see `CliTtyHarness.wide` for why 7 and not 8.

import Foundation
import Testing

@Suite("logisim-cli --tty table modifiers vs the 4.1.0 jar")
struct CliTableFormatTests {

  /// Every combination gated. `table` is the control: if it fails, the defect is in the table
  /// itself and not in a modifier, and `rig.py` will be red too.
  static let formats = [
    "table",
    "table,csv",
    "table,tabs",
    "table,binary",
    "table,hex",
    "table,csv,binary",
    "table,csv,hex",
    "table,tabs,binary",
    "table,csv,tabs",
    "table,binary,hex",
    "stats,table,csv",
  ]

  private func withFixtures<T>(_ body: (URL, URL) throws -> T) throws -> T {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; the binary under test is missing, which is not the same as it being correct")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(CliTtyHarness.wide, named: "wide.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.combinational, named: "fixture.circ", into: dir)
    return try body(cli, dir)
  }

  /// A table is a header line plus at least one row. Asserted on every capture before it is
  /// compared, so an empty output can never be scored equal to another empty output: the
  /// failure mode that once let an md5 of two EMPTY captures pass a case in this project.
  private static func rows(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  // MARK: - The differential

  @Test("every table format byte-matches the jar, on a fixture where they differ")
  func everyFormatMatchesTheJar() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the table-format differential is skipped")
      return
    }
    try withFixtures { cli, dir in
      for format in Self.formats {
        let jar = try #require(try CliTtyHarness.runJar(["-tty", format, "wide.circ"], cwd: dir))
        let port = try CliTtyHarness.run(cli, ["--tty", format, "wide.circ"], cwd: dir)

        // THE ORACLE MUST HAVE PRODUCED SOMETHING. An entry point that writes nothing and exits
        // 0 looks exactly like agreement, and that has scored a false pass here twice.
        #expect(jar.status == 0, "jar -tty \(format): exited \(jar.status)")
        #expect(
          Self.rows(jar.stdout).count >= 2,
          "the ORACLE produced no table for -tty \(format); there is nothing to compare against")

        #expect(port.status == jar.status, "-tty \(format): status \(port.status) vs \(jar.status)")
        #expect(
          port.stdout == jar.stdout,
          """
          -tty \(format) differs from the jar.
            jar : \(Self.rows(jar.stdout).prefix(3).map { $0.debugDescription }.joined(separator: " | "))
            port: \(Self.rows(port.stdout).prefix(3).map { $0.debugDescription }.joined(separator: " | "))
          """)
      }
    }
  }

  // MARK: - The specific decisions, pinned literally
  //
  // The differential above already covers these, but only while the jar is installed. These
  // assert the exact bytes so the rules survive on a machine with no JDK, and so that a reader
  // can see what `binary` actually means without running anything.

  @Test("the four modifiers each change the output in the documented way")
  func eachModifierDoesWhatItSays() throws {
    try withFixtures { cli, dir in
      func header(_ format: String) throws -> String {
        let r = try CliTtyHarness.run(cli, ["--tty", format, "wide.circ"], cwd: dir)
        #expect(r.status == 0, "-tty \(format): \(r.stderr)")
        let lines = Self.rows(r.stdout)
        #expect(lines.count == 257, "-tty \(format): expected 1 header + 256 rows, got \(lines.count)")
        return lines.count > 1 ? lines[1] : ""
      }

      // Row 0 of each: a=0, c=0, q=0, w=0. Every difference below is the modifier and nothing
      // else, because the VALUES are identical across all four.
      let pretty = try header("table")
      let hex = try header("table,hex")
      let binary = try header("table,binary")
      let csv = try header("table,csv")
      let tabs = try header("table,tabs")
      #expect(pretty == "0 0x00 0 0x00", "pretty: >6 bits is hex WITH the 0x prefix")
      #expect(hex == "0 00 0 00", "hex: no prefix, at every width")
      #expect(
        binary == "0 000 0000 0 000 0000",
        "binary is Value.toString(), which puts a space every four bits — NOT toBinaryString()")
      #expect(csv == "0,0x00,0,0x00", "csv: comma separated and UNPADDED")
      #expect(tabs == "0\t0x00\t0\t0x00", "tabs: tab separated and UNPADDED")
    }
  }

  @Test("csv and tabs are unpadded — the half that is not in valueFormat")
  func csvAndTabsDoNotPad() throws {
    try withFixtures { cli, dir in
      // The pretty header pads `a` out to the width of `0x00` below it; csv and tabs do not,
      // because upstream pushes "%s" rather than "%<w>s" for them. This is the single assertion
      // that a valueFormat-only implementation fails.
      let pretty = try CliTtyHarness.run(cli, ["--tty", "table", "wide.circ"], cwd: dir)
      let csv = try CliTtyHarness.run(cli, ["--tty", "table,csv", "wide.circ"], cwd: dir)
      let tabs = try CliTtyHarness.run(cli, ["--tty", "table,tabs", "wide.circ"], cwd: dir)
      #expect(Self.rows(pretty.stdout).first == "a    c q    w", "the pretty header must be padded")
      #expect(Self.rows(csv.stdout).first == "a,c,q,w", "csv must not pad")
      #expect(Self.rows(tabs.stdout).first == "a\tc\tq\tw", "tabs must not pad")
    }
  }

  @Test("a CSV field really can contain a space, and that is upstream's behaviour not a bug here")
  func binaryPutsASpaceInsideACsvField() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "table,csv,binary", "wide.circ"], cwd: dir)
      #expect(r.status == 0, "--tty table,csv,binary: \(r.stderr)")
      #expect(
        Self.rows(r.stdout).dropFirst().first == "0,000 0000,0,000 0000",
        """
        `binary` is `Value.toString()`, which spaces nibbles, and csv does not quote. Do not \
        "fix" this: it is what the jar prints, it is gated by tablefmtgate.py, and it stays \
        parseable because nothing upstream can render a comma — space, hex digits and the four \
        display characters are the entire alphabet.
        """)
    }
  }

  @Test("both precedence rules match the jar's test order")
  func modifierPrecedenceMatchesUpstream() throws {
    try withFixtures { cli, dir in
      // TABBED is tested before CSV (`:160`), BIN before HEX (`:190`). Asked for together,
      // upstream does not error, one silently wins, so the port must pick the same winner.
      let tabsWins = try CliTtyHarness.run(cli, ["--tty", "table,csv,tabs", "wide.circ"], cwd: dir)
      let tabsOnly = try CliTtyHarness.run(cli, ["--tty", "table,tabs", "wide.circ"], cwd: dir)
      #expect(!tabsOnly.stdout.isEmpty)
      #expect(tabsWins.stdout == tabsOnly.stdout, "csv,tabs must resolve to tabs")

      let binWins = try CliTtyHarness.run(cli, ["--tty", "table,binary,hex", "wide.circ"], cwd: dir)
      let binOnly = try CliTtyHarness.run(cli, ["--tty", "table,binary", "wide.circ"], cwd: dir)
      #expect(!binOnly.stdout.isEmpty)
      #expect(binWins.stdout == binOnly.stdout, "binary,hex must resolve to binary")
    }
  }

  @Test("the modifiers are inert at width 1, which is why this suite does not use `combinational`")
  func widthOneCannotDistinguishTheValueStyles() throws {
    try withFixtures { cli, dir in
      // Not a property of the port: a property of the FIXTURE, asserted so that nobody
      // "simplifies" this suite onto `combinational` and turns every value-style test into a
      // tautology. If this ever fails, a value style has started differing at width 1 and the
      // reasoning in the header needs revisiting.
      let plain = try CliTtyHarness.run(cli, ["--tty", "table", "fixture.circ"], cwd: dir)
      #expect(!plain.stdout.isEmpty)
      for modifier in ["binary", "hex"] {
        let r = try CliTtyHarness.run(cli, ["--tty", "table,\(modifier)", "fixture.circ"], cwd: dir)
        #expect(
          r.stdout == plain.stdout,
          "-tty table,\(modifier) differs from plain table at width 1; the header's claim that all-1-bit fixtures cannot discriminate is no longer true")
      }
    }
  }

  // MARK: - The refusal, which is a deliberate divergence

  @Test("a modifier with no `table` is refused — upstream accepts it and never terminates")
  func aBareModifierIsRefused() throws {
    try withFixtures { cli, dir in
      // `-tty csv` sets FORMAT_TABLE_CSV and no FORMAT_TABLE bit, so upstream's `format == 0`
      // early exit does not fire and `(format & FORMAT_TABLE) != 0` is false: control reaches
      // `runSimulation`, whose `while (true)` has no exit without an output pin labelled `halt`.
      // Measured on the 4.1.0 jar with a 20-second cap: all four killed, none printed anything.
      //
      // Not tested against the jar here: a passing assertion would have to WAIT for the hang,
      // and four 20-second sleeps do not belong in a suite that runs on every build.
      // `tablefmtgate.py --probe-divergences` re-measures it on demand.
      for modifier in ["csv", "tabs", "binary", "hex"] {
        let r = try CliTtyHarness.run(cli, ["--tty", modifier, "wide.circ"], cwd: dir)
        #expect(r.status == 2, "--tty \(modifier): expected 2, got \(r.status)")
        #expect(r.stdout.isEmpty, "--tty \(modifier): refused but still wrote to stdout")
        #expect(
          r.stderr.contains("table,\(modifier)"),
          "the refusal must name the spelling that works; got: \(r.stderr)")
      }
      // …and the same modifier alongside `table` is accepted, so the guard is about the missing
      // `table` and not about the modifier being unknown.
      let ok = try CliTtyHarness.run(cli, ["--tty", "table,csv", "wide.circ"], cwd: dir)
      #expect(ok.status == 0, "table,csv must be accepted: \(ok.stderr)")
      #expect(!ok.stdout.isEmpty)
    }
  }

  @Test("stats still leads, and the modifier does not leak into it")
  func statsOrderingSurvivesTheModifiers() throws {
    try withFixtures { cli, dir in
      // `TtyInterface.run` prints statistics first (`:291-294`) and clears the bit before it
      // looks at anything else, so a modifier can only ever affect the table half.
      let a = try CliTtyHarness.run(cli, ["--tty", "stats,table,csv", "wide.circ"], cwd: dir)
      let statsOnly = try CliTtyHarness.run(cli, ["--tty", "stats", "wide.circ"], cwd: dir)
      let tableOnly = try CliTtyHarness.run(cli, ["--tty", "table,csv", "wide.circ"], cwd: dir)
      #expect(a.status == 0 && !statsOnly.stdout.isEmpty && !tableOnly.stdout.isEmpty)
      #expect(
        a.stdout == statsOnly.stdout + tableOnly.stdout,
        "stats,table,csv must be the stats block followed by the csv table, unchanged")
    }
  }
}
