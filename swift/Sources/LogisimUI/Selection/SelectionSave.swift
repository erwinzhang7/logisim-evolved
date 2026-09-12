// SelectionSave.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.SelectionSave),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── What it is for ──────────────────────────────────────────────────────────────────────────
//
// A snapshot of *which* components were anchored and which were floating, taken before an action
// runs. It has two jobs, and they are unrelated to each other:
//
//   1. **Undo restores the selection.** `Selection.MyListener` files one of these against every
//      action as it starts, and on `UNDO_COMPLETE` puts the components back into the right half
//      of the selection: re-deciding anchored-versus-floating by asking the circuit whether it
//      still contains each one, rather than trusting the snapshot's own split.
//   2. **Undo coalescing.** `Anchor`, `Drop` and `Translate` append onto a preceding `Paste` or
//      `Duplicate` when the earlier action's *after* snapshot equals this one's *before*
//      snapshot; i.e. nothing happened in between. That is what makes "paste, then nudge into
//      place" a single undo step.
//
// Job 2 is why equality here has to be Java's: `HashSet.equals`, which for `Wire` is structural.
// See `ComponentSet`'s header.
//
// ── The null-versus-empty distinction is real ───────────────────────────────────────────────
//
// Upstream leaves the arrays `null` when the corresponding half is empty, and `isSame` treats
// null and zero-length as the same thing everywhere. Modelled as an empty `ComponentSet` and the
// distinction dropped, because upstream never lets the two diverge: `create` only assigns when
// `!isEmpty()`, so a non-null array is never empty.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.gui.main.SelectionSave`.
///
/// Deliberately **not** `@MainActor`, unlike the rest of this slice. It is an inert snapshot,
/// two lists of references and their key sets, and its `Equatable`/`Hashable` conformances have
/// to be usable from wherever a `Set` or a `==` needs them. Only the two members that touch a
/// live `SelectionBase` are main-actor isolated, which is where the isolation actually belongs.
public struct SelectionSave {
  /// `floating`; the components that were **not** in the circuit.
  public let floatingComponents: [any Component]
  /// `anchored`; the components that were in the circuit.
  public let anchoredComponents: [any Component]

  private let floatingKeys: Set<SelectionComponentKey>
  private let anchoredKeys: Set<SelectionComponentKey>

  /// `create(Selection)`.
  @MainActor
  public static func create(_ selection: SelectionBase) -> SelectionSave {
    SelectionSave(
      floating: selection.floatingComponents,
      anchored: selection.anchoredComponents)
  }

  init(floating: [any Component], anchored: [any Component]) {
    self.floatingComponents = floating
    self.anchoredComponents = anchored
    self.floatingKeys = Set(floating.map(SelectionComponentKey.init))
    self.anchoredKeys = Set(anchored.map(SelectionComponentKey.init))
  }

  /// `isSame(Selection)`; does this snapshot still describe the live selection?
  ///
  /// Used by `Selection.MyListener` on `ACTION_COMPLETE` to decide whether the saved snapshot can
  /// be forgotten: if the action did not disturb the selection there is nothing for a later undo
  /// to restore.
  @MainActor
  public func isSame(as selection: SelectionBase) -> Bool {
    floatingKeys == Set(selection.floatingComponents.map(SelectionComponentKey.init))
      && anchoredKeys == Set(selection.anchoredComponents.map(SelectionComponentKey.init))
  }
}

extension SelectionSave: Equatable {
  /// `equals(Object)`, which is `isSame(floating, o.floating) && isSame(anchored, o.anchored)`.
  ///
  /// Upstream's array-length pre-check is subsumed: the arrays come from `HashSet`s, so they
  /// never contain duplicates and equal sets always have equal lengths.
  public static func == (lhs: SelectionSave, rhs: SelectionSave) -> Bool {
    lhs.floatingKeys == rhs.floatingKeys && lhs.anchoredKeys == rhs.anchoredKeys
  }
}

extension SelectionSave: Hashable {
  /// `hashCode()` is the *sum* of the member hash codes: deliberately order-independent, so two
  /// snapshots that compare equal hash equally. `Set`'s own hashing has the same property, so it
  /// is used directly rather than reproducing the sum.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(floatingKeys)
    hasher.combine(anchoredKeys)
  }
}
