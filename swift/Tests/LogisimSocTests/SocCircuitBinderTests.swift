// SocCircuitBinderTests.swift; part of logisim-evolved.
//
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE RULE THIS FILE IS WRITTEN UNDER: **NOTHING HERE CALLS `registerComponent`.**
//
// Seam #17 survived because every existing SoC test registered by hand; `SocBusFabricTests`'
// fixture even carries a comment explaining that `Circuit.mutatorAdd` does not do it and that
// the test therefore does. A suite that performs the work under test reports the product's
// omission as a pass. So the whole point of this file is the absence: every component below
// reaches its bus fabric through `Circuit.mutatorAdd` alone, and the only SoC call made by hand
// is `binder.attach(to:)`, which is the session-creation step an executable makes: the
// analogue of constructing a `Project`, not of doing the registration.
//
// Grep is the check: `registerComponent` and `removeComponent` must not appear below this
// header.
//
// ── Why `Circuit.mutatorAdd` and not `CircuitMutation` ──────────────────────────────────────
//
// `CircuitMutation`/`CircuitMutatorImpl` live in `LogisimUI`, which does not depend on
// `LogisimSoc` (Package.swift:176), so this target cannot import them, and adding the edge
// would mean editing `Package.swift`. `CircuitMutatorImpl.add` is a one-line forwarder to
// `circuit.mutatorAdd(component)` (`CircuitMutator.swift:94`), and `remove`/`clear` likewise
// (`:131`, `:109`), so the seam exercised here is byte-for-byte the one an undoable user edit
// takes. That is a reachability limit of the test target, not a weaker assertion.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimSoc

private let binderLibrariesRegistered: Void = {
  StdLibraries.registerAll()
  SocLibrary.registerBuiltinTools()
}()

/// A `SocBus` and a `SocMemory` naming its id: built, but **not placed** and **not registered**.
/// Each test decides when they enter the circuit, because when they enter is what is under test.
private struct Parts {
  let busFactory: SocBus
  let bus: any Component
  let busId: String
  let memoryFactory: SocMemory
  let memory: any Component
}

private func makeParts() throws -> Parts {
  _ = binderLibrariesRegistered

  let busFactory = SocBus()
  let busAttrs = busFactory.createAttributeSet()
  let bus = try busFactory.createComponent(
    location: Location.create(100, 100, hasToSnap: true), attributes: busAttrs)
  // Reading `SOC_BUS_ID` is what mints the lazily-generated id, exactly as upstream's first
  // `getValue` does.
  let busId = try #require(busAttrs.getValue(SocBusAttributes.socBusId)?.busId)
  #expect(!busId.isEmpty)

  let memoryFactory = SocMemory()
  let memAttrs = memoryFactory.createAttributeSet()
  try memAttrs.setValue(SocSimulationManager.socBusSelect, SocBusInfo(busId))
  let memory = try memoryFactory.createComponent(
    location: Location.create(400, 100, hasToSnap: true), attributes: memAttrs)

  return Parts(
    busFactory: busFactory, bus: bus, busId: busId, memoryFactory: memoryFactory, memory: memory)
}

private func makeCircuit() throws -> Circuit {
  try Circuit(name: "soc", defaultAppearance: CircuitAttributes.appearEvolution)
}

@Suite("placing a SoC component registers it, with no help from the test", .serialized)
struct SocCircuitBinderTests {

  /// `Circuit.java:778`. The whole seam in one assertion: place a `SocBus` the ordinary way and
  /// the fabric exists, pointing at that component.
  ///
  /// Deleting the `.add` case from `SocCircuitBinder.Binding.circuitChanged` turns this red.
  @Test("a SocBus placed through mutatorAdd reaches the bus fabric")
  func placingABusRegistersIt() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    #expect(!manager.hasSocBusses, "nothing is placed yet")

    try circuit.mutatorAdd(parts.bus)

