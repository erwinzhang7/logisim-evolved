// Nios2Seams.swift: part of logisim-evolved.
//
// Provisional protocol stand-ins for parts of `com.cburch.logisim.soc.nios2.Nios2` and
// `Nios2State` this module deliberately does NOT port, because they belong to modules this
// task does not own. Each is a MODEL-side seam (D9): the UI/instance-factory layer implements
// them against the real `Instance`/`InstanceState`/`CircuitState`/`SocBusInfo` types and wires
// the result into `Nios2ProcessorState`/`Nios2Config`.
//
// ── STALE, and corrected here rather than left to be believed ───────────────────────────────
//
// This list used to open with `Nios2.java` and `Nios2Attributes.java` as "not ported at all".
// Both ARE ported, `Nios2.swift` (factory, ports, `propagate`, the three SoC interfaces) and
// `Nios2Attributes.swift` (the full `AbstractAttributeSet`), and have been since `#Soc` needed
// registerable tools. A file header that describes a gap which has since been filled is exactly
// the kind of stale premise this project has acted on before, so the correction lives here, in
// the file that made the claim.
//
// `Nios2PortIndex` below stays, and is still load-bearing: the `CLOCK/RESET/DATAA/DATAB/START/
// N/A/READRA/B/READRB/C/WRITERC/RESULT/DONE/IRQSTART` indices are written by
// `Nios2CustomInstructions` and read by `Nios2.ports(_:)`, so the two cannot drift.
//
// Still not ported (report only, no stand-in, pure UI plumbing with no numeric-fidelity
// content of its own):
//   * `SocUpMenuProvider`/`BreakpointPanel`/`CpuDrawSupport`/`TraceInfo`/`SocUpSimulationState`'s
//     UI half (register/trace panel painting, the debugger's breakpoint list, window-visibility
//     tracking), D6/D9 model/UI split; `Nios2ProcessorState` exposes the raw state (registers,
//     pc, control regs, trace list) any of these can render.
//   * `OptionPane` dialogs (`Nios2DonePinError`, fetch/execution-error messages,
//     `RV32imBreakPointReached`); D9/D17: converted to `Nios2ExecutionFault` cases the host
//     surfaces however it wants (log line in headless mode, dialog in the GUI).
import LogisimKernel

public enum Nios2PortIndex {
  public static let clock = 0
  public static let reset = 1
  public static let dataA = 2
  public static let dataB = 3
  public static let start = 4
  public static let n = 5
  public static let a = 6
  public static let readRA = 7
  public static let b = 8
  public static let readRB = 9
  public static let c = 10
  public static let writeRC = 11
  public static let result = 12
  public static let done = 13
  public static let irqStart = 14
}

/// Stands in for the `Instance`/`InstanceState`/`CircuitState` round-trip
/// `Nios2CustomInstructions.execute`/`waitingOnReady` do against the component's own ports
/// (`Nios2.DATAA` … `Nios2.DONE`/`Nios2.RESULT`). `width`/`value` mirror
/// `Value.createKnown(width, value)`'s two arguments; `value` may be negative (a 32-bit two's
/// complement register value); `delay` mirrors `InstanceState.setPort`'s propagation-delay
/// argument (Java passes `5` for the custom-instruction ports, `0` when clearing START).
public protocol Nios2CustomInstructionHost: AnyObject {
  func setCustomPort(_ index: Int, width: Int, value: Int, delay: Int)
  /// `istate.getPortValue(Nios2.DONE)`; returns the real `Value` (LogisimKernel) so the caller
  /// can distinguish `.trueValue`/`.falseValue` from an undefined/error/multi-bit state exactly
  /// as `Nios2CustomInstructions.waitingOnReady` does (`!done.equals(TRUE) &&
  /// !done.equals(FALSE)` is itself an error condition, not just "not ready yet").
  func customPortValue(_ index: Int) -> Value
}

/// Non-localised (D5/D9) stand-in for the `OptionPane` error dialogs
/// `Nios2ProcessorState.execute`/`Nios2CustomInstructions.waitingOnReady` show. The UI layer
/// renders these; a headless caller can log `debugDescription`.
public enum Nios2ExecutionFault: Error, CustomStringConvertible {
  case breakpointReached
  case fetchTransactionError(message: String)
  case fetchInvalidInstruction
  case executionError(message: String?)
  case donePinError

  public var description: String {
    switch self {
    case .breakpointReached:
      return "Execution is paused due to a break point set at the current instruction."
    case .fetchTransactionError(let message):
      return "-> Fetch transaction error.\n\(message)"
    case .fetchInvalidInstruction:
      return "Invalid instruction fetched"
    case .executionError(let message):
      return "Error in executing fetched instruction" + (message.map { "\n\($0)" } ?? "")
    case .donePinError:
      return AssemblerMessage.nios2DonePinError.englishText
    }
  }
}
