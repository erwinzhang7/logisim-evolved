// AssemblerExecutionInterface.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.util.AssemblerExecutionInterface,
// AbstractExecutionUnitWithLabelSupport, AssemblerInterface), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Object processorState` becomes `Any` deliberately (not a generic), matching Java's own
// looseness here: `AssemblerExecutionInterface` is shared verbatim across CPU families (Nios II
// here, RV32IM elsewhere), each of which casts to its own concrete processor-state type inside
// `execute`.
//
// `CircuitState` is `(any SocCircuitStateToken)?`: the module's one seam type for it
// (`Data/SocBusInterfaces.swift`), which `CircuitState` itself conforms to in
// `Data/SocCircuitStateBinding.swift`. It was `Any?` while this slice had no such type; keeping
// `Any?` after one existed would have meant two spellings of the same parameter in one module,
// which is the shape D15a records as this project's signature defect. `nil` remains meaningful
// and is Java's own `null`: `RV32imState.insertTransaction` branches on it explicitly.
public protocol AssemblerExecutionInterface: AnyObject {
  /// `execute(Object, CircuitState)`. Returns `false` on a simulation-visible execution error
  /// (matches `getErrorMessage()`), never traps; D13: a malformed/edge-case instruction is a
  /// simulation error the caller reports, not a process crash.
  func execute(processorState: Any, circuitState: (any SocCircuitStateToken)?) -> Bool

  func getAsmInstruction() -> String?
  func getBinInstruction() -> Int
  func setAsmInstruction(_ instruction: AssemblerAsmInstruction) -> Bool
  func setBinInstruction(_ instr: Int) -> Bool
  func performedJump() -> Bool
  var isValid: Bool { get }
  func getErrorMessage() -> String?
  func getInstructions() -> [String]
  func getInstructionSizeInBytes(_ instruction: String) -> Int
}

/// `AbstractExecutionUnitWithLabelSupport`: the subset of program-control instructions
/// (branches, `call`, `jmpi`) whose immediate is pc-relative or an absolute word address, and so
/// can be re-rendered against a resolved label name for the disassembly listing.
public protocol AssemblerExecutionUnitWithLabelSupport: AssemblerExecutionInterface {
  func isLabelSupported() -> Bool
  func getLabelAddress(pc: Int64) -> Int64
  func getAsmInstruction(label: String) -> String?
}

/// `AssemblerInterface` minus the disassembly-listing generator (`getProgram`, `AbstractAssembler`
/// in upstream): that method needs `ElfProgramHeader`/`ElfSectionHeader` and a live
/// `SocProcessorInterface`/bus round-trip to read memory back, all of which belong to the SoC
/// bus/file slices this module does not own (see Nios2Seams.swift). The tokenizer/assembler/
/// execution engine below does not need it; it is a read-back display feature, not part of the
/// assemble-to-bytes or fetch-decode-execute paths this port is gated on.
public protocol AssemblerInterface: AnyObject {
  func decode(_ instruction: Int)
  func assemble(_ instruction: AssemblerAsmInstruction) -> Bool
  func getExeUnit() -> AssemblerExecutionInterface?
  func getOpcodes() -> [String]
  func getInstructionSize(_ opcode: String) -> Int
  var usesRoundedBrackets: Bool { get }
  var highlightStringIdentifier: String { get }
  func performUpSpecificOperationsOnTokens(_ tokens: [AssemblerToken])
  var acceptedParameterTypes: Set<Int> { get }
}
