// MoveGesture.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.MoveGesture),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - Circuit snapshot

/// The read-only view of the circuit that the connector thread works from.
///
/// **This is a deliberate deviation from upstream, and it is the safety-critical one.** Java's
/// `MoveGesture` keeps a live `Circuit` reference and the connector thread calls
/// `circuit.getComponents(loc)`, `getNonWires()` and `getWires()` on it while the EDT is free to
/// keep editing; an unsynchronised cross-thread read of a mutable model, held together only by
/// the fact that a user cannot usually mutate a circuit and drag it at the same time. Under ARC
/// the same pattern is worse than a stale read: concurrent access to a `Dictionary` or `Array`
/// while another thread mutates it corrupts memory rather than returning an old value.
///
/// So the gesture snapshots what it needs **on the main actor, at construction**, into immutable
/// storage. This is behaviourally identical under upstream's own contract, the circuit is not
/// mutated during a drag, which is exactly why upstream gets away with it, and it removes the
/// race instead of porting it. It also means the tools do not need `Circuit.getComponents(Location)`
/// from M3 in order to work: the point index is built once, here.
///
/// `@unchecked Sendable` still, because it holds `any Component`, which D4 makes a non-`Sendable`
/// class. The unchecked part is the *component objects*, which the engine only reads geometry
/// from (`bounds`, `ends`, `contains`) and never mutates.
public struct MoveCircuitSnapshot: @unchecked Sendable {

  /// `circuit.getNonWires()`, in circuit order.
  public let nonWires: [any Component]
  /// `circuit.getWires()`, in circuit order.
  public let wires: [Wire]

  /// `CircuitPoints`' location index: every component that has an *end* at a point. See
  /// `CircuitPointQueries` for why "end at", not "passes through", is the right rule.
  private let componentsByEnd: [Location: [any Component]]

  @MainActor
  public init(circuit: Circuit) {
    let nonWires = circuit.nonWires
    let wires = circuit.wires
    self.nonWires = nonWires
    self.wires = wires

    var index: [Location: [any Component]] = [:]
    // Non-wires first, then wires, which is the order `Circuit.components` presents and the
    // closest deterministic stand-in for the order components reached `CircuitPoints`. Every
    // consumer in this engine is order-insensitive, see `findWire`, so the choice is about
    // reproducibility, not about matching a specific Java run.
    for component in nonWires {
      for end in component.ends {
        index[end.location, default: []].append(component)
      }
    }
    for wire in wires {
      index[wire.end0, default: []].append(wire)
      index[wire.end1, default: []].append(wire)
    }
    self.componentsByEnd = index
  }

  /// `Circuit.getComponents(Location)`.
  public func components(at location: Location) -> [any Component] {
    componentsByEnd[location] ?? []
  }

  /// Everything in the circuit, non-wires then wires, `Circuit.getComponents()`.
  public var allComponents: [any Component] {
    var all: [any Component] = nonWires
    all.append(contentsOf: wires.map { $0 as any Component })
    return all
  }
}

// MARK: - MoveGesture

/// `com.cburch.logisim.tools.move.MoveGesture`: one drag of a selection, and the cache of
/// reroute results computed for it so far.
///
/// The lifetime is exactly one drag: `SelectTool` creates it on the first move with connections
/// enabled and drops it on release (`SelectTool.java:305-313, 522`). That is what makes the
/// snapshot above sound, and what makes caching by delta worthwhile: a drag revisits the same
/// delta constantly as the pointer jitters on the grid.
public final class MoveGesture: @unchecked Sendable {

  private let listener: MoveRequestListener?
  private let snapshot: MoveCircuitSnapshot

  /// `selected`. Upstream keeps a `HashSet<Component>`; this keeps an ordered array plus an
  /// identity set, because the *order* is observable through `AvoidanceMap.markAll` and Java's is
  /// an identity-hash order that is not reproducible across runs. See `AvoidanceMap.markAll`.
  let selected: [any Component]
  private let selectedIdentities: Set<ObjectIdentifier>

