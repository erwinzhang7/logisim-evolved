// BuiltinHdlWiringInstallationTests: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS SUITE PROVES THAT `HdlGeneratorRegistryTests` DOES NOT ═════════════════════════
//
// `HdlGeneratorRegistryTests` proves the registration LIST is complete, correctly keyed, and that
// `registerAllBuiltins` populates a lookup that answered nothing before. All of that stayed true
// for the entire period during which **nothing at runtime ever called it**: no shipping target
// linked `LogisimHdl`, so the only place in the package that could see both modules was a test
// target, and a test target is not a runtime.
//
// So a test that calls `installBuiltins` itself and checks the return value would have been green
// throughout the defect. This suite therefore never calls it. It asserts, from OUTSIDE the
// process, that a runtime which was merely *started* has a populated registry:
//
//     .build/<config>/logisim-cli --hdl-generators
//
// which prints `HdlGeneratorLookup.shared.registeredFactoryNames` and installs nothing of its
// own. Delete `BuiltinHdlWiring.installBuiltins()` from `logisim-cli/main.swift` and the
// subcommand exits 3 with an empty list, turning `cliStartupInstallsTheGenerators` red.
//
// ── Why the second test is a source scan ────────────────────────────────────────────────────
//
// The same proof cannot be run against `LogisimUI`: this target does not link it (and could not
// without `Package.swift`, which is owned elsewhere), and its registration runs behind a
// `@MainActor` factory rather than a process entry point. The honest substitute is to assert the
// call is present on a non-comment line of the file that owns the UI's startup registration.
// That is weaker than executing it, it would not catch the call being made in an unreachable
// branch, but it does catch the failure that actually happened eleven times: the line being
// absent, or being deleted by one of the merges that reverted `Package.swift` three times.
//
// The stronger version is one line in `LogisimUITests`, which does link `LogisimUI`; it is quoted
// in this task's report rather than written here because that suite is not this task's to edit.

import Foundation
import Testing

@testable import LogisimHdl

@Suite("BuiltinHdlWiring — the call is actually reached at startup", .serialized)
struct BuiltinHdlWiringInstallationTests {

  // MARK: - Locating the things under test

