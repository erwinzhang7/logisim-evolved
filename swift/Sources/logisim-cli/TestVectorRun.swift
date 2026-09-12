// TestVectorRun.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.data.TestVector,
// com.cburch.logisim.circuit.TestVectorEvaluator, com.cburch.logisim.gui.test.TestThread and
// com.cburch.logisim.proj.Project.doTestVector),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY THIS IS THE PIECE #1546 IS REALLY ABOUT ═════════════════════════════════════════════
//
// A truth table answers "what does this circuit compute". A TA needs "does this circuit compute
// the RIGHT thing", which is a vector file: and the CSC258 corpus ships real ones
// (`test.txt`, `op3_test.txt` … `op7_test.txt`, header `A[4] B[4] Cin S[4] Cout`). Upstream has
// the flag for it, `-w` / `--test-vector <circuit> <vectors.txt> <file.circ>`.
//
// **It does not work, in two independent ways, and both were measured.**
//
// 1. IT CANNOT RUN HEADLESSLY.
//
//        $ java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar \
//              --test-vector ripple_carry4 test.txt golden-08.circ
//        Exception in thread "main" java.awt.HeadlessException
//            ... at com.cburch.logisim.gui.generic.OptionPane.showMessageDialog(OptionPane.java:53)
//            at com.cburch.logisim.Main.main(Main.java:81)
//        EXIT=1        (nothing on stdout)
//
//    `Startup.parseArgs` sets `Main.headless = true` only for `-t`/`--tty` and `--test-fpga`
//    (Startup.java:357-360), so `--test-vector` takes the GUI branch of `Startup.run()`. When
//    that throws, `Main`'s `catch (Throwable)` calls `OptionPane.showMessageDialog(null, …)`
//    FIRST, which, with `Main.headless` still false, throws a SECOND HeadlessException out of
//    the catch block. `System.exit(100)` on the next line is never reached. The error reporter
//    destroys the error, and the JVM dies with the default 1.
//
// 2. EVEN WITH A DISPLAY, THE RESULT NEVER REACHES THE EXIT CODE.
//
//    `Startup.java:1029` is `proj.doTestVector(testVector, circuitToTest);`; **the return value
//    is discarded**, and `Project.doTestVector` returns the number of failing vectors. The run
//    then falls through to `if (exitAfterStartup) System.exit(0);` (Startup.java:1075-1077),
//    which is unconditional. So the process exits 0 whether every vector passed or every vector
//    failed. `handleArgTestVector`'s own comment says "It will return 0 or 1 depending on if the
//    tests pass or not." That comment describes an intent the code does not implement.
//
// Together: the one flag advertised for automated vector checking cannot be run from a script,
// and if it could, it would report success unconditionally. That is the substance of #1546 for
// anyone grading with it.
//
// ── So what does this port do, and how is it gated? ─────────────────────────────────────────
//
// The MACHINERY underneath is fine: `TestVectorEvaluator` never touches Swing. Setting
// `Main.headless = true` first (D17's switch, exactly as `tools/valuebridge/CircBridge.java`
// does it) makes the same Java code path run to completion, and
// `tools/difftest/ttybridge/TestVectorBridge.java` does that. So there IS a real oracle:
//
//     golden-08.circ  ripple_carry4  test.txt   ->  OK  pass 8  fail 0  rc 0
//     golden-08.circ  op3            op3_test.txt -> OK  pass 5  fail 0  rc 0
//     golden-08.circ  full_adder     test.txt   ->  OK  pass -1 fail -1 rc -1   (width mismatch)
//
// This file is diffed against that bridge by `tools/difftest/ttybridge/vectorgate.py`, on
// upstream's own stdout, byte for byte.
//
// **The exit code is the one deliberate divergence, and it is the entire point of porting
// this.** 0 when no vector failed, 1 when any did, 255 when the vector file or the pin binding
// could not be set up (`doTestVector`'s -1). Clamped to 0/1 rather than passing the failure
// COUNT through, because a process status is mod 256 and a file with exactly 256 failures would
// otherwise exit 0; the same silent-success shape this whole task exists to remove.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - The vector file

/// `com.cburch.logisim.data.TestVector`.
struct TestVectorFile {

  enum ParseError: Error, CustomStringConvertible {
    case empty
    case header(String)
    case data(String)
    case order(String)

