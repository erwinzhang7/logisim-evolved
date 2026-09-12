// SocCircuitStateBindingTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// A PROTOCOL WITH NO CONFORMER IS INDISTINGUISHABLE FROM A WORKING ONE
//
// `SocCircuitStateToken` is this module's seam for `com.cburch.logisim.circuit.CircuitState`.
// Its own header said the simulation module "needs only to conform"; nothing did, anywhere in
// the tree. The consequence is not a compile error; it is that `SocSimulationManager.data(for:)`
// and `.instanceState(for:)` return `nil` unconditionally and `initializeTransaction` has no
// callable argument type, so the entire bus fabric is unreachable while every file in it
// compiles and reads correctly. Seam #12 of the same shape.
//
// This suite asserts the conformance behaviourally rather than by `is`; a conformance that
// exists but answers `nil` for every real component would satisfy a type check and nothing else.
// Both accessors are checked against a component that a real `CircuitState` really holds data
// for, since that is the only way to tell "wired" from "compiles".

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimSoc

private let librariesRegistered: Void = {
  StdLibraries.registerAll()
  SocLibrary.registerBuiltinTools()
}()

@Suite("CircuitState satisfies the SoC seam, behaviourally", .serialized)
struct SocCircuitStateBindingTests {

  /// A marker payload standing in for the `SocMemoryInfo`/`PioRegState`/`SocBusTraceLog`
  /// objects the real peripherals park in this slot.
  private final class Marker {}

  private func placedPin() throws -> any Component {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(StdAttr.label, "a")
    return try Pin.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: true), attributes: attrs)
  }

  @Test("a CircuitState IS a SocCircuitStateToken — the conformance exists at all")
  func conformanceExists() throws {
    _ = librariesRegistered
    let circuit = try Circuit(name: "t", defaultAppearance: CircuitAttributes.appearEvolution)
    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    #expect(root as Any is any SocCircuitStateToken)
  }

  /// `SocSimulationManager.getdata(Component)`; every peripheral's `getRegPropagateState()`
  /// goes through this to reach its own live register state.
  @Test("socComponentData returns what CircuitState.getData holds for that component")
  func componentDataRoundTrips() throws {
    _ = librariesRegistered
    let circuit = try Circuit(name: "t", defaultAppearance: CircuitAttributes.appearEvolution)
    let component = try placedPin()
    try circuit.mutatorAdd(component)

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    let token: any SocCircuitStateToken = root

    #expect(
      token.socComponentData(for: component) == nil,
      "a component the state has never seen must answer nil, as Java's getData does")

    let marker = Marker()
    guard let simComponent = component as? any SimulatableComponent else {
      Issue.record("a placed Pin should be a SimulatableComponent")
      return
    }
    root.setData(simComponent, marker)

    let readBack = token.socComponentData(for: component)
    #expect(
      readBack === marker,
      "the seam returned \(String(describing: readBack)) — it is not reading CircuitState at all")
  }

  /// `SocSimulationManager.getState(Component)`; `PioState.getPropagateState()` uses it to
  /// re-invoke `handleOperations` after a register write.
  @Test("socInstanceState hands back a live InstanceState for a placed component")
  func instanceStateIsReachable() throws {
    _ = librariesRegistered
    let circuit = try Circuit(name: "t", defaultAppearance: CircuitAttributes.appearEvolution)
    let component = try placedPin()
    try circuit.mutatorAdd(component)

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    let token: any SocCircuitStateToken = root

    let state = token.socInstanceState(for: component)
    #expect(state != nil, "the seam produced no InstanceState — getInstanceState is not wired")
    #expect(state?.component === component)
  }

  /// The manager is the only consumer that stores the token, and it stores it `weak`. A
  /// conformance on a *value* type would have made that silently useless; `CircuitState` is a
  /// class, and this pins it, because the failure would otherwise show up as a bus that works
  /// for exactly one transaction.
  @Test("the token is a class, so SocSimulationManager's weak reference is meaningful")
  func tokenIsAReferenceType() throws {
    _ = librariesRegistered
    let circuit = try Circuit(name: "t", defaultAppearance: CircuitAttributes.appearEvolution)
    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    let a: any SocCircuitStateToken = root
    let b: any SocCircuitStateToken = root
    #expect(a === b)
  }
}
