// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE RENDERER SEAM.
//
// This file is the whole contract between the app shell and whoever implements the
// canvas renderer in `LogisimRender`. The shell does not know what a RenderScene is,
// does not know how components draw, and never touches a CGContext. The renderer, in
// return, does not own the camera, does not own gesture handling, does not own
// hit-testing policy, and does not own the colour palette; it is handed a viewport and
// an appearance and asked to draw.
//
// That division is deliberate and is the fix for issue #1262: in upstream, zoom and pan
// are entangled with the painting component's preferred size (`Canvas.computeSize`), so
// every camera change is also a layout change. Here the camera lives in `CanvasViewport`,
// owned by the shell, and the renderer's view never resizes.
// ============================================================================

import AppKit
import CoreGraphics
import Foundation

// MARK: - Appearance

/// Everything the renderer needs that is *not* geometry. Pushed on every appearance change
/// (issue #2661) and on every preference change; never read out of a global.
public struct CanvasAppearance: Sendable, Equatable {
  public var palette: CircuitPalette
  public var showGrid: Bool
  /// World units between grid marks. Logisim's grid is 10.
  public var gridSpacing: Double
  public var antialiasing: Bool
  /// `NSWindow.backingScaleFactor`. Pushed rather than read so an offscreen render for
  /// Export Image / Print can ask for a different one.
  public var backingScale: Double
  /// Draw wires and pins tinted by their simulated value. Off while the simulator is
  /// stopped so a static schematic reads cleanly.
  public var showsValueColours: Bool
  /// Upstream's `AppPreferences.GATE_SHAPE`.
  public var gateShape: GateShape
  public var showsTickMarkers: Bool
  public var showsAttentionHalo: Bool

  public enum GateShape: String, Sendable, CaseIterable, Codable {
    case shaped
    case rectangular
    case din40700
  }

  public init(
    palette: CircuitPalette = .light,
    showGrid: Bool = true,
    gridSpacing: Double = 10,
    antialiasing: Bool = true,
    backingScale: Double = 2,
    showsValueColours: Bool = true,
    gateShape: GateShape = .shaped,
    showsTickMarkers: Bool = false,
    showsAttentionHalo: Bool = true
  ) {
    self.palette = palette
    self.showGrid = showGrid
    self.gridSpacing = gridSpacing
    self.antialiasing = antialiasing
    self.backingScale = backingScale
    self.showsValueColours = showsValueColours
    self.gateShape = gateShape
    self.showsTickMarkers = showsTickMarkers
    self.showsAttentionHalo = showsAttentionHalo
  }
}

// MARK: - Hit targets

/// What the renderer reports under a world point. The shell uses it for hover feedback,
/// for the context menu, and to decide whether a drag starts a marquee or a move: but the
/// shell never interprets `kind` semantically beyond choosing menu items.
public struct CanvasHitTarget: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case component
    case subcircuit
    case wire
    case wireJunction
    case pin
    case label
    /// D8: a component from a library we could not resolve. It exists, it round-trips, and
    /// it must be visible and selectable rather than silently gone.
    case unresolvedPlaceholder
  }

  public var id: ComponentID
  public var kind: Kind
  public var displayName: String
  /// World-space bounds, used to scroll-to-reveal and to size the halo.
  public var bounds: CGRect

  public init(id: ComponentID, kind: Kind, displayName: String, bounds: CGRect) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.bounds = bounds
  }
}

// MARK: - Input

public struct CanvasModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = CanvasModifiers(rawValue: 1 << 0)
  public static let control = CanvasModifiers(rawValue: 1 << 1)
  public static let option = CanvasModifiers(rawValue: 1 << 2)
  public static let command = CanvasModifiers(rawValue: 1 << 3)

  public init(_ flags: NSEvent.ModifierFlags) {
    var set = CanvasModifiers()
    if flags.contains(.shift) { set.insert(.shift) }
    if flags.contains(.control) { set.insert(.control) }
    if flags.contains(.option) { set.insert(.option) }
    if flags.contains(.command) { set.insert(.command) }
    self = set
  }
}

/// A pointer event already converted to world coordinates. Tools never see view pixels,
/// which removes the whole class of zoom-dependent tool bugs upstream has (`Canvas.zoomEvent`
/// mutates the `MouseEvent` in place and every tool has to remember that it happened).
public struct CanvasPointerEvent: Sendable {
  public enum Phase: Sendable, Hashable {
    case moved
    case down
    case dragged
    case up
    case entered
    case exited
  }

  public var phase: Phase
  /// The raw world point, unsnapped and unrounded.
  ///
  /// There is deliberately no `snappedWorld` beside it. One used to exist: the shell computed
  /// `(v / gridSpacing).rounded() * gridSpacing` and put the result here on every event. Nothing
  /// ever read it: the tools snap for themselves in `ToolGeometry.CanvasGrid`, with upstream's
  /// exact integer arithmetic, because the snapped value is a *model* coordinate that gets
  /// written into the saved file and cannot be the shell's to decide.
  ///
  /// Its rule was also wrong: rounding the continuous world value puts the 0 -> 10 threshold at
  /// 5.0, where 4.1.0 integerises first (`Canvas.zoomEvent`, `(int) Math.round(px / zoom)`) and
  /// thresholds at 4.5. Carrying a second, subtly different snap next to the real one is exactly
  /// the invitation a future reader should not be given, so the field is gone rather than fixed.
  public var world: CGPoint
  public var modifiers: CanvasModifiers
  public var clickCount: Int
  public var buttonNumber: Int
  /// Present for `.up`/`.dragged`, so a tool can compute a total displacement without
  /// keeping its own state.
  public var dragOriginWorld: CGPoint?

