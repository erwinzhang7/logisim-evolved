// LogisimFileActions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.file.LogisimFileActions),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16), not `main`.
//
// ── What this file is for ───────────────────────────────────────────────────────────────────
//
// `CircuitMutation` is the undo unit for everything whose scope is *one circuit's netlist*.
// It cannot express "the file now has one more circuit", because a `CircuitTransaction` locks
// and replays a set of circuits and has nowhere to put a change to the *tool list*. Upstream
// answers that with a second, much simpler action family whose unit is the `LogisimFile`, and
// which does not go anywhere near the transaction machinery: `LogisimFileActions`. This is that
// family.
//
// Six of upstream's ten are ported here. The four that are not, `MergeFile`, `LoadLibraries`,
// `RevertDefaults`, and the two VHDL ones (`AddVhdl`/`RemoveVhdl`), have no command reaching
// them in this port; see the note at the bottom of the file.
//
// ── The shape every one of these shares ─────────────────────────────────────────────────────
//
// Each holds a **strong** reference to the model object it removed, and that is the point: the
// undo stack is what keeps a removed circuit alive between the removal and the undo. D3 calls
// that out explicitly; `LogisimFile.ownedCircuits` drops its reference in `removeCircuit`, so
// after a removal the *only* owner is the action sitting in `Project.undoLog`. Clearing the undo
// history is therefore also what finally frees it, which is the behaviour `Project` already has.
//
// Each also captures its "before" state inside `doIt`, not inside `init`. That is not a style
// choice: `Project.redoAction` calls `doIt` again rather than a separate `redo`, so an action
// that captured the old value at construction time would, on the second run, restore a value
// from two edits ago. `Action.doIt`'s own doc comment states the rule; `RemoveCircuitAction`
// and `MoveCircuitAction` and `SetMainCircuitAction` all re-capture.
//
// ── The SoC eviction hooks ──────────────────────────────────────────────────────────────────
//
// `LogisimFileProjectHost` owns a `SocCircuitBinder`, the port's stand-in for Java's
// `Circuit.socSim` field, and until this file existed it evicted a removed circuit's binding
// inline at the `.removeCircuit` command arm. With removal undoable the eviction has to move
// with the operation; a circuit that comes *back* needs its binding back, and a circuit still
// held by the undo stack must not keep a live `SocBusFabric`/`SocMemoryMap` graph attached. So
// `AddCircuitAction` and `RemoveCircuitAction` take a pair of closures and call them at the four
// moments the membership actually changes (add/redo-add, undo-of-add, remove/redo-remove,
// undo-of-remove).
//
// D3: the host captures itself **weakly** in those closures. The owning chain is
// host → project → undoLog → action → closure, so a strong capture would make every open
// document immortal the moment the user adds a circuit.

import Foundation
@preconcurrency import LogisimFile

/// `com.cburch.logisim.file.LogisimFileActions`: the factory namespace, as upstream has it.
///
/// Upstream's nested classes are private and reached only through these statics. The Swift
/// classes below are `final` and internal for the same reason: nothing outside this module has
/// business subclassing one, and the tests drive them through `LogisimFileProjectHost.perform`,
/// which is the seam that actually matters (an action tested in isolation can be perfect while
/// nothing pushes it onto the stack).
@MainActor
public enum LogisimFileActions {

  /// `LogisimFileActions.addCircuit(Circuit)`.
  public static func addCircuit(
    _ circuit: Circuit,
    onAdded: @escaping (Circuit) -> Void = { _ in },
    onRemoved: @escaping (Circuit) -> Void = { _ in }
  ) -> Action {
    AddCircuitAction(circuit: circuit, onAdded: onAdded, onRemoved: onRemoved)
  }

  /// `LogisimFileActions.removeCircuit(Circuit)`.
  public static func removeCircuit(
    _ circuit: Circuit,
    onAdded: @escaping (Circuit) -> Void = { _ in },
    onRemoved: @escaping (Circuit) -> Void = { _ in }
  ) -> Action {
    RemoveCircuitAction(circuit: circuit, onAdded: onAdded, onRemoved: onRemoved)
  }

