// CliExitCodeTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHY EXIT CODES GET THEIR OWN SUITE ══════════════════════════════════════════════════════
//
// Upstream #1546 asks for a usable command-line verification path, and the reason it matters
// here is that the owner grades CSC258 labs: a grading loop is a shell script, and a shell
// script branches on `$?`. An exit code is therefore part of the interface, and it is exactly
// the kind of thing that gets transcribed wrong once and never noticed again; nothing in the
// output looks different when the number is wrong.
//
// Every expectation below was MEASURED against the shipped 4.1.0 jar rather than read off the
// Java source, and three of the five results contradicted the reading:
//
//   * `System.exit(-1)` surfaces to the shell as **255**, not -1 and not 1.
//   * An **oscillating** circuit under `-tty table` exits **0**. `doTableAnalysis` substitutes
//     `Value.createError(width)` for every output and returns 0 unconditionally
//     (TtyInterface:437-444, :454). Upstream's exit 1 lives exclusively on the `runSimulation`
//     path, which is unreachable without an output pin labelled `halt`. Measured on
//     `2.7.1__case-514.circ::main`: every column printed `0xEE`/`EEEE` and the process exited 0. **A
//     grader must test the rows, not the status.**
//   * An **unrecognised `-tty` format exits 0**. `handleArgTty` returns `RC.QUIT`, `parseArgs`
//     returns the startup object rather than null (Startup:410), and `Main` then calls
//     `System.exit(0)` because `shallQuit()` is documented as "termination (w/o error)".
//
// The last one is the single deliberate divergence and the test for it is the point of this
// suite: `logisim-cli --tty tabel lab.circ` under upstream's contract prints nothing, exits 0,
// and passes every student in the loop. That is the same silent-empty-output class this project
// has been bitten by twice. This binary exits 2.
//
// ── The jar comparisons skip loudly, the port assertions never skip ─────────────────────────
//
// The fixtures are self-contained (see `CliTtyHarness`), so the port-side expectations always
// run. The jar-differential tests print a line and pass when the oracle is absent, matching
// `TruthTableGoldenTests`' convention for a missing corpus, but a MISSING BINARY is reported as
// a failure, because "the thing under test could not be found" must never read as "the thing
// under test is fine".

import Foundation
import Testing

@Suite("logisim-cli — the exit-code contract a grading script branches on")
struct CliExitCodeTests {

  private func withFixtures<T>(_ body: (URL, URL) throws -> T) throws -> T {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; the binary under test is missing, which is not the same as it being correct")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(CliTtyHarness.combinational, named: "fixture.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.hierarchical, named: "hier.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.unparseable, named: "broken.circ", into: dir)
    return try body(cli, dir)
  }

  // MARK: - 0: the requested output was produced

