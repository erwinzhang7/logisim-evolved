// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// "IT PREVIEWS AS BLACK BUT SOLIDIFIES TO WHITE IN DARK VIEW."
//
// Reported from first real use of the app on a TTL circuit. A wire being dragged is drawn in
// black on a dark canvas and turns near-white the instant it is committed.
//
// The claim these tests make is a sentence about observable output, and it is asserted as one:
//
//     the RGBA the pending-wire primitive resolves to == the RGBA the committed wire
//     primitive resolves to, under the same palette, in BOTH palettes.
//
// Both halves are read out of real `RenderScene`s, `overlayResult.itemScene` for the preview
// and `surface.build.scene` for the committed wire, and resolved through
// `RenderScene.color(of:theme:)` with the same `ValueColorTheme` the canvas passes to the
// backend. Nothing here asserts on an intermediate: the numbers compared are the numbers the
// CoreGraphics renderer is handed.
//
// ── Why the comparison has to be made in BOTH palettes ──────────────────────────────────────
//
// The obvious wrong fix is to hardcode the preview to the dark ink. That passes a dark-only
// test and silently draws a near-white wire on a white canvas. `previewMatchesCommitted` is
// therefore parameterised over both palettes and each case names the palette it ran under, so
// a one-sided fix fails loudly with the palette in the failure message.
//
// ── What these tests are pinned against, and why one of them is about plumbing ───────────────
//
// `ToolOverlaySceneBuilder.build` themes the overlay from the `CanvasAppearance` it is handed,
// and `CircuitSceneSource.build` themes the schematic from the one the *surface* holds. They
// agree only if both are handed the same appearance. `canvasFedTheAppearanceThemesItsOverlay`
// asserts the builder end is correct when it is fed; `appearanceReachesTheEditorCanvas` asserts
// the feeding actually happens on the path the app uses. The second is the one that was broken,
// and separating them is what makes the failure name the defect instead of merely reporting a
// colour mismatch.
//
// ── ⚠ FOUR OF THESE FIVE TESTS ARE RED AS COMMITTED, DELIBERATELY ───────────────────────────
//
// The defect is real and measured, but the two lines that cause it are in files this author did
// not own, so the tests are committed as the gate and the fix is handed over rather than made.
// Measured on this branch: dark preview `#FF000000`, committed wire `#FFE4E4E7`. Light passes,
// which is exactly why nobody saw this until someone opened the app in dark mode.
//
// THE CAUSE, in one sentence: `CanvasHostNSView.pushAppearance()` pushes the resolved palette to
// `delegate.surface` only, and `CircuitEditorCanvas.setAppearance(_:)` has zero callers in
// `Sources`, so `CircuitEditorCanvas.appearance` is permanently the `CanvasAppearance()` default
// : i.e. `CircuitPalette.light`, whose `componentStroke` is `0x000000`.
//
// THE FIX, applied and verified green here (full suite 1387/146 passed, zero regressions), then
// reverted for ownership. Two files, four hunks:
//
//   CircuitCanvasSurface.swift
//     - private var appearance = CanvasAppearance()
//     + private(set) var appearance = CanvasAppearance()
//     + var appearanceDidChange: (() -> Void)?
//     ...at the end of setAppearance(_:):
//     + appearanceDidChange?()
//
//   CircuitEditorCanvas.swift
//     - private var appearance = CanvasAppearance()
//     + private var appearance: CanvasAppearance { surface.appearance }
//     ...in init, after `controller = CanvasToolController(...)`:
//     + surface.appearanceDidChange = { [weak self] in
//     +   guard let self, !self.toolOverlay.items.isEmpty || self.toolOverlay.scene != nil
//     +   else { return }
//     +   self.renderOverlay()
//     + }
//     ...in setAppearance(_:), delete the now-redundant stored write:
//     - appearance = value
//
// Both halves are load-bearing and each has its own gate: dropping `appearanceDidChange?()`
// reddens only `themeFlipMidDragRethemesTheOverlay`; dropping the computed property reddens the
// other four. Measured, not assumed.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// A project, its real render surface, and a `CircuitEditorCanvas` over both: the same three
/// objects `LogisimFileProjectHost.makeRenderSurface()` wires together in the app.
@MainActor
private struct ColourRig {
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas

  init() throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: WiringTool())
  }

  /// Exactly what `CanvasHostNSView.pushAppearance()` does: resolve the palette from the live
  /// `NSAppearance` and hand it to the surface. Reproduced call-for-call rather than
  /// paraphrased, because the defect this file pins is *which object gets the push*.
  func pushAppearanceTheWayTheAppDoes(_ appearance: CanvasAppearance) {
    surface.setAppearance(appearance)
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    let world = CGPoint(x: CGFloat(x), y: CGFloat(y))
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: world,
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }
}

/// The two palettes under test, each with the name that goes in a failure message.
struct WirePreviewPalette: CustomStringConvertible, Sendable {
  let name: String
  let palette: CircuitPalette
  var description: String { name }

