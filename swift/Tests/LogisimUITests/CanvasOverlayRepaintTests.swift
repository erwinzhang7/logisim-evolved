// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Board #100: dragging a component smeared it across the canvas.
//
// ── The defect, and why nothing caught it ────────────────────────────────────────────────────
//
// `CircuitSceneView.toolOverlayScene` was a plain stored property. `CircuitCanvasSurface`
// assigns it on **every mouse event of a drag**, and nothing marked the view dirty. Because
// `CircuitSceneView.draw(_:)` clears only `dirtyRect` before redrawing, which is correct and
// cheap, and makes every invalidation load-bearing, the old overlay's pixels were never cleared.
// Dragging a pin left a trail of copies of it across the canvas.
//
// **Every existing canvas test passed against this.** They assert on what the scene CONTAINS,
// primitive counts, ink, hit targets, and the scene was always right. The bug was entirely in
// *when the view was told to repaint*, which nothing looked at. That is the shape worth
// remembering: a renderer can be correct on every frame it draws and still be wrong about which
// frames it draws.
//
// It was found by the owner using the app on a TTL circuit, not by the suite. The UI has no jar
// oracle, so a person looking at pixels is currently the only instrument that sees this class of
// defect. This file exists so that this particular one is no longer in that class.
//
// ── What is asserted, and what is not ────────────────────────────────────────────────────────
//
// ── The observation, which took three attempts to get honest ────────────────────────────────
//
// `NSView.needsDisplay` is NOT usable here. On a detached view the setter is dropped; on an
// offscreen window it does not survive a `display()`. Asserting on it gave, in order: a suite that
// FAILED against the correct fix, then one that PASSED against the broken one. Both readings were
// the instrument. So these assert on `drawCount`: assign an overlay, ask the window to
// `displayIfNeeded()`, and see whether a frame actually happened. That exercises the entire chain
// (`didSet` → `needsDisplay` → AppKit → `draw`) instead of any single link, and it cannot pass
// against a `didSet` that has stopped invalidating.
//
// The assertions are on `CircuitSceneView` directly, because that is where the property lives and
// where the defect was. The path through `CircuitCanvasSurface.setToolOverlay(items:poke:hidden:)`
// is deliberately NOT asserted here: `CircuitCanvasSurface.view` is `private`, and widening it to
// `internal` purely so a test could reach it would be adding production API for a test; the
// exact thing an audit of this repo flags. If that path ever needs gating, the honest move is a
// behavioural assertion, not a visibility change.

import AppKit
import Foundation
import LogisimRender
import LogisimRenderBackend
import Testing

@testable import LogisimUI

@Suite("Board #100 — a moving overlay invalidates the view")
@MainActor
struct CanvasOverlayRepaintTests {

  /// An empty scene is sufficient and is used on purpose. The contract under test is "assigning
  /// the overlay causes a redraw", which is independent of what the overlay contains.
  private func emptyScene() -> RenderScene {
    SceneBuilder(measurer: CoreTextMeasurer()).finish()
  }

  /// A window-backed view, already drawn once so the initial dirty state is drained.
  private func makeView() -> (view: CircuitSceneView, window: NSWindow) {
    let view = CircuitSceneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    view.display()
    return (view, window)
  }

  /// **The calibration, and it must fail if the harness is measuring nothing.** A view that
  /// redraws on every `displayIfNeeded()` regardless of the overlay would make every assertion
  /// below pass against the unfixed code. This asserts the quiet direction: with nothing assigned,
  /// asking to display must NOT produce a frame.
  @Test("with no overlay change, displayIfNeeded draws nothing")
  func theHarnessDiscriminates() {
    let (view, window) = makeView()
    let before = view.drawCount
    view.displayIfNeeded()
    #expect(
      view.drawCount == before,
      """
      the view redrew without being invalidated (\(before) → \(view.drawCount)), so every \
      assertion in this file would pass against a `didSet` that does nothing. The harness is \
      measuring nothing.
      """)
  }

  /// **The defect, as the user saw it.** A drag assigns a new overlay each mouse-move; if that
  /// assignment does not invalidate, the previous frame is never cleared and the component smears.
  @Test("assigning a tool overlay causes a redraw")
  func assigningTheToolOverlayRedraws() {
    let (view, window) = makeView()
    let before = view.drawCount
    view.toolOverlayScene = emptyScene()
    view.displayIfNeeded()
    #expect(
      view.drawCount > before,
      """
      the tool overlay changed and no frame was drawn. `draw(_:)` clears only `dirtyRect`, so the \
      previous overlay stays on screen — this is the drag smear of board #100.
      """)
  }

  /// The second and later frames of a drag, which is where the trail actually accumulated.
  @Test("each successive overlay during a drag redraws again")
  func successiveOverlaysEachRedraw() {
    let (view, window) = makeView()
    view.toolOverlayScene = emptyScene()
    view.displayIfNeeded()

    for frame in 1...3 {
      let before = view.drawCount
      view.toolOverlayScene = emptyScene()
      view.displayIfNeeded()
      #expect(
        view.drawCount > before,
        "drag frame \(frame) drew nothing; the frame before it stays painted")
    }
  }

  /// Clearing the overlay at the end of a gesture has to redraw too, or the ghost of the last
  /// preview frame is left behind after the mouse comes up.
  @Test("clearing the overlay redraws, so the last preview frame is erased")
  func clearingTheOverlayRedraws() {
    let (view, window) = makeView()
    view.toolOverlayScene = emptyScene()
    view.displayIfNeeded()
    let before = view.drawCount
    view.toolOverlayScene = nil
    view.displayIfNeeded()
    #expect(view.drawCount > before, "the overlay was removed but its last frame was never cleared")
  }

  /// The poke highlight is assigned from the same setter and had the identical defect, so it gets
  /// its own assertion rather than being assumed covered by the one above.
  @Test("the poke highlight redraws on the same terms")
  func assigningThePokeOverlayRedraws() {
    let (view, window) = makeView()
    let before = view.drawCount
    view.pokeOverlayScene = emptyScene()
    view.displayIfNeeded()
    #expect(view.drawCount > before, "a moving poke highlight leaves its previous position painted")
  }
}
