// Nios2ArithmeticAndLogicalInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.
// Nios2ArithmeticAndLogicalInstructions), GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// Numeric-fidelity notes (every one of these is a real divergence class the port brief calls
// out by name):
//   * Every register-width intermediate (`result`, folded immediates) is `wrap32`'d before
//     being stored/returned: Java `int` arithmetic wraps silently; Swift `Int` (64-bit,
//     unbounded here) does not, and does not trap either since these are always plain `Int`
//     rather than native `Int32`, so the divergence would be silent rather than a crash.
//   * MUL/MULXSS/MULXUU/MULXSU widen to 64 bits (`SocSupport.convUnsignedInt`/`convUnsignedLong`
//     for the unsigned variants), matching Java's `long oppA = valueA;` sign-extending widen;
//     these products can never overflow 64 bits (two 32-bit factors), so no further masking is
//     needed before the final 32-bit truncation.
//   * DIV/DIVU: Java's uncaught `ArithmeticException` on divide-by-zero would, per D13, be
//     caught by the propagation loop and reported as a circuit error rather than crashing the
//     app, but this file's `execute` returns `Bool`, not `throws` (matching the shared
//     `AssemblerExecutionInterface`, which every instruction family and both CPU cores
//     implement). Reported via `getErrorMessage()`/returning `false` instead, which
//     `Nios2ProcessorState.execute()` already treats as an execution fault
//     (`isHalted = true`); the same non-crashing outcome D13 requires, reached through the
//     interface this module actually has rather than by widening it. Upstream itself returns
//     `null` unconditionally from `getErrorMessage()` for this instruction family (it never
//     reaches here because it crashes first); this is a deliberate improvement on the crash
//     path, not a behavioural regression on any path that previously succeeded.
//   * `Integer.MIN_VALUE / -1` does NOT throw in Java (unlike divide-by-zero): the JLS defines
//     it as silently returning `Integer.MIN_VALUE`. Since every operand here is carried in a
//     64-bit `Int` (not native `Int32`), the same division computes the mathematically exact
//     `2147483648` with no overflow at 64-bit width, and `wrap32` folds it right back down to
//     `Int32.min`: reproducing Java's special case as a side effect of the wrap, with no
//     special-case code needed.
import LogisimKernel

public final class Nios2ArithmeticAndLogicalInstructions: AssemblerExecutionInterface {
  private static let instrAnd = 0
  private static let instrOr = 1
  private static let instrXor = 2
  private static let instrNor = 3
  private static let instrAdd = 4
  private static let instrSub = 5
  private static let instrMul = 6
  private static let instrDiv = 7
  private static let instrDivu = 8
  private static let instrMulxss = 9
  private static let instrMulxuu = 10
  private static let instrMulxsu = 11
  private static let instrAndi = 12
  private static let instrOri = 13
  private static let instrXori = 14
  private static let instrAndhi = 15
  private static let instrOrhi = 16
  private static let instrXorhi = 17
  private static let instrAddi = 18
  private static let instrSubi = 19
  private static let instrMuli = 20
  private static let instrNop = 21
  private static let instrMov = 22
  private static let instrMovhi = 23
  private static let instrMovi = 24
  private static let instrMovui = 25
  private static let instrMovia = 26

  private static let signExtend = 0x100
  private static let pseudoInstr = 0x200
  private static let doubleSize = 0x400

