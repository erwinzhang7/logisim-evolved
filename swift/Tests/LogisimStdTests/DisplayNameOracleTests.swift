// DisplayNameOracleTests.swift; part of logisim-evolved.
//
// Every display name in the builtin set, against the 4.1.0 jar's own answer.
//
// ── What went wrong, and why a corpus gate was not enough to find all of it ──────────────────
//
// `ComponentFactory.getDisplayName()` fell through to `getName()`, the `.circ` `_ID`, so the
// explorer sidebar, the component palette and `logisim-cli --tty stats` printed programmer
// identifiers: "DipSwitch", "NoConnect", "LedBar", "Binary_to_BCD_converter", "FPToInt". That
// was 105 of 105 remaining `--tty stats` failures.
//
// The corpus found the twelve components and one library it happens to contain. It cannot find
// the other thirty-odd, and it says nothing at all about the *tool* names the sidebar renders.
// So the gate is not the corpus: it is `tools/valuebridge/NameBridge.java`, which walks
// `new Builtin()` inside the shipped jar and prints, for every library and every tool:
//
//     LIB  \t <parent> \t <lib._ID>        \t <lib.getDisplayName()>
//     TOOL \t <lib>    \t <tool.getName()> \t <tool.getDisplayName()> \t <factory.getDisplayName()> \t <class>
//
// Its output is committed at `tools/valuebridge/names-4.1.0.tsv`, next to the
// `components-4.1.0.tsv` that `ComponentBridge.java` produces, for the reason
// `OffsetBoundsOracleTests` gives about `bounds-4.1.0.oracle`: it derives only from the public
// jar, no corpus, no coursework, so committing it lets the gate run with no JVM installed.
//
// ── The finding this suite exists to protect, and it is NOT intuitive ────────────────────────
//
// **`tool.getDisplayName()` and `tool.getFactory().getDisplayName()` are different strings for
// 66 of the 173 builtin tools, and both are shipped.** `AddTool.getDisplayName()` is
//
//     return desc == null ? factory.getDisplayName() : desc.getDisplayName(); // AddTool.java:309
//
// and upstream passes a *different* bundle key to the description than the factory passes to
// its own constructor. `IoLibrary` declares `S.getter("dipswitchComponent")` -> "Dip switch";
// `DipSwitch`'s constructor passes `S.getter("DipSwitchComponent")` -> "DIP Switch". One
// capital letter apart, two live strings. All 61 TTL parts diverge the same way, far more
// visibly: the factory says "7400" and the description says "7400: quad 2-input NAND gate".
//
// The sidebar renders the tool's (`ProjectOutlineBuilder`), `--tty stats` prints the factory's
// (`TtyInterface.java:86` and `:104`). A port that keeps one string is wrong for one of the two
// consumers, so this suite checks the two columns INDEPENDENTLY. Swapping the port's
// `DescribedAddTool` for a plain `AddTool`, or vice versa, turns it red.
//
// ── Why the coverage assertions are not decoration ───────────────────────────────────────────
//
// A table-driven differential whose table failed to load, or whose lookup silently matched
// nothing, agrees with everything. That shape has scored empty output as a pass twice in this
// project. So `comparedTools` and `comparedLibraries` have floors, and three named strings that
// were literally wrong before this change are asserted individually.
//
// Regenerate the table with the command in `NameBridge.java`'s header if 4.1.0 is re-pinned.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import Testing

@testable import LogisimStd

// MARK: - The table

/// One `LIB` or `TOOL` row of `names-4.1.0.tsv`.
struct NameOracleRow {
  let kind: String  // "LIB" | "TOOL"
  /// `LIB`: the parent library's id. `TOOL`: the owning library's id.
  let owner: String
  /// `LIB`: `_ID`. `TOOL`: `Tool.getName()`.
  let identifier: String
  /// `Library.getDisplayName()` / `Tool.getDisplayName()`.
  let displayName: String
  /// `TOOL` only: `AddTool.getFactory().getDisplayName()`, or `nil` for a non-`AddTool`.
  let factoryDisplayName: String?
}

enum NameOracle {

  /// `tools/valuebridge/names-4.1.0.tsv`, located relative to this source file so the suite
  /// needs no environment variable and no resource bundle.
  static var tablePath: String {
    // …/swift/Tests/LogisimStdTests/DisplayNameOracleTests.swift → repo root
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimStdTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // repo root
    return root.appendingPathComponent("tools/valuebridge/names-4.1.0.tsv").path
  }

  static func load() throws -> [NameOracleRow] {
    let text = try String(contentsOfFile: tablePath, encoding: .utf8)
    var rows: [NameOracleRow] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 4 else { continue }
      let factoryDisplay: String? =
        (f.count >= 5 && f[4] != "-") ? f[4] : nil
      rows.append(
        NameOracleRow(
          kind: f[0], owner: f[1], identifier: f[2], displayName: f[3],
          factoryDisplayName: factoryDisplay))
    }
    return rows
  }
}