    var description: String {
      switch self {
      case .empty: return "TestVector format error: empty file"
      case let .header(m): return "Test Vector header format error: \(m)"
      case let .data(m): return "Test Vector data format error: \(m)"
      case let .order(m): return m
      }
    }
  }

  var columnName: [String] = []
  var columnWidth: [BitWidth] = []
  var data: [[Value]] = []
  var setNumbers: [Int] = []
  var seqNumbers: [Int] = []
  private var dontCareFlags: [[Bool]] = []
  private var floatingFlags: [[Bool]] = []

  func isDontCare(_ row: Int, _ column: Int) -> Bool {
    guard row >= 0, row < dontCareFlags.count else { return false }
    let flags = dontCareFlags[row]
    guard column >= 0, column < flags.count else { return false }
    return flags[column]
  }

  func isFloating(_ row: Int, _ column: Int) -> Bool {
    guard row >= 0, row < floatingFlags.count else { return false }
    let flags = floatingFlags[row]
    guard column >= 0, column < flags.count else { return false }
    return flags[column]
  }

  /// `TestVector(File)` via `TestVectorReader.parse()`.
  init(contentsOf url: URL) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    // `BufferedReader.readLine()` splits on \n, \r or \r\n and drops the terminator.
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map(String.init)
    var cursor = 0

    /// `findNonemptyLine()`: strip from the first `#`, then tokenise on whitespace exactly as
    /// `new StringTokenizer(line)` does (the default delimiters are " \t\n\r\f", and it never
    /// produces an empty token). Returns nil at end of input.
    func findNonemptyLine() -> [String]? {
      while cursor < lines.count {
        var line = lines[cursor]
        cursor += 1
        if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{0C}" })
          .map(String.init)
        if !tokens.isEmpty { return tokens }
      }
      return nil
    }

    guard var current = findNonemptyLine() else { throw ParseError.empty }

    // ── parseHeader ─────────────────────────────────────────────────────────────────────────
    //
    // `<SET>` and `<SEQ>` are recognised by POSITION among the header tokens, and the data rows
    // are then matched against those token indices; not against the pin columns. So a `<SET>`
    // column shifts every later token's pin index by one, which is why `parseData` below tracks
    // `tokenIndex` and `pinIndex` separately.
    var setColumnIndex = -1
    var seqColumnIndex = -1
    for (i, token) in current.enumerated() {
      let upper = token.uppercased()
      if upper == "<SET>" {
        setColumnIndex = i
        continue
      }
      if upper == "<SEQ>" {
        seqColumnIndex = i
        continue
      }
      guard let open = token.firstIndex(of: "[") else {
        columnName.append(token)
        columnWidth.append(BitWidth.one)
        continue
      }
      guard let close = token.firstIndex(of: "]") else {
        throw ParseError.header("bad spec: \(token)")
      }
      let afterClose = token.index(after: close)
      if afterClose != token.endIndex || open == token.startIndex
        || close == token.index(after: open)
      {
        throw ParseError.header("bad spec: \(token)")
      }
      columnName.append(String(token[token.startIndex..<open]))
      // Java: `Integer.parseInt` in a try/catch that leaves `w = 0`, so a non-numeric width
      // falls into the range check below rather than throwing a parse error.
      let widthText = String(token[token.index(after: open)..<close])
      let w = Int(widthText) ?? 0
      guard w >= 1, w <= 64 else { throw ParseError.header("bad width: \(token)") }
      columnWidth.append(try BitWidth.create(w))
    }

