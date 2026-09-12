// HexWindow.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.hex.HexFrame and the two window
// registries in com.cburch.logisim.std.memory.RomAttributes/Ram/DualRam),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ HOW THIS GETS OPENED ═══════════════════════════════════════════════════════════════════
//
// It is opened. This header used to say the menu item was left to an integrator, and for a while
// that was true: `open(contents:project:title:)` had ZERO call sites across 697 `Sources` files,
// and the scene registration in `LogisimEvolvedApp.swift:93` carried a comment pointing at an
// `AppCommands` item that had never been written. Board #93.
//
// The way in now is Edit ▸ Edit Contents… (`AppCommands.swift`, `EditMemoryContentsItem`), which
// calls `open(component:in:)` below. That overload is the one that does the seam-legal work: the
// shell holds a `ComponentID`, the window wants a `MemContents`, and only the *host* may turn one
// into the other (`ProjectSeam.swift:8`). See `MemoryContentsSeam.swift`.
//
// The programmatic entry point is unchanged and is still what every test drives:
//
//     let editor = controller.open(contents: state.contents, project: project, title: "ROM")
//
// and `HexWindowScene(controller:)` is a ready `Scene`.
//
// What is still NOT wired: the component's right-click menu. 4.1.0 reaches the hex editor from
// there and only from there (`MemMenu.configureMenu`; the item is `ramEditMenuItem` = "Edit
// Contents…"). `Tools/MenuTool.swift` is owned elsewhere, so that route is reported as exact
// lines rather than applied. The double-click route does not exist upstream at all, 4.1.0
// double-click on a memory pokes it (`MemPoker`), it does not open the editor, so the
// `ContentUnavailableView` below telling the user to double-click is wrong on both counts and is
// corrected to name the menu item.
//
// ── One window, a registry of editors ───────────────────────────────────────────────────────
//
// Upstream keeps a `WeakHashMap<MemContents, HexFrame>` per memory family (`RomAttributes`,
// `Ram`, `DualRam` each have their own) so that re-opening the same memory raises the window that
// is already showing it rather than making a second one. That map is why `MemContents.swift`'s
// header says identity matters for the class.
//
// The same rule is kept, with one difference forced by SwiftUI: a `Window(id:)` scene is a
// singleton, so there is one *window* and a registry of *editor models* behind it. Re-opening a
// memory restores that memory's caret and scroll position, which is the user-visible half of what
// the registry buys upstream. Keying is by `ObjectIdentifier`, which is `WeakHashMap`'s identity
// semantics exactly: never by value, since two ROMs holding equal bytes are two ROMs.
//
// The registry holds editors **strongly**, unlike the weak Java map. It is bounded by
// `closeEditor(for:)`, which the integrator must call from the same place `Ram.closeHexFrame` and
// `RomAttributes.closeHexFrame` are called; component removal and circuit reset. That call is
// already modelled in the kernel as `SimHexFrameOwner.closeHexFrame()`
// (`LogisimKernel/Propagation/ComponentState.swift:78`), which today has no conformer that does
// anything; wiring it here is the second handoff line.

import AppKit
import LogisimStd
import SwiftUI
import UniformTypeIdentifiers

/// `RomAttributes.windowRegistry` + `getHexFrame`/`closeHexFrame`, as one object.
@MainActor
@Observable
public final class HexWindowController {

  /// The editor currently on screen, if any.
  public private(set) var current: HexEditorModel?

  /// `HexFrame`'s title. Upstream's is the constant `S.get("hexFrameTitle")` = "Hex Editor"; the
  /// component's label is appended here because one window now serves every memory in the file
  /// and "which one am I looking at" stops being answerable from the window itself otherwise.
  public private(set) var title = "Hex Editor"

  /// The last error a file operation produced, for the window to show. Upstream puts these in an
  /// `OptionPane`; surfacing it as state keeps the panel-free path testable.
  public var failure: String?

  @ObservationIgnored private var editors: [ObjectIdentifier: HexEditorModel] = [:]

  public init() {}

  /// `Mem.getHexFrame(Project, Instance, CircuitState)` → `RomAttributes.getHexFrame`.
  ///
  /// Returns the editor either way, so a caller that wants to drive it (a test, or a future
  /// "jump to address" command) has it without reaching back through `current`.
  @discardableResult
  public func open(contents: MemContents, project: Project? = nil, title: String? = nil)
    -> HexEditorModel
  {
    let key = ObjectIdentifier(contents)
    let editor: HexEditorModel
    if let existing = editors[key] {
      editor = existing
    } else {
      editor = HexEditorModel(contents: contents, project: project)
      editors[key] = editor
    }
    self.title = title.map { "Hex Editor — \($0)" } ?? "Hex Editor"
    self.failure = nil
    self.current = editor
    return editor
  }

  /// `MemMenu.doEdit()`: `factory.getHexFrame(proj, instance, circState).setVisible(true)`.
  ///
  /// This is the call site the file header above said it deliberately left to the integrator, and
  /// it is now taken up; the three lines the handoff listed are the two below plus the menu item
  /// in `AppCommands`. The `ComponentID` → `MemContents` step is the host's, not this type's:
  /// `ProjectSeam.swift:8` forbids the shell from seeing a `Component`, so the resolution happens
  /// behind `MemoryContentsProviding` and only `EditableMemory` crosses.
  ///
  /// Returns `nil` when the selection is not a memory this actor can reach; see
  /// `MemoryContentsSeam.swift`'s header for exactly when that is and why.
  @discardableResult
  public func open<Host: ProjectHost & MemoryContentsProviding>(
    component: ComponentID, in host: Host
  ) -> HexEditorModel? {
    guard let memory = host.editableMemory(for: component) else { return nil }
    let editor = open(contents: memory.contents, project: memory.project, title: memory.title)
    observe(host)
    return editor
  }

