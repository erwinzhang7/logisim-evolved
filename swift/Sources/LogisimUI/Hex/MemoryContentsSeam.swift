// MemoryContentsSeam.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.Mem.getHexFrame,
// RomAttributes.getHexFrame/closeHexFrame/register, Ram.getHexFrame, MemMenu.doEdit),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: the shipping 4.1.0 jar,
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar (D16). Every
// citation below was taken from it with `javap -c -p` / `unzip -p`, NOT from `src/main/java`,
// which is upstream main.
//
// ══ WHY THIS FILE EXISTS AT ALL ════════════════════════════════════════════════════════════
//
// `HexWindowController.open(contents:project:title:)` had ZERO call sites in `Sources`. The
// window was finished, the model was finished, and nothing joined them, because joining them
// needs one thing neither side may do: turn a `ComponentID` (all the shell has) into a
// `MemContents` (all the window wants): and `ProjectSeam.swift:8` forbids the shell from ever
// seeing a `Circuit`, a `Component`, an `AttributeSet` or a `CircuitState` to do it with.
//
// So the resolution happens on the *host* side of the seam, and what crosses is a value
// (`EditableMemory`) plus the one live object the hex editor's whole design is built on not
// copying. `MemContents` is not in the seam's forbidden list and cannot be: `HexEditorModel`
// holds the very object the placed component holds, which is the property board #47 made
// load-bearing and `HexEditorModel.swift:22` states in capitals.
//
// ══ ROM YES, RAM NOT YET, AND THE REASON IS MEASURED, NOT ASSUMED ═════════════════════════
//
// 4.1.0 has two `getHexFrame` bodies and they read their contents from two different places:
//
//   RomAttributes.getHexFrame(MemContents, Project, Instance)   ← the ATTRIBUTE SET
//   Ram.getHexFrame(Project, Instance, CircuitState)            ← `instance.getData(circState)`
//                                                                 cast to `RamState`
//
// (`javap -p …Rom/Ram/RomAttributes` over the 4.1.0 jar.) A ROM's words live in its
// `AttributeSet` and are what the `.circ` file stores; a RAM's live in a `RamState`, which is
// `InstanceData` hanging off a `CircuitState`.
//
// This port has no main-thread `CircuitState`. `SimulationEngine.currentState` is owned by the
// propagation thread and `LogisimFileProjectHost.swift:779` says in as many words that "the main
// actor must not read" it; `CircuitEditorCanvas.circuitState`, the one `ToolCircuitState` seam
// that would have been the main-thread route, has **zero assignments anywhere in `Sources`**
// (`grep -rn "circuitState =" swift/Sources/LogisimUI/` → one hit, and it is in
// `CircuitAnalysis.swift`, a different state entirely).
//
// A RAM therefore has no `MemContents` this actor may legally reach today. `editableMemory`
// returns `nil` for one and the menu item greys out, with `unreachableReason` carrying the
// sentence a user gets in the tooltip. That is the honest state; inventing a `MemContents` for
// the RAM (which is, note, what upstream's own `ramState == null` arm does; it opens a hex
// frame over a brand-new `getNewContents(attrs)` that is attached to nothing) would produce an
// editor whose edits go nowhere, which is worse than a greyed item.
//
// ══ UNDO: THE ASYMMETRY IS UPSTREAM'S ══════════════════════════════════════════════════════
//
// `RomContentsListener.bytesChanged` calls `proj.doAction(new Change(…))`: verified in the
// 4.1.0 bytecode, `invokevirtual com/cburch/logisim/proj/Project.doAction`. It is installed by
// `RomAttributes.register(MemContents, Project)` and by nothing else: `Ram.getHexFrame` never
// registers one. So in 4.1.0 a ROM edit made in the hex window is undoable and a RAM edit is
// not. `HexEditorModel.swift:71-76` already carries that rule; this file is where the `Project`
// that switches it on gets chosen, so the choice is stated once, here, with the citation.

import Foundation
import LogisimStd

/// What a `ComponentID` resolves to when the component is a memory whose words this actor may
/// touch: `Mem.getHexFrame`'s two arguments, as a value.
@MainActor
public struct EditableMemory {

  /// The live words of the placed component. **Not a copy.** Writing through this is what makes
  /// the hex editor edit the circuit rather than a scratch buffer.
  public let contents: MemContents