    // ── parseData, row by row ───────────────────────────────────────────────────────────────
    current = findNonemptyLine() ?? []
    var haveLine = !current.isEmpty
    while haveLine {
      var values = [Value](repeating: .unknownValue, count: columnName.count)
      var dontCare = [Bool](repeating: false, count: columnName.count)
      var floating = [Bool](repeating: false, count: columnName.count)
      var setValue = 0
      var seqValue = 0
      var pinIndex = 0

      for (tokenIndex, token) in current.enumerated() {
        if setColumnIndex >= 0 && tokenIndex == setColumnIndex {
          guard let parsed = Int(token) else {
            throw ParseError.data("invalid set value: \(token)")
          }
          setValue = parsed
          continue
        }
        if seqColumnIndex >= 0 && tokenIndex == seqColumnIndex {
          guard let parsed = Int(token) else {
            throw ParseError.data("invalid seq value: \(token)")
          }
          seqValue = parsed
          continue
        }
        guard pinIndex < columnName.count else { throw ParseError.data("too many values") }

        let upper = token.uppercased()
        if upper == "<DC>" {
          dontCare[pinIndex] = true
          // Java stores `Value.UNKNOWN` (width 1) as a placeholder that is never compared.
          values[pinIndex] = .unknownValue
        } else if upper == "<FLOAT>" {
          floating[pinIndex] = true
          values[pinIndex] = Value.createUnknown(columnWidth[pinIndex])
        } else {
          do {
            values[pinIndex] = try Value.fromLogString(columnWidth[pinIndex], token)
          } catch {
            throw ParseError.data("\(error)")
          }
        }
        pinIndex += 1
      }
      guard pinIndex >= columnName.count else { throw ParseError.data("not enough values") }

      data.append(values)
      dontCareFlags.append(dontCare)
      floatingFlags.append(floating)
      setNumbers.append(setValue)
      seqNumbers.append(seqValue)

      if let next = findNonemptyLine() {
        current = next
      } else {
        haveLine = false
      }
    }

    // ── Verify set and sequence order ───────────────────────────────────────────────────────
    var lastSet = 0
    var lastSeq = 0
    for i in 0..<setNumbers.count {
      let thisSet = setNumbers[i]
      let thisSeq = seqNumbers[i]
      if thisSet < lastSet {
        throw ParseError.order("<Set> numbers out of order: \(lastSet) before \(thisSet)")
      }
      if thisSet == lastSet && thisSet > 0 && thisSeq <= lastSeq {
        throw ParseError.order(
          "<Seq> numbers out of order: \(lastSeq) before \(thisSeq) in set \(thisSet)")
      }
      if thisSet == 0 && thisSeq != 0 {
        throw ParseError.order("<Set> is 0 but <Seq> is \(thisSeq), not 0")
      }
      if thisSet != 0 && thisSeq == 0 {
        throw ParseError.order("<Set> is \(thisSet) which not 0 but <Seq> is 0")
      }
      lastSet = thisSet
      lastSeq = thisSeq
    }
  }
}

// MARK: - The evaluator

/// `com.cburch.logisim.circuit.TestVectorEvaluator` plus `TestThread.doTestVector`'s reporting.
enum TestVectorRun {

  enum Failure: Error, CustomStringConvertible {
    case noSuchCircuit(String)
    case setup(String)

    var description: String {
      switch self {
      case let .noSuchCircuit(name): return "Circuit '\(name)' not found."
      case let .setup(m): return m
      }
    }
  }

  /// `TestVectorEvaluator.LineReport`.
  struct LineReport {
    let columnName: String
    let expected: Value
    let computed: Value
    let oscillating: Bool

    /// `LineReport.toString()`: `"%s = %s (%s %s)%s"` with `tveExpected` / `tveOscillating`
    /// from `gui.properties`. `toDisplayString(2)` on both sides.
    var text: String {
      let suffix = oscillating ? " \(TtyStrings.tveOscillating)" : ""
      return "\(columnName) = \(computed.toDisplayString(radix: 2)) "
        + "(\(TtyStrings.tveExpected) \(expected.toDisplayString(radix: 2)))\(suffix)"
    }
  }

  struct Outcome {
    let passed: Int
    let failed: Int
    /// Everything upstream writes to stdout, in order, so it can be diffed byte for byte
    /// against `TestVectorBridge`'s capture of the real thing.
    let stdout: String
  }

