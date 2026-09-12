// Tool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.Tool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `Tool` is a CLASS, and it lives in `LogisimFile`, not here ──────────────────────────────
//
// Upstream's `Tool` is an abstract class whose seventeen methods are all no-ops, so a concrete
// tool overrides only what it cares about. This file originally declared a competing
// `protocol Tool: AnyObject`; that has been deleted. **`LogisimFile.Tool` is the one `Tool`**,
// and it is an `open class`, for three reasons that are not stylistic:
//
//   1. **Identity.** D4's rule that `Component` and `AttributeSet` compare by reference applies
//      to tools too. `Tool.sharesSource` is `this == other`, and `LogisimFile.findTool`,
//      `ToolbarData.replaceAll`, `MouseMappings.replaceAll` and `AddTool.sharesSource` all key on
//      a tool by identity. A value type would compile and then silently match the wrong toolbar
//      entry. A class-bound protocol would give identity too, but not (2).
//   2. **Inherited stored state.** `AddTool` carries a factory and a lazily-built `AttributeSet`,
//      and `LogisimFile`'s writer reads them (`AddTool.sharesSource` is documented there as
//      load-bearing: without it every cloned toolbar button becomes unresolvable and saving any
//      file with a toolbar fails). Protocols cannot carry that.
//   3. **It already exists below us and every library is built out of it.** `LogisimStd`'s
//      library tables are ~200 literal `AddTool(factory:)` calls and `LogisimFile.swift` builds
//      more for circuits and VHDL entities. The tool the user clicks in the explorer *is* a
//      `LogisimFile.AddTool`. A second `Tool` here meant `Project.tool` and every `as? AddTool`
//      test in `Project.swift` looked at the wrong type, which is exactly what they did.
//
// So the split is: `LogisimFile.Tool` is Java's class minus the editing surface, because D9 keeps
// `NSCursor` and canvas events out of the file layer; `CanvasTool` below is a **class-constrained
// protocol** (`protocol CanvasTool: Tool`) that adds the surface back, with an extension supplying
// the same no-op defaults Java's base class does. A tool is therefore a `Tool` subclass that
// conforms to `CanvasTool`, and `AddTool` can go on inheriting `LogisimFile.AddTool`, which
// single inheritance would have forbidden had `CanvasTool` been a base class of its own.
//
// ── Where `@MainActor` sits, module-wide ────────────────────────────────────────────────────
//
// D1 puts the kernel in Swift 5 with no Concurrency and this module in Swift 6 with full
// isolation, which means every type here has to pick a side. Three slices picked differently and
// that is what produced the "main actor-isolated property 'factory' cannot be referenced from a
// nonisolated context" class of error. The rule, applied uniformly:
//
//   **The whole editing layer is `@MainActor`**: `Project`, `Action` and its subclasses,
//   `Selection`, `SelectionActions`, the six tools, the canvas, the controller. Java confines all
//   of it to the EDT; the annotation is the compiler-checked version of that confinement.
//
//   **Three things are deliberately not**, each because it mirrors something Java also runs off
//   the EDT or below the Swift-6 line:
//     * the transaction substrate: `CircuitTransaction`, `CircuitLocker`, `CircuitMutator`,
//       `CircuitChange`, `ReplacementMap`, and `CircuitMutation`'s recording half. Upstream takes
//       real per-circuit locks here precisely because a transaction can run off the EDT, and the
//       port kept them.
//     * `Tools/Move/*`, the background reroute engine. Upstream runs it on its own
//       `ConnectorThread` and so does this.
//     * the `LogisimFile.Tool` half every tool inherits, which compiles in the module below.
//
// Where the two meet, the crossing is explicit and named rather than sprinkled: `nonisolated
// override` on the members inherited from `LogisimFile.Tool`, `MainActor.assumeIsolated` in the
// `LibraryListener` callback `Project` owns (Java fires it on the EDT), and the two existing
// boxes `WeakToolCanvasRef` / `UncheckedSendableBox` for the reroute engine's completion hop.
//
// Two members did not come across, and both for D6/D9 reasons rather than oversight:
//
//   * `draw(Canvas, ComponentDrawContext)` and `draw(ComponentDrawContext)`; these hand the tool
//     an AWT `Graphics`. D6 makes `RenderScene` the only drawing API and forbids components
//     touching a context; a tool is no more entitled to one than a component is. What tools
//     actually draw is a small, closed set of overlays (a rubber band, a pending wire, ghosts,
//     a value callout), so `overlay` describes it and the render surface draws it. That also
//     removes the whole `Graphics g` parameter threaded through every mouse method upstream.
//   * `paintIcon(ComponentDrawContext, int, int)`; the toolbar/explorer icon. `DomainTypes.ToolItem`
//     already carries an SF Symbol name for this, which is the macOS-native answer.

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - Input

