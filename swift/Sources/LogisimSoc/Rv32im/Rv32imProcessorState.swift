/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imState.java (4.1.0), the outer config class and its inner
 * `ProcessorState`, MODEL ONLY (D9). Everything Swing/AWT-shaped is dropped and reported
 * below rather than ported, per the binding rule that this module carries no AppKit/UIKit/
 * SwiftUI/CoreGraphics:
 *
 *   DROPPED (UI, D9)                         | Java
 *   ------------------------------------------|--------------------------------------------
 *   `ProcessorState extends JPanel`, `paint`, | drawing; a future LogisimUI CPU-state
 *   `draw`, `windowOpened/…` (WindowListener)  | inspector renders this MODEL, not itself.
 *   `BreakpointPanel bPanel` (assembly editor  | replaced by a plain `Set<Int>` of PC
 *   with line numbers), `bPanel.gotoLine`      | addresses; "jump the editor to a line" has
 *                                              | no headless meaning.
 *   `SocUpMenuProvider` (de)registration       | menu/window-list wiring; UI shell concern.
 *   `OptionPane.showMessageDialog` on every    | replaced by `Rv32imStepOutcome` values the
 *   soft failure (fetch error, invalid opcode, | caller inspects and may present however it
 *   execute() == false, MOI/ECALL "not         | likes (a log line under D17 headless, a
 *   implemented" notices, breakpoint reached)  | dialog with a UI). No message is ever lost;
 *                                              | it comes back as data, not a side effect.
 *   `AbstractTokenMakerFactory` registration    | the RSyntaxTextArea wiring only.
 *                                              | `Rv32imSyntaxHighlighter` itself IS ported;
 *                                              | it is the lexer's word map, not colouring.
 *
 * CLOSED (was a seam): `attachedBus`/bus I/O. `Rv32imConfig` now owns the `SocBusInfo`, as
 * `RV32imState` does, and `Rv32imSocBusPort` satisfies `Rv32imBus` from the real
 * `SocSimulationManager`/`SocBusTransaction` fabric. `step(bus:)` still takes the bus explicitly
 * so a test can drive the core against its own; `setClock(high:circuitState:)` is what
 * `Rv32imRiscV.propagate` calls, and it uses this state's own `busPort`.
 *
 * SEAM: `Rv32imSimulationState` mirrors the pure state-machine half of
 * `soc/data/SocUpSimulationState.java` (RUNNING / HALTED_BY_ERROR / HALTED_BY_BREAKPOINT /
 * HALTED_BY_STOP, `canExecute`/`breakPointReached`/`errorInExecution`/`buttonPressed`/`reset`).
 * That Java file lives in `soc/data`, not `soc/rv32im`, so it is not this slice's file to own
 * , but `RV32imState.execute()`'s control flow is unusable without it, so a concrete
 * `Rv32imDefaultSimulationState` mirroring its logic (not its `paint`/listener/Swing half) is
 * provided here as a working default. Whichever slice ports `soc/data` for real should either
 * satisfy `Rv32imSimulationState` from the genuine port or this default should be deleted in
 * favor of it; reported as a seam, not claimed as the `soc/data` port.
 */

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - Static register/CSR tables (Java: RV32imState's static fields and lookups)

/// Java: `RV32imState.registerABINames`.
public enum Rv32imRegisterNames {
  public static let abi: [String] = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4",
    "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4",
    "t5", "t6",
  ]

  /// Java: `getRegisterIndex(String)`. Case-insensitive ABI name, or `x<n>` for `n` in
  /// `0..<1000` textually (Java: `regName.length() < 4` after the `x`: i.e. up to 3 digits,
  /// so `x999` parses but is later range-checked by the caller against 0...31, exactly as
  /// ported here: this function returns whatever `Integer.parseUnsignedInt` would, including
  /// out-of-range values, and range-checking is the caller's job in both Java and here).
  /// Returns `-1` on failure, matching Java (never throws; this is assembler-input parsing,
  /// reachable from a user-typed program).
  public static func index(of name: String) -> Int {
    let regName = name.lowercased()
    if let i = abi.firstIndex(of: regName) { return i }
    if regName.hasPrefix("x") && regName.count < 4 {
      let digits = regName.dropFirst()
      if let value = UInt32(digits) { return Int(value) }
      return -1
    }
    return -1
  }
}

/// Java: `RV32imState`'s implemented-SPR tables and lookups. Kept as a standalone enum
/// (rather than nested in `Rv32imProcessorState`) since Java exposes them as `static` on the
/// outer class, reachable without an instance (`RV32imState.isSprImplemented`, etc.).
public enum Rv32imCsr {
  /// Java: `implementedSprs`: raw 12-bit CSR addresses, in the array order that
  /// `getSprArrayIndex` and the `csrs[]` storage array both index by.
  public static let implementedAddresses: [Int] = [
    0xF11, 0xF12, 0xF13, 0xF14, 0x300, 0x301, 0x304, 0x305,
    0x340, 0x341, 0x342, 0x343, 0x344, 0x7B0, 0x7B1, 0x7A0, 0x7A1, 0x7A2, 0x7A4,
  ]

  /// Java: `implementedSprNames`, parallel to `implementedAddresses`.
  public static let implementedNames: [String] = [
    "MVENDORID", "MARCHID", "MIMPID", "MHARTID", "MSTATUS", "MISA", "MIE", "MTVEC",
    "MSCRATCH", "MEPC", "MCAUSE", "MTVAL", "MIP", "DCSR", "DPC", "TSELECT", "TDATA1", "TDATA2",
    "TINFO",
  ]

  /// Java: `getSprArrayIndex(int)`: despite the name, `index` here is the raw CSR *address*
  /// (e.g. `0x300`), and the return value is its position in `implementedAddresses`/`csrs[]`,
  /// or `-1`. Every call site in the Java (including this file's own `IDX_*` constants) passes
  /// a raw address, never an already-resolved array position; the naming is confusing in the
  /// Java and is preserved rather than "fixed", since fixing it here and not in the mental
  /// model of anyone cross-referencing the Java would be its own source of bugs.
  public static func arrayIndex(ofAddress address: Int) -> Int {
    implementedAddresses.firstIndex(of: address) ?? -1
  }

  /// Java: `getSprArrayIndex(String)`: case-insensitive name lookup, returning the same
  /// array position space as the address overload above.
  public static func arrayIndex(ofName name: String) -> Int {
    implementedNames.firstIndex(of: name.uppercased()) ?? -1
  }

  /// Java: `isSprImplemented(int)`.
  public static func isImplemented(address: Int) -> Bool { arrayIndex(ofAddress: address) != -1 }

  /// Java: `getSprName(int)`: lower-cased mnemonic if implemented, else `0x%03X` of the raw
  /// address.
  public static func name(ofAddress address: Int) -> String {
    let idx = arrayIndex(ofAddress: address)
    if idx != -1 { return implementedNames[idx].lowercased() }
    return String(format: "0x%03X", address)
  }

  /// Java: `getSprValue(int)`: the raw address stored at array position `index`, or `-1` if
  /// `index` is out of `implementedAddresses`' bounds (Java: `index < 0 || index >=
  /// implementedSprs.length`).
  public static func address(atArrayIndex index: Int) -> Int {
    (index < 0 || index >= implementedAddresses.count) ? -1 : implementedAddresses[index]
  }
}

// MARK: - Trace history (Java: soc/data/TraceInfo.java, data half only)

/// Mirrors `soc/data/TraceInfo.java`'s data fields (`pc`, `instruction`, `asm`, `error`): not
/// its `paint`. `TraceInfo` lives in `soc/data`, outside this slice; duplicated here as a small
/// value type rather than left unported, since `RV32imState.execute()`'s trace ring buffer is
/// part of the processor's observable state (what a debugger view would show), not UI itself.
public struct Rv32imTraceInfo {
  public let pc: Int
  public let instruction: Int
  public let asmText: String
  public var isError: Bool

  public init(pc: Int, instruction: Int, asmText: String, isError: Bool) {
    self.pc = pc
    self.instruction = instruction
    self.asmText = asmText
    self.isError = isError
  }
}

// MARK: - Simulation run/halt state (seam over soc/data/SocUpSimulationState.java)

public protocol Rv32imSimulationState: AnyObject {
  var canExecute: Bool { get }
  func errorInExecution()
  /// Java: `breakPointReached()`; returns `true` the first time a given halt is reached
  /// (and transitions to halted-by-breakpoint), `false` if a prior `buttonPressed()` already
  /// armed a one-shot "continue through this breakpoint" (`canContinueAfterBreak`).
  func breakPointReached() -> Bool
  func buttonPressed()
  func reset()
}

/// A working default implementing the exact state machine in
/// `soc/data/SocUpSimulationState.java` (`SIMULATION_RUNNING` /
/// `SIMULATION_HALTED_BY_ERROR` / `SIMULATION_HALTED_BY_BREAKPOINT` /
/// `SIMULATION_HALTED_BY_STOP`, `canContinueAfterBreak`), minus its listener list and `paint`.
public final class Rv32imDefaultSimulationState: Rv32imSimulationState {
  private enum State: Equatable { case running, haltedByError, haltedByBreakpoint, haltedByStop }
  private var state: State = .haltedByStop
  private var canContinueAfterBreak = false

  public init() {}

  public var canExecute: Bool { state == .running }

  public func errorInExecution() { state = .haltedByError }

  public func breakPointReached() -> Bool {
    if canContinueAfterBreak {
      canContinueAfterBreak = false
      return false
    }
    state = .haltedByBreakpoint
    return true
  }

  public func buttonPressed() {
    if state == .running {
      state = .haltedByStop
    } else {
      if state == .haltedByBreakpoint { canContinueAfterBreak = true }
      state = .running
    }
  }

  public func reset() {
    canContinueAfterBreak = false
    state = .haltedByStop
  }
}

// MARK: - Outer config (Java: RV32imState, the outer class)

/// Java: `RV32imState` (the outer class): the attribute-backed configuration
/// `RV32imAttributes.upState` wraps: reset vector, IRQ count, label, attached-bus identity.
/// The `AttributeSet` wiring is `Rv32imAttributes.swift`; this doc used to say it was "not
/// ported (out of this slice)", which stopped being true once `#Soc` needed registerable tools.
/// This class carries the values; that one binds them to `Attribute<V>`/`AbstractAttributeSet`
/// and to `SocSimulationManager.socBusSelect`, and hands back **this object's** `attachedBus`
/// rather than a second `SocBusInfo` of its own.
public final class Rv32imConfig {
  public private(set) var resetVector: Int = 0
  public private(set) var numberOfIrqs: Int = 0
  public private(set) var label: String = ""

  /// Java: `private final SocBusInfo attachedBus` (`RV32imState.java:489`, initialised to
  /// `new SocBusInfo("")` at `:518`).
  ///
  /// This used to be a bare `attachedBusId: String`, with `Rv32imAttributes` owning a separate
  /// `SocBusInfo` and mirroring the id across on every write. That file's header called the
  /// difference "confined to a live simulation that re-assigns a bus id behind the attribute's
  /// back", which was true only while nothing simulated. `SocSimulationManager
  /// .registerComponent` attaches the manager and the placed component *to this object*, and
  /// `getEntryPoint`/`insertTransaction` read them back off it, so the CPU and the attribute set
  /// must be looking at one object, exactly as Java has them. Java's own `getValue(SOC_BUS_SELECT)`
  /// is literally `return upState.getAttachedBus();`.
  public let attachedBus = SocBusInfo("")

  /// Convenience for the several call sites that only want the id.
  public var attachedBusId: String { attachedBus.busId }

  public init() {}

  /// Java: `copyInto(RV32imState)`: note it copies the bus **id**, not the object, so each
  /// config keeps its own `SocBusInfo` identity (`RV32imState.java:525`).
  public func copyInto(_ dest: Rv32imConfig) {
    dest.resetVector = resetVector
    dest.numberOfIrqs = numberOfIrqs
    dest.label = label
    dest.attachedBus.busId = attachedBus.busId
  }

  /// Java: `setResetVector(int)`; returns whether the value actually changed, exactly as
  /// Java does (used by the attribute layer to decide whether to fire a change event; kept
  /// even though nothing in this slice fires events, since it is part of the ported surface
  /// a future `RV32imAttributes` needs unchanged).
  @discardableResult
  public func setResetVector(_ value: Int) -> Bool {
    if resetVector == value { return false }
    resetVector = value
    return true
  }

  @discardableResult
  public func setNumberOfIrqs(_ value: Int) -> Bool {
    if numberOfIrqs == value { return false }
    numberOfIrqs = value
    return true
  }

  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    if label == value { return false }
    label = value
    return true
  }

  /// Java: `setAttachedBus(SocBusInfo)`; copies the **id** out of the incoming object and
  /// keeps its own (`RV32imState.java:573-575`). That is what makes the identity fix in
  /// `SocSimulationManager`'s codec sufficient: the attribute set always hands back *this*
  /// object, and a `setValue` never swaps it for the caller's.
  @discardableResult
  public func setAttachedBus(_ info: SocBusInfo) -> Bool {
    if attachedBus.busId == info.busId { return false }
    attachedBus.busId = info.busId
    return true
  }

  @discardableResult
  public func setAttachedBusId(_ value: String) -> Bool {
    if attachedBus.busId == value { return false }
    attachedBus.busId = value
    return true
  }

  /// Java: `getNewState(Instance)`. The `Instance` parameter is dropped; it existed only so
  /// `ProcessorState` could reach back into `SocUpMenuProvider`/window management (D9, UI).
  public func makeProcessorState() -> Rv32imProcessorState {
    Rv32imProcessorState(resetVector: resetVector, config: self)
  }
}

