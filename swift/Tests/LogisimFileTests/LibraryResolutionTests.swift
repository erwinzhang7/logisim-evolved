// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// The load-bearing gate for library resolution: every corpus file declares twelve builtin
// libraries while instantiating components from two or three, and an unresolved `<lib>` fails
// the whole load. These tests assert that every builtin descriptor resolves *by its exact
// string*, and that the permanent `jar#` gap (D11) routes through D8's opaque path instead of
// destroying the declaration.

import Foundation
import Testing

@testable import LogisimFile

@Test func everyBuiltinDescriptorResolvesToItsLibrary() {
  let loader = Loader()
  #expect(Builtin.allDescriptors.count == 14)
  for descriptor in Builtin.allDescriptors {
    let library = loader.loadLibrary(desc: descriptor)
    #expect(!(library is MissingLibrary), "\(descriptor) did not resolve")
    #expect("#" + library.name == descriptor)
  }
}

/// The exact twelve every corpus file declares. Spelled out rather than derived from
/// `allDescriptors`, so a typo in the registry cannot make the test agree with itself.
@Test func theTwelveDeclaredByEveryCorpusFileResolve() {
  let declared = [
    "#Base", "#Gates", "#Wiring", "#Plexers", "#Arithmetic", "#Memory", "#I/O", "#TTL",
    "#TCL", "#Base", "#BFH-Praktika", "#Input/Output-Extra", "#Soc",
  ]
  let loader = Loader()
  for descriptor in Set(declared) {
    let library = loader.loadLibrary(desc: descriptor)
    #expect(!(library is MissingLibrary), "\(descriptor) did not resolve")
  }
}

@Test func builtinDescriptorsAreCaseAndPunctuationSensitive() {
  let loader = Loader()
  // `I/O` is not `IO`, `FPArithmetic` is not `FP Arithmetic`, `HDL-IP` is not `HDL IP`. Each of
  // these is a plausible transcription slip that would fail a whole file at load.
  for wrong in ["#IO", "#FP Arithmetic", "#HDL IP", "#Input/Output Extra", "#SOC"] {
    #expect(loader.loadLibrary(desc: wrong) is MissingLibrary, "\(wrong) should not resolve")
  }
}

@Test func aJarLibraryBecomesAnOpaquePlaceholderRatherThanNothing() {
  let loader = Loader()
  let descriptor = "jar#logisim-uart.jar#org.cdm.logisim.uart.Components"
  let library = loader.loadLibrary(desc: descriptor)
  let missing = try? #require(library as? MissingLibrary)
  #expect(missing?.descriptorText == descriptor)
  #expect(
    missing?.reason
      == .jarUnsupported(file: "logisim-uart.jar", className: "org.cdm.logisim.uart.Components"))
  // D8: any component name the file asks for gets a stable placeholder, so `<comp lib="6"
  // name="UART">` still has something to bind to and survives the round trip.
  let tool = missing?.tool(named: "UART")
  #expect(tool?.name == "UART")
  #expect(missing?.tool(named: "UART") === tool)
}

@Test func anUnavailableBuiltinIsPreservedRatherThanDropped() {
  let loader = Loader()
  // Real in the corpus: 3.0.0-era builtins that 4.1.0 no longer ships.
  let library = loader.loadLibrary(desc: "#Risc-V")
  let missing = try? #require(library as? MissingLibrary)
  #expect(missing?.descriptorText == "#Risc-V")
  #expect(missing?.reason == .builtinUnavailable(name: "Risc-V"))
  #expect(missing?.name == "Risc-V")
}

@Test func theBaseLibraryAnswersTextByNameWithoutPublishingIt() {
  let base = BaseLibrary()
  #expect(base.isHidden)
  // 4.1.0's BaseLibrary publishes exactly these five tools. Image was added after the pinned
  // release and must not resolve in this fidelity port.
  #expect(base.tools.map(\.name) == ["Poke Tool", "Edit Tool", "Wiring Tool", "Text Tool", "Menu Tool"])
  // `Text` is reachable only through `getTool`, which is what XmlCircuitReader relies on for
  // `<comp lib="0" name="Text">`.
  #expect(base.tool(named: "Text")?.name == "Text")
  #expect(!base.tools.contains { $0.name == "Text" })
  #expect(base.tool(named: "Image") == nil)
}

@Test func aMissingBuiltinStillReportsItsDescriptorToTheWriter() throws {
  let loader = Loader()
  let library = loader.loadLibrary(desc: "#Yosys Components")
  // D8's round-trip guarantee: no recomputation, no canonicalisation.
  #expect(try loader.descriptor(for: library) == "#Yosys Components")
}

@Test func builtinDescriptorsRoundTripThroughTheDescriptorLookup() throws {
  let loader = Loader()
  for descriptor in Builtin.allDescriptors {
    let library = loader.loadLibrary(desc: descriptor)
    #expect(try loader.descriptor(for: library) == descriptor)
  }
}