  /// The package root (`swift/`), from this file's own path.
  ///
  /// Same technique as `LogisimStdTests/PlatformFreedomTests`.
  private static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimHdlTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
  }

  /// The build products directory; the one this test bundle was itself built into, so the
  /// binary examined is the binary from this build, in this configuration.
  ///
  /// `swift test` builds every product in the package, `logisim-cli` included (verified: deleting
  /// `.build/debug/logisim-cli` and running a single filtered test restores it), so the executable
  /// is present whenever this suite runs. If it is ever missing, that is reported as a failure
  /// rather than skipped: "the runtime could not be found" must not read as "the runtime is fine".
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

  // MARK: - 1. The CLI: a runtime that was merely started has a populated registry

  /// **This is the test that goes red when the startup call is deleted.**
  ///
  /// It runs the real executable and inspects the registry the executable's own startup left
  /// behind. Nothing in this file installs anything.
  @Test("logisim-cli's startup installs the builtin HDL generators")
  func cliStartupInstallsTheGenerators() throws {
    let cli = try #require(
      Self.cliURL,
      "logisim-cli was not found in the build products directory; the runtime under test is missing, which is not the same as it being correct")

    let result = try Self.run(cli, ["--hdl-generators"])

    #expect(
      result.status == 0,
      "logisim-cli --hdl-generators exited \(result.status) (exit 3 means the registry was EMPTY at startup — BuiltinHdlWiring.installBuiltins() is not being called from main.swift): \(result.stderr)")

    let names = result.stdout.split(separator: "\n").map(String.init)
    #expect(
      !names.isEmpty,
      "the CLI started with an empty HdlGeneratorLookup; every component would be treated as non-synthesizable")

    // The list must be the whole join, not one family that happened to register. The four ported
    // families contribute 40 registrations between them; the count is asserted as a floor so a
    // family being added does not fail this, but a family being dropped does.
    #expect(
      names.count >= 40,
      "only \(names.count) generators installed at startup — a family's list is missing: \(names)")
  }

  /// One name from each of the four families must survive the trip through the real startup path,
  /// so this cannot pass on a registry that happens to be non-empty for some other reason.
  ///
  /// The names are read off the registration lists rather than typed as literals here, so a
  /// renamed key fails at the source of truth instead of drifting against a copy.
  @Test("all four families are present in the started process's registry")
  func startupRegistryCoversEveryFamily() throws {
    let cli = try #require(Self.cliURL, "logisim-cli was not found in the build products directory")
    let installed = Set(
      try Self.run(cli, ["--hdl-generators"]).stdout.split(separator: "\n").map(String.init))

    let expected: [(family: String, name: String)] = [
      ("gates", GatesHdlRegistrations.FactoryName.andGate),
      ("arith", ArithHdlRegistrations.adderName),
      ("memory", MemoryHdlGenerators.FactoryName.register),
      ("io", IoHdlRegistrations.FactoryName.led),
    ]
    for (family, name) in expected {
      #expect(
        installed.contains(name),
        "\(family): '\(name)' is not registered in the started process — that family's list is not reaching the runtime")
    }
  }

  /// The CLI's diagnostic must not install anything itself, or the test above would be circular:
  /// it would report a populated registry even with the startup call deleted.
  ///
  /// Asserted against the source, because the property is "this code path contains no
  /// installation": an absence, which no amount of running the passing case can demonstrate.
  @Test("the --hdl-generators diagnostic only reads the registry, it does not populate it")
  func theDiagnosticIsNotCircular() throws {
    let main = Self.packageRoot.appendingPathComponent("Sources/logisim-cli/main.swift")
    let source = try String(contentsOf: main, encoding: .utf8)
    let lines = Self.effectiveLines(of: source)

    guard let caseIndex = lines.firstIndex(where: { $0.contains("case \"--hdl-generators\":") })
    else {
      Issue.record("logisim-cli has no --hdl-generators subcommand; this suite cannot observe the startup registry")
      return
    }
    let nextCase = lines[(caseIndex + 1)...].firstIndex(where: { $0.hasPrefix("case ") })
      ?? lines.endIndex
    // String literals are stripped first: the branch's own error message names
    // `installBuiltins()` as the thing that did NOT run, and a naive substring scan would read
    // that diagnostic text as a call.
    let body = lines[(caseIndex + 1)..<nextCase].map(Self.strippingStringLiterals)
    #expect(
      !body.contains(where: { $0.contains("installBuiltins") || $0.contains("registerAllBuiltins") }),
      "the --hdl-generators branch installs generators itself, so it would report success with the startup call deleted")
  }

  // MARK: - 2. The UI call site

  /// `LogisimUI`'s launch path must make the same call.
  ///
  /// A registration living in one executable's startup is a registration the other executable
  /// silently lacks; `main.swift` says exactly this about `#Soc`, and the app is the runtime
  /// where an unpopulated registry would be least visible, because nothing in the UI reports
  /// "this component has no generator" until an export is attempted.
  @Test("LogisimUI's startup registration calls installBuiltins too")
  func uiStartupInstallsTheGenerators() throws {
    let host = Self.packageRoot.appendingPathComponent(
      "Sources/LogisimUI/Project/LogisimFileProjectHost.swift")
    let source = try String(contentsOf: host, encoding: .utf8)
    let lines = Self.effectiveLines(of: source)

    guard
      let start = lines.firstIndex(where: {
        $0.contains("func registerBuiltinLibrariesIfNeeded()")
      })
    else {
      Issue.record("registerBuiltinLibrariesIfNeeded no longer exists; the UI's registration seam has moved and this test must follow it")
      return
    }
    // ── MATCHED BY BRACE DEPTH, NOT BY THE FIRST `}` ────────────────────────────────────────
    //
    // This was `firstIndex(where: { $0 == "}" })`, and it broke the moment the function grew a
    // nested closure: installing `CircuitTransaction.wireRepair` put a closure's closing brace
    // ahead of the function's, so the scan stopped early and reported that
    // `BuiltinHdlWiring.installBuiltins()` was missing when it was three lines below the window.
    //
    // A false "the app would run with an empty HdlGeneratorLookup" is worse than no check: it is
    // exactly the alarm this file exists to raise, so crying it wrongly trains a reader to ignore
    // the real one. Same defect class as `graphcheck.py`'s fixed-width target window, which
    // reported three present edges as MISSING for the same reason.
    var depth = 0
    var end = lines.endIndex
    for index in start..<lines.endIndex {
      depth += lines[index].filter { $0 == "{" }.count
      depth -= lines[index].filter { $0 == "}" }.count
      if index > start, depth <= 0 {
        end = index
        break
      }
    }
    // Same literal-stripping as above, so a call named only inside a message string cannot
    // satisfy this.
    let body = lines[start..<end].map(Self.strippingStringLiterals)

    #expect(
      body.contains(where: { $0.contains("StdLibraries.registerAll()") }),
      "the function scanned is not the builtin-registration seam any more")
    #expect(
      body.contains(where: { $0.contains("BuiltinHdlWiring.installBuiltins()") }),
      "LogisimUI's startup does not install the HDL generators; the app would run with an empty HdlGeneratorLookup while the CLI's is full")
  }

  /// Source lines with `//` comment lines and blank lines removed, so a call that appears only
  /// inside a doc comment cannot satisfy any assertion above.
  /// A line with the contents of every double-quoted literal removed, so prose inside a message
  /// string cannot be mistaken for code. Crude, it does not understand escapes or interpolation
  /// , but it only has to distinguish "a call" from "a sentence about a call".
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
