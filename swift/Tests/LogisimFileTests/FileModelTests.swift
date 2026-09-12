// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// `LogisimFile`, `ToolbarData` and `MouseMappings`; the parts of file loading that do not need
// a `.circ` on disk.

import Foundation
import Testing

@testable import LogisimFile

private final class ToolbarSpy: ToolbarListener {
  var changes = 0
  func toolbarChanged() { changes += 1 }
}

private final class MappingsSpy: MouseMappingsListener {
  var changes = 0
  func mouseMappingsChanged() { changes += 1 }
}

@Test func aNewFileTakesTheDefaultProjectName() { LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  #expect(file.name == "Untitled")
  #expect(file.circuits.isEmpty)
  #expect(!file.isDirty)
} }

@Test func theDefaultProjectNameIsDisambiguatedAgainstOpenProjects() {
  // The `defer { removeAll() }` this replaces did not restore anything: it cleared, leaving
  // BOTH seams nil for every concurrent suite. `withCleared` puts back exactly what was there
  // and holds the lock across the whole window, so no other suite can observe the gap.
  LogisimFileSeams.withCleared {
    LogisimFileSeams.projectNameInUse = { ["Untitled", "Untitled_2"].contains($0) }
    #expect(LogisimFile.createEmpty(loader: Loader()).name == "Untitled_3")
  }
}

@Test func createNewInstallsAMainCircuitWithoutFiringEvents() throws { try LogisimFileSeams.withCleared {
  let file = try LogisimFile.createNew(loader: Loader())
  #expect(file.circuitCount == 1)
  #expect(file.mainCircuit === file.circuits.first)
  #expect(file.mainCircuit?.name == "main")
  #expect(file.tools.count == 1)
  #expect(file.circuit(named: "main") === file.mainCircuit)
  #expect(file.contains(circuit: try #require(file.mainCircuit)))
} }

@Test func addingACircuitMakesTheFirstOneMain() throws { try LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  let first = try Circuit(name: "alpha", file: file)
  let second = try Circuit(name: "beta", file: file)
  file.addCircuit(first)
  file.addCircuit(second)
  #expect(file.mainCircuit === first)
  #expect(file.circuits.map(\.name) == ["alpha", "beta"])
  #expect(file.indexOfCircuit(second) == 1)
  // The circuit's own strong owner is the file; the AddTool's factory edge is unowned.
  #expect(file.addTool(for: second)?.factory.name == "beta")
} }

@Test func theLastCircuitCannotBeRemoved() throws { try LogisimFileSeams.withCleared {
  let file = try LogisimFile.createNew(loader: Loader())
  let main = try #require(file.mainCircuit)
  #expect(throws: LoadFailedError.self) { try file.removeCircuit(main) }
  #expect(file.circuitCount == 1)
} }

@Test func removingTheMainCircuitPromotesTheFirstRemainingOne() throws { try LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  let first = try Circuit(name: "alpha", file: file)
  let second = try Circuit(name: "beta", file: file)
  file.addCircuit(first)
  file.addCircuit(second)
  try file.removeCircuit(first)
  #expect(file.mainCircuit === second)
  #expect(file.circuitCount == 1)
} }

@Test func aDuplicateCircuitNameIsDetectedButOnlyAgainstOtherCircuits() throws { try LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  let alpha = try Circuit(name: "alpha", file: file)
  file.addCircuit(alpha)
  #expect(file.circuitNameConflicts("alpha", changed: nil))
  // A circuit never conflicts with itself; that is what makes a no-op rename legal.
  #expect(!file.circuitNameConflicts("alpha", changed: alpha))
  #expect(!file.circuitNameConflicts("", changed: nil))
  // VHDL is the default HDL and its identifiers are case-insensitive.
  #expect(file.circuitNameConflicts("ALPHA", changed: nil))
} }

@Test func aCircuitNameCollidingWithALibraryToolIsRejected() { LogisimFileSeams.withCleared {
  let loader = Loader()
  let file = LogisimFile.createEmpty(loader: loader)
  file.addLibrary(loader.loadLibrary(desc: "#Base"))
  #expect(file.circuitNameConflicts("Poke Tool", changed: nil))
  #expect(!file.circuitNameConflicts("not a tool", changed: nil))
} }

