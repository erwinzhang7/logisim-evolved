// SocLibraryRegistrationTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS SUITE EXISTS AT ALL
//
// Before it, `LogisimSoc` had 78 source files and **zero** tests; the largest untested module
// in the tree. That is not merely a coverage number: every claim about this subsystem was a
// reading of the Java rather than a measurement, and this project's own record says readings of
// the Java have been wrong repeatedly.
//
// The specific thing asserted here is the join, not the parts. `<lib desc="#Soc">` resolves
// through `BuiltinToolProviders`, which `LogisimFile` declares and *something above it* has to
// fill in. For `#Soc` that something cannot be `StdLibraries.registerAll()`, `LogisimSoc`
// depends on `LogisimStd`, so the arrow cannot point back, so it is
// `SocLibrary.registerBuiltinTools()`, called by each executable separately. Exactly the shape
// that cost `PlexersLibrary` and `ExtraIoLibrary` 2,052 placements: ported, and not registered.
//
// The `_ID` strings are checked one by one against the Java `public static final String _ID`
// (`Soc.java`'s `FactoryDescription` list resolves them reflectively; there is no reflection
// here, so each is transcribed). They are NOT tidy; `"Socmem"` has a lower-case m, and the
// JTAG UART is `"SocJtagUart"` while its Java class is `JtagUart`. One wrong character makes one
// tool silently unresolvable in every file that names it, with no error anywhere.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimSoc

@Suite("#Soc resolves, and every tool id matches the Java _ID", .serialized)
struct SocLibraryRegistrationTests {

  /// Every `_ID` in `com.cburch.logisim.soc`, transcribed from the 4.1.0 tree, in `Soc.java`'s
  /// `DESCRIPTIONS` order, which is also the order `XmlWriter.fromLibrary` walks when deciding
  /// which `<tool>` elements a `<lib desc="#Soc">` needs, so the order is observable in output.
  static let expectedIds = [
    "Rv32im",  // rv32im/Rv32imRiscV.java:51
    "Nios2",  // nios2/Nios2.java:53
    "SocBus",  // bus/SocBus.java:45
    "Socmem",  // memory/SocMemory.java:43
    "SocPio",  // pio/SocPio.java:44
    "SocVga",  // vga/SocVga.java:45
    "SocDma",  // dma/SocDma.java:60
    "SocJtagUart",  // jtaguart/JtagUart.java:44
  ]

  @Test("the library exposes the eight factories, in upstream's order, under upstream's ids")
  func toolIdsAndOrder() {
    let library = SocLibrary()
    let names = library.tools.map(\.name)
    #expect(names == Self.expectedIds)
  }

  @Test("the tool list is memoised, so factory identity survives repeated access (D4)")
  func toolIdentityIsStable() {
    let library = SocLibrary()
    let first = library.tools
    let second = library.tools
    #expect(first.count == second.count)
    for (a, b) in zip(first, second) {
      #expect(a === b, "AddTool.sharesSource and Library.contains compare by reference (D4)")
    }
  }

  @Test("registerBuiltinTools fills the #Soc slot that StdLibraries.registerAll cannot")
  func registrationFillsTheBuiltinSlot() {
    SocLibrary.registerBuiltinTools()
    let tools = BuiltinToolProviders.tools(forLibraryId: Builtin.socId)
    #expect(!tools.isEmpty, "#Soc resolved to no tools — the registration seam is open")
    #expect(tools.map(\.name) == Self.expectedIds)
  }

  /// The third argument of each factory's `super(_ID, …, <flags>)` call in 4.1.0. These decide
  /// what `SocSimulationManager.registerComponent` does with a placed component; a factory
  /// missing `SOC_SLAVE` is never registered on any bus and answers no transaction, silently.
  @Test("each factory answers to the SoC role Java gives it")
  func socKinds() {
    #expect(Rv32imRiscV().socKind == [.master, .slave])  // Rv32imRiscV.java:54
    #expect(Nios2().socKind == [.master])  // Nios2.java:77
    #expect(SocBus().socKind == [.bus])  // SocBus.java:50
    #expect(SocMemory().socKind == [.slave])  // SocMemory.java:46
    #expect(SocPio().socKind == [.slave])  // SocPio.java:50
    #expect(SocVga().socKind == [.slave, .sniffer, .master])  // SocVga.java:48
    #expect(SocDma().socKind == [.slave, .master])  // SocDma.java:70
    #expect(JtagUart().socKind == [.slave])  // JtagUart.java:58
  }
}
