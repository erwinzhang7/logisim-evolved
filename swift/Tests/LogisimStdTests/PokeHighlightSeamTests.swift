// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// SEAM #15, MEASURED RATHER THAN COMPILED
//
// `Instance/InstancePoker.swift` ended with a comment that said `getBounds` and `paint` were
// "intentionally omitted" because `InstancePainter` had not been ported. It had been. So the
// comment described a decision that had expired, over a seam that nothing was holding; the most
// dangerous shape this defect class takes, because a documented gap and an accidental one are
// indistinguishable in code.
//
// The consequence was two layers deep, and neither layer produced a diagnostic:
//
//   1. Nothing called `poker.paint`. Every ported highlight, `RegisterPoker.paint`,
//      `CounterPoker.paint`, `ShiftRegisterPoker.paint`, `Joystick.Poker.paint`,
//      `MemPoker.paint`/`highlightBounds`, was correct and unreachable.
//   2. Nothing could reach a poker at all. `InstanceFactoryBase.instanceFeature` answered `nil`
//      for every key, so `makePoker()`, declared, and overridden by fourteen factories, was
//      called from nowhere in the package, `Component.feature(.pokable)` was `nil` for every
//      stock component, and `PokeTool` therefore never built a caret.
//
// Both states compiled with zero diagnostics and every existing test passed. So this suite does
// not assert that a call returned: it counts scene primitives on either side of the wiring, and
// it walks the same two hops the tool walks (`feature(.pokable)` → `beginPoke` → `paint`).
//
// NUMBERS. Measured on this branch by reverting one thing at a time and re-running. Every
// reverted state built with **zero errors and zero new warnings**, which is the whole reason this
// file measures instead of trusting the build.
//
// (a) The paint half. Comment out the three conformance lines in `InstancePokerPainting.swift`
//     (`extension RegisterPoker: MemPokerPaintable {}` and its two siblings), leaving every
//     poker, every ported `paint(any MemPainter)`/`paint(any IoInstancePainter)`, the whole
//     `PokeOverlayRenderer`, and the reachability fix in place:
//
//                                      without the forward | with it
//       synthetic, the four painters     0 0 0 0 primitives | Register 1, Counter 1,
//                                                             Shift Register 1, Joystick 4
//       corpus (csc258, 2,614 pokable
//         components off disk)           0 highlights, | 1,720 highlights,
//                                        0 primitives        1,735 primitives
//
// (b) The reachability half. Revert `InstanceFactoryFeatures.instanceFeature(key, of: self)` to
//     `nil` in the two places `InstanceFactory.swift` calls it, leaving the paint wired:
//
//                                      without the dispatch | with it
//       factories answering `.pokable`   0 of 14            | 14 of 14
//       corpus pokable components
//         the tool can reach             0 of 2,614         | 2,614 of 2,614
//
// (b) is the deeper of the two: without it not one component in the app could be poked at all:
// not the highlight, the entire input path.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// A minimal `InstanceState`: everything a poker's `beginPoke` reads, and nothing else.
///
/// Deliberately hand-written rather than reusing the simulation module's `InstanceStateImpl`;
/// `LogisimStdTests` depends on `LogisimStd`/`LogisimFile`/`LogisimKernel` only (Package.swift),
/// which is also what keeps this gate runnable without a propagator.
private final class PokeTestState: InstanceState {
  let component: any Component
  private var stored: (any InstanceData)?
  private(set) var invalidations = 0

  init(_ component: any Component) {
    self.component = component
  }

  var attributeSet: any AttributeSet { component.attributeSet }
  var factory: (any InstanceFactory)? { component.factory as? any InstanceFactory }
  var data: (any InstanceData)? { stored }
  func setData(_ value: (any InstanceData)?) { stored = value }
  func portIndex(of port: LogisimStd.Port) -> Int { -1 }
  func portValue(_ index: Int) -> Value { .unknownValue }
  func isPortConnected(_ index: Int) -> Bool { false }
  func setPort(_ index: Int, _ value: Value, _ delay: Int) {}
  var tickCount: Int { 0 }
  var isCircuitRoot: Bool { true }
  func fireInvalidated() { invalidations += 1 }
  var projectOptions: any AttributeSet { AttributeSets.empty }
}

