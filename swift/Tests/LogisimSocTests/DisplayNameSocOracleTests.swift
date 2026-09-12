// DisplayNameSocOracleTests.swift: part of logisim-evolved.
//
// The `#Soc` half of the display-name gate, against the 4.1.0 jar's own answer.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS IS A SECOND SUITE AND NOT MORE ROWS IN THE FIRST ONE
//
// `LogisimStdTests/DisplayNameOracleTests` covers the other thirteen builtin libraries and
// explicitly skips this one:
//
//     private static let toolsUnreachableFromHere: Set<String> = ["Soc"]
//
// That is not an oversight and it cannot be removed. `LogisimSoc` depends on `LogisimStd`
// (D9's arrow: kernel → file → std → soc), so the arrow cannot point back, and
// `LogisimStdTests`' dependencies are `["LogisimStd", "LogisimFile", "LogisimKernel"]`; the
// SoC factories are not in its link graph and cannot be constructed there at all. Adding rows
// there would not compile; adding them and letting the lookup miss would be worse, because a
// differential whose lookup matches nothing agrees with everything. So the floor for the eight
// SoC rows lives here, in the one target that links `LogisimSoc`.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT WAS WRONG
//
// `SocInstanceFactoryBase.init` took no display name, so `super.init(name)` left
// `InstanceFactoryBase.factoryDisplayName` nil and `displayName` fell through to
// `factoryName`: the `.circ` `_ID`. The explorer sidebar, the palette and `--tty stats`
// printed "Socmem", "SocJtagUart", "Rv32im", "SocPio". Upstream every one of the eight passes
// a getter: `super(_ID, S.getter("SocBusComponent"), SOC_BUS)` (`SocBus.java:50`).
//
// `SocLibrary.displayName` was the same defect one level up, and had a comment defending it:
// `Library.displayName` falls back to `name`, so the library answered "Soc" where 4.1.0
// answers "System On a Chip". D5/D9 drop the *bundle lookup*, not the string.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE TWO COLUMNS ARE CHECKED SEPARATELY, AND THAT IS THE POINT
//
// `AddTool.getDisplayName()` is `desc == null ? factory.getDisplayName() : desc.getDisplayName()`
// (`AddTool.java:309`), and upstream frequently gives the description a different bundle key
// than the factory gives its own constructor: 66 of 173 builtin tools disagree with their own
// factory, which is why `DescribedAddTool` exists.
//
// `#Soc` declares descriptions for all eight components (`Soc.java:37-46`) but passes each the
// SAME key the factory passes (`S.getter("SocBusComponent")` in both places), so here the two
// columns agree and a plain `AddTool` is correct. That is a *measured* result, not an
// assumption, and it is exactly the kind of claim that rots: if a future re-pin of 4.1.0, or a
// mistaken "tidy-up" of the library, splits the two, `toolAndFactoryNamesAreCheckedApart` goes
// red instead of passing on a collapsed string. Hence both columns, read independently out of
// the TSV, never one derived from the other.
//
// The table is `tools/valuebridge/names-4.1.0.tsv`, the committed output of
// `tools/valuebridge/NameBridge.java` run against the shipped jar. Regenerate with the command
// in that file's header if 4.1.0 is re-pinned.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimSoc

// MARK: - The table

/// One `TOOL` or `LIB` row of `names-4.1.0.tsv`.
private struct SocNameOracleRow {
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

private enum SocNameOracle {

  /// Located relative to this source file, so the suite needs no environment variable and no
  /// resource bundle; same arrangement `DisplayNameOracleTests` uses for the same reason.
  static var tablePath: String {
    // …/swift/Tests/LogisimSocTests/DisplayNameSocOracleTests.swift → repo root
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimSocTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // repo root
    return root.appendingPathComponent("tools/valuebridge/names-4.1.0.tsv").path
  }

  static func load() throws -> [SocNameOracleRow] {
    let text = try String(contentsOfFile: tablePath, encoding: .utf8)
    var rows: [SocNameOracleRow] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 4 else { continue }
      rows.append(
        SocNameOracleRow(
          kind: f[0], owner: f[1], identifier: f[2], displayName: f[3],
          factoryDisplayName: (f.count >= 5 && f[4] != "-") ? f[4] : nil))
    }
    return rows
  }

  /// The eight `TOOL` rows owned by `Soc`, in the table's order (which is `DESCRIPTIONS`' order).
  static func socTools() throws -> [SocNameOracleRow] {
    try load().filter { $0.kind == "TOOL" && $0.owner == "Soc" }
  }

  /// The single `LIB` row for `Soc` itself.
  static func socLibraryRow() throws -> SocNameOracleRow? {
    try load().first { $0.kind == "LIB" && $0.identifier == "Soc" }
  }
}