/// The modifier keys a tool consults, and **the one place this port deliberately deviates from
/// AWT** (M7: "Deliberate macOS modifier conventions, not literal AWT translation").
///
/// The rule that governs every entry below: the *input* mapping may differ from Java, the
/// resulting model mutation may not. Each case therefore names the AWT original it replaces, and
/// nothing here changes what a gesture does: only which keys reach it.
public struct ToolModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let shift = ToolModifiers(rawValue: 1 << 0)
  public static let control = ToolModifiers(rawValue: 1 << 1)
  public static let option = ToolModifiers(rawValue: 1 << 2)
  public static let command = ToolModifiers(rawValue: 1 << 3)

  public init(_ canvasModifiers: CanvasModifiers) {
    var set = ToolModifiers()
    if canvasModifiers.contains(.shift) { set.insert(.shift) }
    if canvasModifiers.contains(.control) { set.insert(.control) }
    if canvasModifiers.contains(.option) { set.insert(.option) }
    if canvasModifiers.contains(.command) { set.insert(.command) }
    self = set
  }

  // ── The mapping table ─────────────────────────────────────────────────────────────────────

  /// Extend or toggle the selection.
  ///
  /// **AWT original:** `InputEvent.SHIFT_DOWN_MASK`, tested four times in
  /// `SelectTool.mousePressed` (`SelectTool.java:439,455,475`).
  ///
  /// **macOS:** Shift **or** Command. Command-click is the platform's toggle-selection gesture in
  /// every list, canvas and Finder view; Shift is kept because it is what every existing Logisim
  /// user's hands already do, and because the two produce the identical mutation here; upstream
  /// uses one modifier for what macOS splits into extend (Shift) and toggle (Command), and this
  /// gesture is the toggle in both readings.
  public var isAdditiveSelection: Bool { contains(.shift) || contains(.command) }

  /// Invert the "keep connections while moving" preference for this drag.
  ///
  /// **AWT original:** `MouseEvent.SHIFT_DOWN_MASK` in `SelectTool.shouldConnect`
  /// (`SelectTool.java:639-643`).
  ///
  /// **macOS:** Shift, unchanged. Shift-as-constrain-modifier during a drag is the same idiom on
  /// both platforms, and unlike the selection case there is no Mac convention pulling it
  /// elsewhere.
  ///
  /// Note this is *not* folded into `isAdditiveSelection` even though both start from Shift:
  /// they are read at different moments (press vs. drag/release) and conflating them would make
  /// Command-drag silently change the reconnect behaviour.
  public var invertsKeepConnections: Bool { contains(.shift) }

  /// Force the point under the cursor to count as a wiring point regardless of what is there.
  ///
  /// **AWT original:** `MouseEvent.ALT_DOWN_MASK`, read by `EditTool.isWiringPoint` and
  /// `EditTool.updateLocation` (`EditTool.java:248,435`).
  ///
  /// **macOS:** Option, which is the same physical key. Kept literal because it is already
  /// correct: Option is Alt.
  public var forcesWiringPoint: Bool { contains(.option) }

  /// Duplicate rather than move while dragging a selection.
  ///
  /// **AWT original:** none. `HOTKEY_EDIT_TOOL_DUPLICATE` defaults to bare **Insert**
  /// (`AppPreferences.java:988,1069`) and duplicates in place; 4.1.0 has no drag-duplicate
  /// gesture at all.
  ///
  /// **macOS:** Option-drag is the platform's duplicate-drag, and Option is free during a select
  /// drag. It is defined here, and left *unbound* by `SelectTool`, deliberately: wiring it up
  /// would create an edit sequence the Java oracle cannot produce, which is precisely the kind of
  /// divergence M7's byte-exact gate exists to catch. The constant is here so that whoever adds
  /// it later adds it knowingly, and so the Insert-key remap below has an obvious companion.
  public var isDuplicateDrag: Bool { contains(.option) }
}

