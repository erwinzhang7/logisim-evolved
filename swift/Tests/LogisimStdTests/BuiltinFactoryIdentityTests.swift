// BuiltinFactoryIdentityTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// IS A COMPONENT FACTORY THE SAME OBJECT FOR THE WHOLE PROCESS?
//
// Upstream it is, by construction and without anyone having to remember: every builtin factory
// is a `public static final FACTORY` singleton (`Pin.FACTORY`, `AndGate.FACTORY`, …), and the
// families that route through `FactoryDescription` get the same guarantee from the other side;
// `FactoryDescription` is itself a `private static final` array element and caches the factory
// it reflectively loads. So `AddTool.sharesSource`, which is `factory == other.factory` and
// nothing else, cannot be defeated by *when* something is registered.
//
// This port inverts the dependency: `LogisimFile` declares `BuiltinToolProviders` and
// `LogisimStd` fills it in with CLOSURES. A closure that says `{ MemoryLibrary().tools }`
// constructs a whole library, and therefore a brand-new `DFlipFlop()`, on every call, and
// `BuiltinLibraryShell` calls it again whenever the registry's generation counter moves. Every
// `register` bumps that counter, so a second `StdLibraries.registerAll()` from any other suite
// silently re-mints every factory in the process.
//
// The consequence is not cosmetic. `XmlReader` clones library tools into the toolbar and the
// mouse mappings, and `XmlWriter.fromTool` resolves a tool back to its library through
// `sharesSource`. Re-mint the factories under a loaded document and every cloned toolbar entry
// becomes unattributable: the palette cannot say which library a button came from, and saving
// reports `tool '…' not found`.
//
// ── WHAT MAKES THESE TESTS DISCRIMINATING ───────────────────────────────────────────────────
//
// A test that registers, reads the tools and compares identity inside ONE generation passes
// against the broken code; the shell's cache makes identity stable until the counter moves.
// Both tests below therefore force the counter to move between the clone and the comparison,
// which is the actual failing shape reported from the app and from `ComponentPaletteTests`.
//
// The bump is a second `StdLibraries.registerAll()` rather than a synthetic
// `register(libraryId: "…")`, for two reasons: it is what really happens (several suites and
// both executables call it), and it leaves the registry holding exactly what it held before, so
// these tests cannot strand a neighbouring suite the way a bare `removeAll()` can.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("Builtin factory identity", .serialized)
struct BuiltinFactoryIdentityTests {

  /// A cut-down `default.templ`: four libraries, and a toolbar holding one tool from each of the
  /// three that matter here. `#Wiring` and `#Gates` build their `AddTool`s over singleton
  /// factories already, `#Memory` constructs a fresh `Register()` per library instance, so a
  /// list that covers all three fails for Memory alone and reports which family broke.
  private static let circ = """
    <?xml version="1.0" encoding="UTF-8"?>
    <project version="1.0">
     <lib name="0" desc="#Wiring" />
     <lib name="1" desc="#Gates" />
     <lib name="4" desc="#Memory" />
     <lib name="8" desc="#Base" />
     <toolbar>
      <tool lib="8" name="Poke Tool" />
      <sep />
      <tool lib="0" name="Pin" />
      <tool lib="1" name="AND Gate" />
      <tool lib="4" name="D Flip-Flop" />
      <tool lib="4" name="Register" />
     </toolbar>
     <circuit name="main" />
    </project>
    """

  private func loadFile() throws -> LogisimFile {
    StdLibraries.registerAll()
    return try #require(try Loader().openLogisimFile(data: Data(Self.circ.utf8)))
  }

  @Test("a loaded toolbar still resolves to its library after a late registration")
  func toolbarSurvivesALateRegistration() throws {
    let file = try loadFile()

    // The clones `XmlReader` put on the toolbar. `cloneTool()` is unconditional there, exactly as
    // upstream, because a toolbar entry carries its own attribute set.
    let toolbar = file.options.toolbarData.toolbarContents.compactMap { $0 }
    let addTools = toolbar.filter { $0 is AddTool }
    #expect(addTools.count == 4, "expected 4 AddTool toolbar entries, saw \(addTools.count)")

    // Baseline: they resolve BEFORE anything moves. If this half fails the file above is wrong,
    // not the registry.
    for entry in addTools {
      let source = file.libraries.flatMap(\.tools).first { $0.sharesSource(entry) }
      #expect(source != nil, "\(entry.name) did not resolve even before the bump")
    }

    // THE BUMP. Another suite, or the other executable, registering the same libraries again.
    // Nothing about the document changed; only `BuiltinToolProviders.generation` did.
    StdLibraries.registerAll()

    let after = file.libraries.flatMap(\.tools)
    for entry in addTools {
      let source = after.first { $0.sharesSource(entry) }
      let orphaned = """
        after a late registration, toolbar entry \(entry.name) shares its source with no \
        library tool — its factory was re-minted underneath it
        """
      #expect(source != nil, Comment(rawValue: orphaned))
      // Still a clone, not the library's own object: sharing it would make configuring a toolbar
      // button edit the library.
      if let source { #expect(source !== entry, "\(entry.name) is the library's own object") }
    }
  }

  @Test("two loaders see the same factory objects for the same builtin library")
  func factoryIdentityIsProcessStable() throws {
    StdLibraries.registerAll()

    // Two `Loader`s, which upstream gives two distinct `Builtin` instances and two distinct
    // `MemoryLibrary` objects: but only ONE `Register` factory, because upstream's factories are
    // static. The shells are deliberately materialised on either side of a bump, so this fails
    // for the registry reason and not merely because the two loaders differ.
    let first = try #require(try Loader().openLogisimFile(data: Data(Self.circ.utf8)))
    let firstFactories = Self.factories(of: first, library: "Memory")

    StdLibraries.registerAll()

    let second = try #require(try Loader().openLogisimFile(data: Data(Self.circ.utf8)))
    let secondFactories = Self.factories(of: second, library: "Memory")

    #expect(!firstFactories.isEmpty, "#Memory published no AddTools at all")
    #expect(firstFactories.count == secondFactories.count)
    for (lhs, rhs) in zip(firstFactories, secondFactories) {
      let remade = """
        \(lhs.name) is a different factory object in the second loader; `sharesSource` and \
        `Library.indexOf` both compare factories by reference, so nothing loaded by one loader \
        can be attributed by the other
        """
      #expect(lhs === rhs, Comment(rawValue: remade))
    }
  }

  /// Every `AddTool` factory a named library publishes, in order.
  private static func factories(
    of file: LogisimFile, library name: String
  ) -> [any ComponentFactory] {
    guard let library = file.libraries.first(where: { $0.name == name }) else { return [] }
    return library.tools.compactMap { ($0 as? AddTool)?.factory }
  }
}
