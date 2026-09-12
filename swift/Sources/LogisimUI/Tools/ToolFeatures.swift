// ToolFeatures.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.{Caret, AbstractCaret, CaretEvent,
// CaretListener, TextEditable, Pokable, CustomHandles, MenuExtender, ToolTipMaker};
// `WireRepair`/`WireRepairData` moved to LogisimStd; see the note where they used to be),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// These are the small interfaces a *component* implements so that a *tool* can do something with
// it. They are reached through `Component.getFeature(Object)`, whose Swift key space already
// exists as `ComponentFeatureKey` in `LogisimFile/Component.swift`; every key below is already
// declared there, so nothing new has to be invented to look them up.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

// MARK: - Component user event

/// `com.cburch.logisim.comp.ComponentUserEvent`, minus the `Canvas` back-reference.
///
/// Upstream's carries the canvas so a component's caret can call back into the UI. Nothing in the
/// six tools' use of it needs that, and carrying it would put a UI object inside a value the
/// component layer is meant to consume, so it is left out. `circuitState` is kept because pokers
/// genuinely need it.
public struct ComponentUserEvent {
  public var x: Int
  public var y: Int
  public var state: (any ToolCircuitState)?

  public init(x: Int, y: Int, state: (any ToolCircuitState)? = nil) {
    self.x = x
    self.y = y
    self.state = state
  }
}

// MARK: - Caret

/// `com.cburch.logisim.tools.CaretEvent`, a Java `record`.
public struct CaretEvent {
  public let caret: any Caret
  public let oldText: String
  public let text: String

  public init(caret: any Caret, oldText: String, text: String) {
    self.caret = caret
    self.oldText = oldText
    self.text = text
  }
}

/// `com.cburch.logisim.tools.CaretListener`.
@MainActor
public protocol CaretListener: AnyObject {
  func editingCanceled(_ event: CaretEvent)
  func editingStopped(_ event: CaretEvent)
}

/// `com.cburch.logisim.tools.Caret`; an in-place editing session owned by a tool.
///
/// Every method but `bounds` and `text` is a no-op by default, matching upstream's `default`
/// interface methods. `draw(Graphics)` does not come across: D6 keeps drawing behind
/// `RenderScene`, so a caret contributes `ToolOverlayItem`s instead.
@MainActor
public protocol Caret: AnyObject {
  /// `getBounds(Graphics)`; the hit region that decides whether a click stays inside this caret.
  var bounds: Bounds { get }
  /// `getText()`.
  var text: String { get }

  func addCaretListener(_ listener: any CaretListener)
  func removeCaretListener(_ listener: any CaretListener)

  func cancelEditing()
  func stopEditing()
  func commitText(_ text: String)

  /// What this caret wants drawn. Replaces `draw(Graphics)`.
  var overlayItems: [ToolOverlayItem] { get }

  /// Component-authored highlight geometry; `InstancePokerAdapter.draw(Graphics)`.
  ///
  /// Separate from `overlayItems` because a poker draws whatever it likes and `ToolOverlayItem`
  /// is a closed `Hashable` enum. Nil for every caret but `InstancePokerCaret`; see
  /// `ToolOverlay.scene`.
  func overlayScene(context: any PaintContext) -> RenderScene?

  /// Recompute `bounds` from the live poker: `InstancePokerAdapter.getBounds(Graphics)`, which
  /// upstream calls on **every** `PokeTool.mousePressed` rather than caching. It has to be a call
  /// and not a stored value because `MemPoker`'s sub-pokers derive the caret box from the cell
  /// being edited, which moves as the user types.
  func refreshBounds(context: any PaintContext)

  func mousePressed(_ event: inout ToolMouseEvent)
  func mouseDragged(_ event: inout ToolMouseEvent)
  func mouseReleased(_ event: inout ToolMouseEvent)
  func keyPressed(_ event: inout ToolKeyEvent)
  func keyReleased(_ event: inout ToolKeyEvent)
  func keyTyped(_ event: inout ToolKeyEvent)
}

