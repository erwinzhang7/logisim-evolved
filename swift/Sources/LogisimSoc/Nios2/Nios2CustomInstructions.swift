// Nios2CustomInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2CustomInstructions),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// The `custom` opcode hands four register-file slots (two read, one write, or any of them
// re-routed to the "custom register file" `cN` instead) and an 8-bit function number `n` to a
// user-supplied combinational/sequential block wired to the component's CUSTOM* ports, then
// polls its DONE pin every subsequent cycle until it settles to a defined `Value` (see
// Nios2Seams.swift's `Nios2CustomInstructionHost`; the `Instance`/`InstanceState` round-trip
// this module does not own).
//
// ── waitingOnReady control-flow seam (D9/D13) ──────────────────────────────────────────────
//
// Java's `waitingOnReady`, on an undefined DONE pin, pops a modal `OptionPane` dialog AND calls
// `state.getSimState().errorInExecution()`; the *dialog itself* is what actually blocks further
// execution (Swing's `showMessageDialog` is synchronous), not the `true` it returns (which reads
// identically to the ordinary “still busy” case one line above). `errorInExecution()` sets a
// latch on `SocUpSimulationState` (soc/data, not owned by this module) that a live GUI checks
// before allowing another step.
//
// This port has no modal dialog to block on, so the fault is instead captured as
// `getErrorMessage()`/an internal flag exactly like every other execution-unit error in this
// package (D13: report, do not silently continue and do not trap). The one thing this file
// canNOT do is reach into `Nios2ProcessorState.isHalted`/`lastFault` to latch the run loop the
// way `SocUpSimulationState.errorInExecution()` would: `Nios2ProcessorState` (already committed
// by another agent, not owned by this file) exposes both as `private(set)` with no public
// setter, and `execute()`'s early-return branch for this exact case
// (`if custom.isValid, custom.waitingOnReady(...) { return true }`) only inspects the boolean,
// never `getErrorMessage()`. So today, after a done-pin error, `waitingOnReady` correctly stops
// itself (`custActive = false`) but the *next* clock edge falls through to a normal fetch of
// whatever instruction follows, rather than latching `isHalted` the way a fetch error or a
// failed `exe.execute()` does elsewhere in `Nios2ProcessorState.execute()`. Wiring this properly
// needs either a public fault-setter on `Nios2ProcessorState` or for its early-return branch to
// consult `getErrorMessage()`; flagged for the integrator; not fixed here since it requires
// editing a file this task does not own.
import LogisimKernel

public final class Nios2CustomInstructions: AssemblerExecutionInterface {
  private static let custom = 0x32

  private var instruction = 0
  private var valid = false
  private var regA = 0
  private var regB = 0
  private var regC = 0
  private var readra = false
  private var readrb = false
  private var writerc = false
  private var n = 0
  private var custActive = false
  private var errorMessage: String?

