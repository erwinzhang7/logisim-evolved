/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports the *decode/execute* half of: soc/util/AssemblerExecutionInterface.java (4.1.0),
 * as implemented by each of the eight instruction-family classes under soc/rv32im.
 *
 * The assemble half, `setAsmInstruction(AssemblerAsmInstruction)` and, for control transfer,
 * `AbstractExecutionUnitWithLabelSupport`'s label-relative variant, used to be listed here as
 * NOT ported, on the grounds that `AssemblerToken`/`AssemblerAsmInstruction`/`AbstractAssembler`
 * were "outside this slice". They are in this module now, so it is ported too: each of the eight
 * families implements `setAsmInstruction`, and `Rv32imAsmSupport.swift` carries the shared
 * shape checks and the `AssemblerExecutionInterface` bridge.
 *
 * `Rv32imExecutionUnit` stays the *typed* view, `Rv32imProcessorState.step` needs the `throws`
 * `execute(on:bus:)` that the erased interface cannot express, so the two protocols are two
 * views of one Java interface, joined once in `Rv32imAsmSupport.swift`.
 */

/// One instruction family's decoder + executor. Each Java class implementing
/// `AssemblerExecutionInterface` (or, for control transfer,
/// `AbstractExecutionUnitWithLabelSupport`, which extends it) becomes one conforming type.
///
/// Java's execution units are **stateful, single-instruction-at-a-time objects**: decoding
/// populates private fields that `execute`/`getAsmInstruction` read back. This is preserved
/// deliberately (not refactored into a stateless `decode() -> Instruction` value) because it
/// is a 1:1 structural port and the fields' exact semantics (e.g. a decoded-but-since-mutated
/// `operation` constant standing in for a pseudo-instruction) are easiest to verify against the
/// Java line-by-line when the shape matches.
public protocol Rv32imExecutionUnit: AnyObject {
  /// Java: `getInstructions()`. The mnemonics (including pseudo-instructions) this unit
  /// recognises, in the family's declared order.
  var instructions: [String] { get }

  /// Java: `setBinInstruction(int)`. Stores `word` and attempts to decode it as one of this
  /// unit's instructions, returning (and caching in `isValid`) whether it succeeded. Java
  /// calls this on **every** unit for **every** fetched word (`AbstractAssembler.decode`,
  /// which does not short-circuit); `Rv32imAssembler` reproduces that.
  @discardableResult
  func decode(_ word: Int) -> Bool

  /// Java: `isValid()`.
  var isValid: Bool { get }

  /// Java: `getBinInstruction()`.
  var binaryInstruction: Int { get }

  /// Java: `execute(Object, CircuitState)`. Executes the currently-decoded instruction.
  ///
  /// Returns `false` exactly where the Java method's `boolean execute` returns `false`:
  /// an unrecognised `operation` reaching a `switch`'s implicit default, or (load/store only)
  /// a bus transaction that reported an error via `trans.hasError()`. Java never treats either
  /// case as a thrown exception: `RV32imState.execute()` reads a `false` return as a **soft**
  /// failure (dialog + `simState.errorInExecution()`, PC not advanced) and keeps running.
  /// `errorMessage` carries the human-readable reason for that case, matching
  /// `getErrorMessage()`.
  ///
  /// This method is `throws` only because ONE family needs it to be: the M-extension's
  /// `DIV`/`DIVU`/`REM`/`REMU` divide by `BigInteger.divide`/`remainder`, which Java never
  /// guards against a zero divisor; `ArithmeticException: BigInteger divide by zero` is
  /// thrown, uncaught, straight out of `execute`, up through `RV32imState.execute()` (no
  /// try/catch there either) and `Rv32imRiscV.propagate()`, to the `Simulator`'s top-level
  /// `catch (Exception err)` (D13). That is a genuine Java crash-to-circuit-error path, not a
  /// soft failure, so it is the one place in this whole slice that becomes a Swift `throw`
  /// rather than a `false` return. See `Rv32imMExtensionInstructions.execute`.
  func execute(on state: Rv32imProcessorState, bus: Rv32imBus) throws -> Bool

  /// Java: `getAsmInstruction()`: disassembly of the currently-decoded instruction, `nil`
  /// (Java: `null`) if invalid. Note some families return the literal string `"Unknown"`
  /// instead of `null` for this case (`RV32imIntegerRegisterImmediateInstructions`,
  /// `RV32imIntegerRegisterRegisterOperations`) while most return `null`; that inconsistency
  /// is in the Java and is preserved by each conforming type individually rather than
  /// papered over here.
  var asmInstruction: String? { get }

  /// Java: `performedJump()`.
  var performedJump: Bool { get }

  /// Java: `getErrorMessage()`.
  var errorMessage: String? { get }

  /// Java: `getInstructionSizeInBytes(String)`. Every RV32IM instruction is 4 bytes; the
  /// lookup is by mnemonic membership, matching `getInstructions().contains(...)` case-
  /// insensitively, returning `nil` (Java: `-1`) for a mnemonic this unit does not own.
  func instructionSizeInBytes(for mnemonic: String) -> Int?
}

extension Rv32imExecutionUnit {
  /// Shared default matching every conforming type's identical
  /// `getInstructionSizeInBytes` body: `instructions.contains(mnemonic.uppercased()) ? 4 : -1`
  /// (`nil` here for `-1`).
  public func instructionSizeInBytes(for mnemonic: String) -> Int? {
    instructions.contains(mnemonic.uppercased()) ? 4 : nil
  }
}