extension Caret {
  public var text: String { "" }
  public func addCaretListener(_ listener: any CaretListener) {}
  public func removeCaretListener(_ listener: any CaretListener) {}
  public func cancelEditing() {}
  public func stopEditing() {}
  public func commitText(_ text: String) {}
  public var overlayItems: [ToolOverlayItem] { [] }
  public func overlayScene(context: any PaintContext) -> RenderScene? { nil }
  public func refreshBounds(context: any PaintContext) {}
  public func mousePressed(_ event: inout ToolMouseEvent) {}
  public func mouseDragged(_ event: inout ToolMouseEvent) {}
  public func mouseReleased(_ event: inout ToolMouseEvent) {}
  public func keyPressed(_ event: inout ToolKeyEvent) {}
  public func keyReleased(_ event: inout ToolKeyEvent) {}
  public func keyTyped(_ event: inout ToolKeyEvent) {}
}

/// `com.cburch.logisim.tools.AbstractCaret`; listener bookkeeping plus a settable bounds.
///
/// D3: upstream holds listeners strongly in an `ArrayList` and relies on the GC. Here the list is
/// weak, because the only listeners are the tools themselves and a tool outlives every caret it
/// makes; a strong edge would keep a dead caret's tool graph alive for the life of the app.
@MainActor
open class AbstractCaret: Caret {
  private struct WeakListener {
    weak var listener: (any CaretListener)?
  }

  private var listeners: [WeakListener] = []

  public private(set) var bounds: Bounds = .empty

  public init() {}

  public func addCaretListener(_ listener: any CaretListener) {
    listeners.append(WeakListener(listener: listener))
  }

  public func removeCaretListener(_ listener: any CaretListener) {
    listeners.removeAll { $0.listener == nil || $0.listener === listener }
  }

  /// `getCaretListeners()`, with the cleared entries dropped as they are noticed.
  public func caretListeners() -> [any CaretListener] {
    listeners.removeAll { $0.listener == nil }
    return listeners.compactMap(\.listener)
  }

  /// `setBounds(Bounds)`.
  public func setBounds(_ value: Bounds) {
    bounds = value
  }

  open var text: String { "" }
  open var overlayItems: [ToolOverlayItem] { [] }
  // Same reason as the block below: a protocol-extension witness is not a class member, so a
  // subclass "override" of it would be an unrelated method and dispatch would miss it.
  open func overlayScene(context: any PaintContext) -> RenderScene? { nil }
  open func refreshBounds(context: any PaintContext) {}

  // The protocol extension's no-op defaults are *witnesses*, not class members, so a subclass
  // cannot override them; it would silently define an unrelated method and the dispatch would go
  // to the extension. Redeclaring them here as `open` is what makes `InstancePokerCaret` and
  // `WireCaret` able to override them at all. Same set, same bodies, same Java (`Caret`'s
  // `default` methods).
  open func cancelEditing() {}
  open func stopEditing() {}
  open func commitText(_ text: String) {}
  open func mousePressed(_ event: inout ToolMouseEvent) {}
  open func mouseDragged(_ event: inout ToolMouseEvent) {}
  open func mouseReleased(_ event: inout ToolMouseEvent) {}
  open func keyPressed(_ event: inout ToolKeyEvent) {}
  open func keyReleased(_ event: inout ToolKeyEvent) {}
  open func keyTyped(_ event: inout ToolKeyEvent) {}
}

// MARK: - Component features

/// `com.cburch.logisim.tools.TextEditable`; a component whose text a `TextTool` may edit.
/// Feature key: `ComponentFeatureKey.textEditable`.
///
/// ── WIRED. The conformer is `LogisimStd.InstanceTextField`. ─────────────────────────────────
///
/// This declaration used to carry a conformer-less gap marker, and the plan written in it was
/// correct, so it was followed rather than replaced: port `TextField`/`TextFieldCaret`, add
/// `InstanceTextField` beside `StdInstanceComponent`, and answer `.textEditable` with it. Where
/// each piece landed, and why, is in three headers: `LogisimStd/Instance/TextField.swift` for
/// the model/caret split, `LogisimStd/Instance/InstanceTextField.swift` for how a component's
/// text field is derived without `Instance.setTextField`, and
/// `LogisimUI/Tools/InstanceTextEditable.swift` for the retroactive conformance.
///
/// **The marker is deleted, not moved.** `seamcheck` matches `ACKNOWLEDGED` only in the six lines
/// immediately above a declaration, so a marker left anywhere in this comment would still
/// suppress the check, and a suppressed check on a protocol that now has a conformer is worse
/// than no check, because it hides the *next* regression too.
///
/// Upstream shape, restated because it explains the odd conformer: `TextEditable` has exactly one
/// implementor in the whole 4.1.0 tree, `com.cburch.logisim.instance.InstanceTextField`, and
/// exactly one producer, `InstanceComponent.getFeature` returning its `textField`
/// (`InstanceComponent.java:362-374`). So the conformer is not a component at all; it is the
/// in-canvas editable label the component owns. `Component.feature(_:key:)` at the bottom of this
/// file is where a `StdInstanceComponent` is turned into one.
@MainActor
public protocol TextEditable: AnyObject {
  /// `getCommitAction(Circuit, String, String)`.
  func commitAction(circuit: Circuit, oldText: String, newText: String) -> Action?
  /// `getTextCaret(ComponentUserEvent)`.
  func textCaret(_ event: ComponentUserEvent) -> (any Caret)?
}

