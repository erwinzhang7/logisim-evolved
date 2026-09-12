// PokeTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.PokeTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.tools.PokeTool`; the tool that drives a component's own input handling.
///
/// It owns at most one caret at a time and routes every subsequent event to it until the user
/// clicks outside its bounds. The one thing worth understanding before reading the code is that
/// **poking is not editing**: nothing here produces a `CircuitMutation` or an undoable action.
/// A poke changes simulation state, not the netlist, so a poked circuit saves identically to an
/// unpoked one. That is why this tool contributes nothing to M7's byte-exact gate, and why it can
/// be correct without the mutation layer existing.
///
/// M7's brief is specific that the poke path must go through `LogisimStd.InstancePoker` rather
/// than a parallel input path. It does: `Component.pokeCaret(_:)` in `ToolFeatures.swift` is the
/// only bridge, and it wraps an `InstancePoker` in `InstancePokerCaret`: the port of upstream's
/// `InstancePokerAdapter`.
@MainActor
public final class PokeTool: Tool, CanvasTool {

  /// `_ID`. Declared as `Tool.toolId`, the base class's overridable identity, so the
  /// `.circ` codec in `LogisimFile` can read it without hopping to the main actor.
  /// `CanvasTool.id` is the same string; see `CanvasTool`'s extension.
  public override nonisolated class var toolId: String { "Poke Tool" }

  public var displayNameKey: String { "pokeTool" }
  public var descriptionKey: String { "pokeToolDesc" }
  public var cursor: NSCursor { .pointingHand }

  private var pokedCircuit: Circuit?
  private var pokedComponent: (any Component)?
  private var pokeCaret: (any Caret)?
  /// The canvas the live caret belongs to, so `removeCaret` can take the simulation lock.
  ///
  /// `stopEditing` is not a bookkeeping call, a `MemPoker` commits the cell it was editing into
  /// the RAM's contents there, so ending a poke writes simulation state exactly as starting one
  /// does. Weak, and set alongside the caret: the tool outlives every canvas it is used on
  /// (`CanvasToolController` keeps one instance per tool id), so a strong reference here would
  /// keep a closed document's whole object graph alive.
  private weak var pokeCanvas: (any ToolCanvas)?
  private var circuitListenerToken: CircuitPokeListener?

  /// `AppPreferences.POKE_WIRE_RADIX1` / `RADIX2`, pushed in by the shell (D9). The defaults are
  /// upstream's: binary, and no secondary radix.
  public var wireRadix: RadixDisplay = .init()
  /// The radix formatter. Injected because `RadixOption` lives with the circuit package and is
  /// not ported yet; the default renders binary, which is `RadixOption.RADIX_2`.
  public var formatValue: (Value, RadixDisplay) -> String = PokeTool.defaultValueText

  public override init() {}

  // MARK: Overlay

