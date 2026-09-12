// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE MEMORY PAINT SEAM, MEASURED RATHER THAN COMPILED
//
// Seam #10, the tenth instance of this project's signature defect. `MemPainter.swift` declared
// `public protocol MemPainter` and the whole memory family drew against it, Ram, Rom, DualRam,
// Register, Counter, ShiftRegister, Random and the four flip-flops each define
// `paintInstance(_ painter: any MemPainter)`, and **nothing conformed to `MemPainter`**. Worse,
// no memory factory conformed to `InstancePaintable`, which is the protocol `CircuitRenderer`
// actually casts to (`component.factory as? any InstancePaintable`, CircuitRenderer.swift:108).
// Both halves were individually legal Swift, so the build was clean and every existing test
// passed while all eleven memory factories drew nothing at all.
//
// Neither a build nor a "the call returned" unit test can see that. So this suite measures: it
// places real memory factories, renders through the real `CircuitRenderer`, and asserts on the
// *painted count* and the *primitive count*, both of which were zero before the bridge.
//
// NUMBERS. Measured on this branch by reverting exactly one token, `MemPaintable:
// InstancePaintable` back to `MemPaintable: AnyObject`, leaving every painter, every
// conformance and the whole `InstancePainter: MemPainter` bridge in place, and re-running:
//
//                                              without the refinement | with it
//   synthetic circuit, all 11 factories        0/11 painted, 0 prims  | 11/11, 617 prims
//   corpus 3.6.0__case-135.circ::RegisterFile      89 painted, 2389 prims | 153 painted, 3925
//   (1719 components, 64 of them memory)
//
// The corpus delta is +64 components and +1536 primitives; 64 is exactly the memory count in
// that circuit. Both states compiled without a single diagnostic, which is the whole reason
// this file measures instead of trusting the build.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// `StdLibraries.registerAll()`, at most once per process, and **only where a `.circ` is loaded**.
///
/// `registerAll` writes into process-global dictionaries no test target ever unwinds, so the
/// first suite in the binary to call it changes what every later suite sees (this is the known
/// `ToolPreservationTests` flake, task #34). The tests below that only inspect factories build
/// `MemoryLibrary()` directly and need no registry at all; only the corpus test registers.
private let memLibrariesRegistered: Void = {
  StdLibraries.registerAll()
}()

private func ensureMemLibrariesRegistered() { _ = memLibrariesRegistered }

/// Renders `circuit` through the real walker and reports both halves of the measurement.
///
/// Both numbers matter and neither alone is sufficient: `painted` can rise while the scene stays
/// empty, and the scene can be non-empty from the wire layer alone while nothing painted.
private func measureMem(_ circuit: Circuit) -> (painted: Int, primitives: Int, total: Int) {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  let context = StaticPaintContext()
  let painted = CircuitRenderer.render(circuit, into: builder, context: context)
  let scene = builder.finish()
  return (painted, scene.primitives.count, circuit.components.count)
}

/// Places one component of each named factory into a fresh circuit, spaced far enough apart that
/// nothing overlaps.
private func memCircuit(of factories: [any ComponentFactory], named name: String) throws -> Circuit
{
  let result = try Circuit(name: name)
  for (index, factory) in factories.enumerated() {
    let attributes = factory.createAttributeSet()
    let component = try factory.createComponent(
      location: Location.create(300 * (index % 8), 300 * (index / 8), hasToSnap: false),
      attributes: attributes)
    try result.mutatorAdd(component)
  }
  return result
}

/// Every memory factory this port has.
///
/// Taken from `MemoryLibrary` rather than written out by hand, so a factory added later is
/// covered automatically instead of silently escaping the gate.
private func memFactories() -> [any ComponentFactory] {
  MemoryLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
}

private func memCorpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

// MARK: - The gate

/// `.serialized` because the corpus test walks every `.circ` on disk, and running it against the
/// other corpus suites at once is pure contention for no coverage.
@Suite("Memory paint seam", .serialized)
struct MemPaintSeamTests {