/// `com.cburch.logisim.tools.Pokable`; a component that answers a poke with a caret.
/// Feature key: `ComponentFeatureKey.pokable`.
///
/// Stock components do not implement this directly upstream either: `InstanceComponent` answers
/// `Pokable.class` with an `InstancePokerAdapter` wrapping the factory's `InstancePoker`. The
/// Swift equivalent is `InstancePokerCaret` below, so a component only has to supply an
/// `InstancePoker`, the protocol M7's brief names, and never a caret.
@MainActor
public protocol Pokable: AnyObject {
  /// `getPokeCaret(ComponentUserEvent)`.
  func pokeCaret(_ event: ComponentUserEvent) -> (any Caret)?
}

// ── `WireRepair` / `WireRepairData` USED TO BE DECLARED HERE, AND THE MOVE IS THE FIX ────────
//
// They now live in `LogisimStd/Instance/WireRepair.swift`, beside `InstancePoker`, and that file
// carries the reasoning in full. The short version, kept here because this is where anyone will
// look for them: every implementor upstream is a component, in this port every component lives
// in `LogisimStd`, and `LogisimStd` sits *below* `LogisimUI` in the module graph, so a type
// down there could not name a protocol declared up here, and `wireRepairFeature()`'s `as?`
// matched nothing for every component in the app. Splitter, `AbstractGate` and
// `ControlledBuffer` conform down there now.
//
// They cannot go into `LogisimFile` instead: `LogisimFile.WireRepair` is already the
// `CircuitTransaction` repair pass (`com.cburch.logisim.circuit.WireRepair`), an unrelated
// upstream class that happens to share the name. That collision is why `LogisimUI` must now
// spell the protocol `LogisimStd.WireRepair`: see `wireRepairFeature()` at the bottom of this
// file, which is the only place in the module that names it.

/// `com.cburch.logisim.tools.CustomHandles`. Feature key: `ComponentFeatureKey.customHandles`.
///
/// Upstream's single method is `drawHandles(ComponentDrawContext)`, which D6 forbids. What it
/// means, "I draw my own selection handles, do not draw the default ones", is preserved as a
/// marker the renderer can consult; the drawing itself belongs with the component's `RenderScene`
/// emission, not with a tool.
///
/// **Exactly one type answers this key, and it already tries to.** `Wire` is the only
/// `CustomHandles` implementor in the whole 4.1.0 tree (`circuit/Wire.java:38`, and `:237-238`
/// answers `getFeature(CustomHandles.class)` with `this`), and the only consumer is
/// `gui/main/Selection.java:74-81`. The port had ported both halves: `LogisimFile/Wire.swift:178`
/// already returns `self` for `.customHandles`. What was missing was the conformance itself, so
/// the `as?` in `Component.feature(_:key:)` could never succeed and *every* wire would have
/// silently fallen back to the default handles; a wrong picture with no error anywhere. The
/// conformance below is retroactive because `Wire` lives in `LogisimFile`, under this module;
/// that is fine for a single known concrete type, and it is what makes the seam real.
@MainActor
public protocol CustomHandles: AnyObject {
  var drawsOwnHandles: Bool { get }
}

extension CustomHandles {
  public var drawsOwnHandles: Bool { true }
}

