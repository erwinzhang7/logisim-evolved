// SocBusFabric.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocBusStateInfo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the actual bus-arbitration logic: given a transaction and the slaves registered on
// this bus, decide whether zero, one, or more than one slave claims the address, dispatch to
// the single claimant, run sniffers, and record a trace entry. Everything else `SocBusStateInfo`
// did in Java (it was simultaneously the `JDialog` for the memory-map inspector window and the
// per-instance trace-log painter) is UI and is dropped per D6/D9: see the per-type notes below.
//
// ── Split from upstream's one God-class into two model types ───────────────────────────────────
//
//   * `SocBusFabric`: one per placed `SocBus` component (Java: one `SocBusStateInfo`, keyed by
//     bus id, inside `SocSimulationManager.socBusses`). Owns the registered slave/sniffer lists
//     (via `SocMemoryMap`) and `initializeTransaction`, which is the actual arbitration Java's
//     method of the same name performs: ported field-for-field, including the exact ordering
//     (no-slaves check, then non-atomic-RW check, then the claim scan, then sniffing, then the
//     trace append) since a reordering here would change which error a malformed circuit sees.
//   * `SocBusTraceLog`: Java's inner `SocBusState` (`InstanceData`), the per-simulation-run
//     ring buffer of the last 10,000 transactions. Kept separate because it is *instance data*
//     (reset when the simulation resets; it is what `SocBus.propagate` clears on a rising
//     reset edge) whereas `SocBusFabric` is *configuration* (persists across simulation runs,
//     like the slave list itself).
//
// Not ported: `SocBusStateInfo`'s entire `JDialog`/`JTable`/`JButton` body, `SocBusStateTrace`
// (a `JPanel` that paints one trace row), `SocBusState.paint`/`getEntry` (row rendering). The UI
// layer renders a trace from `SocBusTraceLog.entries` (below) directly; every field
// `SocBusTransaction.paint` read (`address`, `readData`/`writeData`, `accessType`, `kind`,
// `error`, `initiator`, `responder`) is already public on `SocBusTransaction`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocBusStateInfo.SocBusState` minus its `JDialog`/paint half: the per-run trace ring buffer.
/// One instance lives in a component's `InstanceData` slot (mirroring upstream: `SocBus
/// .propagate` creates it via `getNewState()` on first propagation and clears it on reset).
public final class SocBusTraceLog: InstanceData {
  /// `NR_OF_TRACES_TO_KEEP`.
  public static let maxEntries = 10_000

  private var trace: [SocBusTransaction] = []
  public private(set) var startTraceIndex: Int64 = 0

  public init() {}

  /// `addTransaction(SocBusTransaction)`.
  public func add(_ transaction: SocBusTransaction) {
    while trace.count >= Self.maxEntries {
      startTraceIndex += 1
      trace.removeFirst()
    }
    trace.append(transaction)
  }

  /// `clear()`.
  public func clear() {
    guard !trace.isEmpty else { return }
    trace.removeAll()
    startTraceIndex = 0
  }

  /// `getNrOfEntires()`.
  public var count: Int { trace.count }

  /// The trace entries, oldest first: the UI walks this directly instead of upstream's
  /// index-juggling `getEntry(int, TraceWindowTableModel)`.
  ///
  /// `gui/TraceWindowTableModel` itself is **not ported**, and a parity survey of
  /// `com/cburch/logisim/soc` found it cited here and declared excluded nowhere, so the record
  /// belongs on the property that replaces it. It is a `javax.swing.table.AbstractTableModel`
  /// (`TraceWindowTableModel.java:34`) that is also a `BaseMouseListenerContract`,
  /// `SocBusStateListener`, `ComponentListener` and `CircuitListener`: one column per traced
  /// bus in `myTraceList` (`:111`), plus two `TableCellRenderer` inner classes. Its only
  /// non-Swing content is the arithmetic mapping a table row onto a ring-buffer slot, and that
  /// exists solely because upstream hands the widget a row index instead of a list; returning
  /// `[SocBusTransaction]` here makes it unnecessary rather than dropping it. The cost is the
  /// **trace window** as a window: the entries are all here, and a viewer can be built over
  /// this property at any time with no further porting.
  public var entries: [SocBusTransaction] { trace }

