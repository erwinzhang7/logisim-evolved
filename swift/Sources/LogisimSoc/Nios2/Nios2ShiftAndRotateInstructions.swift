// Nios2ShiftAndRotateInstructions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.
// Nios2ShiftAndRotateInstructions), GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// Numeric-fidelity notes:
//   * Every shift count is masked to 5 bits (`& 0x1F`) before use, exactly like upstream; this
//     is the *register-operand* shift amount (ROL/ROR/SLL/SRA/SRL take the count from a
//     register, not the instruction word), so unlike the classic "Swift traps on an
//     instruction-derived huge shift count" hazard, the count here is already guaranteed 0-31
//     before it ever reaches a `<<`/`>>`.
//   * SLL does NOT get the free wraparound Java's native `int <<` gives it: `valueA` is a plain
//     `Int` (not `Int32`), so `valueA << imm` can produce a value outside the 32-bit range in the
//     64-bit container. `wrap32` is applied explicitly here; Java's own source doesn't need an
//     equivalent line because `int` arithmetic wraps for free, which is exactly the "looks
//     correct in Java, wrong if translated naively" hazard the port brief calls out.
//   * SRA (arithmetic right shift) needs no such fix-up: `valueA` already carries the correct
//     sign as a plain `Int`, and Swift's `>>` on a signed `Int` is arithmetic, so it reproduces
//     Java's `int >>` exactly without any extra masking: shrinking a value never overflows.
//   * SRL/ROL/ROR go through `SocSupport.convUnsignedInt`/`convUnsignedLong`, the same
//     unsigned-widen-then-narrow pair Java's `long`-based logical-shift/rotate math uses, so the
//     top bit never gets sign-extended into the result.
import LogisimKernel

public final class Nios2ShiftAndRotateInstructions: AssemblerExecutionInterface {
  private static let instrRol = 0
  private static let instrRor = 1
  private static let instrSll = 2
  private static let instrSra = 3
  private static let instrSrl = 4
  private static let instrRoli = 5
  private static let instrSlli = 6
  private static let instrSrai = 7
  private static let instrSrli = 8

  private static let asmOpcodes: [String] = ["ROL", "ROR", "SLL", "SRA", "SRL", "ROLI", "SLLI", "SRAI", "SRLI"]
  private static let asmOpxs: [Int] = [0x03, 0x0B, 0x13, 0x3B, 0x1B, 0x02, 0x12, 0x3A, 0x1A]

  private let opcodes: [String]
  private let opxCodes: [Int]

  private var instruction = 0
  private var valid = false
  private var operation = 0
  private var immediate = 0
  private var sourceA = 0
  private var sourceB = 0
  private var sourceC = 0

  public init() {
    opcodes = Self.asmOpcodes.map { $0.lowercased() }
    opxCodes = Self.asmOpxs
  }

  public func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool {
    guard valid, let state = processorState as? Nios2ProcessorState else { return false }
    var imm = state.getRegisterValue(sourceB) & 0x1F
    let valueA = state.getRegisterValue(sourceA)
    var result = 0
    switch operation {
    case Self.instrRoli:
      imm = immediate & 0x1F
      fallthrough
    case Self.instrRol:
      var opp = SocSupport.convUnsignedInt(valueA) << imm
      opp |= (opp >> 32)
      result = Int(SocSupport.convUnsignedLong(opp))
    case Self.instrRor:
      var opp = SocSupport.convUnsignedInt(valueA) << (32 - imm)
      opp |= (opp >> 32)
      result = Int(SocSupport.convUnsignedLong(opp))
    case Self.instrSlli:
      imm = immediate & 0x1F
      fallthrough
    case Self.instrSll:
      result = wrap32(valueA << imm)
    case Self.instrSrai:
      imm = immediate & 0x1F
      fallthrough
    case Self.instrSra:
      result = valueA >> imm
    case Self.instrSrli:
      imm = immediate & 0x1F
      fallthrough
    case Self.instrSrl:
      var opA = SocSupport.convUnsignedInt(valueA)
      opA >>= imm
      result = Int(SocSupport.convUnsignedLong(opA))
    default:
      return false
    }
    state.writeRegister(sourceC, result)
    return true
  }

  public func getAsmInstruction() -> String? {
    guard valid else { return nil }
    var s = opcodes[operation]
    while s.count < Nios2Support.asmFieldSize { s += " " }
    s += "\(Nios2ProcessorState.registerABINames[sourceC]),\(Nios2ProcessorState.registerABINames[sourceA]),"
    if operation < Self.instrRoli {
      s += Nios2ProcessorState.registerABINames[sourceB]
    } else {
      s += "\(immediate)"
    }
    return s
  }

  public func getBinInstruction() -> Int { instruction }

  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    valid = false
    guard opcodes.contains(instr.opcode.lowercased()) else { return false }
    guard instr.numberOfParameters == 3 else {
      instr.setError(instr.instruction, .assemblerExpectedThreeArguments)
      return false
    }
    valid = true
    operation = opcodes.firstIndex(of: instr.opcode.lowercased())!
    valid = Nios2Support.isCorrectRegister(instr, 0) && valid
    sourceC = Nios2Support.getRegisterIndex(instr, 0)
    valid = Nios2Support.isCorrectRegister(instr, 1) && valid
    sourceA = Nios2Support.getRegisterIndex(instr, 1)
    if operation >= Self.instrRoli {
      sourceB = 0
      guard let param3 = instr.getParameter(2) else { valid = false; return true }
      if param3.count != 1 || !param3[0].isNumber {
        valid = false
        if let t = param3.first { instr.setError(t, .assemblerExpectedImmediateValue) }
      }
      immediate = param3.first?.getNumberValue() ?? 0
      if immediate > 31 || immediate < 0 {
        valid = false
        if let t = param3.first { instr.setError(t, .assemblerImmediateOutOfRange) }
      }
    } else {
      immediate = 0
      valid = Nios2Support.isCorrectRegister(instr, 2) && valid
      sourceB = Nios2Support.getRegisterIndex(instr, 2)
    }
    if valid {
      instruction = Nios2Support.getRTypeInstructionCode(sourceA, sourceB, sourceC, opxCodes[operation], immediate)
      instr.setInstructionByteCode(instruction, nrOfBytes: 4)
    }
    return true
  }

  public func setBinInstruction(_ instr: Int) -> Bool {
    instruction = instr
    valid = false
    guard Nios2Support.getOpcode(instr) == 0x3A else { return false }
    valid = true
    sourceA = Nios2Support.getRegAIndex(instr, Nios2Support.rType)
    sourceB = Nios2Support.getRegBIndex(instr, Nios2Support.rType)
    sourceC = Nios2Support.getRegCIndex(instr, Nios2Support.rType)
    immediate = Nios2Support.getOPXImm(instr, Nios2Support.rType)
    let opx = Nios2Support.getOPXCode(instr, Nios2Support.rType)
    if let idx = opxCodes.firstIndex(of: opx) {
      operation = idx
    } else {
      valid = false
    }
    if (operation < Self.instrRoli && immediate != 0) || (operation >= Self.instrRoli && sourceB != 0) {
      valid = false
    }
    return valid
  }

  public func performedJump() -> Bool { false }
  public var isValid: Bool { valid }
  public func getErrorMessage() -> String? { nil }
  public func getInstructions() -> [String] { opcodes }

  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    opcodes.contains(instruction.lowercased()) ? 4 : -1
  }
}
