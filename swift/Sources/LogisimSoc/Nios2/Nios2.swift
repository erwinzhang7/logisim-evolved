// Nios2.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Nios2Seams.swift` records `Nios2.java` as "not ported at all (report only, no stand-in)",
// keeping only its port-index constants as `Nios2PortIndex` because
// `Nios2CustomInstructions` reads and writes exactly those indices. That was right for the
// execution-engine slice and is no longer sufficient: `Soc.java` names `Nios2.class` in its
// tool list, so `#Soc` cannot be registered without the factory. This file is the codec and
// geometry half; the port indices stay where they are, and `ports(_:)` below is written
// against them so the two cannot drift.
//
// NOT PORTED (D6/D9, unchanged from the seam note):
//   * `paintInstance`, `CpuDrawSupport`, `ArithmeticIcon`: drawing.
//   * `getInstanceFeature(MenuExtender.class)` / `SocUpMenuProvider`: right-click menu.
//   * `setInstancePoker(CpuDrawSupport.SimStatePoker.class)`; canvas interaction.
//   * `configureNewInstance`'s `setTextField` call; label placement is a paint concern.
//   * `DynamicElementProvider.createDynamicElement` (`Nios2.java:221`): the "add this CPU's
//     register panel to a custom appearance" hook, building a `SocCpuShape`. `Rv32imRiscV.swift`
//     already listed this exclusion; it was missing here, and `Nios2` implements the same Java
//     interface (`Nios2.java:46`). A `.circ` carrying such a shape is not lost: `visible-*`
//     elements take `CircuitAppearanceReader`'s D8 verbatim path and re-emit unchanged.
//
// `propagate` was on that list with the note "the SoC simulation is not wired to
// `InstanceState`; […] a placed CPU simulates as inert". It is wired now; see
// `Rv32imRiscV.swift`'s header for the three pieces that had to exist first.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.nios2.Nios2`.
public final class Nios2: SocInstanceFactoryBase {
  /// `Nios2._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "Nios2"

  public init() {
    super.init(Nios2.id, displayName: "Nios2s simulator", socKind: .master)
    // `setOffsetBounds(Bounds.create(0, 0, 640, 650))`.
    setOffsetBounds(Bounds.create(0, 0, 640, 650))
  }

  public override func createAttributeSet() -> any AttributeSet { Nios2Attributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is Nios2Attributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `updatePorts(Instance)`. Java fills a `Port[NrOfIrqs + IRQSTART]` by index rather than in
  /// order, so this builds the fixed prefix positionally and asserts the mapping through
  /// `Nios2PortIndex`; the same constants `Nios2CustomInstructions` drives.
  // `Port` is qualified because Foundation re-exports `NSPort` as `Port`.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    let irqs = attributes.getValue(Nios2Attributes.nios2State)?.nrOfIrqs ?? 0
    var result = [LogisimStd.Port?](repeating: nil, count: Nios2PortIndex.irqStart)
    result[Nios2PortIndex.clock] = LogisimStd.Port(0, 640, .input, 1)
    result[Nios2PortIndex.reset] = LogisimStd.Port(0, 620, .input, 1)
    result[Nios2PortIndex.dataA] = LogisimStd.Port(30, 0, .output, 32)
    result[Nios2PortIndex.dataB] = LogisimStd.Port(80, 0, .output, 32)
    result[Nios2PortIndex.start] = LogisimStd.Port(130, 0, .output, 1)
    result[Nios2PortIndex.n] = LogisimStd.Port(180, 0, .output, 8)
    result[Nios2PortIndex.a] = LogisimStd.Port(230, 0, .output, 5)
    result[Nios2PortIndex.readRA] = LogisimStd.Port(280, 0, .output, 1)
    result[Nios2PortIndex.b] = LogisimStd.Port(330, 0, .output, 5)
    result[Nios2PortIndex.readRB] = LogisimStd.Port(380, 0, .output, 1)
    result[Nios2PortIndex.c] = LogisimStd.Port(430, 0, .output, 5)
    result[Nios2PortIndex.writeRC] = LogisimStd.Port(480, 0, .output, 1)
    result[Nios2PortIndex.done] = LogisimStd.Port(560, 0, .input, 1)
    result[Nios2PortIndex.result] = LogisimStd.Port(610, 0, .input, 32)

    // Every fixed slot is assigned above, so the compact is total; a nil would be a port index
    // this file forgot, which is exactly the bug the `Nios2PortIndex` indirection is meant to
    // make impossible.
    var ports = result.compactMap { $0 }
    for index in 0..<max(0, irqs) {
      ports.append(LogisimStd.Port(0, 40 + index * 10, .input, 1))
    }
    return ports
  }

  /// `propagate(InstanceState)` (`Nios2.java:204-218`).
  ///
  /// Note the IRQ sampling runs **after** the reset/clock branch and unconditionally; Java does
  /// not put it in the `else`, so a Nios II held in reset still latches `ipending` from its IRQ
  /// pins. Preserved; it reads like an oversight and is upstream's behaviour.
  public override func propagate(_ state: any InstanceState) throws {
    let config = state.attributeValue(Nios2Attributes.nios2State)
    let data: Nios2ProcessorState
    if let existing = state.data as? Nios2ProcessorState {
      data = existing
    } else {
      guard let config else { return }
      data = Nios2ProcessorState(config: config)
      state.setData(data)
    }

    // `((InstanceStateImpl) state).getCircuitState()`: the same downcast Java performs.
    let circuitState = (state as? InstanceStateImpl)?.circuitState

    if state.portValue(Nios2PortIndex.reset) == .trueValue {
      data.reset()
    } else {
      data.setClock(state.portValue(Nios2PortIndex.clock), circuitState: circuitState)
    }

    // `for (i = 0; i < NR_OF_IRQS.getWidth(); i++) if (getPortValue(i + IRQSTART) == TRUE)
    //    irqs |= 1 << i;`: `1 << i` with `i` up to 31, so the mask is a 32-bit `int`.
    var irqs = 0
    let irqCount = max(0, config?.nrOfIrqs ?? 0)
    for index in 0..<irqCount where state.portValue(Nios2PortIndex.irqStart + index) == .trueValue
    {
      irqs |= 1 << index
    }
    data.setIpending(irqs)
  }

  /// `getSlaveInterface`/`getSnifferInterface` both return `null` in 4.1.0
  /// (`Nios2.java:226-233`); the Nios II core is `SOC_MASTER` only. Stated rather than
  /// inherited so the asymmetry with `Rv32imRiscV`, which does expose its PLIC as a slave, is
  /// visible where someone would look for it.
  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    nil
  }

  public override func snifferInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSnifferInterface)? {
    nil
  }

  /// `getProcessorInterface(AttributeSet)`: `attrs.getValue(NIOS2_STATE)` (`Nios2.java:236`).
  public override func processorInterface(
    _ attributes: any AttributeSet
  ) -> (any SocProcessorInterface)? {
    attributes.getValue(Nios2Attributes.nios2State)
  }
}
