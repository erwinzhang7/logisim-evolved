// SocUpStateInterface.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocUpStateInterface),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The interface each CPU core's per-instance simulation state implements (Java:
// `RV32imState.ProcessorState`, `Nios2State.ProcessorState`; both owned by other slices) so
// that the ELF loader and the assembler/state-window UI can talk to "whatever CPU is plugged
// in here" without knowing which processor family it is. Only the model-shaped half is ported,
// per D9:
//
//   DROPPED (UI, D9)                    | Java
//   -------------------------------------|------------------------------------------------------
//   `WindowListener getWindowListener()` | wires the CPU state's own window-close bookkeeping
//                                        | into a Swing `Frame`/`SocUpMenuProvider`; the UI
//                                        | layer owns its own window lifecycle and has nothing
//                                        | to attach here.
//   `JPanel getAsmWindow()`              | pre-built disassembly-listing / register-file Swing
//   `JPanel getStatePanel()`             | widgets; the UI renders its own view from
//                                        | `getTraces()`/the register accessors below instead of
//                                        | receiving a finished panel.
//   `void repaint()`                     | a paint-now trigger for the (dropped) state panel;
//                                        | the UI already observes `getSimState()`'s
//                                        | `SocUpSimulationStateListener` (SocUpSimulationState
//                                        | .swift) for "when to redraw", which is the same
//                                        | information this call was ever used to react to.
//
// `SocUpMenuProvider` itself (the type this interface exists to serve; building/registering the
// right-click "show state"/"show program"/"read ELF" menu items) is not ported at all: it is
// entirely `JMenuItem`/`JPopupMenu`/`JFileChooser`/`Frame` wiring with no model-shaped residue,
// so there is nothing here for a model port to carry. See the seam notes already on file for the
// two CPU-state ports that reference it (`Rv32imProcessorState.swift`, `Nios2Seams.swift`).
//
// `AssemblerInterface` and `SocProcessorInterface` are this module's own protocols
// (`Assembler/AssemblerExecutionInterface.swift`, `Data/SocBusInterfaces.swift`); `TraceInfo`
// and `SocUpSimulationState` are the two neighbouring files in this directory.
public protocol SocUpStateInterface: AnyObject {
  /// `getLastRegisterWritten()`.
  func getLastRegisterWritten() -> Int

  /// `getRegisterValueHex(int)`.
  func getRegisterValueHex(_ index: Int) -> String

  /// `getRegisterAbiName(int)`.
  func getRegisterAbiName(_ index: Int) -> String

  /// `getRegisterNormalName(int)`.
  func getRegisterNormalName(_ index: Int) -> String

  /// `getProgramCounter()`.
  func getProgramCounter() -> Int

  /// `getTraces()`. Java returns a `LinkedList<TraceInfo>` in the order the core appended rows
  /// (oldest first); preserve that ordering here.
  func getTraces() -> [TraceInfo]

  /// `simButtonPressed()`.
  func simButtonPressed()

  /// `getSimState()`.
  func getSimState() -> SocUpSimulationState

  /// `programLoaded()`.
  func programLoaded() -> Bool

  /// `getAssembler()`.
  func getAssembler() -> AssemblerInterface

  /// `getProcessorInterface()`.
  func getProcessorInterface() -> SocProcessorInterface

  /// `getProcessorType()`.
  func getProcessorType() -> String

  /// `getElfType()`. One of the `ElfHeader` `ELFCLASS`/machine-type constants (`File/`); a plain
  /// `Int` here, matching Java's unadorned `int`.
  func getElfType() -> Int
}