  /// `connections`, `initAvoid`: both `transient` and lazily computed upstream, and both
  /// computed on the connector thread. The lock below is what makes that safe here.
  private var connectionsStorage: [ConnectionData]?
  private var fixedAvoidanceStorage: AvoidanceMap?

  /// `cachedResults`, and the monitor upstream synchronises on. `NSCondition` is the direct
  /// analogue of a Java monitor: `lock`/`unlock` are `synchronized`, `wait`/`broadcast` are
  /// `Object.wait`/`notifyAll`.
  private let resultsCondition = NSCondition()
  private var cachedResults: [MoveRequest: MoveResult] = [:]

  /// `MoveGesture(MoveRequestListener, Circuit, Collection<Component>)`.
  ///
  /// `@MainActor` because it snapshots the circuit; everything afterwards is thread-agnostic.
  @MainActor
  public init(
    listener: MoveRequestListener?, circuit: Circuit, selected: [any Component]
  ) {
    self.listener = listener
    self.snapshot = MoveCircuitSnapshot(circuit: circuit)
    // Deduplicate by identity while preserving order, which is what `new HashSet<>(selected)`
    // does minus the ordering nondeterminism.
    var identities: Set<ObjectIdentifier> = []
    var ordered: [any Component] = []
    for component in selected where identities.insert(ObjectIdentifier(component)).inserted {
      ordered.append(component)
    }
    self.selected = ordered
    self.selectedIdentities = identities
  }

  func isSelected(_ component: any Component) -> Bool {
    selectedIdentities.contains(ObjectIdentifier(component))
  }

  // MARK: Requests

  /// `enqueueRequest(int, int)`; returns true when the request was actually queued, i.e. when
  /// there was no cached answer. `SelectTool` uses that to decide whether to show the "computing"
  /// message.
  @discardableResult
  public func enqueueRequest(dx: Int, dy: Int) -> Bool {
    let request = MoveRequest(self, dx, dy)
    resultsCondition.lock()
    let cached = cachedResults[request]
    resultsCondition.unlock()
    if cached == nil {
      ConnectorThread.enqueue(request, priority: false)
      return true
    }
    return false
  }

  /// `findResult(int, int)`: the cached answer, or nil while it is still being computed.
  public func findResult(dx: Int, dy: Int) -> MoveResult? {
    let request = MoveRequest(self, dx, dy)
    resultsCondition.lock()
    defer { resultsCondition.unlock() }
    return cachedResults[request]
  }

  /// The cached answer for this gesture whose delta is **nearest** `(dx, dy)`, or nil when nothing
  /// has been computed yet. Exact hits win, so this is a strict superset of `findResult`.
  ///
  /// ── A DELIBERATE DIVERGENCE FROM 4.1.0 ──────────────────────────────────────────────────────
  ///
  /// Upstream has no equivalent and could not use one: `MoveGesture.findResult` is
  /// `monitorenter; HashMap.get; monitorexit; areturn` and nothing else (4.1.0 jar, `javap -c
  /// com.cburch.logisim.tools.move.MoveGesture`, offsets 11-33), and `SelectTool.draw` branches
  /// straight past all drawing when it answers null (`ifnull` at offset 78). Upstream draws the
  /// exact delta's route or no route at all.
  ///
  /// This exists because the *cache* is the asymmetry the reroute bug report is about, and the
  /// cache is upstream's too (`enqueueRequest` offsets 19-46: `HashMap.get`, and only on null
  /// `ConnectorThread.enqueueRequest(req, false)`). A delta the drag has already visited answers
  /// instantly from this map; a delta it has not must wait for a single, process-wide,
  /// one-slot-latest-wins connector thread. So dragging back over ground already covered is exact
  /// and dragging into new ground is not, which is precisely "other direction works fine, if new
  /// bend is closer than the last".
  ///
  /// The connector *does* keep answering while the pointer runs ahead; those answers simply land
  /// under deltas nobody asks for again. Reading the nearest one instead of only the exact one
  /// spends them. Every answer in this map is a real, self-consistent reroute of the same circuit
  /// snapshot for a nearby delta, so choosing by proximity never fabricates geometry; see
  /// `SelectTool.previewResult` for why the alternative (translating a held route onto the ghost)
  /// is worse.
  ///
  /// Ties are broken on `(dx, dy)` lexicographically and **this is not defensive tidying**. The
  /// pointer snaps to the grid and so do the cached deltas, so a query at `dy = 50` with `40` and
  /// `60` computed is an exact tie; every other frame of a steady drag is one. Swift seeds
  /// `Dictionary` hashing per process, so leaving the choice to iteration order picks a different
  /// equidistant reroute on different launches and can flip as the cache grows. Red-probed:
  /// deleting the tie-break failed `nearestResultBreaksTiesDeterministically` on three of six
  /// launches and passed on the other three.
  func nearestResult(dx: Int, dy: Int) -> MoveResult? {
    resultsCondition.lock()
    defer { resultsCondition.unlock() }
    if let exact = cachedResults[MoveRequest(self, dx, dy)] { return exact }

    var best: MoveResult?
    var bestDistance = Int.max
    var bestKey = (dx: 0, dy: 0)
    for (request, result) in cachedResults {
      let distance = wrap32(
        javaAbs(wrap32(request.dx &- dx)) &+ javaAbs(wrap32(request.dy &- dy)))
      let isNearer = distance < bestDistance
      let isTieBreak =
        distance == bestDistance
        && (request.dx, request.dy) < (bestKey.dx, bestKey.dy)
      if isNearer || isTieBreak {
        best = result
        bestDistance = distance
        bestKey = (request.dx, request.dy)
      }
    }
    return best
  }

