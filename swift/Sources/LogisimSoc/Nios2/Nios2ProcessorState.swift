// Nios2ProcessorState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2State.ProcessorState and
// the static members of the outer Nios2State class it depends on: registerABINames,
// getRegisterIndex, isCustomRegister, isControlRegister), GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the actual CPU model: 31 general registers (r0/"zero" is hardwired and not stored),
// the program counter, the five control registers (status/estatus/bstatus/ienable/ipending),
// and the fetch-decode-execute loop. Everything UI/instance-factory shaped is dropped per D9:
// see Nios2Seams.swift for the exact list and the protocols that replace it
// (`Nios2CustomInstructionHost`) plus `Nios2ExecutionFault` in
// place of `OptionPane` dialogs.
//
// Registers/pc/control-registers are all held as plain `Int`, kept inside the `Int32`-
// representable range by construction (every arithmetic result that would be a 32-bit register
// value is `wrap32`'d before being stored); the same convention `LogisimKernel/Location.swift`
// uses, rather than native `Int32` (whose `+`/`-`/`*`/`<<` trap on overflow instead of wrapping,
// which is exactly the bug class the port brief calls out by name).
import LogisimFile
import LogisimKernel
import LogisimStd

public final class Nios2ProcessorState {
  private static let statusRSIE = 1 << 23
  private static let statusPIE = 1

  public static let registerABINames: [String] = [
    "zero", "at", "r2", "r3", "r4", "r5", "r6", "r7",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "r16", "r17", "r18", "r19", "r20", "r21", "r22", "r23", "et", "bt",
    "gp", "sp", "fp", "ea", "sstat", "ra",
  ]

  /// `Nios2State.getRegisterIndex(String)`. Accepts the ABI name, `rN`, `cN` (custom register),
  /// or `ctlN` (control register): the caller (`Nios2Support.isCorrectRegister`, the
  /// data-transfer/other-control instruction parsers) is what enforces which of those is valid
  /// in a given syntactic position.
  public static func getRegisterIndex(_ name: String) -> Int {
    let regName = name.lowercased()
    if let i = registerABINames.firstIndex(of: regName) { return i }
    if regName.hasPrefix("r") && regName.count < 4 {
      return javaParseUnsignedInt32(String(regName.dropFirst()), radix: 10) ?? -1
    } else if regName.hasPrefix("ctl") && regName.count < 6 {
      return javaParseUnsignedInt32(String(regName.dropFirst(3)), radix: 10) ?? -1
    } else if regName.hasPrefix("c") && regName.count < 4 {
      return javaParseUnsignedInt32(String(regName.dropFirst()), radix: 10) ?? -1
    }
    return -1
  }

  public static func isCustomRegister(_ name: String) -> Bool {
    let regName = name.lowercased()
    return regName.hasPrefix("c") && regName.count < 4 && !regName.hasPrefix("ctl")
  }

  public static func isControlRegister(_ name: String) -> Bool {
    let regName = name.lowercased()
    return regName.hasPrefix("ctl") && regName.count < 6
  }

  // MARK: - Instance state

  public let config: Nios2Config
  /// One decode/execute engine per CPU instance. Java shares a single `static final ASSEMBLER`
  /// across every Nios2 component in the whole application; since `decode()` fully overwrites
  /// every exec unit's transient fields before `execute()` reads them (D2: propagation is
  /// synchronous and non-reentrant, so no two CPUs' decode+execute can interleave), giving each
  /// `Nios2ProcessorState` its own `Nios2Assembler` is behaviourally identical and avoids a
  /// process-wide singleton with no compensating benefit in a value-oriented port.
  public let assembler = Nios2Assembler()

  private var registers = [Int](repeating: 0, count: 31)  // index i = register (i+1); r0 is not stored
  private var registersValid = [Bool](repeating: false, count: 31)
  public private(set) var programCounter: Int = 0
  public private(set) var status: Int = 0
  public private(set) var estatus: Int = 0
  public private(set) var bstatus: Int = 0
  public private(set) var ienable: Int = 0
  public private(set) var ipending: Int = 0
  public private(set) var lastRegisterWritten: Int = -1
  private var lastClock: Value = .createUnknown(.one)
  public private(set) var entryPoint: Int? = nil
  public private(set) var programLoaded = false
  /// Stands in for `SocUpSimulationState`'s running/paused/error state machine (soc/data, not
  /// owned here); the one bit that is load-bearing for instruction-execution fidelity: once an
  /// execution fault occurs, `execute` stops advancing until `reset()`.
  public private(set) var isHalted = false
  public private(set) var lastFault: Nios2ExecutionFault?

  /// `attachedBus`: the CPU's own `SocBusInfo`, reached through the config exactly as Java's
  /// inner class reaches `Nios2State.this.attachedBus`. This replaces a `weak var bus: (any
  /// SocProcessorInterface)?` seam that nothing ever assigned, which is why every fetch this
  /// class issued went nowhere.
  private var attachedBus: SocBusInfo { config.attachedBus }
  /// `Instance` → `InstanceState` round-trip for the custom-instruction ports (see
  /// Nios2Seams.swift).
  public weak var customInstructionHost: Nios2CustomInstructionHost?

