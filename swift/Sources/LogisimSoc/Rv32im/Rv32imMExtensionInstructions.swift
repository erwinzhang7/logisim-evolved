/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32im_M_ExtensionInstructions.java (4.1.0):
 * MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU. Decode/execute/disassemble only;
 * Decode, execute, disassemble and assemble.
 *
 * THIS IS THE HIGH-RISK FILE (see the task brief: "MUL/MULH/MULHSU/MULHU differ only in
 * signedness of the operands and which half is kept, and are the classic place a port
 * silently breaks"). Every case below is commented with exactly which operand(s) are read as
 * signed vs. unsigned, which 32-bit half of the product is kept, and why the arithmetic is
 * safe in `Int`/`UInt64` without an `Int128` (the concern D15 raises for the *arbitrary-width*
 * Multiplier/Divider components does not apply to a fixed 32-bit multiply, but the margin is
 * checked explicitly below rather than assumed).
 */

import LogisimKernel

/// Java: `BigInteger.divide`/`remainder` throwing `ArithmeticException: BigInteger divide by
/// zero`, uncaught anywhere in the call chain (`execute` has no try/catch, nor does
/// `RV32imState.execute()`, nor `Rv32imRiscV.propagate()`) until the `Simulator`'s top-level
/// `catch (Exception err)` (D13). This is the ONE place in the entire rv32im slice where the
/// Java genuinely crashes to a circuit-level error rather than soft-failing: DIV/DIVU/REM/
/// REMU by a zero divisor.
///
/// RISC-V's own ISA spec defines a divide-by-zero result (all-ones quotient, dividend as the
/// remainder) precisely so software never has to guard against it; this Java implementation
/// does not follow the spec here. Per "preserve upstream behaviour even where it looks wrong"
/// (objectives.md) this port does not either: a divide-by-zero in a running RV32IM program is
/// a genuine, simulation-halting `throw` here, matching the Java crash, not the ISA's defined
/// result. This is the one instruction in this whole slice that is `throws` in practice;
/// every other `Rv32imExecutionUnit.execute` implementation never throws, only returns
/// `false`, exactly mirroring which Java paths are soft-fails vs. genuine uncaught exceptions.
public struct Rv32imDivideByZeroError: Error {
  public let mnemonic: String
}

public final class Rv32imMExtensionInstructions: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let op = 0x33

  private static let instrMul = 0
  private static let instrMulh = 1
  private static let instrMulhsu = 2
  private static let instrMulhu = 3
  private static let instrDiv = 4
  private static let instrDivu = 5
  private static let instrRem = 6
  private static let instrRemu = 7

  private static let asmOpcodes = ["MUL", "MULH", "MULHSU", "MULHU", "DIV", "DIVU", "REM", "REMU"]

  private var instruction = 0
  public private(set) var isValid = false
  private var operation = 0
  private var destination = 0
  private var source1 = 0
  private var source2 = 0

  public var instructions: [String] { Self.asmOpcodes }
  public var binaryInstruction: Int { instruction }
  public var performedJump: Bool { false }
  public var errorMessage: String? { nil }

  @discardableResult
  public func decode(_ word: Int) -> Bool {
    instruction = word
    isValid = decodeBin()
    return isValid
  }

  public func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool {
    guard isValid else { return false }
    let val1 = state.registerValue(source1)
    let val2 = state.registerValue(source2)
    var result = 0

    switch operation {
    case Self.instrMul, Self.instrMulh:
      // Both operands SIGNED. `val1`/`val2` are each within ±2^31, so their product's
      // magnitude is at most 2^62: well inside `Int64` (max ≈4.6e18 vs. 2^62 ≈4.6e18,
      // exactly at the boundary for the extreme `Int32.min * Int32.min` case, which equals
      // 2^62 and IS representable, `Int64.max` being 2^63-1). `&*` is used defensively even
      // though this specific product cannot overflow, matching this file's general
      // "assume nothing, wrap explicitly" discipline.
      let product = val1 &* val2
      // MUL keeps the low 32 bits (Java: `res.and(mask)`); MULH keeps bits 63:32 of the full
      // signed product (Java: `res.shiftRight(32).and(mask)`; BigInteger's shiftRight on a
      // negative value is arithmetic/sign-extending, which Swift's `>>` on `Int` already is).
      result = (operation == Self.instrMul) ? wrap32(product) : wrap32(product >> 32)
    case Self.instrMulhsu:
      // rs1 SIGNED, rs2 UNSIGNED (this is what distinguishes MULHSU from MULH/MULHU; the
      // one place a signedness mix-up is easiest to miss). Magnitude check: `val1` down to
      // -2^31, `opp2` up to 2^32-1, product down to -(2^31)*(2^32-1) = -(2^63-2^31), which is
      // greater (less negative) than `Int64.min` = -2^63: fits with margin, verified by hand
      // rather than assumed.
      let opp2 = Rv32imBits.unsignedMagnitude(val2)
      let product = val1 &* opp2
      result = wrap32(product >> 32)
    case Self.instrMulhu:
      // Both operands UNSIGNED. This is the one case in this file that does NOT fit in a
      // signed `Int64`: the product of two full-range unsigned 32-bit magnitudes reaches
      // (2^32-1)^2 = 18446744065119617025, which exceeds `Int64.max` (9223372036854775807)
      // by roughly a factor of two; an `Int`-typed product here would silently overflow-trap
      // on large operands. `UInt64` holds it (`UInt64.max` = 18446744073709551615 > the
      // product's maximum), which is why this one case routes through `UInt64` instead of the
      // `Int`-everywhere convention the rest of this slice uses.
      let u1 = Rv32imBits.unsignedMagnitude64(val1)
      let u2 = Rv32imBits.unsignedMagnitude64(val2)
      let product = u1 &* u2
      result = wrap32(Int(product >> 32))
    case Self.instrDiv, Self.instrRem:
      // Both operands SIGNED, truncating division (Swift's `/`/`%` on `Int` already truncate
      // toward zero and take the dividend's sign for `%`, exactly matching Java's
      // `BigInteger.divide`/`remainder` here, no special-casing needed for
      // `Int32.min / -1`: computed in the wide `Int` container, the quotient is `2^31`
      // (representable, unlike in a genuine 32-bit ALU), and `wrap32` truncating it back to
      // 32 bits reproduces the exact bit pattern the Java's `BigInteger.and(mask).intValue()`
      // produces, which happens to coincide with the RISC-V spec's defined overflow result
      // (`rd = dividend`) even though that coincidence, not spec compliance, is why it works).
      guard val2 != 0 else { throw Rv32imDivideByZeroError(mnemonic: Self.asmOpcodes[operation]) }
      result = wrap32(operation == Self.instrRem ? val1 % val2 : val1 / val2)
    case Self.instrDivu, Self.instrRemu:
      // Both operands UNSIGNED; both are non-negative once read via `unsignedMagnitude`, so
      // Swift's ordinary `/`/`%` on `Int` already compute the unsigned result directly, no
      // reinterpretation needed afterward beyond the usual defensive `wrap32`.
      let opp1 = Rv32imBits.unsignedMagnitude(val1)
      let opp2 = Rv32imBits.unsignedMagnitude(val2)
      guard opp2 != 0 else { throw Rv32imDivideByZeroError(mnemonic: Self.asmOpcodes[operation]) }
      result = wrap32(operation == Self.instrRemu ? opp1 % opp2 : opp1 / opp2)
    default:
      return false
    }

    state.writeRegister(destination, result)
    return true
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    var s = Self.asmOpcodes[operation].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    s += "\(Rv32imRegisterNames.abi[destination]),\(Rv32imRegisterNames.abi[source1]),\(Rv32imRegisterNames.abi[source2])"
    return s
  }

  private func decodeBin() -> Bool {
    guard Rv32imBits.opcode(instruction) == Self.op else { return false }
    guard Rv32imBits.funct7(instruction) == 1 else { return false }
    operation = Rv32imBits.funct3(instruction)
    destination = Rv32imBits.destinationRegisterIndex(instruction)
    source1 = Rv32imBits.sourceRegister1Index(instruction)
    source2 = Rv32imBits.sourceRegister2Index(instruction)
    return true
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`. The plainest of the eight: three registers,
  /// `funct3 = operation` (the `AsmOpcodes` order IS the funct3 order), and `funct7 = 1`, which
  /// is what marks the whole M extension.
  ///
  /// Note `valid = true` is assigned before the opcode lookup and then overwritten: upstream's
  /// line order, harmless, kept so the two read alike.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    isValid = true
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }
    guard instr.numberOfParameters == 3 else {
      instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
      isValid = false
      return true
    }
    guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1),
      let param3 = instr.getParameter(2)
    else {
      isValid = false
      return true
    }

    var errors = false
    if param1.count != 1 || param1[0].type != AssemblerToken.register {
      instr.setError(param1[0], .assemblerExpectedRegister)
      errors = true
    }
    if param2.count != 1 || param2[0].type != AssemblerToken.register {
      instr.setError(param2[0], .assemblerExpectedRegister)
      errors = true
    }
    if param3.count != 1 || param3[0].type != AssemblerToken.register {
      instr.setError(param3[0], .assemblerExpectedRegister)
      errors = true
    }
    destination = Rv32imRegisterNames.index(of: param1[0].value)
    if destination < 0 || destination > 31 {
      instr.setError(param1[0], .assemblerUnknownRegister)
      errors = true
    }
    source1 = Rv32imRegisterNames.index(of: param2[0].value)
    if source1 < 0 || source1 > 31 {
      instr.setError(param2[0], .assemblerUnknownRegister)
      errors = true
    }
    source2 = Rv32imRegisterNames.index(of: param3[0].value)
    if source2 < 0 || source2 > 31 {
      instr.setError(param3[0], .assemblerUnknownRegister)
      errors = true
    }

    isValid = !errors
    if isValid {
      instruction = Rv32imBits.rTypeInstruction(
        opcode: Self.op, rd: destination, funct3: operation, rs1: source1, rs2: source2,
        funct7: 1)
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }
}
