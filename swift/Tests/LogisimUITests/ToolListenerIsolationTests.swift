// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// D1'S COROLLARY, IN THE THREE PLACES `Tools/` STILL GOT IT WRONG
//
// `decisions.md` D1 corollary: a kernel callback crossing into a `@MainActor` type must HOP,
// never assert. `MainActor.assumeIsolated` is an assertion; off the main thread it traps the
// whole process with `EXC_BREAKPOINT`, **and no test failure is reported, because the test binary
// dies with it.** That is what makes this defect class so expensive: the usual signal, a red
// assertion, is unavailable, and the usual reasoning ("circuits are only mutated from the main
// actor") is true right up until subcircuit propagation makes it false.
//
// Three `CircuitListener`s in `Tools/` were still asserting when this suite was written:
//
//   * `CircuitPokeListener` (`PokeTool.swift`): registered on the poked circuit for the whole
//     life of a poke.
//   * `TextCaretListener` (`TextTool.swift`).
//   * `EditToolListener` (`EditTool.swift`); registered for as long as `EditTool` is selected,
//     which in the app is most of the time.
//
// All three filtered for the actions they cared about *inside* the isolated closure, so the
// assertion fired before the filter could reject an event they did not even want. And
// `.invalidate` is exactly the reachable one: `InstanceComponent.fireInvalidated()` posts it, and
// `SubcircuitPropagation.substate` reaches that from the **simulation thread**. The identical bug
// was already found twice: `LogisimFileProjectHost.observeCircuit` and
// `CircuitCanvasSurface`'s relay both carry a comment about it.
//
// So this suite fires real circuit events from a real background thread. Note what a failure
// looks like: **the test process dies**, taking the rest of the run with it. That is a louder
// signal than a red assertion, not a quieter one, and it is the only signal available.
//
// MEASURED, by reverting all three listeners to `MainActor.assumeIsolated` and re-running:
//
//   swift test --filter ToolListenerIsolation
//     ◇ Suite "Tool listener isolation" started.
//     ◇ Test "a kernel .invalidate … does not kill the poke tool" started.
//     error: … swiftpm-testing-helper … exited with unexpected signal code 5
//
//   The run stops mid-sentence at the FIRST test: **0 tests reported, 0 failures recorded**, no
//   results written, and every later suite in the binary never runs. That is the whole hazard in
//   one line of output: a green `swift test` and a dead process look nothing alike, but a *newly
//   added listener with this bug* and *no listener at all* look identical until something
//   propagates.
//
//   With `onMainActor`: 3 tests in 1 suite passed after 0.132 seconds.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

/// Fires `body` on a genuine background thread and waits for it to return.
///
/// A `Thread` rather than `DispatchQueue.global().async`: the propagation thread is a real
/// `Thread` (D1 keeps the kernel out of Swift Concurrency entirely), and a cooperative-pool
/// thread is not the same object of study; `assumeIsolated` calls
/// `dispatch_assert_queue(main_queue)`, so what matters is that the caller is not on the main
/// queue, and a `Thread` guarantees that unambiguously.
private func onABackgroundThread(_ body: @escaping @Sendable () -> Void) {
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    body()
    done.signal()
  }
  thread.start()
  done.wait()
}

@Suite("Tool listener isolation", .serialized)
struct ToolListenerIsolationTests {

  @Test("a kernel .invalidate from the propagation thread does not kill the poke tool")
  @MainActor
  func pokeListenerSurvivesOffMainInvalidate() async throws {
    let rig = try PokeRig()

    // The event that actually reaches a live poke from the simulation thread. Before the fix
    // this line trapped: the assertion is outside the `.remove`/`.clear` filter, so an action
    // the listener explicitly ignores still killed the process.
    // `Circuit` is not `Sendable` (D1 keeps the kernel in Swift 5 mode), and neither is a
    // `Component`. Boxing is the sanctioned shape here for the same reason the three listeners
    // box their event: the kernel genuinely does hand these across this boundary, and the box
    // says so out loud instead of hiding it behind `@preconcurrency`.
    let boxed = UncheckedSendableBox(rig.circuit)
    onABackgroundThread {
      boxed.value.fireEvent(.invalidate, .none)
    }
    await settle()

    // The caret is untouched: `.invalidate` is not one of the two actions that end a poke.
    #expect(rig.canvas.overlayResult.pokeScene != nil)
  }