  /// The one-line statement of the seam. Before the bridge this was `false` for **all eleven**
  /// memory factories, which is what made every `any MemPainter` call site in
  /// `swift/Sources/LogisimStd/Memory/` unreachable.
  @Test("every memory factory dispatches through the renderer's protocol")
  func everyMemoryFactoryIsPaintable() {
    let factories = memFactories()
    #expect(factories.count == 11)
    let unpaintable =
      factories
      .filter { !($0 is any InstancePaintable) }
      .map(\.name)
      .sorted()
    #expect(
      unpaintable.isEmpty,
      "memory factories the renderer cannot dispatch to: \(unpaintable.joined(separator: ", "))")
  }

  /// The painter half. The concrete painter `CircuitRenderer` builds must satisfy the protocol
  /// the memory family writes against, or every one of those call sites is dead code.
  @Test("the concrete painter satisfies the memory painter protocol")
  func painterConformsToMemPainter() {
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    // Erased to `Any` on purpose. Written against the concrete type the compiler folds the
    // check away as "always true": the right answer and a useless assertion, since deleting
    // the conformance would delete the *warning* rather than fail the test.
    let erased: Any = painter
    #expect(erased is any MemPainter)
    // `graphics` is the D6 emitter every memory draw call goes through. If the bridge handed
    // back a different builder than the one the renderer walks, geometry would land in a scene
    // nobody rasterises; the failure mode that produced "6 painted, 0 primitives" on the io
    // side. Identity, not equality.
    #expect((erased as? any MemPainter)?.graphics === builder)
  }

  /// The pen-width contract `MemPainter.swift`'s header documents: `drawBounds`, `drawClock` and
  /// `drawClockSymbol` are `switchToWidth(g, 2); …; switchToWidth(g, 1)` in upstream's
  /// `ComponentDrawContext`: they leave the pen at **width 1**, and `RamAppearance`'s
  /// line-enable/byte-enable stubs are drawn after the clock loop with no stroke of their own.
  ///
  /// `SceneBuilder`'s same-named helpers *restore* the previous width instead, so a bridge that
  /// forwarded straight through would break this. Asserted rather than trusted.
  @Test("the bridge leaves the pen at width 1, as ComponentDrawContext does")
  func penWidthContract() throws {
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let context = StaticPaintContext()
    let painter = InstancePainter(g: builder, context: context)
    let register = Register()
    let attrs = register.createAttributeSet()
    let component = try register.createComponent(
      location: Location.create(100, 100, hasToSnap: false), attributes: attrs)
    painter.setComponent(component)
    let mem: any MemPainter = painter

    for (name, call) in [
      ("drawBounds", { mem.drawBounds() }),
      ("drawClock", { mem.drawClock(0, .east) }),
      ("drawClockSymbol", { mem.drawClockSymbol(100, 100) }),
    ] as [(String, () -> Void)] {
      builder.strokeWidth = 7
      call()
      #expect(builder.strokeWidth == 1, "\(name) left the pen at \(builder.strokeWidth), not 1")
    }
  }

  @Test("a circuit of memory components paints and emits geometry")
  func memoryComponentsPaint() throws {
    let factories = memFactories()
    let result = measureMem(try memCircuit(of: factories, named: "mem-all"))

    #expect(result.total == factories.count)
    // The measurement the task asked for: this was 0 / 0 before the bridge.
    #expect(
      result.painted == result.total,
      "\(result.painted) of \(result.total) memory components painted")
    #expect(
      result.primitives > 0,
      "memory components reported painted but emitted no geometry — the empty-scene failure mode")
    print(
      "mem paint seam: \(result.painted)/\(result.total) painted, \(result.primitives) primitives")
  }

  /// Per factory, so one silently-inert component cannot hide inside a healthy total.
  @Test("no single memory factory is silently inert")
  func noMemoryFactoryIsInert() throws {
    var silent: [String] = []
    var report: [String] = []
    for factory in memFactories() {
      let result = measureMem(try memCircuit(of: [factory], named: "mem-\(factory.name)"))
      report.append("\(factory.name)=\(result.primitives)")
      if result.painted != 1 || result.primitives == 0 { silent.append(factory.name) }
    }
    print("mem per-factory primitives: \(report.joined(separator: " "))")
    #expect(
      silent.isEmpty, "memory factories that emitted nothing: \(silent.joined(separator: ", "))")
  }

  /// Both memory appearances, not just the default one.
  ///
  /// `StdAttr.APPEARANCE` selects between the classic (`AppearanceLogisimEvolution == false`)
  /// and evolution bodies, and the two are entirely separate paint paths:
  /// `RamAppearance.drawRamClassic` vs `drawRamEvolution`, `AbstractFlipFlop.paintInstanceClassic`
  /// vs `paintInstanceEvolution`. A bridge that worked for one and trapped in the other would
  /// pass every test above, since `getDefaultAppearance()` picks only one of them.
  @Test("both appearances paint, for every memory factory")
  func bothAppearancesPaint() throws {
    for appearance in [StdAttr.appearClassic, StdAttr.appearEvolution] {
      var silent: [String] = []
      for factory in memFactories() {
        let attrs = factory.createAttributeSet()
        guard attrs.containsAttribute(StdAttr.appearance) else { continue }
        try attrs.setValue(StdAttr.appearance, appearance)
        let circuit = try Circuit(name: "mem-\(appearance.name)-\(factory.name)")
        try circuit.mutatorAdd(
          try factory.createComponent(
            location: Location.create(200, 200, hasToSnap: false), attributes: attrs))
        let result = measureMem(circuit)
        if result.painted != 1 || result.primitives == 0 { silent.append(factory.name) }
      }
      #expect(
        silent.isEmpty,
        "\(appearance) appearance drew nothing for: \(silent.joined(separator: ", "))")
    }
  }

  /// Ghost painting must not trap. Upstream no memory factory overrides `paintGhost` (checked:
  /// `grep -l paintGhost std/memory/*.java` is empty in 4.1.0), so the inherited no-op is the
  /// correct behaviour, and it is what the bridge deliberately leaves in place rather than
  /// forwarding the ghost to `paintInstance`, which would draw a live-state body for a component
  /// that has no state.
  @Test("ghost painting a memory factory is a no-op and does not trap")
  func ghostPaintingIsSafe() {
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    let before = builder.finish().primitives.count
    for factory in memFactories() {
      guard let paintable = factory as? any InstancePaintable else { continue }
      painter.setFactory(
        factory as? any InstanceFactory, factory.createAttributeSet(),
        at: Location.create(0, 0, hasToSnap: false))
      paintable.paintGhost(painter)
    }
    #expect(painter.isGhost)
    #expect(builder.finish().primitives.count == before)
  }

  // MARK: Corpus

  /// The join, survived by a file that came off disk.
  ///
  /// The synthetic circuits above prove the protocols line up on factories built by a `new`.
  /// This proves it for factories materialised by a `BuiltinLibraryShell` from a `.circ`, with
  /// attributes parsed out of XML: different objects reaching the same cast, and a conformance
  /// that lived on the wrong type would pass everything above and fail here.
  @Test("a corpus circuit's memory components paint")
  func corpusMemoryPaints() throws {
    guard let corpus = memCorpusDirectory() else {
      print("LOGISIM_CORPUS unset — corpus memory render skipped")
      return
    }
    ensureMemLibrariesRegistered()
    let memNames = Set(memFactories().map(\.name))

    let files =
      (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])

    // The memory-densest circuit in the corpus, so the numbers below are about memory and not
    // about whatever else happens to be on the canvas.
    // The `file` is kept deliberately: holding only the winning `Circuit` releases every OTHER
    // circuit in that file, including the subcircuits the winner places, and the `unowned` D3
    // back-edges on `CircuitSubcircuitFactory.source` / `CircuitAppearance.circuit` then trap
    // during paint. See the full account in `IoPaintSeamTests.corpusIoPaints`, where this shape
    // took down the whole test binary.
    var best: (name: String, file: LogisimFile, circuit: Circuit, memCount: Int)?
    for url in files {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits {
        let memCount = circuit.components.filter { memNames.contains($0.factory.name) }.count
        if memCount > (best?.memCount ?? 0) {
          best = ("\(url.lastPathComponent)/\(circuit.name)", file, circuit, memCount)
        }
      }
    }

    let chosen = try #require(best, "no corpus circuit contains a memory component")
    let result = measureMem(chosen.circuit)
    print(
      "corpus memory render: \(chosen.name) — \(chosen.memCount) memory of \(result.total) "
        + "components, \(result.painted) painted, \(result.primitives) primitives")

    // A floor like `painted >= memCount` is NOT enough, and that was measured rather than
    // assumed: with the fix reverted this circuit still reported 89 painted (the gates, wiring
    // and plexers around the memory) against 64 memory components, so `89 >= 64` passed while
    // every memory component drew nothing. The assertion has to be per-component.
    let undispatched =
      Set(
        chosen.circuit.components
          .filter { memNames.contains($0.factory.name) }
          .filter { !($0.factory is any InstancePaintable) }
          .map(\.factory.name))
    let undispatchedList = undispatched.sorted().joined(separator: ", ")
    #expect(
      undispatched.isEmpty,
      "memory components in \(chosen.name) the renderer cannot dispatch to: \(undispatchedList)")
    #expect(result.painted >= chosen.memCount)
    #expect(result.primitives > 0)
  }
}
