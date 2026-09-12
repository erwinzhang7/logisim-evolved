// SocBusInterfaces.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.{SocBusMasterInterface,
// SocBusSlaveInterface, SocBusSlaveListener, SocBusSnifferInterface, SocProcessorInterface}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// One file for the five small SPI-style protocols that every bus participant implements, since
// none is more than a handful of methods and they are always read together.
//
// ── Seam: `CircuitState` ─────────────────────────────────────────────────────────────────────
//
// Upstream passes the live `com.cburch.logisim.circuit.CircuitState` into
// `initializeTransaction`/`insertTransaction` so a master can start a transaction against
// whichever circuit instance it is propagating in (needed for subcircuits; the same SoC
// component template can be instantiated many times). This module owns none of the simulation
// core, so `CircuitState` is represented here as `any SocCircuitStateToken`: an opaque,
// hashable handle. The simulation module's real `CircuitState` needs only to conform (trivially,
// since D4 already keys everything on reference identity): `extension CircuitState:
// SocCircuitStateToken {}`. Every consumer in this module treats the token opaquely; it is
// threaded through and handed back to `SocSimulationManager`, never inspected.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// Seam for `com.cburch.logisim.circuit.CircuitState` (see file header).
///
/// Reference identity is what most SoC types need (they thread the token through opaquely), but
/// `SocSimulationManager` additionally needs the two accessors Java calls directly on
/// `CircuitState`: `getData(Component)` (`SocSimulationManager.getdata`, used by every
/// peripheral's `getRegPropagateState()` to reach its own live register state) and
/// `getInstanceState(Component)` (`SocSimulationManager.getState`, used by `PioState
/// .getPropagateState()` to re-invoke `handleOperations` on a register write). The simulation
/// module's real `CircuitState` conforms by forwarding to its existing `componentData`/
/// `getInstanceState`: no new storage, since D4 already keys both by component reference
/// identity exactly as these two methods assume.
public protocol SocCircuitStateToken: AnyObject {
  /// `CircuitState.getData(Component)`.
  func socComponentData(for component: any Component) -> AnyObject?
  /// `CircuitState.getInstanceState(Component)`.
  func socInstanceState(for component: any Component) -> (any InstanceState)?
}

/// `com.cburch.logisim.soc.data.SocBusMasterInterface`.
///
/// `circuitState` is Optional for the same reason as `SocProcessorInterface`'s: Java's
/// `initializeTransaction` assigns `state = cState` unconditionally and `null` is a value real
/// callers pass.
public protocol SocBusMasterInterface: AnyObject {
  func initializeTransaction(
    _ transaction: SocBusTransaction, busId: String,
    circuitState: (any SocCircuitStateToken)?)
}

/// `com.cburch.logisim.soc.data.SocBusSlaveListener`.
public protocol SocBusSlaveListener: AnyObject {
  func labelChanged()
  func memoryMapChanged()
}

/// `com.cburch.logisim.soc.data.SocBusSlaveInterface`.
public protocol SocBusSlaveInterface: AnyObject {
  func canHandleTransaction(_ transaction: SocBusTransaction) -> Bool
  func handleTransaction(_ transaction: SocBusTransaction)
  var startAddress: Int32 { get }
  var memorySize: Int32 { get }
  var slaveName: String { get }
  func registerListener(_ listener: any SocBusSlaveListener)
  func removeListener(_ listener: any SocBusSlaveListener)
  var component: (any Component)? { get }
}

/// `com.cburch.logisim.soc.data.SocBusSnifferInterface`.
public protocol SocBusSnifferInterface: AnyObject {
  func sniffTransaction(_ transaction: SocBusTransaction)
}

/// `com.cburch.logisim.soc.data.SocProcessorInterface`.
///
/// `ElfProgramHeader`/`ElfSectionHeader` are this module's own (`File/`), so the ELF loader and
/// every CPU core (owned by the Rv32im/Nios2 slices) share this one signature.
///
/// ── Every reference parameter is Optional, and each one is Optional in the Java too ──────────
///
/// This was not so until the two views of this interface were collapsed into one, and the
/// non-optional version made two of upstream's own call sites unrepresentable:
///
/// | parameter | who passes null in 4.1.0 |
/// |---|---|
/// | `circuitState` | `RV32imState.insertTransaction` explicitly branches on `cState == null` and recovers the state from the attached component (`RV32imState.java:628-640`), so `null` is a *supported* argument, not a defensive check |
/// | `programHeader` | `AssemblerPanel.java:259`, `cpu.setEntryPointandReset(circuitState, entryPoint, null, assembler.getSectionHeader())`; assembling from source produces no ELF program header |
///
/// `sectionHeader` follows `programHeader` because the same call site pairs them and a future
/// caller assembling without sections would otherwise have to fabricate an empty one.
///
/// Making them non-optional does not "tighten" anything: it moves a `null` upstream passes
/// deliberately into a place the type system forbids, which is how a port ends up inventing a
/// dummy value whose behaviour nobody checked against the Java.
public protocol SocProcessorInterface: AnyObject {
  /// `setEntryPointandReset(CircuitState, long, ElfProgramHeader, ElfSectionHeader)`.
  func setEntryPointAndReset(
    circuitState: (any SocCircuitStateToken)?, entryPoint: Int64,
    programHeader: ElfProgramHeader?, sectionHeader: ElfSectionHeader?)
  /// `insertTransaction(SocBusTransaction, boolean, CircuitState)`.
  func insertTransaction(
    _ transaction: SocBusTransaction, hidden: Bool, circuitState: (any SocCircuitStateToken)?)
  /// `getEntryPoint(CircuitState)`.
  func entryPoint(_ circuitState: (any SocCircuitStateToken)?) -> Int32
}