  /// `RomAttributes.register`'s `proj`, or `nil` where upstream registers no
  /// `RomContentsListener` and the edit is therefore not undoable. See the file header.
  public let project: Project?

  /// What to put after "Hex Editor: " in the title bar. Upstream's title is the bare constant
  /// `S.get("hexFrameTitle")` = "Hex Editor" (`gui.properties:145` in the 4.1.0 jar); this port
  /// has one window for the whole file rather than one `HexFrame` per memory, so the window has
  /// to say which memory it is showing. `HexWindowController.open` already documents that.
  public let title: String

  public init(contents: MemContents, project: Project?, title: String) {
    self.contents = contents
    self.project = project
    self.title = title
  }
}

/// The host-side half of the join. Implemented by `LogisimFileProjectHost`, whose file is where
/// the `Component` lookup that this cannot do lives.
///
/// Deliberately a **separate** protocol rather than three more members on `ProjectHost`:
/// `ProjectSeam.swift` is owned elsewhere, and, more to the point, a host that cannot open a
/// hex editor (a headless one under `logisim-cli`) should not have to say so by implementing
/// three stubs.
@MainActor
public protocol MemoryContentsProviding: AnyObject {

  /// `Mem.getHexFrame(proj, instance, circState)`, up to but not including making the window.
  /// `nil` when the component is not a memory, is not in the current circuit any more, or is a
  /// memory whose contents are not reachable from this actor (see the file header).
  func editableMemory(for component: ComponentID) -> EditableMemory?

  /// Why `editableMemory` said `nil` for something that *is* a memory, for the menu item's
  /// tooltip. `nil` when the component is not a memory at all; there is nothing to explain.
  func memoryUnreachableReason(for component: ComponentID) -> String?

  /// Identity of every memory currently placed in the edited circuit.
  ///
  /// This is what makes `HexWindowController.closeEditor(for:)` reachable: upstream calls
  /// `Ram.closeHexFrame(RamState)` / `RomAttributes.closeHexFrame(MemContents)` from
  /// `removeComponent`, and this port has no `removeComponent` hook on the shell side, so the
  /// controller diffs this set against its registry after every structural change instead.
  /// Same effect, one indirection more.
  var liveMemoryIdentities: Set<ObjectIdentifier> { get }
}

extension ProjectHost {

  /// The single selected component, or `nil`: the enablement rule for
  /// `MemMenu.configureMenu`, which is built for exactly one `Instance`.
  public var singleSelectedComponent: ComponentID? {
    guard case .components(let ids) = selection, ids.count == 1 else { return nil }
    return ids.first
  }
}

/// Everything Edit ▸ Edit Contents… decides, with no SwiftUI in it.
///
/// The decision lives here rather than inside the menu item's `body` on purpose. A `Button` is
/// trivially constructible and a test that asserts one exists proves nothing: this project's
/// recurring false green. Lifting the enablement, the target and the tooltip out of the view
/// leaves the view with two statements (call `open`, call `openWindow`) and leaves the part that
/// can actually be wrong under test.
@MainActor
public enum EditMemoryContentsAvailability: Equatable {

  /// Enabled, and this is the component the command will open.
  case ready(ComponentID)

  /// Greyed. `reason` is the host's sentence when the selection *is* a memory this build cannot
  /// reach; `nil` means the ordinary "nothing suitable is selected".
  case unavailable(reason: String?)

  public var target: ComponentID? {
    if case .ready(let id) = self { return id }
    return nil
  }

  public var isEnabled: Bool { target != nil }

  /// The tooltip. Upstream has none, a `JPopupMenu` on the component *is* the context, so this
  /// is the port answering the question the menu bar creates: why is it grey?
  public var help: String {
    switch self {
    case .ready: return "Open the selected memory in the Hex Editor."
    case .unavailable(let reason): return reason ?? "Select a single ROM to edit its contents."
    }
  }

  /// `MenuListener`'s enablement, computed from the model instead of from a pushed boolean.
  public static func resolve(host: (any ProjectHost & MemoryContentsProviding)?) -> Self {
    guard let host, let id = host.singleSelectedComponent else { return .unavailable(reason: nil) }
    if host.editableMemory(for: id) != nil { return .ready(id) }
    return .unavailable(reason: host.memoryUnreachableReason(for: id))
  }
}