  static let light = WirePreviewPalette(name: "light", palette: .light)
  static let dark = WirePreviewPalette(name: "dark", palette: .dark)
  static let both: [WirePreviewPalette] = [.light, .dark]
}

private func appearance(_ palette: CircuitPalette) -> CanvasAppearance {
  var made = CanvasAppearance()
  made.palette = palette
  return made
}

/// The one stroked colour in a scene that is expected to hold exactly one stroked line.
///
/// Deliberately not `primitives[0]`: an off-by-one in the builder would otherwise be read as a
/// colour result. The count is asserted first, so "the scene did not contain what this test
/// thinks it did" fails as itself.
private func soleStrokeColour(
  of scene: RenderScene, theme: ValueColorTheme, _ label: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> LogisimRender.RGBA {
  let lines = scene.primitives.filter { $0.kind == .line && $0.style == .stroke }
  #expect(lines.count == 1, "\(label): expected exactly one stroked line", sourceLocation: sourceLocation)
  let line = try #require(lines.first, sourceLocation: sourceLocation)
  return scene.color(of: line.color, theme: theme)
}

// MARK: - The gate

@Suite("Wire preview colour", .serialized)
struct WirePreviewColourTests {

  // ── 1. The owner's sentence, asserted ─────────────────────────────────────────────────────

  @Test(
    "a pending wire previews in the colour the committed wire will have",
    arguments: WirePreviewPalette.both)
  @MainActor
  func previewMatchesCommitted(_ scenario: WirePreviewPalette) throws {
    let rig = try ColourRig()
    rig.pushAppearanceTheWayTheAppDoes(appearance(scenario.palette))
    let theme = CircuitSceneSource.theme(for: scenario.palette)

    // Mid-drag: the preview.
    rig.pointer(.down, 100, 100)
    rig.pointer(.dragged, 160, 100)
    let preview = try soleStrokeColour(
      of: rig.canvas.overlayResult.itemScene, theme: theme, "\(scenario.name) preview")

    // Released: the committed wire, out of the scene the canvas actually paints.
    rig.pointer(.up, 160, 100)
    #expect(rig.circuit.wires.count == 1, "\(scenario.name): the drag must have committed a wire")
    let committed = try soleStrokeColour(
      of: rig.surface.build.scene, theme: theme, "\(scenario.name) committed")

    #expect(
      preview == committed,
      """
      \(scenario.name): the pending wire previews \(preview) but commits to \(committed). \
      A wire must not change colour when the mouse is released.
      """)
  }

  // ── 2. Which end is broken ────────────────────────────────────────────────────────────────

  @Test(
    "the overlay builder themes the preview correctly when it is handed the appearance",
    arguments: WirePreviewPalette.both)
  @MainActor
  func canvasFedTheAppearanceThemesItsOverlay(_ scenario: WirePreviewPalette) throws {
    let rig = try ColourRig()
    // `CircuitEditorCanvas.setAppearance`; the method that exists for exactly this and that
    // nothing in the app calls. Feeding it by hand isolates the builder from the plumbing.
    rig.canvas.setAppearance(appearance(scenario.palette))
    let theme = CircuitSceneSource.theme(for: scenario.palette)

    rig.pointer(.down, 100, 100)
    rig.pointer(.dragged, 160, 100)
    let preview = try soleStrokeColour(
      of: rig.canvas.overlayResult.itemScene, theme: theme, "\(scenario.name) preview")

    rig.pointer(.up, 160, 100)
    let committed = try soleStrokeColour(
      of: rig.surface.build.scene, theme: theme, "\(scenario.name) committed")

    #expect(
      preview == committed,
      "\(scenario.name): builder fed the palette directly still mismatched: \(preview) vs \(committed)")
  }

  @Test("the appearance the app pushes reaches the editor canvas, not just the surface")
  @MainActor
  func appearanceReachesTheEditorCanvas() throws {
    let rig = try ColourRig()
    rig.pushAppearanceTheWayTheAppDoes(appearance(.dark))

    // Nothing observable on `CircuitEditorCanvas` exposes its palette directly, so the question
    // is asked the way a user asks it: draw something and look at the colour. A cursor dot is
    // the cheapest overlay item there is: one `fillOval`, themed from the canvas's palette.
    rig.pointer(.moved, 100, 100)
    let dots = rig.canvas.overlayResult.itemScene.primitives.filter { $0.kind == .oval }
    let dot = try #require(dots.first, "the wiring tool draws a cursor dot on hover")
    let colour = rig.canvas.overlayResult.itemScene.color(
      of: dot.color, theme: CircuitSceneSource.theme(for: .dark))

    // The dot is `componentStroke` at 45% alpha. On a dark canvas that is a light neutral; the
    // assertion is only that it is not the LIGHT palette's near-black, which is what a canvas
    // still holding `CanvasAppearance()` produces.
    let lightInk = CircuitPalette.light[.componentStroke].sceneRGBA
    #expect(
      !(colour.r == lightInk.r && colour.g == lightInk.g && colour.b == lightInk.b),
      """
      the overlay drew in the LIGHT palette's ink (\(colour)) after the app pushed a DARK \
      appearance — the push reached CircuitCanvasSurface but not CircuitEditorCanvas.
      """)
  }

  /// The push has to *re-theme what is already on screen*, not merely be read by the next build.
  ///
  /// Written because the obvious half-fix, letting the canvas read the surface's appearance,
  /// passes every other test in this file: they all move the pointer after pushing, and a
  /// pointer move rebuilds the overlay anyway. Switching the system theme mid-drag moves no
  /// pointer, so nothing rebuilds and the pending wire keeps the colour it was born with. This
  /// is the only case that distinguishes "the canvas can see the palette" from "the canvas is
  /// told when the palette changes".
  @Test("a theme flip mid-drag re-themes the pending wire without a mouse move")
  @MainActor
  func themeFlipMidDragRethemesTheOverlay() throws {
    let rig = try ColourRig()
    rig.pushAppearanceTheWayTheAppDoes(appearance(.light))

    rig.pointer(.down, 100, 100)
    rig.pointer(.dragged, 160, 100)
    let before = try soleStrokeColour(
      of: rig.canvas.overlayResult.itemScene,
      theme: CircuitSceneSource.theme(for: .light), "light preview")
    #expect(before == CircuitPalette.light[.componentStroke].sceneRGBA)

    // The system theme flips. No pointer event follows; the user's hand has not moved.
    rig.pushAppearanceTheWayTheAppDoes(appearance(.dark))

    let after = try soleStrokeColour(
      of: rig.canvas.overlayResult.itemScene,
      theme: CircuitSceneSource.theme(for: .dark), "dark preview")
    #expect(
      after == CircuitPalette.dark[.componentStroke].sceneRGBA,
      """
      after the theme flipped to dark the pending wire is still \(after); the overlay scene was \
      not rebuilt, so it kept the ink baked into it under the light palette.
      """)
  }

  // ── 3. The same plumbing feeds AddTool's placement ghost ──────────────────────────────────

  /// The wire preview is the case the owner hit, but nothing about the fault is wire-specific:
  /// every `ToolOverlayItem` is themed from the same `CanvasAppearance`. `AddTool`'s placement
  /// ghost is the item a user meets first, it is what a component looks like while it is being
  /// dropped, so it is pinned here too, or a fix aimed only at `.pendingWire` would look
  /// complete and leave every ghost drawn in the wrong palette.
  @Test(
    "a placement ghost previews in the palette the canvas is actually showing",
    arguments: WirePreviewPalette.both)
  @MainActor
  func placementGhostFollowsThePalette(_ scenario: WirePreviewPalette) throws {
    let rig = try ColourRig()
    rig.pushAppearanceTheWayTheAppDoes(appearance(scenario.palette))
    rig.canvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))

    rig.pointer(.moved, 120, 120)
    let scene = rig.canvas.overlayResult.itemScene
    #expect(!scene.primitives.isEmpty, "\(scenario.name): the add tool must draw a ghost on hover")
    let theme = CircuitSceneSource.theme(for: scenario.palette)

    // The expected colour is the palette's `componentStroke` at FULL opacity, which looks wrong
    // next to `ToolOverlaySceneBuilder`'s 55%-alpha `ghostInk` until you follow the paint:
    // `ghostInk` is set on the builder and then *overwritten*, because `AbstractGate.paintBase`
    // opens with `let baseColor = painter.componentColor` and sets it. So a gate ghost is drawn
    // in the paint context's colour, `CircuitSceneSource.paintContext(for:)`'s
    // `.rgba(appearance.palette[.componentStroke])`, and never in `ghostInk` at all.
    //
    // That is faithful, not a port bug: 4.1.0's `AbstractGate.paintBase` likewise builds
    // `new Color(AppPreferences.COMPONENT_COLOR.get())` and `setColor`s it over the ghost colour
    // `InstanceFactory.drawGhost` had just installed (verified with `javap -c` on
    // logisim-evolution-4.1.0-all.jar).
    //
    // It is recorded here because this test would otherwise look like it is checking `ghostInk`
    // and quietly keep passing if `ghostInk` were broken. It checks the *other* consumer of the
    // canvas's stale appearance, which is the second reason this file exists.
    //
    // Every primitive is asserted, not just the first: a multi-primitive ghost with one stale
    // colour is the shape a partial fix produces.
    let expected = scenario.palette[.componentStroke].sceneRGBA
    for primitive in scene.primitives {
      let colour = scene.color(of: primitive.color, theme: theme)
      #expect(
        colour.r == expected.r && colour.g == expected.g && colour.b == expected.b,
        """
        \(scenario.name): a placement-ghost primitive drew \(colour), but the canvas is showing \
        the \(scenario.name) palette whose componentStroke is \(expected).
        """)
    }
  }
}