  public init() {}

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    guard valid, let state = processorState as? Nios2ProcessorState, let host = state.customInstructionHost else {
      return false
    }
    let regAValue = state.getRegisterValue(regA)
    let regBValue = state.getRegisterValue(regB)
    host.setCustomPort(Nios2PortIndex.dataA, width: 32, value: regAValue, delay: 5)
    host.setCustomPort(Nios2PortIndex.dataB, width: 32, value: regBValue, delay: 5)
    host.setCustomPort(Nios2PortIndex.start, width: 1, value: 1, delay: 5)
    host.setCustomPort(Nios2PortIndex.n, width: 8, value: n, delay: 5)
    host.setCustomPort(Nios2PortIndex.a, width: 5, value: regA, delay: 5)
    host.setCustomPort(Nios2PortIndex.readRA, width: 1, value: readra ? 1 : 0, delay: 5)
    host.setCustomPort(Nios2PortIndex.b, width: 5, value: regB, delay: 5)
    host.setCustomPort(Nios2PortIndex.readRB, width: 1, value: readrb ? 1 : 0, delay: 5)
    host.setCustomPort(Nios2PortIndex.c, width: 5, value: regC, delay: 5)
    host.setCustomPort(Nios2PortIndex.writeRC, width: 1, value: writerc ? 1 : 0, delay: 5)
    custActive = true
    return true
  }

  /// `waitingOnReady(Object, CircuitState)`. See the file header for why this returns `true` on
  /// the same literal `Bool` schedule Java does (still-busy vs. instruction-complete), and the
  /// integration gap on the error path.
  public func waitingOnReady(processorState: Nios2ProcessorState) -> Bool {
    guard custActive, valid, let host = processorState.customInstructionHost else { return false }
    let done = host.customPortValue(Nios2PortIndex.done)
    host.setCustomPort(Nios2PortIndex.start, width: 1, value: 0, delay: 0)
    if done != .trueValue && done != .falseValue {
      custActive = false
      errorMessage = Nios2ExecutionFault.donePinError.description
      return true
    }
    if done == .trueValue {
      custActive = false
      if !writerc {
        var result = 0
        let rValue = host.customPortValue(Nios2PortIndex.result)
        if rValue.isFullyDefined() { result = javaParseUnsignedInt32(rValue.toHexString(), radix: 16) ?? 0 }
        processorState.writeRegister(regC, result)
      }
      return false
    }
    return true
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = "custom"
    while s.count < Nios2Support.asmFieldSize { s += " " }
    s += "\(n),"
    s += "\(writerc ? "c" : "r")\(regC),"
    s += "\(readra ? "c" : "r")\(regA),"
    s += "\(readrb ? "c" : "r")\(regB)"
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    guard instr.opcode.lowercased() == "custom" else {
      valid = false
      return false
    }
    valid = true
    guard instr.numberOfParameters == 4 else {
      valid = false
      instr.setError(instr.instruction, .assemblerExpectedFourArguments)
      return true
    }
    guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1),
      let param3 = instr.getParameter(2), let param4 = instr.getParameter(3),
      let tok1 = param1.first, let tok2 = param2.first, let tok3 = param3.first, let tok4 = param4.first
    else {
      // D13: an empty parameter-token group (a malformed assembly line, e.g. a stray comma)
      // would index Java's array out of bounds; guarded here instead of trapping.
      valid = false
      return true
    }
    if param1.count != 1 || !tok1.isNumber {
      valid = false
      instr.setError(tok1, .assemblerExpectedImmediateValue)
      return true
    }
    n = tok1.getNumberValue()
    if n < 0 || n > 255 {
      valid = false
      instr.setError(tok1, .assemblerImmediateOutOfRange)
      return true
    }
    if param2.count != 1 || !(tok2.type == AssemblerToken.register || tok2.type == Nios2Assembler.customRegister) {
      valid = false
      instr.setError(tok2, .assemblerExpectedRegister)
    }
    writerc = tok2.type == Nios2Assembler.customRegister
    regC = Nios2ProcessorState.getRegisterIndex(tok2.value)
    if regC < 0 || regC > 31 {
      valid = false
      instr.setError(tok2, .assemblerUnknownRegister)
    }
    if param3.count != 1 || !(tok3.type == AssemblerToken.register || tok3.type == Nios2Assembler.customRegister) {
      valid = false
      instr.setError(tok3, .assemblerExpectedRegister)
    }
    readra = tok3.type == Nios2Assembler.customRegister
    regA = Nios2ProcessorState.getRegisterIndex(tok3.value)
    if regA < 0 || regA > 31 {
      valid = false
      instr.setError(tok3, .assemblerUnknownRegister)
    }
    if param4.count != 1 || !(tok4.type == AssemblerToken.register || tok4.type == Nios2Assembler.customRegister) {
      valid = false
      instr.setError(tok4, .assemblerExpectedRegister)
    }
    readrb = tok4.type == Nios2Assembler.customRegister
    regB = Nios2ProcessorState.getRegisterIndex(tok4.value)
    if regB < 0 || regB > 31 {
      valid = false
      instr.setError(tok4, .assemblerUnknownRegister)
    }
    if valid {
      var opx = n & 0xFF
      if writerc { opx |= 1 << 8 }
      if readrb { opx |= 1 << 9 }
      if readra { opx |= 1 << 10 }
      instruction = Nios2Support.getCustomInstructionCode(regA, regB, regC, opx, Self.custom)
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }

  public func setBinInstruction(_ instr: Int) -> Bool {
    instruction = instr
    valid = false
    if Nios2Support.getOpcode(instr) == Self.custom {
      valid = true
      regA = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
      regB = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
      regC = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
      let opx = Nios2Support.getOPX(instr, Nios2Support.rType)
      n = opx & 0xFF
      writerc = ((opx >> 8) & 1) != 0
      readrb = ((opx >> 9) & 1) != 0
      readra = ((opx >> 10) & 1) != 0
    }
    return valid
  }

  public func performedJump() -> Bool { false }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { errorMessage }
  public func getInstructions() -> [String] { ["custom"] }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    instruction.lowercased() == "custom" ? 4 : -1
  }
}