// MARK: - Suite

@Suite("display names against the 4.1.0 Java oracle", .serialized)
struct DisplayNameOracleTests {

  /// `#Soc`'s factories live in `LogisimSoc`, which depends on this module, so the arrow cannot
  /// point back and this test target cannot construct them. Its *library* row is still checked;
  /// the shell that carries the name lives in `LogisimFile` and is registered regardless.
  private static let toolsUnreachableFromHere: Set<String> = ["Soc"]

  @Test("the oracle table is present and well-formed")
  func tableLoads() throws {
    let rows = try NameOracle.load()
    let libs = rows.filter { $0.kind == "LIB" }
    let tools = rows.filter { $0.kind == "TOOL" }
    #expect(libs.count == 15, "expected 15 LIB rows (Builtin + 14), got \(libs.count)")
    #expect(tools.count > 150, "table at \(NameOracle.tablePath) looks truncated: \(tools.count)")
    // The row that motivated the whole exercise; if the table stops carrying it the suite has
    // quietly stopped testing the thing it was written for.
    let dip = tools.first { $0.identifier == "DipSwitch" }
    #expect(dip?.displayName == "Dip switch")
    #expect(dip?.factoryDisplayName == "DIP Switch")
  }

  @Test("every builtin library's displayName is 4.1.0's")
  func libraryDisplayNames() throws {
    StdLibraries.registerAll()
    let builtin = Builtin()
    let rows = try NameOracle.load().filter { $0.kind == "LIB" }

    var compared = 0
    var mismatches: [String] = []
    var absent: [String] = []
    for row in rows {
      let library: Library? =
        row.identifier == Builtin.libraryId ? builtin : builtin.library(named: row.identifier)
      guard let library else {
        absent.append(row.identifier)
        continue
      }
      compared += 1
      if library.displayName != row.displayName {
        mismatches.append(
          "\(row.identifier): java \(row.displayName.debugDescription) "
            + "vs swift \(library.displayName.debugDescription)")
      }
    }

    #expect(absent.isEmpty, "the port has no library for: \(absent)")
    #expect(compared == 15, "compared \(compared) libraries, expected 15")
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
  }

  @Test("every builtin tool's displayName AND its factory's are 4.1.0's")
  func toolAndFactoryDisplayNames() throws {
    StdLibraries.registerAll()
    let builtin = Builtin()
    let rows = try NameOracle.load().filter { $0.kind == "TOOL" }

    var comparedTools = 0
    var comparedFactories = 0
    var unported: [String] = []
    var toolMismatches: [String] = []
    var factoryMismatches: [String] = []

    for row in rows {
      if Self.toolsUnreachableFromHere.contains(row.owner) { continue }
      guard let library = builtin.library(named: row.owner) else {
        unported.append("\(row.owner)/\(row.identifier) (no library)")
        continue
      }
      guard let tool = library.tools.first(where: { $0.name == row.identifier }) else {
        unported.append("\(row.owner)/\(row.identifier)")
        continue
      }

      comparedTools += 1
      if tool.displayName != row.displayName {
        toolMismatches.append(
          "\(row.owner)/\(row.identifier): tool name java \(row.displayName.debugDescription) "
            + "vs swift \(tool.displayName.debugDescription)")
      }

      guard let expectedFactoryName = row.factoryDisplayName,
        let factory = (tool as? AddTool)?.factory
      else { continue }
      comparedFactories += 1
      if factory.displayName != expectedFactoryName {
        factoryMismatches.append(
          "\(row.owner)/\(row.identifier): factory name java "
            + "\(expectedFactoryName.debugDescription) vs swift "
            + "\(factory.displayName.debugDescription)")
      }
    }

    // Floors, not exact counts: an unported family is a parity gap on the M-backlog, not a
    // naming bug, and it must not be able to turn this green by emptying the comparison.
    #expect(comparedTools > 140, "only \(comparedTools) tools compared — lookup is broken")
    #expect(comparedFactories > 130, "only \(comparedFactories) factories compared")
    #expect(toolMismatches.isEmpty, "\(toolMismatches.joined(separator: "\n"))")
    #expect(factoryMismatches.isEmpty, "\(factoryMismatches.joined(separator: "\n"))")
    if !unported.isEmpty {
      print("display-name oracle: \(unported.count) tool(s) not ported — \(unported)")
    }
  }