    #expect(
      manager.hasSocBusses,
      "mutatorAdd fired .add and nothing registered the bus — seam #17 is back")
    #expect(manager.busFabric(parts.busId)?.component === parts.bus)
  }

  /// The attachment upstream's `registerComponent` makes on the component's *live* `SocBusInfo`
  /// ; the object `getRegPropagateState()` reaches the manager through. If this is nil, a memory
  /// read silently falls to `rand.nextInt()`.
  @Test("placing a peripheral attaches the manager to its live SocBusInfo and its bus fabric")
  func placingAPeripheralRegistersItAsASlave() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)

    let info = try #require(parts.memory.attributeSet.getValue(SocSimulationManager.socBusSelect))
    #expect(info.simulationManager === manager)
    #expect(info.component === parts.memory)

    let fabric = try #require(manager.busFabric(parts.busId))
    #expect(fabric.slaves.count == 1, "the placed memory did not register as a slave on its bus")
    #expect(fabric.slaves.first?.slaveName != "BUG: Unknown")
  }

  /// The pending list, driven entirely by placement order: a `.circ` may place slaves before
  /// their bus.
  ///
  /// ── This expectation was WRONG on first writing, and the jar corrected it ──────────────────
  ///
  /// The obvious guess is that the arriving bus adopts the slaves waiting for it. It does not:
  /// `registerComponent`'s drain loop sits lexically **inside**
  /// `if (fact.isSocSlave() || fact.isSocSniffer())` (`SocSimulationManager.java:138-156`), and a
  /// `SocBus` is neither, so placing a bus never runs it. The adoption happens in the *other*
  /// drain loop, `initializeTransaction`'s, on the first transaction anyone initiates.
  ///
  /// Not reasoned: measured. `tools/socbridge/SocRegistrationBridge.java` drives upstream
  /// 4.1.0's own `Circuit`/`CircuitMutation`/`SocSimulationManager` and prints
  /// (`tools/socbridge/oracle.txt`):
  ///
  /// ```
  /// memoryThenBus.afterMemory.slaveCount=-1  pending=1     (no fabric yet)
  /// memoryThenBus.afterBus.slaveCount=0      pending=1     <- the bus does NOT adopt it
  /// memoryThenBus.afterTransaction.slaveCount=1 pending=0  <- the transaction does
  /// ```
  ///
  /// Both rows are asserted below, because the first one is the counter-intuitive one and a port
  /// that "fixed" it would diverge from the oracle on every slaves-before-bus file.
  @Test("a peripheral placed before its bus is adopted by the first transaction, not by the bus")
  func peripheralPlacedBeforeItsBusIsAdoptedOnFirstTransaction() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.memory)
    #expect(manager.busFabric(parts.busId) == nil, "no bus exists yet — oracle: fabricExists=false")

    try circuit.mutatorAdd(parts.bus)
    let fabric = try #require(manager.busFabric(parts.busId))
    #expect(fabric.component === parts.bus)
    #expect(
      fabric.slaves.isEmpty,
      "oracle: memoryThenBus.afterBus.slaveCount=0 — a placed bus must NOT drain the pending list")

    // Now initiate a transaction, which is what upstream's second drain loop hangs off.
    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    let instanceState = try #require(root.socInstanceState(for: parts.memory))
    try parts.memoryFactory.propagate(instanceState)
    let busInfo = try #require(parts.bus.attributeSet.getValue(SocBusAttributes.socBusId))
    let port = Rv32imSocBusPort(attachedBus: busInfo, circuitState: root)
    try port.write(0, at: 0, size: .word)

    #expect(
      fabric.slaves.count == 1,
      "oracle: memoryThenBus.afterTransaction.slaveCount=1 — the first transaction must adopt it")
  }

  /// The two rows of the oracle that say what `removeComponent` does *not* do. Deleting the bus
  /// clears only the fabric's component pointer; the memory stays registered as its slave.
  /// `mutatorClear` is the one that takes the slave off too, because it removes the memory as
  /// well. Both fabrics survive in the map either way.
  ///
  /// ```
  /// afterRemove.fabricExists=true  fabricComponentIsBus=false  slaveCount=1
  /// afterClear .fabricExists=true  fabricComponentIsBus=false  slaveCount=0
  /// ```
  @Test("removing the bus leaves its slave registered; clearing does not")
  func removeAndClearDifferOnTheSlaveList() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)

    circuit.mutatorRemove(parts.bus)
    let afterRemove = try #require(manager.busFabric(parts.busId), "oracle: fabricExists=true")
    #expect(afterRemove.component == nil, "oracle: afterRemove.fabricComponentIsBus=false")
    #expect(afterRemove.slaves.count == 1, "oracle: afterRemove.slaveCount=1")

    circuit.mutatorClear()
    let afterClear = try #require(manager.busFabric(parts.busId), "oracle: fabricExists=true")
    #expect(afterClear.slaves.isEmpty, "oracle: afterClear.slaveCount=0")
  }

  /// `Circuit.java:827`. Deleting the `.remove` case turns this red.
  @Test("removing the bus through mutatorRemove clears its fabric immediately")
  func removingTheBusUnregistersIt() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    #expect(manager.hasSocBusses)

    circuit.mutatorRemove(parts.bus)

    #expect(
      !manager.hasSocBusses,
      "a deleted bus still counts as live — mutatorRemove reached no manager")
    #expect(manager.busFabric(parts.busId)?.component == nil)
  }

  /// `Circuit.java:844`'s loop. Deleting the `.clear` case turns this red, and note it must be
  /// the `.components` payload, not `.component`: `mutatorClear` fires the whole old list at
  /// once.
  @Test("mutatorClear unregisters every component it drops")
  func clearingUnregistersEverything() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)
    #expect(manager.busFabric(parts.busId)?.slaves.count == 1)

    circuit.mutatorClear()

    #expect(!manager.hasSocBusses, "mutatorClear left the bus registered")
    #expect(
      manager.busFabric(parts.busId)?.slaves.isEmpty == true,
      "mutatorClear left the memory registered as a slave on a bus that no longer exists")
  }

  /// `attach` backfills, which is what makes session-scoped ownership equivalent to Java's
  /// per-`Circuit` field: a binder created *after* a file is loaded still sees everything in it.
  @Test("attaching to an already-populated circuit registers what is already there")
  func attachBackfillsExistingComponents() throws {
    let circuit = try makeCircuit()
    let parts = try makeParts()

    // Placed with no binder in existence at all.
    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)

    let manager = SocCircuitBinder().attach(to: circuit)

    #expect(manager.hasSocBusses, "attach did not backfill the components already placed")
    #expect(manager.busFabric(parts.busId)?.slaves.count == 1)
  }

  /// Attaching twice must not double-register: `SocMemoryMap` keeps a list, so a second backfill
  /// would put the same slave on the bus twice and every read would report a multiply-claimed
  /// address.
  @Test("attaching twice is idempotent and does not double-register a slave")
  func attachIsIdempotent() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let first = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)

    let second = binder.attach(to: circuit)
    #expect(first === second, "the second attach minted a different manager")
    #expect(binder.attachedCircuitCount == 1)
    #expect(
      first.busFabric(parts.busId)?.slaves.count == 1,
      "the second attach re-ran the backfill and registered the memory twice")
  }

  /// One binder, two circuits: registrations must not bleed across. This is the property a
  /// process-global table keyed on `ObjectIdentifier` gets wrong the moment an address is reused.
  @Test("two circuits under one binder get independent managers")
  func circuitsDoNotShareManagers() throws {
    let binder = SocCircuitBinder()
    let circuitA = try makeCircuit()
    let circuitB = try makeCircuit()
    let managerA = binder.attach(to: circuitA)
    let managerB = binder.attach(to: circuitB)
    #expect(managerA !== managerB)

    let parts = try makeParts()
    try circuitA.mutatorAdd(parts.bus)

    #expect(managerA.hasSocBusses)
    #expect(!managerB.hasSocBusses, "a bus placed in circuit A registered on circuit B's manager")
    #expect(binder.attachedCircuitCount == 2)
  }

  /// **The eviction claim, measured.** D3 rejects a table with no eviction owner; this asserts
  /// the owner works; a circuit that deallocates takes its manager's entry with it, and the
  /// binder's `deinit` takes the rest.
  @Test("a deallocated circuit's binding is evicted")
  func deadCircuitsAreEvicted() throws {
    let binder = SocCircuitBinder()
    let survivor = try makeCircuit()
    binder.attach(to: survivor)

    weak var weakManager: SocSimulationManager?
    do {
      let doomed = try makeCircuit()
      weakManager = binder.attach(to: doomed)
      #expect(binder.attachedCircuitCount == 2)
      #expect(weakManager != nil)
    }

    #expect(
      binder.attachedCircuitCount == 1,
      "the deallocated circuit's binding survived — the table has no eviction owner")
    #expect(
      weakManager == nil,
      "the manager outlived its circuit; only the binder should have held it")
    #expect(binder.manager(for: survivor) != nil)
  }

  /// `detach` is the other half of the eviction story: a circuit deleted from a still-open
  /// project, where the circuit object itself may outlive the deletion (an undo stack holds it).
  @Test("detaching stops tracking further edits to that circuit")
  func detachUnsubscribes() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    binder.detach(from: circuit)
    #expect(binder.attachedCircuitCount == 0)
    #expect(binder.manager(for: circuit) == nil)

    try circuit.mutatorAdd(parts.bus)
    #expect(!manager.hasSocBusses, "a detached binding is still listening")
  }

  /// **End to end, and the reason any of this matters.** A word written through the bus reads
  /// back byte-identical: with the *only* SoC-side call in the test being `attach`. Before this
  /// wiring the read fell through to `SocMemoryState`'s `rand.nextInt()` branch, because
  /// `getRegPropagateState()` could not reach a manager that nothing had ever attached.
  @Test("a memory placed the ordinary way stores and returns a real word")
  func placedMemoryRoundTripsAWord() throws {
    let circuit = try makeCircuit()
    let binder = SocCircuitBinder()
    let manager = binder.attach(to: circuit)
    let parts = try makeParts()

    try circuit.mutatorAdd(parts.bus)
    try circuit.mutatorAdd(parts.memory)

    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)
    // `SocMemory.propagate` is what parks the per-run `SocMemoryInfo` in the state's data slot;
    // a `SocMemory` has no ports, so the engine has no reason to visit it on its own.
    let instanceState = try #require(root.socInstanceState(for: parts.memory))
    try parts.memoryFactory.propagate(instanceState)

    // The processor's view of the bus: an id and whatever manager the *circuit* attached to it.
    let busInfo = try #require(parts.bus.attributeSet.getValue(SocBusAttributes.socBusId))
    let attachedManager = try #require(
      busInfo.simulationManager,
      "the placed bus's SocBusInfo never met a manager — that is seam #17 exactly")
    #expect(attachedManager === manager)

    let port = Rv32imSocBusPort(attachedBus: busInfo, circuitState: root)
    try port.write(0x1234_5678, at: 0x40, size: .word)
    let readBack = try port.read(at: 0x40, size: .word)
    #expect(
      readBack == 0x1234_5678,
      "read back 0x\(String(readBack, radix: 16)) — a random word means the memory never stored it")
  }
}
