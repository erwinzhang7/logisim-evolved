// SelectionEditHandler.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.LayoutEditHandler),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// The canvas's edit surface: which Edit-menu commands are live right now, and what each one does
// to the selection. Upstream this is an `EditHandler` the `Frame` installs; here it is a plain
// object the shell asks, so the same answers are available to a headless driver.
//
// ── Why the enablement rules are ported and not re-derived ──────────────────────────────────
//
// Each one encodes a real precondition, and guessing them produces menu items that are live when
// the command would fail:
//
//   * Everything needs the **Base library** to be loaded, because Paste and Select All both
//     switch the active tool to the Edit tool first and that tool lives in Base.
//   * Everything that *modifies* additionally needs the current circuit to belong to this file;
//     a circuit being viewed out of a loaded library is read-only.
//   * Copy is the one modifying-looking command that is not: it needs a non-empty selection and
//     the Base library, but not a writable circuit.
//   * Paste needs a non-empty clipboard, which is "null **or** empty"; a copy of nothing leaves
//     an empty clipboard object behind, and pasting it would push a no-op onto the undo stack.
//
// The four ordering commands (Raise/Lower/Raise Top/Lower Bottom) and the two control-point
// commands are unconditionally disabled here: they belong to the appearance editor, and upstream
// says so twice; see `isDisabledInLayoutMode` for the 4.1.0 bytecode.
//
// ── That rule was stated here and read nowhere ──────────────────────────────────────────────
//
// This whole class had **no constructor call anywhere in `Sources` or `Tests`** when the rule
// below was written. So the port carried a faithful `LayoutEditHandler` translation that nothing
// could ask, and `LogisimFileProjectHost.canPerform` independently re-derived an answer for the
// same six commands: `return !selection.isEmpty` for four of them. The measured consequence:
// Arrange ▸ Bring Forward / Bring to Front / Send Backward / Send to Back were **live** menu
// items whose `perform` threw `notImplemented`, so a click produced a "Command unavailable"
// banner where 4.1.0 shows a greyed item. The remaining two of the six were disabled, which is
// what made the split hard to see: the port got half of one upstream decision.
//
// `isDisabledInLayoutMode` exists so there is one statement of that rule and the shell can read
// it without owning a canvas. `EditorModel.canPerform` is the reader.
//
// ── macOS conventions ───────────────────────────────────────────────────────────────────────
//
// objectives.md asks for deliberate macOS modifier conventions rather than a literal AWT
// translation. Deliberately, **none are made here**: this file is the command *semantics*, and
// the key equivalents belong on the menu items the shell builds. The mapping this layer implies
// is the standard one, ⌘X ⌘C ⌘V ⌘D ⌘A and Delete, and none of those differ from what the AWT
// menu already binds, so there is nothing to diverge on at this level. The place a real decision
// is due is the drag/duplicate modifier on the canvas (AWT uses Ctrl-drag), and that belongs to
// the tools slice, not to this one.

import Foundation
import LogisimFile
import LogisimKernel

/// The Edit-menu commands `LayoutEditHandler` answers for, named after the `LogisimMenuBar`
/// constants they stand for.
public enum SelectionEditCommand: String, Sendable, CaseIterable {
  case cut = "CUT"
  case copy = "COPY"
  case paste = "PASTE"
  case delete = "DELETE"
  case duplicate = "DUPLICATE"
  case selectAll = "SELECT_ALL"
  /// Appearance-editor only; always disabled in layout mode.
  case raise = "RAISE"
  case lower = "LOWER"
  case raiseTop = "RAISE_TOP"
  case lowerBottom = "LOWER_BOTTOM"
  case addControlPoint = "ADD_CONTROL"
  case removeControlPoint = "REMOVE_CONTROL"
}

/// `com.cburch.logisim.gui.main.LayoutEditHandler`.
///
/// Holds nothing but the project and the selection; every answer is computed on demand, which is
/// what upstream's `computeEnabled()` does on each of the events it listens for.
@MainActor
public final class SelectionEditHandler {

  /// D3: both edges point back up the ownership chain (Project → Frame → Canvas → handler), so
  /// both are weak.
  public weak var project: Project?
  public weak var selection: Selection?

  public init(project: Project?, selection: Selection?) {
    self.project = project
    self.selection = selection
  }

  // MARK: - computeEnabled

  /// `computeEnabled()`, asked one command at a time.
  public func isEnabled(_ command: SelectionEditCommand) -> Bool {
    let selectionIsEmpty = selection?.isEmpty ?? true
    let selectAvailable = isBaseLibraryAvailable
    let canChange = currentCircuitBelongsToThisFile

    switch command {
    case .cut: return !selectionIsEmpty && selectAvailable && canChange
    case .copy: return !selectionIsEmpty && selectAvailable
    case .paste: return selectAvailable && canChange && !Clipboard.isEmpty
    case .delete: return !selectionIsEmpty && selectAvailable && canChange
    case .duplicate: return !selectionIsEmpty && selectAvailable && canChange
    case .selectAll: return selectAvailable
    case .raise, .lower, .raiseTop, .lowerBottom,
      .addControlPoint, .removeControlPoint:
      return !Self.isDisabledInLayoutMode(command)
    }
  }

