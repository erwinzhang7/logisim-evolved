// Nios2OtherControlInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2OtherControlInstructions),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// TRAP/ERET/BREAK/BRET (software interrupt/exception/breakpoint entry-exit), RDCTL/WRCTL
// (control-register access), and the cache/pipeline-management opcodes (FLUSHx/INITx/FLUSHP/
// SYNC) which upstream itself does nothing for in simulation ("these are HW dependent
// operations"): reproduced as no-ops here too, matching D1's fidelity mandate to preserve even
// behaviour that looks like it should do more.
//
// Method-name note: Java's `Nios2State.ProcessorState` spells these `endofInterrupt`/
// `breakReq`/`breakRet`; the already-ported `Nios2ProcessorState` (Nios2ProcessorState.swift,
// not owned by this file) spells them `endOfInterrupt`/`breakRequest`/`breakReturn`; called by
// those names here.
import LogisimKernel

public final class Nios2OtherControlInstructions: AssemblerExecutionInterface {
  private static let instrTrap = 0
  private static let instrEret = 1
  private static let instrBreak = 2
  private static let instrBret = 3
  private static let instrRdctl = 4
  private static let instrWrctl = 5
  private static let instrFlushd = 6
  private static let instrFlushda = 7
  private static let instrFlushi = 8
  private static let instrInitd = 9
  private static let instrInitda = 10
  private static let instrIniti = 11
  private static let instrFlushp = 12
  private static let instrSync = 13

  private static let signExtend = 0x100

  private static let asmOpcodes: [String] = [
    "TRAP", "ERET", "BREAK", "BRET",
    "RDCTL", "WRCTL", "FLUSHD", "FLUSHDA", "FLUSHI", "INITD", "INITDA", "INITI",
    "FLUSHP", "SYNC",
  ]
  private static let asmOpcs: [Int] = [
    0x3A, 0x3A, 0x3A, 0x3A,
    0x3A, 0x3A, 0x3B, 0x1B, 0x3A, 0x33, 0x13, 0x3A,
    0x3A, 0x3A,
  ]
  private static let asmOpxs: [Int] = [
    0x2D, 0x01, 0x34, 0x09,
    0x26, 0x2E, signExtend, signExtend, 0x0C, signExtend, signExtend, 0x29,
    0x04, 0x36,
  ]

  private let opcodes: [String]
  private let opcCodes: [Int]
  private let opxCodes: [Int]

  private var instruction = 0
  private var valid = false
  private var jumped = false
  private var operation = 0
  private var sourceA = 0
  private var immediate = 0