/// Every builtin factory, without touching the process-global builtin registry.
///
/// `StdLibraries.registerAll()` writes into dictionaries no test target unwinds, and the first
/// suite in the binary to call it changes what every later suite sees (the known
/// `ToolPreservationTests` flake, task #34). Nothing here needs a `.circ`, so nothing here
/// registers.
private func pokeCandidateFactories() -> [any ComponentFactory] {
  let libraries: [Library] = [
    MemoryLibrary(), IoLibrary(), ExtraIoLibrary(), WiringLibrary(), GatesLibrary(),
    PlexersLibrary(), ArithmeticLibrary(),
  ]
  return libraries.flatMap { $0.tools.compactMap { ($0 as? AddTool)?.factory } }
}

/// The factories that declare a poker, this port's `setInstancePoker(Class<?>)`.
private func pokerFactories() -> [any InstanceFactory] {
  pokeCandidateFactories().compactMap { $0 as? any InstanceFactory }.filter {
    $0.makePoker() != nil
  }
}

private func placed(_ factory: any ComponentFactory, at x: Int = 200, y: Int = 200) throws
  -> any Component
{
  try factory.createComponent(
    location: Location.create(x, y, hasToSnap: false), attributes: factory.createAttributeSet())
}

/// The poker the *tool* would get, through the same key and the same cast
/// (`LogisimUI/Tools/ToolFeatures.swift`: `let raw = feature(.pokable)` →
/// `raw as? any InstancePoker`). Going through `feature` rather than calling `makePoker()`
/// directly is the point: `makePoker()` was never the broken half.
private func pokerAsToolWouldSeeIt(_ component: any Component) -> (any InstancePoker)? {
  component.feature(.pokable) as? any InstancePoker
}

/// Starts a poke the way `PokeTool.mousePressed` does, scanning the component's own bounds for a
/// point `beginPoke` accepts.
///
/// A scan rather than a hardcoded point because two pokers genuinely reject most of their body:
/// `ShiftRegisterPoker.beginPoke` returns `computeStage(...) >= 0`, so only a click inside a
/// drawn stage starts an edit at all, and that geometry differs between the classic and
/// evolution appearances.
private func beginPokeAnywhere(_ poker: any InstancePoker, _ state: PokeTestState) -> Location? {
  let bds = state.component.bounds
  guard bds.width > 0, bds.height > 0 else { return nil }
  for y in stride(from: bds.y, through: bds.y + bds.height, by: 1) {
    for x in stride(from: bds.x, through: bds.x + bds.width, by: 1) {
      if poker.beginPoke(state, PokeMouseEvent(x: x, y: y)) {
        return Location.create(x, y, hasToSnap: false)
      }
    }
  }
  return nil
}

/// `StdLibraries.registerAll()`, at most once per process, and **only** for the corpus test.
///
/// Same reasoning as `MemPaintSeamTests`': `registerAll` writes into process-global dictionaries
/// no test target unwinds, so the first suite in the binary to call it changes what every later
/// suite sees. Nothing else in this file needs a registry.
private let pokeLibrariesRegistered: Void = {
  StdLibraries.registerAll()
}()

private func ensurePokeLibrariesRegistered() { _ = pokeLibrariesRegistered }

private func pokeCorpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

/// Drives one live poke's highlight through the real driver and reports the scene it produced.
private func measurePoke(
  _ poker: any InstancePoker, _ component: any Component
) -> (reached: Bool, primitives: Int) {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  let reached = PokeOverlayRenderer.render(
    poker: poker, component: component, into: builder, context: StaticPaintContext())
  return (reached, builder.finish().primitives.count)
}

// MARK: - The gate

@Suite("Poke highlight seam")
struct PokeHighlightSeamTests {

  // ── Half one: reachability ────────────────────────────────────────────────────────────────