// MARK: - Suite

@Suite("#Soc display names against the 4.1.0 Java oracle", .serialized)
struct DisplayNameSocOracleTests {

  /// Upstream's count. `#Soc` has had exactly these eight since 4.1.0 and the `.circ` format
  /// pins the ids, so an exact count is safe here where `DisplayNameOracleTests` needs a floor.
  private static let expectedSocToolCount = 8

  // ── The guard against the failure mode that has scored empty output as a pass twice ───────

  @Test("the oracle table loads and actually carries the #Soc rows")
  func tableCarriesSocRows() throws {
    let all = try SocNameOracle.load()
    #expect(all.count > 150, "table at \(SocNameOracle.tablePath) looks truncated: \(all.count)")

    let tools = try SocNameOracle.socTools()
    let emptyFilterWarning =
      "expected \(Self.expectedSocToolCount) #Soc TOOL rows, got \(tools.count) — if this is 0 "
      + "the filter matched nothing and every comparison below is vacuous"
    #expect(tools.count == Self.expectedSocToolCount, "\(emptyFilterWarning)")

    // Not decoration: every assertion in this suite is driven off these strings, so if the
    // table stopped carrying them the suite would agree with anything the port said.
    #expect(tools.allSatisfy { !$0.displayName.isEmpty })
    #expect(tools.allSatisfy { $0.factoryDisplayName?.isEmpty == false })

    let library = try #require(try SocNameOracle.socLibraryRow(), "no LIB row for Soc")
    #expect(library.owner == "Builtin")
    #expect(!library.displayName.isEmpty)
  }

  // ── The factories ─────────────────────────────────────────────────────────────────────────

