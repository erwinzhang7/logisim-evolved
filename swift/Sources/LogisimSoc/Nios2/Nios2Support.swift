// Nios2Support.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2Support), GPL-3.0-only.
// See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Pure bit-field encode/decode for the three Nios II instruction formats (I-type, R-type,
// J-type). Every value here is a 32-bit field; all shifts are already within range (the widest,
// 27, is far under 32), so none of the RV32-style shift-count-masking hazards apply, the hazard
// here is purely making sure every intermediate stays `Int` (not `Int32`, which traps on `<<`
// overflow into the sign bit) and gets `wrap32`'d at the one place a full instruction word is
// assembled (the field values themselves are always masked to their own width before shifting,
// so the final OR can never itself exceed 32 significant bits, `wrap32` at the end is there so
// callers always get back something in the `Int32`-representable range Java's `int` return type
// implies, exactly like every RV32 encode helper does).
import LogisimKernel

public enum Nios2Support {
  public static let asmFieldSize = 10

  public static let iType = 0
  public static let rType = 1
  public static let jType = 2

  public static func getOpcode(_ instruction: Int) -> Int {
    instruction & 0x3F
  }

  public static func getImmediate(_ instruction: Int, _ type: Int) -> Int {
    switch type {
    case iType: return (instruction >> 6) & 0xFFFF
    case jType: return (instruction >> 6) & 0x3FFFFFF
    default: return 0
    }
  }

  public static func getRegAIndex(_ instruction: Int, _ type: Int) -> Int {
    switch type {
    case iType, rType: return (instruction >> 27) & 0x1F
    default: return 0
    }
  }

  public static func getRegBIndex(_ instruction: Int, _ type: Int) -> Int {
    switch type {
    case iType, rType: return (instruction >> 22) & 0x1F
    default: return 0
    }
  }

  public static func getRegCIndex(_ instruction: Int, _ type: Int) -> Int {
    guard type == rType else { return 0 }
    return (instruction >> 17) & 0x1F
  }

  public static func getOPX(_ instruction: Int, _ type: Int) -> Int {
    guard type == rType else { return 0 }
    return (instruction >> 6) & 0x7FF
  }

  public static func getOPXCode(_ instruction: Int, _ type: Int) -> Int {
    guard type == rType else { return 0 }
    return (instruction >> 11) & 0x3F
  }

  public static func getOPXImm(_ instruction: Int, _ type: Int) -> Int {
    guard type == rType else { return 0 }
    return (instruction >> 6) & 0x1F
  }

  public static func getITypeInstructionCode(_ regA: Int, _ regB: Int, _ imm: Int, _ opc: Int) -> Int {
    var instruction = opc & 0x3F
    instruction |= (imm & 0xFFFF) << 6
    instruction |= (regB & 0x1F) << 22
    instruction |= (regA & 0x1F) << 27
    return wrap32(instruction)
  }

  public static func getCustomInstructionCode(
    _ regA: Int, _ regB: Int, _ regC: Int, _ opx: Int, _ opc: Int
  ) -> Int {
    var instruction = opc & 0x3F
    instruction |= (opx & 0x7FF) << 6
    instruction |= (regC & 0x1F) << 17
    instruction |= (regB & 0x1F) << 22
    instruction |= (regA & 0x1F) << 27
    return wrap32(instruction)
  }

  public static func getRTypeInstructionCode(_ regA: Int, _ regB: Int, _ regC: Int, _ opxcode: Int) -> Int {
    var instruction = 0x3A
    instruction |= (opxcode & 0x3F) << 11
    instruction |= (regC & 0x1F) << 17
    instruction |= (regB & 0x1F) << 22
    instruction |= (regA & 0x1F) << 27
    return wrap32(instruction)
  }

  public static func getRTypeInstructionCode(
    _ regA: Int, _ regB: Int, _ regC: Int, _ opxcode: Int, _ opximm: Int
  ) -> Int {
    var instruction = 0x3A
    instruction |= (opxcode & 0x3F) << 11
    instruction |= (opximm & 0x1F) << 6
    instruction |= (regC & 0x1F) << 17
    instruction |= (regB & 0x1F) << 22
    instruction |= (regA & 0x1F) << 27
    return wrap32(instruction)
  }

  public static func getJTypeInstructionCode(_ imm: Int, _ opc: Int) -> Int {
    var instruction = opc & 0x3F
    instruction |= (imm & 0x3FFFFFF) << 6
    return wrap32(instruction)
  }

  public static func isCorrectRegister(_ instr: AssemblerAsmInstruction, _ index: Int) -> Bool {
    guard index >= 0, index < instr.numberOfParameters, let tok = instr.getParameter(index) else {
      return false
    }
    guard tok.count == 1 else {
      if let first = tok.first { instr.setError(first, .assemblerExpectedRegister) }
      return false
    }
    if tok[0].type == Nios2Assembler.customRegister {
      instr.setError(tok[0], .nios2CannotUseCustomRegister)
      return false
    }
    if tok[0].type == Nios2Assembler.controlRegister {
      instr.setError(tok[0], .nios2CannotUseControlRegister)
      return false
    }
    if tok[0].type != AssemblerToken.register {
      instr.setError(tok[0], .assemblerExpectedRegister)
      return false
    }
    let regid = Nios2ProcessorState.getRegisterIndex(tok[0].value)
    if regid < 0 || regid > 31 {
      instr.setError(tok[0], .assemblerUnknownRegister)
      return false
    }
    return true
  }

  public static func getRegisterIndex(_ instr: AssemblerAsmInstruction, _ index: Int) -> Int {
    guard isCorrectRegister(instr, index), let tok = instr.getParameter(index) else { return 0 }
    return Nios2ProcessorState.getRegisterIndex(tok[0].value)
  }
}
