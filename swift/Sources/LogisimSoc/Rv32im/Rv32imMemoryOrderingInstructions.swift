/*
 * logisim-evolved: a native Swift/macOS port of logisim-evolution.
 * Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
 * which is GPL-3.0-only. This port is therefore also GPL-3.0-only.
 *
 * Ports: soc/rv32im/Rv32imMemoryOrderingInstructions.java (4.1.0); FENCE / FENCE.TSO.
 *
 * Java's `execute()` is a stub: it pops an "FENCE/FENCE.TSO not implemented" info dialog and
 * unconditionally returns `true` (success, no functional effect; this port has a single
 * hart and no reordering to fence against, so the *absence* of behavior is itself the correct
 * port, not a gap). The dialog is D17/D9 UI (`OptionPane.showMessageDialog`, gated headless to
 * a log line); replaced here with `lastInfoMessage`, a plain stored property the caller may
 * surface however it likes. This is deliberately NOT part of the shared `Rv32imExecutionUnit`
 * protocol (only this class and `Rv32imEnvironmentCallAndBreakpoints` ever populate an
 * informational, non-error message from `execute`), so it is exposed as a concrete property
 * on this type rather than widening the protocol for two implementers.
 *
 * `setAsmInstruction` is ported, and it REFUSES: in the Java it
 * unconditionally reports "not supported yet" and never encodes an instruction anyway.
 */

public final class Rv32imMemoryOrderingInstructions: Rv32imExecutionUnit,
  AssemblerExecutionInterface
{
  private static let fence = 0xF
  private static let iFlag = 8
  private static let oFlag = 4
  private static let rFlag = 2
  private static let wFlag = 1

  private static let instrFence = 0
  private static let instrFenceTso = 1

  private static let asmOpcodes = ["FENCE", "FENCE.TSO"]

  private var instruction = 0
  public private(set) var isValid = false
  private var succ = 0
  private var pred = 0
  private var operation = 0

  /// Java: the literal dialog text `S.get("Rv32imMOINotImplmented")` (typo preserved from the
  /// Java resource key, not introduced here). Not localized: see this file's header note on
  /// `soc/Strings.properties` being outside this slice.
  public private(set) var lastInfoMessage: String?

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
    lastInfoMessage = "FENCE/FENCE.TSO: not implemented"
    return true
  }

  public var asmInstruction: String? {
    guard isValid else { return nil }
    var s = Self.asmOpcodes[operation].lowercased()
    if operation != Self.instrFenceTso {
      while s.count < Rv32imBits.asmFieldSize { s += " " }
      s += masks(succ)
      s += ","
      s += masks(pred)
    }
    return s
  }

  private func masks(_ value: Int) -> String {
    var s = ""
    if (value & Self.iFlag) != 0 { s += "i" }
    if (value & Self.oFlag) != 0 { s += "o" }
    if (value & Self.rFlag) != 0 { s += "r" }
    if (value & Self.wFlag) != 0 { s += "w" }
    return s
  }

  private func decodeBin() -> Bool {
    guard Rv32imBits.opcode(instruction) == Self.fence else { return false }
    guard Rv32imBits.funct3(instruction) == 0 else { return false }
    succ = (instruction >> 20) & 0xF
    pred = (instruction >> 24) & 0xF
    let fm = (instruction >> 28) & 0xF
    let rwMask = Self.rFlag | Self.wFlag
    operation = (fm == 8 && succ == rwMask && pred == rwMask) ? Self.instrFenceTso : Self.instrFence
    return true
  }

  // MARK: - Assemble (Java: setAsmInstruction)

  /// `setAsmInstruction(AssemblerAsmInstruction)`, which upstream **deliberately refuses**:
  /// it recognises the mnemonic (so `AbstractAssembler.assemble` does not report an unknown
  /// opcode) and then reports `RV32imAssemblerNotSupportedYet`. FENCE and FENCE.TSO can be
  /// decoded and disassembled but not written.
  ///
  /// That asymmetry is the whole behaviour here and it is worth stating, because "assembling
  /// `fence` fails" reads like a port gap and is not one: the jar answers
  /// `ERR  Unsupported asm opcode` for the same input (measured through
  /// `tools/socbridge/AsmBridge.java`).
  public func setAsmInstruction(_ instr: AssemblerAsmInstruction) -> Bool {
    var operation = -1
    let wanted = instr.opcode.uppercased()
    for (index, name) in Self.asmOpcodes.enumerated() where name == wanted { operation = index }
    guard operation >= 0 else {
      isValid = false
      return false
    }
    instr.setError(instr.instruction, .rv32imAssemblerNotSupportedYet)
    isValid = false
    return true
  }
}
