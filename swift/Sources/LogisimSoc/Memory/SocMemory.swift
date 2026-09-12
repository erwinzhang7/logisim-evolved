// SocMemory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.memory.SocMemory),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The RAM/ROM peripheral component. It has no pins at all, it is pure bus-mapped storage, only
// reachable through `SocMemoryState` as a `SocBusSlaveInterface`, so `ports(_:)` is empty and
// `propagate` only lazily creates the per-run `SocMemoryInfo`.
//
// Not ported: `paintInstance` (draws the base-address/size labels and the bus-connection strip
// : D6/D9), `getSizeString` (a paint-only helper formatting the size as "NkB"/"NMB").

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.soc.memory.SocMemory`.
public final class SocMemory: SocInstanceFactoryBase {
  /// `SocMemory._ID`. Do NOT change: `.circ` files reference this string.
  public static let id = "Socmem"

  public init() {
    super.init(SocMemory.id, displayName: "Memory simulator", socKind: .slave)
    setOffsetBounds(Bounds.create(0, 0, 320, 60))
  }

  public override func createAttributeSet() -> any AttributeSet { SocMemoryAttributes() }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is SocMemoryAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    if state.data == nil {
      let memState = state.attributeValue(SocMemoryAttributes.socMemState)
      state.setData(memState?.newState())
    }
  }

  public override func slaveInterface(
    _ attributes: any AttributeSet
  ) -> (any SocBusSlaveInterface)? {
    attributes.getValue(SocMemoryAttributes.socMemState)
  }
}