  /// **Seam #16, closed.** `items` is the `WireCaret` callout, which is a fixed shape and fits
  /// the closed enum. `scene` is the *component's own* highlight, drawn by whichever
  /// `InstancePoker` is live: `RegisterPoker`, `CounterPoker`, `ShiftRegisterPoker` and
  /// `Joystick.Poker` all have a fully ported `paint` and, until this line existed, no caller.
  /// `InstancePokerPainting.swift`'s header wrote out this exact hop as the one it could not
  /// make from `LogisimStd`.
  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    guard let caret = pokeCaret else { return .empty }
    // `InstancePokerAdapter.draw` reads the component's live `InstanceData`, a `MemPoker` draws
    // the cell it is editing out of the RAM's contents, so this is a read of simulation state
    // and takes the lock like every other one. See `ToolCanvas.withSimulation`.
    return ToolOverlay(
      items: caret.overlayItems,
      scene: canvas.withSimulation { caret.overlayScene(context: canvas.overlayPaintContext) })
  }

  // MARK: Mouse

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    let point = Location.create(event.x, event.y, hasToSnap: false)
    var dirty = false
    canvas.setHighlightedWires(nil)

    // A click outside the current caret's bounds ends it: normally, i.e. committing whatever it
    // was editing.
    if let caret = pokeCaret, !caret.bounds.contains(point) {
      dirty = true
      removeCaret(normal: true)
    }

    if pokeCaret == nil, let circuit = canvas.circuit {
      let userEvent = ComponentUserEvent(x: event.x, y: event.y, state: canvas.circuitState)
      for component in circuit.allContaining(point) {
        if pokeCaret != nil { break }

        if let wire = component as? Wire {
          let caret = WireCaret(
            wire: wire, at: point, canvas: canvas, radix: wireRadix, format: formatValue)
          setPokedComponent(canvas, circuit, component, caret)
          canvas.setHighlightedWires(canvas.pointQueries.wireSet(containing: wire))
        } else if let caret = canvas.withSimulation({ component.pokeCaret(userEvent) }) {
          setPokedComponent(canvas, circuit, component, caret)
          // Upstream shows the component's attributes when it has any. The guard matters: a
          // component with an empty attribute set must not steal the inspector.
          if !component.attributeSet.attributes.isEmpty {
            canvas.project.viewComponentAttributes(circuit, component)
          }
        }
      }
    }

    if let caret = pokeCaret {
      dirty = true
      // `InstancePokerAdapter.getBounds` is re-read on every press upstream, not cached at
      // construction: `MemPoker`'s sub-pokers derive the caret box from the cell being edited,
      // which moves as the user types, so a stored box ends the poke at the wrong click.
      // The whole interaction under one lock: `refreshBounds` reads the poker's live geometry and
      // `mousePressed` is where a `PinPoker` flips a bit, and a propagation landing between them
      // would move the caret out from under the press.
      var pressed = event
      canvas.withSimulation {
        caret.refreshBounds(context: canvas.overlayPaintContext)
        caret.mousePressed(&pressed)
      }
      event = pressed
      // Outside the lock, always: the propagation thread needs it to do the work being asked for.
      canvas.simulationDidChange()
    }
    if dirty { canvas.project.repaintCanvas() }
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let caret = pokeCaret else {
      // Upstream turns a drag on empty space into a scroll-pane pan, reading
      // `canvas.getMousePosition()` and pushing the scrollbars directly
      // (`PokeTool.java:209-220`). That is camera work, and `RenderSeam.swift` is explicit that
      // the camera belongs to the shell and not to the renderer or the tools; upstream
      // entangling the two is issue #1262. So the pan is not reimplemented here; the shell owns
      // drag-to-pan for every tool, which is also the macOS-consistent behaviour.
      return
    }
    var forwarded = event
    canvas.withSimulation { caret.mouseDragged(&forwarded) }
    event = forwarded
    canvas.simulationDidChange()
    canvas.project.repaintCanvas()
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let caret = pokeCaret else { return }
    var forwarded = event
    canvas.withSimulation { caret.mouseReleased(&forwarded) }
    event = forwarded
    canvas.simulationDidChange()
    canvas.project.repaintCanvas()
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret = pokeCaret else { return }
    var forwarded = event
    canvas.withSimulation { caret.keyPressed(&forwarded) }
    event = forwarded
    canvas.simulationDidChange()
    canvas.project.repaintCanvas()
  }

  public func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret = pokeCaret else { return }
    var forwarded = event
    canvas.withSimulation { caret.keyReleased(&forwarded) }
    event = forwarded
    canvas.simulationDidChange()
    canvas.project.repaintCanvas()
  }

  public func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret = pokeCaret else { return }
    var forwarded = event
    canvas.withSimulation { caret.keyTyped(&forwarded) }
    event = forwarded
    canvas.simulationDidChange()
    canvas.project.repaintCanvas()
  }

  // MARK: Lifecycle

  public func deselect(_ canvas: any ToolCanvas) {
    removeCaret(normal: true)
    canvas.setHighlightedWires(nil)
  }

  /// `isScrollable()`; true while a component (not a wire) is being poked, which the shell uses
  /// to decide whether a scroll gesture belongs to the component or to the canvas.
  public var isScrollable: Bool {
    pokeCaret != nil && !(pokeCaret is WireCaret)
  }

  /// `setPokedComponent(Circuit, Component, Caret)`.
  private func setPokedComponent(
    _ canvas: any ToolCanvas, _ circuit: Circuit, _ component: any Component, _ caret: (any Caret)?
  ) {
    removeCaret(normal: true)
    pokeCanvas = canvas
    pokedCircuit = circuit
    pokedComponent = component
    pokeCaret = caret
    guard caret != nil else { return }
    // `PokeTool.Listener`; drops the caret when the poked component leaves the circuit.
    let listener = CircuitPokeListener(tool: self)
    circuitListenerToken = listener
    circuit.addCircuitListener(listener)
  }

  /// `removeCaret(boolean)`. `normal` distinguishes committing from cancelling, which is the
  /// difference between a poke that sticks and one that is thrown away.
  private func removeCaret(normal: Bool) {
    guard let caret = pokeCaret else { return }
    // Under the lock: see `pokeCanvas`. With no canvas, a caret outliving its document, this
    // falls back to running inline, which is the same thing `ToolCanvas.withSimulation`'s default
    // does and is correct, because a canvas that has gone has no propagation thread left to race.
    if let pokeCanvas {
      pokeCanvas.withSimulation { normal ? caret.stopEditing() : caret.cancelEditing() }
      pokeCanvas.simulationDidChange()
    } else if normal {
      caret.stopEditing()
    } else {
      caret.cancelEditing()
    }
    if let circuit = pokedCircuit, let listener = circuitListenerToken {
      circuit.removeCircuitListener(listener)
    }
    circuitListenerToken = nil
    pokedCircuit = nil
    pokedComponent = nil
    pokeCaret = nil
    pokeCanvas = nil
  }

  fileprivate func circuitChanged(_ event: CircuitEvent) {
    guard let circuit = pokedCircuit, event.circuit === circuit,
      event.action == .remove || event.action == .clear,
      let component = pokedComponent, !circuit.contains(component)
    else { return }
    removeCaret(normal: false)
  }

  nonisolated static func defaultValueText(_ value: Value, _ radix: RadixDisplay) -> String {
    // `RadixOption.RADIX_2.toString(v)`; `Value.toString()` is the binary form.
    String(describing: value)
  }
}