  /// Whether a memory already has an editor, `windowRegistry.containsKey(value)`.
  public func hasEditor(for contents: MemContents) -> Bool {
    editors[ObjectIdentifier(contents)] != nil
  }

  // MARK: - Deletion

  /// The observation that makes `closeEditor(for:)` fire. One per host; re-registering for the
  /// same host is a no-op, so opening ten ROMs installs one subscription, not ten.
  @ObservationIgnored private var deletionWatch: (host: ObjectIdentifier, token: ProjectObservation)?

  /// Upstream's `Ram.closeHexFrame` / `RomAttributes.closeHexFrame` are called from
  /// `removeComponent`. This port's shell has no `removeComponent` hook, it learns about
  /// structural change through `ProjectChange.outline`, so the equivalent is: after every
  /// structural change, drop every editor whose memory is no longer placed.
  ///
  /// The diff is what makes this safe to run on *any* change: an editor is only closed when its
  /// `MemContents` has genuinely left the circuit.
  private func observe<Host: ProjectHost & MemoryContentsProviding>(_ host: Host) {
    let key = ObjectIdentifier(host)
    guard deletionWatch?.host != key else { return }
    let token = host.addObserver { [weak self, weak host] change in
      guard change.contains(.outline) || change.contains(.geometry) else { return }
      guard let self, let host else { return }
      self.closeEditorsNotIn(host.liveMemoryIdentities)
    }
    deletionWatch = (key, token)
  }

  /// `closeHexFrame` for everything that vanished. Public so a test can drive the deletion path
  /// without building a host, and so an integrator wiring a second host has the primitive.
  public func closeEditorsNotIn(_ live: Set<ObjectIdentifier>) {
    for key in editors.keys where !live.contains(key) {
      let editor = editors.removeValue(forKey: key)
      if current === editor { current = nil }
    }
  }

  /// `RomAttributes.closeHexFrame(MemContents)` / `Ram.closeHexFrame(RamState)`: drop the window
  /// for one memory, because the component holding it is going away.
  public func closeEditor(for contents: MemContents) {
    let key = ObjectIdentifier(contents)
    guard let editor = editors.removeValue(forKey: key) else { return }
    if current === editor { current = nil }
  }

  /// The Close button; `processWindowEvent(WINDOW_CLOSING)`. The editor stays in the registry,
  /// matching `HexFrame`'s `HIDE_ON_CLOSE`.
  public func close() {
    current = nil
  }
}

/// The Hex Editor window as a `Scene`, ready to add to the app's `body`.
public struct HexWindowScene: Scene {
  /// The scene identifier, so `openWindow(id:)` can raise it.
  public static let sceneID = "hex-editor"

  private var controller: HexWindowController

  public init(controller: HexWindowController) {
    self.controller = controller
  }

  public var body: some Scene {
    Window("Hex Editor", id: HexWindowScene.sceneID) {
      HexWindow(controller: controller)
    }
    .defaultSize(width: 620, height: 520)
  }
}

/// `HexFrame`'s content: the grid, and the Open/Save/Close button row.
public struct HexWindow: View {
  @Bindable private var controller: HexWindowController

  public init(controller: HexWindowController) {
    self.controller = controller
  }

  public var body: some View {
    VStack(spacing: 0) {
      if let editor = controller.current {
        HexGridView(model: editor)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("No Memory Open", systemImage: "memorychip")
        } description: {
          Text("Select a ROM in a circuit, then choose Edit ▸ Edit Contents….")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if let failure = controller.failure {
        Text(failure)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.top, 8)
      }

      Divider()

      // `HexFrame`'s `buttonPanel`: open, save, close, in that order, same labels.
      HStack {
        Button("Open…") { openImage() }
        Button("Save…") { saveImage() }
        Spacer()
        Button("Close") { controller.close() }
      }
      .disabled(controller.current == nil)
      .padding(12)
    }
    .navigationTitle(controller.title)
  }

  /// `MyListener.actionPerformed`'s `src == open` arm → `HexFile.open(model, frame, proj,
  /// instance)`, which is a file chooser plus `HexFile.open(dst, file)`.
  private func openImage() {
    guard let editor = controller.current else { return }
    let panel = NSOpenPanel()
    panel.title = "Load Memory Image"  // `S.get("ramLoadDialogTitle")`
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try editor.loadImage(from: url)
      controller.failure = nil
    } catch {
      // `OptionPane.showMessageDialog(parent, e.getMessage(), S.get("ramLoadErrorTitle"), …)`.
      controller.failure = error.localizedDescription
    }
  }

  /// `src == save` → `HexFile.save(model, frame, proj, instance)`.
  private func saveImage() {
    guard let editor = controller.current else { return }
    let panel = NSSavePanel()
    panel.title = "Save Memory Image"  // `S.get("ramSaveDialogTitle")`
    panel.nameFieldStringValue = "memory.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try editor.saveImage(to: url)
      controller.failure = nil
    } catch {
      controller.failure = error.localizedDescription
    }
  }
}
