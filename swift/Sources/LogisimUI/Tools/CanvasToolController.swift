// CanvasToolController.swift: part of logisim-evolved.
//
// The adapter between the canvas host's input seam (`Seams/RenderSeam.swift`) and the ported
// tools. GPL-3.0-only, as the rest of this port is. See LICENSE.md.
//
// Reference tree for the behaviour it routes: upstream-java-4.1.0 (D16).
//
// ── What this file owns ─────────────────────────────────────────────────────────────────────
//
// `RenderSeam.swift` declares `CanvasInteractionHandler` as "what the shell sends back into the
// editing layer … implemented by whatever owns tools and selection". This is that object. It does
// three jobs and nothing else:
//
//   1. converts a `CanvasPointerEvent` (world `CGPoint`, `NSEvent` modifiers) into the integer
//      circuit-coordinate `ToolMouseEvent` the tools expect;
//   2. resolves a physical key press into a `ToolCommandKey`, which is the single place the macOS
//      key bindings live; every deviation from AWT is stated in `ToolCommandKey`'s cases, and
//      this is where those decisions are actually applied;
//   3. keeps the active tool and forwards to it, so the shell never touches a `Tool`.
//
// It deliberately does **not** own the camera, the selection, or the undo stack. Those belong to
// the project layer; see `ToolSeams.swift`.

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// Routes canvas input to the active tool.
@MainActor
public final class CanvasToolController: CanvasInteractionHandler {

  private unowned let canvas: any ToolCanvas
  /// Typed `any CanvasTool`, not `Tool`: everything this class does with it, mouse, keys,
  /// cursor, overlay, lives on the editing half. See `upgrade(_:)` for how a `Tool` taken out of
  /// a `Library` becomes one.
  public private(set) var activeTool: any CanvasTool

  /// Where a drag started, in circuit coordinates. `CanvasPointerEvent` carries a
  /// `dragOriginWorld`, but the tools maintain their own press point (`SelectTool.start`,
  /// `EditTool.pressX`), so this is only used to synthesise the click count for a drag.
  private var lastPointerModifiers: ToolModifiers = []

  public init(canvas: any ToolCanvas, initialTool: any CanvasTool) {
    self.canvas = canvas
    self.activeTool = initialTool
    initialTool.select(canvas)
  }

  /// Turn a `Tool` from a `Library`, a toolbar or `Project.tool` into one that can drive a canvas.
  ///
  /// **This is the join Java does not need.** Upstream has one `Tool` class carrying both halves,
  /// so the tool the explorer hands over is already drivable. This port splits it, `LogisimFile`
  /// owns the identity half because the `.circ` codec needed it at M2, D9 keeps `NSCursor` and
  /// canvas events out of that module, and the split has to be rejoined exactly here.
  ///
  /// The `AddTool` arm is the one that matters in practice: every library entry is a plain
  /// `LogisimFile.AddTool`, and `CanvasAddTool.canvasTool(for:)` upgrades it while preserving the
  /// factory identity `sharesSource` and `XmlWriter.fromTool` compare on. `nil` means the tool
  /// genuinely has no editing behaviour; the caller should leave the current tool selected
  /// rather than switch to something inert.
  ///
  /// **This arm does not cover the five base editing tools**, and cannot: they are registered as
  /// `BuiltinPlaceholderTool` in `LogisimStd`/`LogisimFile`, which D9 keeps free of canvas events,
  /// so the identity half has no drivable counterpart to hand back statically. Those are resolved
  /// per-controller by `baseTools`, see `setActiveTool(fromLibrary:)`.
  public static func upgrade(_ tool: Tool) -> (any CanvasTool)? {
    if let already = tool as? any CanvasTool { return already }
    if let add = tool as? AddTool { return CanvasAddTool.canvasTool(for: add) }
    return nil
  }