  /// `LogisimFileActions.moveCircuit(AddTool, int)`.
  public static func moveCircuit(_ tool: AddTool, to index: Int) -> Action {
    MoveCircuitAction(tool: tool, toIndex: index)
  }

  /// `LogisimFileActions.setMainCircuit(Circuit)`.
  public static func setMainCircuit(_ circuit: Circuit) -> Action {
    SetMainCircuitAction(newValue: circuit)
  }

  /// `LogisimFileActions.unloadLibrary(Library)`; upstream's one-library convenience over
  /// `unloadLibraries`. Only the singular form is ported, because only the singular command
  /// exists (`ProjectCommand.unloadLibrary(LibraryID)`).
  public static func unloadLibrary(_ library: Library) -> Action {
    UnloadLibraryAction(libraries: [library])
  }
}

// MARK: - Add

/// `LogisimFileActions.AddCircuit` (`LogisimFileActions.java:43`).
@MainActor
final class AddCircuitAction: Action {

  private let circuit: Circuit
  private let onAdded: (Circuit) -> Void
  private let onRemoved: (Circuit) -> Void

  init(
    circuit: Circuit,
    onAdded: @escaping (Circuit) -> Void,
    onRemoved: @escaping (Circuit) -> Void
  ) {
    self.circuit = circuit
    self.onAdded = onAdded
    self.onRemoved = onRemoved
  }

  /// `S.get("addCircuitAction")`: "Add Circuit" in `file.properties:56`.
  override var name: String { "Add Circuit" }

  override func doIt(_ project: Project) throws {
    // Upstream appends (`addCircuit(circuit)` → `addCircuit(circuit, tools.size())`), and so does
    // this. A redo therefore puts the circuit back at the *end*, not at the index it originally
    // occupied, which is the same place it went the first time, since the first time was also an
    // append. It only differs if a `MoveCircuit` ran in between, and that move is its own undo
    // entry which is unwound first.
    project.logisimFile.addCircuit(circuit)
    onAdded(circuit)
  }

  override func undo(_ project: Project) throws {
    // D13: `removeCircuit` throws on the last circuit rather than trapping. It cannot be the last
    // one here, `doIt` just added it to a file that already had at least one, but propagating
    // is still the right shape, because swallowing it would leave the undo log claiming a change
    // the model does not have.
    try project.logisimFile.removeCircuit(circuit)
    onRemoved(circuit)
  }
}

// MARK: - Remove

/// `LogisimFileActions.RemoveCircuit` (`LogisimFileActions.java:522`).
@MainActor
final class RemoveCircuitAction: Action {

  private let circuit: Circuit
  /// The circuit's position in the **tool** list, not in `circuits`. `indexOfCircuit` returns the
  /// former and `addCircuit(_:at:)` consumes the former; mixing them up would silently reorder a
  /// file that also contains VHDL entities, whose tools interleave with the circuits'.
  private var index = -1
  /// Whether this circuit was the file's main circuit. See `undo` for why this exists.
  private var wasMain = false

  private let onAdded: (Circuit) -> Void
  private let onRemoved: (Circuit) -> Void

  init(
    circuit: Circuit,
    onAdded: @escaping (Circuit) -> Void,
    onRemoved: @escaping (Circuit) -> Void
  ) {
    self.circuit = circuit
    self.onAdded = onAdded
    self.onRemoved = onRemoved
  }

  /// `S.get("removeCircuitAction")`: "Remove Circuit" in `file.properties:77`.
  override var name: String { "Remove Circuit" }

  override func doIt(_ project: Project) throws {
    let file = project.logisimFile
    index = file.indexOfCircuit(circuit)
    wasMain = file.mainCircuit === circuit
    try file.removeCircuit(circuit)
    onRemoved(circuit)
  }