/// The fields the six tools read from `java.awt.event.MouseEvent`.
///
/// **Why `inout` everywhere it is passed.** Upstream's `Canvas.snapToGrid(MouseEvent)` mutates
/// the event *in place* (`Canvas.java:199-205`), and that mutation is observed by a later
/// handler: `EditTool.mouseReleased` forwards the event to `WiringTool`, which snaps it, and then
/// passes the **already-snapped** event on to `SelectTool.mousePressed`
/// (`EditTool.java:395-399`). Making this a value type passed by value would silently unsnap that
/// second call. So every tool entry point takes `inout`, which is the faithful translation of a
/// mutable Java event object and makes the coupling visible rather than accidental.
public struct ToolMouseEvent: Hashable, Sendable {
  /// `getX()`/`getY()`, in integer circuit coordinates.
  public var point: ToolPoint
  public var modifiers: ToolModifiers
  /// `getClickCount()`.
  public var clickCount: Int
  /// `getButton()`. 1 is the primary button; upstream's tools only ever see the primary one,
  /// because `Canvas` routes the others to the popup menu and the pan gesture.
  public var button: Int
  /// `isConsumed()` / `consume()`.
  public private(set) var isConsumed: Bool

  public init(
    point: ToolPoint, modifiers: ToolModifiers = [], clickCount: Int = 1, button: Int = 1,
    isConsumed: Bool = false
  ) {
    self.point = point
    self.modifiers = modifiers
    self.clickCount = clickCount
    self.button = button
    self.isConsumed = isConsumed
  }

  public var x: Int { point.x }
  public var y: Int { point.y }

  public mutating func consume() { isConsumed = true }

  /// `Canvas.snapToGrid(this)`.
  public mutating func snapToGrid() {
    point = CanvasGrid.snapToGrid(point)
  }
}

/// The AWT virtual key codes the six tools compare against, plus the macOS remaps.
///
/// Upstream compares `KeyEvent.getKeyCode()` against `VK_*` constants and against user-rebindable
/// `PrefMonitorKeyStroke`s. The port keeps the *decisions* and names them semantically, so the
/// shell can bind whatever keys the platform wants without a tool ever seeing a key code.
public enum ToolCommandKey: Hashable, Sendable {
  /// **AWT:** `VK_DELETE` and `VK_BACK_SPACE` (`SelectTool.java:380-381`, `EditTool.java:284`).
  /// **macOS:** Delete and Forward Delete. Unchanged, both platforms agree.
  case deleteSelection

  /// **AWT:** `HOTKEY_EDIT_TOOL_DUPLICATE`, default bare **Insert** (`AppPreferences.java:1069`).
  /// **macOS:** Command-D. Mac keyboards have no Insert key at all, so the AWT default is not
  /// merely unidiomatic here, it is unreachable. Command-D is the platform's Duplicate, and it
  /// coincides with upstream's *menu* duplicate (`HOTKEY_EDIT_MENU_DUPLICATE`, ⌘D) which invokes
  /// the same `SelectionActions.duplicate`, so the two collapse into one binding with no change
  /// of behaviour.
  case duplicateSelection

  /// **AWT:** `HOTKEY_DIR_NORTH`/`SOUTH`/`EAST`/`WEST`, default bare arrow keys.
  /// **macOS:** unchanged.
  case face(Direction)

  /// **AWT:** `VK_SPACE` **with** `CTRL_DOWN_MASK` (`EditTool.java:308-312`).
  /// **macOS:** Option-Space. Both obvious translations are taken by the system; Command-Space
  /// is Spotlight and Control-Space is "select the previous input source", so neither can be
  /// bound without the OS eating the event first. Option-Space is free and adjacent.
  case rotateSelection

