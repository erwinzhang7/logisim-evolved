// Rv32imSimulationTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// A RISC-V CORE FETCHING ITS OWN INSTRUCTIONS OUT OF A REAL SoC MEMORY
//
// The RV32IM execution engine was ported in full, every instruction family, the CSR file, the
// M-extension's division semantics, against an `Rv32imBus` protocol that **nothing in the tree
// implemented**. So `Rv32imProcessorState.step(bus:)` was uncallable outside a hand-written
// mock, and `Rv32imRiscV` inherited a no-op `propagate`: a placed CPU simulated as inert.
//
// This suite closes the loop. The program is written into a `SocMemory` through the bus, and
// the CPU fetches it back through the same bus, so a fetch that silently returned garbage
// (the `rand.nextInt()` path the memory fell into before the codec fix) shows up here as a
// decoded instruction that is not the one that was stored.
//
// ── What is NOT asserted, and why ───────────────────────────────────────────────────────────
//
// `propagate` reads the clock and reset **ports**, and driving those needs a wired circuit and
// a sequenced clock, which the headless truth-table harness cannot express. So `propagate` is
// tested for the part it uniquely owns, creating the per-run `InstanceData` and not trapping,
// and the fetch/execute loop is driven through `setClock(high:circuitState:)` directly, which is
// the exact call `propagate`'s last line makes.

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

/// A `SocBus` + `SocMemory` + `Rv32imRiscV` on one bus, registered, with a root `CircuitState`
/// both peripherals have propagated in.
private struct SocFixture {
  let root: CircuitState
  let manager: SocSimulationManager
  let cpu: any Component
  let cpuState: Rv32imProcessorState
}

