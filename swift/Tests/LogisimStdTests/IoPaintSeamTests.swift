// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE IO PAINT SEAM, MEASURED RATHER THAN COMPILED
//
// `tools/seamcheck.py` found the ninth instance of this project's signature defect: every io
// component paints through `any IoInstancePainter` (44 call sites across Led, SevenSegment,
// DotMatrix, LedBar, ReptarLocalBus and the rest), and **nothing conformed to that protocol**.
// The concrete painter `CircuitRenderer` builds is `InstancePainter`, and `CircuitRenderer`
// dispatches on `InstancePaintable`, which no io factory conformed to either. Both halves were
// individually valid Swift, so the build was clean and every existing test passed while the
// whole io family was undrawable.
//
// A build cannot see that and neither can a scene-level unit test that only asserts a walker
// ran. So this suite measures: it places real io factories, renders through the real
// `CircuitRenderer`, and asserts on the *painted count* and the *primitive count*. Both were
// zero before the bridge and both are non-zero after.
//
// The `familyBreakdown` test is the general form of the same question and is why the numbers in
// the report are trustworthy: it attributes every component in a circuit to the builtin library
// that owns its factory and reports painted-vs-total per family, so a future family that stops
// dispatching shows up as a named regression rather than as a slightly smaller total.
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
/// `registerAll` writes into two process-global dictionaries that no test target ever unwinds, so
/// the first suite anywhere in the binary to call it changes what every later suite sees. That is
/// already load-bearing for somebody else's assertions, see the note on `corpusIoPaints`, so
/// this suite calls it as late and as rarely as it can: the tests that only inspect factories
/// build `IoLibrary()` directly, which needs no registry at all, and only the two corpus tests
/// that genuinely parse XML register anything.
private let librariesRegistered: Void = {
  StdLibraries.registerAll()
}()

private func ensureLibrariesRegistered() { _ = librariesRegistered }

/// Renders `circuit` through the real walker and reports both halves of the measurement.
///
/// Both numbers matter and neither alone is sufficient: `painted` can rise while the scene stays
/// empty (that is exactly what the stray `builder.reset()` did: 6 painted, 0 primitives), and
/// the scene can be non-empty from the wire layer alone while no component painted at all.
private func measure(_ circuit: Circuit) -> (painted: Int, primitives: Int, total: Int) {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  let context = StaticPaintContext()
  let painted = CircuitRenderer.render(circuit, into: builder, context: context)
  let scene = builder.finish()
  return (painted, scene.primitives.count, circuit.components.count)
}

/// Places one component of each named factory into a fresh circuit, spaced far enough apart that
/// nothing overlaps.
private func circuit(of factories: [any ComponentFactory], named name: String) throws -> Circuit {
  let result = try Circuit(name: name)
  for (index, factory) in factories.enumerated() {
    let attributes = factory.createAttributeSet()
    let component = try factory.createComponent(
      location: Location.create(200 * (index % 8), 200 * (index / 8), hasToSnap: false),
      attributes: attributes)
    try result.mutatorAdd(component)
  }
  return result
}

/// Every io factory this port has, in both io libraries.
///
/// Taken from the libraries rather than written out by hand, so a factory added to `IoLibrary`
/// later is covered automatically instead of silently escaping the gate.
private func ioFactories() -> [any ComponentFactory] {
  return (IoLibrary().tools + ExtraIoLibrary().tools)
    .compactMap { ($0 as? AddTool)?.factory }
}