  public init(
    phase: Phase,
    world: CGPoint,
    modifiers: CanvasModifiers,
    clickCount: Int,
    buttonNumber: Int,
    dragOriginWorld: CGPoint?
  ) {
    self.phase = phase
    self.world = world
    self.modifiers = modifiers
    self.clickCount = clickCount
    self.buttonNumber = buttonNumber
    self.dragOriginWorld = dragOriginWorld
  }
}

public struct CanvasKeyEvent: Sendable {
  public enum Phase: Sendable { case down, up }
  public var phase: Phase
  public var characters: String
  public var keyCode: UInt16
  public var modifiers: CanvasModifiers
  public var isRepeat: Bool

  public init(
    phase: Phase, characters: String, keyCode: UInt16, modifiers: CanvasModifiers,
    isRepeat: Bool
  ) {
    self.phase = phase
    self.characters = characters
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isRepeat = isRepeat
  }
}

// MARK: - The render surface

/// Implemented in `LogisimRender`. One instance per open circuit editor.
///
/// Threading: `@MainActor`, like every other view-layer type here. D1 keeps the *kernel*
/// off Swift Concurrency; that does not mean the view layer should be.
@MainActor
public protocol CircuitRenderSurface: AnyObject {
  /// The layer-backed view that actually draws. The shell embeds this and puts its own
  /// gesture recognisers and tracking area on a container *above* it, so the renderer never
  /// has to implement `mouseDown`.
  var renderView: NSView { get }

  /// World-space bounds of everything in the circuit, for zoom-to-fit. `.null` when empty.
  var contentBounds: CGRect { get }

  /// Camera changed. Must not resize `renderView`.
  func setViewport(_ viewport: CanvasViewport)

  /// Palette / grid / gate-shape changed. Must repaint everything.
  func setAppearance(_ appearance: CanvasAppearance)

  /// Selection changed; the renderer draws the selection adornment, since it knows the
  /// exact geometry. `haloed` is upstream's "attention" halo (`Frame.setAttrTableModel`).
  func setSelection(_ ids: Set<ComponentID>, haloed: ComponentID?)

  /// A rubber-band rectangle in world coordinates, or nil.
  func setMarquee(_ worldRect: CGRect?)

  /// Invalidate. `worldRect == nil` means everything.
  ///
  /// **Upstream issue #786 (GUI redraw).** Upstream funnels every repaint through
  /// `CanvasPaintCoordinator`, which hard-caps redraws at ~20/s using a rotating table of
  /// magic 47–53 ms delays chosen to avoid resonating with the tick frequency
  /// (`CanvasPaintCoordinator.java:37-39`). That cap exists because a frame costs
  /// O(all components): no culling, two `Graphics2D` clones per component. It is why the
  /// UI looks like it is dropping frames, and why a redraw can be missed entirely when a
  /// request lands while `cleaning` is true and the follow-up timer is coalesced away.
  ///
  /// Here there is no coalescing timer and no cap. Invalidation is a rectangle; the
  /// renderer culls to `viewport.visibleWorldRect` and the window server drives repaint at
  /// display refresh. The simulator does not call this at all; it publishes committed
  /// state and the surface samples it (D7: simulation time is decoupled from render time).
  func invalidate(worldRect: CGRect?)

  /// Topmost drawable at a world point, honouring `tolerance` in world units so thin wires
  /// are still clickable at low zoom.
  func hitTest(worldPoint: CGPoint, tolerance: Double) -> CanvasHitTarget?

  /// Everything intersecting a world rectangle, marquee selection.
  func hitTest(worldRect: CGRect) -> [CanvasHitTarget]

  /// Render off-screen at an explicit scale, for File ▸ Export Image and for Print.
  /// (`ExportImage.java`, `Print.java`.) Returning nil means "not supported yet".
  func snapshotImage(worldRect: CGRect, scale: Double, appearance: CanvasAppearance)
    -> CGImage?
}

/// How the shell obtains a surface. A closure rather than a protocol so the renderer team
/// can hand back a value type or a factory method with equal ease.
public typealias CircuitRenderSurfaceProvider = @MainActor () -> CircuitRenderSurface

/// What the shell sends *back* into the editing layer. Implemented by whatever owns tools
/// and selection (the project layer), not by the renderer.
@MainActor
public protocol CanvasInteractionHandler: AnyObject {
  func canvasHandlePointer(_ event: CanvasPointerEvent)
  /// Return true if consumed; false lets the shell fall through to its own key handling.
  func canvasHandleKey(_ event: CanvasKeyEvent) -> Bool
  /// A tool was dropped from the explorer sidebar.
  func canvasDropTool(_ tool: ToolID, atWorldPoint point: CGPoint)
  /// The cursor the shell should show for the active tool at this point.
  func canvasCursor(atWorldPoint point: CGPoint) -> NSCursor

  /// The contextual menu for a right-click at this world point, or `nil` for none.
  ///
  /// This is upstream's `MenuTool`, which is not a tool anyone selects: the default project
  /// template binds it to `Button3` and `Ctrl Button1`, and `Canvas.MyListener.mousePressed`
  /// resolves the button through `MouseMappings` before dispatching. So the gesture belongs to
  /// the editing layer even though AppKit asks the *view* for it, and this is the crossing.
  ///
  /// **`nil` is meaningfully different from an empty menu.** Measured against 4.1.0: a
  /// right-click on bare canvas shows nothing at all, not an empty panel.
  func canvasContextMenu(atWorldPoint point: CGPoint) -> NSMenu?
}

extension CanvasInteractionHandler {
  /// Defaulted so a handler that predates the menu, every test double, and the CLI, keeps
  /// compiling and simply offers no menu.
  public func canvasContextMenu(atWorldPoint point: CGPoint) -> NSMenu? { nil }
}
