/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imLoadAndStoreInstructions.java (4.1.0): LB/LH/LW/LBU/LHU/SB/SH/SW.
 * Decode, execute, disassemble and assemble.
 *
 * Bus errors here are Java's one SOFT failure path (`trans.hasError()` inspected, never
 * thrown): see `Rv32imBus.swift`'s doc comment on `Rv32imBusError` for why a thrown
 * `Rv32imBusError` from the bus implementation is caught here and folded back into
 * `execute() -> false` + `errorMessage`, not rethrown.
 *
 * Message text below is placeholder English, not the localized `S.get(...)` string table
 * (`soc/Strings.properties`; a resources/i18n concern outside this slice). Numeric fidelity
 * does not depend on the exact wording; flagged as a seam for whoever ports the SoC string
 * resources.
 */

import LogisimKernel

public final class Rv32imLoadAndStoreInstructions: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let load = 0x3
  private static let store = 0x23
  private static let lb = 0
  private static let lh = 1
  private static let lw = 2
  private static let lbu = 4
  private static let lhu = 5

  private static let instrLb = 0
  private static let instrLh = 1
  private static let instrLw = 2
  private static let instrLbu = 3
  private static let instrLhu = 4
  private static let instrSb = 5
  private static let instrSh = 6
  private static let instrSw = 7

  private static let asmOpcodes = ["LB", "LH", "LW", "LBU", "LHU", "SB", "SH", "SW"]

  private var instruction = 0
  public private(set) var isValid = false
  private var operation = 0
  private var destination = 0
  private var immediate = 0
  private var base = 0
  public private(set) var errorMessage: String?

  public var instructions: [String] { Self.asmOpcodes }
  public var binaryInstruction: Int { instruction }
  public var performedJump: Bool { false }

  @discardableResult
  public func decode(_ word: Int) -> Bool {
    instruction = word
    isValid = decodeBin()
    return isValid
  }

  public func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool {
    if !isValid { return false }
    errorMessage = nil
    let toBeStoredRaw = state.registerValue(destination)
    // Java: `long address = ElfHeader.getLongValue(base) + immediate`: an unsigned 32-bit
    // base plus a signed immediate, computed wide so it cannot itself wrap before being
    // truncated back to a 32-bit address below (`ElfHeader.getIntValue(address)`); `Int` here
    // is already 64-bit so the intermediate sum needs no special widening.
    let address = Rv32imBits.unsignedMagnitude(state.registerValue(base)) &+ immediate
    let effectiveAddress = wrap32(address)

    switch operation {
    case Self.instrSb, Self.instrSh, Self.instrSw:
      var toBeStored = toBeStoredRaw
      let size: Rv32imAccessSize
      switch operation {
      case Self.instrSb: toBeStored &= 0xFF; size = .byte
      case Self.instrSh: toBeStored &= 0xFFFF; size = .halfWord
      default: size = .word
      }
      do {
        try bus.write(toBeStored, at: effectiveAddress, size: size)
        return true
      } catch let error as Rv32imBusError {
        errorMessage = "Error in write transaction\n\(error.message)"
        return false
      }
    case Self.instrLb, Self.instrLbu, Self.instrLh, Self.instrLhu, Self.instrLw:
      let size: Rv32imAccessSize
      switch operation {
      case Self.instrLb, Self.instrLbu: size = .byte
      case Self.instrLh, Self.instrLhu: size = .halfWord
      default: size = .word
      }
      let raw: Int
      do {
        raw = try bus.read(at: effectiveAddress, size: size)
      } catch let error as Rv32imBusError {
        errorMessage = "Error in read transaction\n\(error.message)"
        return false
      }
      var toBeLoaded = raw
      switch operation {
      case Self.instrLbu:
        toBeLoaded &= 0xFF
      case Self.instrLb:
        // Java: `toBeLoaded <<= 24; toBeLoaded >>= 24;` on a 32-bit `int`; the left shift
        // itself is what pushes the byte's sign bit into bit 31, and the arithmetic right
        // shift then sign-extends from there. Ported as two Swift `Int` (64-bit) shifts, this
        // is exactly the "forgot to re-wrap between two shifts" trap: with `toBeLoaded` a
        // plain non-negative byte value (0…255), `toBeLoaded << 24` on a 64-bit `Int` is
        // still a small POSITIVE 64-bit number (max ≈4.28e9, nowhere near overflowing 64
        // bits) with no sign information yet; Java gets the sign bit for free from 32-bit
        // truncation at the shift itself, Swift does not. `wrap32` must run BETWEEN the two
        // shifts, not after both, or a byte with its high bit set (e.g. 0xFF, which must
        // sign-extend to -1) silently loads as a positive value instead.
        toBeLoaded = wrap32(toBeLoaded << 24) >> 24
      case Self.instrLhu:
        toBeLoaded &= 0xFFFF
      case Self.instrLh:
        // Same trap, half-word width: see the LB case above.
        toBeLoaded = wrap32(toBeLoaded << 16) >> 16
      default:
        break
      }
      state.writeRegister(destination, wrap32(toBeLoaded))
      return true
    default:
      return false
    }
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    var s = Self.asmOpcodes[operation].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    s += "\(Rv32imRegisterNames.abi[destination]),\(immediate)(\(Rv32imRegisterNames.abi[base]))"
    return s
  }

  private func decodeBin() -> Bool {
    let opcode = Rv32imBits.opcode(instruction)
    if opcode == Self.load {
      destination = Rv32imBits.destinationRegisterIndex(instruction)
      immediate = Rv32imBits.immediate(instruction, type: .iType)
      base = Rv32imBits.sourceRegister1Index(instruction)
      let funct3 = Rv32imBits.funct3(instruction)
      switch funct3 {
      case Self.lb, Self.lh, Self.lw:
        operation = funct3
        return true
      case Self.lbu, Self.lhu:
        operation = funct3 - 1
        return true
      default:
        return false
      }
    }
    if opcode == Self.store {
      let funct3 = Rv32imBits.funct3(instruction)
      if funct3 > 2 { return false }
      operation = funct3 + 5
      immediate = Rv32imBits.immediate(instruction, type: .sType)
      base = Rv32imBits.sourceRegister1Index(instruction)
      destination = Rv32imBits.sourceRegister2Index(instruction)
      return true
    }
    return false
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`.
  ///
  /// The second parameter is the `imm(reg)` form, which reaches here as **two** tokens, a
  /// number and a `BRACKETED_REGISTER`, because `Assembler`'s fourth pass folds `4`, `(`, `sp`,
  /// `)` into that pair before `setAsmInstruction` sees it. A `param2.count != 2` is therefore
  /// the "you did not write `imm(reg)`" error, and it is the ONE check here that returns
  /// immediately rather than accumulating.
  ///
  /// This unit tracks failure in `valid` directly rather than a local `errors` flag, and it
  /// checks `if (!valid) return true;` at two points mid-way. Both are upstream's shape and are
  /// kept, because the second gate is what stops `getNumberValue()` running on a token that was
  /// already rejected as a non-number.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }
    guard instr.numberOfParameters == 2 else {
      instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
      isValid = false
      return true
    }

    isValid = true
    guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1) else {
      isValid = false
      return true
    }
    if param1.count != 1 || param1[0].type != AssemblerToken.register {
      instr.setError(param1[0], .assemblerExpectedRegister)
      isValid = false
    }
    guard param2.count == 2 else {
      instr.setError(param2[0], .rv32imAssemblerExpectedImmediateIndexedRegister)
      isValid = false
      return true
    }
    if !param2[0].isNumber {
      instr.setError(param2[0], .assemblerExpectedImmediateValue)
      isValid = false
    }
    if param2[1].type != AssemblerToken.bracketedRegister {
      instr.setError(param2[1], .rv32imAssemblerExpectedBracketedRegister)
      isValid = false
    }
    if !isValid { return true }

    destination = Rv32imRegisterNames.index(of: param1[0].value)
    if destination < 0 || destination > 31 {
      instr.setError(param1[0], .assemblerUnknownRegister)
      isValid = false
    }
    base = Rv32imRegisterNames.index(of: param2[1].value)
    if base < 0 || base > 31 {
      instr.setError(param2[1], .assemblerUnknownRegister)
      isValid = false
    }
    immediate = param2[0].getNumberValue()
    if immediate >= (1 << 11) || immediate < -(1 << 11) {
      instr.setError(param2[0], .assemblerImmediateOutOfRange)
      isValid = false
    }
    if !isValid { return true }

    switch operation {
    case Self.instrSb, Self.instrSh, Self.instrSw:
      let funct3 = operation - Self.instrSb
      instruction = Rv32imBits.sTypeInstruction(
        opcode: Self.store, rs1: base, rs2: destination, funct3: funct3, imm: immediate)
    case Self.instrLb, Self.instrLbu, Self.instrLh, Self.instrLhu, Self.instrLw:
      // LBU/LHU are `operation + 1` because `AsmOpcodes` orders them LB,LH,LW,LBU,LHU while the
      // funct3 encoding is LB=0,LH=1,LW=2,LBU=4,LHU=5: the +1 closes the gap at 3.
      let funct3 =
        (operation == Self.instrLbu || operation == Self.instrLhu) ? operation + 1 : operation
      instruction = Rv32imBits.iTypeInstruction(
        opcode: Self.load, rd: destination, funct3: funct3, rs1: base, imm: immediate)
    default:
      // Java pops "Severe Bug in RV32imLoadAndStoreInstructions.java" (D9/D17: dropped).
      isValid = false
    }

    if isValid { instr.setInstructionByteCode(instruction, nrOfBytes: 4) }
    return true
  }
}
