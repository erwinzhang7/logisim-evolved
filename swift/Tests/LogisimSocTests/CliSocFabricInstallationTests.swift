// CliSocFabricInstallationTests.swift: part of logisim-evolved.
//
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES THE **GRADING BINARY** GIVE A SoC DESIGN A BUS FABRIC?
//
// Board #49 closed seam #17 in the model: `SocCircuitBinder` reproduces Java's `Circuit.socSim`
// field and its three mutator calls. It is session-scoped by construction; "an executable must
// create a binder and attach it", says its own header, and `logisim-cli` did not. So every SoC
// design put through `--tty` or `--test-vector` simulated with **no fabric at all**, and that is
// a WRONG ANSWER rather than an error:
//
//   * `SocMemoryState.performReadAction` → `regPropagateState()` nil → `Int32.random(in:)`
//     (`SocMemoryState.swift:282`). A plausible word, different on every run.
//   * `PioState.handleOutputWriteTransaction` → `regPropagateState()` nil → the write is
//     discarded and the PIO's pins keep their old value.
//   * `SocBusInfo.simulationManager` nil → `slaveName` is `"BUG: Unknown"`.
//
// Exit 0, output produced, no diagnostic.
//
// ── WHY THIS SUITE IS NOT ALLOWED TO CONSTRUCT A BINDER, AND WHY IT LIVES HERE ───────────────
//
// `LogisimSocTests` already contains `SocCircuitBinderTests`, `SocBusFabricTests` and
// `SocCircuitStateBindingTests`. **Every one of them was green for the entire life of this
// defect**, because every one of them creates the session object itself, which is the correct
// thing for a test *of the binder* to do, and exactly what makes them incapable of noticing that
// no runtime does. A test that calls `binder.attach(to:)` passes against a CLI that never has.
//
// So this file does the only thing that can distinguish the two: it runs the shipped executable
// and inspects what **that process's own load path** left behind.
//
//     .build/<config>/logisim-cli --soc-fabric <file.circ>
//
// This target is the right home for that in spite of its siblings, and because of them: it is
// where SoC runtime behaviour is already gated, it links `LogisimSoc` so the fixtures' `_ID`s and
// attribute names are checked against the constants the codec keys on rather than typed as
// folklore (`theFixturesMatchTheRealIdentifiers`), and, the load-bearing part,
// `LogisimUITests` cannot host it. That suite asserts against `LogisimFileProjectHost`,
// which owns its own `socBinder`; a green result there says the *app* is wired and says nothing
// whatever about the CLI. Two runtimes, two integrator calls, and the CLI's was missing.
//
// Same rule as `SocCircuitBinderTests`, one notch stricter: **no line below this header CALLS
// `SocCircuitBinder`, `attach` or `registerComponent`.** The three names do appear once more, as
// the string constants `theDiagnosticIsNotCircular` searches `main.swift` for, which is the
// enforcement of the rule, not an exception to it.
//
// ── WHAT THE OBSERVABLE IS, EXACTLY ─────────────────────────────────────────────────────────
//
// `--soc-fabric` prints, per SoC component, whether the component's own live `SocBusInfo` has a
// `simulationManager`, the precise `weak` field whose nil-ness produces every wrong answer
// listed above, plus the slave count on each bus and the result of one real bus read.
//
// Measured on the four-part fixture below, same binary, one line of `main.swift` apart:
//
//   with the attach                                without it
//   ---------------------------------------------  ---------------------------------------
//   SocBus   … fabric=attached                     SocBus   … fabric=DETACHED
//   Socmem   … fabric=attached                     Socmem   … fabric=DETACHED
//   SocPio   … fabric=attached                     SocPio   … fabric=DETACHED
//   Rv32im   … fabric=attached                     Rv32im   … fabric=DETACHED
//   bus …: live=true slaves=3                      (no bus line, no manager to ask)
//   bus-read …: responder=mem                      (no read, nothing to read through)
//              error=transaction successful
//   exit 0                                         exit 5
//
// The read is reported by RESPONDER AND ERROR CODE, never by data: the CLI has no `CircuitState`,
// so `SocSimulationManager.data(for:)` is nil even with a live fabric and the memory's read still
// falls through to `Int32.random`. Whether a slave *answered* is deterministic; the word is not.
// Printing the word as if it were evidence is the failure this whole subcommand exists to expose.
//
// ── THE RED PROBES, RUN, AND WHAT EACH ONE PROVES THIS SUITE CANNOT DO ──────────────────────
//
// Four deliberate breakages of `main.swift`, each rebuilt and run, with the tests that went red:
//
//   A  delete the attach in `loadForSimulation`   the two fabric tests, and the `.attach` half of
//                                                 the call-site scan
//   B  make `--soc-fabric` build its own binder    `theDiagnosticIsNotCircular` ONLY, every
//                                                 dynamic test above stayed green, which is the
//                                                 whole reason that scan exists
//   C  restore `--tty`'s own `openLogisimFile`     `theGradedVerbsUseTheAttachingLoader` ONLY
//   D  drop `managers.keys.sorted()`               `theDiagnosticIsDeterministic` ONLY
//
// B and C are the honest limits. **No dynamic test here can tell that `--tty` bypassed the
// loader**, because a truth table over a SoC design is two bytes: no ported SoC factory drives an
// output pin without a program running, which is also why the one corpus file that places SoC
// components does not discriminate (measured: `--tty table` on it emits 2 bytes, identical across
// three runs). The source scan is the substitute, and it is named as one.
//
// This suite is also the lifetime check, without needing an assertion of its own: `SocBusInfo`
// holds its manager **weakly**, so if the CLI dropped the binder when the load function returned,
// every fabric would deallocate before the diagnostic could read it and these tests would report
// DETACHED against a `main.swift` that does call attach.