// MARK: - SocProcessorInterface (Java: RV32imState implements it on the OUTER class)

extension Rv32imConfig: SocProcessorInterface {

  /// `setEntryPointandReset(CircuitState, long, ElfProgramHeader, ElfSectionHeader)`
  /// (`RV32imState.java:615`). The ELF headers exist upstream only to hand the program image to
  /// `bPanel.loadProgram`, the assembly-editor UI, D9, so they are accepted and ignored here,
  /// which is why the protocol makes them Optional.
  public func setEntryPointAndReset(
    circuitState: (any SocCircuitStateToken)?, entryPoint: Int64,
    programHeader: ElfProgramHeader?, sectionHeader: ElfSectionHeader?
  ) {
    guard let state = processorState(in: circuitState) else { return }
    state.reset(entryPoint: Int(Int32(truncatingIfNeeded: entryPoint)), programWasLoaded: true)
  }

  /// `insertTransaction(SocBusTransaction, boolean, CircuitState)` (`RV32imState.java:628`).
  ///
  /// NOT ported: the `cState == null` recovery that reaches
  /// `InstanceComponent.getInstanceStateImpl().getProject().getCircuitState()`. `Project` is not
  /// a type this module can name, and a `nil` state reaches `initializeTransaction` as `nil`
  /// exactly as Java's `null` does when that recovery finds nothing.
  public func insertTransaction(
    _ transaction: SocBusTransaction, hidden: Bool, circuitState: (any SocCircuitStateToken)?
  ) {
    if hidden { transaction.setAsHidden() }
    attachedBus.simulationManager?.initializeTransaction(
      transaction, busId: attachedBus.busId, circuitState: circuitState)
  }