  /// `forceRequest(int, int)`: jump the queue and **block** until the answer arrives.
  ///
  /// Upstream blocks the EDT here (`MoveGesture.java:134-150`), and it does so on purpose: this
  /// is called from `SelectTool.mouseReleased`, where the result is needed to build the undoable
  /// action, and there is nothing sensible to draw in the meantime. The port keeps that, with one
  /// addition upstream lacks: a ceiling. Java's wait is unbounded, so a connector thread that
  /// dies mid-computation hangs the UI permanently with no diagnostic. `Connector` already caps
  /// its own work at ten seconds, so waiting a little past that and then giving up costs nothing
  /// that was going to succeed.
  ///
  /// The give-up answer is not invented: it is the same one upstream's own `ConnectorThread`
  /// catch-block publishes when a priority request throws; an empty `ReplacementMap` with every
  /// connection reported unsatisfied (`ConnectorThread.java:83-87`). The drag still commits; the
  /// wires simply are not rerouted, and the canvas marks the connections it could not keep.
  public func forceRequest(dx: Int, dy: Int) -> MoveResult {
    let request = MoveRequest(self, dx, dy)
    ConnectorThread.enqueue(request, priority: true)

    let deadline = Date(timeIntervalSinceNow: Connector.maximumSeconds + 2)
    resultsCondition.lock()
    while cachedResults[request] == nil {
      if !resultsCondition.wait(until: deadline) { break }
    }
    let result = cachedResults[request]
    resultsCondition.unlock()

    if let result { return result }
    return MoveResult(
      replacements: ReplacementMap(), unsatisfiedConnections: connections(), totalDistance: 0)
  }

  /// `notifyResult(MoveRequest, MoveResult)`.
  func notifyResult(_ request: MoveRequest, _ result: MoveResult) {
    resultsCondition.lock()
    cachedResults[request] = result
    resultsCondition.broadcast()
    resultsCondition.unlock()
    listener?(self, request.dx, request.dy)
  }

  // MARK: Derived state

  /// `getConnections()`.
  func connections() -> [ConnectionData] {
    resultsCondition.lock()
    defer { resultsCondition.unlock() }
    if let existing = connectionsStorage { return existing }
    let computed = MoveGesture.computeConnections(snapshot: snapshot, gesture: self)
    connectionsStorage = computed
    return computed
  }

