/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Reference tree: upstream-java-4.1.0 (D16).
 *
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * THE ASSEMBLE HALF OF `AssemblerExecutionInterface`, FOR THE RV32IM FAMILY
 *
 * Every RV32IM execution unit was ported decode/execute-only; each file's header said so and
 * pointed at `Rv32imExecutionUnit.swift`'s "NOT ported: the assemble half". Nios II's seven units
 * *do* have it, so the assembler worked for one CPU family and silently not the other; a
 * `Rv32imAssembler` did not exist at all, and `AbstractAssembler`/`AssemblerInfo`/`AssemblerRunner`
 * were sitting there fully ported with nothing RISC-V to drive.
 *
 * ── Why the shape checks live here and not inline eight times ────────────────────────────────
 *
 * Java writes the same six-line block; "is this parameter exactly one REGISTER token? if not,
 * flag every token in it and bail"; 30-odd times across the eight files. Transcribing it 30
 * times is 30 chances to omit the loop over `param` (upstream flags EVERY token in a malformed
 * parameter, not just the first) or to invert a bail-out. So it is written once, here, with the
 * Java's own control flow preserved in the return type: `nil` means "shape wrong, error already
 * recorded, stop", a value means "carry on", and the register *range* check is separate because
 * upstream's range check sets `errors = true` WITHOUT breaking out of the switch.
 *
 * That distinction is load-bearing. `x99` produces a range error and still runs the rest of the
 * case; `(x1)` where a register was expected produces a shape error and skips it.
 */

import Foundation

/// The repeated parameter-shape and register-resolution blocks of every RV32IM
/// `setAsmInstruction`.
public enum Rv32imAsmSupport {

  /// Java's repeated:
  /// ```java
  /// if (paramN.length != 1 || paramN[0].getType() != AssemblerToken.REGISTER) {
  ///   for (AssemblerToken t : paramN) instr.setError(t, S.getter("AssemblerExpectedRegister"));
  ///   errors = true;
  ///   break;
  /// }
  /// ```
  /// Returns the single token on success; `nil` (with the errors recorded) on failure, which the
  /// caller treats as Java's `break`.
  public static func registerToken(
    _ instr: AssemblerAsmInstruction, _ index: Int
  ) -> AssemblerToken? {
    guard let param = instr.getParameter(index) else { return nil }
    if param.count != 1 || param[0].type != AssemblerToken.register {
      for token in param { instr.setError(token, .assemblerExpectedRegister) }
      return nil
    }
    return param[0]
  }

  /// Same, for `AssemblerToken.BRACKETED_REGISTER`: the `(x1)` form the load/store units want.
  public static func bracketedRegisterToken(
    _ instr: AssemblerAsmInstruction, _ index: Int
  ) -> AssemblerToken? {
    guard let param = instr.getParameter(index) else { return nil }
    if param.count != 1 || param[0].type != AssemblerToken.bracketedRegister {
      for token in param { instr.setError(token, .rv32imAssemblerExpectedBracketedRegister) }
      return nil
    }
    return param[0]
  }

  /// Java's repeated:
  /// ```java
  /// if (paramN.length != 1 || !paramN[0].isNumber()) {
  ///   for (AssemblerToken t : paramN) instr.setError(t, S.getter("AssemblerExpectedImmediateValue"));
  ///   errors = true;
  ///   break;
  /// }
  /// ```
  public static func numberToken(
    _ instr: AssemblerAsmInstruction, _ index: Int
  ) -> AssemblerToken? {
    guard let param = instr.getParameter(index) else { return nil }
    if param.count != 1 || !param[0].isNumber {
      for token in param { instr.setError(token, .assemblerExpectedImmediateValue) }
      return nil
    }
    return param[0]
  }

