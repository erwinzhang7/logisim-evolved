// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN THE USER ACTUALLY SELECT THE TOOLS THEY EDIT WITH?
//
// Measured over a real host before this was fixed: of the 162 tools the explorer offers,
// `CanvasToolController.upgrade` could drive 157. The five it could not were exactly
//
//     Edit Tool · Menu Tool · Poke Tool · Wiring Tool · Text Tool
//
// Selecting any of them called `setActiveTool(fromLibrary:)`, got `nil`, and **silently left the
// previous tool active**. Placing components worked; selecting, poking, wiring and labelling did
// not, and nothing reported it; a returned `false` that every call site discarded.
//
// `Text Tool` is the sharpest case: there are TWO `TextTool` types, `LogisimFile`'s plain `Tool`
// and `LogisimUI`'s real `CanvasTool`. Different modules, so neither the compiler nor
// `tools/mergecheck.py` (which reports collisions only WITHIN a module, deliberately) says a
// word, and the explorer registers the inert one.
//
// ── WHAT THESE ASSERT, AND WHY NOT THE OBVIOUS THING ─────────────────────────────────────────
//
// Not "does `baseTools` contain the id"; that passes against a table wired to nothing. Each test
// selects a tool through the same call the shell makes and then asserts the controller's
// `activeTool` is an instance of the real class. The count test additionally walks EVERY tool the
// explorer publishes, so a future library whose tools cannot be driven shows up as a number
// moving rather than as a tool that quietly does nothing.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Base tool reachability", .serialized)
struct BaseToolReachabilityTests {

  /// Returns the canvas as well, and every caller must HOLD it.
  ///
  /// `CanvasToolController.canvas` is `unowned`; the canvas owns the controller, so the back
  /// edge must not retain (D3). An earlier version of this helper returned only the controller
  /// and the canvas died at the end of the call: `Fatal error: Attempted to read an unowned
  /// reference but object 0x… was already destroyed`, which kills the whole test process on
  /// signal 6 rather than failing one test. Worth keeping in mind; it is the same class of
  /// silent-total-failure as the `assumeIsolated` crashes, and the ownership it enforces is real.
  @MainActor
  private func makeStack() throws
    -> (LogisimFileProjectHost, CircuitEditorCanvas, CanvasToolController)
  {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: host.currentCircuitObject,
      initialTool: SelectTool())
    return (host, canvas, canvas.controller)
  }

  @Test("every base editing tool the explorer publishes becomes the active tool")
  @MainActor
  func baseToolsBecomeActive() throws {
    let (host, canvas, controller) = try makeStack()
    defer { _ = canvas }

    // id -> the class the controller must end up on. **`Menu Tool` is now here**: it was the last
    // pinned gap in this suite, asserted below as the sole undrivable tool. `MenuTool` exists,
    // so the gap is retired rather than left as a comment that outlived its subject. Note it is
    // still the tool nobody selects, the default template binds it to Button3, but a `.circ`
    // that names it in `<mappings>` or `<toolbar>` has to resolve to something drivable, and
    // `MenuToolTests` is where its behaviour is pinned.
    let expected: [(String, Any.Type)] = [
      (BaseToolIds.edit, EditTool.self),
      (BaseToolIds.poke, PokeTool.self),
      (BaseToolIds.wiring, WiringTool.self),
      (BaseToolIds.menu, MenuTool.self),
      // MODULE-QUALIFIED, and the reason is the finding itself: written as a bare `TextTool.self`
      // this line resolved to `LogisimFile.TextTool` -- the inert one -- and the assertion failed
      // with the gloriously unhelpful `(TextTool) == (TextTool)`. The ambiguity this test exists
      // to pin caught the test while it was being written.
      (BaseToolIds.textTool, LogisimUI.TextTool.self),
    ]

    for (id, type) in expected {
      let tool = try #require(
        host.handles.tools.values.first { $0.name == id },
        "the explorer does not publish a tool named \(id)")

      // Start somewhere else every time, so "it was already active" cannot pass this.
      controller.setActiveTool(SelectTool())
      let accepted = controller.setActiveTool(fromLibrary: tool)

      #expect(accepted, "setActiveTool(fromLibrary:) refused \(id)")
      #expect(
        Swift.type(of: controller.activeTool) == type,
        "\(id) left the controller on \(Swift.type(of: controller.activeTool)), not \(type)")
    }
  }

  @Test("selecting a base tool twice keeps the same instance, so gesture state survives")
  @MainActor
  func baseToolsAreStable() throws {
    let (host, canvas, controller) = try makeStack()
    defer { _ = canvas }
    let wiring = try #require(host.handles.tools.values.first { $0.name == BaseToolIds.wiring })

    controller.setActiveTool(fromLibrary: wiring)
    let first = controller.activeTool
    controller.setActiveTool(SelectTool())
    controller.setActiveTool(fromLibrary: wiring)

    // Identity, not type. A table that rebuilt the tool on every lookup would satisfy the test
    // above and throw away a half-drawn wire every time the user switched away and back.
    #expect(first === controller.activeTool)
  }

  @Test("EditTool is wired to the same Select and Wiring instances the controller hands out")
  @MainActor
  func editToolSharesItsSubTools() throws {
    let (host, canvas, controller) = try makeStack()
    defer { _ = canvas }

    controller.setActiveTool(fromLibrary:
      try #require(host.handles.tools.values.first { $0.name == BaseToolIds.wiring }))
    let wiring = try #require(controller.activeTool as? WiringTool)

    controller.setActiveTool(fromLibrary:
      try #require(host.handles.tools.values.first { $0.name == BaseToolIds.edit }))
    let edit = try #require(controller.activeTool as? EditTool)

    // Upstream's EditTool delegates to the *same* SelectTool and WiringTool the toolbar selects
    // (`EditTool.java` holds them as fields). Two separate instances compile and behave almost
    // right, diverging only when a gesture starts under one and continues under the other.
    #expect(edit.wiringTool === wiring)
  }

  @Test("the explorer publishes nothing else the controller cannot drive")
  @MainActor
  func coverageIsComplete() throws {
    let (host, canvas, controller) = try makeStack()
    defer { _ = canvas }

    var undrivable: [String] = []
    for tool in host.handles.tools.values {
      controller.setActiveTool(SelectTool())
      if !controller.setActiveTool(fromLibrary: tool) {
        undrivable.append("\(Swift.type(of: tool)):\(tool.name)")
      }
    }

    // **The gap is closed.** Was 5 before the base-tool table existed, then 1 (`Menu Tool`,
    // unported), now 0. Kept as an exact-empty assertion rather than deleted, because the value
    // of this test was never the number; it is that a library added later whose tools cannot be
    // driven shows up here instead of quietly doing nothing when clicked.
    #expect(
      undrivable.sorted() == [],
      "undrivable tools changed: \(undrivable.sorted())")
  }
}