  public init(config: Nios2Config) {
    self.config = config
  }

  // MARK: - Reset

  public func reset() {
    reset(entry: nil, programLoaded: false)
  }

  /// `reset(CircuitState, Integer, ElfProgramHeader, ElfSectionHeader)`. The ELF/section-header
  /// program-loading half (`bPanel.loadProgram(...)`) is a soc/file + UI concern this module
  /// does not own; callers that just loaded a program pass `programLoaded: true` and whatever
  /// `entry` address they resolved.
  public func reset(entry: Int?, programLoaded: Bool) {
    if let entry { self.entryPoint = entry }
    if programLoaded { self.programLoaded = true }
    programCounter = self.entryPoint ?? config.resetVector
    for i in 0..<registersValid.count { registersValid[i] = false }
    lastRegisterWritten = -1
    status = Self.statusRSIE
    estatus = 0
    bstatus = 0
    ienable = 0
    ipending = 0
    isHalted = false
    lastFault = nil
  }

  // MARK: - Control registers

  public func getControlRegister(_ index: Int) -> Int {
    switch index {
    case 0: return status
    case 1: return estatus
    case 2: return bstatus
    case 3: return ienable
    case 4: return ipending
    default: return 0
    }
  }

  /// `setControlRegister`. Java's `default` case `throw`s `IllegalStateException` for indices
  /// 5+ (ipending is read-only from software), an internal-invariant trap the RDCTL/WRCTL
  /// decoder is supposed to prevent from ever firing (WRCTL's `immediate` comes straight off a
  /// 5-bit instruction field, and only 0-3 are meaningful destinations); reproduced as a no-op
  /// here rather than a trap, since a malformed `.circ`-adjacent input (a corrupted program
  /// image containing a WRCTL to an out-of-range control register number) IS a way to reach
  /// this, D13.
  public func setControlRegister(_ index: Int, _ value: Int) {
    switch index {
    case 0: setStatus(value)
    case 1: estatus = wrap32(value)
    case 2: bstatus = wrap32(value)
    case 3: ienable = wrap32(value)
    default: break
    }
  }

  public func setStatus(_ value: Int) {
    status = value & Self.statusPIE
    status |= Self.statusRSIE
  }

  public func setIenable(_ value: Int) {
    ienable = wrap32(value)
  }

  public func setIpending(_ value: Int) {
    ipending = wrap32(value)
  }

  // MARK: - Registers

  public func getRegisterValue(_ index: Int) -> Int {
    if index == 0 || index > 31 { return 0 }
    // TODO(upstream too: "TODO: handle correctly undefined registers instead of returning 0").
    return registers[index - 1]
  }

  public func getRegisterValueHex(_ index: Int) -> String {
    isRegisterValid(index) ? String(format: "0x%08X", getRegisterValue(index)) : "??????????"
  }

  public func isRegisterValid(_ index: Int) -> Bool {
    if index == 0 { return true }
    if index > 31 { return false }
    return registersValid[index - 1]
  }

  public func writeRegister(_ index: Int, _ value: Int) {
    lastRegisterWritten = -1
    if !(index == 0 || index > 31) {
      registersValid[index - 1] = true
      registers[index - 1] = wrap32(value)
      lastRegisterWritten = index
    }
  }

  // MARK: - Clock / interrupts / exceptions

  /// `setClock(Value, CircuitState)`.
  ///
  /// `circuitState` is threaded straight through to `execute` exactly as Java does; it is what
  /// every bus transaction the executed instruction issues is addressed against, so dropping it
  /// (as this method did while there was no seam type for it) makes every load/store in the
  /// program run against `nil` and answer `noSocBusConnected`.
  public func setClock(_ clock: Value, circuitState: (any SocCircuitStateToken)? = nil) {
    if lastClock == .falseValue && clock == .trueValue { execute(circuitState: circuitState) }
    lastClock = clock
  }

  public func setProgramCounter(_ value: Int) {
    // TODO(upstream too: "TODO: check for misaligned exception").
    programCounter = wrap32(value)
  }

  public func interrupt() {
    estatus = status
    status &= ~Self.statusPIE
    programCounter = config.exceptionVector
  }

  public func endOfInterrupt() {
    status = estatus
    programCounter = getRegisterValue(29)
  }

  public func breakRequest() {
    bstatus = status
    status &= ~Self.statusPIE
    let nextPc = SocSupport.convUnsignedInt(programCounter) + 4
    writeRegister(30, Int(SocSupport.convUnsignedLong(nextPc)))
    programCounter = config.breakVector
  }

  public func breakReturn() {
    status = bstatus
    programCounter = getRegisterValue(30)
  }

  public var masterComponent: (any Component)? { config.masterComponent }

