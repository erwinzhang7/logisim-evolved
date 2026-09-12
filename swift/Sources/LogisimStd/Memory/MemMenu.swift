// MemMenu.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.MemMenu),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── UI seam ──────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `MemMenu implements ActionListener, MenuExtender` builds a `JPopupMenu` with four
// items (Edit/Clear/Load/Save) against a live `Project`/`Frame`/`CircuitState`; none of which
// exist in this port yet (`Project` and `CircuitState` are M7/M3 machinery). What survives that
// gap, and is ported below, is the one piece of real logic `MemMenu` has: **Clear** skips its
// confirmation dialog when the contents are already all zero, and otherwise actually clears
// them. Edit/Load/Save have no logic of their own upstream beyond "construct a UI object and
// show it" (`Mem.getHexFrame` → a `HexFrame` window; `HexFile.open`/`HexFile.save` → a file
// chooser plus serialization); exactly the hex-editor UI this task says not to port. This file
// hands back what each of those needs (the `MemContents` to read from or write into) and stops
// there; building the window, the file dialog, and wiring `configureMenu`'s four `JMenuItem`s to
// an actual `JPopupMenu`/`NSMenu` is the M6/M7 owner's job.
//
// `RomAttributes.setProject(proj)`, upstream's `configureMenu` reaches into the component's
// attribute set to hand it the current `Project` so the ROM's own menu items work later, is
// pure editing-session wiring, not menu logic, and is dropped with the same reasoning as
// `MemPoker`'s identical drop of the same call (see that file's header).
//
// ── Assumed API from `MemState`/`MemContents` (owned by the Mem/Ram/Rom slice) ─────────────
//
//   `MemState.contents: MemContents`      (`getContents()`)
//   `MemContents.isClear: Bool`           (`isClear()`)
//   `MemContents.clear()`

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.MemMenu`: the RAM/ROM right-click menu's model half.
///
/// One instance per placed component, exactly as upstream constructs one `MemMenu` per
/// `(factory, instance)` pair. Holds no UI state (no `JMenuItem`s, no `Frame`): see the file
/// header for why.
public final class MemMenu {

  /// `MemMenu.factory`. Unused by the logic below (Clear only needs the `MemState`), kept for
  /// structural fidelity with upstream's field and because a future `getHexFrame`-equivalent
  /// wiring will need it.
  private let factory: any ComponentFactory
  private unowned let component: StdInstanceComponent

  public init(factory: any ComponentFactory, component: StdInstanceComponent) {
    self.factory = factory
    self.component = component
  }

  /// Whether the four menu items should be enabled at all: upstream's
  /// `enabled = circState != null`, i.e. whether there is a running simulation session to poke.
  /// The caller supplies this because `CircuitState` (M3) is not visible from this module.
  public func isEnabled(hasCircuitState: Bool) -> Bool {
    hasCircuitState
  }

  // MARK: Clear — the one action with real logic

  /// `doClear`'s guard: `if (s.getContents().isClear()) return;` before ever showing the
  /// confirmation dialog.
  public func clearRequiresConfirmation(_ state: MemState) -> Bool {
    !state.contents.isClear
  }

  /// `doClear`'s effect, once the caller has confirmed (or determined via
  /// `clearRequiresConfirmation` that no confirmation was needed).
  public func performClear(_ state: MemState) {
    state.contents.clear()
  }

  // MARK: Edit / Load / Save — hand-off points only

  /// What `doEdit` (`factory.getHexFrame(proj, instance, circState)`), `doLoad`
  /// (`HexFile.open`), and `doSave` (`HexFile.save`) all actually operate on. None of the three
  /// upstream methods do anything else; the hex-editor window and file dialogs are UI (M6/M7)
  /// and not built here.
  public func contentsForEditing(_ state: MemState) -> MemContents {
    state.contents
  }
}
