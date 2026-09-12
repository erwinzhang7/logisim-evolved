// The seam the M3 audit flagged: `CircuitState`'s two factories, the concrete
// `InstanceStateImpl`, and the ARC contract around both.
//
// Three of these four tests would have passed trivially before the seam was wired, because the
// code they exercise was unreachable; `createRootState` hit `fatalError("propagatorFactory is
// not installed")` on the ordinary path for opening any `.circ`. The first test is therefore the
// regression guard that matters most: it asserts that the ordinary path *runs*.
//
// The leak tests use `weak` probes rather than Instruments. That is deliberate: an ARC cycle
// produces zero test failures and is invisible without instrumentation (D3's corollary), and CI's
// `leaks` run covers only what the test binary actually executes. A `weak` probe that stays
// non-nil after the last strong reference drops *is* the cycle, reported at the exact object.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import Testing

@testable import LogisimKernel

// MARK: - Minimal conformers

/// The smallest thing that is a `SimComponent`: one output end, no behaviour.
private final class StubComponent: SimComponent {
  let endLocation: Location
  private(set) var propagateCount = 0

  let componentAttributeSet: any AttributeSet = AttributeSets.fixedSet([])

  init(at endLocation: Location) { self.endLocation = endLocation }

  var factoryRoles: SimFactoryRole { [.instanceFactory] }
  var factoryTypeIdentity: ObjectIdentifier { ObjectIdentifier(StubComponent.self) }

  var wireRole: WireComponentRole { .plain }
  var wireLocation: Location { endLocation }
  var wireEnds: [WireEndInfo] {
    [WireEndInfo(location: endLocation, width: BitWidth.known(1), type: .outputOnly)]
  }

  func propagate(in state: CircuitState) throws { propagateCount += 1 }
}

/// The smallest thing that is a `SimCircuit`.
private final class StubCircuit: SimCircuit {
  let circuitName = "stub"
  let wireStore = CircuitWires()
  private var components: [StubComponent]
  private let listeners = CircuitListenerRegistry()

  init(components: [StubComponent] = []) {
    self.components = components
    for component in components { wireStore.add(component) }
  }

  var nonWireComponents: [any SimComponent] { components }
  var clockComponents: [any SimComponent] { [] }
  func width(at point: Location) -> BitWidth { wireStore.getWidth(point) }

  func isConnected(_ location: Location, ignoring component: any SimComponent) -> Bool {
    wireStore.pointStore.getComponents(location).contains { $0 !== component }
  }

  func addCircuitListener(_ listener: any SimCircuitListener) -> CircuitSubscription {
    listeners.add(listener)
  }
}

// MARK: - Tests

@Suite("M3 seam — CircuitState factories and InstanceStateImpl ownership")
struct SimulationSeamTests {

  @Test("createRootState builds a working propagator with nothing installed")
  func rootStateIsReachable() throws {
    // The regression guard. Before the seam was wired this call reached
    // `fatalError("CircuitState.propagatorFactory is not installed")`: not a test failure, a
    // process kill, on the ordinary path for opening any `.circ`.
    let circuit = StubCircuit(components: [StubComponent(at: Location.create(30, 40, hasToSnap: false))])
    let state = CircuitState.createRootState(project: nil, circuit: circuit)

    #expect(state.propagator.rootState === state)
    #expect(state.propagator.tickCount == 0)
    #expect(!state.propagator.isOscillating)

    // And it can actually be driven: `markAllComponentsDirty` ran in the initializer, so a
    // propagate call reaches the component.
    _ = try state.propagator.propagate()
  }

  @Test("the reusable InstanceStateImpl is one object, repurposed in place")
  func reusableInstanceStateIsShared() throws {
    // Standing rule 4. Upstream documents the aliasing and measures per-call allocation as a
    // ~90% slowdown; a "fix" that allocated per call would pass every behavioural test and lose
    // the property this asserts.
    let a = StubComponent(at: Location.create(10, 10, hasToSnap: false))
    let b = StubComponent(at: Location.create(20, 20, hasToSnap: false))
    let state = CircuitState.createRootState(
      project: nil, circuit: StubCircuit(components: [a, b]))

    let first = try state.getReusableInstanceState(a)
    let second = try state.getReusableInstanceState(b)
    #expect(first === second, "the reusable scratch object must be one object per CircuitState")

    // ...and the second call has repurposed it, which is the documented, deliberate hazard.
    #expect((second as? InstanceStateImpl)?.simComponent === b)
    #expect((first as? InstanceStateImpl)?.simComponent === b)
  }

  @Test("a root CircuitState deallocates once the last strong reference drops")
  func rootStateDoesNotLeak() throws {
    // Four cycles meet at `CircuitState`: its propagator, its reusable `InstanceStateImpl`, its
    // circuit listener, and its `componentData`. Every one of them is a strong edge *out*; this
    // asserts that none of them has a strong edge back.
    weak var probeState: CircuitState?
    weak var probePropagator: Propagator?
    weak var probeInstanceState: AnyObject?

    do {
      let component = StubComponent(at: Location.create(30, 40, hasToSnap: false))
      let circuit = StubCircuit(components: [component])
      let state = CircuitState.createRootState(project: nil, circuit: circuit)
      // Force the lazy reusable instance state into existence; an unrealised `lazy` cannot leak.
      let instanceState = try state.getReusableInstanceState(component)

      probeState = state
      probePropagator = state.propagator
      probeInstanceState = instanceState
      #expect(probeState != nil)
    }

    #expect(probeState == nil, "CircuitState leaked — a back-edge into it is strong")
    #expect(probePropagator == nil, "Propagator leaked — its `root` must stay weak")
    #expect(
      probeInstanceState == nil,
      "InstanceStateImpl leaked — its `state` must stay unowned, not strong")
  }

  @Test("dropping a CircuitState unregisters it from the circuit")
  func circuitDoesNotRetainState() throws {
    // The listener edge specifically, which was prose ("the conformer must hold listeners
    // weakly") until `addCircuitListener` started returning a token. A conformer that used a
    // plain array would pin every `CircuitState` ever created to its `Circuit`; the whole state
    // tree kept alive on file close, with no test failure anywhere.
    let circuit = StubCircuit()
    weak var probe: CircuitState?
    do {
      let state = CircuitState.createRootState(project: nil, circuit: circuit)
      probe = state
      #expect(probe != nil)
    }
    #expect(probe == nil, "the circuit is still holding its listener's CircuitState")

    // The circuit itself is still perfectly usable afterwards.
    let second = CircuitState.createRootState(project: nil, circuit: circuit)
    #expect(second.circuit === circuit)
  }
}