  // MARK: - Fetch / decode / execute

  /// `execute(CircuitState)`, minus: the breakpoint check (`bPanel.getBreakPoints()`: UI,
  /// D9), and every `OptionPane` dialog (replaced by `lastFault`/`isHalted`, matching D13's
  /// "report, don't crash": and note `isHalted` mirrors `simState.errorInExecution()` staying
  /// latched until the next `reset()`, exactly like upstream's `SocUpSimulationState`).
  @discardableResult
  public func execute(circuitState: (any SocCircuitStateToken)? = nil) -> Bool {
    guard !isHalted else { return false }

    if let exe = assembler.getExeUnit(), let custom = exe as? Nios2CustomInstructions {
      if custom.isValid, custom.waitingOnReady(processorState: self) { return true }
    }

    if (status & Self.statusPIE) != 0 {
      let maskedIrqs = ienable & ipending
      if maskedIrqs != 0 {
        writeRegister(29, programCounter)
        interrupt()
      }
    }

    // Java passes the raw `int pc` field straight through (no unsigned conversion at the fetch
    // site; `SocBusTransaction`'s address field is itself `int`); `Int32(truncatingIfNeeded:)`
    // matches, since `programCounter` is already kept within `Int32` range by `wrap32`.
    let fetch = SocBusTransaction(
      kind: .read, address: Int32(truncatingIfNeeded: programCounter),
      writeData: 0, accessType: .word, initiator: transactionInitiator())
    insertTransaction(fetch, hidden: false, circuitState: circuitState)
    if fetch.hasError {
      lastFault = .fetchTransactionError(message: fetch.error.description)
      isHalted = true
      return false
    }

    let instruction = Int(fetch.readData)
    assembler.decode(instruction)
    let exe = assembler.getExeUnit()
    lastRegisterWritten = -1
    guard let exe else {
      lastFault = .fetchInvalidInstruction
      isHalted = true
      programCounter = wrap32(programCounter &+ 4)
      return false
    }

    if !exe.execute(processorState: self, circuitState: circuitState) {
      lastFault = .executionError(message: exe.getErrorMessage())
      isHalted = true
      return false
    }
    if !exe.performedJump() { programCounter = wrap32(programCounter &+ 4) }
    return true
  }

  /// `insertTransaction(SocBusTransaction, boolean, CircuitState)` (`Nios2State.java:373`),
  /// which is, verbatim:
  ///
  /// ```java
  /// if (hidden) trans.setAsHiddenTransaction();
  /// attachedBus.getSocSimulationManager()
  ///            .initializeTransaction(trans, attachedBus.getBusId(), cState);
  /// ```
  ///
  /// A `nil` manager is the "never registered" case; Java would NPE, so this returns having
  /// marked the transaction, which is what `DmaState.java:271` does at the equivalent site and
  /// is what D13 asks for on a path a `.circ` can reach.
  public func insertTransaction(
    _ transaction: SocBusTransaction, hidden: Bool,
    circuitState: (any SocCircuitStateToken)? = nil
  ) {
    if hidden { transaction.setAsHidden() }
    guard let manager = attachedBus.simulationManager else {
      transaction.setError(.noSocBusConnected)
      return
    }
    manager.initializeTransaction(
      transaction, busId: attachedBus.busId, circuitState: circuitState)
  }

  private func transactionInitiator() -> SocTransactionInitiator {
    if let comp = masterComponent { return .component(comp) }
    return .named(config.name.isEmpty ? "Nios2s" : config.name)
  }
}

// MARK: - InstanceData (Java: `ProcessorState implements InstanceData, Cloneable`)

extension Nios2ProcessorState: InstanceData {

  /// Java's `clone()` is a shallow `Object.clone`, so the copy shares the original's `registers`
  /// and `registers_valid` arrays; two forked `CircuitState`s would write each other's register
  /// file. Same latent upstream bug as `SocBusStateInfo.SocBusState.clone()` (see
  /// `Data/SocBusFabric.swift`) and handled the same way: Swift's `[Int]`/`[Bool]` are value
  /// types, so a field-by-field copy deep-copies them for free.
  ///
  /// `config` is shared by reference, which is what Java's shallow clone does with
  /// `Nios2State.this` and is right: it describes the placement, which the fork shares.
  public func cloneData() -> any InstanceData {
    let copy = Nios2ProcessorState(config: config)
    copy.registers = registers
    copy.registersValid = registersValid
    copy.programCounter = programCounter
    copy.status = status
    copy.estatus = estatus
    copy.bstatus = bstatus
    copy.ienable = ienable
    copy.ipending = ipending
    copy.lastRegisterWritten = lastRegisterWritten
    copy.lastClock = lastClock
    copy.entryPoint = entryPoint
    copy.programLoaded = programLoaded
    copy.isHalted = isHalted
    copy.lastFault = lastFault
    copy.customInstructionHost = customInstructionHost
    return copy
  }
}