  /// The five base editing tools, by the id the explorer publishes them under.
  ///
  /// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────
  ///
  /// Measured over a real host: of the **162** tools the explorer offers, `upgrade` could drive
  /// **157**. The five it could not were `Edit Tool`, `Menu Tool`, `Poke Tool`, `Wiring Tool` and
  /// `Text Tool`, which is to say every tool a user edits with. Selecting any of them called
  /// `setActiveTool(fromLibrary:)`, got `nil`, and silently left the previous tool active. Placing
  /// components worked; selecting, poking, wiring and labelling did not.
  ///
  /// `Text Tool` is the sharpest version: there are **two** `TextTool` types: `LogisimFile`'s,
  /// a plain `Tool`, and this module's, a real `CanvasTool`. Different modules, so nothing
  /// complains, and the explorer registers the inert one. Same shape as the duplicated
  /// `LedArrayDriving` (board #39), in the tool layer.
  ///
  /// Per-controller rather than static because these carry gesture state, `WiringTool`'s pending
  /// wire, `SelectTool`'s move gesture, which belongs to one canvas, not to the process.
  private lazy var baseTools: [String: any CanvasTool] = {
    let select = SelectTool()
    let wiring = WiringTool()
    return [
      BaseToolIds.select: select,
      BaseToolIds.wiring: wiring,
      BaseToolIds.edit: EditTool(select: select, wiring: wiring),
      BaseToolIds.poke: PokeTool(),
      // `TextTool()`'s `textFactory` defaults to nil, and `createTextComponent` guards on it --
      // so the no-argument form makes every click a silent no-op. The tool takes the factory as a
      // parameter deliberately, so the tool slice need not depend on `std.base.Text` having
      // landed, exactly as `AddTool` does; nothing ever passed it. Found while testing the
      // `Text` painter end to end, and independent of it: a working painter still leaves a user
      // clicking on an empty sheet forever.
      //
      // `Text.factory` is a singleton with a private init, and that is load-bearing under D4 --
      // `AddTool.sharesSource`, `Library.indexOf` and `BaseLibrary.contains` all compare
      // factories with `===`. `BaseLibrary` builds its own `AddTool(factory: Text.factory)` from
      // the same singleton, so passing it here and resolving it through the loaded library give
      // the identical object.
      //
      // MODULE-QUALIFIED, and `import LogisimStd` had to be added to THIS file: imports are
      // per-file, and a bare `Text` here would otherwise resolve to SwiftUI's. That is the same
      // ambiguity class as the two `TextTool` types this controller already has to disambiguate.
      BaseToolIds.textTool: TextTool(textFactory: LogisimStd.Text.factory),
      // `BaseToolIds.menu` was the last hole in this table. It is now a real `MenuTool`, and note
      // that a user essentially never selects it from the explorer: the default template binds it
      // to Button3 and Ctrl-Button1 (`NewProjectTemplate.swift`'s `<mappings>`), so the way it is
      // actually reached is `contextMenu(atWorldPoint:)` below. Registering it here is still
      // load-bearing: `.circ` files name it in `<mappings>`/`<toolbar>`, and a file that does
      // has to resolve to something drivable.
      BaseToolIds.menu: MenuTool(),
    ]
  }()

  /// The `MenuTool` instance this controller drives, for the right-click path.
  ///
  /// Reached through `baseTools` rather than stored separately so there is exactly one, and so
  /// selecting `Menu Tool` in the explorer and right-clicking use the same object, which is what
  /// makes `lastMenu` a single, unambiguous record of the last menu raised.
  public var menuTool: MenuTool {
    // Force-unwrapped deliberately: the table above is a literal in this file, so an absent key
    // is a programmer error no user input can reach (D13's "left trapping" category).
    baseTools[BaseToolIds.menu] as! MenuTool
  }

  /// Switching tools runs `deselect` then `select`, in that order, which is what lets a tool
  /// clean up a half-finished gesture (`WiringTool.reset`, `SelectTool.moveGesture = nil`).
  public func setActiveTool(_ tool: any CanvasTool) {
    guard tool !== activeTool else { return }
    activeTool.deselect(canvas)
    activeTool = tool
    tool.select(canvas)
    canvas.setCursor(tool.cursor)
  }

  /// `setActiveTool` for a tool that has not been upgraded yet. A tool with no editing behaviour
  /// is ignored rather than replacing a working one; see `upgrade(_:)`.
  @discardableResult
  public func setActiveTool(fromLibrary tool: Tool) -> Bool {
    // Placeholders first. A `BuiltinPlaceholderTool` carries only a name, so `upgrade` can say
    // nothing about it; the name IS the id (`BuiltinPlaceholderTool.name` returns its identifier),
    // which is what `baseTools` is keyed on.
    if let base = baseTools[tool.name] {
      setActiveTool(base)
      return true
    }
    guard let upgraded = CanvasToolController.upgrade(tool) else { return false }
    setActiveTool(upgraded)
    return true
  }

  // MARK: - CanvasInteractionHandler

