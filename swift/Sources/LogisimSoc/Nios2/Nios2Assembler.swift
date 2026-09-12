// Nios2Assembler.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2Assembler), GPL-3.0-only.
// See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
public final class Nios2Assembler: AbstractAssembler {
  public static let customRegister = 256
  public static let controlRegister = 257

  public override init() {
    super.init()
    addAcceptedParameterType(Nios2Assembler.customRegister)
    addAcceptedParameterType(Nios2Assembler.controlRegister)
    // Custom instructions first, matching upstream's registration order (which matters:
    // `AbstractAssembler.getExeUnit()`/`assemble()` iterate exec units in registration order,
    // and `custom` is a real opcode mnemonic like any other; first-registered-first-tried is
    // the only ordering rule, so this only matters if two units ever claimed the same opcode,
    // which they don't).
    addAssemblerExecutionUnit(Nios2CustomInstructions())
    addAssemblerExecutionUnit(Nios2DataTransferInstructions())
    addAssemblerExecutionUnit(Nios2ArithmeticAndLogicalInstructions())
    addAssemblerExecutionUnit(Nios2ComparisonInstructions())
    addAssemblerExecutionUnit(Nios2ShiftAndRotateInstructions())
    addAssemblerExecutionUnit(Nios2ProgramControlInstructions())
    addAssemblerExecutionUnit(Nios2OtherControlInstructions())
  }

  public override var usesRoundedBrackets: Bool { true }
  public override var highlightStringIdentifier: String { "asm/nios2" }

  public override func performUpSpecificOperationsOnTokens(_ tokens: [AssemblerToken]) {
    for token in tokens where token.type == AssemblerToken.register {
      let lower = token.value.lowercased()
      if lower.hasPrefix("ctl") {
        token.setType(Nios2Assembler.controlRegister)
      } else if lower.hasPrefix("c") {
        token.setType(Nios2Assembler.customRegister)
      }
    }
  }
}
