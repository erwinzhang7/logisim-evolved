// SocBusFabricTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE ONE END-TO-END QUESTION: CAN THE SoC BUS CARRY A BYTE?
//
// Every part of this subsystem had a plausible-looking port and no test, and the composition of
// correct-looking parts was broken in a way none of them could show on its own:
//
//   `SocBusSelection`'s codec encoded to `.string(busId)` and decoded by minting a **new**
//   `SocBusInfo`. `SocSimulationManager.registerComponent` therefore attached the manager and
//   the component to a temporary that was discarded on the next line, so
//   `SocMemoryState.getRegPropagateState()` always answered `nil` and `performReadAction` fell
//   through to its `rand.nextInt()` branch.
//
// A read returned a **plausible random word**. Not an error, not a zero; a value that looks
// like memory. `SocBusTransaction`'s own header names this exact failure ("a silently-succeeding
// failed read produces a plausible wrong program run") and nothing was checking for it.
//
// So this suite writes a word and reads it back, through the whole stack the Java uses: an
// attribute set → `SocSimulationManager.registerComponent` → `SocBusFabric`'s arbitration →
// `SocMemoryState.handleTransaction` → `CircuitState`'s component data. If any one of those
// links reverts to a copy, `roundTripsAWordThroughRealMemory` fails with a random number.

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

/// A circuit holding one `SocBus` and one `SocMemory` wired to it, plus the manager that has
/// registered both and a root `CircuitState` the memory has propagated in.
private struct Fixture {
  let circuit: Circuit
  let manager: SocSimulationManager
  let root: CircuitState
  let busId: String
  let memory: any Component
  let bus: any Component
  let memoryFactory: SocMemory
}

private func makeFixture() throws -> Fixture {
  _ = librariesRegistered
  let circuit = try Circuit(name: "soc", defaultAppearance: CircuitAttributes.appearEvolution)

  // The bus first: reading `SOC_BUS_ID` is what mints its lazily-generated id (Java does the
  // same on first `getValue`), and the memory has to name that id.
  let busFactory = SocBus()
  let busAttrs = busFactory.createAttributeSet()
  let bus = try busFactory.createComponent(
    location: Location.create(100, 100, hasToSnap: true), attributes: busAttrs)
  let busId = try #require(busAttrs.getValue(SocBusAttributes.socBusId)?.busId)
  #expect(!busId.isEmpty, "SocBusAttributes never generated a bus id")

  let memoryFactory = SocMemory()
  let memAttrs = memoryFactory.createAttributeSet()
  try memAttrs.setValue(SocSimulationManager.socBusSelect, SocBusInfo(busId))
  let memory = try memoryFactory.createComponent(
    location: Location.create(400, 100, hasToSnap: true), attributes: memAttrs)

  try circuit.mutatorAdd(bus)
  try circuit.mutatorAdd(memory)

  // ── Registering by hand here is now a DELIBERATE narrowing, not the seam ────────────────────
  //
  // It used to be the seam: `Circuit.mutatorAdd` reached no manager at all (`Circuit.java:778`
  // does), and this fixture papering over it is exactly why seam #17 survived; the suite passed
  // while the product did nothing. `SocCircuitBinder` closes it, and
  // `SocCircuitBinderTests` proves the placement path end to end **without any call like the two
  // below**. That suite owns the wiring claim.
  //
  // These two lines stay because this file is the *fabric arbitration* suite: it wants a manager
  // holding exactly these two components and nothing else, with no listener, no binder and no
  // backfill in the picture. Keeping the two suites separate is what stops a fabric failure and
  // a wiring failure from masking each other.
  let manager = SocSimulationManager()
  #expect(manager.registerComponent(bus))
  #expect(manager.registerComponent(memory))

  let session = SimulationSession(host: SimulationHost())
  let root = session.createRootState(for: circuit)

  // `SocMemory.propagate` is what creates the per-run `SocMemoryInfo` and parks it in the
  // circuit state's component-data slot. Driven directly rather than through a full
  // propagation, because a `SocMemory` has no ports and the engine has no reason to visit it.
  let instanceState = try #require(root.socInstanceState(for: memory))
  try memoryFactory.propagate(instanceState)

  return Fixture(
    circuit: circuit, manager: manager, root: root, busId: busId, memory: memory, bus: bus,
    memoryFactory: memoryFactory)
}

@Suite("the SoC bus fabric carries real data", .serialized)
struct SocBusFabricTests {

  /// `SocSimulationManager.registerComponent` must reach the component's **live** `SocBusInfo`.
  /// This is the property whose loss made every peripheral invisible to its own bus.
  @Test("registering a peripheral attaches the manager to its live SocBusInfo")
  func registrationAttachesToTheLiveBusInfo() throws {
    let f = try makeFixture()
    let info = try #require(f.memory.attributeSet.getValue(SocSimulationManager.socBusSelect))
    #expect(
      info.simulationManager === f.manager,
      "the manager was attached to a copy — SocBusSelection's codec is not identity-preserving")
    #expect(info.component === f.memory)