  private static let asmOpcodes: [String] = [
    "AND", "OR", "XOR", "NOR", "ADD", "SUB", "MUL", "DIV", "DIVU",
    "MULXSS", "MULXUU", "MULXSU",
    "ANDI", "ORI", "XORI", "ANDHI", "ORHI", "XORHI", "ADDI", "SUBI", "MULI",
    "NOP", "MOV", "MOVHI", "MOVI", "MOVUI", "MOVIA",
  ]
  private static let asmOpcs: [Int] = [
    0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A,
    0x3A, 0x3A, 0x3A, 0x0C, 0x14, 0x1C, 0x2C, 0x34, 0x3C, 0x04, 0x04, 0x24,
    pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr, pseudoInstr,
  ]
  private static let asmOpxs: [Int] = [
    0x0e, 0x16, 0x1E, 0x06, 0x31, 0x39, 0x27, 0x18, 0x24,
    0x1F, 0x07, 0x17, -1, -1, -1, -1, -1, -1, signExtend, signExtend, signExtend,
    -1, -1, -1, signExtend, -1, doubleSize,
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
  private var errorMessage: String?

  public init() {
    opcodes = Self.asmOpcodes.map { $0.lowercased() }
    opcCodes = Self.asmOpcs
    opxCodes = Self.asmOpxs
  }

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    guard valid, let state = processorState as? Nios2ProcessorState else { return false }
    var valueB = state.getRegisterValue(sourceB)
    let valueA = state.getRegisterValue(sourceA)
    var result = 0
    var imm = wrap32(immediate << 16)
    var op = operation
    if op == Self.instrSubi {
      imm = wrap32(-imm)
      op = Self.instrAddi
    }
    errorMessage = nil
    switch op {
    case Self.instrMovia:
      result = immediate
    case Self.instrAndhi:
      result = valueA & imm
    case Self.instrAndi:
      valueB = immediate
      fallthrough
    case Self.instrAnd:
      result = valueA & valueB
    case Self.instrMovhi, Self.instrOrhi:
      result = valueA | imm
    case Self.instrMovui, Self.instrOri:
      valueB = immediate
      fallthrough
    case Self.instrOr:
      result = valueA | valueB
    case Self.instrNor:
      result = wrap32((valueA | valueB) ^ -1)
    case Self.instrXorhi:
      result = valueA ^ imm
    case Self.instrXori:
      valueB = immediate
      fallthrough
    case Self.instrXor:
      result = valueA ^ valueB
    case Self.instrMovi, Self.instrAddi:
      valueB = imm >> 16
      fallthrough
    case Self.instrMov, Self.instrNop, Self.instrAdd:
      result = wrap32(valueA &+ valueB)
    case Self.instrSub:
      result = wrap32(valueA &- valueB)
    case Self.instrMuli:
      valueB = imm >> 16
      fallthrough
    case Self.instrMulxss, Self.instrMul:
      let oppA = Int64(valueA)
      let oppB = Int64(valueB)
      let res = oppA &* oppB
      result = Int(op == Self.instrMul ? SocSupport.convUnsignedLong(res) : SocSupport.convUnsignedLong(res >> 32))
    case Self.instrDiv:
      if valueB == 0 {
        errorMessage = "Divide by zero error"
        return false
      }
      result = wrap32(valueA / valueB)
    case Self.instrDivu:
      let opA = SocSupport.convUnsignedInt(valueA)
      let opB = SocSupport.convUnsignedInt(valueB)
      if opB == 0 {
        errorMessage = "Divide by zero error"
        return false
      }
      result = Int(SocSupport.convUnsignedLong(opA / opB))
    case Self.instrMulxuu:
      let oppA = SocSupport.convUnsignedInt(valueA)
      let oppB = SocSupport.convUnsignedInt(valueB)
      let res = oppA &* oppB
      result = Int(SocSupport.convUnsignedLong(res >> 32))
    case Self.instrMulxsu:
      let oppA = Int64(valueA)
      let oppB = SocSupport.convUnsignedInt(valueB)
      let res = oppA &* oppB
      result = Int(SocSupport.convUnsignedLong(res >> 32))
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
    if opcCodes[operation] == Self.pseudoInstr {
      if operation != Self.instrNop {
        if operation == Self.instrMov {
          s += "\(Nios2ProcessorState.registerABINames[destination]),\(Nios2ProcessorState.registerABINames[sourceA])"
        } else {
          var imm = immediate
          if opxCodes[operation] == Self.signExtend {
            imm = wrap32(imm << 16)
            imm >>= 16
          }
          s += "\(Nios2ProcessorState.registerABINames[destination]),\(imm)"
        }
      }
    } else if opcCodes[operation] == 0x3A {
      s +=
        "\(Nios2ProcessorState.registerABINames[destination]),\(Nios2ProcessorState.registerABINames[sourceA])"
      s += ",\(Nios2ProcessorState.registerABINames[sourceB])"
    } else {
      var imm = immediate
      if opxCodes[operation] == Self.signExtend {
        imm = wrap32(immediate << 16)
        imm >>= 16
      }
      s +=
        "\(Nios2ProcessorState.registerABINames[destination]),\(Nios2ProcessorState.registerABINames[sourceA]),\(imm)"
    }
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    valid = true
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    if operation == Self.instrNop {
      guard instr.numberOfParameters == 0 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedNoArguments)
        return true
      }
      sourceA = 0; sourceB = 0; destination = 0; immediate = 0
      instruction = Nios2Support.getRTypeInstructionCode(0, 0, 0, opxCodes[Self.instrAdd])
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
      return true
    } else if operation == Self.instrMovia {
      guard instr.numberOfParameters == 2 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      destination = Nios2Support.getRegisterIndex(instr, 0)
      guard let param2 = instr.getParameter(1) else { valid = false; return true }
      if param2.count != 1 || !param2[0].isNumber {
        valid = false
        if let t = param2.first { instr.setError(t, .assemblerExpextedImmediateOrLabel) }
      }
      immediate = param2.first?.getNumberValue() ?? 0
      sourceA = 0; sourceB = 0
      instruction = -1
      if valid {
        var imm = (immediate >> 16) & 0xFFFF
        imm = imm &+ ((immediate >> 15) & 1)
        imm &= 0xFFFF
        let instr0 = Nios2Support.getITypeInstructionCode(0, destination, imm, opcCodes[Self.instrOrhi])
        let imm2 = immediate & 0xFFFF
        let instr1 = Nios2Support.getITypeInstructionCode(destination, destination, imm2, opcCodes[Self.instrAddi])
        instr.setInstructionByteCode([instr0, instr1], nrOfBytes: 4)
      }
      return true
    } else if operation == Self.instrMov {
      guard instr.numberOfParameters == 2 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      valid = Nios2Support.isCorrectRegister(instr, 1) && valid
      destination = Nios2Support.getRegisterIndex(instr, 0)
      sourceA = Nios2Support.getRegisterIndex(instr, 1)
      sourceB = sourceA
      if valid {
        instruction = Nios2Support.getRTypeInstructionCode(sourceA, 0, destination, opxCodes[Self.instrAdd])
        instr.setInstructionByteCode(instruction, nrOfBytes: 4)
      }
      return true
    } else if opcCodes[operation] == Self.pseudoInstr {
      guard instr.numberOfParameters == 2 else {
        valid = false
        instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
        return true
      }
      valid = Nios2Support.isCorrectRegister(instr, 0) && valid
      destination = Nios2Support.getRegisterIndex(instr, 0)
      guard let param2 = instr.getParameter(1) else { valid = false; return true }
      if param2.count != 1 || !param2[0].isNumber {
        valid = false
        if let t = param2.first { instr.setError(t, .assemblerExpectedImmediateValue) }
      }
      immediate = param2.first?.getNumberValue() ?? 0
      sourceA = 0; sourceB = 0
      switch operation {
      case Self.instrMovui, Self.instrMovhi:
        if immediate >= (1 << 16) || immediate < 0 {
          valid = false
          if let t = param2.first { instr.setError(t, .assemblerImmediateOutOfRange) }
        }
        operation = operation == Self.instrMovhi ? Self.instrOrhi : Self.instrOri
      case Self.instrMovi:
        if immediate >= (1 << 15) || immediate < -(1 << 15) {
          valid = false
          if let t = param2.first { instr.setError(t, .assemblerImmediateOutOfRange) }
        }
        operation = Self.instrAddi
      default:
        valid = false
        return false
      }
      if valid {
        instruction = Nios2Support.getITypeInstructionCode(sourceA, destination, immediate, opcCodes[operation])
        instr.setInstructionByteCode(instruction, nrOfBytes: 4)
      }
      return true
    }
    guard instr.numberOfParameters == 3 else {
      valid = false
      instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
      return true
    }
    valid = Nios2Support.isCorrectRegister(instr, 0) && valid
    valid = Nios2Support.isCorrectRegister(instr, 1) && valid
    destination = Nios2Support.getRegisterIndex(instr, 0)
    sourceA = Nios2Support.getRegisterIndex(instr, 1)
    if operation >= Self.instrAndi {
      sourceB = 0
      guard let param3 = instr.getParameter(2) else { valid = false; return true }
      if param3.count != 1 || !param3[0].isNumber {
        valid = false
        if let t = param3.first { instr.setError(t, .assemblerExpectedImmediateValue) }
      }
      immediate = param3.first?.getNumberValue() ?? 0
      if opxCodes[operation] == Self.signExtend {
        if immediate >= (1 << 15) || immediate < -(1 << 15) {
          valid = false
          if let t = param3.first { instr.setError(t, .assemblerImmediateOutOfRange) }
        }
      } else {
        if immediate >= (1 << 16) || immediate < 0 {
          valid = false
          if let t = param3.first { instr.setError(t, .assemblerImmediateOutOfRange) }
        }
      }
    } else {
      immediate = 0
      valid = Nios2Support.isCorrectRegister(instr, 2) && valid
      sourceB = Nios2Support.getRegisterIndex(instr, 2)
    }
    if valid {
      if operation >= Self.instrAndi {
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
      let rcode = Nios2Support.getOPXCode(instr, Nios2Support.rType)
      if let idx = opxCodes.firstIndex(of: rcode) {
        operation = idx
        destination = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
        sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
        sourceB = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
        immediate = -1
        valid = true
      }
    } else if let idx = opcCodes.firstIndex(of: opcode) {
      operation = idx
      destination = Nios2Support.getRegBIndex(instr, Nios2Support.iType)
      sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.iType)
      sourceB = sourceA
      immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
      valid = true
    }
    if valid { convertToPseudo() }
    return valid
  }

  private func convertToPseudo() {
    switch operation {
    case Self.instrAdd:
      if sourceA == 0 && sourceB == 0 && destination == 0 {
        operation = Self.instrNop
      } else if sourceB == 0 {
        operation = Self.instrMov
      }
    case Self.instrOrhi:
      if sourceA == 0 { operation = Self.instrMovhi }
    case Self.instrAddi:
      if sourceA == 0 { operation = Self.instrMovi }
    case Self.instrOri:
      if sourceA == 0 { operation = Self.instrMovui }
    default: break
    }
  }

  public func performedJump() -> Bool { false }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { errorMessage }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    if let idx = opcodes.firstIndex(of: instruction.lowercased()) {
      return opxCodes[idx] == Self.doubleSize ? 8 : 4
    }
    return -1
  }
}
