/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imSupport.java (4.1.0)
 *
 * Pure bit manipulation: instruction-field extraction, immediate sign-extension/decoding, and
 * instruction encoding. No dependency on processor state or the bus, so every function here is
 * static in the Java and a free function/static method here.
 *
 * CONVENTION (binding for this whole Rv32im slice): every value that a Java `int` would hold,
 * a register, a CSR, a raw instruction word, an immediate, an address, is carried as a Swift
 * `Int` that is kept in *canonical wrapped form*: the low 32 bits, sign-extended into the
 * high bits of the 64-bit `Int`, exactly as `wrap32` (LogisimKernel/Location.swift) produces.
 * That is what licenses porting Java's bitwise tricks (`>>`, `<<`, `&`, `|`, comparisons)
 * literally: as long as every value flowing into an expression is already canonical, Swift's
 * `>>` on `Int` is an arithmetic (sign-extending) shift exactly like Java's `>>` on `int`, and
 * masking the low bits of a shift result is unaffected by the extra sign-extension bits above
 * bit 31. The one discipline this demands, and the one this file is careful about everywhere
 * it builds a *new* word by OR-ing shifted fields together (the six `xTypeInstruction`
 * encoders): the result must be re-wrapped with `wrap32` before anyone treats it as a
 * canonical value again, because OR-ing shifted 7-bit/5-bit fields can legitimately set bit 31
 * and produce a large *positive* `Int` that must be reinterpreted as the corresponding
 * negative 32-bit word; Java gets this for free because `int` arithmetic IS 32-bit; we do not.
 */

import LogisimKernel

/// The six RISC-V instruction formats, matching `RV32imSupport.R_TYPE` … `J_TYPE`.
public enum Rv32imInstructionType: Int, Equatable {
  case rType = 0
  case iType = 1
  case sType = 2
  case bType = 3
  case uType = 4
  case jType = 5
}

public enum Rv32imBits {
  /// `RV32imSupport.ASM_FIELD_SIZE`; column the operand list is padded to in disassembly text.
  public static let asmFieldSize = 10

  /// Java: `ElfHeader.getLongValue(Object)` for the `Integer` overload; reads a canonical
  /// wrap32'd word as its zero-extended unsigned 32-bit magnitude. Ported locally (rather than
  /// depending on `soc/file/ElfHeader`, which is outside this slice) because it is the one
  /// primitive every unsigned comparison and the M-extension's unsigned multiplies/divides
  /// need. `v` MUST already be canonical (wrap32'd); the mask only clears the sign-extension
  /// bits above bit 31; it does not itself canonicalize a non-wrapped input.
  public static func unsignedMagnitude(_ v: Int) -> Int { v & 0xFFFF_FFFF }

  /// Same, widened to `UInt64`; needed once for MULHU (see `Rv32imMExtensionInstructions`),
  /// where the product of two full-range unsigned 32-bit magnitudes (up to `(2^32-1)^2` ≈
  /// 1.8447e19) exceeds `Int64.max` (≈ 9.223e18) and would silently overflow-trap if computed
  /// with `Int`/`Int64`.
  public static func unsignedMagnitude64(_ v: Int) -> UInt64 { UInt64(UInt32(truncatingIfNeeded: v)) }

