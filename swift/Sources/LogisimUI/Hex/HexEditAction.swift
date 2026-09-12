// HexEditAction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RomContentsListener.Change),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The half of `RomContentsListener` that could not be ported in M5 ─────────────────────────
//
// `LogisimStd/Memory/RomContentsListener.swift` already ports the listener and the coalescing
// arithmetic (`RomContentsChange.merged(withNewer:)` is `Change.append` verbatim). What it could
// not port is the `extends Action` half, because `Action` and `Project` live in this module and
// `LogisimStd` may not depend on it. That file says so in its own header and names this as the
// thing to write. This is that.
//
// The whole of the undo behaviour is in `completed`, which is initialised **true**:
//
//   * the edit has *already* happened by the time the action exists; `MemContents.set` fired
//     `bytesChanged`, the listener saw it, and only then is the action constructed. So the first
//     `doIt` must be a no-op, or the write is applied twice (harmless for a plain `set`, not
//     harmless once it is coalesced with a neighbour whose old values it would then clobber);
//   * `undo` writes `oldValues` and clears the flag; a later `doIt` (redo) writes `newValues` and
//     sets it. That is the only reason `doIt` is not simply "apply".
//
// Both directions disable the listener across the write; upstream's guard against an undo being
// recorded as a fresh edit, which would make the undo stack grow every time the user pressed ⌘Z.
//
// ── Measured: in THIS port that guard is redundant, and it is kept anyway ────────────────────
//
// `HexEditorModel.recordingUndo` buffers what the listener reports and drains it only around the
// model's own edit methods. `Project.undoAction` calls `undo` directly, outside any such window,
// so the write below is never turned into an action even with `setEnabled` removed. A red probe
// confirmed it: deleting both `setEnabled` calls leaves
// `HexEditUndoTests.undoIsNotRecorded` GREEN; it only goes red when the buffer is *also* replaced
// by upstream's direct `proj.doAction(...)`-from-`bytesChanged` dispatch. So the honest statement
// is that the buffer is this port's guard and `setEnabled` is upstream fidelity plus defence in
// depth for any future caller that drives `undo` from inside a recording window.

import Foundation
import LogisimStd

/// `com.cburch.logisim.std.memory.RomContentsListener.Change`: one undoable hex-editor edit.
@MainActor
public final class HexEditAction: Action {

  /// `Change.source`; the listener to silence while this action writes.
  private let listener: RomContentsListener
  /// `Change.contents`.
  public let contents: MemContents
  /// `Change.start` / `oldValues` / `newValues`, already carried as one value by the M5 port.
  public private(set) var change: RomContentsChange
  /// `Change.completed`. See the file header; it starts `true`.
  private var completed = true

  public init(listener: RomContentsListener, contents: MemContents, change: RomContentsChange) {
    self.listener = listener
    self.contents = contents
    self.change = change
  }

  /// `getName()`: `S.get("romChangeAction")`, `std.properties:829`, `Edit ROM Contents` in the
  /// `en` bundle. A literal rather than a `ToolActionName` because that enumeration lives in
  /// `Tools/ToolSeams.swift`, which this slice does not own; the Edit menu reads the right words
  /// either way.
  public override var name: String { "Edit ROM Contents" }

  /// `doIt(Project)`. A no-op on the first call; the redo half thereafter.
  public override func doIt(_ project: Project) throws {
    guard !completed else { return }
    completed = true
    listener.setEnabled(false)
    defer { listener.setEnabled(true) }
    contents.set(start: change.start, values: change.newValues)
  }

  /// `undo(Project)`.
  public override func undo(_ project: Project) throws {
    guard completed else { return }
    completed = false
    listener.setEnabled(false)
    defer { listener.setEnabled(true) }
    contents.set(start: change.start, values: change.oldValues)
  }

  /// `shouldAppendTo(Action)`.
  ///
  /// ── UPSTREAM QUIRK, PRESERVED: no `contents` comparison ─────────────────────────────────
  /// Java tests `other instanceof Change` and the range overlap, and nothing else. It never asks
  /// whether the two changes touch the *same memory*. Two hex editors open on two different ROMs
  /// in one project therefore coalesce into a single action whose `contents` is the older one's,
  /// so undoing the pair rewrites the first ROM twice and leaves the second edited. Reproduced
  /// exactly (see `HexEditActionTests.mergingIgnoresWhichMemoryWasEdited`, which pins it), because
  /// "fixing" it here would diverge the port from 4.1.0's undo stack with no gate able to see it.
  /// It is reported as an upstream defect rather than repaired locally.
  ///
  /// Note also that upstream does **not** unwrap a `JoinedAction` first, unlike the three
  /// `SelectionActions` overrides. It does not need to: a run of hex edits never produces one,
  /// because `append` below always returns another `HexEditAction`.
  public override func shouldAppendTo(_ other: Action) -> Bool {
    guard let other = other as? HexEditAction else { return super.shouldAppendTo(other) }
    // `self` is the incoming (newer) action, `other` the one on the stack; the reverse of
    // `append`'s roles. The overlap test is symmetric, so it reads the same either way.
    return other.change.overlapsOrTouches(change)
  }

  /// `append(Action)`.
  ///
  /// `self` is the older action, already on the undo stack; `other` is the newer one just
  /// performed. That is the order `Project.doAction` calls it in and the order
  /// `RomContentsChange.merged(withNewer:)` documents.
  ///
  /// The merged action carries `self`'s `listener` and `contents`, exactly as Java's
  /// `new Change(source, contents, ...)` does: see the quirk note on `shouldAppendTo`.
  public override func append(_ other: Action) -> Action? {
    guard let other = other as? HexEditAction,
      let merged = change.merged(withNewer: other.change)
    else {
      return super.append(other)
    }
    return HexEditAction(listener: listener, contents: contents, change: merged)
  }
}
