/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/RV32imAssembler.java (4.1.0).
 *
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * REPLACES `Rv32imDecoder`, WHICH WAS `AbstractAssembler` WRITTEN A SECOND TIME
 *
 * `Rv32imDecoder` existed because the RV32IM slice was ported before `soc/util`, so it could not
 * use `AbstractAssembler`. Its own header said so and then reimplemented `decode(int)`,
 * `getExeUnit()` and `getOpcodes()`: three methods that now exist, ported, twenty lines away.
 * Two implementations of one Java class is the shape D15a records as this project's signature
 * defect, and the divergence had already started: the decoder had no `assemble`, no
 * `getInstructionSize`, and no way to be handed to `AssemblerRunner`, so RISC-V had a decoder,
 * Nios II had an assembler, and neither had both.
 *
 * This is upstream's single class. `Rv32imProcessorState` drives it through
 * `selectedExecutionUnit`, which is `getExeUnit()` narrowed back to the typed
 * `Rv32imExecutionUnit` so `step` can call the `throws` `execute(on:bus:)` (see
 * `Rv32imAsmSupport.swift` on why the erased entry point is not that path).
 *
 * ── One instance per CPU, not Java's process-wide static ─────────────────────────────────────
 *
 * Java shares a single `static final RV32imAssembler ASSEMBLER` across every RV32IM component in
 * the application. The execution units are *stateful scratch*, `decode` overwrites every unit's
 * fields and `execute` reads them straight back, so sharing is only safe because propagation is
 * synchronous and non-reentrant (D2). The port keeps one per `Rv32imProcessorState` instead, as
 * `Rv32imDecoder` already did and for the reason it gave: behaviourally identical, and it avoids
 * a process-wide mutable singleton that D1/D2 are otherwise careful to keep out of this codebase.
 */

/// `com.cburch.logisim.soc.rv32im.RV32imAssembler`.
public final class Rv32imAssembler: AbstractAssembler {

  /// The eight execution units in registration order, kept concretely typed alongside
  /// `AbstractAssembler`'s erased list so the decode/execute path does not have to downcast.
  ///
  /// Java's dispatch (`AbstractAssembler.java:60-72`): `decode` calls `setBinInstruction` on
  /// EVERY unit, no short-circuit, so each unit's fields are always current, and `getExeUnit`
  /// returns the first-registered valid one. RV32I's opcode/funct3/funct7 encoding means at most
  /// one unit validates a legal word, but the "first wins" tie-break is preserved literally
  /// rather than assumed unreachable, since registration order is one thing this file could get
  /// wrong invisibly.
  public let executionUnits: [any Rv32imExecutionUnit & AssemblerExecutionInterface]

  public override init() {
    executionUnits = [
      Rv32imIntegerRegisterImmediateInstructions(),
      Rv32imIntegerRegisterRegisterOperations(),
      Rv32imControlTransferInstructions(),
      Rv32imLoadAndStoreInstructions(),
      Rv32imMemoryOrderingInstructions(),
      Rv32imEnvironmentCallAndBreakpoints(),
      Rv32imMExtensionInstructions(),
      Rv32imZicsrExtensionInstructions(),
    ]
    super.init()
    for unit in executionUnits { addAssemblerExecutionUnit(unit) }
  }

  /// `usesRoundedBrackets()`; `true`. This is what tells the tokenizer that `4(sp)` is an
  /// immediate-indexed register rather than a syntax error.
  public override var usesRoundedBrackets: Bool { true }

  /// `getHighlightStringIdentifier()`.
  public override var highlightStringIdentifier: String { "asm/riscv" }

  /// `performUpSpecificOperationsOnTokens(LinkedList<AssemblerToken>)`: empty in the Java, where
  /// Nios II uses it to retype `ctlN`/`cN` registers. Overridden with an empty body rather than
  /// inherited, so the difference from `Nios2Assembler` is visible in both files.
  public override func performUpSpecificOperationsOnTokens(_ tokens: [AssemblerToken]) {}

  /// `getExeUnit()`, narrowed to the typed protocol `Rv32imProcessorState.step` needs.
  public var selectedExecutionUnit: (any Rv32imExecutionUnit)? {
    executionUnits.first { $0.isValid }
  }

  /// Convenience matching what `Rv32imDecoder.decode` offered; `AbstractAssembler.decode` is the
  /// same call.
  public func decodeWord(_ word: Int) { decode(word) }

  /// `AbstractAssembler.getOpcodes()`, kept under the name the RV32IM slice already used.
  public var allMnemonics: [String] { getOpcodes() }
}