  /// Ports `RV32imSupport.getImmediateValue`. The Java builds the sign extension by seeding
  /// `result` with `Integer.MIN_VALUE` when the instruction is negative and then arithmetic-
  /// shifting it right by the format's field width before OR-ing in the format-specific bit
  /// groups: a roundabout but exact way of sign-extending from whatever the format's sign-bit
  /// position is. Ported literally, field extraction and all, rather than reimplemented, since
  /// getting the bit groupings for B_TYPE/J_TYPE (which interleave immediate bits out of
  /// order) subtly wrong is exactly the kind of thing a "cleaner" rewrite would miss.
  public static func immediate(_ instruction: Int, type: Rv32imInstructionType) -> Int {
    let shifts = [0, 20, 20, 19, 0, 11]
    if type == .rType { return 0 }
    var result = (instruction < 0) ? Int(Int32.min) : 0
    result = result >> shifts[type.rawValue]
    let bits30_25 = (instruction >> 25) & 0x3F
    let bits24_21 = (instruction >> 21) & 0xF
    let bit20 = (instruction >> 20) & 0x1
    let bits19_12 = (instruction >> 12) & 0xFF
    let bits11_8 = (instruction >> 8) & 0xF
    let bit7 = (instruction >> 7) & 0x1
    switch type {
    case .iType:
      result |= (bits30_25 << 5) | (bits24_21 << 1) | bit20
    case .sType:
      result |= (bits30_25 << 5) | (bits11_8 << 1) | bit7
    case .bType:
      result |= (bit7 << 11) | (bits30_25 << 5) | (bits11_8 << 1)
    case .uType:
      result |= (bits30_25 << 25) | (bits24_21 << 21) | (bit20 << 20) | (bits19_12 << 12)
    case .jType:
      result |= (bits19_12 << 12) | (bit20 << 11) | (bits30_25 << 5) | (bits24_21 << 1)
    case .rType:
      break
    }
    return wrap32(result)
  }

  public static func iTypeInstruction(opcode: Int, rd: Int, funct3: Int, rs1: Int, imm: Int) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (rd & 0x1F) << 7
    instruction |= (funct3 & 0x7) << 12
    instruction |= (rs1 & 0x1F) << 15
    instruction |= (imm & 0xFFF) << 20
    return wrap32(instruction)
  }

  public static func rTypeInstruction(
    opcode: Int, rd: Int, funct3: Int, rs1: Int, rs2: Int, funct7: Int
  ) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (rd & 0x1F) << 7
    instruction |= (funct3 & 0x7) << 12
    instruction |= (rs1 & 0x1F) << 15
    instruction |= (rs2 & 0x1F) << 20
    instruction |= (funct7 & 0x7F) << 25
    return wrap32(instruction)
  }

  public static func sTypeInstruction(opcode: Int, rs1: Int, rs2: Int, funct3: Int, imm: Int) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (funct3 & 0x7) << 12
    instruction |= (rs1 & 0x1F) << 15
    instruction |= (rs2 & 0x1F) << 20
    instruction |= (imm & 0x1F) << 7
    instruction |= ((imm >> 5) & 0x7F) << 25
    return wrap32(instruction)
  }

  public static func jTypeInstruction(opcode: Int, rd: Int, imm: Int) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (rd & 0x1F) << 7
    instruction |= ((imm >> 12) & 0xFF) << 12
    instruction |= ((imm >> 11) & 1) << 20
    instruction |= ((imm >> 1) & 0x3FF) << 21
    instruction |= ((imm >> 20) & 1) << 31
    return wrap32(instruction)
  }

  public static func bTypeInstruction(opcode: Int, funct3: Int, rs1: Int, rs2: Int, imm: Int) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (funct3 & 0x7) << 12
    instruction |= (rs1 & 0x1F) << 15
    instruction |= (rs2 & 0x1F) << 20
    instruction |= ((imm >> 11) & 1) << 7
    instruction |= ((imm >> 1) & 0xF) << 8
    instruction |= ((imm >> 5) & 0x3F) << 25
    instruction |= ((imm >> 12) & 1) << 31
    return wrap32(instruction)
  }

  public static func uTypeInstruction(opcode: Int, rd: Int, imm: Int) -> Int {
    var instruction = opcode & 0x7F
    instruction |= (rd & 0x1F) << 7
    instruction |= (imm & 0xFFFFF) << 12
    return wrap32(instruction)
  }

  public static func opcode(_ instruction: Int) -> Int { instruction & 0x7F }
  public static func funct3(_ instruction: Int) -> Int { (instruction >> 12) & 0x7 }
  public static func destinationRegisterIndex(_ instruction: Int) -> Int { (instruction >> 7) & 0x1F }
  public static func sourceRegister1Index(_ instruction: Int) -> Int { (instruction >> 15) & 0x1F }
  public static func sourceRegister2Index(_ instruction: Int) -> Int { (instruction >> 20) & 0x1F }
  public static func funct7(_ instruction: Int) -> Int { (instruction >> 25) & 0x7F }
}