  /// **AWT:** `HOTKEY_ADD_TOOL_ROTATE`, default bare `R` (`AppPreferences.java:1074`).
  /// **macOS:** unchanged.
  case rotatePendingComponent

  /// **AWT:** `VK_X` (`AddTool.java:372`). **macOS:** unchanged.
  case toggleMatrixPlacement

  /// **AWT:** `VK_ESCAPE` (`AddTool.java:399`). **macOS:** unchanged.
  case cancelPlacement

  /// **AWT:** `VK_BACK_SPACE` in `AddTool`/`WiringTool`, which undoes the placement this tool
  /// just made, but only while it is still the top of the undo stack
  /// (`AddTool.java:410-414`, `WiringTool.java:192-198`).
  /// **macOS:** unchanged. It shares a key with `deleteSelection`, as upstream does; the two are
  /// unreachable from one another because they are handled by different tools.
  case undoOwnLastPlacement

  /// **AWT:** `VK_ALT` press/release, which re-evaluates the wiring indicator without the mouse
  /// moving (`EditTool.java:305-307,322-324`). **macOS:** Option. Unchanged.
  case wiringOverrideModifierChanged

  /// **AWT:** `VK_SHIFT` press/release during a move, which re-runs the reroute with the
  /// inverted connect preference (`SelectTool.java:342,399`). **macOS:** unchanged.
  case keepConnectionsModifierChanged
}

/// The fields the six tools read from `java.awt.event.KeyEvent`.
///
/// `isConsumed` is `inout`-visible for the same reason `ToolMouseEvent`'s is: `AddTool.keyPressed`
/// branches on whether its own `processKeyEvent` consumed the event (`AddTool.java:354`).
public struct ToolKeyEvent: Hashable, Sendable {
  /// The semantic command, resolved by the shell from the platform key binding. Nil for a key
  /// that carries no tool command; it can still reach a component's key configurator through
  /// `character`/`rawKeyCode`.
  public var command: ToolCommandKey?
  /// The typed character, for `keyTyped` and for label entry.
  public var character: Character?
  /// The AWT-equivalent virtual key code, for the component key configurators ported from
  /// `tools/key`, which genuinely switch on `VK_*`.
  public var rawKeyCode: Int
  public var modifiers: ToolModifiers
  public var isRepeat: Bool
  public private(set) var isConsumed: Bool

  public init(
    command: ToolCommandKey? = nil, character: Character? = nil, rawKeyCode: Int = 0,
    modifiers: ToolModifiers = [], isRepeat: Bool = false, isConsumed: Bool = false
  ) {
    self.command = command
    self.character = character
    self.rawKeyCode = rawKeyCode
    self.modifiers = modifiers
    self.isRepeat = isRepeat
    self.isConsumed = isConsumed
  }

  public mutating func consume() { isConsumed = true }
}

// MARK: - Overlay