/// `com.cburch.logisim.circuit.Wire implements … CustomHandles` (`Wire.java:38`).
///
/// `Wire.drawHandles` paints a handle at each end. Under D6 the painting belongs to the wire's
/// own scene emission, so all that crosses here is the marker; the default `true` is exactly
/// upstream's answer, since a `Wire` never wants `ComponentDrawContext.drawHandles`.
extension Wire: CustomHandles {}

/// `com.cburch.logisim.tools.ToolTipMaker`. Feature key: `ComponentFeatureKey.toolTipMaker`.
///
/// Conformers and the consumer both live in `ComponentToolTips.swift`, which also carries the
/// account of what 4.1.0 puts in a tool tip and where this port diverges from it. Until that file
/// existed this protocol had no conformer and the key had no consumer; the tip was unreachable
/// from either end, which is why nothing noticed that hovering a chip said nothing.
@MainActor
public protocol ToolTipMaker: AnyObject {
  /// `getToolTip(ComponentUserEvent)`.
  func toolTip(_ event: ComponentUserEvent) -> String?
}

// MARK: - The instance poker adapter

/// `com.cburch.logisim.instance.InstancePokerAdapter`, reduced to what a caret needs.
///
/// M7's brief is explicit that the poke protocol already exists at
/// `LogisimStd/Instance/InstancePoker.swift` and that `PokeTool` must drive *that*, not a parallel
/// input path. This is the adapter that makes it possible: `PokeTool` only knows about `Caret`,
/// components only know about `InstancePoker`, and this is the one place the two meet.
///
/// The event translation is upstream's: `InstancePoker` sees a `PokeMouseEvent` carrying raw
/// coordinates and a `PokeKeyEvent` carrying an AWT virtual key code and a UTF-16 `char`, and its
/// `consumed` flag is written back into the tool's event so the tool can stop propagating.
@MainActor
public final class InstancePokerCaret: AbstractCaret, Pokable {

  private let poker: any InstancePoker
  private let state: any InstanceState
  /// The poked component.
  ///
  /// **Added by seam #16.** `InstancePokerAdapter` is constructed from an `InstanceComponent` and
  /// holds it for its whole life, because `paint` and `getBounds` both need an
  /// `InstancePainter` bound to a *component*; a factory-backed (ghost) painter has no data and
  /// empty bounds, and `PokeOverlayRenderer` refuses one on purpose. Without this field the
  /// caret could route input to a poker and could never ask it to draw.
  private let component: any Component
  /// `InstancePokerAdapter` keeps this so `stopEditing` can reach the poker exactly once.
  private var isEditing = true

  public init(
    poker: any InstancePoker, state: any InstanceState, component: any Component, bounds: Bounds
  ) {
    self.poker = poker
    self.state = state
    self.component = component
    super.init()
    setBounds(bounds)
  }

  /// `InstancePokerAdapter.draw(Graphics)`: the whole of it, in one call.
  ///
  /// Returns the highlight as its own scene rather than drawing into the circuit's, because a
  /// poke moves on every keystroke and the circuit scene is rebuilt only when its geometry key
  /// changes. `nil` means the poker emitted nothing, which is different from "was never asked":
  /// `PokeOverlayRenderer.render` returns `false` only when the painter had no component.
  public override func overlayScene(context: any PaintContext) -> RenderScene? {
    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    guard
      PokeOverlayRenderer.render(
        poker: poker, component: component, into: builder, context: context)
    else { return nil }
    let scene = builder.finish()
    return scene.isEmpty ? nil : scene
  }

  /// `InstancePokerAdapter.getBounds(Graphics)`.
  public override func refreshBounds(context: any PaintContext) {
    let scratch = SceneBuilder(measurer: CoreTextMeasurer())
    setBounds(
      PokeOverlayRenderer.highlightBounds(
        poker: poker, component: component, scratch: scratch, context: context))
  }

  /// `Pokable.getPokeCaret`; a poker caret is its own pokable, which is how
  /// `PokeTool.setPokedComponent` can be handed either shape.
  public func pokeCaret(_ event: ComponentUserEvent) -> (any Caret)? { self }

  public override func mousePressed(_ event: inout ToolMouseEvent) {
    poker.mousePressed(state, PokeMouseEvent(x: event.x, y: event.y))
  }

  public override func mouseDragged(_ event: inout ToolMouseEvent) {
    poker.mouseDragged(state, PokeMouseEvent(x: event.x, y: event.y))
  }

