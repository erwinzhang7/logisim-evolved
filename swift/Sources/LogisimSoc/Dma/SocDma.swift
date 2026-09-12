// SocDma.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.dma.SocDma),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Ports: 0 Reset (active high), 1 Clock, 2 IRQ output (active high, driven directly: no
// propagation delay beyond the Java `setPort(..., 1)` single-tick delay, preserved below).
//
// Not ported: `paintInstance` (status text, bus-connection strips; D6/D9).
//
// ── Seam: `InstanceStateImpl.getCircuitState()` ─────────────────────────────────────────────────
//
// Java's `propagate` reaches the live `CircuitState` via `((InstanceStateImpl) state)
// .getCircuitState()`: a downcast to the simulation module's concrete implementation, which
// this module does not own. The port instead requires `InstanceState` itself to double as a
// `SocCircuitStateToken` (`state as? any SocCircuitStateToken`); the simulation module's real
// `InstanceStateImpl` needs one trivial conformance (it already knows its own `CircuitState`)
// rather than a public accessor this module would have to know the concrete type of.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.dma.SocDma`.
public final class SocDma: SocInstanceFactoryBase {
  /// `SocDma._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "SocDma"

  private static let resetIndex = 0
  private static let clockIndex = 1
  private static let irqIndex = 2
  private static let width = 320
  private static let height = 120

  public init() {
    super.init(SocDma.id, displayName: "DMA engine", socKind: [.slave, .master])
    setOffsetBounds(Bounds.create(0, 0, Self.width, Self.height))
  }

  public override func createAttributeSet() -> any AttributeSet { DmaAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is DmaAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  // `Port` is qualified because Foundation re-exports `NSPort` as `Port`, making the bare
  // name ambiguous wherever Foundation and LogisimStd are both imported.
  public override func ports(_ attributes: any AttributeSet) -> [LogisimStd.Port] {
    [
      LogisimStd.Port(0, 100, .input, 1),
      LogisimStd.Port(0, 110, .input, 1),
      LogisimStd.Port(Self.width, 100, .output, 1),
    ]
  }

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let regs: DmaRegState
    if let existing = state.data as? DmaRegState {
      regs = existing
    } else {
      regs = state.attributeValue(DmaAttributes.dmaState)?.newState() ?? DmaRegState()
      state.setData(regs)
    }

    let clock = state.portValue(Self.clockIndex)

    if state.portValue(Self.resetIndex) == .trueValue {
      regs.reset()
      regs.lastClock = clock
      state.setPort(Self.irqIndex, .falseValue, 1)
      return
    }

    if regs.lastClock == .falseValue && clock == .trueValue,
      let dmaState = state.attributeValue(DmaAttributes.dmaState),
      let circuitState = state as? any SocCircuitStateToken
    {
      dmaState.executeBurst(regs, circuitState: circuitState)
    }
    regs.lastClock = clock

    state.setPort(Self.irqIndex, regs.irqAsserted ? .trueValue : .falseValue, 1)
  }

  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(DmaAttributes.dmaState)
  }
}
