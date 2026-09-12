// CliTtyHarness: part of logisim-evolved.
//
// Derived from logisim-evolved, GPL-3.0-only. See LICENSE.md.
//
// Shared plumbing for `CliExitCodeTests` and `CliStatsTests`: locate the built `logisim-cli`,
// locate the 4.1.0 oracle jar, run either as a subprocess, and write self-contained `.circ`
// fixtures to a scratch directory.
//
// ── Why the fixtures are inline and not corpus files ────────────────────────────────────────
//
// The corpus is private coursework and lives outside this repo (docs/objectives.md), so any test
// keyed to it is skipped on a machine that lacks it. The exit-code contract must not be
// skippable; it is the interface a grading script branches on. So the fixtures here are
// hand-written, minimal, and byte-verified against the jar before being committed:
//
//     $ logisim-cli --tty stats,table fixture.circ     $ java -jar J -tty stats,table fixture.circ
//     3 3 Pin        Wiring                            3 3 Pin        Wiring
//     1 1 AND Gate   Gates                             1 1 AND Gate   Gates
//     4 4 TOTAL (without project’s sub circuits)       (identical)
//     ...
//
// `hierarchical` is the discriminating one. In `combinational` every column is equal, so it
// would pass against an implementation that printed `simpleCount` three times; in `hierarchical`
// Pin is 6 unique / 9 recursive and the two totals are 8/12 and 10/14, so the recursion, the
// unique sum over all circuits, and the subcircuit exclusion are each observable.

import Foundation
import Testing

enum CliTtyHarness {

  // MARK: - Locating the binaries