  /// Java's repeated:
  /// ```java
  /// destination = RV32imState.getRegisterIndex(paramN[0].getValue());
  /// if (destination < 0 || destination > 31) {
  ///   errors = true;
  ///   instr.setError(paramN[0], S.getter("AssemblerUnknownRegister"));
  /// }
  /// ```
  /// **Not** a `break` in the Java, the index is used anyway, so this returns the value it
  /// resolved (which may be out of range) and reports through `inout errors`, exactly as
  /// upstream does. Returning an Optional here would silently change the control flow.
  public static func registerIndex(
    _ instr: AssemblerAsmInstruction, _ token: AssemblerToken, _ errors: inout Bool
  ) -> Int {
    let index = Rv32imRegisterNames.index(of: token.value)
    if index < 0 || index > 31 {
      errors = true
      instr.setError(token, .assemblerUnknownRegister)
    }
    return index
  }

  /// The parameter-count guard every case opens with. `expected` is the exact count; the message
  /// is chosen the way Java chooses it, one getter per arity.
  public static func expectParameters(
    _ instr: AssemblerAsmInstruction, _ expected: Int
  ) -> Bool {
    guard instr.numberOfParameters != expected else { return true }
    let message: AssemblerMessage
    switch expected {
    case 0: message = .assemblerExpectedNoArguments
    case 1: message = .assemblerExpectedOneArgument
    case 2: message = .assemblerExpectedTwoArguments
    case 3: message = .assemblerExpectedThreeArguments
    default: message = .assemblerExpectedFourArguments
    }
    instr.setError(instr.instruction, message)
    return false
  }
}

// MARK: - AssemblerExecutionInterface, from what Rv32imExecutionUnit already provides

/// Every member of `AssemblerExecutionInterface` that an `Rv32imExecutionUnit` can already
/// answer, so each of the eight units only has to write `setAsmInstruction` itself.
///
/// The two protocols are two views of one Java interface, `AssemblerExecutionInterface` is what
/// `AbstractAssembler` stores, `Rv32imExecutionUnit` is the typed view
/// `Rv32imProcessorState.step` drives, and this extension is the join, written once rather than
/// eight times.
extension AssemblerExecutionInterface where Self: Rv32imExecutionUnit {

  public func getAsmInstruction() -> String? { asmInstruction }
  public func getBinInstruction() -> Int { binaryInstruction }
  public func setBinInstruction(_ instr: Int) -> Bool { decode(instr) }
  public func performedJump() -> Bool { performedJump }
  public func getErrorMessage() -> String? { errorMessage }
  public func getInstructions() -> [String] { instructions }

  /// Java returns `-1` for a mnemonic this unit does not own; `Rv32imExecutionUnit` models that
  /// as `nil`, and `AbstractAssembler.getInstructionSize` tests `size > 0`, so the two agree.
  public func getInstructionSizeInBytes(_ instruction: String) -> Int {
    instructionSizeInBytes(for: instruction) ?? -1
  }

  /// `execute(Object, CircuitState)`.
  ///
  /// **Not the path the RV32IM core takes.** `Rv32imProcessorState.step` holds the concrete
  /// `Rv32imExecutionUnit` and calls `execute(on:bus:)` directly, which is `throws` and so keeps
  /// D13's promise for the one genuinely-uncaught Java exception on this path (the M-extension's
  /// `BigInteger` division by zero). This erased entry point exists because
  /// `AbstractAssembler.getExeUnit()` hands back the shared interface, and a caller reaching it
  /// gets the real result: with one stated narrowing: a thrown division-by-zero becomes `false`
  /// here rather than propagating, because the protocol method cannot throw. Java would let it
  /// escape to `Simulator`'s `catch (Exception)`; a caller that needs that behaviour must use
  /// the typed method, as the core does.
  public func execute(
    processorState: Any, circuitState: (any SocCircuitStateToken)?
  ) -> Bool {
    guard let state = processorState as? Rv32imProcessorState, let bus = state.busPort else {
      return false
    }
    bus.circuitState = circuitState
    return (try? execute(on: state, bus: bus)) ?? false
  }
}
