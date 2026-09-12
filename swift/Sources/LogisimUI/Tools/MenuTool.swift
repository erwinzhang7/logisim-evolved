// MenuTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.MenuTool, and its inner
// MenuComponent / MenuSelection classes), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHAT THIS TOOL ACTUALLY IS ══════════════════════════════════════════════════════════════
//
// `MenuTool` is the fifth base editing tool, and the only one a user essentially never selects.
// It is bound to the **right mouse button** by the default project template's mouse mappings;
// `resources/logisim/default.templ` has, verbatim:
//
//     <tool lib="8" name="Menu Tool" map="Button3" />
//     <tool lib="8" name="Menu Tool" map="Ctrl Button1" />
//
// and `Canvas.MyListener.mousePressed` resolves the button through
// `MouseMappings.getToolFor(e.getModifiersEx())` before dispatching. So "the canvas contextual
// menu" and "MenuTool" are the same object upstream; this port's `NewProjectTemplate` already
// writes the identical `<mappings>` block, which is why the id had to be reachable at all.
//
// ── MEASURED, NOT INFERRED ──────────────────────────────────────────────────────────────────
//
// Every rule below was read off 4.1.0 running from
// `/Applications/Logisim-evolution.app/.../logisim-evolution-4.1.0-all.jar`, driven with
// synthetic CGEvents against a three-AND-gate / one-Pin / two-wire circuit. The four cases and
// what the real app produced:
//
//   | gesture                                          | menu 4.1.0 shows                          |
//   |--------------------------------------------------|-------------------------------------------|
//   | right-click an UNSELECTED AND gate                | Rotate Left · Rotate Right · Delete ·     |
//   |                                                   | Show Attributes                           |
//   | right-click a WIRE                                | Delete · Show Attributes                  |
//   | right-click EMPTY canvas                          | **nothing at all**, no menu is shown     |
//   | right-click INSIDE a 3-component selection        | Delete Selection · Cut Selection ·        |
//   |                                                   | Copy Selection                            |
//
// A fifth case is the one the brief warned about and it is the reason the dispatch below is
// written the way it is: with three gates selected, right-clicking the **Pin, which is not in the
// selection**, produced the four-item *component* menu, and choosing Delete removed only the Pin
// , the three-gate selection survived untouched, and the title bar gained `[UNSAVED]`, i.e. the
// edit went on the undo stack. So the target is:
//
//   * the SELECTION, only when the click lands inside it **and** the selection holds more than
//     one component;
//   * otherwise the single component under the pointer, selected or not;
//   * and nothing at all on bare canvas.
//
// The wire case is what distinguishes the rotate items: they are **omitted, not disabled**, when
// the component's attribute set has no `StdAttr.FACING`. Everything else upstream greys rather
// than hides, and that asymmetry is reproduced exactly.
//
// ── AND THE PORT WAS DRIVEN THE SAME WAY ────────────────────────────────────────────────────
//
// Not only unit-tested. `logisim-evolved-app`, wrapped in a minimal `.app` bundle (see the
// keyboard note in `CanvasHostNSView.swift` for why a bare executable will not do), was used by
// hand: place an AND gate, right-click it, and the popup that appears is
//
//     Rotate Left · Rotate Right · Delete · Show Attributes
//
// item-for-item what the jar showed. Choosing Delete removed the gate from the canvas and ⌘Z put
// it back. Worth stating because a contextual menu is precisely the kind of thing that can pass
// every test and still never appear on screen; the first right-click in that session returned
// the *shell's* menu instead, because the click landed on the gate's output pin rather than
// inside its body, which is the same `Component.contains` trap `HostCanvasRoutingTests.interior`
// documents.
//
// ── WHERE EACH ITEM'S ACTION GOES ───────────────────────────────────────────────────────────
//
// Every mutating item builds a `CircuitMutation` and hands it to `Project.doAction`, which is
// what serialises the edit against the propagation thread through `modelGuard` (D1). Nothing
// here touches a `Circuit` directly. Delete/Cut/Copy on a selection go through the ported
// `SelectionActions`, which is where upstream puts them too.
//
// ── D9 ──────────────────────────────────────────────────────────────────────────────────────
//
// `NSMenu` is AppKit and this file is in `LogisimUI`, so building one here is allowed. What is
// *not* allowed is letting menu construction leak downward, and the shape that keeps it out is
// the split below:
//
//   * `MenuToolMenu` / `MenuToolItem` are a **plain value description** of the menu: kind,
//     title, enabled. No AppKit. This is what the tests assert on and what a component would
//     contribute to.
//   * `MenuTool.makeNSMenu(...)` is the only place an `NSMenu` is built, and it consumes that
//     description.
//   * upstream's `MenuExtender`, the hook that lets a component add its own items, is NOT
//     ported and no protocol is declared for it. See the MenuExtender section below for the
//     measurement that made that the right call.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - The menu description