  /// The six commands `LayoutEditHandler.computeEnabled()` disables **unconditionally**, and the
  /// reason they are a `static` rule rather than an instance answer.
  ///
  /// Verified against the shipping artifact, not against `src/main/java` (which is upstream
  /// *main*, not 4.1.0): `javap -p -c` on
  /// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`,
  /// `com/cburch/logisim/gui/main/LayoutEditHandler.class`:
  ///
  ///   * `computeEnabled()` ends with six consecutive
  ///     `getstatic LogisimMenuBar.{RAISE,LOWER,RAISE_TOP,LOWER_BOTTOM,ADD_CONTROL,REMOVE_CONTROL}`
  ///     / `iconst_0` / `invokevirtual setEnabled` triples (bytecode offsets 255–300). `iconst_0`
  ///     is a literal `false`: no selection, no circuit and no library is consulted for any of
  ///     the six.
  ///   * `raise()`, `lower()`, `raiseTop()`, `lowerBottom()`, `addControlPoint()` and
  ///     `removeControlPoint()` each disassemble to exactly `0: return`; empty method bodies.
  ///
  /// So this is not a gap upstream left open; it is a decision upstream made and stated twice.
  /// The items exist in the Edit menu (`MenuEdit.<init>` adds all six,
  /// `LogisimMenuBar.EDIT_ITEMS`) because the **appearance** editor's handler,
  /// `com.cburch.logisim.gui.appear.AppearanceEditHandler`, implements all six for real; a
  /// `CanvasModel` of draw objects has a z-order, and a `Circuit` does not: it holds its
  /// components in a `Set`, so there is no "front" to bring anything to.
  ///
  /// **`nonisolated static`, and with no `Project` or `Selection` parameter, deliberately.** That
  /// is what lets the shell state the same rule for a menu item without first having to reach a
  /// canvas; see `EditorModel.canPerform`. An instance method here would have forced the shell to
  /// construct a handler it has no ingredients for, which is why the rule was previously
  /// re-derived (wrongly) in the project host instead of being read from this file. `nonisolated`
  /// because the answer is a pure function of the argument: the class is `@MainActor` for the
  /// `Project`/`Selection` it holds, and this consults neither.
  nonisolated public static func isDisabledInLayoutMode(_ command: SelectionEditCommand) -> Bool {
    switch command {
    case .raise, .lower, .raiseTop, .lowerBottom, .addControlPoint, .removeControlPoint:
      return true
    case .cut, .copy, .paste, .delete, .duplicate, .selectAll:
      return false
    }
  }

  /// `for (lib : proj.getLogisimFile().getLibraries()) if (lib instanceof BaseLibrary)`.
  ///
  /// Note it scans the *libraries*, not the file itself, so a file that somehow lost its Base
  /// library reference disables the whole Edit menu rather than half-working.
  private var isBaseLibraryAvailable: Bool {
    guard let file = project?.logisimFile else { return false }
    return file.libraries.contains { $0 is BaseLibrary }
  }

  /// `proj.getLogisimFile().contains(proj.getCurrentCircuit())`; is the circuit being edited one
  /// of *this* file's, rather than one being viewed out of a loaded library?
  private var currentCircuitBelongsToThisFile: Bool {
    guard let project, let circuit = project.currentCircuit else { return false }
    return project.logisimFile.contains(circuit: circuit)
  }

  // MARK: - The commands

  /// `copy()`.
  public func copy() throws {
    guard let project, let selection else { return }
    try project.doAction(SelectionActions.copy(selection))
  }

  /// `cut()`.
  public func cut() throws {
    guard let project, let selection else { return }
    try project.doAction(SelectionActions.cut(selection))
  }

  /// `delete()`.
  public func delete() throws {
    guard let project, let selection else { return }
    try project.doAction(SelectionActions.clear(selection))
  }

  /// `duplicate()`.
  public func duplicate() throws {
    guard let project, let selection else { return }
    try project.doAction(SelectionActions.duplicate(selection))
  }

  /// `paste()`.
  ///
  /// The tool switch happens **before** the action is built, because building it may ask the user
  /// about unresolvable factories and the canvas must already be in Edit mode when the paste
  /// lands. Upstream's null check on the action is kept even though `pasteMaybe` never returns
  /// null: it documents that this call is allowed to decline.
  public func paste() throws {
    guard let project, let selection else { return }
    project.selectEditTool()
    let action = try SelectionActions.pasteMaybe(project, selection)
    try project.doAction(action)
  }

  /// `selectAll()`.
  ///
  /// Wires first, then non-wires: upstream's order, and with the insertion-ordered sets this
  /// port uses it is the order the selection then iterates in. Note this deliberately does *not*
  /// go through an action: selecting is not a modification and does not belong on the undo stack.
  public func selectAll() {
    guard let project, let selection, let circuit = project.currentCircuit else { return }
    project.selectEditTool()
    selection.addAll(circuit.wires.map { $0 as any Component })
    selection.addAll(circuit.nonWires)
    project.repaintCanvas()
  }
}