  override func undo(_ project: Project) throws {
    let file = project.logisimFile
    // Clamp rather than trust. `index` is recorded by `doIt` and undo is LIFO, so in every
    // reachable ordering the list is exactly as long as it was, but `Array.insert(at:)` traps
    // out of range, and D13's rule is that a trap takes the user's unsaved work with it.
    let target = min(max(index, 0), file.addTools.count)
    file.addCircuit(circuit, at: target)

    // ── A deliberate divergence from 4.1.0, and the only one in this file ──────────────────
    //
    // `LogisimFile.removeCircuit` destroys three things (`LogisimFile.java:604-615`, and the
    // port's `LogisimFile.swift:601-615` line for line): the tool, its position, and, if the
    // removed circuit was `main`, the main-circuit pointer, which it silently reassigns to
    // `tools.get(0)`'s subcircuit.
    //
    // Upstream's `RemoveCircuit.undo` restores only the first two: it calls
    // `addCircuit(circuit, index)`, and `addCircuit` sets `main` only when the file has exactly
    // one tool afterwards (`LogisimFile.java:315`), which after an undo it never does. So
    // upstream leaves the user with their circuit back and a *different* main circuit, with no
    // indication that happened. That is not a subtlety of the model; it is a defect, and it is
    // reachable by two clicks.
    //
    // Restored here. If this ever has to be reverted for fidelity, the test that pins it is
    // `undoing the removal of the main circuit restores main-circuit status` in
    // `FileActionUndoTests`; it will fail loudly rather than quietly drifting.
    if wasMain {
      file.setMainCircuit(circuit)
    }
    onAdded(circuit)
  }
}

// MARK: - Move

/// `LogisimFileActions.MoveCircuit` (`LogisimFileActions.java:483`).
///
/// The one member of this family with real coalescing: dragging a circuit three places up the
/// sidebar is three commands and must be one undo entry.
@MainActor
final class MoveCircuitAction: Action {

  /// Held by reference, and compared by reference in `shouldAppendTo`, exactly as upstream's
  /// `circ.tool == this.tool` does. `Tool` has no value equality in either tree (D4).
  let tool: AddTool
  private var fromIndex = -1
  private let toIndex: Int

  init(tool: AddTool, toIndex: Int) {
    self.tool = tool
    self.toIndex = toIndex
  }

  /// `S.get("moveCircuitAction")`: "Reorder Circuits" in `file.properties:76`. Plural even for
  /// one move, which is upstream's wording and reads correctly once a run has coalesced.
  override var name: String { "Reorder Circuits" }

  /// `append(Action)` (`LogisimFileActions.java:493`).
  ///
  /// Note what upstream builds and what `Project.performAction` then does with it: the merged
  /// action keeps **this** action's `fromIndex` and takes the **incoming** action's `toIndex`, so
  /// it describes the whole run; but the coalescing branch of `doAction` performs the *incoming*
  /// action, not the merged one, and the incoming action records its own `fromIndex` in its own
  /// `doIt`. The merged object is only ever asked to `undo`. Returning `nil` when the run has
  /// come back to where it started is what keeps a no-op entry off the stack.
  override func append(_ other: Action) -> Action? {
    guard let other = other as? MoveCircuitAction else { return super.append(other) }
    let merged = MoveCircuitAction(tool: tool, toIndex: other.toIndex)
    merged.fromIndex = fromIndex
    return merged.fromIndex == merged.toIndex ? nil : merged
  }

  /// `shouldAppendTo(Action)` (`LogisimFileActions.java:512`).
  ///
  /// Unwraps `JoinedAction` first: see `Action.shouldAppendTo`'s comment for the drag that
  /// coalesces exactly once when this line is missing. Upstream's override does not unwrap,
  /// because a `MoveCircuit` never merges into a `JoinedAction`: its own `append` always returns
  /// a `MoveCircuit` or `nil`, so the top of the log is either this type or something it will
  /// refuse anyway. Unwrapping is a no-op on every reachable input and stays for the day some
  /// other file-level action learns to merge with this one.
  override func shouldAppendTo(_ other: Action) -> Bool {
    guard let last = Action.lastAction(of: other) as? MoveCircuitAction else { return false }
    return last.tool === tool
  }