  public init() {
    opcodes = Self.asmOpcodes.map { $0.lowercased() }
    opcCodes = Self.asmOpcs
    opxCodes = Self.asmOpxs
  }

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    jumped = false
    guard valid, let state = processorState as? Nios2ProcessorState else { return false }
    let pc = SocSupport.convUnsignedInt(state.programCounter)
    let nextPc = pc + 4
    switch operation {
    case Self.instrTrap:
      state.writeRegister(29, Int(SocSupport.convUnsignedLong(nextPc)))
      state.interrupt()
      jumped = true
    case Self.instrEret:
      state.endOfInterrupt()
      jumped = true
    case Self.instrBreak:
      state.breakRequest()
      jumped = true
    case Self.instrBret:
      state.breakReturn()
      jumped = true
    case Self.instrRdctl:
      state.writeRegister(sourceA, state.getControlRegister(immediate))
    case Self.instrWrctl:
      state.setControlRegister(immediate, state.getRegisterValue(sourceA))
    default:
      break  // Nothing to do in simulation, these are HW-dependent operations.
    }
    return true
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    switch operation {
    case Self.instrBreak, Self.instrTrap:
      if immediate != 0 { s += "\(immediate)" }
    case Self.instrRdctl:
      s += "\(Nios2ProcessorState.registerABINames[sourceA]),ctl\(immediate)"
    case Self.instrWrctl:
      s += "ctl\(immediate),\(Nios2ProcessorState.registerABINames[sourceA])"
    case Self.instrInitd, Self.instrInitda, Self.instrFlushda, Self.instrFlushd:
      let imm = wrap32(immediate << 16) >> 16
      s += "\(imm)(\(Nios2ProcessorState.registerABINames[sourceA]))"
    case Self.instrIniti, Self.instrFlushi:
      s += Nios2ProcessorState.registerABINames[sourceA]
    default:
      break
    }
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    valid = false
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    valid = true
    var first = -1
    switch operation {
    case Self.instrBreak, Self.instrTrap:
      if instr.numberOfParameters == 0 {
        immediate = 0
        sourceA = 0
      } else if instr.numberOfParameters == 1 {
        guard let imm = instr.getParameter(0) else { valid = false; return true }
        if imm.count != 1 || !imm[0].isNumber {
          valid = false
          if let t = imm.first { instr.setError(t, .assemblerExpectedImmediateValue) }
        }
        immediate = imm.first?.getNumberValue() ?? 0
        if immediate > 0x1F || immediate < 0 {
          valid = false
          if let t = imm.first { instr.setError(t, .assemblerImmediateOutOfRange) }
        }
      } else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedZeroOrOneArgument)
      }
    case Self.instrWrctl, Self.instrRdctl:
      first = operation == Self.instrWrctl ? 1 : 0
      guard instr.numberOfParameters == 2 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, first) && valid
      sourceA = Nios2Support.getRegisterIndex(instr, first)
      first = (first + 1) & 1
      guard let ctl = instr.getParameter(first) else { valid = false; return true }
      if ctl.count != 1 || ctl[0].type != Nios2Assembler.controlRegister {
        valid = false
        if let t = ctl.first { instr.setError(t, .nios2ExpectedControlRegister) }
      }
      immediate = ctl.first.map { Nios2ProcessorState.getRegisterIndex($0.value) } ?? -1
      if immediate < 0 || immediate > 31 {
        valid = false
        if let t = ctl.first { instr.setError(t, .assemblerUnknownRegister) }
      }
    case Self.instrIniti, Self.instrFlushi:
      guard instr.numberOfParameters == 1 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      sourceA = Nios2Support.getRegisterIndex(instr, 0)
      immediate = 0
    case Self.instrInitd, Self.instrInitda, Self.instrFlushda, Self.instrFlushd:
      guard instr.numberOfParameters == 1 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        return true
      }
      guard let ireg = instr.getParameter(0) else { valid = false; return true }
      if ireg.count != 2 {
        valid = false
        if let t = ireg.first { instr.setError(t, .nios2AssemblerExpectedImmediateIndexedRegister) }
        return true
      }
      if !ireg[0].isNumber {
        valid = false
        instr.setError(ireg[0], .assemblerExpectedImmediateValue)
      }
      immediate = ireg[0].getNumberValue()
      if immediate >= (1 << 15) || immediate < -(1 << 15) {
        valid = false
        instr.setError(ireg[0], .assemblerImmediateOutOfRange)
      }
      if ireg[1].type != AssemblerToken.bracketedRegister {
        valid = false
        instr.setError(ireg[1], .nios2AssemblerExpectedBracketedRegister)
        return true
      }
      if Nios2ProcessorState.isCustomRegister(ireg[1].value) {
        valid = false
        instr.setError(ireg[1], .nios2CannotUseCustomRegister)
        return true
      }
      if Nios2ProcessorState.isControlRegister(ireg[1].value) {
        valid = false
        instr.setError(ireg[1], .nios2CannotUseControlRegister)
        return true
      }
      sourceA = Nios2ProcessorState.getRegisterIndex(ireg[1].value)
      if sourceA < 0 || sourceA > 31 {
        valid = false
        instr.setError(ireg[1], .assemblerUnknownRegister)
      }
    default:
      if instr.numberOfParameters != 0 {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedNoArguments)
      }
    }

    if valid {
      switch operation {
      case Self.instrTrap:
        instruction = Nios2Support.getRTypeInstructionCode(0, 0, 0x1D, 0x2D, immediate)
      case Self.instrEret:
        instruction = Nios2Support.getRTypeInstructionCode(0x1D, 0x1E, 0, 0x01)
      case Self.instrBreak:
        instruction = Nios2Support.getRTypeInstructionCode(0, 0, 0x1E, 0x34, immediate)
      case Self.instrBret:
        instruction = Nios2Support.getRTypeInstructionCode(0x1E, 0, 0x1E, 0x09)
      case Self.instrRdctl:
        instruction = Nios2Support.getRTypeInstructionCode(0, 0, sourceA, 0x26, immediate)
      case Self.instrWrctl:
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, 0, 0, 0x2E, immediate)
      case Self.instrFlushp, Self.instrIniti, Self.instrFlushi:
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, 0, 0, opxCodes[operation])
      case Self.instrSync:
        instruction = Nios2Support.getRTypeInstructionCode(0, 0, 0, 0x36)
      case Self.instrInitda, Self.instrInitd, Self.instrFlushda, Self.instrFlushd:
        instruction = Nios2Support.getITypeInstructionCode(sourceA, 0, immediate, opcCodes[operation])
      default:
        valid = false
        return false
      }
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }

  public func setBinInstruction(_ instr: Int) -> Bool {
    valid = false
    instruction = instr
    let opcode = Nios2Support.getOpcode(instr)
    if opcode == 0x3A {
      let opx = Nios2Support.getOPXCode(instr, Nios2Support.rType)
      guard let idx = opxCodes.firstIndex(of: opx) else { return false }
      valid = true
      operation = idx
      let ra = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
      let rb = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
      let rc = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
      let imm5 = Nios2Support.getOPXImm(instr, Nios2Support.rType)
      switch operation {
      case Self.instrTrap:
        if ra != 0 || rb != 0 || rc != 0x1D { valid = false }
        immediate = imm5
      case Self.instrEret:
        if ra != 0x1D || rb != 0x1E || rc != 0 || imm5 != 0 { valid = false }
      case Self.instrBreak:
        if ra != 0 || rb != 0 || rc != 0x1E { valid = false }
        immediate = imm5
      case Self.instrBret:
        if ra != 0x1E || rb != 0 || rc != 0x1E || imm5 != 0 { valid = false }
      case Self.instrRdctl:
        if ra != 0 || rb != 0 { valid = false }
        sourceA = rc
        immediate = imm5
      case Self.instrWrctl:
        if rb != 0 || rc != 0 { valid = false }
        sourceA = ra
        immediate = imm5
      case Self.instrFlushp, Self.instrIniti, Self.instrFlushi:
        if rb != 0 || rc != 0 || imm5 != 0 { valid = false }
        sourceA = ra
      case Self.instrSync:
        if ra != 0 || rb != 0 || rc != 0 || imm5 != 0 { valid = false }
      default:
        valid = false
      }
    } else {
      guard let idx = opcCodes.firstIndex(of: opcode) else { return false }
      operation = idx
      valid = true
      switch operation {
      case Self.instrInitda, Self.instrInitd, Self.instrFlushda, Self.instrFlushd:
        if Nios2Support.getRegBIndex(instr, Nios2Support.iType) != 0 { valid = false }
        sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.iType)
        immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
      default:
        valid = false
      }
    }
    return valid
  }

  public func performedJump() -> Bool { jumped && valid }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { nil }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    opcodes.contains(instruction.lowercased()) ? 4 : -1
  }
}