  /// `getEntryPoint(CircuitState)` (`RV32imState.java:644`), including its `return 0` for a
  /// `null` state and for a component the state has no data for.
  public func entryPoint(_ circuitState: (any SocCircuitStateToken)?) -> Int32 {
    guard let state = processorState(in: circuitState) else { return 0 }
    return Int32(truncatingIfNeeded: state.entryPointValue ?? 0)
  }

  /// `(ProcessorState) cState.getData(attachedBus.getComponent())`; the live per-run state for
  /// the placement this config belongs to.
  private func processorState(
    in circuitState: (any SocCircuitStateToken)?
  ) -> Rv32imProcessorState? {
    guard let circuitState, let component = attachedBus.component else { return nil }
    return circuitState.socComponentData(for: component) as? Rv32imProcessorState
  }
}

// MARK: - Outcome of one execute() cycle (replaces the dialogs — see file header)

/// What `Rv32imProcessorState.step` produced, replacing every place Java's
/// `RV32imState.execute()` popped an `OptionPane` dialog. The caller decides how (or whether)
/// to surface each case; nothing here decides UI policy (D9).
public enum Rv32imStepOutcome: Equatable {
  /// Java: `!simState.canExecute()`; nothing happened this cycle.
  case notRunning
  /// Java: a breakpoint at the current PC and `simState.breakPointReached()` returned `true`.
  case breakpointHit(pc: Int)
  /// Java: `exe == null`; no execution unit decoded the fetched word. PC still advances by 4
  /// (Java does this even on an invalid instruction: verified against
  /// `RV32imState.execute()`, not an oversight to "fix").
  case invalidInstruction(pc: Int, word: Int)
  /// Java: the instruction fetch's bus transaction had an error. PC does NOT advance.
  case fetchError(pc: Int, message: String)
  /// Java: `exe.execute()` returned `false`. PC does NOT advance.
  case executionError(pc: Int, message: String?)
  /// Java: a normal instruction retire, whether or not it jumped.
  case executed(pc: Int, jumped: Bool)
}

