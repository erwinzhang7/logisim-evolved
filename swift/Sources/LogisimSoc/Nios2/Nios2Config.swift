// Nios2Config.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2State: the outer class,
// i.e. everything except the `ProcessorState` inner class, which is `Nios2ProcessorState.swift`),
// GPL-3.0-only. See LICENSE.md. Reference tree: upstream-java-4.1.0 (D16).
//
// Per-component configuration: reset/exception/break vectors, IRQ count, label, and which SoC
// bus this CPU is attached to. In Java this data lives directly on `Nios2Attributes` /
// `Nios2State`, wired through LogisimKernel's `Attribute<V>`/`AttributeSet` (D5) machinery. This
// class carries the same fields and the same mutate-and-report-changed shape
// (`setX(value) -> Bool`, mirroring Java's "return true iff it actually changed" convention used
// to decide whether to fire an attribute-changed event) WITHOUT depending on that machinery:
// see the seam note in Nios2Seams.swift for why, and what the integrator still has to wire.
import LogisimFile

public final class Nios2Config {
  public private(set) var resetVector: Int = 0
  public private(set) var exceptionVector: Int = 0x14
  public private(set) var breakVector: Int = 0x30
  public private(set) var nrOfIrqs: Int = 0
  public private(set) var label: String = ""
  /// Java: `private final SocBusInfo attachedBus` on `Nios2State`, initialised to
  /// `new SocBusInfo("")`.
  ///
  /// This was a bare id string with the note "the real `SocBusInfo` […] additionally resolves
  /// this to a live bus component; that resolution is the integrator's job". `SocBusInfo` is in
  /// this module now, and `SocSimulationManager.registerComponent` attaches the manager and the
  /// component *to the object the attribute hands back*, so the CPU has to be holding that same
  /// object, not a copy of its id. `Nios2Attributes.getValue(SOC_BUS_SELECT)` is
  /// `return upState.getAttachedBus();` (`Nios2Attributes.java:95`), which is now literally true
  /// here too.
  public let attachedBus = SocBusInfo("")

  /// Convenience for call sites that only want the id.
  public var attachedBusId: String { attachedBus.busId }

  /// `attachedBus.getComponent()`: the placed CPU, used as `SocBusTransaction`'s `initiator`
  /// so bus-side logging and arbitration see the real originating component. Reads through the
  /// `SocBusInfo` rather than being a second, separately-maintained back-pointer.
  public var masterComponent: (any Component)? { attachedBus.component }

  public init() {}

  public func copyInto(_ dest: Nios2Config) {
    dest.resetVector = resetVector
    dest.exceptionVector = exceptionVector
    dest.breakVector = breakVector
    dest.nrOfIrqs = nrOfIrqs
    dest.label = label
    dest.attachedBus.busId = attachedBus.busId
  }

  /// `getName()` minus the `Component`/`Location`-based fallback (`"<displayName>@x,y"`), which
  /// needs the real placed-component identity this module does not own. Callers with a
  /// `masterComponent` available can build that fallback themselves via `SocSupport`.
  public var name: String { label }

  @discardableResult
  public func setResetVector(_ value: Int) -> Bool {
    guard resetVector != value else { return false }
    resetVector = value
    return true
  }

  @discardableResult
  public func setExceptionVector(_ value: Int) -> Bool {
    guard exceptionVector != value else { return false }
    exceptionVector = value
    return true
  }

  @discardableResult
  public func setBreakVector(_ value: Int) -> Bool {
    guard breakVector != value else { return false }
    breakVector = value
    return true
  }

  @discardableResult
  public func setNrOfIrqs(_ value: Int) -> Bool {
    guard nrOfIrqs != value else { return false }
    nrOfIrqs = value
    return true
  }

  @discardableResult
  public func setLabel(_ value: String) -> Bool {
    guard label != value else { return false }
    label = value
    return true
  }

  /// Java: `setAttachedBus(SocBusInfo)`; copies the **id** out of the incoming object and keeps
  /// its own, so the identity the simulation manager attached to survives every `setValue`.
  @discardableResult
  public func setAttachedBus(_ info: SocBusInfo) -> Bool {
    guard attachedBus.busId != info.busId else { return false }
    attachedBus.busId = info.busId
    return true
  }

  @discardableResult
  public func setAttachedBus(_ busId: String) -> Bool {
    guard attachedBus.busId != busId else { return false }
    attachedBus.busId = busId
    return true
  }
}

// MARK: - SocProcessorInterface (Java: `Nios2State implements … SocProcessorInterface`)

extension Nios2Config: SocProcessorInterface {

  /// `setEntryPointandReset(CircuitState, long, ElfProgramHeader, ElfSectionHeader)`
  /// (`Nios2State.java:651`). Upstream also calls `comp.getInstance().fireInvalidated()` to
  /// repaint the CPU face; that is D6/D9 and the renderer observes the state directly.
  public func setEntryPointAndReset(
    circuitState: (any SocCircuitStateToken)?, entryPoint: Int64,
    programHeader: ElfProgramHeader?, sectionHeader: ElfSectionHeader?
  ) {
    guard let state = processorState(in: circuitState) else { return }
    state.reset(entry: Int(Int32(truncatingIfNeeded: entryPoint)), programLoaded: true)
  }

  /// `insertTransaction(SocBusTransaction, boolean, CircuitState)` (`Nios2State.java:664`),
  /// minus the `cState == null` recovery through `Project`: see the identical note on
  /// `Rv32imConfig.insertTransaction`.
  public func insertTransaction(
    _ transaction: SocBusTransaction, hidden: Bool, circuitState: (any SocCircuitStateToken)?
  ) {
    if hidden { transaction.setAsHidden() }
    guard let manager = attachedBus.simulationManager else {
      transaction.setError(.noSocBusConnected)
      return
    }
    manager.initializeTransaction(
      transaction, busId: attachedBus.busId, circuitState: circuitState)
  }

  /// `getEntryPoint(CircuitState)` (`Nios2State.java:679`), including its `return 0` for a
  /// `null` state. Note Java would NPE on `((ProcessorState) cState.getData(comp)).getEntryPoint()`
  /// when the state holds no data for the component; answering 0 is the same value its `null`
  /// path produces and is what D13 asks for on a path a `.circ` can reach.
  public func entryPoint(_ circuitState: (any SocCircuitStateToken)?) -> Int32 {
    guard let state = processorState(in: circuitState) else { return 0 }
    return Int32(truncatingIfNeeded: state.entryPoint ?? 0)
  }

  private func processorState(
    in circuitState: (any SocCircuitStateToken)?
  ) -> Nios2ProcessorState? {
    guard let circuitState, let component = attachedBus.component else { return nil }
    return circuitState.socComponentData(for: component) as? Nios2ProcessorState
  }
}

