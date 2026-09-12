// Nios2DataTransferInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2DataTransferInstructions),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Loads/stores. `SocBusTransaction` (Data, not owned by this module) carries the actual
// request; this file only computes the address (`SocSupport.convUnsignedInt` widen so a
// top-bit-set base register still adds as a large unsigned value, matching every other
// address computation in this subsystem) and the byte/half-word sign/zero-extension of loaded
// data.
//
// Numeric-fidelity notes:
//   * `toBeLoaded <<= 24; toBeLoaded >>= 24;` (LDB) and the analogous `<<16;>>16` (LDH) rely on
//     Java `int`'s free 32-bit wraparound on the left shift to produce sign extension via the
//     following arithmetic right shift. Since `toBeLoaded` here is a plain `Int` (not `Int32`),
//     the left shift is `wrap32`'d first so the subsequent arithmetic `>>` sees the same bit
//     pattern Java's native `int` would.
//   * `setBinInstruction`'s manual sign-extension (`if (((immediate >> 15) & 1) != 0) immediate
//     |= 0xFFFF0000;`) is reproduced as-is; `immediate` starts as the non-negative 16-bit field
//     `Nios2Support.getImmediate` returns, so the OR with `0xFFFF0000` needs no `wrap32` of its
//     own; the result is already within `Int32` range (top 16 bits are all 1s, bottom 16 are
//     the field), and is used as a plain sign-extended `Int` from here on exactly like every
//     other decoded immediate in this module.
import LogisimFile
import LogisimKernel

public final class Nios2DataTransferInstructions: AssemblerExecutionInterface {
  private static let instrLdw = 0
  private static let instrLdh = 1
  private static let instrLdhu = 2
  private static let instrLdb = 3
  private static let instrLdbu = 4
  private static let instrLdwio = 5
  private static let instrLdhio = 6
  private static let instrLdhuio = 7
  private static let instrLdbio = 8
  private static let instrLdbuio = 9
  private static let instrStw = 10
  private static let instrSth = 11
  private static let instrStb = 12
  private static let instrStwio = 13
  private static let instrSthio = 14
  private static let instrStbio = 15

  private static let asmOpcodes: [String] = [
    "LDW", "LDH", "LDHU", "LDB", "LDBU",
    "LDWIO", "LDHIO", "LDHUIO", "LDBIO", "LDBUIO",
    "STW", "STH", "STB",
    "STWIO", "STHIO", "STBIO",
  ]
  private static let asmOpcs: [Int] = [
    0x17, 0x0F, 0x0B, 0x07, 0x03,
    0x37, 0x2F, 0x2B, 0x27, 0x23,
    0x15, 0x0D, 0x05,
    0x35, 0x2D, 0x25,
  ]

  private let opcodes: [String]
  private let opcCodes: [Int]

  private var instruction = 0
  private var valid = false
  private var operation = 0
  private var destination = 0
  private var immediate = 0
  private var base = 0
  private var errorMessage: String?