  @Test("a successful --tty run exits 0 and writes something")
  func successExitsZero() throws {
    try withFixtures { cli, dir in
      for formats in ["stats", "table", "stats,table"] {
        let r = try CliTtyHarness.run(cli, ["--tty", formats, "fixture.circ"], cwd: dir)
        #expect(r.status == 0, "--tty \(formats): exited \(r.status): \(r.stderr)")
        // ASSERT THE RUN PRODUCED OUTPUT. An entry point that writes nothing and exits 0 looks
        // exactly like agreement, and that has scored a false pass in this project before.
        #expect(
          !r.stdout.isEmpty,
          "--tty \(formats) exited 0 having written NOTHING; a silent success is the failure mode this assertion exists for")
      }
    }
  }

  // MARK: - 255: a file that will not parse

  @Test("a file that will not parse exits 255, as Java's System.exit(-1) does")
  func unparseableFileExits255() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "stats", "broken.circ"], cwd: dir)
      #expect(
        r.status == 255,
        "expected 255 (upstream TtyInterface:277 System.exit(-1)), got \(r.status)")
      #expect(r.stdout.isEmpty, "a failed load must not write a partial table to stdout")
    }
  }

  @Test("a file that does not exist exits 255 too")
  func missingFileExits255() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "stats", "no-such-file.circ"], cwd: dir)
      #expect(r.status == 255, "expected 255, got \(r.status)")
    }
  }

  // MARK: - 255: an unknown circuit name

  @Test("--toplevel-circuit naming no circuit exits 255, for both formats")
  func unknownCircuitExits255() throws {
    try withFixtures { cli, dir in
      // Upstream NPEs in two different places depending on the format, `Analyze.getPinLabels`
      // for `table`, `FileStatistics.doSimpleCount` for `stats`, and `Startup.run`'s
      // `catch (Exception)` funnels both to exit(-1). Both were measured; both are asserted,
      // because a port that got one right and the other wrong would look correct from either
      // half alone.
      for formats in ["stats", "table"] {
        let r = try CliTtyHarness.run(
          cli, ["--toplevel-circuit", "NoSuchCircuit", "--tty", formats, "fixture.circ"], cwd: dir)
        #expect(r.status == 255, "--tty \(formats): expected 255, got \(r.status)")
        #expect(r.stdout.isEmpty, "--tty \(formats): nothing may be written for a missing circuit")
      }
    }
  }

  @Test("--toplevel-circuit is accepted on either side of the subcommand")
  func toplevelCircuitParsesInEitherPosition() throws {
    try withFixtures { cli, dir in
      // Upstream's own order puts the global first. Accepting only the trailing form is what made
      // rig.py's simulation mode report 0/1392 for its entire existence, so both are pinned.
      let before = try CliTtyHarness.run(
        cli, ["--toplevel-circuit", "leaf", "--tty", "stats", "hier.circ"], cwd: dir)
      let after = try CliTtyHarness.run(
        cli, ["--tty", "stats", "--toplevel-circuit", "leaf", "hier.circ"], cwd: dir)
      #expect(before.status == 0, "leading --toplevel-circuit: \(before.stderr)")
      #expect(after.status == 0, "trailing --toplevel-circuit: \(after.stderr)")
      #expect(!before.stdout.isEmpty, "leading form produced no output")
      #expect(
        before.stdout == after.stdout,
        "the two positions produced different output; one of the parse paths is not reaching the same circuit")

      // And it must actually SELECT: `leaf` and `top` differ, so a --toplevel-circuit that were
      // silently ignored would be caught here rather than passing on identical output.
      let top = try CliTtyHarness.run(
        cli, ["--toplevel-circuit", "top", "--tty", "stats", "hier.circ"], cwd: dir)
      #expect(
        top.stdout != before.stdout,
        "stats for `top` and `leaf` are identical, so --toplevel-circuit is being ignored")
    }
  }

  // MARK: - 2: our own usage errors, including the deliberate divergence

  @Test("an unrecognised --tty format exits 2 — upstream exits 0, and that is the defect")
  func unknownFormatExitsNonZero() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "tabel", "fixture.circ"], cwd: dir)
      #expect(
        r.status == 2,
        "expected 2. Upstream returns 0 here (handleArgTty -> RC.QUIT -> shallQuit -> System.exit(0)), which would make a typo'd format pass every student in a grading loop.")
      #expect(r.stdout.isEmpty, "nothing may be written for a format that was not understood")
      #expect(!r.stderr.isEmpty, "a refused format must say so on stderr")
    }
  }

  @Test("the real upstream formats we do not implement are refused, not silently ignored")
  func unimplementedUpstreamFormatsAreRefused() throws {
    try withFixtures { cli, dir in
      // `speed` and `halt` report on `runSimulation`, which needs an output pin labelled `halt`;
      // the corpus has 6 such circuits and the jar produces usable output for NONE of them (4
      // will not load, 2 do not terminate in 40 s), so there is nothing to gate an implementation
      // against. `tty` needs Tty/Keyboard plus a stdin thread.
      //
      // `binary`/`hex`/`csv`/`tabs` ARE implemented now, and are accepted alongside `table`;
      // `CliTableFormatTests` gates all four against the jar. They are still refused *on their
      // own*, but for a different and stronger reason: a bare modifier sets no `FORMAT_TABLE`
      // bit, so upstream falls through to `runSimulation` and never terminates. Measured, 20 s
      // cap, all four killed having printed nothing. See `CliTableFormatTests`.
      //
      // The refusal is the load-bearing part either way: accepting one of these and printing
      // nothing would be a passing run with no output.
      for format in ["speed", "halt", "tty", "binary", "hex", "csv", "tabs"] {
        let r = try CliTtyHarness.run(cli, ["--tty", format, "fixture.circ"], cwd: dir)
        #expect(r.status == 2, "--tty \(format): expected a refusal (2), got \(r.status)")
        #expect(
          r.stdout.isEmpty,
          "--tty \(format): refused but still wrote to stdout")
      }
      // …and `table` rescues exactly the four that are modifiers, so the loop above is testing
      // the missing `table` and not "these four are unimplemented". Without this, deleting the
      // modifier implementation entirely would leave the loop above green.
      for format in ["binary", "hex", "csv", "tabs"] {
        let r = try CliTtyHarness.run(cli, ["--tty", "table,\(format)", "fixture.circ"], cwd: dir)
        #expect(r.status == 0, "--tty table,\(format): expected 0, got \(r.status): \(r.stderr)")
        #expect(!r.stdout.isEmpty, "--tty table,\(format) exited 0 having written NOTHING")
      }

      // A comma list is refused if ANY member is unimplemented, so a grader cannot get a partial
      // answer that looks complete.
      let mixed = try CliTtyHarness.run(cli, ["--tty", "stats,speed", "fixture.circ"], cwd: dir)
      #expect(mixed.status == 2, "stats,speed: expected 2, got \(mixed.status)")
      #expect(
        mixed.stdout.isEmpty,
        "stats,speed printed the stats half and refused the rest; a partial answer that exits nonzero is still a partial answer written to stdout")
    }
  }

  @Test("format order does not change the bytes, because upstream emits stats first")
  func formatOrderIsNormalised() throws {
    try withFixtures { cli, dir in
      let a = try CliTtyHarness.run(cli, ["--tty", "stats,table", "fixture.circ"], cwd: dir)
      let b = try CliTtyHarness.run(cli, ["--tty", "table,stats", "fixture.circ"], cwd: dir)
      #expect(a.status == 0 && b.status == 0)
      #expect(!a.stdout.isEmpty)
      #expect(
        a.stdout == b.stdout,
        "TtyInterface.run prints statistics at :291-294 before it looks at the remaining format bits, so the typed order must not matter")
    }
  }

  // MARK: - The same five questions, asked of the jar

  @Test("the jar agrees on every exit code this suite pins")
  func theJarAgrees() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the exit-code differential is skipped")
      return
    }
    try withFixtures { _, dir in
      // (arguments, expected jar status, what it is)
      let cases: [([String], Int32, String)] = [
        (["-tty", "stats", "fixture.circ"], 0, "success"),
        (["-tty", "table", "fixture.circ"], 0, "success"),
        (["-tty", "stats", "broken.circ"], 255, "a file that will not parse"),
        (["-tty", "stats", "no-such-file.circ"], 255, "a file that does not exist"),
        (
          ["--toplevel-circuit", "NoSuchCircuit", "-tty", "stats", "fixture.circ"], 255,
          "an unknown circuit name"
        ),
        (
          ["--toplevel-circuit", "NoSuchCircuit", "-tty", "table", "fixture.circ"], 255,
          "an unknown circuit name"
        ),
        // THE DIVERGENCE, asserted against the jar so the claim in this file's header cannot
        // quietly stop being true. If upstream ever fixes #1546 this test goes red and the
        // divergence note above needs revisiting.
        (["-tty", "tabel", "fixture.circ"], 0, "an unrecognised format — upstream's exit 0"),
      ]
      for (arguments, expected, what) in cases {
        let r = try #require(try CliTtyHarness.runJar(arguments, cwd: dir))
        #expect(
          r.status == expected,
          "jar \(arguments.joined(separator: " ")) [\(what)]: expected \(expected), got \(r.status)")
      }
    }
  }
}