// MARK: - Inner processor state (Java: RV32imState.ProcessorState)

/// Java: `RV32imState.ProcessorState`: the live simulation state for one placed RV32IM
/// instance: 32 general registers, the implemented CSRs, the program counter, and the
/// fetch/decode/execute loop. See the file header for exactly what was dropped for D9 and
/// what is a seam rather than a full port.
public final class Rv32imProcessorState {
  // Java: `CSR_MSTATUS` etc. and the precomputed `IDX_*` array positions.
  private static let csrMstatus = 0x300
  private static let csrMie = 0x304
  private static let csrMtvec = 0x305
  private static let csrMepc = 0x341
  private static let csrMcause = 0x342
  private static let csrMip = 0x344

  private static let idxMstatus = Rv32imCsr.arrayIndex(ofAddress: csrMstatus)
  private static let idxMie = Rv32imCsr.arrayIndex(ofAddress: csrMie)
  private static let idxMtvec = Rv32imCsr.arrayIndex(ofAddress: csrMtvec)
  private static let idxMepc = Rv32imCsr.arrayIndex(ofAddress: csrMepc)
  private static let idxMcause = Rv32imCsr.arrayIndex(ofAddress: csrMcause)
  private static let idxMip = Rv32imCsr.arrayIndex(ofAddress: csrMip)

