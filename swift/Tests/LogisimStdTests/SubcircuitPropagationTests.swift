// SubcircuitPropagationTests.swift: part of logisim-evolved.
//
// `SubcircuitPropagation`, the port of `SubcircuitFactory.propagate` and `getSubstate`, against
// hand-built circuits rather than the corpus, so the suite runs everywhere.
//
// `SubcircuitPortsTests` already proves the *ends* are right, and that was never the problem: it
// passed while every hierarchical corpus oracle still read all-`U`, because
// `SimulatableComponent.propagate(in:)` dropped subcircuits at its `as? any InstanceFactory`
// guard and nothing ever drove those ends. This suite is the missing half, it asserts that a
// value entering a placement comes out the other side, plus the two properties the fix is easy
// to get wrong on: substate identity, and the absence of a process-global cache.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - Fixtures

/// `StdLibraries.registerAll()`, run once for the whole file under `swift_once`.
///
/// `BuiltinToolProviders` keeps its provider table in two unsynchronised `static var`
/// dictionaries (`LogisimFile/Builtin.swift:25-26`) and `registerAll()` writes ~12 entries into
/// them on every call, so calling it from each of five tests that swift-testing runs in parallel
/// is an unsynchronised dictionary mutation. **That was NOT the cause of the SIGSEGV this suite
/// first hit**, that was a shared listener registry, since fixed in `SimulationHost.init`, and
/// this is recorded as a suspicion, not a finding, because acting on an unverified one is how
/// this project has burned time before. Once is simply the correct number of times to register.
private let librariesRegistered: Void = StdLibraries.registerAll()

private func at(_ x: Int, _ y: Int) -> Location {
  Location.create(x, y, hasToSnap: true)
}

private func pin(_ label: String, _ type: AttributeOption, at location: Location) throws
  -> any Component
{
  let attrs = Pin.factory.createAttributeSet()
  try attrs.setValue(Pin.attrType, type)
  try attrs.setValue(StdAttr.label, label)
  return try Pin.factory.createComponent(location: location, attributes: attrs)
}