  /// The one-line statement of the reachability half. Before the fix this was `nil` for **every**
  /// factory in the app, which is why not one of the fourteen ported pokers could ever run: not
  /// just their highlights, their whole input handling.
  @Test("every factory that declares a poker hands one back through the feature key")
  func everyPokerFactoryAnswersTheFeatureKey() throws {
    let factories = pokerFactories()
    #expect(factories.count >= 14, "expected the ported pokers; found \(factories.count)")

    var unreachable: [String] = []
    for factory in factories {
      let component = try placed(factory)
      if pokerAsToolWouldSeeIt(component) == nil { unreachable.append(factory.name) }
    }
    #expect(
      unreachable.isEmpty,
      "factories whose poker the tool cannot obtain: \(unreachable.sorted().joined(separator: ", "))"
    )
    print("poke reachability: \(factories.count) factories declare a poker, all reachable")
  }

  /// Upstream builds a fresh `InstancePokerAdapter`, and therefore a fresh poker, on every
  /// `getFeature(Pokable.class)` (`InstanceFactory.java:220`), i.e. once per mouse-down. Every
  /// poker here carries per-gesture edit state (`RegisterPoker.curValue`,
  /// `ShiftRegisterPoker.loc`), so a cached singleton would leak one component's half-typed value
  /// into the next component poked.
  @Test("each poke gets a fresh poker, as a fresh InstancePokerAdapter would")
  func pokersAreNotShared() throws {
    for factory in pokerFactories() {
      let component = try placed(factory)
      let first = try #require(pokerAsToolWouldSeeIt(component))
      let second = try #require(pokerAsToolWouldSeeIt(component))
      #expect(first !== second, "\(factory.name) reused one poker across two pokes")
    }
  }

  /// `getInstanceFeature` answers exactly one key in 4.1.0's `InstanceFactory` that this port has
  /// a witness for. An implementation that answered every key with the poker would compile and
  /// would hand a poker to the text tool and the wire-repair pass.
  @Test("the feature dispatch answers only the poke key")
  func featureDispatchIsNarrow() throws {
    let component = try placed(Register())
    #expect(component.feature(.pokable) is any InstancePoker)
    for key: ComponentFeatureKey in [.textEditable, .wireRepair, .customHandles, .toolTipMaker] {
      #expect(component.feature(key) == nil, "\(key) should be unanswered")
    }
  }

  // ── Half two: the highlight actually draws ────────────────────────────────────────────────

  /// The measurement the task asked for. Each of these has a fully ported `paint` that was
  /// unreachable; each emits geometry now.
  @Test("a live poke on each painting poker emits geometry")
  func pokeHighlightsEmitGeometry() throws {
    // The four pokers that override `paint` upstream *and* are ported here. The other ten take
    // Java's empty default, which is not a gap, see `InstancePokerPainting.swift`.
    let painting: [any ComponentFactory] = [Register(), Counter(), ShiftRegister(), Joystick()]

    var report: [String] = []
    var silent: [String] = []
    for factory in painting {
      let component = try placed(factory)
      let poker = try #require(
        pokerAsToolWouldSeeIt(component), "\(factory.name) has no reachable poker")
      let state = PokeTestState(component)
      let hit = beginPokeAnywhere(poker, state)
      #expect(hit != nil, "\(factory.name): no point in its bounds starts a poke")

      let result = measurePoke(poker, component)
      report.append("\(factory.name)=\(result.primitives)")
      if !result.reached || result.primitives == 0 { silent.append(factory.name) }
    }
    print("poke highlight primitives: \(report.joined(separator: " "))")
    #expect(
      silent.isEmpty,
      "pokers whose highlight drew nothing: \(silent.sorted().joined(separator: ", "))")
  }

  /// The witness-selection half, isolated.
  ///
  /// `RegisterPoker.paint` takes `any MemPainter` and the protocol requirement takes the concrete
  /// `InstancePainter`. Swift matches a witness on the **static** parameter type and applies no
  /// contravariance, so `InstancePainter: MemPainter` does not make one satisfy the other; the
  /// forward in `MemPokerPaintable` is what connects them. Written against `any InstancePoker` so
  /// the call goes through the witness table, exactly as the driver's does; calling
  /// `RegisterPoker().paint(painter)` on the concrete type would pick the `MemPainter` overload
  /// directly and prove nothing.
  @Test("the memory and io pokers are selected as the paint witness, not the empty default")
  func paintWitnessResolvesToThePortedOverload() throws {
    for factory in [Register(), Counter(), ShiftRegister()] as [any ComponentFactory] {
      let poker = try #require(factory as? any InstanceFactory).makePoker()
      #expect(poker is any MemPokerPaintable, "\(factory.name)'s poker misses the forward")
    }
    #expect(Joystick().makePoker() is any IoPokerPaintable)
  }

  /// `CounterPoker extends RegisterPoker` and overrides **`paint` only**; the counter's caret is
  /// `7 * len + 2` wide at `bds.y + 4`, the register's is `8 * len + 2` at `bds.y`. If the
  /// forward had bound the witness statically to `RegisterPoker.paint`, a counter would draw a
  /// register's caret and every other test here would still pass.
  @Test("CounterPoker's override wins through the forward")
  func counterOverridesRegistersCaret() throws {
    func caret(_ factory: any ComponentFactory) throws -> [ScenePrimitive] {
      let component = try placed(factory)
      let poker = try #require(pokerAsToolWouldSeeIt(component))
      let builder = SceneBuilder(measurer: NominalTextMeasurer())
      _ = poker.beginPoke(PokeTestState(component), PokeMouseEvent(x: 200, y: 200))
      PokeOverlayRenderer.render(
        poker: poker, component: component, into: builder, context: StaticPaintContext())
      return builder.finish().primitives
    }

    let attrs = Counter().createAttributeSet()
    try attrs.setValue(StdAttr.appearance, StdAttr.appearClassic)

    let registerCaret = try caret(Register())
    let counterCaret = try caret(Counter())
    #expect(!registerCaret.isEmpty)
    #expect(!counterCaret.isEmpty)
    // Same component origin, same default width, so identical geometry would mean the counter
    // drew the register's rectangle.
    #expect(
      registerCaret.count != counterCaret.count
        || registerCaret.first?.bounds != counterCaret.first?.bounds,
      "the counter drew the register's caret — the override did not dispatch")
  }

  // ── Defaults, and the ghost case ──────────────────────────────────────────────────────────

  /// Java's default is `painter.getInstance().getBounds()` (`InstancePoker.java:18`), and that is
  /// what `PokeTool.mousePressed` tests the next click against before ending the poke. A poker
  /// that does not override it must report the component's own rectangle, or a second click
  /// anywhere on the component would cancel the edit it just started.
  @Test("the default poke bounds are the component's own bounds")
  func defaultPokeBoundsAreTheComponentBounds() throws {
    let component = try placed(Button())
    let poker = try #require(pokerAsToolWouldSeeIt(component))
    let bounds = PokeOverlayRenderer.highlightBounds(
      poker: poker, component: component,
      scratch: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext())
    #expect(bounds == component.bounds)
    #expect(bounds != .empty)
  }

  /// The pokers that override no `paint` upstream must draw nothing; Java's default body is
  /// empty (`InstancePoker.java:37`). Forwarding those to some other hook would have been the
  /// tempting "fix" and would have put a stray caret on ten components.
  @Test("a poker with no upstream paint draws nothing, as Java's empty default does")
  func nonPaintingPokersDrawNothing() throws {
    let painting: Set<String> = [
      Register().name, Counter().name, ShiftRegister().name, Joystick().name,
    ]
    for factory in pokerFactories() where !painting.contains(factory.name) {
      let component = try placed(factory)
      let poker = try #require(pokerAsToolWouldSeeIt(component))
      let state = PokeTestState(component)
      _ = beginPokeAnywhere(poker, state)
      let result = measurePoke(poker, component)
      #expect(result.reached)
      #expect(result.primitives == 0, "\(factory.name) drew a highlight upstream does not")
    }
  }

  /// The warning carried over from the memory seam: a poke painter has **no component** in the
  /// ghost case, so `data`, `portValue` and `portLocation` are all absent, and
  /// `RegisterPoker.paint`/`ShiftRegisterPoker.paint` read `painter.bounds` while
  /// `MemPoker.paint` reads `painter.data`. Upstream can never reach that state,
  /// `InstancePokerAdapter` is built from an `InstanceComponent` and holds it for life, so the
  /// driver refuses it rather than drawing a live-state caret for a component with no state.
  @Test("a ghost painter is refused, not forwarded")
  func ghostPaintIsRefused() throws {
    let factory = Register()
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    painter.setFactory(factory, factory.createAttributeSet())
    #expect(painter.isGhost)

    let poker = try #require(factory.makePoker())
    let reached = PokeOverlayRenderer.render(poker: poker, with: painter, into: builder)
    #expect(reached == false)
    #expect(builder.finish().primitives.isEmpty)
  }

  /// D13, at the one index this seam can reach out of range. `ShiftRegisterPoker.loc` survives an
  /// attribute edit, so selecting a high stage and then shrinking `ATTR_LENGTH` leaves the poker
  /// pointing past the end. Upstream throws an `ArrayIndexOutOfBoundsException` on the AWT thread
  /// ; the app keeps running and the poke is lost. A Swift trap would take the process and the
  /// user's unsaved circuit with it, so painting past the end must be survivable.
  @Test("a stale shift-register stage does not trap when the highlight is drawn")
  func staleShiftRegisterStageDoesNotTrap() throws {
    let factory = ShiftRegister()
    let attrs = factory.createAttributeSet()
    try attrs.setValue(ShiftRegister.attrLength, 8)
    let component = try factory.createComponent(
      location: Location.create(200, 200, hasToSnap: false), attributes: attrs)
    let poker = try #require(pokerAsToolWouldSeeIt(component))
    let state = PokeTestState(component)
    _ = try #require(beginPokeAnywhere(poker, state), "no point starts a shift-register poke")

    // Shrink the register under the live poke, then draw. `loc` now names a stage that no longer
    // exists.
    try attrs.setValue(ShiftRegister.attrLength, 1)
    let result = measurePoke(poker, component)
    #expect(result.reached)
    // Nothing is asserted about *what* it draws; upstream's own geometry is unbounded above
    // here (see `ShiftRegisterPoker.swift`'s header). The assertion is that we got here at all.
  }

  // MARK: Corpus

  /// The join, survived by components that came off disk.
  ///
  /// Every test above builds its factories with a `new`. This one takes them from a
  /// `BuiltinLibraryShell` materialising a `.circ`, with attributes parsed out of XML: different
  /// objects reaching the same `feature(.pokable)` key. A conformance or a dispatch that lived on
  /// the wrong type would pass everything above and fail here.
  ///
  /// `.serialized` is not needed: this is the only corpus test in the suite, and it registers the
  /// builtin libraries exactly once for the process.
  @Test("a corpus circuit's pokable components are reachable and their highlights draw")
  func corpusPokablesAreReachable() throws {
    guard let corpus = pokeCorpusDirectory() else {
      print("LOGISIM_CORPUS unset — corpus poke render skipped")
      return
    }
    ensurePokeLibrariesRegistered()

    /// "This component's factory declares a poker": asked of the factory itself, not by name.
    ///
    /// A name set was tried first and is wrong: the corpus contains **subcircuits named
    /// `Register` and `Counter`**, whose factory is a `SubcircuitFactory` with no poker, and they
    /// were reported as an unreachable seam. `makePoker()` was never the broken half of #15, so
    /// asking it here and then asserting on `feature(.pokable)` still discriminates exactly the
    /// dispatch that was missing.
    func declaresPoker(_ component: any Component) -> Bool {
      (component.factory as? any InstanceFactory)?.makePoker() != nil
    }

    let files =
      (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])

    var pokableSeen = 0
    var unreachable: Set<String> = []
    var primitives = 0
    var painting = 0
    for url in files {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits {
        for component in circuit.components where declaresPoker(component) {
          pokableSeen += 1
          guard let poker = pokerAsToolWouldSeeIt(component) else {
            unreachable.insert(component.factory.name)
            continue
          }
          _ = beginPokeAnywhere(poker, PokeTestState(component))
          let result = measurePoke(poker, component)
          primitives += result.primitives
          if result.primitives > 0 { painting += 1 }
        }
      }
    }

    print(
      "corpus poke seam: \(pokableSeen) pokable components, \(painting) with a highlight, "
        + "\(primitives) primitives")
    #expect(pokableSeen > 0, "no corpus circuit contains a pokable component")
    let unreachableList = unreachable.sorted().joined(separator: ", ")
    #expect(
      unreachable.isEmpty,
      "corpus components whose poker the tool cannot obtain: \(unreachableList)")
    // A floor on the total is not enough on its own, most pokers correctly draw nothing, so the
    // per-component reachability check above is the real assertion and this is the geometry one.
    #expect(primitives > 0, "not one corpus poke emitted geometry")
  }
}