/// What a tool wants drawn over the schematic, replacing `Tool.draw(Canvas, ComponentDrawContext)`.
///
/// Closed on purpose. Upstream's tools draw with a raw `Graphics`, which means the set of things
/// a tool can put on screen is unbounded and undiscoverable; in practice it is the nine cases
/// below. Enumerating them lets the renderer own every pixel (D6) and lets a headless test assert
/// what the tool *intended* to draw without a framebuffer.
/// Not `Sendable`: two cases carry a `Component`/`ComponentFactory` reference, and D4 makes those
/// non-`Sendable` classes on purpose. An overlay is produced and consumed on the main actor.
public enum ToolOverlayItem: Hashable {
  /// `WiringTool.draw`; the L-shaped wire being dragged. `elbow` is nil for a straight run.
  /// The two segments are `start → elbow` and `elbow → end`, in that order, matching the two
  /// `drawLine` calls (`WiringTool.java:130-136`).
  case pendingWire(start: Location, elbow: Location?, end: Location)
  /// `WiringTool.draw`'s grey dot shown at the snapped cursor when `ADD_SHOW_GHOSTS` is on.
  case cursorDot(Location)
  /// `EditTool.draw`: the hollow circle marking a wiring point (`EditTool.java:163-173`).
  case wiringPointIndicator(Location)
  /// `SelectTool.draw`'s rubber band, in circuit coordinates.
  case marquee(Bounds)
  /// `SelectTool.draw`; components that would be swept up by the current marquee, drawn as
  /// ghosts.
  case marqueeGhost(component: ComponentRef)
  /// `SelectTool.draw`: the selection drawn shifted by the current drag delta.
  case selectionGhost(dx: Int, dy: Int)
  /// `SelectTool.draw`: a wire the move engine proposes to add.
  case proposedWire(start: Location, end: Location)
  /// `SelectTool.draw`; the red dots at a connection the move engine could not satisfy. Drawn
  /// at both the old and the shifted position, which is why the delta rides along.
  case unsatisfiedConnection(Location, dx: Int, dy: Int)
  /// `AddTool.draw`: the ghost of the component about to be placed. `isCommitted` distinguishes
  /// upstream's `SHOW_GHOST` (grey/magenta) from `SHOW_ADD` (black/blue), and `needsLabel` is its
  /// auto-labeller tint.
  case placementGhost(
    factory: ComponentFactoryRef, at: Location, isCommitted: Bool, needsLabel: Bool)
  /// `PokeTool`'s `WireCaret` callout showing a wire's value.
  case valueCallout(at: Location, text: String)
}

/// A `Hashable` box around a `ComponentFactory`, keyed by reference identity. The same device
/// `LogisimFile.ComponentRef` is, and for the same D4 reason: factories are singletons compared
/// with `==` in Java, which is reference equality there.
public struct ComponentFactoryRef: Hashable {
  public let factory: any ComponentFactory

  public init(_ factory: any ComponentFactory) { self.factory = factory }

  public static func == (lhs: ComponentFactoryRef, rhs: ComponentFactoryRef) -> Bool {
    lhs.factory === rhs.factory
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(factory))
  }
}

/// Everything the active tool wants drawn this frame.
public struct ToolOverlay {
  public var items: [ToolOverlayItem]
  /// `Tool.getHiddenComponents(Canvas)`; components the renderer must *not* draw, because the
  /// tool is drawing a moved or shortened version of them itself. Returning the wrong set here is
  /// how upstream's move preview ends up double-drawing wires.
  public var hiddenComponents: Set<ComponentRef>

  /// Component-authored overlay geometry, carried whole.
  ///
  /// **Seam #16's other half, and the reason `items` alone is not enough.** A live poke draws
  /// through `InstancePoker.paint(InstancePainter)`; arbitrary geometry written by whichever
  /// component is being poked, six ported implementations of it in `LogisimStd` today. That
  /// cannot travel as a `ToolOverlayItem`: the enum is closed *and* `Hashable` by design, which
  /// is exactly what makes it a good contract for the nine fixed shapes a tool draws and a
  /// useless one for geometry a component invents. `InstancePokerPainting.swift`'s header states
  /// the requirement; this is it.
  ///
  /// Nil for every tool but `PokeTool`. The canvas draws it after `items`, as its own pass:
  /// `RenderScene` interns points and colour slots by index, so two scenes are two draw calls,
  /// not a concatenation. See `ToolOverlaySceneBuilder`.
  public var scene: RenderScene?

  public init(
    items: [ToolOverlayItem] = [], hiddenComponents: Set<ComponentRef> = [],
    scene: RenderScene? = nil
  ) {
    self.items = items
    self.hiddenComponents = hiddenComponents
    self.scene = scene
  }

  /// Computed rather than a stored `static let`, because `ToolOverlay` is deliberately not
  /// `Sendable` (it carries component references) and a stored static of a non-`Sendable` type is
  /// global mutable state under Swift 6.
  public static var empty: ToolOverlay { ToolOverlay() }

