// Rv32imSocBusPort.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.rv32im.RV32imState's bus half),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CLOSES THE SEAM `Rv32imBus.swift` NAMES BY NUMBER
//
// `Rv32imBus.swift`'s header says, verbatim:
//
//     Whoever ports `soc/data`/`soc/util` (task #24, the wider SoC subsystem) owns satisfying
//     this protocol from the real `SocSimulationManager`/`SocBusTransaction` machinery […]
//
// This is that. `Rv32imBus` was written as the minimum the RV32IM core needs from "the SoC bus",
// with no implementation anywhere in the tree, so `Rv32imProcessorState.step(bus:)` was
// uncallable and the core, complete down to the M-extension's division semantics, could not
// fetch a single instruction.
//
// ── The three protocol methods are ONE Java call, three times ────────────────────────────────
//
// Java builds a `SocBusTransaction` at each site and hands it to
// `attachedBus.getSocSimulationManager().initializeTransaction(trans, attachedBus.getBusId(),
// cState)`, then inspects `trans.hasError()`. The sites differ only in kind and access size:
//
// | `Rv32imBus` method | Java site | transaction |
// |---|---|---|
// | `fetchInstruction(at:)` | `RV32imState.java:318-327` | READ, WORD, address `pc` |
// | `read(at:size:)` | `RV32imLoadAndStoreInstructions.java:98-105` | READ, `size` |
// | `write(_:at:size:)` | `RV32imLoadAndStoreInstructions.java:79-86` | WRITE, `size` |
//
// The initiator is `attachedBus.getComponent()` at all three; `getMasterComponent()`
// (`RV32imState.java:296`) is literally `return attachedBus.getComponent();`, so the fetch site
// spelling it out directly and the load/store sites going through the getter are the same value.
//
// ── Errors: `throws`, and why that is still D13-faithful ────────────────────────────────────
//
// Java does not throw here; a failed transaction is a flag on the object, which the caller
// turns into a dialog plus `simState.errorInExecution()`. `Rv32imBus` chose `throws` because
// Swift has no out-parameter idiom that reads as well, and `Rv32imProcessorState.step` already
// catches `Rv32imBusError` and folds it back into exactly Java's soft-failure shape
// (`.fetchError` / `false` from the load-store unit). Nothing here escapes to the caller as a
// Swift error that Java would not have surfaced as a circuit error, which is what D13 asks.
//
// ── What is NOT here ────────────────────────────────────────────────────────────────────────
//
// `RV32imState.insertTransaction`'s `cState == null` recovery path (`RV32imState.java:628-640`)
// reaches through `InstanceComponent.getInstanceStateImpl().getProject().getCircuitState()` to
// find a circuit state when the caller has none. `Project` is not a type this module can name,
// and the recovery only matters for the assembler window's "download" button, which has a live
// circuit state anyway. A `nil` circuit state here reaches `initializeTransaction` as `nil`,
// exactly as Java's `null` does when the recovery finds nothing; the transaction still runs,
// and the peripherals that need a state to reach their own data answer as they do for any
// unknown component.

import Foundation
import LogisimFile
import LogisimKernel

/// Satisfies `Rv32imBus` from the real SoC bus fabric.
///
/// One per placed RV32IM component per simulation run. Holds the component's own `SocBusInfo`
/// (which is where both the bus id and the live `SocSimulationManager` live: see
/// `SocBusInfo.attach(to:component:)`), and the circuit state the current propagation is
/// running in.
public final class Rv32imSocBusPort: Rv32imBus {

  /// Java: `RV32imState.attachedBus`. Strong, and correctly so: this port object is owned by
  /// the per-run processor state, while `SocBusInfo` is owned by the component's attribute set
  /// and holds only weak edges of its own (`simulationManager`, `component`), so no cycle
  /// closes here.
  public let attachedBus: SocBusInfo

  /// The `CircuitState` the current propagation is running in. Weak (D3): a bus port must never
  /// keep a circuit state alive, and a stale one must read as absent rather than as a live
  /// state belonging to a finished run.
  public weak var circuitState: (any SocCircuitStateToken)?

  /// The initiating component's per-run trace ring buffer, if the caller can supply one. Java
  /// reaches it inside `SocBusStateInfo.initializeTransaction` via
  /// `socManager.getdata(myComp)`; this module does not own per-component instance data, so the
  /// caller passes a closure. `nil` means "do not trace", which loses only the debug window's
  /// history, never a transaction's result.
  public var traceLog: (() -> SocBusTraceLog?)?

  public init(
    attachedBus: SocBusInfo,
    circuitState: (any SocCircuitStateToken)? = nil,
    traceLog: (() -> SocBusTraceLog?)? = nil
  ) {
    self.attachedBus = attachedBus
    self.circuitState = circuitState
    self.traceLog = traceLog
  }

  // MARK: - Rv32imBus

  public func fetchInstruction(at address: Int) throws -> Int {
    let transaction = try run(
      kind: .read, address: address, writeData: 0, accessType: .word)
    return Int(transaction.readData)
  }

  public func read(at address: Int, size: Rv32imAccessSize) throws -> Int {
    let transaction = try run(
      kind: .read, address: address, writeData: 0, accessType: Self.accessType(size))
    return Int(transaction.readData)
  }

  public func write(_ value: Int, at address: Int, size: Rv32imAccessSize) throws {
    _ = try run(
      kind: .write, address: address, writeData: Int32(truncatingIfNeeded: value),
      accessType: Self.accessType(size))
  }

  // MARK: - Internals

  /// `SocBusTransaction.BYTE_ACCESS`/`HALF_WORD_ACCESS`/`WORD_ACCESS`. Two enums for one Java
  /// `int` because `Rv32imBus` is deliberately independent of `soc/data`; this function is the
  /// only place the two meet.
  private static func accessType(_ size: Rv32imAccessSize) -> SocAccessType {
    switch size {
    case .byte: return .byte
    case .halfWord: return .halfWord
    case .word: return .word
    }
  }

  private func run(
    kind: SocTransactionKind, address: Int, writeData: Int32, accessType: SocAccessType
  ) throws -> SocBusTransaction {
    // Java passes the raw `int` address; `Int32(truncatingIfNeeded:)` is that cast, and the
    // callers keep every address wrap32'd already (see `Rv32imBits`'s convention note).
    let transaction = SocBusTransaction(
      kind: kind, address: Int32(truncatingIfNeeded: address), writeData: writeData,
      accessType: accessType, initiator: initiator)

    guard let manager = attachedBus.simulationManager else {
      // Java: `attachedBus.getSocSimulationManager()` is null only before any
      // `registerComponent` has run; `DmaState.java:271` guards the same way and returns
      // silently. Here the transaction is failed explicitly so the caller sees a bus error
      // rather than a zero read that looks like a successful fetch of `nop`-shaped garbage.
      transaction.setError(.noSocBusConnected)
      throw Rv32imBusError(transaction.error.description)
    }

    manager.initializeTransaction(
      transaction, busId: attachedBus.busId, circuitState: circuitState, traceLog: traceLog)

    if transaction.hasError {
      throw Rv32imBusError(transaction.error.description)
    }
    return transaction
  }

  /// Java: `cpuState.getMasterComponent()` / `attachedBus.getComponent()`: the same value.
  /// Falls back to a named initiator when the component back-pointer is not set, which is what
  /// `SocBusTransaction`'s `.named` case exists for; upstream would pass `null` there and the
  /// trace window would render an empty master column.
  private var initiator: SocTransactionInitiator {
    if let component = attachedBus.component { return .component(component) }
    return .named("Rv32im")
  }
}
