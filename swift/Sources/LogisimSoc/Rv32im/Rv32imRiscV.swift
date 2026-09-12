// Rv32imRiscV.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.rv32im.Rv32imRiscV),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The `InstanceFactory` half of the RV32IM core. The execution engine
// (`Rv32imProcessorState`, `Rv32imExecutionUnit`, the six instruction-set files) was ported
// first and had no factory to hang off; this is that factory, and it exists now because
// `Soc.java`'s tool list names `Rv32imRiscV.class` and a `<lib desc="#Soc">` cannot resolve
// its `<tool name="Rv32im">` without one.
//
// NOT PORTED, and each is a deliberate D6/D9 exclusion rather than an omission:
//   * `paintInstance` / `SocCpuShape` / `CpuDrawSupport`: Graphics2D drawing of the register
//     file, trace window and PLIC panel.
//   * `DynamicElementProvider.createDynamicElement`: the "add to custom appearance" hook.
//   * `getInstanceFeature(MenuExtender.class)` / `SocUpMenuProvider`: right-click menu.
//   * `setInstancePoker(CpuDrawSupport.SimStatePoker.class)`; canvas interaction.
//   * `configureNewInstance`'s `setTextField` call (`Rv32imRiscV.java:97`); label placement is
//     a paint concern, and `configureNewInstance` has no counterpart anywhere in `LogisimStd`,
//     so this is a whole-port omission rather than a SoC one. `Nios2.swift` already listed the
//     identical exclusion for `Nios2.java:144`; the two lists now agree.
//
// `propagate` used to be on that list, with the note "the SoC simulation is not wired to
// `InstanceState` yet […] a `.circ` that places a CPU will simulate it as inert". It is wired
// now: `CircuitState` conforms to `SocCircuitStateToken`, `Rv32imSocBusPort` implements
// `Rv32imBus` from the real fabric, and `Rv32imProcessorState` is `InstanceData`, so all three
// things the Java body needs exist. This and `Nios2` were the last two of the eight `#Soc`
// factories with no `propagate`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.rv32im.Rv32imRiscV`.
public final class Rv32imRiscV: SocInstanceFactoryBase {
  /// `Rv32imRiscV._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "Rv32im"

  /// Port indices, matching `updatePorts`: reset, clock, then one per IRQ line.
  private static let resetPort = 0
  private static let clockPort = 1
  private static let firstIrqPort = 2

  public init() {
    super.init(Rv32imRiscV.id, displayName: "Risc V IM simulator", socKind: [.master, .slave])
    // `setOffsetBounds(Bounds.create(0, 0, 640, 640))`.
    setOffsetBounds(Bounds.create(0, 0, 640, 640))
  }

  public override func createAttributeSet() -> any AttributeSet { Rv32imAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is Rv32imAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `updatePorts(Instance)`, expressed as this port's attribute-driven `ports(_:)`.
  // `Port` is qualified because Foundation re-exports `NSPort` as `Port`.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    let irqs = attributes.getValue(Rv32imAttributes.rv32imState)?.numberOfIrqs ?? 0
    var result: [LogisimStd.Port] = [
      LogisimStd.Port(0, 610, .input, 1),
      LogisimStd.Port(0, 630, .input, 1),
    ]
    for index in 0..<max(0, irqs) {
      result.append(LogisimStd.Port(0, 10 + index * 10, .input, 1))
    }
    return result
  }

  /// `propagate(InstanceState)` (`Rv32imRiscV.java:156-172`).
  ///
  /// D13: `throws`, because `Rv32imProcessorState.step` does: for the one genuinely-uncaught
  /// Java exception on this path, the M-extension's `BigInteger` division by zero, which upstream
  /// lets escape to `Simulator`'s `catch (Exception)` and report as a circuit error.
  public override func propagate(_ state: any InstanceState) throws {
    let config = state.attributeValue(Rv32imAttributes.rv32imState)
    let data: Rv32imProcessorState
    if let existing = state.data as? Rv32imProcessorState {
      data = existing
    } else {
      guard let config else { return }
      data = config.makeProcessorState()
      state.setData(data)
    }

    if state.portValue(Self.resetPort) == .trueValue {
      data.reset()
      return
    }

    // Java: `plic.updateFromIrqPorts(state)` reads `RV32IM_STATE.getNrOfIrqs()` itself and then
    // `state.getPortValue(i + 2) == Value.TRUE` per line. The port keeps that split (see
    // `Rv32imPlicState`'s header): the `Value` → `Bool` translation is the caller's, and this is
    // the one call site. `== .trueValue` is exact; UNKNOWN/FALSE/ERROR are all "not asserted",
    // matching Java's reference comparison against the interned `Value.TRUE`.
    if let plic = state.attributeValue(Rv32imAttributes.rv32imPlicState) {
      let irqCount = max(0, min(32, config?.numberOfIrqs ?? 0))
      var lines: [Bool] = []
      lines.reserveCapacity(irqCount)
      for index in 0..<irqCount {
        lines.append(state.portValue(Self.firstIrqPort + index) == .trueValue)
      }
      plic.updateFromIrqPorts(numberOfIrqs: irqCount, irqLines: lines)
      data.setMachineExternalInterruptPending(plic.isMachineExternalInterruptPending)
    }

    // `((InstanceStateImpl) state).getCircuitState()`: the same downcast Java performs, and the
    // reason `InstanceState` needs no `circuitState` member: only SoC components and
    // `SubcircuitFactory` reach for it. A non-`InstanceStateImpl` state (a test double) yields
    // `nil`, which `initializeTransaction` accepts exactly as Java accepts a null `CircuitState`.
    let circuitState = (state as? InstanceStateImpl)?.circuitState
    try data.setClock(
      high: state.portValue(Self.clockPort) == .trueValue, circuitState: circuitState)
  }

  /// `getSlaveInterface(AttributeSet)`; `attrs.getValue(RV32IM_PLIC_STATE)`
  /// (`Rv32imRiscV.java:175-177`). The CPU is `SOC_MASTER | SOC_SLAVE` precisely because its
  /// PLIC answers MMIO transactions from any master on the same bus; returning `nil` here (the
  /// inherited default) meant the PLIC was never registered on any fabric and every access to
  /// its window answered `NO_RESPONSE_ERROR`.
  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(Rv32imAttributes.rv32imPlicState)
  }

  /// `getSnifferInterface(AttributeSet)`: `null` in 4.1.0. Stated rather than inherited,
  /// because "the RV32IM core does not sniff the bus" is a fact worth being able to find.
  public override func snifferInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSnifferInterface)? {
    nil
  }

  /// `getProcessorInterface(AttributeSet)`; `attrs.getValue(RV32IM_STATE)`
  /// (`Rv32imRiscV.java:185-187`). This is what the ELF loader and the assembler window write a
  /// program through.
  public override func processorInterface(
    _ attributes: any AttributeSet
  ) -> (any SocProcessorInterface)? {
    attributes.getValue(Rv32imAttributes.rv32imState)
  }
}