/// One item of the contextual menu, as a value.
///
/// `kind` exists so a test can assert *which* item without matching on English, exactly as
/// `ToolStatusMessage` does for the canvas status strip.
public struct MenuToolItem: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    // `MenuComponent`
    case rotateLeft
    case rotateRight
    case delete
    case showAttributes
    // `MenuSelection`
    case deleteSelection
    case cutSelection
    case copySelection
    // There is deliberately no `contributed` case for upstream's `MenuExtender` items: nothing
    // can produce one in this build, and an enum case no value inhabits is a switch arm every
    // reader has to reason about for nothing. See the MenuExtender section above.
  }

  public let kind: Kind
  /// The upstream `Strings.S` key, kept for the same reason `ToolActionName` keeps its key.
  public let titleKey: String
  /// The `en` bundle's rendering of `titleKey`. See `ToolActionName.displayName` for why the
  /// rendering happens here rather than at display time.
  public let title: String
  /// Upstream **greys rather than hides**; `isEnabled == false` is a visible, dead item.
  public let isEnabled: Bool

  public init(kind: Kind, titleKey: String, title: String, isEnabled: Bool) {
    self.kind = kind
    self.titleKey = titleKey
    self.title = title
    self.isEnabled = isEnabled
  }
}

/// What the click resolved to. `MenuComponent` and `MenuSelection` upstream.
public enum MenuToolTarget {
  /// `new MenuComponent(proj, circ, comp)`: the one component the items act on.
  case component(any Component)
  /// `new MenuSelection(proj)`: the items act on `proj.getSelection()` as a whole.
  case selection
}

/// The whole menu: what it targets and what it offers.
public struct MenuToolMenu {
  public let target: MenuToolTarget
  public let items: [MenuToolItem]

  /// The circuit the menu was raised over. `MenuComponent` keeps this to answer
  /// `viewComponentAttributes(circ, comp)`; the *mutations* deliberately go to
  /// `proj.getCurrentCircuit()` instead, which is upstream's own shadowing in
  /// `MenuComponent.actionPerformed`.
  public let circuit: Circuit

  public var component: (any Component)? {
    if case .component(let c) = target { return c }
    return nil
  }

  public func item(_ kind: MenuToolItem.Kind) -> MenuToolItem? {
    items.first { $0.kind == kind }
  }

  public var kinds: [MenuToolItem.Kind] { items.map(\.kind) }
}

// MARK: - MenuExtender — NOT ported, and deliberately not stubbed either
//
// Upstream's `MenuTool.mousePressed` ends each component branch with
//
//     final var extender = (MenuExtender) comp.getFeature(MenuExtender.class);
//     if (extender != null) extender.configureMenu(menu, proj);
//
// Ten types implement `MenuExtender` in 4.1.0: `Splitter`, `Mem` (RAM/ROM, through `MemMenu`),
// `Pla`, `PlaRom`, `ProgrammableGenerator`, `SubcircuitFactory.CircuitFeature`, and the four SoC
// ones (`SocBus`, `SocPio`, `SocVga`, and the `Nios2`/`Rv32imRiscV` pair through
// `SocUpMenuProvider`). **None is ported here, and no extension point is declared for them,
// which is a decision, not an omission.**
//
// The obvious move; declare a `ComponentMenuExtender` protocol now and let components adopt it
// later: was written, measured, and reverted. `tools/seamcheck.py` reported it at once:
//
//     NEW NO CONFORMER  protocol ComponentMenuExtender  (5 references, none conforming)
//
// which is exactly right. A protocol with references and no implementer is the shape this port
// has been burned by nineteen times, and the checker exists to stop one being added on purpose.
//
// What each extender would need before it could contribute an item; i.e. why none of this is a
// small follow-up:
//
//   * `Mem`: "Edit Contents…", which opens the hex editor (`gui/hex`). Unported.
//   * `Pla` / `PlaRom`: the PLA truth-table editor. Unported.
//   * `ProgrammableGenerator`: its own waveform dialog. Unported.
//   * `SubcircuitFactory`: "View <name>", whose action is
//     `proj.setCircuitState(getSubstate(superState, comp))`. `CircuitEditorCanvas` records why
//     that cannot be wired yet: root `CircuitState`s are created on the propagation thread (D1),
//     so `circuitState` is `nil` in the running app and there is no substate to descend into.
//   * `Splitter`; its bit-distribution editor. Unported.
//   * the four SoC ones; the whole subsystem is unported (parity backlog).
//
// So the honest state is a named absence, recorded here and pinned by
// `componentMenuHasNoContributedItemsYet` in `MenuToolTests`; not a half-built seam. When the
// first of those dialogs lands, the hook goes in *with* its conformer and seamcheck stays quiet.

