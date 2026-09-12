/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imEnvironmentCallAndBreakpoints.java (4.1.0); ECALL / EBREAK / MRET.
 *
 * ECALL/EBREAK are stubs in the Java exactly like FENCE (see
 * Rv32imMemoryOrderingInstructions.swift's header for the same pattern: an info dialog,
 * unconditional `true`, no functional effect). MRET is fully implemented and delegates to
 * `Rv32imProcessorState.machineReturn()`.
 *
 * Decode, execute, disassemble and assemble.
 */

public final class Rv32imEnvironmentCallAndBreakpoints: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let system = 0x73
  private static let instrEcall = 0
  private static let instrEbreak = 1
  private static let instrMret = 2
  private static let funct12Mret = 0x302

  private static let asmOpcodes = ["ECALL", "EBREAK", "MRET"]

  private var instruction = 0
  private var operation = 0
  public private(set) var isValid = false

  /// See `Rv32imMemoryOrderingInstructions.lastInfoMessage`: same D17/D9 dialog replacement,
  /// same reason it is a concrete property rather than part of the shared protocol.
  public private(set) var lastInfoMessage: String?

  public var instructions: [String] { Self.asmOpcodes }
  public var binaryInstruction: Int { instruction }
  public var errorMessage: String? { nil }
  public var performedJump: Bool { isValid && operation == Self.instrMret }

  @discardableResult
  public func decode(_ word: Int) -> Bool {
    instruction = word
    isValid = decodeBin()
    return isValid
  }

  public func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool {
    guard isValid else { return false }
    if operation == Self.instrMret {
      state.machineReturn()
      return true
    }
    lastInfoMessage = "ECALL/EBREAK: not implemented"
    return true
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    return Self.asmOpcodes[operation].lowercased()
  }

  private func decodeBin() -> Bool {
    guard Rv32imBits.opcode(instruction) == Self.system else { return false }
    let funct12 = (instruction >> 20) & 0xFFF
    if funct12 <= 1 {
      operation = funct12
      return true
    }
    if funct12 == Self.funct12Mret {
      operation = Self.instrMret
      return true
    }
    return false
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`. Three zero-operand mnemonics, encoded as
  /// I-type SYSTEM words whose whole content is the 12-bit immediate: ECALL 0, EBREAK 1, MRET
  /// `FUNCT12_MRET` (0x302).
  ///
  /// The immediate for ECALL/EBREAK is `operation` itself, which works only because their
  /// `AsmOpcodes` positions (0 and 1) happen to equal their funct12 values. Upstream relies on
  /// that; transcribed as written rather than "clarified" with a lookup that could drift.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }
    guard instr.numberOfParameters == 0 else {
      instr.setError(instr.instruction, .assemblerExpectedNoArguments)
      isValid = false
      return true
    }
    instruction =
      (operation == Self.instrMret)
      ? Rv32imBits.iTypeInstruction(
        opcode: Self.system, rd: 0, funct3: 0, rs1: 0, imm: Self.funct12Mret)
      : Rv32imBits.iTypeInstruction(
        opcode: Self.system, rd: 0, funct3: 0, rs1: 0, imm: operation)
    isValid = true
    instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    return true
  }
}
