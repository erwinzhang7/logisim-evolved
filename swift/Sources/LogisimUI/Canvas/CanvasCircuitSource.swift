// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// WHAT THE CANVAS DRAWS, AND WHERE IT COMES FROM.
//
// The shell's project host is still a stand-in: it has no `LogisimFile` behind it, so it
// cannot hand the canvas a circuit. Rather than let that keep the canvas empty, which is how
// the placeholder surface came to exist and then to survive a whole milestone, this file
// closes the gap from the renderer's side:
//
//   • given the bytes of the document that was actually opened, parse them with the real
//     `Loader` and draw the real circuit;
//   • given nothing (a new, unsaved document), draw a small circuit built from the real
//     builtin factories, so the canvas is never blank and the drawing path is never untested.
//
// It is NOT a substitute for wiring the codec to the project layer. When that lands, the host
// hands its own `Circuit` to `CircuitCanvasSurface.setCircuit(_:)` and this file's
// `makeSurface(data:)` becomes a two-line call to the same method. Nothing else changes, which
// is the point of putting the fallback here instead of inside the surface.
// ============================================================================

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

@MainActor
enum CanvasCircuitSource {

  /// `StdLibraries.registerAll()` materialises a `BuiltinLibraryShell`'s tool list on first
  /// use and caches it, so it must run before the first load and must run exactly once.
  private static var librariesRegistered = false

  static func registerBuiltinLibrariesIfNeeded() {
    guard !librariesRegistered else { return }
    librariesRegistered = true
    StdLibraries.registerAll()
    // FOR THE INTEGRATOR: `logisim-cli/main.swift` performs four further registrations that
    // `StdLibraries.registerAll()` is missing: the real `Text` factory for `#Base`, and the
    // `#Plexers`, `#FpArithmetic` and `#ExtraIo` libraries, which exist and are simply not in
    // the list. They are deliberately NOT duplicated here: the CLI's block carries the
    // measurement that justifies each one and is annotated to be moved *into*
    // `registerAll()`. Until that move happens the canvas draws a component from any of those
    // four as a D8 placeholder box rather than as itself: visible and honest, but wrong.
  }

  /// The surface the shell should show, and anything the user needs told about it.
  struct Result {
    var surface: CircuitCanvasSurface
    var issue: UserFacingIssue?
  }

  static func makeSurface(data: Data?) -> Result {
    registerBuiltinLibrariesIfNeeded()
    let surface = CircuitCanvasSurface()

    guard let data, !data.isEmpty else {
      surface.setCircuit(demonstrationCircuit())
      return Result(surface: surface, issue: nil)
    }

    // Both failure shapes are handled the same way, and both are real: `openLogisimFile(data:)`
    // *throws* on a malformed document and *returns nil* on one it declines, and an early
    // version of this file treated only the throw, so a rejected file left the canvas blank
    // with no explanation, which is the exact failure this whole task is about.
    let reason: String
    do {
      if let file = try Loader().openLogisimFile(data: data),
        let circuit = file.mainCircuit ?? file.circuits.first
      {
        surface.setCircuit(circuit)
        return Result(surface: surface, issue: nil)
      }
      reason = "The file parsed but contained no circuit."
    } catch {
      reason = "\(error)"
    }

    surface.setCircuit(demonstrationCircuit())
    return Result(
      surface: surface,
      issue: UserFacingIssue(
        severity: .warning,
        title: "Could not draw this file",
        detail:
          "\(reason)\n\nThe canvas is showing a demonstration circuit instead. The file "
          + "itself has not been modified."))
  }

  // MARK: - Demonstration circuit

  /// A handful of real components, placed with the real factories.
  ///
  /// Deliberately built out of `AndGate.factory` and friends rather than out of fabricated
  /// rectangles: the reason the placeholder surface was misleading is that it drew shapes that
  /// looked like a schematic without any component code being involved, so "the canvas draws"
  /// was true of it while being false of the application.
  ///
  /// A fresh instance per call, deliberately; a shared one would make two Untitled windows
  /// edit the same components.
  static func demonstrationCircuit() -> Circuit? {
    registerBuiltinLibrariesIfNeeded()
    guard let circuit = try? Circuit(name: "Untitled") else { return nil }

    func place(_ factory: any ComponentFactory, _ x: Int, _ y: Int) {
      let attributes = factory.createAttributeSet()
      guard
        let component = try? factory.createComponent(
          location: Location.create(x, y, hasToSnap: false), attributes: attributes)
      else { return }
      try? circuit.mutatorAdd(component)
    }

    func wire(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
      try? circuit.mutatorAdd(
        Wire.create(
          Location.create(x0, y0, hasToSnap: false),
          Location.create(x1, y1, hasToSnap: false)))
    }

    place(AndGate.factory, 200, 120)
    place(OrGate.factory, 200, 220)
    place(NotGate.factory, 320, 120)

    wire(100, 110, 200, 110)
    wire(100, 130, 200, 130)
    wire(100, 210, 200, 210)
    wire(100, 230, 200, 230)
    wire(200, 120, 320, 120)
    wire(320, 120, 400, 120)

    return circuit
  }
}