// MARK: - MenuTool

/// `com.cburch.logisim.tools.MenuTool`.
@MainActor
public final class MenuTool: Tool, CanvasTool {

  /// `_ID`. Upstream's comment applies verbatim: this string is written into `.circ` files as a
  /// tool reference, so changing it stops projects loading.
  public override nonisolated class var toolId: String { BaseToolIds.menu }

  public var displayNameKey: String { "menuTool" }
  public var descriptionKey: String { "menuToolDesc" }
  /// Upstream inherits `Tool`'s crosshair. A contextual-menu gesture on macOS keeps the arrow;
  /// this is the same class of deliberate platform deviation `ToolModifiers` documents, and it
  /// changes no mutation.
  public var cursor: NSCursor { .arrow }

  /// The menu the last `mousePressed` produced, or `nil` when the press was on bare canvas.
  ///
  /// Upstream calls `canvas.showPopupMenu(menu, x, y)` from inside `mousePressed`. AppKit
  /// presents contextual menus by *returning* one from `NSView.menu(for:)`, so the tool records
  /// what it built and the shell collects it; see `CanvasToolController.contextMenu(atWorldPoint:)`
  /// for the right-click path, which is how a user actually reaches this tool.
  public private(set) var lastMenu: MenuToolMenu?

  public override init() {}