  private static let mstatusMie = 1 << 3
  private static let mstatusMpie = 1 << 7
  private static let mieMeie = 1 << 11
  private static let mipMeip = 1 << 11
  private static let mcauseInterrupt = 1 << 31
  private static let mcauseMachineExternalInterrupt = 11

  /// Java: `CpuDrawSupport.NR_OF_TRACES` (a UI-owned constant, `soc/gui`): copied as a plain
  /// value since only its magnitude (21), not anything about the class it lives in, matters
  /// to the trace ring buffer's behavior.
  public static let traceHistoryLimit = 21

  // Java: `registers`, `registers_valid`, `csrs`, `pc`, `lastRegisterWritten`.
  private var registers = [Int](repeating: 0, count: 32)
  private var registersValid = [Bool](repeating: false, count: 32)
  private var csrs = [Int](repeating: 0, count: Rv32imCsr.implementedAddresses.count)
  public private(set) var pc: Int = 0
  public private(set) var lastRegisterWritten: Int = -1

  private let resetVector: Int
  private var entryPoint: Int?
  public private(set) var programLoaded = false

  /// Java: `instrTrace` (a `LinkedList`, newest-first via `addFirst`, capped at
  /// `NR_OF_TRACES`). Modeled the same way: index 0 is the most recent retire.
  public private(set) var instructionTrace: [Rv32imTraceInfo] = []

  /// Java: `bPanel.getBreakPoints()`; a PC-address set. The editor-line half of
  /// `BreakpointPanel` (D9) has no headless meaning; only "is this address a breakpoint"
  /// survives.
  public var breakpoints: Set<Int> = []

  public var simulationState: Rv32imSimulationState

  /// Java: `lastClock`; used only to detect the rising edge that triggers `execute()`.
  private var lastClockWasHigh = false

  /// Java: `RV32imState.ASSEMBLER`, a `static final` shared across every instance. Kept
  /// per-instance here; see `Rv32imAssembler.swift`'s header for why that is behaviourally
  /// identical and preferable.
  public let decoder = Rv32imAssembler()

  /// Java: the implicit `RV32imState.this` outer reference every inner-class method uses
  /// (`attachedBus`, `getName()`, `nrOfIrqs`). Weak: the config is owned by the component's
  /// attribute set and this object by the `CircuitState`, so neither outlives the other by
  /// design and a strong edge here would be an unnecessary cross-lifetime hold (D3).
  public weak var config: Rv32imConfig?

  /// The live SoC bus this CPU issues transactions on, built from the config's `SocBusInfo`.
  /// `nil` only for a state constructed without a config (unit tests that drive `step(bus:)`
  /// with their own bus).
  public private(set) var busPort: Rv32imSocBusPort?

