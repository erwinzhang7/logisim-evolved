// DualRamState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.DualRamState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Ownership note ───────────────────────────────────────────────────────────────────────────
//
// See `DualRamAttributes.swift`'s header for why this file: part of the community-contributed
// "Dual Port RAM" variant; is ported under this slice's "remaining memory/*.java" clause rather
// than the sibling Mem/Ram/Rom slice's, whose landed `MemState.swift` this file subclasses.
//
// ── Following `MemState.swift`'s own conventions exactly ────────────────────────────────────────
//
// `MemState.swift` (sibling slice, landed) already sets the pattern this file follows:
// `getContents()`/`getCurrent()`/`setCurrent(_:)` etc. are *methods*, not computed properties
// (unlike this same directory's `MemPoker.swift`, written earlier against an assumed API that
// guessed properties, see that file's own header, and this file's final-report note); `clone()`
// has no Swift equivalent, so `cloneData()` is overridden entirely rather than composed via a
// `copyInto`-style hook, using the explicit `cloneBaseState(into:)` stand-in `MemState.swift`
// provides for exactly this; and the designated initializer calls `super.init(_:)` (the *real*
// `MemState` constructor, `setBits` + `contents.addHexModelListener(self)`), not the
// clone-only, `setBits`-bypassing `init(contents:)` overload that constructor's doc comment
// reserves for `MemState.cloneData()`'s own internal use.
//
// Upstream's `DualRamState extends MemState`: port A's cursor/scroll/current-address bookkeeping
// *is* the inherited `MemState`; port B gets a second, independently-constructed `MemState`
// (`stateB`) held by composition. That asymmetry is upstream's own design, not something this
// port introduces: kept exactly, per this task's "preserve inheritance chains" rule.
//
// ── Two upstream asymmetries with `RamState`, preserved ────────────────────────────────────────
//
//   * `RamState.clone()` (per `MemState.swift`'s doc comment on what it expects) re-adds its
//     captured `Mem.MemListener` to the cloned contents; `DualRamState.clone()` does **not**: it
//     clones `contents`, `clockState0`/`clockState1` and `stateB`, and stops. Whether this is an
//     intentional difference or a gap in the upstream contribution, it is observable behaviour (a
//     cloned dual-port RAM's repaint-on-edit listener is not re-attached) and is reproduced here
//     via `attachListener: false` in `cloneData()`'s call to this file's own initializer.
//   * `this.stateB.clone()` clones port B's `MemState` independently of port A's clone; each
//     side ends up with its *own* `MemContents.cloneContents()` copy, even though at clone time
//     both `contents` (this instance, port A) and `stateB.contents` (port B) still pointed at the
//     *same* `MemContents`. A cloned `DualRamState`'s two ports therefore silently stop sharing
//     memory. This is upstream's own bug (`getPortBState()`'s only caller, the not-yet-ported
//     paint code, never mutates through it, so it has gone unnoticed), reproduced verbatim rather
//     than "fixed" into a shared clone, per this port's fidelity mandate.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * (nothing further: `getAddressAt(int, int)` is now overridden, M6.)

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.DualRamState`: `MemState` (port A) plus a second, owned
/// `MemState` for port B, and one `ClockState` per port.
public final class DualRamState: MemState, AttributeListener {

  /// `DualRamState.listener`: the shared `Mem.MemListener`, attached to `contents` (both ports
  /// read the same underlying `MemContents`; there is only one memory array to repaint on).
  /// Optional for the same reason `Ram.swift`'s `ramState(for:)` makes its own listener optional:
  /// there is no component to notify when `state.component` is not a `StdInstanceComponent`.
  private let listener: Mem.MemListener?

  /// `DualRamState.clockState0` / `.clockState1`.
  private var clockState0 = ClockState()
  private var clockState1 = ClockState()

  /// `DualRamState.stateB`: port B's own cursor/scroll/current-address bookkeeping, backed
  /// (initially) by the *same* `MemContents` port A (the inherited `MemState` half) holds. See
  /// the file header for the clone-time divergence this reproduces.
  private var stateB: MemState

  /// `DualRamState.parent`. `weak`: the component outlives no attribute-listener subscription
  /// registered against it, matching D3's ownership direction (`StdInstanceComponent` owns its
  /// `attributeSet`; nothing downstream should hold it strongly).
  private weak var parent: StdInstanceComponent?
  private var subscription: AttributeSubscription?

  /// `DualRamState(Instance, MemContents, MemListener)`.
  ///
  /// `attachListener` is not part of upstream's constructor; it exists so `cloneData()` (below)
  /// can reuse this initializer for everything *except* the one step `RamState.clone()` does and
  /// `DualRamState.clone()` does not. See the file header.
  init(
    contents: MemContents, parent: StdInstanceComponent?, listener: Mem.MemListener?,
    attachListener: Bool = true
  ) {
    self.listener = listener
    self.stateB = MemState(contents)
    super.init(contents)
    self.parent = parent
    if let parent {
      subscription = parent.attributeSet.addAttributeListener(self)
    }
    if attachListener, let listener {
      contents.addHexModelListener(listener)
    }
  }

  /// `getPortBState()`.
  func portBState() -> MemState { stateB }

  // MARK: AttributeListener

  /// `attributeValueChanged(AttributeEvent)`.
  public func attributeValueChanged(_ event: AttributeEvent) {
    guard
      let addrBits = event.source.getValue(Mem.addr),
      let dataBits = event.source.getValue(Mem.data)
    else { return }
    // `getContents().setDimensions(...)`. Upstream's call cannot fail: both widths came through
    // already-bounds-checked attributes. `try?` matches that in spirit (D13; nothing a `.circ`
    // file can do reaches a real failure here) without introducing a trap.
    try? getContents().setDimensions(addrBits: addrBits.width, width: dataBits.width)
  }

  // MARK: Cloning

  /// `clone()`. See the file header for the two things this deliberately does differently from
  /// what `MemState.swift` documents `RamState.clone()` doing.
  public override func cloneData() -> any InstanceData {
    let copy = DualRamState(
      contents: getContents().cloneContents(), parent: nil, listener: listener,
      attachListener: false)
    cloneBaseState(into: copy)
    copy.clockState0 = clockState0
    copy.clockState1 = clockState1
    // `ret.stateB = this.stateB.clone();`; `stateB` is always constructed as a bare `MemState`
    // (never a subclass), so its own `cloneData()` is guaranteed to hand back a `MemState`; this
    // is an internal invariant of this file's own constructor, not something a `.circ` file can
    // violate (D13).
    copy.stateB = (stateB.cloneData() as! MemState)
    return copy
  }

  // MARK: Per-port clock

  /// `setClock(int, Value, Object)`.
  func setClock(portIndex: Int, newClock: Value, trigger: AttributeOption?) -> Bool {
    portIndex == 0
      ? clockState0.updateClock(newClock, trigger: trigger)
      : clockState1.updateClock(newClock, trigger: trigger)
  }

  // MARK: Re-parenting (`setRam`)

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

  // MARK: Per-port address bookkeeping

  /// `getCurrent(int)`.
  func current(portIndex: Int) -> Int64 {
    portIndex == 0 ? getCurrent() : stateB.getCurrent()
  }

  /// `setCurrent(int, long)`.
  func setCurrent(portIndex: Int, _ value: Int64) {
    if portIndex == 0 {
      setCurrent(value)
    } else {
      stateB.setCurrent(value)
    }
  }

  /// `scrollToShow(int, long)`.
  func scrollToShow(portIndex: Int, _ addr: Int64) {
    if portIndex == 0 {
      scrollToShow(addr)
    } else {
      stateB.scrollToShow(addr)
    }
  }

  // MARK: Hit testing (M6)

  /// `getAddressAt(int, int)`: try port A's grid, then port B's.
  ///
  /// The two grids are drawn one above the other, so a click can only ever land in one of them;
  /// upstream's "A first, then B" order is what decides which, and is kept.
  public override func addressAt(x: Int, y: Int) -> Int64 {
    let addrA = super.addressAt(x: x, y: y)
    if addrA != -1 { return addrA }
    return stateB.addressAt(x: x, y: y)
  }
}