  public override func mouseReleased(_ event: inout ToolMouseEvent) {
    poker.mouseReleased(state, PokeMouseEvent(x: event.x, y: event.y))
  }

  public override func keyPressed(_ event: inout ToolKeyEvent) {
    var pokeEvent = InstancePokerCaret.pokeKeyEvent(event)
    poker.keyPressed(state, &pokeEvent)
    if pokeEvent.consumed { event.consume() }
  }

  public override func keyReleased(_ event: inout ToolKeyEvent) {
    var pokeEvent = InstancePokerCaret.pokeKeyEvent(event)
    poker.keyReleased(state, &pokeEvent)
    if pokeEvent.consumed { event.consume() }
  }

  public override func keyTyped(_ event: inout ToolKeyEvent) {
    var pokeEvent = InstancePokerCaret.pokeKeyEvent(event)
    poker.keyTyped(state, &pokeEvent)
    if pokeEvent.consumed { event.consume() }
  }

  public override func stopEditing() {
    guard isEditing else { return }
    isEditing = false
    poker.stopEditing(state)
  }

  /// Upstream's `cancelEditing` on the adapter also calls `stopEditing` on the poker; the poker
  /// interface has no cancel, so a cancelled poke is simply a stopped one.
  public override func cancelEditing() {
    stopEditing()
  }

  private static func pokeKeyEvent(_ event: ToolKeyEvent) -> PokeKeyEvent {
    // `PokeKeyEvent.keyChar` is Java's UTF-16 code unit, with nil standing for
    // `KeyEvent.CHAR_UNDEFINED`. A Swift `Character` may be more than one code unit (an emoji, a
    // combining sequence); those cannot be a Java `char` at all, so they map to undefined, which
    // is what AWT would have delivered for an input method commit too.
    var keyChar: UInt16?
    if let character = event.character {
      let units = Array(String(character).utf16)
      keyChar = units.count == 1 ? units[0] : nil
    }
    return PokeKeyEvent(keyCode: event.rawKeyCode, keyChar: keyChar)
  }
}

// MARK: - Feature lookup

extension Component {
  /// `getFeature(X.class)` with the cast folded in, so a tool reads
  /// `component.feature(WireRepair.self, key: .wireRepair)` instead of an `as?` dance at every
  /// call site. Upstream passes the `Class` object as both the key *and* the cast target; Swift
  /// needs them separately because `ComponentFeatureKey` is a string, not a metatype.
  public func feature<T>(_ type: T.Type, key: ComponentFeatureKey) -> T? {
    if let direct = feature(key) as? T { return direct }
    // ── `.textEditable`, and why the fork is here rather than in `StdInstanceComponent` ──────
    //
    // Upstream's `InstanceComponent.getFeature` answers `TextEditable.class` with its own
    // `textField`; a field the component carries for life, installed by `setTextField` from a
    // factory's `configureNewInstance`. This port has neither: `Instance` is gone (D3) and
    // `setTextField`'s six arguments are recomputed on demand instead (D6: see
    // `LabelPlacement`). More to the point, `StdInstanceComponent` lives in `LogisimStd`, which
    // sits *below* this module and cannot name `TextEditable` to declare a return type.
    //
    // So the component-side half, which attribute holds the text, where it sits, how to write
    // it back, is `LogisimStd.InstanceTextField`, and the one place it is turned into a
    // `TextEditable` is here. Same shape as `pokeCaret(_:)` below, which accepts either a
    // `Pokable` or a bare `InstancePoker` and wraps the latter; the difference is only that a
    // text field needs no wrapper, because the conformance is declared retroactively.
    //
    // Deliberately a *second* arm rather than a replacement for the cast above: a component that
    // does answer `.textEditable` itself, a future `LogisimUI`-side conformer, still wins.
    if key == .textEditable, let component = self as? StdInstanceComponent,
      let editable = InstanceTextField.make(
        for: component, measurer: InstanceTextField.canvasMeasurer) as? T
    {
      return editable
    }
    // ── `.toolTipMaker`, and why it needs an arm at all ──────────────────────────────────────
    //
    // Same shape as `.textEditable` above, for the same reason. In 4.1.0 the key is answered by
    // the component itself: `Splitter.getFeature` returns `this` (circuit/Splitter.class), and
    // `InstanceComponent.getFeature` returns `this` when the instance has port tips or its
    // factory has a default tip (instance/InstanceComponent.class).
    //
    // Neither can here, and the reason is module direction, not an oversight.
    // `Splitter.feature(_:)` (`LogisimStd/Wiring/Splitter.swift:243`) answers only `.wireRepair`;
    // `StdInstanceComponent.feature(_:)` (`LogisimStd/Instance/StdInstanceComponent.swift:235`)
    // forwards to `instanceFactory?.instanceFeature(key, self)`, which is upstream's own first
    // line, but `InstanceFactory` is in `LogisimStd` too, so no conformer it could return would
    // be nameable there. Both files sit *below* this module. This is where the two can meet.
    //
    // Two arms, in upstream's own precedence order. The retroactive conformance first, so a
    // component that IS a `ToolTipMaker` (today: `Splitter`) wins; then the subcircuit wrapper,
    // which stands in for `getDefaultToolTip()`; the only `setDefaultToolTip` call site in the
    // whole 4.1.0 jar. Both are in `ComponentToolTips.swift`.
    if key == .toolTipMaker {
      if let maker = self as? any ToolTipMaker, let typed = maker as? T { return typed }
      if let subcircuit = SubcircuitToolTip(self), let typed = subcircuit as? T { return typed }
    }
    return nil
  }

