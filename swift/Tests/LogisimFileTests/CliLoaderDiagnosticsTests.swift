// CliLoaderDiagnosticsTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS PROVES, AND THE PREMISE IT CORRECTS ═══════════════════════════════════════════
//
// `HeadlessLoaderUI` records every `showError`/`showMessage` into two arrays. Until this suite's
// change nothing read them back, so `logisim-cli` loaded a file naming an unresolvable library in
// total silence. `LibraryDropDivergenceTests` already proved the message is *produced*; this
// suite proves it now *arrives*.
//
// ── The premise handed over with this work was half wrong ───────────────────────────────────
//
// It said: "where the jar logs `the built-in library #Risc-V is not available`, the port prints
// nothing." The second half held. **The first half does not: the jar prints nothing either.**
//
// `Loader.showError` (`Loader.java:579`) branches on
// `description.contains("\n") || description.length() > 60`. The long branch wraps the text in a
// `JScrollPane` and passes *that* to `OptionPane.showMessageDialog`, whose headless arm is
// `else if (message instanceof String)` (`OptionPane.java:71`). A JScrollPane is not a String, so
// the message is dropped on the floor. `The built-in library “Risc-V” is not available in this
// version.` is 63 characters. It loses by three.
//
// Three fixtures, run as `java -Djava.awt.headless=true -jar J -tty table <f>`, all exit 0:
//
//   fixture                          jar stderr
//   -------------------------------- -----------------------------------------------------------
//   <lib desc="bogus"/>              ERROR …OptionPane - File Error:…: Unrecognized library
//                                    descriptor bogus                      (35 chars, logged)
//   <lib desc="#Risc-V"/>            (nothing at all)                      (63 chars; dropped)
//   source="2.7.1"                   WARN  …OptionPane - Old file format -- compatibility mode:
//                                    You are opening a file created with…  (3 lines, LOGGED)
//
// The third is the one that makes it a measurement rather than a story: it is *longer* than the
// `#Risc-V` message and is still logged, because its call site passes a plain `String`. The
// suppression is about the ARGUMENT'S TYPE, and length only decides which argument gets built.
//
// ── The divergence, and its limit ───────────────────────────────────────────────────────────
//
// The port prints every recorded diagnostic whatever its length, because the class upstream
// suppresses is exactly the class that costs the user components (D8: 14 components in, 13 out).
// The message TEXT is upstream's byte for byte, so a script grepping upstream's wording still
// matches.
//
// **Exit codes do not move, and that is asserted here rather than merely intended.** 39 corpus
// files name a library 4.1.0 cannot resolve; making that nonzero would turn the migration gate
// red for a condition upstream tolerates. Diagnostics go to stderr and stdout is untouched, so
// `rig.py` and `statsgate.py` keep diffing exactly what they diffed before.

import Foundation
import Testing

@Suite("logisim-cli surfaces what the loader recorded")
struct CliLoaderDiagnosticsTests {

  private func withFixtures<T>(_ body: (URL, URL) throws -> T) throws -> T {
    let cli = try #require(
      CliTtyHarness.cliURL,
      "logisim-cli was not found in the build products directory; the binary under test is missing, which is not the same as it being correct")
    let dir = try CliTtyHarness.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try CliTtyHarness.write(CliTtyHarness.combinational, named: "clean.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.unresolvableLibrary, named: "riscv.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.badDescriptor, named: "baddesc.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.oldFormat, named: "old.circ", into: dir)
    try CliTtyHarness.write(CliTtyHarness.passingVectors, named: "vectors.txt", into: dir)
    return try body(cli, dir)
  }

  // MARK: - The gap that was closed