  /// The whole of `Project.doTestVector(vectorname, name)` → `TestThread.doTestVector`.
  /// `vectorPath` is echoed VERBATIM in the first line of output. Upstream passes the raw
  /// command-line string to `S.get("testLoadingVector", vectorname)`, so absolutising it here,
  /// which the first version of this did; makes every byte comparison against the oracle fail
  /// on line 1 for a reason that has nothing to do with the vectors.
  static func run(
    file: LogisimFile, circuitName: String?, vectorPath: String
  ) throws -> Outcome {
    let vectorURL = URL(fileURLWithPath: vectorPath)
    let circuit: Circuit?
    if let circuitName, !circuitName.isEmpty {
      circuit = file.circuit(named: circuitName)
    } else {
      circuit = file.mainCircuit
    }
    // `Project.doTestVector:264-267` prints to STDERR and returns -1 rather than NPEing, which
    // is the one place in this family upstream already handles a missing circuit.
    guard let circuit else { throw Failure.noSuchCircuit(circuitName ?? "<main>") }

    var out = ""
    out += TtyStrings.testLoadingVector(vectorPath) + "\n"

    let vector: TestVectorFile
    do {
      vector = try TestVectorFile(contentsOf: vectorURL)
    } catch {
      // `TestThread.doTestVector:60-63` prints `testLoadingFailed` to STDERR and returns -1.
      throw Failure.setup(TtyStrings.testLoadingFailed("\(error)"))
    }

    let session = SimulationSession(file: file, thread: nil)
    let state = session.createRootState(for: circuit)
    let pins = try bindPins(vector: vector, circuit: circuit)

    out += TtyStrings.testRunning(vector.data.count) + "\n"

    let propagator = state.propagator
    var passed = 0
    var failed = 0
    var currentSet = -1
    var currentSeq = 0

    for row in 0..<vector.data.count {
      let testSet = vector.setNumbers[row]
      let testSeq = vector.seqNumbers[row]
      // "Reset if: starting a new set or test is combinational (seq == 0)"
      let shouldReset = (testSeq == 0 || currentSeq == 0 || testSet != currentSet)
      currentSet = testSet
      currentSeq = testSeq

      if shouldReset {
        try propagator.reset()
        _ = try propagator.propagate()
      }

      if !shouldReset && !propagator.isOscillating {
        _ = try propagator.toggleClocks()
        // "make sure clock signal reaches wires before setting pins"
        _ = try propagator.step(nil)
      }

      if !propagator.isOscillating {
        for (j, pin) in pins.enumerated() {
          guard pin.isInputPin else { continue }
          guard
            let simComponent = pin.component as? any SimComponent,
            let pinState = state.unvalidatedReusableInstanceState(for: simComponent)
              as? InstanceStateImpl
          else { continue }
          let oldValue = Pin.getValue(pinState)
          let driveValue = vector.data[row][j]
          if driveValue != oldValue {
            Pin.driveInputPin(pinState, driveValue)
            // "Mark the pin component as dirty so it gets processed during propagation"
            state.markComponentAsDirty(simComponent)
          }
        }
        // Java skips the final propagate only when `propagateOnLast` is false; the command-line
        // path leaves it true, so every row propagates.
        _ = try propagator.propagate()
      }

      // ── Compare ───────────────────────────────────────────────────────────────────────────
      var report: [LineReport] = []
      let expectedRow = vector.data[row]
      for (i, pin) in pins.enumerated() {
        // Clocks ARE compared (they are outputs of the circuit's own clocking), and so is
        // anything that is not an input pin. An input pin is driven, not checked.
        guard pin.isClock || !pin.isInputPin else { continue }
        guard vector.isDontCare(row, i) == false else { continue }

        if propagator.isOscillating {
          // "Report oscillating circuit outputs as ERROR."
          report.append(
            LineReport(
              columnName: vector.columnName[i], expected: expectedRow[i],
              computed: .errorValue, oscillating: true))
          continue
        }
        guard
          let simComponent = pin.component as? any SimComponent,
          let pinState = state.unvalidatedReusableInstanceState(for: simComponent)
            as? InstanceStateImpl
        else { continue }
        let computed = pin.isClock
          ? try Clock.factory.getValue(pinState) : Pin.getValue(pinState)

        if vector.isFloating(row, i) {
          if !computed.isUnknown() {
            report.append(
              LineReport(
                columnName: vector.columnName[i], expected: expectedRow[i],
                computed: computed, oscillating: false))
          }
        } else if !expectedRow[i].compatible(computed) {
          report.append(
            LineReport(
              columnName: vector.columnName[i], expected: expectedRow[i],
              computed: computed, oscillating: false))
        }
      }

      // `TestThread.doTestVector()`'s per-row callback, reproduced including the `\r` progress
      // counter; a byte-exact diff against upstream's stdout is the gate, so the carriage
      // returns are part of the output, not decoration.
      out += "\(row + 1) \r"
      if !report.isEmpty {
        out += "\n"
        for entry in report { out += "  " + entry.text + "\n" }
      }

      if report.isEmpty {
        passed += 1
      } else {
        failed += 1
      }
    }

    out += "\n"
    out += TtyStrings.testResults(passed, failed) + "\n"
    return Outcome(passed: passed, failed: failed, stdout: out)
  }