/// The two radix preferences `WireCaret` reads (`AppPreferences.POKE_WIRE_RADIX1`/`RADIX2`).
public struct RadixDisplay: Hashable, Sendable {
  public var primary: String
  public var secondary: String?

  public init(primary: String = "2", secondary: String? = nil) {
    self.primary = primary
    self.secondary = secondary
  }
}

/// `PokeTool.WireCaret`; the yellow callout showing a wire's current value.
///
/// Upstream's `draw` is 50 lines of polygon arithmetic that positions the callout above or below
/// the cursor depending on how close it is to the viewport edge (`PokeTool.java:73-126`). That is
/// presentation, and D6 puts it on the render surface: the caret reports *what* to show and
/// *where*, and the surface decides how to keep it on screen. The value formatting rule is
/// behaviour and is kept: primary radix, then the secondary one for multi-bit values, then the
/// float interpretation for widths 8, 16, 32 and 64.
@MainActor
final class WireCaret: AbstractCaret {
  private let wire: Wire
  private let point: Location
  private weak var canvas: (any ToolCanvas)?
  private let radix: RadixDisplay
  private let format: (Value, RadixDisplay) -> String

  init(
    wire: Wire, at point: Location, canvas: any ToolCanvas, radix: RadixDisplay,
    format: @escaping (Value, RadixDisplay) -> String
  ) {
    self.wire = wire
    self.point = point
    self.canvas = canvas
    self.radix = radix
    self.format = format
    super.init()
  }

  override var text: String {
    guard let value = canvas?.circuitState?.value(at: wire.end0) else { return "" }
    return format(value, radix)
  }

  override var overlayItems: [ToolOverlayItem] {
    let string = text
    return string.isEmpty ? [] : [.valueCallout(at: point, text: string)]
  }
}

/// `PokeTool.Listener`. A separate object because `CircuitListener` is a protocol the tool itself
/// should not have to adopt publicly, and because D3 wants the registration token to be something
/// the tool can drop.
@MainActor
final class CircuitPokeListener: CircuitListener {
  private weak var tool: PokeTool?

  init(tool: PokeTool) { self.tool = tool }

  nonisolated func circuitChanged(_ event: CircuitEvent) {
    // `onMainActor`, **not** `MainActor.assumeIsolated`; see D1's corollary.
    //
    // The comment this replaced said circuits are only ever mutated from the main actor, so
    // asserting isolation was safe. That was true when the only source of circuit events was a
    // user edit, and stopped being true when subcircuit propagation landed: `.invalidate` is
    // posted by `InstanceComponent.fireInvalidated()`, which `SubcircuitPropagation.substate`
    // reaches **from the simulation thread**. This listener is registered on the poked circuit
    // for the whole life of a poke, so a poke held across a propagation would have trapped the
    // process with EXC_BREAKPOINT and reported no test failure, because the binary dies. The
    // event filter is inside `circuitChanged`, so the assertion fired before the `.remove` /
    // `.clear` guard could reject it. Identical to the fix in `CircuitCanvasSurface`'s relay and
    // in `LogisimFileProjectHost.observeCircuit`.
    let boxed = UncheckedSendableBox(event)
    onMainActor { [weak self] in
      self?.tool?.circuitChanged(boxed.value)
    }
  }
}