  /// `Selection.java:74-81`; "does this component paint its own selection handles?"
  ///
  /// Upstream's branch is `handler == null ? context.drawHandles(comp) : handler.drawHandles(…)`.
  /// D6 moves the painting itself into the component's scene emission, so what the renderer needs
  /// from here is the predicate, and it needs it in exactly one place; this one. Answering
  /// `false` for a component with no feature is upstream's `null` arm.
  ///
  /// Being a plain computed property rather than an `as?` at the call site is deliberate: the cast
  /// spelled by hand is what silently returned nil for every wire while both halves of the seam
  /// looked correct.
  ///
  /// Named `hasCustomHandles` rather than `drawsOwnHandles` because `Wire` is both a `Component`
  /// and a `CustomHandles`, and the two spellings would then be an ambiguous lookup on it, which
  /// is a compile error, but only at the call site, and only for the one type that matters.
  @MainActor
  public var hasCustomHandles: Bool {
    feature((any CustomHandles).self, key: .customHandles)?.drawsOwnHandles ?? false
  }

  /// `comp.getFeature(WireRepair.class)`: the single place `WiringTool.checkForRepairs` asks.
  ///
  /// One call site on purpose, and it is now a *live* one: `Splitter`, `AbstractGate` and
  /// `ControlledBuffer` answer `.wireRepair` from `LogisimStd`, so this returns a conformer for
  /// every splitter, every gate and every controlled buffer on the canvas. Before the protocol
  /// moved down there it returned nil for everything, because no component could name a type
  /// declared in this module.
  ///
  /// **`LogisimStd.` is load-bearing, not decoration.** `LogisimFile` exports its own
  /// `WireRepair`, the `CircuitTransaction` repair pass, `com.cburch.logisim.circuit.WireRepair`
  /// , and this module imports both, so the bare name is ambiguous here. Spelling the module is
  /// what says which of the two unrelated upstream classes is meant.
  @MainActor
  public func wireRepairFeature() -> (any LogisimStd.WireRepair)? {
    feature((any LogisimStd.WireRepair).self, key: .wireRepair)
  }

  /// The poke feature specifically, which has two acceptable shapes: a `Pokable` (upstream's
  /// contract) or a bare `InstancePoker` (what a ported stock component naturally supplies).
  /// Returning the caret directly keeps that fork in one place instead of inside `PokeTool`.
  @MainActor
  public func pokeCaret(_ event: ComponentUserEvent) -> (any Caret)? {
    let raw = feature(.pokable)
    if let pokable = raw as? any Pokable {
      return pokable.pokeCaret(event)
    }
    if let poker = raw as? any InstancePoker,
      let state = event.state?.instanceState(for: self)
    {
      let caret = InstancePokerCaret(
        poker: poker, state: state, component: self, bounds: bounds)
      guard poker.beginPoke(state, PokeMouseEvent(x: event.x, y: event.y)) else { return nil }
      return caret
    }
    return nil
  }
}
