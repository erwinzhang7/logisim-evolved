// Nios2ProgramControlInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2ProgramControlInstructions),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Branches, jumps and calls. Conforms to `AssemblerExecutionUnitWithLabelSupport` (Java:
// `AbstractExecutionUnitWithLabelSupport`) so the disassembly listing can re-render the
// immediate against a resolved label name.
//
// Numeric-fidelity notes:
//   * `SocSupport.convUnsignedInt`/`convUnsignedLong` widen every pc/register value used in
//     address arithmetic to an unsigned 64-bit accumulator before adding/comparing; the usual
//     "top-bit-set address must not compare as negative" hazard.
//   * `((immediate << 16) >> 16)` sign-extends the 16-bit branch displacement. Java's `int`
//     wraps for free on the left shift; here `immediate` is a plain `Int`, so the left shift is
//     `wrap32`'d first (same fix-up as every other sign-extending shift pair in this port).
//   * BGE/BLT compare `valueA`/`valueB` (plain signed `Int`, already the correct sign) directly;
//     BGEU/BLTU compare the `SocSupport.convUnsignedInt`-widened unsigned values; the two
//     variants Nios II keeps as genuinely distinct opcodes for exactly this reason.
import LogisimKernel

public final class Nios2ProgramControlInstructions: AssemblerExecutionUnitWithLabelSupport {
  private static let instrCallr = 0
  private static let instrRet = 1
  private static let instrJmp = 2
  private static let instrCall = 3
  private static let instrJmpi = 4
  private static let instrBr = 5
  private static let instrBge = 6
  private static let instrBgeu = 7
  private static let instrBlt = 8
  private static let instrBltu = 9
  private static let instrBeq = 10
  private static let instrBne = 11
  private static let instrBgt = 12
  private static let instrBgtu = 13
  private static let instrBle = 14
  private static let instrBleu = 15

  private static let signExtend = 0x100
  private static let pseudoInstr = 0x200

  private static let asmOpcodes: [String] = [
    "CALLR", "RET", "JMP", "CALL", "JMPI", "BR",
    "BGE", "BGEU", "BLT", "BLTU", "BEQ", "BNE",
    "BGT", "BGTU", "BLE", "BLEU",
  ]
  private static let asmOpcs: [Int] = [
    0x3A, 0x3A, 0x3A, 0x00, 0x01, 0x06,
    0x0E, 0x2E, 0x16, 0x36, 0x26, 0x1E,
    pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr,
  ]
  private static let asmOpxs: [Int] = [
    0x1D, 0x05, 0x0D, -1, -1, signExtend,
    signExtend, signExtend, signExtend, signExtend,
    signExtend, signExtend, signExtend, signExtend,
    signExtend, signExtend,
  ]

  private let opcodes: [String]
  private let opcCodes: [Int]
  private let opxCodes: [Int]

  private var instruction = 0
  private var valid = false
  private var jumped = false
  private var operation = 0
  private var immediate = 0
  private var sourceA = 0
  private var sourceB = 0