import Foundation
import Testing

@testable import LogisimSoc

// MARK: - Fixtures

/// One of each of the four SoC parts a real design is built from, all on one bus.
///
/// Same shape and the same bus id as `LogisimUITests/SocRegistrationTests.socFixture`, and for
/// the same reason: it is transcribed from `harvested/3.7.2__case-186.circ`, the only corpus
/// file that PLACES SoC components rather than merely declaring the
/// library. Held here as a literal rather than read from `$LOGISIM_CORPUS` so this gate runs on
/// a machine with no corpus; the corpus file itself is checked separately, when it is present.
///
/// The memory keeps its default `StartAddress` (0) and default size (1 KiB), which is what makes
/// the probe read at `0x00000000` land on it. The PIO is at `0x448`, outside that window, so
/// exactly one slave can answer and the read cannot be a `multipleSlaves` false positive.
private let socFixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Base" name="0"/>
  <lib desc="#Wiring" name="1"/>
  <lib desc="#Soc" name="11"/>
  <main name="main"/>
  <circuit name="main">
    <comp lib="11" loc="(300,100)" name="SocBus">
      <a name="SocBusIdentifier" val="0x000001900000000000000001"/>
      <a name="TraceVisible" val="false"/>
    </comp>
    <comp lib="11" loc="(500,100)" name="Socmem">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
      <a name="label" val="mem"/>
    </comp>
    <comp lib="11" loc="(500,400)" name="SocPio">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
      <a name="StartAddress" val="0x448"/>
      <a name="direction" val="outputonly"/>
      <a name="label" val="port_out"/>
    </comp>
    <comp lib="11" loc="(100,100)" name="Rv32im">
      <a name="SocBusSelection" val="0x000001900000000000000001"/>
    </comp>
  </circuit>