@Test func messagesAreDrainedInOrderAndOnlyOnce() { LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  file.addMessage("first")
  file.addMessage("second")
  #expect(file.takeMessage() == "first")
  #expect(file.takeMessage() == "second")
  #expect(file.takeMessage() == nil)
} }

@Test func dirtyStateTracksTheAutosaveFlagWithIt() { LogisimFileSeams.withCleared {
  let file = LogisimFile.createEmpty(loader: Loader())
  #expect(!file.isAutosaveDirty)
  file.setDirty(true)
  #expect(file.isDirty && file.isAutosaveDirty)
  file.setDirty(false)
  #expect(!file.isDirty && !file.isAutosaveDirty)
} }

@Test func removeLibraryByNameIsSilentWhileRemoveLibraryByReferenceFiresAnEvent() { LogisimFileSeams.withCleared {
  let loader = Loader()
  let file = LogisimFile.createEmpty(loader: loader)
  let gates = loader.loadLibrary(desc: "#Gates")
  file.addLibrary(gates)
  #expect(file.libraries.count == 1)
  #expect(file.removeLibrary(named: "Gates"))
  #expect(file.libraries.isEmpty)
  #expect(!file.removeLibrary(named: "Gates"))
} }

// MARK: - ToolbarData

@Test func toolbarSeparatorsAreNullEntriesAndSurviveEveryQuery() {
  let toolbar = ToolbarData()
  let spy = ToolbarSpy()
  toolbar.addToolbarListener(spy)

  let poke = BuiltinPlaceholderTool(id: "Poke Tool")
  let edit = BuiltinPlaceholderTool(id: "Edit Tool")
  toolbar.addSeparator()
  toolbar.addTool(poke)
  toolbar.addTool(edit)

  #expect(toolbar.count == 3)
  #expect(toolbar.get(0) == nil)
  #expect(toolbar.firstTool === poke)
  #expect(toolbar.toolbarContents.compactMap { $0?.name } == ["Poke Tool", "Edit Tool"])
  #expect(spy.changes == 3)

  toolbar.move(from: 0, to: 2)
  #expect(toolbar.get(2) == nil)
  #expect(toolbar.remove(at: 0) === poke)
  #expect(toolbar.count == 2)
}

@Test func toolbarReportsWhetherItUsesAToolFromALibrary() {
  let toolbar = ToolbarData()
  let poke = BuiltinPlaceholderTool(id: "Poke Tool")
  let other = BuiltinPlaceholderTool(id: "Poke Tool")
  toolbar.addTool(poke)
  // `sharesSource` is reference identity in the base class (D4), so a same-named tool from a
  // different library does not count.
  #expect(toolbar.usesToolFromSource(poke))
  #expect(!toolbar.usesToolFromSource(other))
}

// MARK: - MouseMappings

@Test func mouseMappingsStoreAndCacheByModifierMask() {
  let mappings = MouseMappings()
  let spy = MappingsSpy()
  mappings.addMouseMappingsListener(spy)

  let poke = BuiltinPlaceholderTool(id: "Poke Tool")
  mappings.setToolFor(modifiers: 1024, tool: poke)
  #expect(spy.changes == 1)
  #expect(mappings.toolFor(modifiers: 1024) === poke)
  #expect(mappings.toolFor(modifiers: 2048) == nil)
  #expect(mappings.mappedModifiers == [1024])

  // Setting the very same tool object again fires nothing: Java compares with `!=` on
  // references.
  mappings.setToolFor(modifiers: 1024, tool: poke)
  #expect(spy.changes == 1)

  mappings.setToolFor(modifiers: 1024, tool: nil)
  #expect(spy.changes == 2)
  #expect(mappings.toolFor(modifiers: 1024) == nil)
  // Removing something that is not there fires nothing.
  mappings.setToolFor(modifiers: 1024, tool: nil)
  #expect(spy.changes == 2)
}

@Test func mouseMappingsSeeASelectToolByItsUpstreamId() {
  let mappings = MouseMappings()
  #expect(!mappings.containsSelectTool)
  mappings.setToolFor(modifiers: 0x400, tool: BuiltinPlaceholderTool(id: "Select Tool"))
  #expect(mappings.containsSelectTool)
}
