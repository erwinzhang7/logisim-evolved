// SocFactoryIdentityTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// #Soc's COPY OF THE DEFECT BOARD #67 FIXED FOR THE ELEVEN `LogisimStd` FAMILIES
//
// `LogisimStdTests/BuiltinFactoryIdentityTests` records the shape in full. The short version:
// `BuiltinToolProviders.tools(forLibraryId:)` invokes the registered closure on every call, and
// `BuiltinLibraryShell` re-invokes it whenever the registry's generation counter moves, which
// every `register`, for any library, does. A provider of the shape `{ SocLibrary().tools }`
// therefore mints a brand-new `Rv32imRiscV()`/`SocBus()`/… on each call.
//
// `AddTool.sharesSource` is `factory === other.factory` and nothing else; `Library.contains` and
// `Library.indexOf` are the same comparison (D4); and `XmlReader` stores *clones* of library
// tools in the toolbar and the mouse mappings. So any `.circ` that puts a SoC component on its
// toolbar is orphaned the moment anything registers anything: the palette can no longer say
// which library the button came from, and `XmlWriter.fromTool` fails the save with
// `tool '…' not found`.
//
// `SocLibrary.swift`'s own comment defended the fresh-per-call closure; "a fresh `SocLibrary`
// per call matches `Builtin` being per-`Loader`". Per-`Loader` is right for the *Library* and
// for the `AddTool` objects (upstream builds a new `AddTool` per `Library` instance, and each
// carries its own attribute set). It is wrong for the *factory*: upstream's are
// `public static final FACTORY` singletons, process-stable by construction.
//
// ── WHAT MAKES THESE TESTS DISCRIMINATING ───────────────────────────────────────────────────
//
// `toolIdentityIsStable` in `SocLibraryRegistrationTests` reads `library.tools` twice off ONE
// `SocLibrary` and passes against the broken code, because the `lazy var` memoises within an
// instance. The defect lives one level up, between two *provider invocations*. Both tests below
// therefore cross that boundary: the first by calling the registry twice, the second by moving
// the generation counter under an already-loaded document, which is the shape reported from the
// app.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimSoc

@Suite("#Soc factory identity", .serialized)
struct SocFactoryIdentityTests {

  /// A minimal document that puts two `#Soc` entries on the toolbar. `Rv32im` and `SocBus` are
  /// deliberately different families of the eight; a fix that pinned only the first entry would
  /// still fail on the second.
  private static let circ = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Base" name="0"/>
      <lib desc="#Wiring" name="1"/>
      <lib desc="#Soc" name="11"/>
      <main name="main"/>
      <toolbar>
        <tool lib="0" name="Poke Tool"/>
        <sep/>
        <tool lib="11" name="Rv32im"/>
        <tool lib="11" name="SocBus"/>
      </toolbar>
      <circuit name="main"/>
    </project>
    """

  private static func registerEverything() {
    StdLibraries.registerAll()
    SocLibrary.registerBuiltinTools()
  }

  @Test("two provider calls hand out the same eight factory objects")
  func providerIsFactoryStable() {
    Self.registerEverything()

    let first = BuiltinToolProviders.tools(forLibraryId: Builtin.socId)
    let second = BuiltinToolProviders.tools(forLibraryId: Builtin.socId)

    #expect(first.count == 8, "#Soc published \(first.count) tools, expected 8")
    #expect(first.count == second.count)

    for (lhs, rhs) in zip(first, second) {
      // The tool OBJECTS must differ: upstream builds a new `AddTool` per `Library`, and each
      // holds its own attribute set, so sharing one would make configuring a toolbar button edit
      // the palette entry.
      #expect(lhs !== rhs, "\(lhs.name): the provider handed out its own tool object twice")

      let lhsFactory = (lhs as? AddTool)?.factory
      let rhsFactory = (rhs as? AddTool)?.factory
      #expect(lhsFactory != nil, "\(lhs.name) is not an AddTool")
      let remade = """
        \(lhs.name) is a different ComponentFactory object on the provider's second call; \
        `AddTool.sharesSource` and `Library.indexOf` both compare factories by reference (D4), \
        so nothing resolved from the first call can be attributed after the second
        """
      #expect(lhsFactory === rhsFactory, Comment(rawValue: remade))
    }
  }

  @Test("a loaded #Soc toolbar entry still resolves after a late registration")
  func toolbarSurvivesALateRegistration() throws {
    Self.registerEverything()
    let file = try #require(try Loader().openLogisimFile(data: Data(Self.circ.utf8)))

    let toolbar = file.options.toolbarData.toolbarContents.compactMap { $0 }
    let socEntries = toolbar.filter { $0.name == Rv32imRiscV.id || $0.name == SocBus.id }
    #expect(socEntries.count == 2, "expected 2 #Soc toolbar entries, saw \(socEntries.count)")

    // Baseline. If this half fails the fixture is wrong, not the registry.
    for entry in socEntries {
      let source = file.libraries.flatMap(\.tools).first { $0.sharesSource(entry) }
      #expect(source != nil, "\(entry.name) did not resolve even before the bump")
    }

    // THE BUMP: another executable, or another suite, registering again. Nothing about the
    // document changed; only `BuiltinToolProviders.generation` did.
    Self.registerEverything()

    let after = file.libraries.flatMap(\.tools)
    for entry in socEntries {
      let orphaned = """
        after a late registration, toolbar entry \(entry.name) shares its source with no library \
        tool — its factory was re-minted underneath it, so the palette cannot name the library it \
        came from and `XmlWriter.fromTool` would fail the save
        """
      #expect(after.contains { $0.sharesSource(entry) }, Comment(rawValue: orphaned))
    }
  }
}
