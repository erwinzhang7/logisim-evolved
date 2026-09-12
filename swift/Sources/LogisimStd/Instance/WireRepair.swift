// WireRepair.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.{WireRepair, WireRepairData}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why a `tools` interface lives in the component module ────────────────────────────────────
//
// Upstream puts this in `com.cburch.logisim.tools`, next to `WiringTool` which consumes it. This
// port cannot: the consumer is `LogisimUI` and **every implementor is a component**, and in this
// port every one of those components lives in `LogisimStd`, which sits *below* `LogisimUI` in the
// module graph. Declared up there, no component could name the protocol, so
// `Component.feature(.wireRepair)` would return a value the `as?` in `wireRepairFeature()` could
// never match: nil for everything, silently, with wire repair simply never happening.
//
// `InstancePoker` is the precedent and the shape is identical: the component-facing half of a
// contract lives here, the tool-facing half (`Pokable`, `Caret`) stays in `LogisimUI`, and the
// one lookup that joins them is a single method on `Component`. Like `InstancePoker`, this
// protocol is **not** `@MainActor`: a component answers it from wherever the editing gesture
// happens to be, and `LogisimUI`'s caller is main-actor isolated already.
//
// ── It cannot go into LogisimFile, and this is the fifth time the hazard has bitten ──────────
//
// `LogisimFile` already has a `WireRepair`: `com.cburch.logisim.circuit.WireRepair`, the
// `CircuitTransaction` repair pass that merges collinear wires. Different upstream class,
// different upstream package, same simple name. Two types called `WireRepair` in one module do
// not link, and `LogisimFile/WireRepair.swift` records at length why module qualification is
// unavailable inside the module that declares it. So the two stay in two modules, and the one
// place they are both visible: `LogisimUI`: spells them apart:
//
//   * `LogisimStd.WireRepair`: this protocol (`ToolFeatures.wireRepairFeature`).
//   * `CircuitWireRepairPass` ; the `LogisimFile` typealias (`LogisimFileProjectHost`).
//
// An unqualified `WireRepair` in `LogisimUI` is now ambiguous rather than wrong, which is the
// good failure: the compiler says so instead of picking one.
//
// ── What consumes it ─────────────────────────────────────────────────────────────────────────
//
// `WiringTool.checkForRepairs` (`WiringTool.java:64-88`), once per endpoint of every completed
// wire drag. Note the direction, because the name suggests the opposite: `Wire.create` normalises
// its endpoints, so `end0` is the *lower* coordinate and the candidate for `end0` is
// `end0 + 10`: one grid step back toward the middle of the wire. Repair therefore **shortens** a
// wire that has been dragged one step *past* a component's port and into its body, snapping the
// loose end back onto the port. The three guards around it (length > 10, nothing already at the
// loose end, and the component's bounds containing the loose end within 2) are what confine it
// to exactly that overshoot.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.WireRepairData`: "this wire, extended to this point".
public struct WireRepairData {
  public let wire: Wire
  public let point: Location

  public init(wire: Wire, point: Location) {
    self.wire = wire
    self.point = point
  }
}

/// `com.cburch.logisim.tools.WireRepair`; a component that can say "yes, snap that wire's loose
/// end onto me". Feature key: `ComponentFeatureKey.wireRepair`.
///
/// See the file header for why it lives here rather than beside its consumer.
public protocol WireRepair: AnyObject {
  /// `shouldRepairWire(WireRepairData)`.
  func shouldRepairWire(_ data: WireRepairData) -> Bool
}

/// A repair answer built from a closure, so a factory can vend one without a named class.
///
/// The direct Swift equivalent of upstream's `return (WireRepair) data -> …` lambdas, which is
/// how `AbstractGate.getInstanceFeature` (`:275-277`), `ControlledBuffer.getInstanceFeature`
/// (`:132-137`), `Transistor` (`:190-191`) and `TransmissionGate` (`:170-171`) all answer the
/// key. Modelled on `ClosureExpressionComputer`, which does the same job for the other lambda
/// upstream returns from `getInstanceFeature`.
public final class ClosureWireRepair: WireRepair {
  private let body: (WireRepairData) -> Bool

  public init(_ body: @escaping (WireRepairData) -> Bool) {
    self.body = body
  }

  public func shouldRepairWire(_ data: WireRepairData) -> Bool { body(data) }
}