  // MARK: Mouse

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    lastMenu = MenuTool.menu(for: canvas, at: Location.create(event.x, event.y, hasToSnap: false))
    if lastMenu != nil { event.consume() }
  }

  /// Hands over and clears, so a press that produced no menu cannot re-present the previous one.
  public func takeLastMenu() -> MenuToolMenu? {
    defer { lastMenu = nil }
    return lastMenu
  }

  /// Records a menu raised through the right-click path rather than through `mousePressed`, so
  /// both routes leave the same trace. See `CanvasToolController.contextMenu(atWorldPoint:)`.
  func setLastMenu(_ menu: MenuToolMenu?) { lastMenu = menu }

  // MARK: - The dispatch (`MenuTool.mousePressed`, `MenuTool.java:151-183`)

  /// Which menu a click at `point` raises, or `nil` for none.
  ///
  /// The order of the three tests is upstream's and each one matters: see the file header for
  /// the measured behaviour each reproduces.
  public static func menu(for canvas: any ToolCanvas, at point: Location) -> MenuToolMenu? {
    guard let circuit = canvas.circuit else { return nil }
    let selection = canvas.selection

    // `sel.getComponentsContaining(pt, g)`.
    let inSelection = selection.componentsContaining(point)
    if let first = inSelection.first {
      // `sel.getComponents().size() > 1`: the *whole* selection, not the hits under the pointer.
      // This is the line that makes "select three things, right-click one, Delete" delete three.
      if selection.components.count > 1 {
        return selectionMenu(canvas: canvas, circuit: circuit)
      }
      return componentMenu(canvas: canvas, circuit: circuit, component: first)
    }

    // `canvas.getCircuit().getAllContaining(pt, g)`; note the selection is NOT changed, and a
    // click here targets the component under the pointer even while something else is selected.
    guard let hit = circuit.allContaining(point).first else { return nil }
    return componentMenu(canvas: canvas, circuit: circuit, component: hit)
  }

  /// `MenuComponent`'s constructor (`MenuTool.java:49-67`).
  static func componentMenu(
    canvas: any ToolCanvas, circuit: Circuit, component: any Component
  ) -> MenuToolMenu {
    // `boolean canChange = proj.getLogisimFile().contains(circ)`; false while editing a circuit
    // that belongs to a loaded *library* rather than to this project's own file.
    let canChange = canvas.project.fileContains(circuit)

    var items: [MenuToolItem] = []
    // OMITTED, not disabled, when the component has no facing. Upstream greys everything else;
    // this is the single exception and a wire is the everyday case that hits it.
    //
    // `StdAttr.FACING` directly, NOT `getFacingAttribute(comp)`: upstream's MenuTool does not ask
    // the factory which attribute carries its facing, so a component whose facing lives under a
    // different attribute gets no rotate items here even though `EditTool`'s arrow keys can turn
    // it. Reproduced rather than improved; changing it would add items 4.1.0 does not show.
    if component.attributeSet.containsAttribute(StdAttr.facing) {
      items.append(
        MenuToolItem(
          kind: .rotateLeft, titleKey: "compRotateLeft", title: "Rotate Left", isEnabled: true))
      items.append(
        MenuToolItem(
          kind: .rotateRight, titleKey: "compRotateRight", title: "Rotate Right", isEnabled: true))
    }
    items.append(
      MenuToolItem(
        kind: .delete, titleKey: "compDeleteItem", title: "Delete", isEnabled: canChange))
    // `attrs` is added with no `setEnabled` call, so it is enabled even in a circuit that cannot
    // be modified; viewing attributes is not an edit. Preserved.
    items.append(
      MenuToolItem(
        kind: .showAttributes, titleKey: "compShowAttrItem", title: "Show Attributes",
        isEnabled: true))

    // Upstream appends `extender.configureMenu(menu, proj)` here. Nothing does, in this build,
    // and the absence is pinned by `componentMenuHasNoContributedItemsYet`.
    return MenuToolMenu(target: .component(component), items: items, circuit: circuit)
  }

  /// `MenuSelection`'s constructor (`MenuTool.java:103-118`).
  static func selectionMenu(canvas: any ToolCanvas, circuit: Circuit) -> MenuToolMenu {
    // Upstream asks about `proj.getCurrentCircuit()` here and about `circ` in `MenuComponent`.
    // They are the same circuit on every path that reaches this, but the spelling is kept.
    let canChange = canvas.project.currentCircuit.map { canvas.project.fileContains($0) } ?? false
    return MenuToolMenu(
      target: .selection,
      items: [
        MenuToolItem(
          kind: .deleteSelection, titleKey: "selDeleteItem", title: "Delete Selection",
          isEnabled: canChange),
        MenuToolItem(
          kind: .cutSelection, titleKey: "selCutItem", title: "Cut Selection",
          isEnabled: canChange),
        // Copy is added with no `setEnabled` call; copying out of a read-only circuit is legal.
        MenuToolItem(
          kind: .copySelection, titleKey: "selCopyItem", title: "Copy Selection", isEnabled: true),
      ],
      circuit: circuit)
  }

  // MARK: - The actions (`MenuComponent.actionPerformed`, `MenuSelection.actionPerformed`)

  /// Invoke one item. Everything mutating goes through `Project.doAction`.
  ///
  /// `@discardableResult` reports whether anything was attempted, which is what a test asserts
  /// on before it goes and looks at the model.
  @discardableResult
  public static func perform(
    _ kind: MenuToolItem.Kind, of menu: MenuToolMenu, on canvas: any ToolCanvas
  ) -> Bool {
    let project = canvas.project

    switch kind {
    case .delete:
      guard let component = menu.component else { return false }
      // `proj.getCurrentCircuit()`, not the menu's `circ`. Upstream shadows the field here and
      // the shadowing is preserved rather than tidied away.
      guard let circuit = project.currentCircuit else { return false }
      let mutation = project.beginMutation(on: circuit)
      mutation.remove(component)
      return project.perform {
        mutation.toAction(.removeComponent(component.factory.displayName))
      }

    case .rotateRight, .rotateLeft:
      guard let component = menu.component else { return false }
      guard let circuit = project.currentCircuit else { return false }
      // `comp.getAttributeSet().getValue(StdAttr.FACING)`. Upstream would NPE on a component that
      // offered the item without carrying the attribute; the item is only offered when it does,
      // so this cannot be nil in practice and a nil is a refusal rather than a trap (D13).
      guard let facing = component.attributeSet[StdAttr.facing] else { return false }
      let turned = kind == .rotateRight ? facing.getRight() : facing.getLeft()
      let mutation = project.beginMutation(on: circuit)
      mutation.set(component, StdAttr.facing, turned)
      return project.perform {
        mutation.toAction(.rotateComponent(component.factory.displayName))
      }

    case .showAttributes:
      guard let component = menu.component else { return false }
      showAttributes(of: component, on: canvas)
      return true

    case .deleteSelection:
      return project.perform { SelectionActions.clear(canvas.selection) }

    case .cutSelection:
      return project.perform { SelectionActions.cut(canvas.selection) }

    case .copySelection:
      return project.perform { SelectionActions.copy(canvas.selection) }

    }
  }

  /// `proj.getFrame().viewComponentAttributes(circ, comp)`.
  ///
  /// **A documented divergence, and the reason is structural.** Upstream's `Frame` owns an
  /// attribute table whose target is settable *independently of the selection*
  /// (`AttrTableComponentModel`), so "Show Attributes" points the table at a component without
  /// selecting it. This port's inspector is driven by the selection and there is no second
  /// target; `EditorModel.inspectorForm(for:)` takes the selection and nothing else. With no
  /// independent target the two designs collapse, and the choice is between an item that shows
  /// the attributes (by selecting) and an item that does nothing. Selecting is chosen, because a
  /// dead menu item is the failure mode this whole task exists to remove.
  ///
  /// Note what is preserved: this is **not** an undoable edit. Upstream's is not either, no
  /// `doAction` is involved on this arm, so `SelectionActions.dropAll` is used for its clearing
  /// effect through the project's own path, exactly as `SelectTool.mousePressed` does, and the
  /// `add` that follows is the same non-undoable call the select tool makes.
  static func showAttributes(of component: any Component, on canvas: any ToolCanvas) {
    let selection = canvas.selection
    if selection.components.contains(where: { $0 === component }) { return }
    canvas.project.perform { try SelectionActions.dropAll(selection) }
    selection.add(component)
    canvas.project.repaintCanvas()
  }

  // MARK: - Presentation

  /// The only place an `NSMenu` is built from a `MenuToolMenu`.
  ///
  /// `autoenablesItems = false` because the enablement is upstream's predicate, already computed
  /// into the description; letting AppKit re-derive it from responder-chain validation would
  /// silently replace the ported rule with a different one.
  public static func makeNSMenu(_ menu: MenuToolMenu, on canvas: any ToolCanvas) -> NSMenu {
    let nsMenu = NSMenu()
    nsMenu.autoenablesItems = false
    for item in menu.items {
      let target = MenuToolInvocation(kind: item.kind, menu: menu, canvas: canvas)
      let nsItem = NSMenuItem(
        title: item.title, action: #selector(MenuToolInvocation.invoke), keyEquivalent: "")
      nsItem.target = target
      nsItem.isEnabled = item.isEnabled
      // The item owns its invocation: `NSMenuItem.target` is unowned, so without this the box
      // would be released before the menu is ever shown and the item would do nothing.
      nsItem.representedObject = target
      nsMenu.addItem(nsItem)
    }
    return nsMenu
  }
}

/// The `@objc` trampoline an `NSMenuItem` needs, holding what `MenuTool.perform` requires.
///
/// D3: the canvas is held **unowned**; the canvas owns the controller which owns the tool, and a
/// menu item outliving the canvas is not a case that can occur (the menu is built and shown
/// inside one event loop turn), while a strong edge here would be a retain cycle through the
/// canvas's own view.
@MainActor
final class MenuToolInvocation: NSObject {
  private let kind: MenuToolItem.Kind
  private let menu: MenuToolMenu
  private unowned let canvas: any ToolCanvas

  init(kind: MenuToolItem.Kind, menu: MenuToolMenu, canvas: any ToolCanvas) {
    self.kind = kind
    self.menu = menu
    self.canvas = canvas
  }

  @objc func invoke() {
    MenuTool.perform(kind, of: menu, on: canvas)
  }
}