  override func doIt(_ project: Project) throws {
    let file = project.logisimFile
    fromIndex = file.addTools.firstIndex { $0 === tool } ?? -1
    file.moveCircuit(tool, to: toIndex)
  }

  override func undo(_ project: Project) throws {
    // `fromIndex` is -1 only if `doIt` never found the tool, in which case `moveCircuit` would
    // insert it at a negative index and trap. Upstream has the same hole and reaches it the same
    // way (never); refusing is the D13-shaped answer.
    guard fromIndex >= 0 else { return }
    project.logisimFile.moveCircuit(tool, to: fromIndex)
  }
}

// MARK: - Main circuit

/// `LogisimFileActions.SetMainCircuit` (`LogisimFileActions.java:659`).
@MainActor
final class SetMainCircuitAction: Action {

  private var oldValue: Circuit?
  private let newValue: Circuit

  init(newValue: Circuit) {
    self.newValue = newValue
  }

  /// `S.get("setMainCircuitAction")`; "Set Main Circuit" in `file.properties:81`.
  override var name: String { "Set Main Circuit" }

  override func doIt(_ project: Project) throws {
    oldValue = project.logisimFile.mainCircuit
    project.logisimFile.setMainCircuit(newValue)
  }

  override func undo(_ project: Project) throws {
    // `setMainCircuit(nil)` is a no-op in both trees (`LogisimFile.java:662`'s
    // `if (circuit == null) return;`, and the port's `guard let circuit else { return }`), so a
    // file that somehow had no main circuit before the edit keeps the new one. Upstream has
    // exactly this behaviour; it is unreachable because a file always has a main circuit from its
    // first `addCircuit`.
    project.logisimFile.setMainCircuit(oldValue)
  }
}

// MARK: - Libraries

/// `LogisimFileActions.UnloadLibraries` (`LogisimFileActions.java:684`).
///
/// Kept plural internally even though only the singular factory is vended, because the *order*
/// upstream unloads in is part of the behaviour, backwards on `doIt`, forwards on `undo`, and
/// writing it now costs nothing while rediscovering it later costs a bug.
@MainActor
final class UnloadLibraryAction: Action {

  private let libraries: [Library]

  init(libraries: [Library]) {
    self.libraries = libraries
  }

  /// `S.get("unloadLibraryAction")` / `unloadLibrariesAction`, `file.properties:83`.
  override var name: String {
    libraries.count == 1 ? "Unload Library" : "Unload Libraries"
  }

  override func doIt(_ project: Project) throws {
    for library in libraries.reversed() {
      project.logisimFile.removeLibrary(library)
    }
  }

  override func undo(_ project: Project) throws {
    // Upstream **appends**; it does not restore the library's original position in the list, and
    // neither does this. Unlike the main-circuit case above that is not a defect worth diverging
    // over: library order has no semantic meaning (name resolution walks the whole list), it is
    // visible only as the order of the sidebar's collapsed library rows, and `LogisimFile` has no
    // `addLibrary(_:at:)` to call. Recorded rather than silently matched.
    for library in libraries {
      project.logisimFile.addLibrary(library)
    }
  }
}

// MARK: - What is not here
//
// Upstream's remaining `LogisimFileActions` members are absent because no command in this port
// reaches them, not because they are hard:
//
//   * `AddVhdl` / `RemoveVhdl`; there is no "add VHDL entity" command; `LogisimFile.addVhdlContent`
//     is itself a no-op until `LogisimFileSeams.makeVhdlEntity` is installed.
//   * `MergeFile`; "Merge into project" is not in the menu.
//   * `LoadLibraries`; loading a library is not currently undoable *upstream-shaped* here; the
//     load itself can fail and report, and the port's load path predates this family. Note the
//     asymmetry this leaves: unloading a library is undoable and loading one is not. That is the
//     half-undoable shape this file otherwise exists to remove, and it is called out at the
//     command arm as well.
//   * `RevertDefaults`; "Revert to template defaults" is not in the menu.
