// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// IS THE RENDERER ACTUALLY WIRED INTO THE APPLICATION?
//
// `CanvasDrawsTests` proves the renderer draws when someone calls it. This file proves someone
// calls it, which is the failure that actually happened: `CircuitRenderer` was complete and
// correct and `grep -rn CircuitRenderer Sources/LogisimUI` returned nothing, so the shipping
// app drew a placeholder with a watermark on it.
//
// So these tests start where the application starts: at `ProjectHostFactory.openProject`, with
// the bytes of a document, and follow the same path the window does, `makeRenderSurface()`,
// asserting that what comes back has real geometry in it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

private func corpusCircFile() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  let root = URL(fileURLWithPath: path)
  guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
  else { return nil }
  return walk.compactMap { $0 as? URL }
    .filter { $0.pathExtension == "circ" }
    .sorted { $0.path < $1.path }
    .first
}

@Suite("Canvas wiring")
struct CanvasWiringTests {

  // NOTE. These three used to run against `DemoProjectHostFactory`, which is gone: the real
  // `LogisimFileProjectHostFactory` now backs `ProjectHostFactoryRegistry`. The assertions are
  // the same question, does the surface the *application* vends hold real geometry, asked of
  // the object that ships.

  @Test("a new, unsaved document gets a real circuit from the default template")
  @MainActor
  func newDocumentDraws() throws {
    let host = try LogisimFileProjectHostFactory().makeEmptyProject()
    let surface = host.makeRenderSurface()
    let concrete = try #require(surface as? CircuitCanvasSurface)

    // A new document is upstream's `default.templ`: thirteen libraries and one **empty**
    // circuit called "main". So the canvas is legitimately blank, and that is the change from
    // the stand-in, which drew a demonstration circuit to avoid an empty window. What must be
    // true is that the surface is pointed at the real circuit and rebuilds when it gains
    // something; asserted below rather than assumed.
    #expect(concrete.build.components.isEmpty)

    let real = try #require(host as? LogisimFileProjectHost)
    let circuit = try #require(real.currentCircuitObject)
    #expect(circuit.name == "main")

    let factory = AndGate.factory
    try circuit.mutatorAdd(
      try factory.createComponent(
        location: Location.create(120, 100, hasToSnap: false),
        attributes: factory.createAttributeSet()))

    #expect(concrete.build.components.count == 1)
    #expect(concrete.build.scene.primitives.count > 0)
    #expect(!concrete.contentBounds.isNull)
    #expect(concrete.hitTargets.contains { !$0.displayName.isEmpty })
  }

  @Test("opening a real .circ draws that file, not a stand-in")
  @MainActor
  func openedDocumentDraws() throws {
    guard let url = corpusCircFile() else {
      print("LOGISIM_CORPUS unset — canvas wiring corpus check skipped")
      return
    }
    let data = try Data(contentsOf: url)
    let host = try LogisimFileProjectHostFactory().openProject(
      data: data, url: url, contentType: LogisimDocumentType.circuit)
    let concrete = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    #expect(concrete.build.components.count > 0)
    #expect(concrete.build.scene.primitives.count > 0)

    // And the geometry is the file's, compared against the same file loaded independently
    // through the same `Loader`; the one quantity that cannot coincide by accident.
    let independent = try #require(try Loader().openLogisimFile(data: data))
    let expected = independent.mainCircuit ?? independent.circuits.first
    #expect(concrete.build.components.count == expected?.components.count)
    print(
      "canvas wiring: \(url.lastPathComponent) — \(concrete.build.components.count) components, "
        + "\(concrete.build.scene.primitives.count) primitives")
  }

  @Test("unreadable bytes open an empty project and report the failure")
  @MainActor
  func unreadableFileFallsBack() throws {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data("this is not a circ file".utf8), url: nil,
      contentType: LogisimDocumentType.circuit)
    _ = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    // Never a blank window with no explanation: a file we cannot read is a message.
    let issues = host.drainPendingIssues()
    #expect(issues.contains { $0.severity == .failure })
    #expect(!host.outline.circuits.isEmpty)
  }

  @Test("the demonstration circuit still builds — CanvasCircuitSource's own unit")
  @MainActor
  func demonstrationCircuitStillDraws() throws {
    // `CanvasCircuitSource` was the renderer team's way of drawing something real before the
    // project layer existed. Nothing in the shipping path calls it any more, the host hands
    // the canvas its own `Circuit`, but the file belongs to another slice, so it is exercised
    // here rather than removed from under them.
    let circuit = try #require(CanvasCircuitSource.demonstrationCircuit())
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    #expect(build.paintedComponentCount > 0)
    #expect(build.scene.primitives.count > 0)
  }

  @Test("the surface rebuilds when the circuit changes and not when it does not")
  @MainActor
  func rebuildsOnCircuitChange() throws {
    CanvasCircuitSource.registerBuiltinLibrariesIfNeeded()
    let circuit = try Circuit(name: "rebuild")
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)
    #expect(surface.build.components.isEmpty)

    let factory = AndGate.factory
    let component = try factory.createComponent(
      location: Location.create(100, 100, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)

    // `Circuit` fires ACTION_ADD; the surface's listener is what turns that into a rebuild.
    // Without it the canvas would show a circuit that no longer exists: upstream's
    // `Canvas`/`CircuitListener` pairing, reproduced through a token rather than a raw
    // registration (D3).
    #expect(surface.build.components.count == 1)
    #expect(surface.build.scene.primitives.count > 0)

    let after = surface.build.scene.primitives.count
    surface.setViewport(CanvasViewport(zoom: 3, center: .zero, viewSize: CGSize(width: 800, height: 600)))
    #expect(surface.build.scene.primitives.count == after, "a camera move rebuilt the scene")
  }
}
