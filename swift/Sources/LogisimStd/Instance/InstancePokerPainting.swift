// InstancePokerPainting.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePokerAdapter and the
// `poker.paint` / `poker.getBounds` half of com.cburch.logisim.tools.PokeTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ SEAM #15, AND WHY IT NEEDED THREE PIECES RATHER THAN ONE ════════════════════════════════
//
// `Instance/InstancePoker.swift` used to end with:
//
//     // Java's `getBounds` (lines 17–19) and `paint` (line 37) are intentionally omitted: both
//     // take `InstancePainter`, which has not yet been ported.
//
// `InstancePainter` has since landed, so that comment stopped being a decision and became
// camouflage over an unwired seam. Adding the two protocol members back is necessary and, on its
// own, changes nothing observable, which is exactly how this defect class has survived eleven
// times. Three separate joins were missing, and all three are here or next door:
//
//   1. **The requirements.** `InstancePoker.pokeBounds(_:)` / `paint(_:)`, with Java's defaults
//      (`painter.getInstance().getBounds()` and an empty body). In `InstancePoker.swift`.
//
//   2. **Witness selection.** `RegisterPoker`, `CounterPoker` and `ShiftRegisterPoker` already
//      had a fully ported `paint(_ painter: any MemPainter)`, and `Joystick.Poker` a
//      `paint(_ painter: any IoInstancePainter)`. Swift matches a protocol witness on the
//      argument's **static** type and does not apply contravariance, so `InstancePainter`
//      conforming to `MemPainter` does NOT make `paint(any MemPainter)` satisfy
//      `paint(InstancePainter)`; every one of those four would have silently inherited the
//      empty default. `MemPokerPaintable` / `IoPokerPaintable` below forward, exactly as
//      `MemPaintable`/`IoPaintable` do for `paintInstance`. This is the piece a build cannot
//      warn about.
//
//   3. **Reachability.** `InstanceFactoryBase.instanceFeature(_:_:)` answered `nil` for every
//      key, so `Component.feature(.pokable)` was `nil` for every stock component in the app and
//      `PokeTool` could never build a caret at all. Upstream's `InstanceFactory
//      .getInstanceFeature` answers `Pokable.class` with an adapter around the factory's poker
//      class (`InstanceFactory.java:218-226`); `makePoker()` is this port's witness-based
//      replacement for `setInstancePoker(Class<?>)` and was declared, overridden by fourteen
//      factories, and **never called from anywhere**. Fixed in `InstanceFactory.swift`.
//
// ── The one hop this file cannot make ───────────────────────────────────────────────────────
//
// Upstream's per-frame path is `Canvas.paintComponent` → `CanvasPainter.drawWithUserState` →
// `tool.draw(canvas, context)` → `PokeTool.draw` → `pokeCaret.draw(g)` →
// `InstancePokerAdapter.draw` → `poker.paint(new InstancePainter(context, comp))`. In this port
// the last three links live in `LogisimUI/Tools/` (`PokeTool.overlay(for:)` →
// `Caret.overlayItems` → `InstancePokerCaret`), which this slice does not own. `PokeOverlayRenderer`
// below is the whole of `InstancePokerAdapter.draw`/`getBounds`, callable in one line from there:
//
//     // InstancePokerCaret, which must also start holding the poked `component`
//     @discardableResult
//     public func drawHighlight(into builder: SceneBuilder, context: any PaintContext) -> Bool {
//       PokeOverlayRenderer.render(poker: poker, component: component, into: builder,
//                                  context: context)
//     }
//
// Two things about that hop are worth stating rather than discovering. First, `Caret.bounds` is
// currently a snapshot of `component.bounds` taken at construction; upstream recomputes it from
// `poker.getBounds(painter)` on every `PokeTool.mousePressed`, and `MemPoker`'s two sub-pokers
// derive it from the cell being edited, which moves as the user types, so it has to become a
// call to `PokeOverlayRenderer.highlightBounds`, not a stored value. Second, the highlight cannot
// travel as a `ToolOverlayItem`: that enum is closed and `Hashable` by design, and a poker emits
// arbitrary component-authored geometry, so `ToolOverlay` needs a `RenderScene?` alongside its
// items. Both are written out in full in the slice report.
//
// ── D6 ──────────────────────────────────────────────────────────────────────────────────────
//
// The overlay is emitted into a `SceneBuilder`, not a `CGContext`, and deliberately into a
// **separate** builder from the circuit scene: the circuit scene is rebuilt only when
// `CircuitSceneGeometryKey` changes, whereas a poke highlight moves on every keystroke.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - Witness forwarding for the memory pokers

/// A poker whose highlight is drawn against the memory family's narrowed painter surface.
///
/// **The forward is the whole point, not sugar.** `RegisterPoker.paint(_:)` takes
/// `any MemPainter`; the protocol requirement takes the concrete `InstancePainter`. Swift will
/// not accept the former as a witness for the latter even though `InstancePainter: MemPainter`,
/// because witness matching is on the static parameter type. Without this shim all three memory
/// pokers compile, conform, and draw nothing; the exact failure `MemPaintable` was written to
/// prevent for `paintInstance`.
public protocol MemPokerPaintable: InstancePoker {
  /// `paint(InstancePainter)`, against this family's painter surface.
  func paint(_ painter: any MemPainter)
}

extension MemPokerPaintable {
  /// `InstancePoker.paint` → the memory overload.
  ///
  /// The `as any MemPainter` is what makes this a forward rather than infinite recursion: the
  /// existential and the concrete class are distinct static types and neither converts
  /// implicitly, so this can only resolve to the protocol requirement above. Because there is no
  /// default for that requirement, a conformer that forgets to write one fails to compile
  /// instead of quietly drawing nothing.
  public func paint(_ painter: InstancePainter) {
    paint(painter as any MemPainter)
  }
}