  public init(
    resetVector: Int,
    simulationState: Rv32imSimulationState = Rv32imDefaultSimulationState(),
    config: Rv32imConfig? = nil
  ) {
    self.resetVector = resetVector
    self.simulationState = simulationState
    self.config = config
    if let config {
      // The SAME `SocBusInfo` the attribute set exposes; that is the whole point of the
      // identity fix in `SocSimulationManager`'s codec, and building the port from a copy here
      // would put it straight back.
      busPort = Rv32imSocBusPort(attachedBus: config.attachedBus)
    }
    reset()
  }

  // MARK: Reset

  /// Java: `reset()` (no-argument overload).
  public func reset() {
    reset(entryPoint: nil, programWasLoaded: false)
  }

  /// Java: `reset(CircuitState, Integer, ElfProgramHeader, ElfSectionHeader)`. The ELF header
  /// parameters exist in Java only to hand the program image to `bPanel.loadProgram` (the
  /// assembly-editor UI, D9); dropped. `entryPoint`/`programWasLoaded` are the two pieces
  /// that affect this object's own state.
  public func reset(entryPoint: Int?, programWasLoaded: Bool) {
    if let entryPoint { self.entryPoint = entryPoint }
    if programWasLoaded { programLoaded = true }
    pc = self.entryPoint ?? resetVector
    for i in 0..<31 { registersValid[i] = false }
    for i in csrs.indices { csrs[i] = 0 }
    // Java: "mtvec remains 0 until firmware initializes it"; no special-case needed here
    // either; csrs[idxMtvec] is already 0 from the fill above.
    lastRegisterWritten = -1
    instructionTrace.removeAll()
    simulationState.reset()
  }

  public var entryPointValue: Int? { entryPoint }

  // MARK: Registers (Java: getRegisterValue/writeRegister/isRegisterValid/getRegisterValueHex)

  /// Java: `getRegisterValue(int)`, `x0` always reads 0; out-of-range likewise reads 0
  /// (Java's own comment: "TODO: handle correctly undefined registers instead of returning 0"
  /// , preserved verbatim, not fixed, per "preserve upstream behaviour even where it looks
  /// wrong" unless decisions.md overrides it, which it does not here).
  public func registerValue(_ index: Int) -> Int {
    (index == 0 || index > 31) ? 0 : registers[index - 1]
  }

  public func isRegisterValid(_ index: Int) -> Bool {
    if index == 0 { return true }
    if index > 31 { return false }
    return registersValid[index - 1]
  }

  /// Java: `getRegisterValueHex(int)`.
  public func registerValueHex(_ index: Int) -> String {
    isRegisterValid(index)
      ? String(format: "0x%08X", Int32(truncatingIfNeeded: registerValue(index)))
      : "??????????"
  }

  /// Java: `writeRegister(int, int)`. Note `lastRegisterWritten` is reset to -1 on *every*
  /// call, including a write to `x0`/out-of-range (which then does nothing else); a write
  /// attempt that is discarded still clears the "what did the previous instruction write"
  /// marker Java uses for the register-file highlight. Preserved exactly.
  public func writeRegister(_ index: Int, _ value: Int) {
    lastRegisterWritten = -1
    if index == 0 || index > 31 { return }
    registersValid[index - 1] = true
    registers[index - 1] = wrap32(value)
    lastRegisterWritten = index
  }

  // MARK: CSRs (Java: getCsrValue/writeCsr/setMachineExternalInterruptPending)

  /// Java: `getCsrValue(int)`; `sprIndex` here is a raw CSR *address* despite the parameter
  /// name (see `Rv32imCsr.arrayIndex(ofAddress:)`'s note); unimplemented addresses read 0.
  public func csrValue(_ address: Int) -> Int {
    let idx = Rv32imCsr.arrayIndex(ofAddress: address)
    return idx < 0 ? 0 : csrs[idx]
  }

  /// Java: `writeCsr(int, int)`. Array positions 0–3 (MVENDORID/MARCHID/MIMPID/MHARTID) and
  /// 17 (TDATA2) are read-only and silently ignore the write: including when `address` does
  /// not resolve at all, since `arrayIndex(ofAddress:)` then returns -1, and `-1 < 4` is true
  /// in both Java and here, so an unimplemented CSR is *also* silently ignored rather than
  /// e.g. trapping. Preserved exactly.
  public func writeCsr(_ address: Int, _ value: Int) {
    let idx = Rv32imCsr.arrayIndex(ofAddress: address)
    if idx < 4 || idx == 17 { return }
    csrs[idx] = wrap32(value)
  }