/// factory name → the builtin library that publishes it, for the family breakdown.
///
/// Keyed by **name**, not by `ObjectIdentifier`, and that is not a style choice. Each loaded
/// `.circ` resolves its libraries through its own `BuiltinLibraryShell`, which materialises its
/// own factory objects, so a factory in a loaded circuit is never the same object as the one a
/// freshly-constructed `IoLibrary()` hands back, and identity keying cannot match across files.
/// Worse, it does not merely miss: the temporary factories built here are released immediately,
/// their addresses get recycled, and `ObjectIdentifier` then *collides* with unrelated live
/// objects. The first run of this breakdown attributed `Adder` and `Multiplexer` to the io
/// family for exactly that reason.
private func familyIndex() -> [String: String] {
  var index: [String: String] = [:]
  let families: [(String, [Tool])] = [
    ("gates", GatesLibrary().tools),
    ("wiring", WiringLibrary().tools),
    ("arithmetic", ArithmeticLibrary().tools),
    ("memory", MemoryLibrary().tools),
    ("io", IoLibrary().tools),
    ("io-extra", ExtraIoLibrary().tools),
    ("plexers", PlexersLibrary().tools),
    ("ttl", TtlLibrary().tools),
    ("fp-arithmetic", FpArithmeticLibrary().tools),
  ]
  for (name, tools) in families {
    for case let add as AddTool in tools {
      index[add.factory.name] = name
    }
  }
  return index
}

private func corpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

// MARK: - The gate

/// `.serialized` because two of these tests walk all 593 corpus files, and running them at once
/// with each other and with the other corpus suites is pure contention for no coverage.
@Suite("Io paint seam", .serialized)
struct IoPaintSeamTests {