  /// The package root (`swift/`), from this file's own path.
  static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimFileTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
  }

  /// The built CLI; preferring the build products directory this test bundle came from, so the
  /// binary examined is this build in this configuration.
  static var cliURL: URL? {
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

  /// The Homebrew JDK and the shipped 4.1.0 fat jar: the oracle, per docs/decisions.md.
  /// The app bundle's own runtime has no `bin/java` (jpackage strips it).
  static var javaURL: URL? {
    let path = ProcessInfo.processInfo.environment["LOGISIM_JAVA"]
      ?? "/opt/homebrew/opt/openjdk@21/bin/java"
    let url = URL(fileURLWithPath: path)
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  static var jarURL: URL? {
    let path = ProcessInfo.processInfo.environment["LOGISIM_JAR"]
      ?? "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar"
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  // MARK: - Running

  struct RunResult {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  static func run(
    _ executable: URL, _ arguments: [String], cwd: URL? = nil
  ) throws -> RunResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
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

  /// The oracle, invoked exactly as `rig.py` and `statsgate.py` invoke it.
  ///
  /// `-tty` makes `Startup.parseArgs` set `Main.headless = true`, so no bridge is needed and no
  /// dialog can block (D17).
  static func runJar(_ arguments: [String], cwd: URL) throws -> RunResult? {
    guard let java = javaURL, let jar = jarURL else { return nil }
    return try run(
      java, ["-Djava.awt.headless=true", "-jar", jar.path] + arguments, cwd: cwd)
  }

  // MARK: - Fixtures

  /// A scratch directory, unique per call, deleted by the caller.
  static func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("logisim-cli-tty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func write(_ contents: String, named name: String, into directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  // MARK: - The fixture files

  /// Two input pins, one output pin, one AND gate. Every stats column is equal here, which is
  /// exactly why `hierarchical` exists as well.
  static let combinational = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Gates" name="1"/>
      <main name="main"/>
      <options/>
      <mappings/>
      <toolbar/>
      <circuit name="main">
        <a name="circuit" val="main"/>
        <comp lib="0" loc="(100,110)" name="Pin">
          <a name="label" val="a"/>
        </comp>
        <comp lib="0" loc="(100,130)" name="Pin">
          <a name="label" val="b"/>
        </comp>
        <comp lib="0" loc="(260,120)" name="Pin">
          <a name="label" val="q"/>
          <a name="type" val="output"/>
        </comp>
        <comp lib="1" loc="(220,120)" name="AND Gate">
          <a name="size" val="30"/>
        </comp>
        <wire from="(100,110)" to="(190,110)"/>
        <wire from="(100,130)" to="(190,130)"/>
        <wire from="(220,120)" to="(260,120)"/>
      </circuit>
    </project>

    """

  /// `top` instantiates `leaf` twice, so the unique / recursive / with- / without-subcircuit
  /// columns all take different values and each is independently observable.
  static let hierarchical = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Gates" name="1"/>
      <main name="top"/>
      <options/>
      <mappings/>
      <toolbar/>
      <circuit name="leaf">
        <a name="circuit" val="leaf"/>
        <comp lib="0" loc="(100,110)" name="Pin">
          <a name="label" val="a"/>
        </comp>
        <comp lib="0" loc="(100,130)" name="Pin">
          <a name="label" val="b"/>
        </comp>
        <comp lib="0" loc="(260,120)" name="Pin">
          <a name="label" val="q"/>
          <a name="type" val="output"/>
        </comp>
        <comp lib="1" loc="(220,120)" name="AND Gate">
          <a name="size" val="30"/>
        </comp>
        <wire from="(100,110)" to="(190,110)"/>
        <wire from="(100,130)" to="(190,130)"/>
        <wire from="(220,120)" to="(260,120)"/>
      </circuit>
      <circuit name="top">
        <a name="circuit" val="top"/>
        <comp lib="0" loc="(100,110)" name="Pin">
          <a name="label" val="x"/>
        </comp>
        <comp lib="0" loc="(100,130)" name="Pin">
          <a name="label" val="y"/>
        </comp>
        <comp lib="0" loc="(400,120)" name="Pin">
          <a name="label" val="z"/>
          <a name="type" val="output"/>
        </comp>
        <comp loc="(200,120)" name="leaf"/>
        <comp loc="(320,120)" name="leaf"/>
        <comp lib="1" loc="(380,120)" name="OR Gate">
          <a name="size" val="30"/>
        </comp>
      </circuit>
    </project>

    """

  /// Not XML at all. The jar answers this with a SAXParseException and `System.exit(-1)`.
  static let unparseable = "this is not a circuit file\n"

  // MARK: - Table-format fixtures

  /// **The discriminating fixture for `-tty table`'s four modifiers.** `combinational` cannot be
  /// one: every column there is one bit wide, and at width 1 all three value styles render the
  /// same single character, so `table`, `table,binary` and `table,hex` produce byte-identical
  /// output and a test over it would pass against an implementation that ignored the modifier
  /// entirely. (Verified against the jar: all five formats agree on `combinational`.)
  ///
  /// Two **7-bit** columns is the smallest shape that separates all four:
  ///
  ///     -tty table          a    c q    w   |  0 0x00 0 0x00   width > 6, so hex WITH `0x`
  ///     -tty table,hex      a  c q  w       |  0 00 0 00       hex, no prefix
  ///     -tty table,binary   a        c q…   |  0 000 0000 0 …  Value.toString(): a space per
  ///                                         |                  nibble, NOT toBinaryString()
  ///     -tty table,csv      a,c,q,w         |  0,0x00,0,0x00   comma, and NO padding
  ///
  /// 7 rather than 8 bits keeps it to 256 rows while still crossing the `width <= 6` boundary and
  /// producing a ragged nibble (7 = 4 + 3), which is where a hand-rolled hex or nibble-spacing
  /// implementation goes wrong. `a`/`q` stay 1 bit so a mixed-width row is exercised too; the
  /// pretty path pads each column independently and a shared width would pass on uniform columns.
  static let wide = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Gates" name="1"/>
      <main name="main"/>
      <options/>
      <mappings/>
      <toolbar/>
      <circuit name="main">
        <a name="circuit" val="main"/>
        <comp lib="0" loc="(100,110)" name="Pin">
          <a name="label" val="a"/>
        </comp>
        <comp lib="0" loc="(300,110)" name="Pin">
          <a name="label" val="q"/>
          <a name="type" val="output"/>
        </comp>
        <comp lib="0" loc="(100,150)" name="Pin">
          <a name="label" val="c"/>
          <a name="width" val="7"/>
        </comp>
        <comp lib="0" loc="(300,150)" name="Pin">
          <a name="label" val="w"/>
          <a name="type" val="output"/>
          <a name="width" val="7"/>
        </comp>
        <wire from="(100,110)" to="(300,110)"/>
        <wire from="(100,150)" to="(300,150)"/>
      </circuit>
    </project>

    """

  // MARK: - Loader-diagnostic fixtures

  /// `combinational` plus `<lib desc="#Risc-V" name="99"/>`. 4.1.0's `Builtin` list has fourteen
  /// libraries and `#Risc-V` is not among them, so `LibraryManager.loadLibrary`'s `case ""` arm
  /// calls `showError(fileBuiltinMissingError)`.
  ///
  /// **The jar prints nothing for this**, and that is the whole point of the fixture. The message
  /// is `The built-in library “Risc-V” is not available in this version.`, 63 characters, and
  /// `Loader.showError` sends anything over 60 through a `JScrollPane`, which `OptionPane`'s
  /// headless arm silently discards because it is not a `String`. Measured, exit 0, empty stderr.
  static let unresolvableLibrary = combinational.replacingOccurrences(
    of: "  <lib desc=\"#Gates\" name=\"1\"/>",
    with: "  <lib desc=\"#Gates\" name=\"1\"/>\n  <lib desc=\"#Risc-V\" name=\"99\"/>")

  /// The other half of the same measurement: a descriptor with no `#` at all, so
  /// `loadLibrary`'s `sep < 0` arm reports `Unrecognized library descriptor bogus`: 35
  /// characters, which fits under the 60-char threshold and therefore **is** logged by the jar:
  ///
  ///     [main] ERROR …OptionPane - File Error:baddesc: Unrecognized library descriptor bogus
  ///
  /// Having both fixtures is what makes the length-dependence a measurement rather than a story.
  static let badDescriptor = combinational.replacingOccurrences(
    of: "  <lib desc=\"#Gates\" name=\"1\"/>",
    with: "  <lib desc=\"#Gates\" name=\"1\"/>\n  <lib desc=\"bogus\" name=\"98\"/>")

  /// `source="2.7.1"`, which trips `XmlReader`'s pre-2.7.2 compatibility warning. That one goes
  /// through `OptionPane.showMessageDialog(parent, String, title, WARNING_MESSAGE)` with a plain
  /// String, so the jar DOES log it despite being three lines long: the third measured point,
  /// and the one that shows the suppression is about the argument's TYPE and not about length as
  /// such.
  static let oldFormat = combinational.replacingOccurrences(
    of: "source=\"4.1.0\"", with: "source=\"2.7.1\"")

  // MARK: - Test-vector fixtures

  /// The truth table of `combinational`'s AND gate, written as a vector file. Column names must
  /// match the pin labels exactly; widths default to 1 with no `[n]` suffix.
  static let passingVectors = """
    # every row is correct for an AND gate
    a b q
    0 0 0
    0 1 0
    1 0 0
    1 1 1

    """

  /// The same file with the last two expected outputs wrong, so exactly two vectors fail.
  /// Two rather than one, so an off-by-one in the tally is visible.
  static let failingVectors = """
    a b q
    0 0 0
    0 1 0
    1 0 1
    1 1 0

    """

  /// `q` declared 4 bits wide against a 1-bit pin: `getPinsForVector` throws `TestException`,
  /// which upstream turns into `testSetupFailed` and a -1 return.
  static let wrongWidthVectors = """
    a b q[4]
    0 0 0000
    1 1 0001

    """
}
