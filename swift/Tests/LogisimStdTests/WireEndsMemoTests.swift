// WireEndsMemoTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this gate is for ───────────────────────────────────────────────────────────────────
//
// `SimulatableComponent.wireEnds` is memoised (board #70). The memo is keyed on the identity of
// the component's `[EndData]` storage, not on the component, so nothing has to remember to
// invalidate it; see `WireEndsMemo` in `ComponentSimulationSeams.swift` for why storage identity
// is sound.
//
// That argument has to be *tested*, because the failure mode is silent and catastrophic: a stale
// `wireEnds` is a wrong answer, not a slow one. A component would read port 3 at the coordinate
// port 3 used to occupy, drive a net nobody reads, and every value downstream would settle to `U`
// , which is what a missing library, an unported factory and a propagation-ordering bug all look
// like too. Exactly the ROM-geometry failure shape `SimPortGeometryTests` was written for.
//
// **The M3 corpus gate cannot catch this.** Its 1,262 cases load a `.circ`, propagate, and dump a
// truth table; no attribute is edited mid-run, so no component's port list ever changes while a
// simulation is live. A memo that never invalidated at all would pass the corpus gate green.
// The only way to see it is to mutate ports directly, which is what every test below does.
//
// ── Why the loops ───────────────────────────────────────────────────────────────────────────
//
// The memo is one process-wide entry, and `swift test` runs suites in parallel: another suite
// simulating a circuit can evict this suite's entry between two statements. An eviction makes a
// broken memo *look* correct (the projection is rebuilt from scratch), so a single-shot assertion
// would be a coin flip against the bug. Each check therefore runs many iterations; a stale read
// has to be dodged every single time to escape.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - Helpers

/// The projection `wireEnds` is supposed to be, written out by hand so the test does not compare
/// the memo against itself.
private func expectedProjection(of component: any Component) -> [WireEndInfo] {
  component.ends.map {
    WireEndInfo(
      location: $0.location,
      width: $0.width,
      type: WireEndType(rawValue: $0.type.rawValue),
      isExclusive: $0.isExclusive)
  }
}

/// An AND gate placed at the origin. Its `inputs` attribute fires `fireAttributeListChanged()`,
/// which is the path `StdInstanceComponent.recomputePorts` takes to replace `endArray`; i.e. the
/// exact mutation the memo has to notice.
private func makeGate(
  _ factory: any ComponentFactory, inputs: Int32, x: Int32 = 0
) throws -> any SimulatableComponent {
  let attributes = factory.createAttributeSet()
  try attributes.setValue(GateAttributes.inputs, inputs)
  let component = try factory.createComponent(
    location: Location.create(Int(x), 0, hasToSnap: false), attributes: attributes)
  guard let simulatable = component as? any SimulatableComponent else {
    Issue.record("\(factory.name) did not produce a SimulatableComponent")
    throw CancellationError()
  }
  return simulatable
}

/// Storage identity of the returned array; equal addresses mean two calls shared a buffer, which
/// is only possible when the memo answered the second one.
private func storageIdentity(_ ends: [WireEndInfo]) -> UInt {
  ends.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
}

// MARK: - Tests

@Suite("wireEnds memo")
struct WireEndsMemoTests {

  /// The headline invariant: `wireEnds` is always the projection of the component's *current*
  /// ends, including immediately after the port count changes underneath it.
  ///
  /// A 2-input AND gate has 3 ends; a 5-input one has 6. Priming the memo at 2 and then reading
  /// at 5 is the stale-array case, and a memo that trusted a component key would return 3 ends
  /// here for the rest of the component's life.
  @Test("port count changes are visible immediately")
  func portCountChangeIsVisible() throws {
    let gate = try makeGate(AndGate.factory, inputs: 2)

    for round in 0..<200 {
      let count = Int32(2 + (round % 7))
      // Prime: whatever the previous round left, take a reading now so the memo holds this
      // component's ends before the mutation.
      _ = gate.wireEnds
      try gate.attributeSet.setValue(GateAttributes.inputs, count)

      let observed = gate.wireEnds
      #expect(observed.count == Int(count) + 1, "round \(round): \(count) inputs + 1 output")
      #expect(observed == expectedProjection(of: gate), "round \(round)")
    }
  }

