// RamState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RamState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Persistent contents vs. per-simulation state ─────────────────────────────────────────────
//
// This file adds nothing to the split `MemState.swift`'s header describes, and must not: the
// `MemContents` a `RamState` holds is still the `.circ`-serialised array (one per component,
// created once by `Ram.getNewContents` and thereafter shared by every `CircuitState` that
// simulates it), while everything declared *here*, the `ClockState`, the parent subscription,
// is per-`CircuitState` scratch that `cloneData()` duplicates when a circuit state forks. The
// only field that crosses the line is `contents` itself, and `cloneData()` below deep-copies it
// exactly where upstream's `MemState.clone()` does, so a forked simulation gets its own array and
// a saved file keeps the one the attribute set points at.
//
// ── Following `MemState.swift`'s conventions, and the shape it already documents ──────────────
//
// `MemState.swift:98-105` writes out, in a doc comment, the exact body it expects this file's
// `cloneData()` to have; `Ram.swift:23-29` writes out the constructor and method signatures it
// calls. Both are honoured literally, with one deliberate adjustment: `MemState.swift`'s sketch
// ends with `copy.contents.addHexModelListener(listener)`, which would attach `listener` a second
// time given that this file's initializer already attaches it (Java's `clone()` bypasses the
// constructor, so upstream attaches it exactly once). A duplicate registration is not harmless
// here; `MemContents.addHexModelListener` appends unconditionally and `removeHexModelListener`
// is upstream-buggy (it appends too; see `MemContents.swift`), so the extra entry would fire
// `fireInvalidated()` twice per write forever. `cloneData()` therefore leans on the initializer
// for that one step instead of repeating it. Every other step of the sketch is verbatim.
//
// `DualRamState.swift` (the community-contributed dual-port variant, sibling slice) is the near
// twin of this file and its header catalogues the two places upstream's `DualRamState.clone()`
// deviates from `RamState.clone()`; this file is the side of that comparison that behaves as
// documented; it *does* re-attach the `MemListener` to the cloned contents.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `Cloneable`/`clone()`'s covariant return; `cloneData()` (`InstanceData`) is this port's
//     hook, per `MemState.swift`'s note on `Object.clone()` having no Swift equivalent.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RamState`; `MemState` plus the one `ClockState` a synchronous
/// RAM needs to turn its clock input into an edge, and a subscription to the owning component's
/// attribute set so an address/data width change resizes the contents.
public final class RamState: MemState, AttributeListener {

  /// `RamState.listener`: the `Mem.MemListener` that repaints the component when its contents
  /// change. Optional for the reason `Ram.swift`'s `ramState(for:)` makes its own optional:
  /// there is no component to invalidate when `state.component` is not a `StdInstanceComponent`.
  private let listener: Mem.MemListener?

  /// `RamState.clockState`.
  private var clockState = ClockState()

  /// `RamState.parent`. `weak`: the component owns its `attributeSet`, and nothing downstream of
  /// that ownership (D3) should keep it alive; the same direction `DualRamState.swift` takes.
  private weak var parent: StdInstanceComponent?
  private var subscription: AttributeSubscription?

  /// `RamState(Instance, MemContents, MemListener)`.
  ///
  /// Argument order follows `Ram.swift`'s documented call (`component:contents:listener:`) rather
  /// than Java's positional order; the body is upstream's, in upstream's order.
  init(component: StdInstanceComponent?, contents: MemContents, listener: Mem.MemListener?) {
    self.listener = listener
    super.init(contents)
    self.parent = component
    if let component {
      subscription = component.attributeSet.addAttributeListener(self)
    }
    if let listener {
      contents.addHexModelListener(listener)
    }
  }

  // MARK: AttributeListener

  /// `attributeValueChanged(AttributeEvent)`.
  public func attributeValueChanged(_ event: AttributeEvent) {
    guard
      let addrBits = event.source.getValue(Mem.addr),
      let dataBits = event.source.getValue(Mem.data)
    else { return }
    // `getContents().setDimensions(...)`. Upstream's call cannot fail: both widths arrive through
    // attributes their own codecs already bounds-checked (`Mem.addr` 2...24, `Mem.data` 1...64),
    // so nothing a `.circ` file can express reaches `MemContents`' throwing path. `try?` keeps
    // that faithful without introducing a trap (D13).
    try? getContents().setDimensions(addrBits: addrBits.width, width: dataBits.width)
  }

  // MARK: Cloning

  /// `clone()`.
  ///
  /// Upstream's three steps on top of `MemState.clone()`, drop the parent, clone the
  /// `ClockState`, re-attach `listener` to the cloned contents, are all here; the third happens
  /// inside the initializer (see the file header). `parent: nil` also means no attribute
  /// subscription is taken out, which is what `ret.parent = null` amounts to: the clone stops
  /// resizing itself when the original component's widths change, until `setRam(_:)` re-parents
  /// it. That is upstream's behaviour, not a simplification.
  public override func cloneData() -> any InstanceData {
    let copy = RamState(component: nil, contents: getContents().cloneContents(), listener: listener)
    cloneBaseState(into: copy)
    // `ret.clockState = this.clockState.clone()`; `ClockState` is a `struct` in this port, so
    // assignment *is* the clone (see `ClockState.swift`'s header).
    copy.clockState = clockState
    return copy
  }

  // MARK: Clock

  /// `setClock(Value, Object)`.
  func setClock(_ newClock: Value, trigger: AttributeOption?) -> Bool {
    clockState.updateClock(newClock, trigger: trigger)
  }

  // MARK: Re-parenting

  /// `setRam(Instance)`.
  func setRam(_ value: StdInstanceComponent?) {
    guard parent !== value else { return }
    subscription?.cancel()
    subscription = nil
    parent = value
    if let value {
      subscription = value.attributeSet.addAttributeListener(self)
    }
  }
}
