// CliTestVectorTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ THE ONE ASSERTION THAT MATTERS ══════════════════════════════════════════════════════════
//
// `logisim-cli --test-vector` must EXIT NONZERO when a vector fails. Upstream does not, and a
// grading loop that trusted it would pass every submission.
//
// Both halves of that claim are pinned here: `failingVectorsExitNonZero` asserts the port, and
// `theJarCannotDoThis` asserts, against the real jar, that upstream cannot. The second test
// is not decoration. It is the reason the first one is allowed to diverge from the oracle, and
// if upstream ever fixes #1546 it goes red and the divergence needs revisiting rather than
// silently outliving its justification.
//
// ── What upstream actually does, measured ───────────────────────────────────────────────────
//
//   $ java -Djava.awt.headless=true -jar J --test-vector ripple_carry4 test.txt golden-08.circ
//   Exception in thread "main" java.awt.HeadlessException
//       ... at com.cburch.logisim.gui.generic.OptionPane.showMessageDialog(OptionPane.java:53)
//       at com.cburch.logisim.Main.main(Main.java:81)
//   EXIT=1, stdout empty
//
// `Main.headless` is set only for `-t`/`--tty` and `--test-fpga` (Startup.java:357-360), so
// `--test-vector` takes the GUI branch, throws, and `Main`'s `catch (Throwable)` then throws a
// SECOND HeadlessException out of its own first statement, the `OptionPane.showMessageDialog`
// call, so `System.exit(100)` below it never runs.
//
// And on a machine WITH a display it would still be useless: `Startup.java:1029` discards
// `proj.doTestVector(...)`'s return value, and the run ends at
// `if (exitAfterStartup) System.exit(0);` (Startup.java:1075-1077). Unconditional zero.
//
// ── The output itself is gated elsewhere ────────────────────────────────────────────────────
//
// `tools/difftest/ttybridge/vectorgate.py` diffs this subcommand's stdout byte-for-byte against
// `TestVectorBridge.java`, which reaches the same Java code path with `Main.headless = true`:
// **62 byte-exact, 0 fail, 580 setup-refusals agreeing on both sides.** This suite covers what
// that gate deliberately does not: the exit code, which is where port and oracle differ on
// purpose.

import Foundation
import Testing

@Suite("logisim-cli --test-vector — the exit code upstream throws away")
struct CliTestVectorTests {

  private func withFixtures<T>(_ body: (URL, URL) throws -> T) throws -> T {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; the binary under test is missing, which is not the same as it being correct")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(CliTtyHarness.combinational, named: "fixture.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.passingVectors, named: "pass.txt", into: dir)
    try CliTtyHarness.write(CliTtyHarness.failingVectors, named: "fail.txt", into: dir)
    try CliTtyHarness.write(CliTtyHarness.wrongWidthVectors, named: "width.txt", into: dir)
    return try body(cli, dir)
  }

  // MARK: - The contract

  @Test("all vectors passing exits 0 and says so")
  func passingVectorsExitZero() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "pass.txt", "fixture.circ"], cwd: dir)
      #expect(r.status == 0, "expected 0, got \(r.status): \(r.stderr)")
      // The tally is asserted, not just the status: a run that evaluated ZERO vectors would
      // also have no failures and would also exit 0.
      #expect(
        r.stdout.contains("Passed: 4, Failed: 0"),
        "expected all four vectors to be evaluated and pass: \(r.stdout)")
    }
  }

  @Test("a failing vector exits 1 — this is the whole reason the subcommand exists")
  func failingVectorsExitNonZero() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "fail.txt", "fixture.circ"], cwd: dir)
      #expect(
        r.status == 1,
        "expected 1. Upstream exits 0 here — Startup.java:1029 discards doTestVector's return and Startup.java:1075 exits 0 unconditionally — so a grading loop would score every submission as passing. Got \(r.status).")
      #expect(
        r.stdout.contains("Passed: 2, Failed: 2"),
        "expected exactly two of four vectors to fail: \(r.stdout)")
      // The per-row diagnostic is what tells a student WHICH row was wrong, and upstream prints
      // it to stdout. `q = <computed> (expected <expected>)`.
      #expect(
        r.stdout.contains("q = ") && r.stdout.contains("expected"),
        "no per-row report was printed, so a failing run says nothing actionable: \(r.stdout)")
    }
  }

  @Test("a vector file that cannot be bound to the circuit exits 255, not 1")
  func setupFailureExits255() throws {
    try withFixtures { cli, dir in
      // "the test could not be run" must be distinguishable from "the test ran and failed";
      // a grading script needs to tell a broken harness from a wrong answer. Upstream's
      // `doTestVector` returns -1 for both of these, which is 255 to a shell.
      let width = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "width.txt", "fixture.circ"], cwd: dir)
      #expect(width.status == 255, "width mismatch: expected 255, got \(width.status)")

      let missingCircuit = try CliTtyHarness.run(
        cli, ["--test-vector", "NoSuchCircuit", "pass.txt", "fixture.circ"], cwd: dir)
      #expect(
        missingCircuit.status == 255,
        "unknown circuit: expected 255, got \(missingCircuit.status)")

      let missingVectors = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "no-such-vectors.txt", "fixture.circ"], cwd: dir)
      #expect(
        missingVectors.status == 255,
        "missing vector file: expected 255, got \(missingVectors.status)")

      let missingCirc = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "pass.txt", "no-such-file.circ"], cwd: dir)
      #expect(
        missingCirc.status == 255,
        "missing circuit file: expected 255, got \(missingCirc.status)")
    }
  }

  @Test("--toplevel-circuit selects the circuit too, so all three verbs agree")
  func toplevelCircuitIsAccepted() throws {
    try withFixtures { cli, dir in
      let positional = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "pass.txt", "fixture.circ"], cwd: dir)
      let global = try CliTtyHarness.run(
        cli, ["--toplevel-circuit", "main", "--test-vector", "pass.txt", "fixture.circ"],
        cwd: dir)
      #expect(positional.status == 0 && global.status == 0, "\(global.stderr)")
      #expect(!positional.stdout.isEmpty)
      #expect(
        positional.stdout == global.stdout,
        "the two ways of naming the circuit produced different output")
    }
  }

  // MARK: - The premise: upstream's own flag

  @Test("the jar's --test-vector is unusable headless, which is what licenses the divergence")
  func theJarCannotDoThis() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the upstream premise check is skipped")
      return
    }
    try withFixtures { _, dir in
      let r = try #require(
        try CliTtyHarness.runJar(
          ["--test-vector", "main", "fail.txt", "fixture.circ"], cwd: dir))
      // The specific failure is a HeadlessException thrown OUT OF Main's own catch block, so
      // exit 100 (the handler's intended code) is never reached and the JVM dies with 1.
      #expect(
        r.status != 0,
        "the jar now exits \(r.status) for --test-vector; if upstream has fixed #1546, this port's deliberate exit-code divergence needs revisiting rather than being carried forward")
      #expect(
        r.stdout.isEmpty,
        "the jar produced output for --test-vector, so it is no longer dying before it starts: \(r.stdout)")
      #expect(
        r.stderr.contains("HeadlessException"),
        "expected the documented HeadlessException; upstream's failure mode has changed: \(r.stderr)")
    }
  }
}