  @Test("the tool name and the factory name are allowed to differ, and do")
  func describedToolsKeepBothStrings() throws {
    StdLibraries.registerAll()
    let builtin = Builtin()

    // DipSwitch: two bundle keys one capital letter apart. Losing `DescribedAddTool` collapses
    // these onto "DIP Switch"; losing the factory's `displayName:` argument collapses them onto
    // "Dip switch"; losing both gives "DipSwitch". All three are distinguishable here.
    let io = try #require(builtin.library(named: Builtin.ioId))
    let dip = try #require(io.tools.first { $0.name == "DipSwitch" } as? AddTool)
    #expect(dip.displayName == "Dip switch")
    #expect(dip.factory.displayName == "DIP Switch")

    // TTL: the factory keeps the bare part number, the palette entry carries the description.
    let ttl = try #require(builtin.library(named: Builtin.ttlId))
    let t7400 = try #require(ttl.tools.first { $0.name == "7400" } as? AddTool)
    #expect(t7400.displayName == "7400: quad 2-input NAND gate")
    #expect(t7400.factory.displayName == "7400")

    // A cloned toolbar entry must keep the description's name; `AddTool.cloneTool()` would
    // silently downgrade it to the factory's, so the toolbar and the palette would disagree.
    let clone = try #require(t7400.cloneTool() as? AddTool)
    #expect(clone.displayName == "7400: quad 2-input NAND gate")
    #expect(clone.sharesSource(t7400))
  }

  @Test("the strings the owner reported seeing are the corrected ones")
  func spotChecksFromTheBugReport() throws {
    StdLibraries.registerAll()
    let builtin = Builtin()

    func factoryDisplayName(_ library: String, _ name: String) throws -> String {
      let lib = try #require(builtin.library(named: library), "no library \(library)")
      let tool = try #require(
        lib.tools.first { $0.name == name } as? AddTool, "no tool \(name) in \(library)")
      return tool.factory.displayName
    }

    // Every one of these printed its `_ID` before the fix, and each appears in the corpus
    // `--tty stats` diff with the count `namediff.py` measured.
    #expect(try factoryDisplayName(Builtin.ioId, "DipSwitch") == "DIP Switch")  // 19 cases
    #expect(try factoryDisplayName(Builtin.wiringId, "NoConnect") == "Do not connect")  // 16
    #expect(try factoryDisplayName(Builtin.plexersId, "BitSelector") == "Bit Selector")  // 13
    #expect(try factoryDisplayName(Builtin.ioId, "LedBar") == "LED Bar")  // 12
    #expect(try factoryDisplayName(Builtin.arithmeticId, "BitFinder") == "Bit Finder")  // 11
    #expect(try factoryDisplayName(Builtin.memoryId, "Random") == "Random Generator")  // 8
    #expect(try factoryDisplayName(Builtin.ioId, "DotMatrix") == "LED Matrix")  // 8
    #expect(try factoryDisplayName(Builtin.arithmeticId, "BitAdder") == "Bit Adder")  // 5
    #expect(try factoryDisplayName(Builtin.ioId, "RGBLED") == "RGB LED")  // 2
    #expect(try factoryDisplayName(Builtin.ioId, "PortIO") == "Port I/O")  // 1

    // Case-only, and therefore the easiest to "fix" wrongly: upstream's _ID is
    // "Digital Oscilloscope" and its display name is "Digital oscilloscope".
    let extra = try #require(builtin.library(named: Builtin.extraIoId))
    let scope = try #require(
      extra.tools.first { $0.name == "Digital Oscilloscope" } as? AddTool)
    #expect(scope.factory.displayName == "Digital oscilloscope")
    #expect(scope.factory.name == "Digital Oscilloscope")

    // The two library headers the sidebar shows.
    #expect(builtin.library(named: Builtin.extraIoId)?.displayName == "Input/Output Extra")
    #expect(
      builtin.library(named: Builtin.fpArithmeticId)?.displayName
        == "Floating Point Arithmetic")
  }

  @Test("a factory that passes no display name still answers its _ID, exactly as Java does")
  func defaultIsTheIdentifier() throws {
    StdLibraries.registerAll()
    let builtin = Builtin()
    // `AbstractComponentFactory.getDisplayGetter()` is `constantGetter(getName())`, and ~90
    // builtin factories rely on it because their `_ID` already IS the English name. If the
    // fallback were changed to anything else, these would move.
    let gates = try #require(builtin.library(named: Builtin.gatesId))
    let and = try #require(gates.tools.first { $0.name == "AND Gate" } as? AddTool)
    #expect(and.factory.displayName == "AND Gate")
    #expect(and.displayName == "AND Gate")

    let memory = try #require(builtin.library(named: Builtin.memoryId))
    let ram = try #require(memory.tools.first { $0.name == "RAM" } as? AddTool)
    #expect(ram.factory.displayName == "RAM")
  }
}