/// A one-bit buffer as a circuit: input pin `a` wired straight through to output pin `y`.
///
/// A wire and not two coincident pins, because the appearance's `getPortOffsets` is a
/// `TreeMap<Location, …>` and two pins on one point would collide there rather than in the
/// simulation; a fixture bug that would look like a propagation bug.
private func makeBufferCircuit(named name: String) throws -> Circuit {
  let circuit = try Circuit(name: name, defaultAppearance: CircuitAttributes.appearEvolution)
  try circuit.staticAttributes.setValue(
    CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
  try circuit.staticAttributes.setValue(CircuitAttributes.namedCircuitBoxFixedSize, false)

  try circuit.mutatorAdd(pin("a", Pin.input, at: at(100, 100)))
  try circuit.mutatorAdd(pin("y", Pin.output, at: at(200, 100)))
  try circuit.mutatorAdd(Wire.create(at(100, 100), at(200, 100)))
  return circuit
}

/// Wraps `inner` in an outer circuit whose own pins sit **exactly on the placement's ends**.
///
/// Landing the pins on the ends rather than running wires to them is what keeps this fixture
/// independent of the appearance geometry: the end locations are read back off the placement
/// after `computePorts` has run, so the test cannot be silently miswired by a change to where the
/// evolution appearance puts its ports.
private func wrap(_ inner: Circuit, named name: String) throws -> (Circuit, InstanceComponent) {
  let outer = try Circuit(name: name, defaultAppearance: CircuitAttributes.appearEvolution)
  let factory = inner.subcircuitFactory
  let component = try factory.createComponent(
    location: at(500, 500), attributes: factory.createAttributeSet())
  guard let placement = component as? InstanceComponent else {
    Issue.record("a subcircuit placement should be an InstanceComponent")
    throw CancellationError()
  }
  try outer.mutatorAdd(placement)

  let inputEnd = try #require(placement.ends.first { $0.isInput })
  let outputEnd = try #require(placement.ends.first { $0.isOutput })
  // The outer circuit's driver faces the placement's input, and vice versa: an outer *input* pin
  // drives the subcircuit's input end.
  try outer.mutatorAdd(pin("a", Pin.input, at: inputEnd.location))
  try outer.mutatorAdd(pin("y", Pin.output, at: outputEnd.location))
  return (outer, placement)
}

// MARK: - Tests

@Suite("Subcircuit propagation — SubcircuitFactory.propagate")
struct SubcircuitPropagationTests {

  /// **The regression this whole file exists for.**
  ///
  /// Before the routing in `ComponentSimulationSeams.propagate(in:)`, this table read
  /// `a y / 0 U / 1 U`: the placement had correct ends and never propagated, so the outer output
  /// pin saw an undriven net. 231 of the 240 remaining corpus mismatches were this one bug.
  @Test("a value driven into a placement comes out the other side")
  func valuesCrossTheBoundary() throws {
    _ = librariesRegistered
    let inner = try makeBufferCircuit(named: "buffer")
    let (outer, _) = try wrap(inner, named: "top")

    let session = SimulationSession(host: SimulationHost())
    let table = try TruthTableRun.run(circuit: outer, session: session)

    #expect(table == "a y\n0 0\n1 1\n")
  }

  /// `getSubstate` returns the *existing* substate on every call after the first.
  ///
  /// Upstream's `(CircuitState) superState.getData(comp)` short-circuit. Getting this wrong is
  /// not a performance bug: `CircuitState` keys `componentData`, dirty lists and the substate
  /// tree on object identity (D4), so a fresh substate per pass would discard the child's
  /// component data every time and a sequential subcircuit would never hold a value.
  @Test("the substate is created once and reused")
  func substateIdentityIsStable() throws {
    _ = librariesRegistered
    let inner = try makeBufferCircuit(named: "buffer")
    let (outer, placement) = try wrap(inner, named: "top")

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: outer)
    let factory = try #require(inner.subcircuitFactory as? CircuitSubcircuitFactory)

    let first = try SubcircuitPropagation.substate(
      of: root, component: placement, factory: factory, provider: session.host)
    let second = try SubcircuitPropagation.substate(
      of: root, component: placement, factory: factory, provider: session.host)

    #expect(first === second)
    #expect(root.getData(placement) as? CircuitState === first)
    #expect(first.parentState === root)
  }

  /// The `SimulatedCircuit` a substate is built from is the **cached** one.
  ///
  /// Two wrappers around one `Circuit` are two silently divergent circuits, for the same
  /// identity reason as above. This asserts the propagation path and `SimulationSession` share
  /// one cache rather than each building their own.
  @Test("the substate's circuit is the session's cached wrapper")
  func substateUsesTheCachedWrapper() throws {
    _ = librariesRegistered
    let inner = try makeBufferCircuit(named: "buffer")
    let (outer, placement) = try wrap(inner, named: "top")

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: outer)
    let factory = try #require(inner.subcircuitFactory as? CircuitSubcircuitFactory)

    let sub = try SubcircuitPropagation.substate(
      of: root, component: placement, factory: factory, provider: session.host)

    #expect(sub.circuit === session.simulated(inner))
  }

  /// D13, and the reason this is a `throw` rather than a silent `return`.
  ///
  /// A `CircuitState` whose project cannot hand back `SimulatedCircuit`s cannot build a substate.
  /// Returning quietly would reproduce exactly the bug this file fixes, a subcircuit that never
  /// propagates, whose neighbours read `UNKNOWN`, with no diagnostic attached. Throwing puts it
  /// in front of the user as a circuit error.
  @Test("a state with no circuit provider reports rather than silently not propagating")
  func missingProviderThrows() throws {
    _ = librariesRegistered
    let inner = try makeBufferCircuit(named: "buffer")
    let (outer, placement) = try wrap(inner, named: "top")

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: outer)
    let factory = try #require(inner.subcircuitFactory as? CircuitSubcircuitFactory)

    #expect(throws: SubcircuitPropagation.Failure.self) {
      _ = try SubcircuitPropagation.substate(
        of: root, component: placement, factory: factory, provider: nil)
    }
  }

  /// **D3: there is no process-global cache, and this is how you can tell.**
  ///
  /// The measurement that justified this work was taken with a global dictionary keyed by
  /// `ObjectIdentifier(circuit)`, which was behaviourally correct within one run and was thrown
  /// away rather than committed because nothing owned eviction; every circuit ever simulated
  /// would stay alive for the life of the process. This test fails if that pattern ever comes
  /// back: after the session and every state built from it are released, the wrapper must go.
  ///
  /// It is a genuine check and not a tautology; the wrapper holds its `Circuit` strongly, so an
  /// undropped wrapper pins the whole netlist, and Instruments Leaks would not flag it because a
  /// live global is not a leak.
  @Test("dropping the session releases the simulated-circuit wrappers")
  func theCacheHasAnEvictionOwner() throws {
    _ = librariesRegistered
    let inner = try makeBufferCircuit(named: "buffer")
    let (outer, _) = try wrap(inner, named: "top")

    weak var wrapper: SimulatedCircuit?
    do {
      let session = SimulationSession(host: SimulationHost())
      _ = try TruthTableRun.run(circuit: outer, session: session)
      wrapper = session.simulated(inner)
      #expect(wrapper != nil)
    }

    #expect(wrapper == nil, "a SimulatedCircuit outlived its session — is there a global cache?")
  }

  /// Two default-constructed hosts must not share one `AttributeSet`.
  ///
  /// **Found by this suite crashing, not by reading the code.** `SimulationHost.init`'s `nil`
  /// fallback used to hand every host the shared `HeadlessSimulationOptions.defaults`, and
  /// `SimulationOptionsBridge` *subscribes* to whatever set it is given, so building two hosts
  /// on different threads was a concurrent `Array.append` into one listener registry. It
  /// `SIGSEGV`ed the whole test bundle inside `objc_destructInstance`, from a stack whose only
  /// project frame was `SimulationHost.init`, which is a spectacularly unhelpful place to start
  /// looking.
  ///
  /// Asserting object distinctness rather than trying to reproduce the race: a data race is
  /// timing-dependent and would make a flaky test, while "these are separate objects" is the
  /// property that actually makes it impossible.
  @Test("each host gets its own options set, so hosts cannot share a listener registry")
  func hostsDoNotShareTheDefaultOptionsSet() {
    let first = SimulationHost()
    let second = SimulationHost()

    #expect(first.optionsAttributeSet !== second.optionsAttributeSet)
    #expect(first.optionsAttributeSet !== HeadlessSimulationOptions.defaults)

    // Same *values*, though; the fallback is still `Options()`'s defaults, so a project-less run
    // behaves as a project with untouched options.
    #expect(
      first.optionsAttributeSet[Options.simulationLimit]
        == HeadlessSimulationOptions.defaults[Options.simulationLimit])
    #expect(
      first.optionsAttributeSet[Options.simulationRandomness]
        == HeadlessSimulationOptions.defaults[Options.simulationRandomness])
  }
}