  public init() {
    opcodes = Self.asmOpcodes.map { $0.lowercased() }
    opcCodes = Self.asmOpcs
  }

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    guard valid, let state = processorState as? Nios2ProcessorState else { return false }
    let address = SocSupport.convUnsignedInt(state.getRegisterValue(base)) + Int64(immediate)
    errorMessage = nil
    var toBeStored = state.getRegisterValue(destination)
    var transType: SocAccessType?
    switch operation {
    case Self.instrStbio, Self.instrStb:
      toBeStored &= 0xFF
      transType = .byte
      fallthrough
    case Self.instrSthio, Self.instrSth:
      toBeStored &= 0xFFFF
      if transType == nil { transType = .halfWord }
      fallthrough
    case Self.instrStwio, Self.instrStw:
      if transType == nil { transType = .word }
      let trans = SocBusTransaction(
        kind: .write, address: SocSupport.convUnsignedLong(address), writeData: Int32(truncatingIfNeeded: toBeStored),
        accessType: transType!, initiator: initiator(state))
      state.insertTransaction(trans, hidden: false, circuitState: circuitState)
      return !transactionHasError(trans)
    case Self.instrLdb, Self.instrLdbio, Self.instrLdbu, Self.instrLdbuio:
      transType = .byte
      fallthrough
    case Self.instrLdh, Self.instrLdhio, Self.instrLdhu, Self.instrLdhuio:
      if transType == nil { transType = .halfWord }
      fallthrough
    case Self.instrLdw, Self.instrLdwio:
      if transType == nil { transType = .word }
      let trans = SocBusTransaction(
        kind: .read, address: SocSupport.convUnsignedLong(address), writeData: 0,
        accessType: transType!, initiator: initiator(state))
      state.insertTransaction(trans, hidden: false, circuitState: circuitState)
      if transactionHasError(trans) { return false }
      var toBeLoaded = Int(trans.readData)
      switch operation {
      case Self.instrLdbu, Self.instrLdbuio:
        toBeLoaded &= 0xFF
      case Self.instrLdb, Self.instrLdbio:
        toBeLoaded = wrap32(toBeLoaded << 24)
        toBeLoaded >>= 24
      case Self.instrLdhu, Self.instrLdhuio:
        toBeLoaded &= 0xFFFF
      case Self.instrLdh, Self.instrLdhio:
        toBeLoaded = wrap32(toBeLoaded << 16)
        toBeLoaded >>= 16
      default:
        break
      }
      state.writeRegister(destination, toBeLoaded)
      return true
    default:
      return false
    }
  }

  private func initiator(_ state: Nios2ProcessorState) -> SocTransactionInitiator {
    if let comp = state.masterComponent { return .component(comp) }
    return .named(state.config.name.isEmpty ? "Nios2s" : state.config.name)
  }

  /// English text matches `soc.properties`' `LoadStoreErrorInReadTransaction`/
  /// `LoadStoreErrorInWriteTransaction` verbatim (D5/D9: non-localised here, see
  /// `SocTransactionError.description`'s header note; the UI owns the localised table).
  private func transactionHasError(_ trans: SocBusTransaction) -> Bool {
    if trans.hasError {
      let prefix =
        trans.isReadTransaction
        ? "Error performing a load from memory system:" : "Error performing a store to the memory system:"
      errorMessage = "\(prefix)\n\(trans.error.description)"
    }
    return trans.hasError
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    s += "\(Nios2ProcessorState.registerABINames[destination]),\(immediate)(\(Nios2ProcessorState.registerABINames[base]))"
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    valid = false
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    valid = true
    guard instr.numberOfParameters == 2 else {
      valid = false
      instr.setError(instr.instruction, .assemblerExpectedTwoArguments)
      return true
    }
    guard let param2 = instr.getParameter(1) else { valid = false; return true }
    valid = Nios2Support.isCorrectRegister(instr, 0) && valid
    destination = Nios2Support.getRegisterIndex(instr, 0)
    if param2.count != 2 {
      valid = false
      if let t = param2.first { instr.setError(t, .nios2AssemblerExpectedImmediateIndexedRegister) }
    }
    guard valid else { return true }
    if !param2[0].isNumber {
      valid = false
      instr.setError(param2[0], .assemblerExpectedImmediateValue)
    }
    if param2[1].type != AssemblerToken.bracketedRegister {
      valid = false
      instr.setError(param2[1], .nios2AssemblerExpectedBracketedRegister)
    }
    guard valid else { return true }
    if Nios2ProcessorState.isCustomRegister(param2[1].value) {
      valid = false
      instr.setError(param2[1], .nios2CannotUseCustomRegister)
    }
    if Nios2ProcessorState.isControlRegister(param2[1].value) {
      valid = false
      instr.setError(param2[1], .nios2CannotUseControlRegister)
    }
    base = Nios2ProcessorState.getRegisterIndex(param2[1].value)
    if base < 0 || base > 31 {
      valid = false
      instr.setError(param2[1], .assemblerUnknownRegister)
    }
    immediate = param2[0].getNumberValue()
    if immediate >= (1 << 15) || immediate < -(1 << 15) {
      valid = false
      instr.setError(param2[0], .assemblerImmediateOutOfRange)
    }
    guard valid else { return true }
    instruction = Nios2Support.getITypeInstructionCode(base, destination, immediate, opcCodes[operation])
    instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    return true
  }

  public func setBinInstruction(_ instr: Int) -> Bool {
    valid = false
    let opc = Nios2Support.getOpcode(instr)
    guard let idx = opcCodes.firstIndex(of: opc) else { return false }
    valid = true
    instruction = instr
    operation = idx
    immediate = Nios2Support.getImmediate(instr, Nios2Support.iType)
    if ((immediate >> 15) & 1) != 0 { immediate |= 0xFFFF0000 }
    base = Nios2Support.getRegAIndex(instr, Nios2Support.iType)
    destination = Nios2Support.getRegBIndex(instr, Nios2Support.iType)
    return valid
  }

  public func performedJump() -> Bool { false }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { errorMessage }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    opcodes.contains(instruction.lowercased()) ? 4 : -1
  }
}