  public func canvasHandlePointer(_ event: CanvasPointerEvent) {
    // `world`, not `snappedWorld`: the tools snap for themselves with Java's exact integer
    // arithmetic, and some of them (SelectTool) deliberately do not snap the pointer at all.
    // See `ToolGeometry.swift`.
    var toolEvent = ToolMouseEvent(
      point: CanvasGrid.circuitPoint(event.world),
      modifiers: ToolModifiers(event.modifiers),
      clickCount: event.clickCount,
      button: event.buttonNumber)
    lastPointerModifiers = toolEvent.modifiers

    switch event.phase {
    case .entered: activeTool.mouseEntered(canvas, &toolEvent)
    case .exited: activeTool.mouseExited(canvas, &toolEvent)
    case .moved: activeTool.mouseMoved(canvas, &toolEvent)
    case .down: activeTool.mousePressed(canvas, &toolEvent)
    case .dragged: activeTool.mouseDragged(canvas, &toolEvent)
    case .up: activeTool.mouseReleased(canvas, &toolEvent)
    }

    canvas.setToolOverlay(activeTool.overlay(for: canvas))
  }

  public func canvasHandleKey(_ event: CanvasKeyEvent) -> Bool {
    var toolEvent = ToolKeyEvent(
      command: CanvasToolController.command(for: event),
      character: event.characters.first,
      rawKeyCode: AwtKeyCodes.virtualKeyCode(for: event),
      modifiers: ToolModifiers(event.modifiers),
      isRepeat: event.isRepeat)

    switch event.phase {
    case .down: activeTool.keyPressed(canvas, &toolEvent)
    case .up: activeTool.keyReleased(canvas, &toolEvent)
    }
    // AWT delivers `keyTyped` as a third event; AppKit does not, so a printable `keyDown` is
    // replayed as one. That ordering, pressed then typed, is AWT's, and the ported components'
    // key configurators depend on it.
    if event.phase == .down, let character = event.characters.first, !character.isNewline,
      !toolEvent.isConsumed
    {
      var typedEvent = toolEvent
      typedEvent.character = character
      activeTool.keyTyped(canvas, &typedEvent)
      if typedEvent.isConsumed { toolEvent.consume() }
    }

    canvas.setToolOverlay(activeTool.overlay(for: canvas))
    return toolEvent.isConsumed
  }

  public func canvasDropTool(_ tool: ToolID, atWorldPoint point: CGPoint) {
    // Dropping a tool from the explorer is a shell gesture: it selects the tool and then
    // synthesises a press/release at the drop point, which is exactly what a click with that tool
    // would have done. The shell resolves the `ToolID` and calls `setActiveTool` first; this hook
    // exists so the drop lands as a real placement rather than a special-cased add.
    var pressEvent = ToolMouseEvent(point: CanvasGrid.circuitPoint(point))
    activeTool.mousePressed(canvas, &pressEvent)
    activeTool.mouseReleased(canvas, &pressEvent)
    canvas.setToolOverlay(activeTool.overlay(for: canvas))
  }

  public func canvasCursor(atWorldPoint point: CGPoint) -> NSCursor {
    activeTool.cursor
  }

  /// The right-click menu, which is upstream's `MenuTool` reached through the default mouse
  /// mapping rather than through the toolbar.
  ///
  /// **Why the active tool is not consulted and not changed.** `Canvas.MyListener.mousePressed`
  /// resolves the *button* to a tool (`mappings.getToolFor(e.getModifiersEx())`), runs that tool's
  /// `mousePressed`, and, for any button but the primary, temporarily swaps `proj.getTool()`
  /// and restores it on release. Net effect: a right-click raises MenuTool's menu and leaves the
  /// user's tool selected. This does the same thing without the swap, because AppKit's contextual
  /// menu is a return value rather than a gesture the tool has to own.
  ///
  /// `nil` means "no menu" and must stay distinguishable from "an empty menu": upstream shows
  /// **nothing at all** on bare canvas, measured against 4.1.0, and an empty `NSMenu` would flash
  /// a one-pixel panel instead.
  public func canvasContextMenu(atWorldPoint point: CGPoint) -> NSMenu? {
    let circuitPoint = CanvasGrid.circuitPoint(point)
    let location = Location.create(circuitPoint.x, circuitPoint.y, hasToSnap: false)
    guard let menu = MenuTool.menu(for: canvas, at: location) else { return nil }
    menuTool.setLastMenu(menu)
    return MenuTool.makeNSMenu(menu, on: canvas)
  }

  // MARK: - Key binding

