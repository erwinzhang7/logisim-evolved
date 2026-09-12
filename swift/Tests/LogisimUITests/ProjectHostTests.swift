// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// IS THE PROJECT LAYER REAL?
//
// The sibling suites ask the same question of the renderer, twice, because the answer was twice
// "no" in a way a build could not see: `CircuitRenderer` emitted a complete scene that nothing
// called, and before that it "painted" six components while emitting zero primitives.
//
// The project layer had the same shape of hole and a larger one. `DemoProjectHost` implemented
// every member of `ProjectHost` correctly against fabricated data: a twelve-library explorer out
// of literals, a four-circuit list out of literals, an attribute table out of literals with an
// override dictionary behind it, and `achievedTickHz = requestedTickHz`, which is exactly the
// `TickCounter` behaviour D7 exists to eliminate. Every one of those compiles, runs, and looks
// right on screen.
//
// So this suite never asserts that a call returns *something*. It asserts that what comes back
// agrees with the file, loaded independently through the same `Loader` the round-trip gate uses:
//
//   • the explorer lists the file's actual circuits and libraries
//   • selecting one changes what the canvas surface holds
//   • the inspector reports a real attribute, by name and by value
//   • editing goes through `CircuitMutation` and is undoable, and a bad value THROWS (D13)
//   • the rate control moves the real `SimulationClock`, and a tick advances the real
//     `Propagator`
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

// MARK: - Corpus

/// The first corpus file with at least two circuits; "selecting a circuit changes the canvas"
/// is not assertable on a single-circuit file, and silently passing on one would be the same
/// class of false green this suite exists to catch.
@MainActor
private func corpusFileWithSeveralCircuits() -> (url: URL, data: Data, file: LogisimFile)? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  let root = URL(fileURLWithPath: path)
  guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
  else { return nil }
  let urls = walk.compactMap { $0 as? URL }
    .filter { $0.pathExtension == "circ" }
    .sorted { $0.path < $1.path }

  for url in urls {
    guard let data = try? Data(contentsOf: url),
      let file = try? Loader().openLogisimFile(data: data),
      file.circuits.count >= 2,
      file.circuits.contains(where: { !$0.components.isEmpty })
    else { continue }
    return (url, data, file)
  }
  return nil
}

/// Poll the engine's snapshot. Propagation happens on the clock thread (D1), so a request posted
/// from the main actor completes asynchronously; there is no completion handler to await and
/// inventing one would change the design to suit the test.
private func waitForEngine(
  _ engine: SimulationEngine,
  timeout: TimeInterval = 3,
  until predicate: (SimulationSnapshot) -> Bool
) -> Bool {
  let deadline = Date(timeIntervalSinceNow: timeout)
  while Date() < deadline {
    if predicate(engine.snapshot) { return true }
    usleep(2000)
  }
  return predicate(engine.snapshot)
}

// MARK: - Structure

@Suite("Project host — structure")
struct ProjectHostStructureTests {