  public init() {
    opcodes = Self.asmOpcodes.map { $0.lowercased() }
    opcCodes = Self.asmOpcs
    opxCodes = Self.asmOpxs
  }

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    guard valid, let state = processorState as? Nios2ProcessorState else { return false }
    jumped = false
    let valueA = state.getRegisterValue(sourceA)
    let valueB = state.getRegisterValue(sourceB)
    let valueAu = SocSupport.convUnsignedInt(valueA)
    let valueBu = SocSupport.convUnsignedInt(valueB)
    let pc = SocSupport.convUnsignedInt(state.programCounter)
    let nextpc = pc + 4
    let imm = wrap32(immediate << 16) >> 16
    let target = nextpc + Int64(imm)
    switch operation {
    case Self.instrCallr:
      jumped = true
      state.writeRegister(31, Int(SocSupport.convUnsignedLong(nextpc)))
      state.setProgramCounter(valueA)
    case Self.instrRet:
      jumped = true
      state.setProgramCounter(state.getRegisterValue(31))
    case Self.instrJmp:
      jumped = true
      state.setProgramCounter(valueA)
    case Self.instrCall:
      state.writeRegister(31, Int(SocSupport.convUnsignedLong(nextpc)))
      fallthrough
    case Self.instrJmpi:
      jumped = true
      state.setProgramCounter(immediate << 2)
    case Self.instrBr:
      jumped = true
      state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
    case Self.instrBge:
      if valueA >= valueB {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    case Self.instrBgeu:
      if valueAu >= valueBu {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    case Self.instrBlt:
      if valueA < valueB {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    case Self.instrBltu:
      if valueAu < valueBu {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    case Self.instrBeq:
      if valueA == valueB {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    case Self.instrBne:
      if valueA != valueB {
        jumped = true
        state.setProgramCounter(Int(SocSupport.convUnsignedLong(target)))
      }
    default:
      return false
    }
    return true
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    let imm = (wrap32(immediate << 16) >> 16) + 4
    switch operation {
    case Self.instrRet:
      break
    case Self.instrCallr, Self.instrJmp:
      s += Nios2ProcessorState.registerABINames[sourceA]
    case Self.instrJmpi, Self.instrCall:
      s += "\(immediate << 2)"
    case Self.instrBr:
      s += "pc" + (imm >= 0 ? "+" : "") + "\(imm)"
    default:
      s += "\(Nios2ProcessorState.registerABINames[sourceA]),\(Nios2ProcessorState.registerABINames[sourceB]),"
      s += "pc" + (imm >= 0 ? "+" : "") + "\(imm)"
    }
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    valid = false
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    valid = true
    let pc = instr.getProgramCounter()
    switch operation {
    case Self.instrJmp, Self.instrCallr:
      guard instr.numberOfParameters == 1 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      sourceA = Nios2Support.getRegisterIndex(instr, 0)
      sourceB = sourceA
      immediate = 0
    case Self.instrRet:
      guard instr.numberOfParameters == 0 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedNoArguments)
        return true
      }
    case Self.instrCall, Self.instrJmpi:
      guard instr.numberOfParameters == 1 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        return true
      }
      guard let imm = instr.getParameter(0) else { valid = false; return true }
      if imm.count != 1 || !imm[0].isNumber {
        valid = false
        if let t = imm.first { instr.setError(t, .assemblerExpextedImmediateOrLabel) }
      } else {
        sourceA = 0
        sourceB = 0
        immediate = imm[0].getNumberValue() >> 2
        if immediate >= (1 << 26) || immediate < 0 {
          valid = false
          instr.setError(imm[0], .assemblerImmediateOutOfRange)
        }
      }
    case Self.instrBr:
      guard instr.numberOfParameters == 1 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        return true
      }
      guard let imm = instr.getParameter(0) else { valid = false; return true }
      if imm.count != 1 || !imm[0].isNumber {
        valid = false
        if let t = imm.first { instr.setError(t, .assemblerExpextedImmediateOrLabel) }
      } else {
        sourceA = 0
        sourceB = 0
        let target = SocSupport.convUnsignedInt(imm[0].getNumberValue())
        let imml = target - pc - 4
        if imml >= (1 << 15) || imml < -(1 << 15) {
          valid = false
          instr.setError(imm[0], .assemblerImmediateOutOfRange)
        }
        immediate = Int(imml)
      }
    default:
      guard instr.numberOfParameters == 3 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      valid = Nios2Support.isCorrectRegister(instr, 1) && valid
      sourceA = Nios2Support.getRegisterIndex(instr, 0)
      sourceB = Nios2Support.getRegisterIndex(instr, 1)
      guard let imm = instr.getParameter(2) else { valid = false; return true }
      if imm.count != 1 || !imm[0].isNumber {
        valid = false
        if let t = imm.first { instr.setError(t, .assemblerExpextedImmediateOrLabel) }
      }
      let target = SocSupport.convUnsignedInt(imm.first?.getNumberValue() ?? 0)
      let imml = target - pc - 4
      if imml >= (1 << 15) || imml < -(1 << 15) {
        valid = false
        if let t = imm.first { instr.setError(t, .assemblerImmediateOutOfRange) }
      }
      immediate = Int(imml)
    }
    // Transform the pseudo instructions.
    var switchab = false
    switch operation {
    case Self.instrBgt:
      operation = Self.instrBlt
      switchab = true
    case Self.instrBgtu:
      operation = Self.instrBltu
      switchab = true
    case Self.instrBle:
      operation = Self.instrBge
      switchab = true
    case Self.instrBleu:
      operation = Self.instrBgeu
      switchab = true
    default:
      break
    }
    if switchab { swap(&sourceA, &sourceB) }
    if valid {
      switch operation {
      case Self.instrCallr:
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, 0, 0x1F, 0x1D)
      case Self.instrRet:
        instruction = Nios2Support.getRTypeInstructionCode(0x1F, 0, 0, 0x05)
      case Self.instrJmp:
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, 0, 0, 0x0D)
      case Self.instrCall, Self.instrJmpi:
        instruction = Nios2Support.getJTypeInstructionCode(immediate, opcCodes[operation])
      default:
        instruction = Nios2Support.getITypeInstructionCode(sourceA, sourceB, immediate, opcCodes[operation])
      }
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }

  public func setBinInstruction(_ instr: Int) -> Bool {
    instruction = instr
    valid = false
    let opcode = Nios2Support.getOpcode(instr)
    if opcode == 0x3A {
      let opx = Nios2Support.getOPXCode(instr, Nios2Support.rType)
      guard opxCodes.contains(opx), Nios2Support.getOPXImm(instr, Nios2Support.rType) == 0 else { return false }
      operation = opxCodes.firstIndex(of: opx)!
      let ra = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
      let rb = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
      let rc = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
      switch operation {
      case Self.instrCallr:
        guard rc == 0x1F, rb == 0 else { return false }
        sourceA = ra
      case Self.instrRet:
        guard ra == 0x1F, rb == 0, rc == 0 else { return false }
      case Self.instrJmp:
        guard rb == 0, rc == 0 else { return false }
        sourceA = ra
      default:
        return false
      }
      valid = true
    } else {
      guard opcCodes.contains(opcode) else { return false }
      valid = true
      operation = opcCodes.firstIndex(of: opcode)!
      switch operation {
      case Self.instrJmpi, Self.instrCall:
        immediate = Nios2Support.getImmediate(instr, Nios2Support.jType)
      case Self.instrBr:
        immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
        if Nios2Support.getRegAIndex(instr, Nios2Support.iType) != 0
          || Nios2Support.getRegBIndex(instr, Nios2Support.iType) != 0 {
          valid = false
        }
      default:
        immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
        sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.iType)
        sourceB = Nios2Support.getRegBIndex(instr, Nios2Support.iType)
      }
    }
    return valid
  }

  public func performedJump() -> Bool { valid && jumped }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { nil }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    opcodes.contains(instruction.lowercased()) ? 4 : -1
  }

  public func isLabelSupported() -> Bool { operation >= Self.instrCall }

  public func getLabelAddress(pc: Int64) -> Int64 {
    guard isLabelSupported() else { return -1 }
    switch operation {
    case Self.instrJmpi, Self.instrCall:
      return SocSupport.convUnsignedInt(immediate << 2)
    default:
      let imm = wrap32(immediate << 16) >> 16
      return pc + 4 + Int64(imm)
    }
  }

  public func getAsmInstruction(label: String) -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    switch operation {
    case Self.instrRet:
      break
    case Self.instrCallr, Self.instrJmp:
      s += Nios2ProcessorState.registerABINames[sourceA]
    case Self.instrBr, Self.instrJmpi, Self.instrCall:
      s += label
    default:
      s += "\(Nios2ProcessorState.registerABINames[sourceA]),\(Nios2ProcessorState.registerABINames[sourceB]),\(label)"
    }
    return s
  }
}