  /// **The macOS key map.** Every entry's AWT original is documented on the corresponding
  /// `ToolCommandKey` case; this function is where those decisions become code, so that changing
  /// a binding means changing one line here and one comment there.
  static func command(for event: CanvasKeyEvent) -> ToolCommandKey? {
    let modifiers = ToolModifiers(event.modifiers)

    switch event.keyCode {
    case AppleKeyCodes.delete, AppleKeyCodes.forwardDelete:
      return .deleteSelection
    case AppleKeyCodes.upArrow:
      return .face(.north)
    case AppleKeyCodes.downArrow:
      return .face(.south)
    case AppleKeyCodes.rightArrow:
      return .face(.east)
    case AppleKeyCodes.leftArrow:
      return .face(.west)
    case AppleKeyCodes.escape:
      return .cancelPlacement
    case AppleKeyCodes.space:
      // AWT: Ctrl-Space. Command-Space is Spotlight and Control-Space switches input source, so
      // neither literal translation survives; Option-Space is the free adjacent chord.
      return modifiers.contains(.option) ? .rotateSelection : nil
    case AppleKeyCodes.keyD:
      // AWT: bare Insert, a key Mac keyboards do not have.
      return modifiers.contains(.command) ? .duplicateSelection : nil
    case AppleKeyCodes.keyR:
      return modifiers.isEmpty ? .rotatePendingComponent : nil
    case AppleKeyCodes.keyX:
      return modifiers.isEmpty ? .toggleMatrixPlacement : nil
    case AppleKeyCodes.option:
      return .wiringOverrideModifierChanged
    case AppleKeyCodes.shift:
      return .keepConnectionsModifierChanged
    default:
      return nil
    }
  }
}

/// The AppKit virtual key codes this file compares against.
///
/// Named constants rather than literals because `NSEvent.keyCode` is a hardware scan code with no
/// symbolic API in AppKit, and a bare `0x33` in a `switch` is unreviewable.
enum AppleKeyCodes {
  static let keyD: UInt16 = 0x02
  static let keyR: UInt16 = 0x0F
  static let keyX: UInt16 = 0x07
  static let space: UInt16 = 0x31
  static let delete: UInt16 = 0x33
  static let escape: UInt16 = 0x35
  static let forwardDelete: UInt16 = 0x75
  static let leftArrow: UInt16 = 0x7B
  static let rightArrow: UInt16 = 0x7C
  static let downArrow: UInt16 = 0x7D
  static let upArrow: UInt16 = 0x7E
  static let shift: UInt16 = 0x38
  static let option: UInt16 = 0x3A
}

/// AWT `KeyEvent.VK_*` values, for the component key configurators.
///
/// `tools/key` is not ported yet (see `SelectTool.keyConfiguratorDispatch`), but when it is, its
/// eight classes genuinely switch on `VK_*` constants: `VK_EQUALS` to widen a gate, `VK_MINUS`
/// to narrow it, digits to set a bit width. Those are *component* bindings, not application ones,
/// and remapping them would change what a keystroke writes into a saved file. So the raw code is
/// carried across the seam and the mapping lives here, in one table, rather than being invented
/// per configurator later.
enum AwtKeyCodes {
  static func virtualKeyCode(for event: CanvasKeyEvent) -> Int {
    // AWT's VK_ values coincide with ASCII for digits and uppercase letters, which covers every
    // configurator binding in 4.1.0.
    if let scalar = event.characters.unicodeScalars.first {
      let upper = Character(scalar).uppercased().unicodeScalars.first?.value ?? scalar.value
      if (48...57).contains(upper) || (65...90).contains(upper) { return Int(upper) }
    }
    switch event.keyCode {
    case AppleKeyCodes.space: return 32  // VK_SPACE
    case AppleKeyCodes.escape: return 27  // VK_ESCAPE
    case AppleKeyCodes.delete: return 8  // VK_BACK_SPACE
    case AppleKeyCodes.forwardDelete: return 127  // VK_DELETE
    case AppleKeyCodes.leftArrow: return 37  // VK_LEFT
    case AppleKeyCodes.upArrow: return 38  // VK_UP
    case AppleKeyCodes.rightArrow: return 39  // VK_RIGHT
    case AppleKeyCodes.downArrow: return 40  // VK_DOWN
    case AppleKeyCodes.shift: return 16  // VK_SHIFT
    case AppleKeyCodes.option: return 18  // VK_ALT
    default: return 0
    }
  }
}