private func makeSocFixture() throws -> SocFixture {
  _ = librariesRegistered
  let circuit = try Circuit(name: "soc", defaultAppearance: CircuitAttributes.appearEvolution)

  let busFactory = SocBus()
  let busAttrs = busFactory.createAttributeSet()
  let bus = try busFactory.createComponent(
    location: Location.create(100, 100, hasToSnap: true), attributes: busAttrs)
  let busId = try #require(busAttrs.getValue(SocBusAttributes.socBusId)?.busId)

  let memFactory = SocMemory()
  let memAttrs = memFactory.createAttributeSet()
  try memAttrs.setValue(SocSimulationManager.socBusSelect, SocBusInfo(busId))
  let memory = try memFactory.createComponent(
    location: Location.create(500, 100, hasToSnap: true), attributes: memAttrs)

  let cpuFactory = Rv32imRiscV()
  let cpuAttrs = cpuFactory.createAttributeSet()
  try cpuAttrs.setValue(SocSimulationManager.socBusSelect, SocBusInfo(busId))
  let cpu = try cpuFactory.createComponent(
    location: Location.create(1000, 100, hasToSnap: true), attributes: cpuAttrs)

  try circuit.mutatorAdd(bus)
  try circuit.mutatorAdd(memory)
  try circuit.mutatorAdd(cpu)

  // `Circuit.mutatorAdd` does this itself upstream (`Circuit.java:778`); the port's `Circuit`
  // lives in `LogisimFile` and cannot name `LogisimSoc`, so the join is open and reported.
  let manager = SocSimulationManager()
  manager.registerComponent(bus)
  manager.registerComponent(memory)
  manager.registerComponent(cpu)

  let session = SimulationSession(host: SimulationHost())
  let root = session.createRootState(for: circuit)

  try memFactory.propagate(try #require(root.socInstanceState(for: memory)))
  try cpuFactory.propagate(try #require(root.socInstanceState(for: cpu)))

  let cpuState = try #require(root.socComponentData(for: cpu) as? Rv32imProcessorState)
  return SocFixture(root: root, manager: manager, cpu: cpu, cpuState: cpuState)
}

@Suite("an RV32IM core runs a program out of SoC memory", .serialized)
struct Rv32imSimulationTests {

  /// `addi rd, rs1, imm`, opcode `0b0010011`, funct3 0.
  private func addi(rd: Int, rs1: Int, imm: Int) -> Int {
    Rv32imBits.iTypeInstruction(opcode: 0x13, rd: rd, funct3: 0, rs1: rs1, imm: imm)
  }

  /// The part `propagate` uniquely owns: `state.getData()` is null on the first pass, so it
  /// builds a `ProcessorState` from `RV32IM_STATE` and parks it. Before this landed,
  /// `Rv32imRiscV` inherited `SocInstanceFactory`'s no-op and the slot stayed empty forever.
  @Test("propagate creates and stores the per-run processor state")
  func propagateCreatesInstanceData() throws {
    let f = try makeSocFixture()
    #expect(f.cpuState.pc == 0, "a fresh core starts at its reset vector")

    // Idempotent: a second pass must reuse the same object, not replace it: `CircuitState`
    // keys component data by reference (D4), and a fresh state per pass would discard the
    // register file on every propagation.
    let factory = try #require(f.cpu.factory as? Rv32imRiscV)
    try factory.propagate(try #require(f.root.socInstanceState(for: f.cpu)))
    #expect(f.root.socComponentData(for: f.cpu) as? Rv32imProcessorState === f.cpuState)
  }

  /// **The end-to-end run.** Two `addi`s written into SoC memory over the bus, fetched back by
  /// the core over the same bus, executed.
  @Test("two instructions written to memory are fetched back and executed")
  func executesAProgramFromMemory() throws {
    let f = try makeSocFixture()
    let port = try #require(f.cpuState.busPort)
    port.circuitState = f.root

    try port.write(addi(rd: 1, rs1: 0, imm: 5), at: 0, size: .word)
    try port.write(addi(rd: 2, rs1: 1, imm: 3), at: 4, size: .word)

    // `SocUpSimulationState` starts HALTED_BY_STOP; the run button is what starts it.
    f.cpuState.simulationState.buttonPressed()
    #expect(f.cpuState.simulationState.canExecute)

    // Two rising edges. `lastClockWasHigh` starts false, so the first `true` is the first edge.
    let first = try f.cpuState.setClock(high: true, circuitState: f.root)
    #expect(first == .executed(pc: 4, jumped: false), "got \(String(describing: first))")
    _ = try f.cpuState.setClock(high: false, circuitState: f.root)
    let second = try f.cpuState.setClock(high: true, circuitState: f.root)
    #expect(second == .executed(pc: 8, jumped: false), "got \(String(describing: second))")

    #expect(f.cpuState.registerValue(1) == 5)
    #expect(f.cpuState.registerValue(2) == 8)
    #expect(f.cpuState.pc == 8)
  }

  /// The disassembly of what was actually fetched. A fetch returning a random word would still
  /// "execute" something; this pins that the core saw the instruction that was stored.
  @Test("the instruction trace records the instruction that was stored, not a random word")
  func traceMatchesTheStoredProgram() throws {
    let f = try makeSocFixture()
    let port = try #require(f.cpuState.busPort)
    port.circuitState = f.root
    let word = addi(rd: 1, rs1: 0, imm: 5)
    try port.write(word, at: 0, size: .word)

    f.cpuState.simulationState.buttonPressed()
    _ = try f.cpuState.setClock(high: true, circuitState: f.root)

    let entry = try #require(f.cpuState.instructionTrace.first)
    #expect(entry.instruction == word, "fetched 0x\(String(entry.instruction, radix: 16))")
    #expect(!entry.isError)

    // `li`, not `addi`, and that is upstream, not the port. `ADDI rd, r0, imm` is the
    // canonical encoding of the `LI` pseudo-instruction, which
    // `RV32imIntegerRegisterImmediateInstructions.java:53-59` lists explicitly:
    //
    //     /* pseudo instructions:
    //      * NOP -> ADDI r0,r0,0
    //      * LI rd,imm -> ADDI rd,r0,imm
    //      …
    //
    // The mnemonic is padded to `ASM_FIELD_SIZE` (10) and `ra` is `registerABINames[1]`. This
    // expectation was written as `addi` first and the port disagreed; the Java settled it.
    #expect(entry.asmText == "li        ra,5", "disassembled as \(entry.asmText)")
  }

  /// A fetch outside every slave's window is a bus error the core reports and halts on, not a
  /// zero word decoded as some instruction. `.fetchError` is Java's `OptionPane` + `simState
  /// .errorInExecution()` path, and the PC must NOT advance.
  @Test("a fetch outside mapped memory halts the core with a bus error")
  func fetchOutsideMemoryIsAnError() throws {
    let f = try makeSocFixture()
    let port = try #require(f.cpuState.busPort)
    port.circuitState = f.root

    // Past the memory's default 1 KiB window.
    f.cpuState.setProgramCounter(0x4000)
    f.cpuState.simulationState.buttonPressed()

    let outcome = try f.cpuState.setClock(high: true, circuitState: f.root)
    guard case .fetchError(let pc, _)? = outcome else {
      Issue.record("expected .fetchError, got \(String(describing: outcome))")
      return
    }
    #expect(pc == 0x4000)
    #expect(f.cpuState.pc == 0x4000, "the PC must not advance past a failed fetch")
    #expect(!f.cpuState.simulationState.canExecute, "errorInExecution must latch the halt")
  }

  /// `Rv32imRiscV.getSlaveInterface` returns the PLIC, which is why the CPU is
  /// `SOC_MASTER | SOC_SLAVE`. Returning `nil` (the inherited default, before this) meant the
  /// PLIC was never registered on any fabric and its whole MMIO window answered NO_RESPONSE.
  @Test("the core's PLIC registers as a bus slave and answers its own MMIO window")
  func plicIsReachableOverTheBus() throws {
    let f = try makeSocFixture()
    let port = try #require(f.cpuState.busPort)
    port.circuitState = f.root

    // The PLIC's enable register 0, at its default base address.
    let enable0 = 0x0C00_0000 + 0x0000_2000
    #expect(throws: Never.self) {
      _ = try port.read(at: enable0, size: .word)
    }

    // And the whole thing has a name rather than upstream's "BUG: Unknown" marker.
    let plic = try #require(f.cpu.attributeSet.getValue(Rv32imAttributes.rv32imPlicState))
    #expect(plic.slaveName != "BUG: Unknown")
    #expect(plic.component === f.cpu)
  }
}
