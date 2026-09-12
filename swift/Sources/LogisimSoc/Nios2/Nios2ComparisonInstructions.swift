// Nios2ComparisonInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2ComparisonInstructions),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Numeric-fidelity notes:
//   * CMPGE/CMPLT etc. compare `valueA`/`valueB` as plain signed `Int`; matches Java's signed
//     `int` comparison directly, since `getRegisterValue` already hands back a properly
//     sign-extended two's-complement value (no extra widening needed for the signed compares).
//   * CMPGEU/CMPLTU widen through `SocSupport.convUnsignedInt` before comparing; the classic
//     "top-bit-set register must sort as a large positive value" hazard this port brief calls
//     out by name; a plain signed `Int` compare here would be wrong for exactly the operands
//     these opcodes exist to handle correctly.
//   * The *I-immediate variants: Java's `((immediate << 16) >> 16)` sign-extension relies on
//     `int`'s automatic 32-bit wraparound on the left shift. Swift's `Int` (64-bit, non-trapping
//     here since it's never a native `Int32`) does not wrap on its own, so the left shift is
//     `wrap32`'d before the arithmetic right shift, exactly like the arithmetic/logical
//     instruction file's `imm = wrap32(immediate << 16)` does.
import LogisimKernel

public final class Nios2ComparisonInstructions: AssemblerExecutionInterface {
  private static let instrCmpeq = 0
  private static let instrCmpne = 1
  private static let instrCmpge = 2
  private static let instrCmpgeu = 3
  private static let instrCmplt = 4
  private static let instrCmpltu = 5
  private static let instrCmpgt = 6
  private static let instrCmpgtu = 7
  private static let instrCmple = 8
  private static let instrCmpleu = 9
  private static let instrCmpeqi = 10
  private static let instrCmpnei = 11
  private static let instrCmpgei = 12
  private static let instrCmpgeui = 13
  private static let instrCmplti = 14
  private static let instrCmpltui = 15
  private static let instrCmpgti = 16
  private static let instrCmpgtui = 17
  private static let instrCmplei = 18
  private static let instrCmpleui = 19

  private static let signExtend = 0x100
  private static let pseudoInstr = 0x200

  private static let asmOpcodes: [String] = [
    "CMPEQ", "CMPNE", "CMPGE", "CMPGEU", "CMPLT", "CMPLTU", "CMPGT", "CMPGTU", "CMPLE", "CMPLEU",
    "CMPEQI", "CMPNEI", "CMPGEI", "CMPGEUI", "CMPLTI", "CMPLTUI", "CMPGTI", "CMPGTUI", "CMPLEI",
    "CMPLEUI",
  ]
  private static let asmOpcs: [Int] = [
    0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr,
    0x20, 0x18, 0x08, 0x28, 0x10, 0x30, pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr,
  ]
  private static let asmOpxs: [Int] = [
    0x20, 0x18, 0x08, 0x28, 0x10, 0x30, signExtend, -1, signExtend, -1,
    signExtend, signExtend, signExtend, -1, signExtend, -1, signExtend, -1, signExtend, -1,
  ]

  private let opcodes: [String]
  private let opcCodes: [Int]
  private let opxCodes: [Int]

