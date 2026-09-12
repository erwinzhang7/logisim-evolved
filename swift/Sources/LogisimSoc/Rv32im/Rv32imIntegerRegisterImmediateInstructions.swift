/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imIntegerRegisterImmediateInstructions.java (4.1.0):
 * ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI/LUI/AUIPC and the pseudo-instructions
 * NOP/LI/SEQZ/NOT/MV, decode/execute/disassemble AND assemble.
 */

import LogisimKernel

public final class Rv32imIntegerRegisterImmediateInstructions: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let opImm = 0x13
  private static let lui = 0x37
  private static let auipc = 0x17
  private static let addi = 0
  private static let xori = 4
  private static let sltiu = 3
  private static let slli = 1
  private static let srlai = 5

  private static let instrAddi = 0
  private static let instrSlti = 2
  private static let instrSltiu = 3
  private static let instrXori = 4
  private static let instrOri = 6
  private static let instrAndi = 7
  private static let instrSlli = 1
  private static let instrSrli = 5
  private static let instrSrai = 8
  private static let instrLui = 9
  private static let instrAuipc = 10
  private static let instrNop = 11
  private static let instrLi = 12
  private static let instrSeqz = 13
  private static let instrNot = 14
  private static let instrMv = 15

  /// Java: `AsmOpcodes`. Index == `operation`'s `INSTR_*` value, verified 1:1 against the
  /// Java's constant list.
  private static let asmOpcodes = [
    "ADDI", "SLLI", "SLTI", "SLTIU", "XORI", "SRLI", "ORI",
    "ANDI", "SRAI", "LUI", "AUIPC", "NOP", "LI", "SEQZ", "NOT", "MV",
  ]

  private var instruction = 0
  private var destination = 0
  private var source = 0
  private var immediate = 0
  private var operation = 0
  public private(set) var isValid = false

  public var instructions: [String] { Self.asmOpcodes }
  public var binaryInstruction: Int { instruction }
  public var performedJump: Bool { false }
  public var errorMessage: String? { nil }

  @discardableResult
  public func decode(_ word: Int) -> Bool {
    instruction = word
    decodeBin()
    return isValid
  }

  public func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool {
    if !isValid { return false }
    let regVal = state.registerValue(source)
    var result = 0
    switch operation {
    case Self.instrLi, Self.instrNop, Self.instrMv, Self.instrAddi:
      result = wrap32(regVal &+ immediate)
    case Self.instrSlti:
      result = (regVal < immediate) ? 1 : 0
    case Self.instrSeqz, Self.instrSltiu:
      result = (Rv32imBits.unsignedMagnitude(regVal) < Rv32imBits.unsignedMagnitude(immediate)) ? 1 : 0
    case Self.instrNot, Self.instrXori:
      result = wrap32(regVal ^ immediate)
    case Self.instrOri:
      result = wrap32(regVal | immediate)
    case Self.instrAndi:
      result = wrap32(regVal & immediate)
    case Self.instrSlli:
      // `immediate` is already masked to 5 bits by `decodeBin` (the SLLI shamt field is only
      // 5 bits wide), so no further masking is needed here: matches the Java, which relies
      // on the same decode-time narrowing rather than masking again at execute time.
      result = wrap32(regVal << immediate)
    case Self.instrSrli:
      // Java: `ElfHeader.getLongValue(regVal) >>> immediate` then `getIntValue`: a logical
      // (zero-filling) right shift, unlike SRAI below. Reproduced by shifting the *unsigned*
      // magnitude, which for a nonnegative Swift `Int` is exactly a logical shift.
      let val1 = Rv32imBits.unsignedMagnitude(regVal) >> immediate
      result = wrap32(val1)
    case Self.instrSrai:
      // Java: `regVal >> immediate`; arithmetic (sign-extending). Swift's `>>` on `Int` is
      // also arithmetic, and `regVal` is canonical (sign-extended through bit 63), so this is
      // a direct, correct port with no extra masking of the shifted-in bits needed.
      result = wrap32(regVal >> immediate)
    case Self.instrLui:
      result = immediate
    case Self.instrAuipc:
      // Java: zero-extend pc to unsigned 64 bits, add the (signed, already-shifted) U-type
      // immediate, then truncate back to the low 32 bits. See this file's own note in
      // `Rv32imBits`-adjacent commentary: truncating `pc &+ immediate` directly gives the
      // identical low 32 bits, since the extra zero-extension only changes bits above 31
      // which `wrap32` discards either way; kept as the explicit two-step form to mirror the
      // Java source line for line.
      let pcUnsigned = Rv32imBits.unsignedMagnitude(state.pc)
      result = wrap32(pcUnsigned &+ immediate)
    default:
      return false
    }
    state.writeRegister(destination, result)
    return true
  }

  public var asmInstruction: String? {
    guard isValid else { return "Unknown" }
    var s = Self.asmOpcodes[operation].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    switch operation {
    case Self.instrNop:
      break
    case Self.instrLi:
      s += "\(Rv32imRegisterNames.abi[destination]),\(immediate)"
    case Self.instrLui, Self.instrAuipc:
      s += "\(Rv32imRegisterNames.abi[destination]),\((immediate >> 12) & 0xFFFFF)"
    case Self.instrMv, Self.instrNot, Self.instrSeqz:
      s += "\(Rv32imRegisterNames.abi[destination]),\(Rv32imRegisterNames.abi[source])"
    default:
      s += "\(Rv32imRegisterNames.abi[destination]),\(Rv32imRegisterNames.abi[source]),\(immediate)"
    }
    return s
  }

  private func decodeBin() {
    let opcode = Rv32imBits.opcode(instruction)
    switch opcode {
    case Self.lui, Self.auipc:
      isValid = true
      destination = Rv32imBits.destinationRegisterIndex(instruction)
      immediate = Rv32imBits.immediate(instruction, type: .uType)
      operation = (opcode == Self.lui) ? Self.instrLui : Self.instrAuipc
      return
    case Self.opImm:
      isValid = true
      source = Rv32imBits.sourceRegister1Index(instruction)
      destination = Rv32imBits.destinationRegisterIndex(instruction)
      immediate = Rv32imBits.immediate(instruction, type: .iType)
    default:
      isValid = false
      return
    }
    // Reached only for opcode == OP_IMM.
    let op3 = Rv32imBits.funct3(instruction)
    if op3 != Self.srlai {
      operation = op3
      if op3 == Self.slli {
        if Rv32imBits.funct7(instruction) != 0 {
          isValid = false
          return
        }
        immediate = (instruction >> 20) & 0x1F
      }
      if op3 == Self.addi {
        if destination == 0 && source == 0 && immediate == 0 {
          operation = Self.instrNop
        } else if source == 0 {
          operation = Self.instrLi
        } else if immediate == 0 {
          operation = Self.instrMv
        }
      }
      if op3 == Self.sltiu {
        if immediate == 1 { operation = Self.instrSeqz }
      }
      if op3 == Self.xori {
        if immediate == -1 { operation = Self.instrNot }
      }
      return
    }
    // Reached only for a SRLI or SRAI instruction.
    let funct7 = Rv32imBits.funct7(instruction)
    if funct7 == 0 || funct7 == 0x20 {
      let bit30 = (instruction >> 30) & 1
      operation = op3 + bit30 * 3
      immediate = (instruction >> 20) & 0x1F
      return
    }
    isValid = false
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`.
  ///
  /// Three shapes, then one encoding switch, and the encoding switch runs on the *rewritten*
  /// `operation`, which is why every pseudo-instruction case reassigns it before falling out.
  ///
  /// Two details that are easy to lose and are both verified against the jar
  /// (`tools/socbridge/AsmBridge.java`):
  ///
  ///   * `SRAI` is encoded as `SRLI` with **bit 10 of the immediate** set (`immediate |= 1 << 10`),
  ///     not with a funct7 field: because `getITypeInstruction` shifts the whole 12-bit
  ///     immediate into place, and bit 10 of that lands at bit 30, which is the SRA marker.
  ///   * `LUI`/`AUIPC` take the immediate **already shifted right by 12** when it came from a
  ///     label, and unshifted when it was a literal. `param2[0].isLabel()` is what distinguishes
  ///     them, and `AUIPC` additionally subtracts the program counter first.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }

    var errors = false
    switch operation {
    case Self.instrNop:
      if !Rv32imAsmSupport.expectParameters(instr, 0) {
        errors = true
        break
      }
      operation = Self.instrAddi
      destination = 0
      source = 0
      immediate = 0

    case Self.instrLui, Self.instrAuipc, Self.instrLi:
      // format: opcode rd,#imm
      if !Rv32imAsmSupport.expectParameters(instr, 2) {
        errors = true
        break
      }
      guard let param1 = Rv32imAsmSupport.registerToken(instr, 0) else {
        errors = true
        break
      }
      guard let param2 = Rv32imAsmSupport.numberToken(instr, 1) else {
        errors = true
        break
      }
      if operation == Self.instrLi { operation = Self.instrAddi }
      source = 0
      destination = Rv32imAsmSupport.registerIndex(instr, param1, &errors)
      immediate = param2.getNumberValue()
      if operation == Self.instrLui && param2.isLabel {
        immediate = (immediate >> 12) & 0xFFFFF
      }
      if operation == Self.instrAuipc && param2.isLabel {
        var imm = Int64(immediate)
        imm -= instr.getProgramCounter()
        immediate = Int(Int32(truncatingIfNeeded: imm))
        immediate = (immediate >> 12) & 0xFFFFF
      }

    case Self.instrMv, Self.instrNot, Self.instrSeqz:
      // format: opcode rd,rs
      if !Rv32imAsmSupport.expectParameters(instr, 2) {
        errors = true
        break
      }
      guard let param1 = Rv32imAsmSupport.registerToken(instr, 0) else {
        errors = true
        break
      }
      guard let param2 = Rv32imAsmSupport.registerToken(instr, 1) else {
        errors = true
        break
      }
      immediate = -1
      source = Rv32imAsmSupport.registerIndex(instr, param2, &errors)
      destination = Rv32imAsmSupport.registerIndex(instr, param1, &errors)
      switch operation {
      case Self.instrMv:
        immediate = 0
        operation = Self.instrAddi
      case Self.instrNot:
        operation = Self.instrXori
      default:
        operation = Self.instrSltiu
        immediate = 1
      }

    default:
      // format: opcode rd,rs,#imm
      if !Rv32imAsmSupport.expectParameters(instr, 3) {
        errors = true
        break
      }
      guard let param1 = Rv32imAsmSupport.registerToken(instr, 0) else {
        errors = true
        break
      }
      guard let param2 = Rv32imAsmSupport.registerToken(instr, 1) else {
        errors = true
        break
      }
      guard let param3 = Rv32imAsmSupport.numberToken(instr, 2) else {
        errors = true
        break
      }
      immediate = param3.getNumberValue()
      source = Rv32imAsmSupport.registerIndex(instr, param2, &errors)
      destination = Rv32imAsmSupport.registerIndex(instr, param1, &errors)
    }

    if !errors {
      /// The token Java flags for an out-of-range immediate: the first token of the LAST
      /// parameter, whichever arity this instruction had.
      let lastParameter = instr.getParameter(instr.numberOfParameters - 1)?.first
      switch operation {
      case Self.instrAddi, Self.instrSlti, Self.instrSltiu, Self.instrAndi, Self.instrOri,
        Self.instrXori:
        if immediate > 2047 || immediate < -2048 {
          errors = true
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          break
        }
        instruction = Rv32imBits.iTypeInstruction(
          opcode: Self.opImm, rd: destination, funct3: operation, rs1: source, imm: immediate)
      case Self.instrSlli, Self.instrSrli, Self.instrSrai:
        if immediate > 31 || immediate < 0 {
          errors = true
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          break
        }
        if operation == Self.instrSrai {
          immediate |= 1 << 10
          operation = Self.instrSrli
        }
        instruction = Rv32imBits.iTypeInstruction(
          opcode: Self.opImm, rd: destination, funct3: operation, rs1: source, imm: immediate)
      case Self.instrLui, Self.instrAuipc:
        if immediate < 0 || immediate >= (1 << 20) {
          errors = true
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          break
        }
        let opcode = (operation == Self.instrLui) ? Self.lui : Self.auipc
        instruction = Rv32imBits.uTypeInstruction(
          opcode: opcode, rd: destination, imm: immediate)
      default:
        errors = true
        instr.setError(instr.instruction, .rv32imAssemblerBug)
      }
    }

    isValid = !errors
    if isValid { instr.setInstructionByteCode(instruction, nrOfBytes: 4) }
    return true
  }
}