  private struct BoundPin {
    let component: any Component
    let isClock: Bool
    let isInputPin: Bool
  }

  /// `TestVectorEvaluator.getPinsForVector`. Throws `TestException` upstream, which
  /// `TestThread.doTestVector` turns into `testSetupFailed` and a -1 return.
  private static func bindPins(vector: TestVectorFile, circuit: Circuit) throws -> [BoundPin] {
    var pins: [BoundPin] = []
    for (i, columnName) in vector.columnName.enumerated() {
      var found: BoundPin?
      for component in circuit.nonWires {
        let factory = component.factory
        let isClock = factory is Clock
        let isPin = factory is Pin
        guard isClock || isPin else { continue }
        let label = component.attributeSet[StdAttr.label]
        if isClock {
          // An unlabelled Clock matches the literal column name `<clk>`, case-insensitively.
          let matches = columnName == label
            || ((label == nil || label!.isEmpty) && columnName.lowercased() == "<clk>")
          guard matches else { continue }
          guard vector.columnWidth[i].width == 1 else {
            throw Failure.setup(
              TtyStrings.tveClockWidthMismatch(columnName, vector.columnWidth[i].width))
          }
          found = BoundPin(component: component, isClock: true, isInputPin: false)
          break
        }
        guard columnName == label else { continue }
        let pinWidth = Pin.getWidth(component.attributeSet).width
        guard pinWidth == vector.columnWidth[i].width else {
          throw Failure.setup(
            TtyStrings.tveWidthMismatch(columnName, vector.columnWidth[i].width, pinWidth))
        }
        found = BoundPin(
          component: component, isClock: false,
          isInputPin: Pin.isInputPin(component.attributeSet))
        break
      }
      guard let found else {
        throw Failure.setup(TtyStrings.tveColumnNoPin(columnName))
      }
      pins.append(found)
    }
    return pins
  }
}

// MARK: - Strings

/// The `gui.properties` entries this path prints, from the resource the oracle runs with (no
/// `-o`/`--locale`, so the default English bundle is what produced every captured byte).
///
/// The typographic quotes in `testLoadingVector` are U+201C / U+201D, not ASCII `"`.
extension TtyStrings {
  /// `testLoadingVector = Loading test vector “%s”…`: note the trailing U+2026 ELLIPSIS.
  static func testLoadingVector(_ name: String) -> String {
    "Loading test vector \u{201C}\(name)\u{201D}\u{2026}"
  }
  /// `testRunning = Running %s vectors…`
  static func testRunning(_ count: Int) -> String { "Running \(count) vectors\u{2026}" }
  /// `testResults = Passed: %s, Failed: %s`
  static func testResults(_ passed: Int, _ failed: Int) -> String {
    "Passed: \(passed), Failed: \(failed)"
  }
  /// `testLoadingFailed = Error loading test vector: %s`
  static func testLoadingFailed(_ message: String) -> String {
    "Error loading test vector: \(message)"
  }
  /// `testSetupFailed = Error preparing test vector: %s`
  static func testSetupFailed(_ message: String) -> String {
    "Error preparing test vector: \(message)"
  }
  /// `testFailed = Error on test vector %s:`
  static func testFailed(_ row: Int) -> String { "Error on test vector \(row):" }

  static let tveExpected = "expected"
  static let tveOscillating = "(oscillating)"
  static func tveColumnNoPin(_ name: String) -> String {
    "Column \(name) does not correspond to any pin or clock in the circuit."
  }
  static func tveWidthMismatch(_ name: String, _ want: Int, _ got: Int) -> String {
    "Test vector column \(name) has width \(want), but the pin has width \(got)."
  }
  static func tveClockWidthMismatch(_ name: String, _ want: Int) -> String {
    "Test vector clock column \(name) has width \(want), but a clock is 1 bit."
  }
}