  /// `getFixedAvoidanceMap()`: everything in the circuit *except* the selection, marked at its
  /// current position.
  func fixedAvoidanceMap() -> AvoidanceMap {
    resultsCondition.lock()
    defer { resultsCondition.unlock() }
    if let existing = fixedAvoidanceStorage { return existing }
    let others = snapshot.allComponents.filter { !isSelected($0) }
    let computed = AvoidanceMap.create(others, dx: 0, dy: 0)
    fixedAvoidanceStorage = computed
    return computed
  }

  // MARK: Connection discovery

  /// `computeConnections(Circuit, Set<Component>)` (`MoveGesture.java:46-98`).
  ///
  /// Finds every point where the moving selection touches something that is staying put, and
  /// walks back along any chain of plain wires leading to it; that chain is what the reroute is
  /// allowed to shorten or redraw rather than having to route around.
  ///
  /// Two ordering notes. Upstream collects the candidate points into a `HashSet<Location>` and the
  /// results into a `HashSet<ConnectionData>`; `Location` and `ConnectionData` both hash on their
  /// contents, so those two sets *are* reproducible in Java, but the order they are filled in
  /// comes from iterating `HashSet<Component> selected`, which is identity-hashed and is not. The
  /// port uses ordered collections seeded from circuit order throughout, so the connection list is
  /// deterministic end to end. Deduplication still uses upstream's partial `ConnectionData`
  /// equality (location + direction), so the *set* of connections is unchanged.
  private static func computeConnections(
    snapshot: MoveCircuitSnapshot, gesture: MoveGesture
  ) -> [ConnectionData] {
    guard !gesture.selected.isEmpty else { return [] }

    // First identify locations that might be connected.
    var seenLocations: Set<Location> = []
    var locations: [Location] = []
    for component in gesture.selected {
      for end in component.ends where seenLocations.insert(end.location).inserted {
        locations.append(end.location)
      }
    }

    // Now see which of them require connection.
    var seenConnections: Set<ConnectionData> = []
    var connections: [ConnectionData] = []
    for location in locations {
      let touchesSomethingStaying = snapshot.components(at: location).contains {
        !gesture.isSelected($0)
      }
      guard touchesSomethingStaying else { continue }

      var wirePath: [Wire] = []
      var wirePathStart = location
      let lastOnPath = findWire(snapshot: snapshot, at: location, gesture: gesture, ignoring: nil)
      if lastOnPath != nil {
        var current = location
        var wire = lastOnPath
        while let step = wire {
          wirePath.append(step)
          current = step.otherEnd(from: current)
          wire = findWire(snapshot: snapshot, at: current, gesture: gesture, ignoring: step)
        }
        wirePath.reverse()
        wirePathStart = current
      }

      var direction: Direction?
      if let lastOnPath {
        let other = lastOnPath.otherEnd(from: location)
        let dx = wrap32(location.x &- other.x)
        let dy = wrap32(location.y &- other.y)
        direction =
          javaAbs(dx) > javaAbs(dy)
          ? (dx > 0 ? .east : .west)
          : (dy > 0 ? .south : .north)
      }

      let connection = ConnectionData(
        location: location, direction: direction, wirePath: wirePath,
        wirePathStart: wirePathStart)
      if seenConnections.insert(connection).inserted {
        connections.append(connection)
      }
    }
    return connections
  }

  /// `findWire(Circuit, Location, Set<Component>, Wire)` (`MoveGesture.java:100-112`).
  ///
  /// Reads as a loop but is a predicate: it returns a wire only when **exactly one** component at
  /// this point is neither selected nor the wire we arrived on, and that one component is a wire.
  /// Anything else, a component end, a second wire, a junction, returns nil and ends the path.
  /// That reading is what makes it order-independent, which in turn is what lets the snapshot's
  /// index use circuit order rather than having to reproduce `CircuitPoints`' insertion order.
  private static func findWire(
    snapshot: MoveCircuitSnapshot, at location: Location, gesture: MoveGesture, ignoring: Wire?
  ) -> Wire? {
    var found: Wire?
    for component in snapshot.components(at: location) {
      if gesture.isSelected(component) { continue }
      if let ignoring, component === ignoring { continue }
      if found == nil, let wire = component as? Wire {
        found = wire
      } else {
        return nil
      }
    }
    return found
  }
}