  @Test("a new project has a real main circuit, not a fabricated outline")
  @MainActor
  func newProjectIsReal() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)

    // `LogisimFile.createNew` makes exactly one circuit, called "main". The demo host produced
    // four circuits with invented component counts and a fabricated error string on one of them.
    #expect(host.outline.circuits.count == 1)
    #expect(host.outline.circuits.first?.name == "main")
    #expect(host.outline.circuits.first?.isMain == true)
    #expect(host.currentCircuit == host.outline.circuits.first?.id)
    #expect(host.currentCircuitObject === host.file.mainCircuit)
    #expect(host.isDirty == false)
  }

  @Test("the explorer lists the file's actual circuits and libraries")
  @MainActor
  func explorerMatchesTheFile() throws {
    guard let corpus = corpusFileWithSeveralCircuits() else {
      print("LOGISIM_CORPUS unset — project host corpus gate skipped")
      return
    }
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: corpus.data, url: corpus.url, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)

    // The reference is the same file loaded independently through the same `Loader` the
    // round-trip gate drives: not a hand-written expectation, which could agree with a wrong
    // host.
    let expectedCircuits = corpus.file.circuits.map(\.name)
    let listedCircuits = host.outline.circuits.filter { $0.kind == .circuit }.map(\.name)
    #expect(listedCircuits == expectedCircuits)
    #expect(!listedCircuits.isEmpty)

    // Exactly one main circuit, and it is the file's.
    let main = host.outline.circuits.filter(\.isMain)
    #expect(main.count == 1)
    #expect(main.first?.name == corpus.file.mainCircuit?.name)

    // Component counts are the circuits', not invented.
    for item in host.outline.circuits where item.kind == .circuit {
      let circuit = try #require(corpus.file.circuits.first { $0.name == item.name })
      #expect(item.componentCount == circuit.components.count)
    }

    // Libraries: every non-hidden `<lib>` the file declares, by display name.
    let expectedLibraries = corpus.file.libraries.filter { !$0.isHidden }.map(\.displayName)
    #expect(host.outline.libraries.map(\.name) == expectedLibraries)
    #expect(host.outline.libraries.count >= 2)

    // And each library's tool list is that library's own, not a literal.
    for item in host.outline.libraries {
      let library = try #require(corpus.file.libraries.first { $0.displayName == item.name })
      if library.tools.isEmpty { continue }
      #expect(item.tools.map(\.name) == library.tools.map(\.displayName))
    }

    print(
      "project host: \(corpus.url.lastPathComponent) — \(listedCircuits.count) circuits, "
        + "\(host.outline.libraries.count) libraries, "
        + "\(host.outline.libraries.reduce(0) { $0 + $1.tools.count }) tools")
  }

  @Test("the editing tools come from the file's own #Base library")
  @MainActor
  func editingToolsAreTheFilesOwn() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let base = try #require(host.file.library(named: Builtin.baseId))
    #expect(!base.tools.isEmpty)
    #expect(host.outline.editingTools.count == base.tools.count)
    // `Project.editTool` resolves the Edit tool through this same library; if the toolbar were
    // built from a literal list the two would be different objects and selecting a tool in the
    // toolbar would not be the tool the project holds.
    #expect(host.activeTool != nil)
    #expect(host.project.tool != nil)
  }

  @Test("an unreadable document opens as an empty project and says why")
  @MainActor
  func unreadableFileReportsRatherThanCrashes() throws {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data("this is not a circ file".utf8), url: nil,
      contentType: LogisimDocumentType.circuit)
    let issues = host.drainPendingIssues()
    #expect(issues.contains { $0.severity == .failure })
    // Never a window with nothing in it and no explanation.
    #expect(!host.outline.circuits.isEmpty)
  }
}

// MARK: - Canvas

@Suite("Project host — canvas")
struct ProjectHostCanvasTests {

  @Test("selecting a circuit in the explorer changes what the canvas renders")
  @MainActor
  func selectingACircuitChangesTheCanvas() throws {
    guard let corpus = corpusFileWithSeveralCircuits() else {
      print("LOGISIM_CORPUS unset — canvas switching gate skipped")
      return
    }
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: corpus.data, url: corpus.url, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    // The canvas starts on the file's main circuit and holds *its* components.
    let first = try #require(host.currentCircuitObject)
    #expect(surface.build.components.count == first.components.count)

    // A circuit whose component count differs from the current one, so "the canvas changed" is
    // provable by the one quantity that cannot coincide; the same trick `CanvasWiringTests`
    // uses to tell a real file from the demonstration circuit.
    guard
      let target = host.outline.circuits.first(where: {
        $0.kind == .circuit && $0.componentCount != first.components.count
      })
    else {
      Issue.record("corpus file has no two circuits of differing size; pick another")
      return
    }

    try host.perform(.setCurrentCircuit(target.id))

    #expect(host.currentCircuitObject?.name == target.name)
    #expect(host.currentCircuit == target.id)
    // The surface, the thing that actually draws, is holding the new circuit's components.
    #expect(surface.build.components.count == target.componentCount)
    #expect(surface.build.components.count != first.components.count)
    // And its geometry moved with it, so a zoom-to-fit would frame the right thing.
    #expect(!surface.contentBounds.isNull || target.componentCount == 0)
    print(
      "canvas switch: \(first.name) (\(first.components.count)) -> "
        + "\(target.name) (\(target.componentCount))")
  }

