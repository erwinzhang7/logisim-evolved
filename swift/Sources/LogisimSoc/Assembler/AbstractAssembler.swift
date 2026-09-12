// AbstractAssembler.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AbstractAssembler),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `getProgram(...)` (the disassembly-listing generator): see the seam note on
// `AssemblerInterface` in AssemblerExecutionInterface.swift.
open class AbstractAssembler: AssemblerInterface {
  private var exeUnits: [AssemblerExecutionInterface] = []
  private var acceptedTypes: Set<Int>

  public init() {
    acceptedTypes = [
      AssemblerToken.bracketedRegister,
      AssemblerToken.decNumber,
      AssemblerToken.hexNumber,
      AssemblerToken.parameterLabel,
      AssemblerToken.register,
      AssemblerToken.seperator,
      AssemblerToken.maybeLabel,
      AssemblerToken.programCounter,
    ]
    acceptedTypes.formUnion(AssemblerToken.mathOperators)
  }

  public func addAcceptedParameterType(_ type: Int) {
    acceptedTypes.insert(type)
  }

  public var acceptedParameterTypes: Set<Int> { acceptedTypes }

  public func addAssemblerExecutionUnit(_ exe: AssemblerExecutionInterface) {
    exeUnits.append(exe)
  }

  public func decode(_ instruction: Int) {
    for exe in exeUnits { _ = exe.setBinInstruction(instruction) }
  }

  public func getExeUnit() -> AssemblerExecutionInterface? {
    for exe in exeUnits where exe.isValid { return exe }
    return nil
  }

  public func getOpcodes() -> [String] {
    var opcodes: [String] = []
    for exe in exeUnits { opcodes.append(contentsOf: exe.getInstructions()) }
    return opcodes
  }

  public func getInstructionSize(_ opcode: String) -> Int {
    for exe in exeUnits {
      let size = exe.getInstructionSizeInBytes(opcode)
      if size > 0 { return size }
    }
    return 1  // Java: "to make sure that instructions are not overwritten"
  }

  public func assemble(_ instruction: AssemblerAsmInstruction) -> Bool {
    var found = false
    for exe in exeUnits {
      found = exe.setAsmInstruction(instruction) || found
    }
    if !found {
      instruction.setError(instruction.instruction, .assemblerUnknownOpcode)
    }
    return !instruction.hasErrors
  }

  // Subclasses (Nios2Assembler, etc.) override these:
  open var usesRoundedBrackets: Bool { false }
  open var highlightStringIdentifier: String { "" }
  open func performUpSpecificOperationsOnTokens(_ tokens: [AssemblerToken]) {}
}