  /// The one-line statement of the seam. Before the bridge this was `false` for every io
  /// factory, which is what made 44 painter call sites unreachable.
  @Test("every io factory dispatches through the renderer's protocol")
  func everyIoFactoryIsPaintable() {
    let factories = ioFactories()
    #expect(!factories.isEmpty)
    let unpaintable =
      factories
      .filter { !($0 is any InstancePaintable) }
      .map(\.name)
      .sorted()
    #expect(
      unpaintable.isEmpty,
      "io factories the renderer cannot dispatch to: \(unpaintable.joined(separator: ", "))")
  }

  /// And the same for the painter half: the concrete painter must satisfy the protocol the io
  /// family writes against, or every one of those 44 call sites is dead code.
  @Test("the concrete painter satisfies the io painter protocol")
  func painterConforms() {
    let painter = InstancePainter(
      g: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext())
    // Erased to `Any` on purpose. Written against the concrete type the compiler now folds the
    // test away as "always succeeds", which is the right answer and a useless assertion, since
    // deleting the conformance would delete the warning rather than fail the test.
    let erased: Any = painter
    #expect(erased is any IoInstancePainter)
    // `scene` is the D6 emitter every io draw call goes through; if the bridge exposed a
    // different builder than the one the renderer walks with, geometry would land in a scene
    // nobody rasterises. Identity, not equality.
    #expect((erased as? any IoInstancePainter)?.scene === painter.g)
  }

  @Test("a circuit of io components paints and emits geometry")
  func ioComponentsPaint() throws {
    let factories = ioFactories()
    let result = measure(try circuit(of: factories, named: "io-all"))

    #expect(result.total == factories.count)
    // The measurement the task asked for: this was 0 / 0 before the bridge.
    #expect(
      result.painted == result.total,
      "\(result.painted) of \(result.total) io components painted")
    #expect(
      result.primitives > 0,
      "io components reported painted but emitted no geometry — the empty-scene failure mode")
    print(
      "io paint seam: \(result.painted)/\(result.total) painted, \(result.primitives) primitives")
  }

  /// Per factory, so a single silently-inert component cannot hide inside a healthy total.
  ///
  /// `Telnet` is the one io factory that legitimately draws almost nothing without a live
  /// connection, so the floor is "more than the wire layer", not a per-component pixel count.
  @Test("no single io factory is silently inert")
  func noIoFactoryIsInert() throws {
    var silent: [String] = []
    for factory in ioFactories() {
      let result = measure(try circuit(of: [factory], named: "io-\(factory.name)"))
      if result.painted != 1 || result.primitives == 0 { silent.append(factory.name) }
    }
    #expect(silent.isEmpty, "io factories that emitted nothing: \(silent.joined(separator: ", "))")
  }

  /// The io family drawn against a painter in ghost mode. Upstream's `paintGhost` default is a
  /// no-op, so the assertion is only that nothing traps; a ghost painter has no component, so
  /// every `portValue`, `data` and `drawPorts` call must survive the `nil`.
  @Test("ghost painting an io factory does not trap")
  func ghostPaintingIsSafe() {
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    for factory in ioFactories() {
      guard let paintable = factory as? any InstancePaintable else { continue }
      painter.setFactory(
        factory as? any InstanceFactory, factory.createAttributeSet(),
        at: Location.create(0, 0, hasToSnap: false))
      paintable.paintGhost(painter)
    }
    #expect(painter.isGhost)
  }

  // MARK: Corpus

  /// The measurement the task was specified against: a **real corpus file**, rendered through
  /// the real walker, with the io components counted separately.
  ///
  /// The synthetic circuit above proves the protocols line up. This proves the join survives a
  /// file that came off disk: factories built by a `BuiltinLibraryShell` rather than by a
  /// `new`, attributes parsed from XML rather than defaulted, and a `Circuit` assembled by the
  /// codec. Those are different objects reaching the same cast, and a conformance that lived on
  /// the wrong type would pass the synthetic test and fail here.
  ///
  /// It asserts a floor rather than an exact number so that a component ported later cannot
  /// break it: the claim is "every io component in this circuit painted, and the scene has
  /// geometry", which stays true as other families come online.
  ///
  /// ── A KNOWN, PRE-EXISTING FLAKE THIS TEST SITS NEXT TO ──────────────────────────────────
  ///
  /// Three tests in `LogisimFileTests/ToolPreservationTests`, `…AttributesIsAbsorbed`,
  /// `separatorsAndOrderSurviveTheMixedCase`, `…PreservedVerbatim`, assert the behaviour of a
  /// `#Base` whose `Text Tool` does **not** resolve, which is only true while
  /// `BuiltinToolProviders` is empty. `LogisimFileTests` never registers anything (it cannot;
  /// `LogisimFile` cannot see `LogisimStd`), and nothing ever unwinds a registration, so those
  /// three pass or fail on whether any `LogisimStd` suite happened to call `registerAll()` first.
  ///
  /// Measured, because the first sample was misleading: 2 failures in 24 runs **without** this
  /// suite present, 2 in 16 **with** it. Indistinguishable; the flake is pre-existing and this
  /// suite neither causes nor meaningfully worsens it. Registration is nevertheless confined to
  /// the two tests here that actually parse XML, since the other five only need `IoLibrary()`
  /// directly and touching a global for no reason is not worth defending. The real fix, decide
  /// whether a registered `#Base` should absorb `font` and pin that state explicitly, belongs
  /// to whoever owns D8's tool-preservation rule.
  @Test("a corpus circuit's io components paint")
  func corpusIoPaints() throws {
    guard let corpus = corpusDirectory() else {
      print("LOGISIM_CORPUS unset — corpus io render skipped")
      return
    }
    ensureLibrariesRegistered()
    let ioNames = Set(ioFactories().map(\.name))

    let files =
      (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])

    // The io-densest circuit in the corpus, so the numbers below are about io and not about
    // whatever else happens to be on the canvas.
    // ── THE `file` IS KEPT, AND IT HAS TO BE ────────────────────────────────────────────────
    //
    // Holding only the winning `Circuit` released the `LogisimFile` at the end of each
    // iteration, which takes every OTHER circuit in that file with it: including the
    // subcircuits the winner places. `CircuitSubcircuitFactory.source` and
    // `CircuitAppearance.circuit` are `unowned` by D3 (Java holds a strong two-cycle the GC
    // absorbs and ARC would not), so a placement of a dead sibling left a dangling back-edge and
    // rendering it trapped:
    //
    //     Fatal error: Attempted to read an unowned reference but object … was already destroyed
    //       CircuitAppearance.isDefaultAppearance.getter
    //       CircuitSubcircuitFactory.appearancePlan(for:)
    //
    // It killed the whole test binary rather than failing a test, so no suite after it reported
    // at all. Latent until `SubcircuitPainter` landed: nothing had previously read the appearance
    // during a paint, so the dangling edge was never dereferenced.
    //
    // The product is not exposed this way; a document owns its `LogisimFile` for as long as any
    // of its circuits are reachable. This was the test outliving the owner, not the port.
    var best: (name: String, file: LogisimFile, circuit: Circuit, ioCount: Int)?
    for url in files {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits {
        let ioCount = circuit.components.filter { ioNames.contains($0.factory.name) }.count
        if ioCount > (best?.ioCount ?? 0) {
          best = ("\(url.lastPathComponent)/\(circuit.name)", file, circuit, ioCount)
        }
      }
    }

    let chosen = try #require(best, "no corpus circuit contains an io component")
    let result = measure(chosen.circuit)
    print(
      "corpus io render: \(chosen.name) — \(chosen.ioCount) io of \(result.total) components, "
        + "\(result.painted) painted, \(result.primitives) primitives")

    // Measured on `2.7.1__case-426.circ::Gigatron`, 873 components of which 143 are io, by running this
    // exact test with `IoPaintable: InstancePaintable` reverted to `IoPaintable: AnyObject` and
    // then restored:
    //
    //     before the bridge: 125 painted, 1836 primitives
    //     after  the bridge: 268 painted, 2342 primitives
    //
    // 143 components and 506 primitives, exactly the io count, which is the point of measuring
    // rather than reading the build log, since both states compiled without a diagnostic.
    #expect(result.painted >= chosen.ioCount)
    #expect(result.primitives > 0)
  }

  // MARK: Corpus breakdown

  /// What else is not dispatching, by family.
  ///
  /// Reports rather than asserts for families other than io: this suite owns the io seam, and a
  /// gap elsewhere is somebody else's slice. Printing it is what turns "49 of 249 components
  /// painted" into an actionable list.
  @Test("family breakdown over the corpus")
  func familyBreakdown() throws {
    guard let corpus = corpusDirectory() else {
      print("LOGISIM_CORPUS unset — io paint family breakdown skipped")
      return
    }
    ensureLibrariesRegistered()
    let index = familyIndex()

    var total: [String: Int] = [:]
    var painted: [String: Int] = [:]
    var unpaintedNames: [String: Set<String>] = [:]

    let files =
      (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])

    for url in files {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits {
        for component in circuit.components where !(component is Wire) {
          let factory = component.factory
          // Subcircuit first: a circuit may legitimately be named `ALU` or `7408`, and asking
          // the name index first would file it under the builtin it collides with.
          let family =
            factory is SubcircuitFactory ? "subcircuit" : (index[factory.name] ?? "unresolved")
          total[family, default: 0] += 1
          let draws =
            (component is any ComponentPaintable) || (factory is any InstancePaintable)
          if draws {
            painted[family, default: 0] += 1
          } else {
            unpaintedNames[family, default: []].insert(factory.name)
          }
        }
      }
    }

    guard !total.isEmpty else {
      print("corpus loaded no components — breakdown skipped")
      return
    }

    print("── paint dispatch by family (corpus: \(files.count) files) ──")
    for family in total.keys.sorted() {
      let n = total[family] ?? 0
      let p = painted[family] ?? 0
      let names = (unpaintedNames[family] ?? []).sorted()
      // `unresolved` alone runs to ~900 distinct names (every user circuit that resolved to no
      // builtin), so the list is truncated; the count is the number that matters.
      let shown = names.prefix(12).joined(separator: ", ")
      let missing =
        names.isEmpty
        ? "" : "  — \(names.count) factories, e.g. \(shown)\(names.count > 12 ? ", …" : "")"
      print("  \(family): \(p)/\(n) dispatch\(missing)")
    }
    let allTotal = total.values.reduce(0, +)
    let allPainted = painted.values.reduce(0, +)
    print("  TOTAL: \(allPainted)/\(allTotal)")

    // The one family this suite owns must be complete.
    for family in ["io", "io-extra"] {
      let missing = (unpaintedNames[family] ?? []).sorted().joined(separator: ", ")
      let detail =
        "\(family): \(painted[family] ?? 0)/\(total[family] ?? 0) dispatch — missing \(missing)"
      #expect((painted[family] ?? 0) == (total[family] ?? 0), "\(detail)")
    }
  }
}