  @Test("an unresolvable builtin library is reported on stderr, for all three verbs")
  func theUnresolvableLibraryIsSurfaced() throws {
    try withFixtures { cli, dir in
      // The exact upstream wording, from `FileStrings.fileBuiltinMissingError`. Note the name is
      // `Risc-V` and not `#Risc-V`: upstream's `loadLibrary` splits the descriptor at the `#` and
      // formats the SUFFIX (`LibraryManager.java:257,263`).
      let expected = "The built-in library \u{201C}Risc-V\u{201D} is not available in this version."

      let tty = try CliTtyHarness.run(cli, ["--tty", "table", "riscv.circ"], cwd: dir)
      #expect(tty.stderr.contains(expected), "--tty said nothing; got: \(tty.stderr.debugDescription)")

      let convert = try CliTtyHarness.run(cli, ["--convert", "riscv.circ", "out.circ"], cwd: dir)
      #expect(
        convert.stderr.contains(expected),
        "--convert said nothing; got: \(convert.stderr.debugDescription)")

      let vectors = try CliTtyHarness.run(
        cli, ["--test-vector", "main", "vectors.txt", "riscv.circ"], cwd: dir)
      #expect(
        vectors.stderr.contains(expected),
        "--test-vector said nothing; got: \(vectors.stderr.debugDescription)")
    }
  }

  @Test("the short-message case, which the jar DOES log, is surfaced with the same wording")
  func theShortDescriptorErrorIsSurfaced() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "table", "baddesc.circ"], cwd: dir)
      #expect(
        r.stderr.contains("Unrecognized library descriptor bogus"),
        "got: \(r.stderr.debugDescription)")
      // `Loader.showError` prefixes the project name when a file is open, exactly as upstream
      // does (`Loader.java:572-577`). Asserted so the prefix is not quietly dropped: it is what
      // tells a grader WHICH submission the message belongs to when several are converted in one
      // loop.
      #expect(
        r.stderr.contains("baddesc: Unrecognized"),
        "the project-name prefix is missing; got: \(r.stderr.debugDescription)")
    }
  }

  @Test("the pre-2.7.2 compatibility notice arrives too — it is a message, not an error")
  func theOldFormatWarningIsSurfaced() throws {
    try withFixtures { cli, dir in
      let r = try CliTtyHarness.run(cli, ["--tty", "table", "old.circ"], cwd: dir)
      #expect(
        r.stderr.contains("You are opening a file created with original Logisim code."),
        "got: \(r.stderr.debugDescription)")
      #expect(r.status == 0, "an old-format file still loads and still exits 0")
    }
  }

  // MARK: - What must NOT move

  @Test("a diagnostic does not change the exit code, and does not touch stdout")
  func diagnosticsAreStderrOnlyAndStatusPreserving() throws {
    try withFixtures { cli, dir in
      // THE ASSERTION THAT KEEPS THE CORPUS GATES GREEN. 39 corpus files name a library 4.1.0
      // cannot resolve. If a diagnostic made the status nonzero, `rig.py` would score every one
      // of them as a failed case; if it went to stdout, every one would fail the byte compare.
      let clean = try CliTtyHarness.run(cli, ["--tty", "table", "clean.circ"], cwd: dir)
      let noisy = try CliTtyHarness.run(cli, ["--tty", "table", "riscv.circ"], cwd: dir)
      #expect(clean.status == 0)
      #expect(!clean.stdout.isEmpty, "the control fixture produced no table; nothing is proven")
      #expect(noisy.status == 0, "a recorded loader error must not change the exit code")
      #expect(!noisy.stderr.isEmpty, "…but it must still be said")
      #expect(
        noisy.stdout == clean.stdout,
        "the unresolvable library changed stdout; the gates compare stdout byte for byte")
      #expect(
        clean.stderr.isEmpty,
        "a clean file emitted a diagnostic: \(clean.stderr.debugDescription) — every corpus run would now be noisy")
    }
  }

  @Test("a load FAILURE prints the recorded diagnostics before it gives up")
  func aFailedLoadStillExplainsItself() throws {
    try withFixtures { cli, dir in
      try CliTtyHarness.write(CliTtyHarness.unparseable, named: "broken.circ", into: dir)
      let r = try CliTtyHarness.run(cli, ["--tty", "table", "broken.circ"], cwd: dir)
      #expect(r.status == 255, "expected 255, got \(r.status)")
      #expect(!r.stderr.isEmpty, "a failed load must say something")
      #expect(r.stdout.isEmpty, "a failed load must not write a partial table")
    }
  }

  // MARK: - The jar side, so the divergence cannot quietly stop being true

  @Test("the jar is silent on the long message and loud on the short one — still")
  func theJarStillSuppressesTheLongMessage() throws {
    guard CliTtyHarness.javaURL != nil, CliTtyHarness.jarURL != nil else {
      print("openjdk@21 or the 4.1.0 jar is not installed — the diagnostic differential is skipped")
      return
    }
    try withFixtures { _, dir in
      let riscv = try #require(try CliTtyHarness.runJar(["-tty", "table", "riscv.circ"], cwd: dir))
      #expect(riscv.status == 0, "the jar loads the file despite the missing library")
      #expect(
        !riscv.stdout.isEmpty,
        "the ORACLE produced no table, so this case proves nothing about its diagnostics")
      #expect(
        !(riscv.stdout + riscv.stderr).contains("Risc-V"),
        """
        The jar now mentions the unresolvable library. That is upstream fixing the >60-char \
        JScrollPane suppression, and it is good news — but the divergence note in \
        logisim-cli/main.swift and this file's header both claim it is silent, so both need \
        revisiting before this test is relaxed.
        """)

      let bad = try #require(try CliTtyHarness.runJar(["-tty", "table", "baddesc.circ"], cwd: dir))
      #expect(
        (bad.stdout + bad.stderr).contains("Unrecognized library descriptor bogus"),
        """
        The jar has stopped logging the SHORT loader error too. Without this half the \
        length-dependence is unmeasured, and the claim that the port merely removes a \
        length threshold would be unsupported.
        """)

      let old = try #require(try CliTtyHarness.runJar(["-tty", "table", "old.circ"], cwd: dir))
      #expect(
        (old.stdout + old.stderr).contains("You are opening a file created with original"),
        "the jar has stopped logging the pre-2.7.2 notice; the third measured point is gone")
    }
  }
}