  public func setMachineExternalInterruptPending(_ pending: Bool) {
    guard Self.idxMip >= 0 else { return }
    if pending {
      csrs[Self.idxMip] |= Self.mipMeip
    } else {
      csrs[Self.idxMip] &= ~Self.mipMeip
    }
  }

  private var isMachineExternalInterruptEnabled: Bool {
    guard Self.idxMstatus >= 0, Self.idxMie >= 0, Self.idxMip >= 0 else { return false }
    let mstatus = csrs[Self.idxMstatus]
    let mie = csrs[Self.idxMie]
    let mip = csrs[Self.idxMip]
    return (mstatus & Self.mstatusMie) != 0 && (mie & Self.mieMeie) != 0 && (mip & Self.mipMeip) != 0
  }

  private func takeMachineExternalInterrupt() {
    if Self.idxMepc >= 0 { csrs[Self.idxMepc] = pc }
    if Self.idxMcause >= 0 {
      csrs[Self.idxMcause] = Self.mcauseInterrupt | Self.mcauseMachineExternalInterrupt
    }
    if Self.idxMstatus >= 0 {
      var mstatus = csrs[Self.idxMstatus]
      let mieSet = (mstatus & Self.mstatusMie) != 0
      if mieSet { mstatus |= Self.mstatusMpie } else { mstatus &= ~Self.mstatusMpie }
      mstatus &= ~Self.mstatusMie
      csrs[Self.idxMstatus] = mstatus
    }
    let handler = Self.idxMtvec >= 0 ? csrs[Self.idxMtvec] : 0
    pc = handler
  }

  /// Java: `machineReturn()` (MRET).
  public func machineReturn() {
    if Self.idxMstatus >= 0 {
      var mstatus = csrs[Self.idxMstatus]
      let mpieSet = (mstatus & Self.mstatusMpie) != 0
      if mpieSet { mstatus |= Self.mstatusMie } else { mstatus &= ~Self.mstatusMie }
      mstatus |= Self.mstatusMpie
      csrs[Self.idxMstatus] = mstatus
    }
    if Self.idxMepc >= 0 { pc = csrs[Self.idxMepc] }
  }

  /// Java: `interrupt()`: unreferenced within `RV32imState` itself in 4.1.0 (verified: the
  /// only other `.interrupt()` call site in `soc/` is `Nios2OtherControlInstructions`, a
  /// different processor family's unrelated same-named method). Ported anyway since it is
  /// part of the class's public surface.
  public func interrupt() {
    pc = Self.idxMtvec >= 0 ? csrs[Self.idxMtvec] : 0
  }

  public func setProgramCounter(_ value: Int) {
    // Java: "/* TODO: check for misaligned exception */": preserved verbatim; no check here
    // either.
    pc = wrap32(value)
  }

  // MARK: Clock edge + fetch/decode/execute (Java: setClock/execute)

  /// Java: `setClock(Value, CircuitState)`. `clockIsHigh` replaces Java's three-valued
  /// `Value` comparison (`lastClock == Value.FALSE && clock == Value.TRUE`) with a plain
  /// `Bool`: UNKNOWN/ERROR reads as "not high" on both sides of the edge check, which is the
  /// same effective behavior (`Value.UNKNOWN == Value.TRUE` is false in Java too), without
  /// this module depending on `LogisimKernel.Value`. Translating an actual port value into
  /// `clockIsHigh` is the caller's job: same seam as `Rv32imBus`.
  @discardableResult
  public func setClock(high clockIsHigh: Bool, bus: Rv32imBus) throws -> Rv32imStepOutcome? {
    var outcome: Rv32imStepOutcome?
    if !lastClockWasHigh && clockIsHigh {
      outcome = try step(bus: bus)
    }
    lastClockWasHigh = clockIsHigh
    return outcome
  }