/// The io counterpart. Only `Joystick.Poker` needs it in 4.1.0 (`Joystick.java:66`); the other
/// nine io pokers override no `paint` upstream either, so they take the empty default.
public protocol IoPokerPaintable: InstancePoker {
  func paint(_ painter: any IoInstancePainter)
}

extension IoPokerPaintable {
  public func paint(_ painter: InstancePainter) {
    paint(painter as any IoInstancePainter)
  }
}

// MARK: - The conformers

// Retroactive conformances rather than edits to `Memory/` and `Io/`, so the whole seam,
// requirement, forward, conformer list and driver, reads in one place, and so a poker that stops
// satisfying it fails here rather than 200 lines into its own file. Same choice `MemPainter.swift`
// and `IoPainter.swift` made when they closed seams #10 and #9.
//
// `RegisterPoker.paint` is `open` and `CounterPoker` overrides it, so the witness is
// vtable-dispatched and the subclass's narrower caret is what actually draws: verified by
// `PokeHighlightSeamTests.counterOverridesRegistersCaret`, which compares the two rectangles.

extension RegisterPoker: MemPokerPaintable {}
extension ShiftRegisterPoker: MemPokerPaintable {}
extension Joystick.Poker: IoPokerPaintable {}

// NOT wired, and stated rather than hidden; the shape of comment this seam was found under:
//
//   * `MemPoker` (`Memory/MemPoker.swift`) has a ported `paint(_:)` and `highlightBounds(_:)`
//     but is **not** an `InstancePoker`: its key handlers take `MemPokerNavigationKey` and
//     `(Character, control: Bool)` rather than `PokeKeyEvent`, and `PokeKeyEvent` carries no
//     control-modifier flag at all, so half of `AddrPoker`/`DataPoker`'s navigation cannot be
//     expressed yet. `Mem` also declares no `makePoker()`. Three changes, two of them in files
//     this slice does not own; written out in the slice report.
//   * `Keyboard.Poker.draw(_:)` stays unwired **because upstream's is dead too**:
//     `Keyboard.java:45` declares `public void draw(InstancePainter)` with no `@Override`, the
//     hook is called `paint`, not `draw`, and nothing in 4.1.0 calls it. Wiring it would be a
//     behavioural change, not a port.
//   * `Pin.PinPoker` and `SubcircuitPoker` both override `paint` upstream and neither is ported
//     yet (`Wiring/Pin.swift:113` and the subcircuit slice).

// MARK: - PokeOverlayRenderer

/// Drives a live poke's highlight into a scene: `InstancePokerAdapter.draw(Graphics)` and
/// `InstancePokerAdapter.getBounds(Graphics)`, which are the only two things that ever call
/// `InstancePoker.paint` / `getBounds` upstream.
///
/// A free function rather than a method on the poker so that the *ghost guard* has one home. A
/// poke painter always has a component upstream, `InstancePokerAdapter` is constructed from an
/// `InstanceComponent` and holds it for its whole life, and the ported highlights rely on that:
/// `MemPoker.paint` reads `painter.data`, `ShiftRegisterPoker.paint` and `RegisterPoker.paint`
/// read `painter.bounds`, and a factory-backed painter has no data and empty bounds. Forwarding a
/// ghost into them would draw a live-state caret for a component with no state, which is the
/// mistake `MemPaintable` explicitly refuses to make for `paintGhost`.
public enum PokeOverlayRenderer {

  /// Group tag for the poke-highlight layer.
  ///
  /// `CircuitRenderer` gives components `1...n` and the wire layer `UInt64.max`; this takes the
  /// next value down so that an overlay emitted into the *same* builder as a circuit, which is
  /// not how the canvas is expected to use it, but is how a test can measure both at once,
  /// stays distinguishable from every component index.
  public static let pokeGroupTag = UInt64.max - 1

  /// `InstancePokerAdapter.draw(Graphics)`.
  ///
  /// Returns whether the poker was actually asked to paint, so a caller can tell "drew nothing"
  /// from "was never reached"; the distinction this whole seam turns on. `false` means the
  /// painter had no component and the paint was refused; it never means the highlight was empty.
  @discardableResult
  public static func render(
    poker: any InstancePoker,
    component: any Component,
    into builder: SceneBuilder,
    context: any PaintContext
  ) -> Bool {
    let painter = InstancePainter(g: builder, context: context, component: component)
    return render(poker: poker, with: painter, into: builder)
  }

  /// The same, for a caller that already holds the painter (upstream's adapter keeps one
  /// `ComponentDrawContext` alive across the whole poke and only swaps its `Graphics`).
  @discardableResult
  public static func render(
    poker: any InstancePoker,
    with painter: InstancePainter,
    into builder: SceneBuilder
  ) -> Bool {
    guard !painter.isGhost else { return false }
    builder.beginGroup(tag: pokeGroupTag, opacity: 1.0)
    defer { builder.endGroup() }
    poker.paint(painter)
    return true
  }

  /// `InstancePokerAdapter.getBounds(Graphics)`: the caret's hit region, which `PokeTool`
  /// tests the next click against before deciding to end the poke.
  ///
  /// Upstream returns `Bounds.EMPTY_BOUNDS` when there is no poker (`InstancePokerAdapter.java:69`);
  /// the same answer is given for a component-less painter, since an empty rectangle contains no
  /// point and so ends the poke, which is the safe direction.
  public static func highlightBounds(
    poker: any InstancePoker,
    component: any Component,
    scratch builder: SceneBuilder,
    context: any PaintContext
  ) -> Bounds {
    let painter = InstancePainter(g: builder, context: context, component: component)
    guard !painter.isGhost else { return .empty }
    return poker.pokeBounds(painter)
  }
}
