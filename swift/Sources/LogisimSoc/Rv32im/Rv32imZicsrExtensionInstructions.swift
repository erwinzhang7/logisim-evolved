/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32im_Zicsr_ExtensionInstructions.java (4.1.0);
 * CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI. Decode/execute/disassemble only; `setAsmInstruction`
 * is ported (it is unusually large in the Java
 * (builds the raw instruction word field-by-field from either a named SPR/register token or a
 * raw immediate, for the 2-argument `CSRW`-family and 3-argument `CSRRW`-family syntaxes) and
 * depends entirely on `AssemblerToken`/`AssemblerAsmInstruction` (soc/util, outside this
 * slice).
 *
 * `sprIndex` throughout the Java (and mirrored here) is a raw 12-bit CSR *address*
 * (`(instruction >> 20) & 0xFFF`), not an index into `Rv32imCsr.implementedAddresses`: see
 * `Rv32imCsr.arrayIndex(ofAddress:)`'s note on the same naming quirk in the Java it mirrors.
 */

import Foundation
import LogisimKernel

public final class Rv32imZicsrExtensionInstructions: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let op = 0x73

  private static let instrCsrrw = 0
  private static let instrCsrrs = 1
  private static let instrCsrrc = 2
  private static let instrCsrrwi = 3
  private static let instrCsrrsi = 4
  private static let instrCsrrci = 5

  private static let asmOpcodes = [
    "CSRRW", "CSRRS", "CSRRC", "CSRRWI", "CSRRSI", "CSRRCI",
    "CSRW", "CSRS", "CSRC", "CSRWI", "CSRSI", "CSRCI",
  ]

  private var instruction = 0
  public private(set) var isValid = false
  private var operation = 0
  private var destination = 0
  private var source = 0
  private var sprAddress = 0

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
    // Java: computes `val = cpuState.getRegisterValue(source)` unconditionally at the top of
    // `execute`, but the CSRRWI/CSRRSI/CSRRCI branches never read `val`: they use `source`
    // directly, since for those three the `rs1` field (decoded into `source` below, exactly
    // like a register index) IS a 5-bit unsigned immediate operand, not a register to read.
    // `getRegisterValue` is a pure lookup with no side effects, so computing it only when it
    // is actually used (the non-*I branches) is behaviorally identical to Java's unconditional
    // computation, just without the wasted call on the *I path.
    let val = (operation == Self.instrCsrrwi || operation == Self.instrCsrrsi
      || operation == Self.instrCsrrci) ? source : state.registerValue(source)

    guard Rv32imCsr.isImplemented(address: sprAddress) else { return false }

    switch operation {
    case Self.instrCsrrw:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      state.writeCsr(sprAddress, val)
    case Self.instrCsrrs:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      let csrContents = state.csrValue(sprAddress)
      state.writeCsr(sprAddress, val | csrContents)
    case Self.instrCsrrc:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      let csrContents = state.csrValue(sprAddress)
      // Java: `val ^ 0xffffffff`: since `0xffffffff` as a Java `int` literal is -1, this is
      // exactly `~val`, a full bitwise complement, NOT "XOR with the low-32-bits mask 0xFFFFFFFF".
      // The distinction matters here specifically because `val` may already be a canonical
      // (sign-extended) negative `Int`: XOR-ing only its low 32 bits against 0xFFFFFFFF would
      // leave the high sign-extension bits untouched and produce a value that no longer reads
      // as the correctly sign-extended complement once AND-ed against `csrContents` (which
      // IS canonical): silently corrupting the upper half of the result. `~val` flips every
      // bit of the full 64-bit container, which stays canonical because `val` started
      // canonical (a sign-extended value's complement is itself sign-extended, just to the
      // opposite polarity).
      let mask = ~val
      state.writeCsr(sprAddress, mask & csrContents)
    case Self.instrCsrrwi:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      state.writeCsr(sprAddress, source)
    case Self.instrCsrrsi:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      let csrContents = state.csrValue(sprAddress)
      state.writeCsr(sprAddress, source | csrContents)
    case Self.instrCsrrci:
      if destination != 0 { state.writeRegister(destination, state.csrValue(sprAddress)) }
      let csrContents = state.csrValue(sprAddress)
      // Java: `source ^ 0xffffffff`; same `~source` note as CSRRC above. `source` here is a
      // small non-negative 5-bit immediate, so the distinction is less likely to bite in
      // practice than in the CSRRC case, but the same `~` is used for consistency and because
      // relying on "the operand happens to be small" is exactly the kind of assumption this
      // slice is trying not to make silently.
      let mask = ~source
      state.writeCsr(sprAddress, mask & csrContents)
    default:
      return true
    }
    return true
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    let realOp = (destination == 0) ? operation + 6 : operation
    var s = Self.asmOpcodes[realOp].lowercased()
    while s.count < Rv32imBits.asmFieldSize { s += " " }
    if destination != 0 { s += "\(Rv32imRegisterNames.abi[destination])," }
    let operand = (operation < Self.instrCsrrwi)
      ? Rv32imRegisterNames.abi[source]
      : String(format: "0x%02X", source)
    s += "\(Rv32imCsr.name(ofAddress: sprAddress)),\(operand)"
    return s
  }

  private func decodeBin() -> Bool {
    guard Rv32imBits.opcode(instruction) == Self.op else { return false }
    switch Rv32imBits.funct3(instruction) {
    case 1: operation = 0
    case 2: operation = 1
    case 3: operation = 2
    case 5: operation = 3
    case 6: operation = 4
    case 7: operation = 5
    default: return false
    }
    sprAddress = (instruction >> 20) & 0xFFF
    destination = Rv32imBits.destinationRegisterIndex(instruction)
    source = Rv32imBits.sourceRegister1Index(instruction)
    return true
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`.
  ///
  /// The odd one out, in three ways, all upstream's:
  ///
  ///  1. It branches on the **parameter count** first, not on the operation, and each branch
  ///     rejects the operations that do not belong to it: two parameters means one of the six
  ///     `CSRW`-family pseudo-ops (`operation >= 6`, then `operation -= 6` and `destination = 0`),
  ///     three means one of the six real ones (`operation <= 5`).
  ///  2. It builds `instruction` by OR-ing fields directly instead of calling one of the
  ///     `getXTypeInstruction` helpers, so the funct3 nudge `(operation < 3) ? operation + 1 :
  ///     operation + 2` is written into bits 12-14 by hand. The gap at funct3 == 3 is why: the
  ///     CSR funct3 encoding is CSRRW=1, CSRRS=2, CSRRC=3, CSRRWI=5, CSRRSI=6, CSRRCI=7.
  ///  3. It returns **`false`** on every error, not `true`; every other unit returns `true`
  ///     ("this opcode is mine, and it was malformed"). Returning `false` makes
  ///     `AbstractAssembler.assemble`'s `found` stay false if no other unit claims the opcode,
  ///     so a malformed `csrrw` reports BOTH its specific error and `AssemblerUnknownOpcode`.
  ///     Preserved: it is observable in the error list.
  ///
  /// A CSR operand may be a register-looking **name** (`mstatus`), resolved through
  /// `Rv32imCsr.arrayIndex(ofName:)` → `Rv32imCsr.address(atArrayIndex:)`, or a literal number.
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    isValid = true
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }

    /// `instruction |= (csr << 20)` for a CSR operand that may be a name or a number.
    func applyCsrOperand(_ token: AssemblerToken, base: Bool) -> Bool {
      if token.type == AssemblerToken.register {
        let index = Rv32imCsr.arrayIndex(ofName: token.value)
        if index < 0 {
          instr.setError(token, .assemblerExpectedImmediateValue)
          isValid = false
          return false
        }
        if base { instruction = Self.op }
        instruction |= Rv32imCsr.address(atArrayIndex: index) << 20
        return true
      }
      if token.type == AssemblerToken.hexNumber || token.type == AssemblerToken.decNumber {
        if base { instruction = Self.op }
        instruction |= token.getNumberValue() << 20
        return true
      }
      instr.setError(token, .assemblerExpectedImmediateValue)
      isValid = false
      return false
    }

    /// `instruction |= (rs1 << 15)` for a source operand that may be a register or a 5-bit
    /// immediate (the `…I` forms).
    func applySourceOperand(_ token: AssemblerToken) -> Bool {
      if token.type == AssemblerToken.register {
        let index = Rv32imRegisterNames.index(of: token.value)
        if index < 0 {
          instr.setError(token, .assemblerExpectedRegister)
          isValid = false
          return false
        }
        instruction |= index << 15
        return true
      }
      if token.type == AssemblerToken.hexNumber || token.type == AssemblerToken.decNumber {
        let value = token.getNumberValue()
        if value < 0 || value > 31 {
          instr.setError(token, .assemblerExpectedImmediateValue)
          isValid = false
          return false
        }
        instruction |= value << 15
        return true
      }
      instr.setError(token, .assemblerExpectedImmediateValue)
      isValid = false
      return false
    }

    /// The shared tail: bits 12-14, then hand over the four bytes.
    func finish(_ operation: Int) -> Bool {
      instruction |= (operation < 3) ? (operation + 1) << 12 : (operation + 2) << 12
      instruction = wrap32(instruction)
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
      return true
    }

    if instr.numberOfParameters == 2 {
      guard operation >= 6 else {
        instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
        isValid = false
        return false
      }
      operation -= 6
      destination = 0
      guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1) else {
        isValid = false
        return false
      }
      guard param1.count == 1 else {
        instr.setError(param1[0], .assemblerExpectedImmediateValue)
        isValid = false
        return false
      }
      guard applyCsrOperand(param1[0], base: true) else { return false }
      guard param2.count == 1 else {
        instr.setError(param2[0], .assemblerExpectedImmediateValue)
        isValid = false
        return false
      }
      guard applySourceOperand(param2[0]) else { return false }
      return finish(operation)
    }

    if instr.numberOfParameters == 3 {
      guard operation <= 5 else {
        instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
        isValid = false
        return false
      }
      guard let param1 = instr.getParameter(0), let param2 = instr.getParameter(1),
        let param3 = instr.getParameter(2)
      else {
        isValid = false
        return false
      }
      guard param1.count == 1, param1[0].type == AssemblerToken.register else {
        instr.setError(param1[0], .assemblerExpectedRegister)
        isValid = false
        return false
      }
      let reg = Rv32imRegisterNames.index(of: param1[0].value)
      guard reg >= 0 else {
        instr.setError(param1[0], .assemblerExpectedRegister)
        isValid = false
        return false
      }
      instruction = Self.op
      instruction |= reg << 7
      guard param2.count == 1 else {
        instr.setError(param2[0], .assemblerExpectedImmediateValue)
        isValid = false
        return false
      }
      guard applyCsrOperand(param2[0], base: false) else { return false }
      guard param3.count == 1 else {
        instr.setError(param3[0], .assemblerExpectedImmediateValue)
        isValid = false
        return false
      }
      guard applySourceOperand(param3[0]) else { return false }
      return finish(operation)
    }

    // Neither 2 nor 3 parameters: upstream falls off the end and returns false without
    // recording any error at all.
    return false
  }
}