  /// `InstanceData.clone()`.
  ///
  /// Deviation, deliberate: Java's `SocBusState.clone()` is a shallow `Object.clone()`; a
  /// *new* object whose `LinkedList` field is the same shared reference as the original, so a
  /// forked `CircuitState`'s clone and the original silently corrupt each other's
  /// `startTraceIndex` bookkeeping the next time either side calls `addTransaction`/`clear`
  /// (each mutates the one shared list but only its own copy of the index counter). That is a
  /// latent upstream bug, not a behaviour anything depends on; a debug trace window
  /// momentarily miscounting entries after a circuit fork is not worth reproducing at the cost
  /// of a genuinely shared mutable list between two `InstanceData` instances here. The port
  /// gives the clone its own copy of the current entries instead.
  public func cloneData() -> any InstanceData {
    let copy = SocBusTraceLog()
    copy.trace = trace
    copy.startTraceIndex = startTraceIndex
    return copy
  }
}

/// `com.cburch.logisim.soc.data.SocBusStateInfo`, minus the `JDialog` (see file header). One per
/// placed `SocBus` component, keyed by bus id in `SocSimulationManager`.
public final class SocBusFabric {
  private let memoryMap = SocMemoryMap()
  private var sniffers: [any SocBusSnifferInterface] = []

  /// `myComp` / `setComponent`/`getComponent`. Weak: this fabric is reachable *from* the
  /// component's simulation-manager registration, not the other way (D3).
  public weak var component: (any Component)?

  public init(component: any Component) {
    self.component = component
  }

  /// `registerSocBusSlave` / `removeSocBusSlave`.
  public func registerSlave(_ slave: any SocBusSlaveInterface) { memoryMap.registerSlave(slave) }
  public func removeSlave(_ slave: any SocBusSlaveInterface) { memoryMap.removeSlave(slave) }

  /// `registerSocBusSniffer` / `removeSocBusSniffer`.
  public func registerSniffer(_ sniffer: any SocBusSnifferInterface) {
    guard !sniffers.contains(where: { $0 === sniffer }) else { return }
    sniffers.append(sniffer)
  }
  public func removeSniffer(_ sniffer: any SocBusSnifferInterface) {
    sniffers.removeAll { $0 === sniffer }
  }

  /// `getSlaves()`.
  public var slaves: [any SocBusSlaveInterface] { memoryMap.registeredSlaves }

  /// `initializeTransaction(SocBusTransaction, String)`; the arbitration logic. `traceLog` is
  /// the calling component's own per-run trace (Java reaches it via
  /// `getRegPropagateState()`/`socManager.getdata(myComp)`; the caller here already has it,
  /// since the simulation module owns per-component instance data, not this module).
  ///
  /// Ordering preserved exactly, including that a non-atomic combined read+write is checked
  /// *before* the slave scan runs at all; a transaction that is simultaneously malformed in
  /// both ways always reports `nonAtomicReadWrite`, never `noResponse`, matching upstream.
  public func initializeTransaction(_ transaction: SocBusTransaction, traceLog: SocBusTraceLog?) {
    if memoryMap.registeredSlaves.isEmpty {
      transaction.setError(.noSlaves)
    } else if transaction.isReadTransaction && transaction.isWriteTransaction
      && !transaction.isAtomicTransaction
    {
      transaction.setError(.nonAtomicReadWrite)
    } else {
      var responderIndex: Int? = nil
      var responderCount = 0
      let candidates = memoryMap.registeredSlaves
      for (index, slave) in candidates.enumerated() where slave.canHandleTransaction(transaction) {
        responderCount += 1
        responderIndex = index
      }
      if responderCount == 0 {
        transaction.setError(.noResponse)
      } else if responderCount != 1 {
        transaction.setError(.multipleSlaves)
      } else if let responderIndex {
        candidates[responderIndex].handleTransaction(transaction)
      }
    }
    if !transaction.hasError && !transaction.isHidden {
      for sniffer in sniffers {
        sniffer.sniffTransaction(transaction)
      }
    }
    if !transaction.isHidden {
      traceLog?.add(transaction)
    }
  }
}