  /// The same-length case, which a count-only validation would wave through.
  ///
  /// Changing `StdAttr.width` replaces every `EndData` with one of a different `BitWidth` and
  /// leaves the array length alone. A memo that checked only "still 3 ends?" would keep serving
  /// 1-bit ports for a 16-bit gate, and every bus in the circuit would resolve one bit wide.
  @Test("port width changes are visible even though the count does not move")
  func portWidthChangeIsVisible() throws {
    let gate = try makeGate(AndGate.factory, inputs: 3)

    for round in 0..<200 {
      let bits = 1 + (round % 24)
      _ = gate.wireEnds
      try gate.attributeSet.setValue(StdAttr.width, BitWidth.create(bits))

      let observed = gate.wireEnds
      #expect(observed.count == 4, "round \(round)")
      #expect(observed.allSatisfy { $0.width.width == bits }, "round \(round): \(bits) bits")
      #expect(observed == expectedProjection(of: gate), "round \(round)")
    }
  }

  /// Two components alternating, which is what the single-entry memo sees whenever one
  /// component's propagation reads another's ends. Each read must answer for its own component;
  /// serving A's projection for B would silently rewire the circuit.
  @Test("alternating components never see each other's ends")
  func alternatingComponentsAreNotConfused() throws {
    let a = try makeGate(AndGate.factory, inputs: 2, x: 0)
    let b = try makeGate(OrGate.factory, inputs: 5, x: 200)

    let expectedA = expectedProjection(of: a)
    let expectedB = expectedProjection(of: b)
    #expect(expectedA.count == 3)
    #expect(expectedB.count == 6)
    #expect(expectedA != expectedB)

    for round in 0..<400 {
      #expect(a.wireEnds == expectedA, "round \(round)")
      #expect(b.wireEnds == expectedB, "round \(round)")
    }
  }

  /// Every conformer, not just the two gates above: including `Wire`, whose `ends` is rebuilt
  /// per call, and `UnresolvedComponent`, whose is empty. The empty case is the one that takes
  /// the memo's early return, so it is the one that would be missed.
  @Test("every conformer projects its own ends")
  func everyConformerProjectsItsOwnEnds() throws {
    let wire = Wire.create(
      Location.create(0, 0, hasToSnap: false), Location.create(50, 0, hasToSnap: false))
    let pinAttributes = Pin.factory.createAttributeSet()
    let pin = try Pin.factory.createComponent(
      location: Location.create(300, 0, hasToSnap: false), attributes: pinAttributes)
    let unresolvedFactory = UnresolvedComponentFactory(name: "Nonexistent")
    let unresolved = UnresolvedComponent(
      factory: unresolvedFactory,
      location: Location.create(500, 0, hasToSnap: false),
      attributes: unresolvedFactory.createAttributeSet())

    let components: [(String, any SimulatableComponent)] = [
      ("Wire", wire),
      ("Pin", try #require(pin as? any SimulatableComponent)),
      ("AndGate", try makeGate(AndGate.factory, inputs: 4, x: 400)),
      ("UnresolvedComponent", unresolved),
    ]

    for round in 0..<100 {
      for (name, component) in components {
        #expect(component.wireEnds == expectedProjection(of: component), "\(name) round \(round)")
      }
    }
  }

  /// The memo is supposed to be a *memo*. Without this, every assertion above would still pass on
  /// the pre-#70 code that rebuilt the array every time, and the suite would be proving nothing
  /// about the fix.
  ///
  /// Two consecutive reads of an unchanged component that share storage can only have shared it
  /// because the second was served from the memo; an `Array.map` always allocates. Asserted as
  /// "at least one pair in 100" rather than "every pair", because a parallel suite is free to
  /// evict the entry between any two statements.
  @Test("an unchanged component is answered from the memo")
  func unchangedComponentIsAnsweredFromTheMemo() throws {
    let gate = try makeGate(AndGate.factory, inputs: 4)

    var shared = 0
    for _ in 0..<100 {
      let first = gate.wireEnds
      let second = gate.wireEnds
      #expect(first == second)
      if storageIdentity(first) == storageIdentity(second) { shared += 1 }
    }
    #expect(shared > 0, "no pair of consecutive reads shared storage — the memo never hit")
  }
}