  /// The world-space delta this overlay's move preview is drawn at, or `.zero`.
  ///
  /// `selectionGhost` is the one item that both *shifts* what is drawn and *hides* what it
  /// replaces, which makes it the one item the selection outline has to follow; see
  /// `CircuitSceneView.dragPreview` for what happens when it does not. Read off `items` rather
  /// than stored beside `hiddenComponents` so there is no second field for a tool to forget to
  /// set: the delta is already in the overlay, by construction, or there is no preview.
  ///
  /// Deliberately NOT `unsatisfiedConnection`'s delta, which is the same number today and is
  /// there for a different reason (it marks a port's destination and is drawn at *both* ends).
  /// Reading it here would make an unrelated tool's red dot able to move the selection outline.
  public var previewOffset: CGSize {
    for item in items {
      if case let .selectionGhost(dx, dy) = item {
        return CGSize(width: CGFloat(dx), height: CGFloat(dy))
      }
    }
    return .zero
  }
}

// MARK: - CanvasTool

/// The editing half of `com.cburch.logisim.tools.Tool`.
///
/// See the file header for why `Tool` itself is `LogisimFile.Tool`, an `open class`, and why this
/// is a **class-constrained protocol** rather than a base class of its own: `AddTool` has to keep
/// inheriting `LogisimFile.AddTool`, and Swift has single inheritance.
///
/// The class constraint (`: Tool`) is load-bearing, not decoration. It is what lets a `CanvasTool`
/// be handed to `Project.setTool`, stored in a `Library`, resolved by `XmlWriter.fromTool`, and
/// compared with `sharesSource`; all of which are declared against the class. Drop it and the
/// canvas would be holding a tool the rest of the app cannot name.
@MainActor
public protocol CanvasTool: Tool {
  /// The `_ID` constant every concrete tool declares. Upstream's comment is emphatic and applies
  /// here verbatim: it is written into `.circ` files as a tool reference, so changing one stops
  /// projects loading.
  ///
  /// Distinct from `LogisimFile.Tool.toolId`, which is the same string reached through a
  /// non-isolated class property so the codec can read it without hopping to the main actor. A
  /// conformer declares `toolId` and gets `id` for free; see the extension.
  static var id: String { get }

  /// `getDisplayName()`. A resource key, not a translated string, see `ToolActionName`.
  var displayNameKey: String { get }
  /// `getDescription()`.
  var descriptionKey: String { get }

  /// `getCursor()`.
  var cursor: NSCursor { get }

  /// `getAttributeSet(Canvas)`. The no-argument `getAttributeSet()` is inherited from `Tool`.
  func attributeSet(for canvas: any ToolCanvas) -> (any AttributeSet)?
  func setAttributeSet(_ attributes: any AttributeSet)

  /// `select(Canvas)` / `deselect(Canvas)`.
  func select(_ canvas: any ToolCanvas)
  func deselect(_ canvas: any ToolCanvas)

  /// The overlay the canvas should draw. Replaces `draw(Canvas, ComponentDrawContext)`.
  func overlay(for canvas: any ToolCanvas) -> ToolOverlay

  /// `getHiddenComponents(Canvas)`.
  func hiddenComponents(for canvas: any ToolCanvas) -> Set<ComponentRef>

  func mouseEntered(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)
  func mouseExited(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)
  func mouseMoved(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)
  func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)
  func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)
  func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent)

  func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent)
  func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent)
  func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent)
}

extension CanvasTool {
  public static var id: String { Self.toolId }
  public var displayNameKey: String { displayName }
  public var descriptionKey: String { toolDescription }
  /// Upstream's `dflt_cursor` is `CROSSHAIR_CURSOR` (`Tool.java:30`).
  public var cursor: NSCursor { .crosshair }
  public func attributeSet(for canvas: any ToolCanvas) -> (any AttributeSet)? { attributeSet }
  public func setAttributeSet(_ attributes: any AttributeSet) {}
  public func select(_ canvas: any ToolCanvas) {}
  public func deselect(_ canvas: any ToolCanvas) {}
  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    ToolOverlay(items: [], hiddenComponents: hiddenComponents(for: canvas))
  }
  public func hiddenComponents(for canvas: any ToolCanvas) -> Set<ComponentRef> { [] }
  public func mouseEntered(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func mouseExited(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func mouseMoved(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {}
  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {}
  public func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {}
  public func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {}
}
