/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imIntegerRegisterRegisterOperations.java (4.1.0):
 * ADD/SUB/SLL/SLT/SLTU/XOR/SRL/OR/AND/SRA and the pseudo-instruction SNEZ,
 * decode/execute/disassemble AND assemble.
 */

import LogisimKernel

public final class Rv32imIntegerRegisterRegisterOperations: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let op = 0x33
  private static let addSub = 0
  private static let srlSra = 5

  private static let instrAdd = 0
  private static let instrSll = 1
  private static let instrSlt = 2
  private static let instrSltu = 3
  private static let instrXor = 4
  private static let instrSrl = 5
  private static let instrOr = 6
  private static let instrAnd = 7
  private static let instrSub = 8
  private static let instrSra = 9
  private static let instrSnez = 10

  private static let asmOpcodes = ["ADD", "SLL", "SLT", "SLTU", "XOR", "SRL", "OR", "AND", "SUB", "SRA", "SNEZ"]

  private var instruction = 0
  private var destination = 0
  private var source1 = 0
  private var source2 = 0
  private var operation = 0
  public private(set) var isValid = false

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
    if !isValid { return false }
    let opp1 = state.registerValue(source1)
    let opp2 = state.registerValue(source2)
    var result = 0
    switch operation {
    case Self.instrAdd:
      result = wrap32(opp1 &+ opp2)
    case Self.instrSub:
      result = wrap32(opp1 &- opp2)
    case Self.instrSll:
      // Java: `opp2 & 0x1F` masks the shift amount to 5 bits before shifting; required
      // explicitly here (unlike the I-type SLLI, where the shift amount is a decode-time
      // constant already ≤ 31): `opp2` is a full register value that could be e.g. 33 or -1,
      // and an unmasked shift is exactly the "Java masks, Swift traps/zeroes" trap this port
      // must not fall into.
      result = wrap32(opp1 << (opp2 & 0x1F))
    case Self.instrSlt:
      result = (opp1 < opp2) ? 1 : 0
    case Self.instrSnez, Self.instrSltu:
      result = (Rv32imBits.unsignedMagnitude(opp1) < Rv32imBits.unsignedMagnitude(opp2)) ? 1 : 0
    case Self.instrXor:
      result = wrap32(opp1 ^ opp2)
    case Self.instrSrl:
      // Logical (zero-filling) right shift: see the SRLI note in
      // Rv32imIntegerRegisterImmediateInstructions.
      let val1 = Rv32imBits.unsignedMagnitude(opp1) >> (opp2 & 0x1F)
      result = wrap32(val1)
    case Self.instrOr:
      result = wrap32(opp1 | opp2)
    case Self.instrAnd:
      result = wrap32(opp1 & opp2)
    case Self.instrSra:
      // Arithmetic (sign-extending) right shift: `opp1` is canonical, so Swift's `>>` on
      // `Int` matches Java's `>>` on `int` directly once the shift amount is masked.
      result = wrap32(opp1 >> (opp2 & 0x1F))
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
    let middle = (operation == Self.instrSnez) ? "" : "\(Rv32imRegisterNames.abi[source1]),"
    s += "\(Rv32imRegisterNames.abi[destination]),\(middle)\(Rv32imRegisterNames.abi[source2])"
    return s
  }

  private func decodeBin() -> Bool {
    guard Rv32imBits.opcode(instruction) == Self.op else { return false }
    let funct7 = Rv32imBits.funct7(instruction)
    let funct3 = Rv32imBits.funct3(instruction)
    destination = Rv32imBits.destinationRegisterIndex(instruction)
    source1 = Rv32imBits.sourceRegister1Index(instruction)
    source2 = Rv32imBits.sourceRegister2Index(instruction)
    switch funct3 {
    case Self.addSub:
      if funct7 == 0 { operation = Self.instrAdd }
      else if funct7 == 0x20 { operation = Self.instrSub }
      else { return false }
    case Self.srlSra:
      if funct7 == 0 { operation = Self.instrSrl }
      else if funct7 == 0x20 { operation = Self.instrSra }
      else { return false }
    default:
      if funct7 != 0 { return false }
      operation = funct3
    }
    if operation == Self.instrSltu && source1 == 0 { operation = Self.instrSnez }
    return true
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`.
  ///
  /// **This unit's shape checks are deliberately NOT the shared helpers.** Where the immediate
  /// family flags every token in a malformed parameter and `break`s out of the case, this one
  /// flags only `param[0]` and keeps going: so a `sub (x1),x2,x3` reports one error here and
  /// several there, and this one still resolves the remaining registers. That asymmetry is
  /// upstream's (`RV32imIntegerRegisterRegisterOperations.java:216-231`), and routing it through
  /// a shared helper would quietly normalise it away.
  ///
  /// `param3 != param2` in the Java is an **array reference** comparison standing in for "was a
  /// third parameter supplied": SNEZ aliases `param3 = param2`. Modelled as an explicit flag,
  /// since Swift arrays are values and `==` would compare contents.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }

    // Note the message is `AssemblerExpectedThreeArguments` even in the SNEZ (two-parameter)
    // case; upstream uses the one getter for both arities here.
    guard instr.numberOfParameters == (operation == Self.instrSnez ? 2 : 3) else {
      instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
      isValid = false
      return true
    }

    var errors = false
    guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1) else {
      isValid = false
      return true
    }
    let hasThirdParameter = operation != Self.instrSnez
    let param3 = hasThirdParameter ? (instr.getParameter(2) ?? param2) : param2

    if param1.count != 1 || param1[0].type != AssemblerToken.register {
      errors = true
      instr.setError(param1[0], .assemblerExpectedRegister)
    }
    if param2.count != 1 || param2[0].type != AssemblerToken.register {
      errors = true
      instr.setError(param2[0], .assemblerExpectedRegister)
    }
    if hasThirdParameter && (param3.count != 1 || param3[0].type != AssemblerToken.register) {
      errors = true
      instr.setError(param3[0], .assemblerExpectedRegister)
    }

    destination = Rv32imRegisterNames.index(of: param1[0].value)
    source1 = Rv32imRegisterNames.index(of: param2[0].value)
    source2 = Rv32imRegisterNames.index(of: param3[0].value)
    if destination < 0 || destination > 31 {
      errors = true
      instr.setError(param1[0], .assemblerUnknownRegister)
    }
    if source1 < 0 || source1 > 31 {
      errors = true
      instr.setError(param2[0], .assemblerUnknownRegister)
    }
    if hasThirdParameter && (source2 < 0 || source2 > 31) {
      errors = true
      instr.setError(param3[0], .assemblerUnknownRegister)
    }

    // SNEZ rd,rs -> SLTU rd,x0,rs: `source2` is already the operand (param3 aliases param2).
    if operation == Self.instrSnez {
      source1 = 0
      operation = Self.instrSltu
    }

    isValid = !errors
    if isValid {
      let funct7 = (operation == Self.instrSub || operation == Self.instrSra) ? 0x20 : 0
      let funct3 =
        operation == Self.instrSub
        ? Self.addSub : (operation == Self.instrSra ? Self.srlSra : operation)
      instruction = Rv32imBits.rTypeInstruction(
        opcode: Self.op, rd: destination, funct3: funct3, rs1: source1, rs2: source2,
        funct7: funct7)
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }
}