</project>
"""

/// The bus id the fixture names. Repeated as a constant because three assertions key on it and a
/// typo in one of them would look like a registration failure.
private let fixtureBusId = "0x000001900000000000000001"

/// The four `_ID`s the fixture places, taken from the factories rather than typed as literals.
///
/// This is what the `@testable import LogisimSoc` above is for, and it is not decoration: the
/// `_ID` strings are the `.circ` codec's keys, `"Socmem"` really is lower-case `m` with no
/// separator, and one wrong character makes exactly one `<comp>` silently unresolvable, which
/// would surface here as "the fabric is missing a slave" and send a reader hunting the binder.
/// Reading them off the source of truth makes a rename fail loudly at the rename.
private let socComponentIds = [SocBus.id, SocMemory.id, SocPio.id, Rv32imRiscV.id]

/// A PIO that names **no** bus at all; the case that separates "the binder ran" from "the bus id
/// happened to resolve".
private let unwiredPioFixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Base" name="0"/>
  <lib desc="#Wiring" name="1"/>
  <lib desc="#Soc" name="11"/>
  <main name="main"/>
  <circuit name="main">
    <comp lib="11" loc="(500,400)" name="SocPio">
      <a name="label" val="orphan"/>
    </comp>
  </circuit>
</project>
"""

/// Two busses, one memory each. Exists for the determinism check: with a single bus the
/// diagnostic's `managers.keys.sorted()` is unfalsifiable, because one key cannot be out of order.
///
/// Swift's `Dictionary` seeds its hashing per process, so an unsorted iteration genuinely differs
/// between runs of the same binary, which is what makes this a real probe rather than a
/// decorative one.
private let twoBusFixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Base" name="0"/>
  <lib desc="#Wiring" name="1"/>
  <lib desc="#Soc" name="11"/>
  <main name="main"/>
  <circuit name="main">
    <comp lib="11" loc="(300,100)" name="SocBus">
      <a name="SocBusIdentifier" val="0x00000000000000000000000a"/>
    </comp>
    <comp lib="11" loc="(300,600)" name="SocBus">
      <a name="SocBusIdentifier" val="0x00000000000000000000000b"/>
    </comp>
    <comp lib="11" loc="(500,100)" name="Socmem">
      <a name="SocBusSelection" val="0x00000000000000000000000a"/>
      <a name="label" val="mem_a"/>
    </comp>
    <comp lib="11" loc="(500,600)" name="Socmem">
      <a name="SocBusSelection" val="0x00000000000000000000000b"/>
      <a name="label" val="mem_b"/>
    </comp>
  </circuit>
</project>
"""

/// An ordinary circuit with nothing SoC in it: the negative control for the exit code.
private let plainFixture = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Base" name="0"/>
  <lib desc="#Wiring" name="1"/>
  <lib desc="#Gates" name="2"/>
  <main name="main"/>
  <circuit name="main">
    <comp lib="1" loc="(100,100)" name="Pin">
      <a name="label" val="a"/>
    </comp>
    <comp lib="1" loc="(200,100)" name="Pin">
      <a name="facing" val="west"/>
      <a name="output" val="true"/>
      <a name="label" val="y"/>
    </comp>
    <wire from="(100,100)" to="(200,100)"/>
  </circuit>
</project>
"""

// MARK: - Harness

@Suite("logisim-cli builds a SoC bus fabric at load", .serialized)
struct CliSocFabricInstallationTests {