  @Test("a component's world bounds come from the component, and reveal them")
  @MainActor
  func boundsAreTheComponents() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let factory = AndGate.factory
    let component = try factory.createComponent(
      location: Location.create(120, 100, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)

    let id = CircuitSceneSource.identity(of: component)
    let bounds = try #require(host.bounds(of: id))
    #expect(bounds.width == CGFloat(component.bounds.width))
    #expect(bounds.height == CGFloat(component.bounds.height))
    // And the ID a canvas hit produces is the same one the host indexes by; the two agree on
    // what a component is called, which is what makes explorer→canvas reveal work at all.
    #expect(host.outline.circuits.first?.componentCount == 1)
  }
}

// MARK: - Inspector

@Suite("Project host — inspector")
struct ProjectHostInspectorTests {

  /// A one-gate project, so the assertions can name a specific attribute.
  @MainActor
  private func gateProject() throws -> (
    host: LogisimFileProjectHost, component: any Component, id: ComponentID
  ) {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let factory = AndGate.factory
    let component = try factory.createComponent(
      location: Location.create(120, 100, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    let id = CircuitSceneSource.identity(of: component)
    host.setSelection(.components([id]))
    return (host, component, id)
  }

  @Test("the inspector reports the component's real AttributeSet")
  @MainActor
  func inspectorReportsRealAttributes() throws {
    let (host, component, _) = try gateProject()
    let form = host.inspectorForm(for: host.selection)

    let rows = form.sections.flatMap(\.rows)
    #expect(!rows.isEmpty)

    // Every row is an attribute the component actually has; the demo host produced rows for
    // "vendorExtension" and "size" on everything, whether or not the component defined them.
    let real = Set(component.attributeSet.attributes.filter { !$0.isHidden }.map(\.name))
    let listed = Set(rows.map(\.key.name))
    #expect(listed == real, "inspector rows \(listed.sorted()) != attributes \(real.sorted())")

    // And a specific one carries the value the set holds, not a literal. A gate always has
    // `width` (`StdAttr.WIDTH`) and it is a bit width.
    let widthRow = try #require(rows.first { $0.key.name == "width" })
    let widthAttribute = try #require(component.attributeSet.attribute(named: "width"))
    let stored = try #require(component.attributeSet.rawValue(widthAttribute))
    guard case .bitWidth(let bits) = stored else {
      Issue.record("width is stored as \(stored), expected .bitWidth")
      return
    }
    #expect(widthRow.value == .boundedInteger(Int(bits), range: 1...BitWidth.maxWidth))
  }

  @Test("editing an attribute changes the model and lands on the undo stack")
  @MainActor
  func editingGoesThroughCircuitMutation() throws {
    let (host, component, _) = try gateProject()
    let attribute = try #require(component.attributeSet.attribute(named: "width"))
    let before = component.attributeSet.rawValue(attribute)
    #expect(host.undoStatus.canUndo == false)

    try host.apply(
      AttributeEdit(target: host.selection, key: AttributeKey("width"), newValue: .integer(8)))

    // The *model* moved, not an override dictionary in the host.
    #expect(component.attributeSet.rawValue(attribute) == .bitWidth(8))
    #expect(component.attributeSet.rawValue(attribute) != before)

    // …and it is undoable, which is what "goes through CircuitMutation" buys.
    #expect(host.undoStatus.canUndo)
    #expect(host.undoStatus.undoStack.first?.contains("Data Bits") == true)

    try host.perform(.undo)
    #expect(component.attributeSet.rawValue(attribute) == before)
    #expect(host.undoStatus.canRedo)

    try host.perform(.redo)
    #expect(component.attributeSet.rawValue(attribute) == .bitWidth(8))
  }

  @Test("a value the attribute refuses THROWS rather than being swallowed — D13")
  @MainActor
  func badValueThrows() throws {
    let (host, component, _) = try gateProject()
    let attribute = try #require(component.attributeSet.attribute(named: "width"))
    let before = component.attributeSet.rawValue(attribute)

    // `BitWidth.create` throws for anything past `Value.MAX_WIDTH`; D13 names
    // `<a name="width" val="999"/>` as the canonical case. Upstream's `AttrTable` catches the
    // exception and reverts the cell with no explanation, so the user gets no signal at all.
    #expect(throws: (any Error).self) {
      try host.apply(
        AttributeEdit(
          target: host.selection, key: AttributeKey("width"), newValue: .integer(999)))
    }
    // Nothing changed, and nothing was pushed onto the undo stack for an edit that did not
    // happen.
    #expect(component.attributeSet.rawValue(attribute) == before)
    #expect(host.undoStatus.canUndo == false)
  }

  @Test("the circuit's own attributes are inspectable and editable")
  @MainActor
  func circuitAttributesAreReal() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuitID = try #require(host.currentCircuit)
    host.setSelection(.circuit(circuitID))

    let form = host.inspectorForm(for: host.selection)
    let rows = form.sections.flatMap(\.rows)
    #expect(form.title == "main")
    #expect(rows.contains { $0.key.name == "circuit" })

    try host.apply(
      AttributeEdit(
        target: .circuit(circuitID), key: AttributeKey("circuit"), newValue: .text("renamed")))
    #expect(host.currentCircuitObject?.name == "renamed")
    #expect(host.undoStatus.canUndo)
  }