  @Test("every #Soc factory's displayName is 4.1.0's, not its _ID")
  func factoryDisplayNames() throws {
    let rows = try SocNameOracle.socTools()
    let library = SocLibrary()

    var compared = 0
    var absent: [String] = []
    var mismatches: [String] = []

    for row in rows {
      guard let tool = library.tools.first(where: { $0.name == row.identifier }) as? AddTool
      else {
        absent.append(row.identifier)
        continue
      }
      guard let expected = row.factoryDisplayName else { continue }
      compared += 1
      if tool.factory.displayName != expected {
        mismatches.append(
          "\(row.identifier): java \(expected.debugDescription) vs swift "
            + "\(tool.factory.displayName.debugDescription)")
      }
    }

    #expect(absent.isEmpty, "the port has no tool for: \(absent)")
    #expect(
      compared == Self.expectedSocToolCount,
      "compared \(compared) factories, expected \(Self.expectedSocToolCount)")
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
  }

  @Test("every #Soc tool's displayName is 4.1.0's")
  func toolDisplayNames() throws {
    let rows = try SocNameOracle.socTools()
    let library = SocLibrary()

    var compared = 0
    var mismatches: [String] = []
    for row in rows {
      guard let tool = library.tools.first(where: { $0.name == row.identifier }) else { continue }
      compared += 1
      if tool.displayName != row.displayName {
        mismatches.append(
          "\(row.identifier): java \(row.displayName.debugDescription) vs swift "
            + "\(tool.displayName.debugDescription)")
      }
    }

    #expect(
      compared == Self.expectedSocToolCount,
      "compared \(compared) tools, expected \(Self.expectedSocToolCount)")
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
  }

  /// The structural claim `SocLibrary.swift` records: for `#Soc`, and unlike 66 of the 173
  /// builtin tools, the description's getter and the factory's are the same key. This reads the
  /// two TSV columns independently rather than deriving one from the other, so it fails if that
  /// ever stops being true instead of quietly agreeing with a collapsed string.
  @Test("tool name and factory name are read apart, and for #Soc they agree")
  func toolAndFactoryNamesAreCheckedApart() throws {
    let rows = try SocNameOracle.socTools()
    #expect(rows.count == Self.expectedSocToolCount)

    for row in rows {
      let factoryName = try #require(row.factoryDisplayName, "\(row.identifier) has no column 5")
      let splitWarning =
        "4.1.0 now splits \(row.identifier) into tool \(row.displayName.debugDescription) vs "
        + "factory \(factoryName.debugDescription). #Soc's plain AddTools answer the factory's "
        + "string, so this tool now needs DescribedAddTool — see "
        + "LogisimStd/Instance/FactoryDescription.swift."
      #expect(row.displayName == factoryName, "\(splitWarning)")
    }

    // And the port agrees with both columns at once, which is what a plain AddTool means.
    let library = SocLibrary()
    for row in rows {
      let tool = try #require(
        library.tools.first { $0.name == row.identifier } as? AddTool, "no tool \(row.identifier)")
      #expect(tool.displayName == tool.factory.displayName)
    }
  }

  // ── The exact strings, spelled out ────────────────────────────────────────────────────────

  /// The eight literals, written out rather than only compared column-to-column. A table-driven
  /// check proves the port equals the table; these prove the table says what this change claims
  /// it says, so a corrupted or regenerated-against-the-wrong-jar table cannot pass silently.
  @Test("the eight strings are the ones the jar prints")
  func theEightStrings() throws {
    #expect(Rv32imRiscV().displayName == "Risc V IM simulator")
    #expect(Nios2().displayName == "Nios2s simulator")  // sic: "Nios2s", upstream's own typo
    #expect(SocBus().displayName == "SoC bus simulator")
    #expect(SocMemory().displayName == "Memory simulator")
    #expect(SocPio().displayName == "Parallel input/output expander")
    #expect(SocVga().displayName == "VGA screen")
    #expect(SocDma().displayName == "DMA engine")
    #expect(JtagUart().displayName == "JTAG UART")

    // The `_ID`s are untouched; they are the `.circ` interface (D8/M2), and the whole defect
    // was these leaking into the UI *as* the display name. If a fix ever "tidied" an id to
    // match its display name, every file naming that tool would stop resolving.
    #expect(SocMemory().name == "Socmem")
    #expect(JtagUart().name == "SocJtagUart")
    #expect(Rv32imRiscV().name == "Rv32im")
    #expect(SocMemory().name != SocMemory().displayName)
    #expect(JtagUart().name != JtagUart().displayName)
  }

  // ── The library header ────────────────────────────────────────────────────────────────────

  @Test("the #Soc library answers System On a Chip, not Soc")
  func libraryDisplayName() throws {
    let row = try #require(try SocNameOracle.socLibraryRow())
    #expect(SocLibrary().displayName == row.displayName)
    #expect(SocLibrary().displayName == "System On a Chip")
    #expect(SocLibrary().name == "Soc", "the _ID is the .circ interface and must not move")
  }

  /// `BuiltinLibraryShell(id: "Soc", displayName: …)` in `LogisimFile/Builtin.swift` is the
  /// object the explorer actually renders: this class only supplies the tool list, through
  /// `BuiltinToolProviders`. That file is not this module's to edit, so this pins it as a
  /// cross-module agreement: if the two ever disagree, whichever one a caller happens to reach
  /// decides the answer, which is exactly the bug this suite exists to prevent.
  @Test("the Builtin shell and SocLibrary agree, and both match the jar")
  func builtinShellAgreesWithTheLibrary() throws {
    let row = try #require(try SocNameOracle.socLibraryRow())
    let shell = try #require(Builtin().library(named: Builtin.socId), "no #Soc shell in Builtin")
    #expect(shell.displayName == row.displayName)
    #expect(shell.displayName == SocLibrary().displayName)
  }

  /// End to end on the path the sidebar uses: register the provider, then read the names back
  /// off the shell rather than off a directly-constructed `SocLibrary`. The registration seam
  /// is the one that cost `PlexersLibrary` 2,052 placements by being ported and not wired, and
  /// a name that is only right on the un-wired object is not right where anyone can see it.
  @Test("the names survive the BuiltinToolProviders round trip")
  func namesThroughTheRegistrationSeam() throws {
    SocLibrary.registerBuiltinTools()
    let rows = try SocNameOracle.socTools()
    let tools = BuiltinToolProviders.tools(forLibraryId: Builtin.socId)
    #expect(
      tools.count == Self.expectedSocToolCount,
      "#Soc resolved to \(tools.count) tools through the seam")

    var compared = 0
    var mismatches: [String] = []
    for row in rows {
      guard let tool = tools.first(where: { $0.name == row.identifier }) else { continue }
      compared += 1
      if tool.displayName != row.displayName {
        mismatches.append("\(row.identifier): \(tool.displayName) != \(row.displayName)")
      }
      if let addTool = tool as? AddTool, let expected = row.factoryDisplayName,
        addTool.factory.displayName != expected
      {
        mismatches.append("\(row.identifier) factory: \(addTool.factory.displayName) != \(expected)")
      }
    }
    #expect(compared == Self.expectedSocToolCount, "only \(compared) compared through the seam")
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
  }

  /// A cloned toolbar entry must keep the name. `AddTool.cloneTool()` forwards to the factory,
  /// which is correct here precisely *because* `#Soc` needs no `DescribedAddTool`; the check is
  /// cheap and would catch a clone path that dropped the factory reference.
  @Test("a cloned #Soc tool keeps its display name")
  func clonesKeepTheName() throws {
    let library = SocLibrary()
    for tool in library.tools {
      let clone = tool.cloneTool()
      #expect(
        clone.displayName == tool.displayName,
        "\(tool.name): clone says \(clone.displayName.debugDescription)")
    }
  }
}