  /// The package root (`swift/`), from this file's own path: same technique as
  /// `BuiltinHdlWiringInstallationTests`, which gates the sibling integrator call.
  private static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimSocTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
  }

  /// The `logisim-cli` built by this same `swift test` invocation, in this same configuration.
  ///
  /// A missing binary is reported as a FAILURE rather than skipped: "the runtime under test could
  /// not be found" must never read as "the runtime under test is fine".
  private static var cliURL: URL? {
    // An override names the BINARY, and is honoured exactly: the first version took its parent
    // directory and appended `logisim-cli`, so `LOGISIM_CLI=/usr/bin/false` silently fell through
    // to a real build and fourteen tests passed against a binary nobody had asked for. Returning
    // nil here surfaces as the missing-binary failure below, which is the intended loud outcome.
    if let override = ProcessInfo.processInfo.environment["LOGISIM_CLI"] {
      let exact = URL(fileURLWithPath: override)
      return FileManager.default.isExecutableFile(atPath: exact.path) ? exact : nil
    }
    var candidates: [URL] = []
    // The directory this test binary is running out of. This is the one that holds up under
    // `swift test --build-path`, where nothing is under `swift/.build` at all: an audit ran the
    // suite that way and 43 tests failed on "logisim-cli was not found", with the binary sitting
    // right beside the test bundle the whole time.
    if let executable = Bundle.main.executableURL {
      candidates.append(executable.deletingLastPathComponent())
    }
    if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
      candidates.append(bundle.bundleURL.deletingLastPathComponent())
    }
    for configuration in ["debug", "release"] {
      candidates.append(
        packageRoot.appendingPathComponent(".build").appendingPathComponent(configuration))
    }
    for directory in candidates {
      let candidate = directory.appendingPathComponent("logisim-cli")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private struct RunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    /// Every non-empty stdout line, trimmed; the form every assertion below reads.
    var lines: [String] {
      stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
  }

  private static func run(_ executable: URL, _ arguments: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Read before waiting: a pipe that fills would deadlock the child.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RunResult(
      status: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self))
  }

  /// Writes `text` to a uniquely named `.circ` under the temporary directory and runs
  /// `logisim-cli` on it. The file is removed afterwards whatever the outcome.
  private static func runOnFixture(_ text: String, _ arguments: [String]) throws -> RunResult {
    let cli = try #require(
      cliURL,
      "logisim-cli was not found in the build products directory; the runtime under test is missing, which is not the same as it being correct")
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("soc-fabric-\(UUID().uuidString).circ")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try run(cli, arguments + [url.path])
  }

  // MARK: - 1. The headline

  /// **The test that goes red when the attach in `loadForSimulation` is deleted.**
  ///
  /// Red probe, run rather than imagined: commenting out the single line
  /// `for circuit in file.circuits { binder.attach(to: circuit) }` and rebuilding turns all four
  /// `fabric=attached` into `fabric=DETACHED`, drops the bus and bus-read lines entirely (there
  /// is no manager left to ask), and moves the exit code from 0 to 5.
  @Test("the CLI's own load path gives a SoC design a live bus fabric")
  func cliLoadPathBuildsALiveSocBusFabric() throws {
    let result = try Self.runOnFixture(socFixture, ["--soc-fabric"])

    #expect(
      result.status == 0,
      "logisim-cli --soc-fabric exited \(result.status) (5 means at least one SoC component reached no SocSimulationManager — no SocCircuitBinder is attached in main.swift's load path): \(result.stderr)")

    // Every part the fixture places, by `_ID` read off the factory. Named individually rather
    // than counted so a fixture that silently lost a component cannot satisfy this.
    for id in socComponentIds {
      let line = result.lines.first { $0.hasPrefix("\(id) ") }
      let found = try #require(
        line, "no \(id) line in --soc-fabric output; the component did not resolve at all:\n\(result.stdout)")
      #expect(
        found.hasSuffix("fabric=attached"),
        Comment(rawValue: "\(id) carries no SocSimulationManager — its reads return Int32.random rather than failing: \(found)"))
      #expect(found.contains("bus=\(fixtureBusId)"))
    }

    // The bus really has the three slaves on it: the memory, the PIO, and the RV32IM's PLIC
    // (`Rv32imRiscV.slaveInterface` returns `RV32IM_PLIC_STATE`; the CPU is MASTER|SLAVE).
    let busLine = try #require(
      result.lines.first { $0.hasPrefix("bus \(fixtureBusId):") },
      "no bus line at all — nothing registered a SocBusFabric:\n\(result.stdout)")
    #expect(busLine.contains("live=true"), "the fabric has no bus component: \(busLine)")
    #expect(
      busLine.contains("slaves=3"),
      Comment(rawValue: "expected memory + PIO + the CPU's PLIC on the bus: \(busLine)"))

    // And the fabric answers. This is the end-to-end statement: a read issued at the memory's
    // window is routed to the memory and returns without error.
    let readLine = try #require(
      result.lines.first { $0.hasPrefix("bus-read \(fixtureBusId)") },
      "no bus read was attempted — there was no manager to issue it through:\n\(result.stdout)")
    #expect(
      readLine.contains("responder=mem"),
      Comment(rawValue: "the memory did not answer a read inside its own window: \(readLine)"))
    #expect(
      readLine.contains("error=transaction successful"),
      Comment(rawValue: "the bus read failed: \(readLine)"))
  }

  /// The fixtures are `.circ` text, so nothing in the compiler checks them. This does.
  ///
  /// Every `_ID` and every attribute name they use is compared against the constant the codec
  /// actually keys on, so a rename in `LogisimSoc` fails HERE, as "the fixture is stale", rather
  /// than three tests away as "the fabric lost a slave", which is the reading that would send
  /// someone back to the binder for a defect that is not there.
  @Test("the fixtures spell every _ID and attribute the way the codec keys them")
  func theFixturesMatchTheRealIdentifiers() {
    for id in socComponentIds {
      #expect(
        socFixture.contains("name=\"\(id)\""),
        Comment(rawValue: "the SoC fixture does not place a '\(id)'; the _ID was renamed and the fixture was not"))
    }
    let busSelect = SocSimulationManager.socBusSelect.name
    let busIdentifier = SocBusAttributes.socBusId.name
    #expect(socFixture.contains("name=\"\(busSelect)\""))
    #expect(socFixture.contains("name=\"\(busIdentifier)\""))
    #expect(twoBusFixture.contains("name=\"\(busSelect)\""))
    #expect(twoBusFixture.contains("name=\"\(busIdentifier)\""))
    // The orphan fixture's whole point is the ABSENCE of the bus attribute.
    #expect(
      !unwiredPioFixture.contains(busSelect),
      "the unwired-PIO fixture names a bus, which is the opposite of what it is for")
    #expect(unwiredPioFixture.contains("name=\"\(SocPio.id)\""))
  }

  // MARK: - 2. The attach is unconditional, which is what makes DETACHED unambiguous

  /// `SocSimulationManager.registerComponent` attaches the manager to any component carrying
  /// `SOC_BUS_SELECT`, **including one whose bus id is still empty**. So "has the attribute and no
  /// manager" means one thing only: the binder never ran.
  ///
  /// Without that, a reader could explain away a DETACHED line as "that peripheral just is not
  /// wired to anything", which is exactly the kind of plausible excuse that let seam #17 live.
  @Test("a peripheral naming no bus still reaches a manager, and is not an error")
  func aPeripheralWithNoBusIdStillReachesAManager() throws {
    let result = try Self.runOnFixture(unwiredPioFixture, ["--soc-fabric"])

    #expect(result.status == 0, "an unwired peripheral must not be reported as a failure: \(result.stderr)")
    let line = try #require(
      result.lines.first { $0.hasPrefix("SocPio ") }, Comment(rawValue: result.stdout))
    #expect(line.contains("bus= "), "the orphan PIO reports a bus id it does not have: \(line)")
    #expect(
      line.hasSuffix("fabric=attached"),
      Comment(rawValue: "registerComponent attaches regardless of bus id, so this must be attached: \(line)"))
  }

  /// The negative control. A file with no SoC content must exit 0 and claim nothing; a
  /// diagnostic that cries wolf on ordinary circuits gets ignored, and then it is not a gate.
  @Test("a circuit with no SoC components is reported as such, not as broken")
  func aFileWithNoSocComponentsIsNotReportedAsBroken() throws {
    let result = try Self.runOnFixture(plainFixture, ["--soc-fabric"])

    #expect(result.status == 0, Comment(rawValue: result.stderr))
    #expect(
      result.lines.contains("circuit main: soc-components=0"), Comment(rawValue: result.stdout))
    #expect(!result.stdout.contains("DETACHED"))
    #expect(!result.stdout.contains("bus-read"))
  }

  /// The output has to be byte-stable across runs, or it is not evidence.
  ///
  /// Two things in this path could have made it wander and neither is obvious: the memory's read
  /// really does return `Int32.random` (there is no `CircuitState` in the CLI), which is why the
  /// data word is deliberately not printed; and the bus lines are emitted from a `Dictionary`,
  /// which has no defined order; `managers.keys.sorted()` is what pins it, and a future edit
  /// that drops the `sorted()` would produce a diagnostic that disagrees with itself between
  /// runs. Three runs, compared byte for byte.
  @Test("the diagnostic's output is identical across runs")
  func theDiagnosticIsDeterministic() throws {
    let first = try Self.runOnFixture(twoBusFixture, ["--soc-fabric"])
    #expect(first.status == 0, Comment(rawValue: first.stderr))
    // Both busses are reported, so the ordering assertion below has something to order.
    #expect(first.lines.filter { $0.hasPrefix("bus ") }.count == 2, Comment(rawValue: first.stdout))
    for _ in 0..<5 {
      let again = try Self.runOnFixture(twoBusFixture, ["--soc-fabric"])
      #expect(
        again.stdout == first.stdout,
        Comment(rawValue: "--soc-fabric is not deterministic:\n\(first.stdout)\n vs \n\(again.stdout)"))
      #expect(again.status == first.status)
    }
  }

  // MARK: - 3. The grading path uses the same loader

  /// `--tty` is the graded verb, and it must go through the loader that attaches. This cannot be
  /// asserted from its OUTPUT, a truth table over the SoC fixture is two bytes, because no SoC
  /// factory drives an output pin without a program running (measured on the corpus file too),
  /// so what is asserted here is that the shared path still loads and runs. The structural half,
  /// that `--tty` really calls it, is the source scan below.
  @Test("--tty still loads a SoC file through the shared path")
  func ttyStillLoadsThroughTheSharedPath() throws {
    let result = try Self.runOnFixture(socFixture, ["--tty", "stats"])

    #expect(result.status == 0, Comment(rawValue: result.stderr))
    // `FileStatistics` prints DISPLAY names, not `_ID`s: checked by running it rather than
    // assumed, which is the same trap `SocRegistrationTests.socToolsReachTheExplorer` documents
    // hitting: `Rv32im` renders as "Risc V IM simulator", and matching on the `_ID` here would
    // have failed and read as a load failure.
    for displayName in [
      "Risc V IM simulator", "SoC bus simulator", "Memory simulator",
      "Parallel input/output expander",
    ] {
      #expect(
        result.stdout.contains(displayName),
        Comment(rawValue: "--tty stats lost '\(displayName)'; the shared loader broke the grading path:\n\(result.stdout)"))
    }
  }

  // MARK: - 4. Non-circularity, and the call sites

  /// The diagnostic must not build the fabric it reports on, or test 1 would be green with the
  /// startup attach deleted; it would be testing itself.
  ///
  /// Asserted against the source because the property is an ABSENCE, which no amount of running
  /// the passing case can demonstrate. Same construction as
  /// `BuiltinHdlWiringInstallationTests.theDiagnosticIsNotCircular`, including stripping string
  /// literals first: the branch's own failure message names `SocCircuitBinder` as the thing that
  /// did NOT run, and a naive substring scan would read that sentence as a call.
  @Test("the --soc-fabric diagnostic only reads the fabric, it does not build it")
  func theDiagnosticIsNotCircular() throws {
    let body = try Self.branchBody(named: "--soc-fabric")
    for forbidden in ["SocCircuitBinder", "attach(", "registerComponent"] {
      #expect(
        !body.contains(where: { $0.contains(forbidden) }),
        Comment(rawValue: "the --soc-fabric branch calls \(forbidden) itself, so it would report a live fabric with the startup attach deleted"))
    }
  }

  /// The two graded verbs must route through the one loader that attaches, and must not open a
  /// file behind its back.
  ///
  /// This is the check that would have caught the defect as written: `--tty` and `--test-vector`
  /// each had their own `openLogisimFile` call, identical line for line, and neither attached.
  /// Weaker than executing them, it would not catch the call sitting in an unreachable branch,
  /// but it catches the failure that actually happened, which is one of the two copies not being
  /// updated.
  @Test("--tty and --test-vector load through the function that attaches the fabric")
  func theGradedVerbsUseTheAttachingLoader() throws {
    for verb in ["--tty", "--test-vector"] {
      let body = try Self.branchBody(named: verb)
      #expect(
        body.contains(where: { $0.contains("loadForSimulation(") }),
        Comment(rawValue: "\(verb) does not use loadForSimulation, so its files get no SoC bus fabric"))
      #expect(
        !body.contains(where: { $0.contains("openLogisimFile(") }),
        Comment(rawValue: "\(verb) opens a file directly, bypassing the loader that attaches the SoC fabric"))
    }

    // And the loader it routes through is the one that does the work.
    let source = try String(contentsOf: Self.mainSwift, encoding: .utf8)
    let lines = Self.effectiveLines(of: source)
    let start = try #require(
      lines.firstIndex(where: { $0.contains("func loadForSimulation(") }),
      "loadForSimulation no longer exists; the CLI's simulation load seam has moved and this suite must follow it")
    let end = Self.endOfBlock(in: lines, from: start)
    let body = lines[start..<end].map(Self.strippingStringLiterals)
    #expect(
      body.contains(where: { $0.contains("SocCircuitBinder()") }),
      "loadForSimulation constructs no SocCircuitBinder; every SoC design it loads reads noise")
    #expect(
      body.contains(where: { $0.contains(".attach(to:") }),
      "loadForSimulation builds a binder and never attaches it to anything")
  }

  // MARK: - Source-scanning helpers

  private static var mainSwift: URL {
    packageRoot.appendingPathComponent("Sources/logisim-cli/main.swift")
  }

  /// The lines of `main.swift`'s `case "<name>":` branch, comments and string literals removed.
  private static func branchBody(named name: String) throws -> [String] {
    let source = try String(contentsOf: mainSwift, encoding: .utf8)
    let lines = effectiveLines(of: source)
    guard let caseIndex = lines.firstIndex(where: { $0.hasPrefix("case \"\(name)\"") }) else {
      Issue.record(Comment(rawValue: "logisim-cli has no \(name) subcommand any more; this suite cannot observe it"))
      return []
    }
    let next = lines[(caseIndex + 1)...].firstIndex(where: { $0.hasPrefix("case ") })
      ?? lines.endIndex
    return lines[(caseIndex + 1)..<next].map(strippingStringLiterals)
  }

  /// The index just past the brace-balanced block that opens on `start`.
  ///
  /// Brace depth, not "the first `}`": that shortcut broke
  /// `BuiltinHdlWiringInstallationTests.uiStartupInstallsTheGenerators` the moment the function it
  /// scanned grew a nested closure, and reported a present call as missing. A false alarm is worse
  /// than no check: it trains a reader to ignore the real one.
  private static func endOfBlock(in lines: [String], from start: Int) -> Int {
    var depth = 0
    for index in start..<lines.endIndex {
      depth += lines[index].filter { $0 == "{" }.count
      depth -= lines[index].filter { $0 == "}" }.count
      if index > start, depth <= 0 { return index }
    }
    return lines.endIndex
  }

  /// A line with the contents of every double-quoted literal removed, so prose inside a message
  /// string cannot be mistaken for code.
  private static func strippingStringLiterals(_ line: String) -> String {
    var result = ""
    var insideLiteral = false
    for character in line {
      if character == "\"" {
        insideLiteral.toggle()
        continue
      }
      if !insideLiteral { result.append(character) }
    }
    return result
  }

  private static func effectiveLines(of source: String) -> [String] {
    source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("//") }
  }
}
