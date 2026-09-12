// RomContentsListener.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RomContentsListener),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── UI seam ──────────────────────────────────────────────────────────────────────────────────
//
// Upstream's `RomContentsListener implements HexModelListener` exists to turn every edit a user
// makes through the hex editor into one entry on the project's undo stack (`proj.doAction(new
// Change(...))`), where `Change extends Action` and coalesces adjacent/overlapping edits into a
// single undoable unit via `append`/`shouldAppendTo`. `Action` and `Project` are M7 (undo/redo,
// not started: see objectives.md), so this file cannot depend on them.
//
// What is ported is everything that does not need them: the coalescing arithmetic itself
// (`RomContentsChange.merged(withNewer:)`, below, is `Change.append` verbatim) and the
// enable/disable guard `Change.doIt`/`undo` use to stop their own writes from re-triggering the
// listener. `RomContentsListener.onChange` stands in for `proj.doAction(...)`: whatever M7's
// concrete undo-action type turns out to be, it wraps a `RomContentsChange` and asks it to
// `merged(withNewer:)` the next one; the interesting logic does not need to be rewritten once
// that type exists.
//
// `HexModel`/`HexModelListener` (the two-method interfaces this class actually implements) are
// declared in `MemContents.swift`, the sibling slice's file: see that file's header for why they
// live there rather than in a `com.cburch.hex` file of their own.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.std.memory.RomContentsListener.Change`, minus its `Action` conformance.
///
/// One coalescible edit to a ROM's contents: the address range touched, what was there before,
/// and what replaced it.
public struct RomContentsChange: Equatable {
  public var start: Int64
  public var oldValues: [Int64]
  public var newValues: [Int64]

  public init(start: Int64, oldValues: [Int64], newValues: [Int64]) {
    precondition(
      oldValues.count == newValues.count,
      "RomContentsChange: old/new value counts must match")
    self.start = start
    self.oldValues = oldValues
    self.newValues = newValues
  }

  private var end: Int64 { start + Int64(newValues.count) }

  /// The shared guard behind both `Change.append` and `Change.shouldAppendTo`:
  /// `oEnd >= start && end >= o.start`: the two address ranges touch or overlap.
  public func overlapsOrTouches(_ other: RomContentsChange) -> Bool {
    other.end >= start && end >= other.start
  }

  /// `Change.append(Action)`. `self` is the older, already-applied change (upstream: the
  /// receiver, already on the undo stack); `other` is the one just performed. Returns `nil`
  /// when the two ranges do not touch, matching upstream's fall-through to
  /// `super.append(other)`: the only outcome reachable here, since the two changes being
  /// compared are always both `RomContentsChange`s.
  public func merged(withNewer other: RomContentsChange) -> RomContentsChange? {
    guard overlapsOrTouches(other) else { return nil }
    let newStart = min(start, other.start)
    let newEnd = max(end, other.end)
    var mergedOld = [Int64](repeating: 0, count: Int(newEnd - newStart))
    var mergedNew = [Int64](repeating: 0, count: Int(newEnd - newStart))

    // Oldest-first into `mergedOld`, then overwritten by `self` (the earlier change); its
    // recorded original value is the true "before any of this happened" value where the two
    // ranges overlap. Newest-first into `mergedNew`, then overwritten by `other` (the later
    // change); its value is the true final state. Matches upstream's arraycopy order exactly.
    Self.place(other.oldValues, into: &mergedOld, at: Int(other.start - newStart))
    Self.place(oldValues, into: &mergedOld, at: Int(start - newStart))
    Self.place(newValues, into: &mergedNew, at: Int(start - newStart))
    Self.place(other.newValues, into: &mergedNew, at: Int(other.start - newStart))

    return RomContentsChange(start: newStart, oldValues: mergedOld, newValues: mergedNew)
  }

  private static func place(_ values: [Int64], into array: inout [Int64], at offset: Int) {
    for (i, value) in values.enumerated() { array[offset + i] = value }
  }
}

/// `com.cburch.logisim.std.memory.RomContentsListener`, minus the `Action`/`Project` undo-log
/// wiring: see the file header. Conforms to `HexModelListener` so it registers directly with a
/// `MemContents` via `addHexModelListener`, exactly as upstream's constructor site does
/// (`contents.addHexModelListener(new RomContentsListener(proj))`).
public final class RomContentsListener: HexModelListener {

  /// `proj.doAction(new Change(...))`. `nil` when there is no undo log to record into, matching
  /// upstream's `proj != null` guard: the common case for a `.circ` processed by `logisim-cli`
  /// rather than opened for editing.
  public var onChange: ((RomContentsChange) -> Void)?

  /// `RomContentsListener.enabled`. `Change.doIt`/`undo` toggle this around their own writes so
  /// applying an undo/redo does not record itself as a fresh change.
  private var enabled = true

  public init(onChange: ((RomContentsChange) -> Void)? = nil) {
    self.onChange = onChange
  }

  /// `setEnabled(boolean)`.
  public func setEnabled(_ value: Bool) {
    enabled = value
  }

  /// `bytesChanged(HexModel, long, long, long[])`.
  public func bytesChanged(source: any HexModel, start: Int64, numBytes: Int64, oldValues: [Int64]?) {
    guard enabled, let onChange, let oldValues else { return }
    let newValues = (0..<oldValues.count).map { source.get(start + Int64($0)) }
    onChange(RomContentsChange(start: start, oldValues: oldValues, newValues: newValues))
  }

  /// `metainfoChanged`; upstream's body is empty ("ignore - this can only come from an
  /// already-registered action").
  public func metainfoChanged(source: any HexModel) {}
}
