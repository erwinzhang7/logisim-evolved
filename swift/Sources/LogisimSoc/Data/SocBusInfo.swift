// SocBusInfo.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocBusInfo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the attribute *value* every SoC peripheral stores to record which bus it is attached
// to: the payload of `SocSimulationManager.SOC_BUS_SELECT` and (for DMA) the master-only
// source/destination bus attributes. It is a reference type in Java (mutated in place by
// `setBusId`/`setSocSimulationManager` and shared between the attribute-set copy and the live
// `SocBusSlaveInterface`), so it stays a `final class` here too; a `struct` copy would silently
// desynchronise the attribute-set value from the state object that actually holds the wiring.
//
// Not ported: `paint(Graphics, Bounds)`; draws the green/red "connected to <bus>" strip on the
// component's face. D6/D9: the renderer can reproduce this directly from
// `simulationManager?.displayString(for: busId)` (ported below as `SocSimulationManager
// .displayString(for:)`), which is the only non-trivial logic `paint` contained.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.soc.data.SocBusInfo`.
public final class SocBusInfo {
  private var busIdValue: String

  /// `getSocSimulationManager()`. Weak: the manager owns the circuit's component graph, not the
  /// other way around (D3; this is exactly the shape of `parentState`/`proj`).
  public weak var simulationManager: SocSimulationManager?
  /// `getComponent()`. Weak for the same reason: this is a back-pointer into the component that
  /// carries this attribute value, not an owning edge.
  public weak var component: (any Component)?

  public init(_ id: String?) {
    self.busIdValue = id ?? ""
  }

  /// `getBusId()`. Java stores `null` until first use (see `SocBusAttributes.getValue`'s lazy
  /// generation of a fresh id) and callers routinely compare against `null`/empty; the port
  /// always carries a `String`, and callers that need "not yet assigned" test `.isEmpty`.
  public var busId: String {
    get { busIdValue }
    set { busIdValue = newValue }
  }

  /// `setSocSimulationManager(SocSimulationManager, Component)`.
  public func attach(to manager: SocSimulationManager, component: any Component) {
    self.simulationManager = manager
    self.component = component
  }
}