  @Test("a multi-selection shows the intersection, with differing values marked")
  @MainActor
  func multiSelectionIntersects() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)

    func place(_ factory: any ComponentFactory, width: Int32?) throws -> any Component {
      let attributes = factory.createAttributeSet()
      if let width, let attribute = attributes.attribute(named: "width") {
        try attributes.setRawValue(attribute, .bitWidth(width))
      }
      let component = try factory.createComponent(
        location: Location.create(100 + Int(width ?? 1) * 20, 100, hasToSnap: false),
        attributes: attributes)
      try circuit.mutatorAdd(component)
      return component
    }

    let a = try place(AndGate.factory, width: 1)
    let b = try place(OrGate.factory, width: 4)
    host.setSelection(
      .components([CircuitSceneSource.identity(of: a), CircuitSceneSource.identity(of: b)]))

    let rows = host.inspectorForm(for: host.selection).sections.flatMap(\.rows)
    let width = try #require(rows.first { $0.key.name == "width" })
    #expect(width.value == .mixed)
    // `facing` agrees across both, so it shows its shared value rather than the marker.
    if let facing = rows.first(where: { $0.key.name == "facing" }) {
      #expect(facing.value != .mixed)
    }
  }
}

// MARK: - Simulation

@Suite("Project host — simulation")
struct ProjectHostSimulationTests {

