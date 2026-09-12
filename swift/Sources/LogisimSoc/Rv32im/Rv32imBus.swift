/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * SEAM, not a port of a single Java file. Java's memory/bus traffic goes through
 * `SocBusTransaction` + `SocSimulationManager` (soc/data, soc/util: outside this slice's
 * ownership: `~/Developer/logisim/logisim-evolved/swift/Sources/LogisimSoc/Rv32im/` only).
 * Rather than depend on those unported types, this protocol is the minimum the RV32IM core
 * needs from "the SoC bus", modeled on what `RV32imLoadAndStoreInstructions`,
 * `RV32imState.execute()` (instruction fetch) and `Rv32imPlicState` (as a bus *slave*)
 * actually call.
 *
 * That was written when `soc/data` was unavailable to this slice and said task #24 owned
 * satisfying it. It does: `Rv32imSocBusPort` (Rv32imSocBusPort.swift) implements this protocol
 * from the real `SocSimulationManager`/`SocBusTransaction` machinery, and `SocBusFabric` does
 * the address routing to each slave's `SocBusSlaveInterface.handleTransaction(_:)`.
 *
 * The protocol stays, rather than being replaced by `SocBusTransaction` at every call site,
 * because it is genuinely the narrower thing: three operations, no error object to thread, and
 * `step(bus:)` taking it means a test can drive the core against a hand-written memory without
 * standing up a bus fabric. It is now a *seam with a conformer*, which is the difference
 * between an abstraction and a gap.
 */

/// Java: `SocBusTransaction.BYTE_ACCESS` / `HALF_WORD_ACCESS` / `WORD_ACCESS`.
public enum Rv32imAccessSize: Equatable {
  case byte
  case halfWord
  case word
}

/// A bus-level failure. Java's `SocBusTransaction` never throws for this; a transaction
/// carries an error flag and message that the caller (`RV32imState.execute()`,
/// `RV32imLoadAndStoreInstructions.execute()`) inspects with `trans.hasError()` and turns into
/// a **soft** failure: a dialog (a log line under D17 headless) plus `simState.errorInExecution()`,
/// never a thrown exception. This type exists so a *bus implementation* can signal that softly
/// (D13: a malformed access must not crash the app) without this module needing to depend on
/// `SocBusTransaction` to build one. See `Rv32imLoadAndStoreInstructions.execute` and
/// `Rv32imProcessorState.step` for where a thrown `Rv32imBusError` is caught and folded back
/// into exactly that Java soft-failure shape, rather than being allowed to propagate as a
/// genuine Swift `throw` out of `step`.
public struct Rv32imBusError: Error {
  public let message: String
  public init(_ message: String) { self.message = message }
}

/// What the RV32IM core needs from "the SoC bus" as a **master** (fetching instructions,
/// executing loads/stores). Java: `SocSimulationManager.initializeTransaction` building and
/// running a `SocBusTransaction` against whichever bus this CPU is attached to
/// (`RV32imState.attachedBus`).
public protocol Rv32imBus: AnyObject {
  /// Java: `RV32imState.execute()`'s instruction fetch; a `READ_TRANSACTION` of
  /// `WORD_ACCESS` at `pc`. Kept distinct from `read(at:size:)` because a real bus may account
  /// fetches separately (e.g. for the sniffer interface `Rv32imRiscV.getSnifferInterface`
  /// does NOT provide, since it always returns `null` in 4.1.0, verified, not an omission).
  func fetchInstruction(at address: Int) throws -> Int
  /// Java: `RV32imLoadAndStoreInstructions.execute()`'s `LB`/`LH`/`LW`/`LBU`/`LHU` path,
  /// which always issues a `WORD_ACCESS`-independent transaction sized by `size` and then
  /// sign/zero-extends the *already narrowed* result itself; the bus is only ever asked for
  /// a value that already fits in `size`; sign/zero-extension to 32 bits is this module's job,
  /// not the bus's, exactly mirroring the Java division of labour.
  func read(at address: Int, size: Rv32imAccessSize) throws -> Int
  /// Java: the `SB`/`SH`/`SW` path. `value` arrives already masked to `size` by the caller
  /// (`RV32imLoadAndStoreInstructions.execute`), matching `toBeStored &= 0xFF` / `0xFFFF`.
  func write(_ value: Int, at address: Int, size: Rv32imAccessSize) throws
}

// ── `Rv32imSlaveTransaction` / `Rv32imBusSlave` were here, and are gone ─────────────────────
//
// They stood in for `SocBusTransaction`/`SocBusSlaveInterface` while this slice could not see
// `soc/data`. It can: both live in this same module now, and the stand-ins had exactly one
// conformer (`Rv32imPlicState`) and **zero callers**: so the PLIC implemented a protocol no
// bus dispatched to, which is the same "nothing owns the join" shape as every other seam here.
// `Rv32imPlicState` now conforms to `SocBusSlaveInterface` directly, which also recovers the
// error *codes* the string-only `errorMessage` field had flattened.