    // And the same for the bus's own id attribute, which has its own codec.
    let busInfo = try #require(f.bus.attributeSet.getValue(SocBusAttributes.socBusId))
    #expect(busInfo.simulationManager === f.manager)
    #expect(busInfo.component === f.bus)
  }

  @Test("the memory's slave face resolves and names itself, rather than reporting BUG: Unknown")
  func slaveIsRegisteredOnTheFabric() throws {
    let f = try makeFixture()
    let fabric = try #require(f.manager.busFabric(f.busId))
    #expect(fabric.slaves.count == 1, "the memory did not register as a slave on its bus")
    let slave = try #require(fabric.slaves.first)
    #expect(
      slave.slaveName != "BUG: Unknown",
      "slaveName is upstream's own marker for 'my component back-pointer is nil'")
    #expect(f.manager.socBusCount == 1)
    #expect(f.manager.hasSocBusses)
  }

  /// **The regression this file exists for.** Write a word, read it back, through the real
  /// fabric. Before the codec fix this returned `Int32.random(...)`.
  @Test("a word written through the bus reads back byte-identical")
  func roundTripsAWordThroughRealMemory() throws {
    let f = try makeFixture()
    let port = Rv32imSocBusPort(attachedBus: SocBusInfo(f.busId), circuitState: f.root)
    port.attachedBus.attach(to: f.manager, component: f.bus)

    try port.write(0x1234_5678, at: 0x40, size: .word)
    let readBack = try port.read(at: 0x40, size: .word)
    #expect(
      readBack == 0x1234_5678,
      "read back 0x\(String(readBack, radix: 16)) — a random word means the memory never stored it")
  }

  /// Byte lanes are read-modify-write against the stored word (`SocMemoryState.java:310-321`),
  /// which only works if the stored word is real. A random-word fallback passes the word test
  /// by luck far less often than it passes this one, so both are here.
  @Test("byte and half-word accesses land in the right lanes of a stored word")
  func subWordAccessesUseTheStoredWord() throws {
    let f = try makeFixture()
    let port = Rv32imSocBusPort(attachedBus: SocBusInfo(f.busId), circuitState: f.root)
    port.attachedBus.attach(to: f.manager, component: f.bus)

    try port.write(0, at: 0x80, size: .word)
    try port.write(0xAB, at: 0x81, size: .byte)
    #expect(try port.read(at: 0x80, size: .word) == 0x0000_AB00)
    #expect(try port.read(at: 0x81, size: .byte) == 0xAB)
    #expect(try port.read(at: 0x80, size: .halfWord) == 0xAB00)

    try port.write(0xBEEF, at: 0x82, size: .halfWord)
    #expect(try port.read(at: 0x80, size: .word) == Int(Int32(bitPattern: 0xBEEF_AB00)))
  }

  /// An address outside every slave's window is `NO_RESPONSE_ERROR`, not a zero read; the
  /// distinction the whole `SocBusTransaction` error channel exists for.
  @Test("an unmapped address raises a bus error instead of reading zero")
  func unmappedAddressErrors() throws {
    let f = try makeFixture()
    let port = Rv32imSocBusPort(attachedBus: SocBusInfo(f.busId), circuitState: f.root)
    port.attachedBus.attach(to: f.manager, component: f.bus)

    // The memory defaults to 1024 bytes at 0; 0x4000 is past its end.
    #expect(throws: Rv32imBusError.self) {
      _ = try port.read(at: 0x4000, size: .word)
    }
  }

  /// A port whose `SocBusInfo` never met a manager must fail loudly. Java's equivalent is
  /// `DmaState.java:271`'s `if (controlBus.getSocSimulationManager() == null) return;`.
  @Test("a port with no simulation manager reports noSocBusConnected")
  func detachedPortErrors() throws {
    _ = librariesRegistered
    let port = Rv32imSocBusPort(attachedBus: SocBusInfo("nonexistent"))
    #expect(throws: Rv32imBusError.self) {
      _ = try port.fetchInstruction(at: 0)
    }
  }

  /// `removeComponent`'s `isSocBus` branch, which was missing entirely: Java clears the
  /// fabric's component pointer at deletion time rather than leaving it to the collector.
  @Test("removing the bus component makes the fabric report itself as gone immediately")
  func removingTheBusClearsTheFabric() throws {
    let f = try makeFixture()
    #expect(f.manager.hasSocBusses)
    #expect(f.manager.removeComponent(f.bus))
    #expect(
      !f.manager.hasSocBusses,
      "the deleted bus still counts as live — removeComponent's isSocBus branch is missing")
    #expect(f.manager.busFabric(f.busId)?.component == nil)
  }

  /// `initializeTransaction`'s drain loop blanks the `SocBusSelection` of a peripheral naming a
  /// bus that does not exist, and empties the pending list; `registerComponent`'s does neither.
  /// Merging the two loops lost a `.circ`-visible attribute rewrite.
  @Test("a transaction blanks the bus id of a peripheral pointing at an absent bus")
  func transactionBlanksDanglingBusIds() throws {
    let f = try makeFixture()

    let strayFactory = SocMemory()
    let strayAttrs = strayFactory.createAttributeSet()
    try strayAttrs.setValue(SocSimulationManager.socBusSelect, SocBusInfo("no-such-bus"))
    let stray = try strayFactory.createComponent(
      location: Location.create(700, 100, hasToSnap: true), attributes: strayAttrs)
    try f.circuit.mutatorAdd(stray)
    #expect(f.manager.registerComponent(stray))

    // Still pending, and still naming the absent bus: registerComponent's loop keeps it, since
    // the bus may yet be placed.
    #expect(
      strayAttrs.getValue(SocSimulationManager.socBusSelect)?.busId == "no-such-bus",
      "registerComponent must NOT blank a dangling id — the bus can still be placed")

    let port = Rv32imSocBusPort(attachedBus: SocBusInfo(f.busId), circuitState: f.root)
    port.attachedBus.attach(to: f.manager, component: f.bus)
    try port.write(1, at: 0, size: .word)

    #expect(
      strayAttrs.getValue(SocSimulationManager.socBusSelect)?.busId == "",
      "initializeTransaction's drain loop must blank a dangling id (SocSimulationManager.java:263-265)")
  }
}