  /// Java: `execute(CircuitState)`. Renamed `step` since "execute" is also this file's name
  /// for running a single decoded *instruction* (`Rv32imExecutionUnit.execute`) and the two
  /// must not be confused when reading this port side by side with the Java.
  ///
  /// `throws` only for the one genuinely-uncaught Java exception reachable from here: the
  /// M-extension's division by zero (see `Rv32imExecutionUnit.execute`'s doc comment). Every
  /// other Java soft-failure path (bus fetch error, invalid opcode, `exe.execute() == false`)
  /// returns an `Rv32imStepOutcome` instead, matching Java's own choice not to throw there.
  @discardableResult
  public func step(bus: Rv32imBus) throws -> Rv32imStepOutcome {
    guard simulationState.canExecute else { return .notRunning }

    if breakpoints.contains(pc) {
      if simulationState.breakPointReached() {
        return .breakpointHit(pc: pc)
      }
    }

    if isMachineExternalInterruptEnabled {
      takeMachineExternalInterrupt()
    }

    let fetchedWord: Int
    do {
      fetchedWord = try bus.fetchInstruction(at: pc)
    } catch let error as Rv32imBusError {
      simulationState.errorInExecution()
      return .fetchError(pc: pc, message: error.message)
    }

    decoder.decodeWord(fetchedWord)
    lastRegisterWritten = -1
    if instructionTrace.count >= Self.traceHistoryLimit { instructionTrace.removeLast() }

    guard let unit = decoder.selectedExecutionUnit else {
      simulationState.errorInExecution()
      instructionTrace.insert(
        Rv32imTraceInfo(pc: pc, instruction: fetchedWord, asmText: "??", isError: true), at: 0)
      pc = wrap32(pc &+ 4)
      return .invalidInstruction(pc: pc, word: fetchedWord)
    }

    let asmText = unit.asmInstruction ?? "??"
    let succeeded = try unit.execute(on: self, bus: bus)
    if !succeeded {
      simulationState.errorInExecution()
      instructionTrace.insert(
        Rv32imTraceInfo(pc: pc, instruction: fetchedWord, asmText: asmText, isError: true), at: 0)
      return .executionError(pc: pc, message: unit.errorMessage)
    }

    instructionTrace.insert(
      Rv32imTraceInfo(pc: pc, instruction: fetchedWord, asmText: asmText, isError: false), at: 0)
    let jumped = unit.performedJump
    if !jumped { pc = wrap32(pc &+ 4) }
    return .executed(pc: pc, jumped: jumped)
  }

  /// `setClock(Value, CircuitState)` as the component's `propagate` calls it: the bus is this
  /// state's own `busPort`, aimed at whichever circuit state the propagation is running in.
  ///
  /// Returns `nil` when there is no bus port at all, which is a mis-wired CPU rather than a
  /// clock edge that did nothing; the caller can tell the two apart because a real
  /// no-op edge returns `nil` too only when `clockIsHigh` did not rise. Kept simple on purpose:
  /// Java has no return value here either.
  @discardableResult
  public func setClock(
    high clockIsHigh: Bool, circuitState: (any SocCircuitStateToken)?
  ) throws -> Rv32imStepOutcome? {
    guard let busPort else { return nil }
    busPort.circuitState = circuitState
    return try setClock(high: clockIsHigh, bus: busPort)
  }
}

// MARK: - InstanceData (Java: `ProcessorState implements InstanceData, Cloneable`)

extension Rv32imProcessorState: InstanceData {

  /// Java's `clone()` is `(ProcessorState) super.clone()`: a **shallow** `Object.clone`, so the
  /// copy shares the very same `registers`, `registers_valid`, `csrs` and `instrTrace` arrays as
  /// the original. Two forked `CircuitState`s would then write each other's register file.
  ///
  /// That is a latent upstream bug, not a behaviour: the same shape is already recorded, and
  /// deliberately not reproduced, for `SocBusStateInfo.SocBusState.clone()` in
  /// `Data/SocBusFabric.swift`. Here Swift makes the right thing free; `[Int]`/`[Bool]` are
  /// value types, so a field-by-field copy deep-copies the arrays without any extra work, and
  /// reproducing the aliasing would take deliberate boxing.
  ///
  /// `config` and `busPort` are carried across by reference, which IS what Java's shallow clone
  /// does with `RV32imState.this` and is correct: both describe the *placement*, which the fork
  /// shares, not the run.
  public func cloneData() -> any InstanceData {
    let copy = Rv32imProcessorState(
      resetVector: resetVector, simulationState: simulationState, config: config)
    copy.registers = registers
    copy.registersValid = registersValid
    copy.csrs = csrs
    copy.pc = pc
    copy.lastRegisterWritten = lastRegisterWritten
    copy.entryPoint = entryPoint
    copy.programLoaded = programLoaded
    copy.instructionTrace = instructionTrace
    copy.breakpoints = breakpoints
    copy.lastClockWasHigh = lastClockWasHigh
    return copy
  }
}
