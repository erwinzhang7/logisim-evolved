/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imControlTransferInstructions.java (4.1.0):
 * BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR and the pseudo-instructions J/JR/RET/BNEZ/BEQZ.
 * Decode, execute, disassemble AND assemble, including the label-relative
 * `getAsmInstruction(String)` overload and `isLabelSupported`/`getLabelAddress` from
 * `AbstractExecutionUnitWithLabelSupport`: the Nios II family's `Nios2ProgramControlInstructions`
 * already conformed to the Swift counterpart of that interface, so RV32IM not doing so was an
 * asymmetry rather than a decision. `isPcRelative`, dropped with them, is restored: it is set by
 * `decodeBin` and is the whole of what `isLabelSupported` answers.
 */

import LogisimKernel

public final class Rv32imControlTransferInstructions: Rv32imExecutionUnit,
  AssemblerExecutionUnitWithLabelSupport
{
  private static let jal = 0x6F
  private static let jalr = 0x67
  private static let branch = 0x63

  private static let instrBeq = 0
  private static let instrBne = 1
  private static let instrJal = 2
  private static let instrJalr = 3
  private static let instrBlt = 4
  private static let instrBge = 5
  private static let instrBltu = 6
  private static let instrBgeu = 7
  private static let instrJ = 8
  private static let instrJr = 9
  private static let instrRet = 10
  private static let instrBnez = 11
  private static let instrBeqz = 12

  private static let asmOpcodes = [
    "BEQ", "BNE", "JAL", "JALR", "BLT", "BGE", "BLTU", "BGEU", "J", "JR", "RET", "BNEZ", "BEQZ",
  ]

  public private(set) var isValid = false
  /// Java: `public boolean isPcRelative`: set by `decodeBin`, read only by `isLabelSupported`.
  public private(set) var isPcRelative = false
  private var jumped = false
  private var instruction = 0
  private var destination = 0
  private var operation = 0
  private var immediate = 0
  private var source1 = 0
  private var source2 = 0

  public var instructions: [String] { Self.asmOpcodes }
  public var binaryInstruction: Int { instruction }
  public var performedJump: Bool { isValid && jumped }
  public var errorMessage: String? { nil }

  @discardableResult
  public func decode(_ word: Int) -> Bool {
    instruction = word
    jumped = false
    isValid = decodeBin()
    return isValid
  }

  public func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool {
    if !isValid { return false }
    jumped = false
    var target = wrap32(state.pc &+ immediate)
    let nextPc = wrap32(state.pc &+ 4)
    let reg1 = state.registerValue(source1)
    let reg2 = state.registerValue(source2)
    switch operation {
    case Self.instrJal, Self.instrJ:
      state.setProgramCounter(target)
      jumped = true
      state.writeRegister(destination, nextPc)
      return true
    case Self.instrRet, Self.instrJr, Self.instrJalr:
      target = wrap32(state.registerValue(source1) &+ immediate)
      target = wrap32((target >> 1) << 1)
      state.setProgramCounter(target)
      jumped = true
      state.writeRegister(destination, nextPc)
      return true
    case Self.instrBeqz, Self.instrBeq:
      if reg1 == reg2 {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    case Self.instrBnez, Self.instrBne:
      if reg1 != reg2 {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    case Self.instrBlt:
      if reg1 < reg2 {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    case Self.instrBge:
      if reg1 >= reg2 {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    case Self.instrBltu:
      if Rv32imBits.unsignedMagnitude(reg1) < Rv32imBits.unsignedMagnitude(reg2) {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    case Self.instrBgeu:
      if Rv32imBits.unsignedMagnitude(reg1) >= Rv32imBits.unsignedMagnitude(reg2) {
        jumped = true
        state.setProgramCounter(target)
      }
      return true
    default:
      return false
    }
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    var s = Self.asmOpcodes[operation].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    switch operation {
    case Self.instrRet:
      break
    case Self.instrJal:
      s += "\(Rv32imRegisterNames.abi[destination]),"
      fallthrough
    case Self.instrJ:
      s += "pc"
      if immediate != 0 { s += (immediate >= 0 ? "+" : "") + "\(immediate)" }
    case Self.instrJalr:
      s += "\(Rv32imRegisterNames.abi[destination]),"
      fallthrough
    case Self.instrJr:
      s += Rv32imRegisterNames.abi[source1]
      if immediate != 0 { s += ",\(immediate)" }
    case Self.instrBeqz, Self.instrBnez:
      s += "\(Rv32imRegisterNames.abi[source1]),pc"
      if immediate != 0 { s += (immediate >= 0 ? "+" : "") + "\(immediate)" }
    default:
      s += "\(Rv32imRegisterNames.abi[source1]),\(Rv32imRegisterNames.abi[source2]),pc"
      if immediate != 0 { s += (immediate >= 0 ? "+" : "") + "\(immediate)" }
    }
    return s
  }

  private func decodeBin() -> Bool {
    let opcode = Rv32imBits.opcode(instruction)
    isPcRelative = true
    switch opcode {
    case Self.jal:
      destination = Rv32imBits.destinationRegisterIndex(instruction)
      operation = (destination == 0) ? Self.instrJ : Self.instrJal
      immediate = Rv32imBits.immediate(instruction, type: .jType)
      return true
    case Self.jalr:
      if Rv32imBits.funct3(instruction) != 0 { return false }
      isPcRelative = false
      destination = Rv32imBits.destinationRegisterIndex(instruction)
      operation = (destination == 0) ? Self.instrJr : Self.instrJalr
      source1 = Rv32imBits.sourceRegister1Index(instruction)
      immediate = Rv32imBits.immediate(instruction, type: .iType)
      if operation == Self.instrJr && source1 == 1 && immediate == 0 { operation = Self.instrRet }
      return true
    case Self.branch:
      operation = Rv32imBits.funct3(instruction)
      if operation == 2 || operation == 3 { return false }
      immediate = Rv32imBits.immediate(instruction, type: .bType)
      source1 = Rv32imBits.sourceRegister1Index(instruction)
      source2 = Rv32imBits.sourceRegister2Index(instruction)
      if operation == Self.instrBne && source2 == 0 { operation = Self.instrBnez }
      if operation == Self.instrBeq && source2 == 0 { operation = Self.instrBeqz }
      return true
    default:
      return false
    }
  }

  // MARK: - Label support (Java: AbstractExecutionUnitWithLabelSupport)

  /// `isLabelSupported()`, literally `return isPcRelative;`.
  public func isLabelSupported() -> Bool { isPcRelative }

  /// `getLabelAddress(long pc)`: `pc + immediate`. No `isLabelSupported` guard upstream, unlike
  /// the Nios II unit's version, which returns -1 first; preserved as written.
  public func getLabelAddress(pc: Int64) -> Int64 { pc + Int64(immediate) }

  /// `getAsmInstruction(String label)`.
  ///
  /// The `default` branch prints `source2` then `source1`: the REVERSE of the no-label
  /// `getAsmInstruction` above, which prints `source1` then `source2`
  /// (`RV32imControlTransferInstructions.java:213-215` against `:172-174`). That is upstream's,
  /// and it is preserved rather than "corrected": the two are different methods and a
  /// disassembly listing that silently swapped operand order relative to the jar would be a
  /// worse bug than the inconsistency.
  public func getAsmInstruction(label: String) -> String? {
    guard isValid else { return nil }
    var s = Self.asmOpcodes[operation].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    switch operation {
    case Self.instrRet:
      break
    case Self.instrJal:
      s += "\(Rv32imRegisterNames.abi[destination]),"
      fallthrough
    case Self.instrJ:
      s += label
    case Self.instrJalr:
      s += "\(Rv32imRegisterNames.abi[destination]),"
      fallthrough
    case Self.instrJr:
      s += Rv32imRegisterNames.abi[source1]
      if immediate != 0 { s += ",\(immediate)" }
    case Self.instrBeqz, Self.instrBnez:
      s += "\(Rv32imRegisterNames.abi[source1]),\(label)"
    default:
      s += "\(Rv32imRegisterNames.abi[source2]),\(Rv32imRegisterNames.abi[source1]),\(label)"
    }
    return s
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`.
  ///
  /// Every pseudo-instruction here rewrites the operand *positions*, not just the mnemonic, and
  /// each rewrite is transcribed literally because the shuffles do not follow a pattern:
  ///
  /// | written | becomes |
  /// |---|---|
  /// | `ret` | `jalr x0, x1, 0`: `source1 = source2 = 1`, `destination = 0` |
  /// | `jr rs` | `jalr x0, rs, imm`; the register moves from `destination` into both sources |
  /// | `beqz rs,imm` | `beq rs, x0, imm`: `source1 = destination`, then `source2 = destination = 0` |
  /// | `j imm` | `jal x0, imm` |
  /// | `beq rd,rs,imm` (default) | `source1 = destination; destination = 0` unless JALR |
  ///
  /// **Upstream inconsistency preserved:** the `J` case records
  /// `AssemblerExpectedImmediateValue` when its parameter is not a number but does **not** set
  /// `errors`, so the instruction is still encoded (from whatever `getNumberValue()` returns for
  /// a non-number, which is 0) and `valid` ends up true. Every other case sets `errors = true`
  /// and breaks. Left exactly as upstream wrote it.
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
    case Self.instrRet:
      guard instr.numberOfParameters == 0 else {
        instr.setError(instr.instruction, .assemblerExpectedNoArguments)
        errors = true
        break
      }
      destination = 0
      operation = Self.instrJalr
      immediate = 0
      source1 = 1
      source2 = 1

    case Self.instrBeqz, Self.instrBnez, Self.instrJr, Self.instrJal:
      guard instr.numberOfParameters != 0, instr.numberOfParameters <= 2 else {
        instr.setError(instr.instruction, .rv32imAssemblerExpectedOneOrTwoArguments)
        errors = true
        break
      }
      guard let param1 = instr.getParameter(0) else {
        errors = true
        break
      }
      if param1.count != 1 || param1[0].type != AssemblerToken.register {
        instr.setError(param1[0], .assemblerExpectedRegister)
        errors = true
        break
      }
      destination = Rv32imRegisterNames.index(of: param1[0].value)
      if destination < 0 || destination > 31 {
        instr.setError(param1[0], .assemblerUnknownRegister)
        errors = true
        break
      }
      source1 = 0
      source2 = 0
      immediate = 0
      if instr.numberOfParameters == 2, let param2 = instr.getParameter(1) {
        if param2.count != 1 || !param2[0].isNumber {
          instr.setError(param2[0], .assemblerExpectedImmediateValue)
          errors = true
          break
        }
        immediate = param2[0].getNumberValue()
      }
      if operation == Self.instrJr {
        source1 = destination
        source2 = destination
        destination = 0
        operation = Self.instrJalr
      }
      if operation == Self.instrBeqz || operation == Self.instrBnez {
        source1 = destination
        source2 = 0
        destination = 0
        operation = (operation == Self.instrBeqz) ? Self.instrBeq : Self.instrBne
      }

    case Self.instrJ:
      guard instr.numberOfParameters == 1, let param1 = instr.getParameter(0) else {
        instr.setError(instr.instruction, .assemblerExpectedOneArgument)
        errors = true
        break
      }
      // Upstream records the error and does NOT set `errors` here, see the doc comment.
      if param1.count != 1 || !param1[0].isNumber {
        instr.setError(param1[0], .assemblerExpectedImmediateValue)
      }
      immediate = param1[0].getNumberValue()
      destination = 0
      source1 = 0
      source2 = 0
      operation = Self.instrJal

    default:
      guard instr.numberOfParameters >= 2, instr.numberOfParameters <= 3 else {
        instr.setError(instr.instruction, .rv32imAssemblerExpectedTwoOrThreeArguments)
        errors = true
        break
      }
      guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1) else {
        errors = true
        break
      }
      if param1.count != 1 || param1[0].type != AssemblerToken.register {
        instr.setError(param1[0], .assemblerExpectedRegister)
        errors = true
        break
      }
      destination = Rv32imRegisterNames.index(of: param1[0].value)
      if destination < 0 || destination > 31 {
        instr.setError(param1[0], .assemblerUnknownRegister)
        errors = true
        break
      }
      if param2.count != 1 || param2[0].type != AssemblerToken.register {
        instr.setError(param2[0], .assemblerExpectedRegister)
        errors = true
        break
      }
      source1 = Rv32imRegisterNames.index(of: param2[0].value)
      source2 = source1
      if source1 < 0 || source1 > 31 {
        // `param1`, not `param2`: upstream flags the wrong token here. Preserved.
        instr.setError(param1[0], .assemblerUnknownRegister)
        errors = true
        break
      }
      immediate = 0
      if instr.numberOfParameters == 3, let param3 = instr.getParameter(2) {
        if param3.count != 1 || !param3[0].isNumber {
          instr.setError(param3[0], .assemblerExpectedImmediateValue)
          errors = true
          break
        }
        immediate = param3[0].getNumberValue()
      }
      if operation != Self.instrJalr {
        source1 = destination
        destination = 0
      }
    }

    if !errors {
      let lastParameter = instr.getParameter(instr.numberOfParameters - 1)?.first
      switch operation {
      case Self.instrJal:
        var imm = Int64(immediate)
        imm -= instr.getProgramCounter()
        immediate = Int(Int32(truncatingIfNeeded: imm))
        if immediate >= (1 << 19) || immediate < -(1 << 19) {
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          errors = true
          break
        }
        instruction = Rv32imBits.jTypeInstruction(
          opcode: Self.jal, rd: destination, imm: immediate)
      case Self.instrJalr:
        if immediate >= (1 << 10) || immediate < -(1 << 10) {
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          errors = true
          break
        }
        instruction = Rv32imBits.iTypeInstruction(
          opcode: Self.jalr, rd: destination, funct3: 0, rs1: source1, imm: immediate)
      case Self.instrBeq, Self.instrBne, Self.instrBlt, Self.instrBge, Self.instrBltu,
        Self.instrBgeu:
        var imm = Int64(immediate)
        imm -= instr.getProgramCounter()
        immediate = Int(Int32(truncatingIfNeeded: imm))
        if immediate >= (1 << 11) || immediate < -(1 << 11) {
          if let token = lastParameter { instr.setError(token, .assemblerImmediateOutOfRange) }
          errors = true
          break
        }
        instruction = Rv32imBits.bTypeInstruction(
          opcode: Self.branch, funct3: operation, rs1: source1, rs2: source2, imm: immediate)
      default:
        // Java pops an `OptionPane` reading "Severe bug in
        // RV32imControlTransferInstructions.java" here. D9/D17: the dialog is dropped and the
        // instruction is simply marked invalid, which is the same observable outcome for the
        // assembled bytes.
        errors = true
      }
    }

    isValid = !errors
    if isValid { instr.setInstructionByteCode(instruction, nrOfBytes: 4) }
    return true
  }
}