  @Test("and the hop still DELIVERS — a removal from off-main drops the caret")
  @MainActor
  func pokeListenerStillDeliversFromOffMain() async throws {
    let rig = try PokeRig()
    #expect(rig.canvas.overlayResult.pokeScene != nil)

    // Take the component out for real, then post the event the way the kernel does. This is the
    // positive half: a hop that never arrives would leave the caret in place and look exactly
    // like a hop that arrived and was correctly ignored.
    try rig.circuit.mutatorRemove(rig.register)
    let boxed = UncheckedSendableBox((circuit: rig.circuit, component: rig.register))
    onABackgroundThread {
      boxed.value.circuit.fireEvent(.remove, .component(boxed.value.component))
    }
    await settle()

    rig.canvas.setToolOverlay(rig.canvas.controller.activeTool.overlay(for: rig.canvas))
    #expect(rig.canvas.overlayResult.pokeScene == nil)
    #expect(rig.canvas.overlayResult.primitiveCount == 0)
  }

  @Test("EditTool's listener survives the same event, and it is the one always registered")
  @MainActor
  func editToolListenerSurvivesOffMainInvalidate() async throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: EditTool(select: SelectTool(), wiring: WiringTool()))

    // `select` is what registers `EditToolListener` on the circuit; `CanvasToolController.init`
    // has already called it, so the subscription is live exactly as it is in the app.
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: .moved, world: .init(x: 100, y: 100),
        modifiers: [], clickCount: 0, buttonNumber: 0, dragOriginWorld: nil))

    let boxed = UncheckedSendableBox(circuit)
    onABackgroundThread {
      boxed.value.fireEvent(.invalidate, .none)
    }
    await settle()

    // Nothing to assert about the tool's state; `EditTool.invalidate` only drops a cache. The
    // assertion is that we got here at all, plus that the canvas is still usable afterwards.
    canvas.repaintAll()
    #expect(canvas.repaintAllCount > 0)
  }
}

/// Lets `onMainActor`'s `DispatchQueue.main.async` arm run before the assertions.
///
/// `onMainActor` stays synchronous when it is already on the main queue and hops otherwise, so
/// an event posted from a background thread is delivered on a later turn of the main queue.
/// Suspending here is what gives that turn a chance to happen; a synchronous test would assert
/// on the state *before* the hop and read a green result for a listener that never fires.
private func settle() async {
  for _ in 0..<10 {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
}

// MARK: - Rig

/// A live poke: a Register, a fake `ToolCircuitState`, and a caret already open on it.
@MainActor
private struct PokeRig {
  let circuit: Circuit
  let canvas: CircuitEditorCanvas
  let register: any Component

  init() throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: PokeTool())

    let factory = try #require(
      MemoryLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
        .first { ($0 as? any InstanceFactory)?.makePoker() is RegisterPoker })
    register = try factory.createComponent(
      location: Location.create(200, 200, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(register)

    canvas.circuitState = PokeOnlyCircuitState(component: register)

    let point = try #require(pokePoint(of: register))
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: .down,
        world: .init(x: CGFloat(point.x), y: CGFloat(point.y)),
        modifiers: [], clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
  }
}

@MainActor
private func pokePoint(of component: any Component) -> Location? {
  let box = component.bounds
  guard box.width > 0, box.height > 0 else { return nil }
  for y in stride(from: box.y, through: box.y + box.height, by: 1) {
    for x in stride(from: box.x, through: box.x + box.width, by: 1) {
      let point = Location.create(x, y, hasToSnap: false)
      if component.contains(point) { return point }
    }
  }
  return nil
}

@MainActor
private final class PokeOnlyCircuitState: ToolCircuitState {
  private let component: any Component
  private let state: PokeOnlyInstanceState

  init(component: any Component) {
    self.component = component
    self.state = PokeOnlyInstanceState(component)
  }

  func value(at location: Location) -> Value? { nil }
  func instanceState(for component: any Component) -> (any InstanceState)? {
    component === self.component ? state : nil
  }
}

private final class PokeOnlyInstanceState: InstanceState {
  let component: any Component
  private var stored: (any InstanceData)?

  init(_ component: any Component) { self.component = component }

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
  func fireInvalidated() {}
  var projectOptions: any AttributeSet { AttributeSets.empty }
}