  private var instruction = 0
  private var valid = false
  private var operation = 0
  private var destination = 0
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
    let valueA = state.getRegisterValue(sourceA)
    var valueB = state.getRegisterValue(sourceB)
    let imm = opxCodes[operation] != Self.signExtend ? (immediate & 0xFFFF) : (wrap32(immediate << 16) >> 16)
    var result = 0
    switch operation {
    case Self.instrCmpeqi:
      valueB = imm
      fallthrough
    case Self.instrCmpeq:
      result = valueA == valueB ? 1 : 0
    case Self.instrCmpnei:
      valueB = imm
      fallthrough
    case Self.instrCmpne:
      result = valueA != valueB ? 1 : 0
    case Self.instrCmpgei:
      valueB = imm
      fallthrough
    case Self.instrCmpge:
      result = valueA >= valueB ? 1 : 0
    case Self.instrCmpgeui:
      valueB = imm
      fallthrough
    case Self.instrCmpgeu:
      let opA = SocSupport.convUnsignedInt(valueA)
      let opB = SocSupport.convUnsignedInt(valueB)
      result = opA >= opB ? 1 : 0
    case Self.instrCmplti:
      valueB = imm
      fallthrough
    case Self.instrCmplt:
      result = valueA < valueB ? 1 : 0
    case Self.instrCmpltui:
      valueB = imm
      fallthrough
    case Self.instrCmpltu:
      let opA = SocSupport.convUnsignedInt(valueA)
      let opB = SocSupport.convUnsignedInt(valueB)
      result = opA < opB ? 1 : 0
    default:
      return false
    }
    state.writeRegister(destination, result)
    return true
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    s += "\(Nios2ProcessorState.registerABINames[destination]),\(Nios2ProcessorState.registerABINames[sourceA]),"
    if operation >= Self.instrCmpeqi {
      let imm = opxCodes[operation] != Self.signExtend ? (immediate & 0xFFFF) : (wrap32(immediate << 16) >> 16)
      s += "\(imm)"
    } else {
      s += Nios2ProcessorState.registerABINames[sourceB]
    }
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    valid = false
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    valid = true
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    guard instr.numberOfParameters == 3 else {
      valid = false
      instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
      return true
    }
    valid = Nios2Support.isCorrectRegister(instr, 0) && valid
    valid = Nios2Support.isCorrectRegister(instr, 1) && valid
    destination = Nios2Support.getRegisterIndex(instr, 0)
    sourceA = Nios2Support.getRegisterIndex(instr, 1)
    var immediateToken: AssemblerToken?
    if operation >= Self.instrCmpeqi {
      guard let param3 = instr.getParameter(2) else { valid = false; return true }
      immediateToken = param3.first
      if param3.count != 1 || !param3[0].isNumber {
        valid = false
        if let t = immediateToken { instr.setError(t, .assemblerExpectedImmediateValue) }
      }
      immediate = param3.first?.getNumberValue() ?? 0
      sourceB = 0
    } else {
      valid = Nios2Support.isCorrectRegister(instr, 2) && valid
      sourceB = Nios2Support.getRegisterIndex(instr, 2)
      immediate = 0
    }
    guard valid else { return true }
    if opcCodes[operation] == Self.pseudoInstr {
      switch operation {
      case Self.instrCmpgt:
        operation = Self.instrCmplt
        swap(&sourceA, &sourceB)
      case Self.instrCmpgti:
        operation = Self.instrCmpgei
        immediate += 1
      case Self.instrCmpgtu:
        operation = Self.instrCmpltu
        swap(&sourceA, &sourceB)
      case Self.instrCmpgtui:
        operation = Self.instrCmpgeui
        immediate += 1
      case Self.instrCmple:
        operation = Self.instrCmpge
        swap(&sourceA, &sourceB)
      case Self.instrCmplei:
        operation = Self.instrCmplti
        immediate += 1
      case Self.instrCmpleu:
        operation = Self.instrCmpgeu
        swap(&sourceA, &sourceB)
      case Self.instrCmpleui:
        operation = Self.instrCmpltui
        immediate += 1
      default:
        valid = false
        return false
      }
    }
    if opxCodes[operation] == Self.signExtend {
      if immediate >= (1 << 15) || immediate < -(1 << 15) {
        valid = false
        if let t = immediateToken { instr.setError(t, .assemblerImmediateOutOfRange) }
      }
    } else {
      if immediate >= (1 << 16) || immediate < 0 {
        valid = false
        if let t = immediateToken { instr.setError(t, .assemblerImmediateOutOfRange) }
      }
    }
    if valid {
      if operation >= Self.instrCmpeqi {
        instruction = Nios2Support.getITypeInstructionCode(sourceA, destination, immediate, opcCodes[operation])
      } else {
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, sourceB, destination, opxCodes[operation])
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
      if Nios2Support.getOPXImm(instr, Nios2Support.rType) != 0 { return false }
      let opxCode = Nios2Support.getOPXCode(instr, Nios2Support.rType)
      guard let idx = opxCodes.firstIndex(of: opxCode) else { return false }
      valid = true
      operation = idx
      destination = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
      sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
      sourceB = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
      immediate = 0
    } else {
      guard let idx = opcCodes.firstIndex(of: opcode) else { return false }
      valid = true
      operation = idx
      destination = Nios2Support.getRegBIndex(instr, Nios2Support.iType)
      sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.iType)
      sourceB = sourceA
      immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
    }
    return valid
  }

  public func performedJump() -> Bool { false }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { nil }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    opcodes.contains(instruction.lowercased()) ? 4 : -1
  }
}