  @Test("the rate control drives the real anchored clock, not a Timer — D7")
  @MainActor
  func rateControlDrivesTheClock() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)

    host.perform(.setTickFrequency(8))
    // The assertion is against `SimulationClock` itself, not against the projected status: a
    // host that only updated `SimulationStatus.requestedTickHz` would pass a status-level test
    // and drive nothing. That is precisely what the object this replaces did.
    #expect(host.engine.clock.ticksPerSecond == 8)
    #expect(host.simulation.requestedTickHz == 8)

    // A rate change re-anchors the schedule; the origin is the clock's, not a Timer's fire date.
    host.perform(.setTickFrequency(64))
    #expect(host.engine.clock.ticksPerSecond == 64)

    // …and it is stored on the circuit, as upstream does, so reopening restores it.
    #expect(host.currentCircuitObject?.tickFrequency == 64)
  }

  @Test("achievedTickHz is never filled in with the request — D7")
  @MainActor
  func achievedRateIsHonest() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    host.perform(.setTickFrequency(4096))
    // Nothing has ticked, so there is no achieved rate. Upstream's `TickCounter` has four
    // separate return paths that hand back the requested frequency here, which is why a
    // simulation running at 300 Hz against a 10 kHz request reads "10 kHz" indefinitely.
    #expect(host.simulation.achievedTickHz == nil)
    #expect(host.engine.clock.report().achievedTicksPerSecond == nil)
  }

  @Test("a tick advances the real Propagator")
  @MainActor
  func tickPropagates() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let factory = AndGate.factory
    try circuit.mutatorAdd(
      try factory.createComponent(
        location: Location.create(120, 100, hasToSnap: false),
        attributes: factory.createAttributeSet()))

    // The root `CircuitState` is built on the propagation thread, so it appears asynchronously.
    #expect(
      waitForEngine(host.engine) { $0.canStep },
      "no root CircuitState was ever built — the propagation thread never ran")

    let before = host.engine.snapshot.halfCycleCount
    host.perform(.tickHalf)
    #expect(
      waitForEngine(host.engine) { $0.halfCycleCount > before },
      "Propagator.tickCount did not move: the tick reached no propagator")

    let afterHalf = host.engine.snapshot.halfCycleCount
    host.perform(.tickFull)
    #expect(
      waitForEngine(host.engine) { $0.halfCycleCount >= afterHalf + 2 },
      "a full cycle is two half-cycles (MenuSimulate's Simulator.tick(2))")

    // Step and reset reach the same propagator without throwing out of the thread.
    host.perform(.step)
    host.perform(.reset)
    #expect(waitForEngine(host.engine) { $0.halfCycleCount == 0 })
    #expect(host.simulation.errorMessage == nil)
  }

  @Test("auto-ticking starts and stops the clock thread")
  @MainActor
  func autoTickingRunsTheClock() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    host.perform(.setTickFrequency(256))
    host.perform(.toggleTicking)
    #expect(host.engine.clock.isRunning)
    #expect(
      waitForEngine(host.engine) { $0.halfCycleCount > 2 },
      "the clock reported running but nothing propagated")
    host.perform(.toggleTicking)
    #expect(host.engine.clock.isRunning == false)
  }
}

// MARK: - Persistence

@Suite("Project host — persistence")
struct ProjectHostPersistenceTests {

  @Test("serialize goes through the real writer and the result reloads")
  @MainActor
  func serializeRoundTrips() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let factory = AndGate.factory
    try circuit.mutatorAdd(
      try factory.createComponent(
        location: Location.create(120, 100, hasToSnap: false),
        attributes: factory.createAttributeSet()))

    let data = try host.serialize()
    // The demo host emitted an XML comment saying it was a placeholder. This is a real document:
    // it parses back through the same `Loader` and carries the component that was placed.
    let reloaded = try #require(try Loader().openLogisimFile(data: data))
    #expect(reloaded.circuits.count == 1)
    #expect(reloaded.circuits.first?.nonWires.count == 1)
    #expect(reloaded.circuits.first?.nonWires.first?.factory.name == AndGate.factory.name)
    #expect(host.isDirty == false, "saving must mark the file clean")
  }

  @Test("a corpus document survives open → serialize → open")
  @MainActor
  func corpusRoundTrips() throws {
    guard let corpus = corpusFileWithSeveralCircuits() else {
      print("LOGISIM_CORPUS unset — host round-trip gate skipped")
      return
    }
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: corpus.data, url: corpus.url, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)

    let written = try host.serialize()
    let reloaded = try #require(try Loader().openLogisimFile(data: written))
    #expect(reloaded.circuits.map(\.name) == corpus.file.circuits.map(\.name))
    for (a, b) in zip(reloaded.circuits, corpus.file.circuits) {
      #expect(a.components.count == b.components.count, "\(a.name) lost or gained components")
    }
  }
}
