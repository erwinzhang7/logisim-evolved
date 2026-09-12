//
//  PropagationEvent.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16), read from `upstream-java-4.1.0`, NOT from main.
//
//  ---------------------------------------------------------------------------------------
//  What this file is
//
//  The small value/helper types that `Propagator` owns, plus the protocol seams it needs for
//  types that live in modules `LogisimKernel` cannot see (D9 keeps the kernel below
//  `LogisimFile`, so `CircuitState`, `Component`, `Wire`, `Splitter`, `SubcircuitFactory`,
//  `Options` and `Simulator` are all *above* us and can only be reached through protocols).
//
//    * `PropagationEvent` : `Propagator.SimulatorEvent` (`circuit/Propagator.java:56-88`)
//                            fused with its superclass `util/QNode.java`.
//    * `PropagationPoints`: `circuit/PropagationPoints.java`, minus every drawing method (D9).
//    * the seams         : `PropagatorComponent`, `PropagatorCircuitState`,
//                           `PropagatorOptionsSource`, `PropagatorOptionsObserver`,
//                           `PropagationProgressListener`.
//
//  NOTE on 4.1.0 vs 3.x: there is **no `SetData` class in 4.1.0**. The linked-list
//  `SetData`/`ComponentPoint` machinery of older Logisim was replaced by
//  `SimulatorEvent extends QNode`. Do not port `SetData`; it does not exist in the target.
//  ---------------------------------------------------------------------------------------
//

import Foundation

// MARK: - Errors (D13)

/// Errors the propagation engine raises.
///
/// D13: a Java exception reachable from the propagation path becomes a Swift `throw`, never a
/// trap. `Simulator.java:515`, `:538` and `:554` wrap propagation in `catch (Exception err)`,
/// so in the Java a misbehaving component produces a *circuit error the user sees*. A
/// `fatalError` here would convert that into an app crash with unsaved work lost.
public enum PropagationError: Error, CustomStringConvertible {
  /// `throw new RuntimeException("Propagate called with incorrect thread")`
  /// (`Propagator.java:184`, `:221`, `:290`). The message text is reproduced verbatim because
  /// it reaches `recordException` and is user-visible.
  case wrongThread(String)

  public var description: String {
    switch self {
    case let .wrongThread(message): return message
    }
  }
}

// MARK: - Seam: the component that caused a value change

/// The two questions `Propagator` asks of a `Component`: nothing more.
///
/// **Seam.** `com.cburch.logisim.comp.Component`, `circuit/Wire`, `circuit/Splitter` and
/// `circuit/SubcircuitFactory` all live in `LogisimFile`, which depends on `LogisimKernel`
/// rather than the other way round (D9). Rather than reach across, the engine codes against
/// the two predicates it actually uses.
public protocol PropagatorComponent: AnyObject {
  /// `cause instanceof Wire || cause instanceof Splitter` (`Propagator.java:253`).
  ///
  /// Wires and splitters do not schedule delayed events; their values are resolved by
  /// `CircuitWires` during `processDirtyPoints`. Returning `true` makes `setValue` a no-op for
  /// this component, which is exactly upstream's early return.
  var isWireOrSplitter: Bool { get }

  /// `cause.getFactory() instanceof SubcircuitFactory` (`Propagator.java:274`).
  ///
  /// Subcircuit components are exempt from the oscillation noise injection: adding a random
  /// extra step to a subcircuit's own boundary would perturb the child's schedule rather than
  /// the gate the noise is meant to jitter.
  var isSubcircuitComponent: Bool { get }
}

// MARK: - Seam: the simulation options

/// Which `<options>` attribute changed. Mirrors the two `Options` attributes
/// `Propagator.Listener` reacts to (`Propagator.java:48-51`).
public enum PropagatorSimulationOption: Sendable {
  /// `Options.ATTR_SIM_RAND`, `simrand`.
  case randomness
  /// `Options.ATTR_SIM_LIMIT`, `simlimit`.
  case limit
}

/// Notified when one of the two simulation options changes.
///
/// **D3.** The conformer supplied by `Propagator` holds its propagator **weakly**, exactly as
/// `Propagator.Listener` holds a `WeakReference<Propagator>` (`Propagator.java:32`). That is
/// what lets the options source retain the observer strongly, as Java's `AttributeSet` does,
/// without pinning the whole circuit.
public protocol PropagatorOptionsObserver: AnyObject {
  func simulationOptionChanged(_ option: PropagatorSimulationOption)
}

/// The `<options>` attribute set, as the propagator sees it.
///
/// **Seam.** `com.cburch.logisim.file.Options` lives in `LogisimFile`. Upstream reaches it as
/// `root.getProject().getOptions().getAttributeSet()` (`Propagator.java:138`, `:343`, `:354`);
/// the port asks the state tree for this protocol instead.
public protocol PropagatorOptionsSource: AnyObject {
  /// `getValue(Options.ATTR_SIM_LIMIT)`. Java default is `1000`.
  var simulationLimitOption: Int { get }

  /// `getValue(Options.ATTR_SIM_RAND)`. Java default is `0` (randomness off). The value the
  /// preferences dialog installs when randomness is switched *on* is `32`.
  var simulationRandomnessOption: Int { get }

  /// `addAttributeListener`. Per D5 the set is expected to hold the observer weakly and the
  /// caller to retain it; per D3 the observer here holds the propagator weakly, so either
  /// arrangement is leak-free.
  func addSimulationOptionsObserver(_ observer: any PropagatorOptionsObserver)

  /// `removeAttributeListener`, used by the self-eviction path when the propagator is gone
  /// (`Propagator.java:47`).
  func removeSimulationOptionsObserver(_ observer: any PropagatorOptionsObserver)
}

// MARK: - Seam: the circuit state tree

/// The `CircuitState` operations `Propagator` performs, and nothing else.
///
/// **Seam.** `circuit/CircuitState.java` is M3 work owned by another slice and will live in
/// `LogisimFile`. Every call `Propagator.java` makes on `root` or on `ev.state` is listed here:
///
/// | Java | here |
/// |---|---|
/// | `root.processDirtyPoints()` | `processDirtyPoints()` |
/// | `root.processDirtyComponents()` | `processDirtyComponents()` |
/// | `root.reset()` | `resetStateTree()` |
/// | `root.toggleClocks(halfClockCycles)` | `toggleClocks(_:)` |
/// | `state.markPointAsDirty(ev)` | `markPointAsDirty(_:)` |
/// | `newState.getPropagator()` | `owningPropagator` |
/// | `root.getProject().getOptions().getAttributeSet()` | `simulationOptions` |
///
/// **D3; ownership across this seam. Settled: the state owns the propagator.**
///
/// ```
/// CircuitState --(strong)--> Propagator --(weak)--> root CircuitState
/// ```
///
/// The conformer holds its propagator **strongly**; `Propagator.root` is **weak**. This is a
/// deliberate deviation from D3's letter, which lists `base` (the state's propagator field)
/// among the weak edges. D3's arrangement cannot be implemented: `CircuitState`'s
/// `createRootState(project:circuit:)` and `cloneAsNewRootState()` each construct a propagator
/// inside the initializer and hand back **only the state**, with no `Simulator` in the picture
/// (a clone is not attached to one). With the state's edge weak, the propagator would have a
/// zero strong count the instant the initializer returned; the returned state's engine would
/// already be dead. Breaking the propagator's back-edge instead dangles nothing and leaks
/// nothing, and it is the direction the `CircuitState` slice implements
/// (`CircuitState.swift`'s header note, `ComponentState.swift`'s `SimPropagator` contract).
///
/// `Propagator.root` is `weak` rather than `unowned` because a *detached* substate keeps its
/// old propagator strongly (upstream nulls `parentState`, not `base`), and such a substate can
/// outlive the root; e.g. held by an undo action. An `unowned` root would then trap when the
/// options listener fires; `weak` reads `nil` and the propagator no-ops, per D13.
public protocol PropagatorCircuitState: AnyObject {
  /// `CircuitState.getPropagator()`. **Must be a strong stored reference** (D3, above).
  ///
  /// Named `owningPropagator`, not `propagator`, for the same defensive reason
  /// `resetStateTree()` is not called `reset()`: the `CircuitState` slice already exposes
  /// `var propagator: any SimPropagator` (non-optional, its own seam type), and two properties
  /// of the same name and different type cannot coexist on one class. A distinct name makes the
  /// conformance a four-line extension instead of a redesign of one slice or the other.
  var owningPropagator: Propagator? { get }

  /// `root.getProject().getOptions()`.
  ///
  /// Optional purely so a state tree can exist without a `Project` (the headless CLI path).
  /// When `nil`, `Propagator` falls back to Java's own defaults, `simlimit = 1000`,
  /// `simrand = 0`, which are what a freshly constructed `Options` carries, so the fallback
  /// cannot diverge from upstream for a default project. **A conformer that has a project must
  /// return its options here**, or a file setting `simrand`/`simlimit` will be silently ignored.
  var simulationOptions: (any PropagatorOptionsSource)? { get }

  /// `CircuitState.markPointAsDirty(Propagator.SimulatorEvent)` (`CircuitState.java:439`).
  func markPointAsDirty(_ event: PropagationEvent)

  /// `CircuitState.processDirtyPoints()` (`CircuitState.java:475`).
  ///
  /// Throws by D13: this reaches `CircuitWires.propagate`, which resolves bus widths and can
  /// raise the `ValueError`s M1 introduced for mismatched wire widths.
  func processDirtyPoints() throws

  /// `CircuitState.processDirtyComponents()` (`CircuitState.java:445`).
  ///
  /// Throws by D13: upstream's own comment on the `try`/`finally` here is
  /// *"comp.propagate() can fail if external (or std) library is buggy"*, and `Simulator`
  /// catches it.
  func processDirtyComponents() throws

  /// `CircuitState.reset()` (`CircuitState.java:509`), reached from `Propagator.reset()`.
  ///
  /// Named `resetStateTree` rather than `reset` so a conformer that already has an unrelated
  /// `reset()` is not silently captured by this requirement.
  func resetStateTree() throws

  /// `CircuitState.toggleClocks(int)` (`CircuitState.java:688`); returns whether the tree
  /// contains any clock at all.
  ///
  /// Throws by D13 even though Java's call site (`Simulator.java:525`) is *not* inside a
  /// `catch`: `Clock.tick` writes values, so it can raise the same `ValueError`s, and in the
  /// Java that would kill the simulation thread outright.
  func toggleClocks(_ ticks: Int) throws -> Bool
}

// MARK: - Seam: the progress listener

/// `Simulator.ProgressListener.propagationInProgress(Simulator.Event)`
/// (`Propagator.java:182`, `:202`).
///
/// **Seam.** `Simulator` is owned by another slice. The event payload is opaque here because
/// `Simulator.Event` carries nothing the propagator reads; it is constructed once at
/// `Simulator.java:530` and handed straight back.
public protocol PropagationProgressListener: AnyObject {
  func propagationInProgress(_ event: AnyObject?)
}

// MARK: - PropagationEvent

/// `Propagator.SimulatorEvent` (`Propagator.java:56-88`) fused with its superclass
/// `com.cburch.logisim.util.QNode` (`util/QNode.java`).
///
/// **Why the two Java classes collapse into one.** `QNode` exists only so that five different
/// queue implementations can share a node type; its `left`/`right` fields are the splay-tree
/// links used by `SplayQueue`/`QueueOfQueues`. `AppPreferences.SIMULATION_QUEUE` defaults to
/// `SIM_QUEUE_DEFAULT`, which falls through `Propagator.java:146` to the `PriorityQueue`-backed
/// implementation, and this port implements that one queue (`PropagationHeap`). The tree links
/// have no reader, so they do not come across; `timeKey`/`serialNumber`/`compare` do.
///
/// **A `final class`, not a struct.** Three independent reasons, all load-bearing:
///  1. `CircuitState.markPointAsDirty(ev)` stores the event itself into `dirtyPoints`
///     (`CircuitState.java:439-443`) and `CircuitWires.propagate` later consumes that list, so
///     the object outlives the queue and must be shared, not copied.
///  2. `val` is a `var` in Java (`Propagator.java:66`), i.e. the field is deliberately mutable.
///  3. D4: simulation keying is reference identity throughout.
public final class PropagationEvent {

  // MARK: Ordering key (QNode)

  /// `QNode.timeKey`; the simulation clock instant at which this value is emitted.
  ///
  /// A Java `int`. It is produced as `clock + delay` (`Propagator.java:283`) with **no overflow
  /// check**, and `QNode.compareTo` compares by *wrapping subtraction* specifically so that a
  /// wrapped clock still orders correctly against nearby keys. Held as `Int` and kept inside
  /// `Int32` range by `wrap32` at every producer.
  public let timeKey: Int

  /// `QNode.serialNumber`: the tie-break, and the reason event order is deterministic.
  ///
  /// A Java `int`, assigned from `Propagator.eventSerialNumber++` (`Propagator.java:283-284`),
  /// so it is unique per propagator until it wraps after 2^32 events.
  public let serialNumber: Int

  // MARK: Payload (SimulatorEvent)

  /// *"State of circuit containing component"*: `SimulatorEvent.state`.
  ///
  /// **D3: `weak`, and this is one of the nine cycles.** Java's field is a plain
  /// `final CircuitState`; under ARC that edge closes
  ///
  /// ```
  /// CircuitState --(strong)--> Propagator --(strong)--> PropagationHeap
  ///              <--(strong)-- PropagationEvent <--(strong)--
  /// ```
  ///
  /// which leaks the entire circuit whenever a project is closed with the queue non-empty;
  /// i.e. whenever a running simulation is closed, which is the ordinary case, and which the M3
  /// gate exercises directly ("leak check clean after 1,000 open/close cycles"). The cycle
  /// exists independently of which way the `Propagator ⇄ CircuitState` edge is broken, so it has
  /// to be broken here.
  ///
  /// **Why dropping a dead state's event is not a simulation divergence.** A `CircuitState` is
  /// deallocated only once nothing in the live tree owns it; substates are owned by their
  /// parent's `componentData`, the root by the project. A state that is unreachable from the
  /// root is never visited by `root.processDirtyPoints()` either, so in Java the
  /// `markPointAsDirty` that this port skips would append to a dirty list that is never
  /// processed. The observable result is identical; only the retention differs.
  ///
  /// `weak` rather than `unowned`: "the state went away while its event was still queued" is a
  /// representable, expected condition here (component deletion mid-propagation), and D13 says
  /// a condition reachable from ordinary use must not trap.
  public private(set) weak var state: (any PropagatorCircuitState)?

  /// *"The location at which value is emitted"*, `SimulatorEvent.loc`.
  public let loc: Location

  /// *"Component emitting the value"*: `SimulatorEvent.cause`.
  ///
  /// D3: strong, as in Java. Components are owned by `Circuit`, and no component holds a
  /// strong reference back into the propagator (`InstanceComponent.instanceState` is weak per
  /// D3), so this closes no cycle.
  public let cause: any PropagatorComponent

  /// *"Value being emitted"*: `SimulatorEvent.val`. `var` in Java, so `var` here.
  public var val: Value

  /// Mirrors the private constructor at `Propagator.java:69`.
  ///
  /// `internal` rather than `public` for the same reason Java's is `private`: every event must
  /// be minted by the propagator so it carries a serial number from the one counter that makes
  /// ordering deterministic.
  init(
    timeKey: Int,
    serialNumber: Int,
    state: any PropagatorCircuitState,
    loc: Location,
    cause: any PropagatorComponent,
    val: Value
  ) {
    self.timeKey = wrap32(timeKey)
    self.serialNumber = wrap32(serialNumber)
    self.state = state
    self.loc = loc
    self.cause = cause
    self.val = val
  }

  /// `SimulatorEvent.cloneFor(CircuitState)` (`Propagator.java:78-83`).
  ///
  /// Re-bases the event's time onto another propagator's clock and takes a serial number from
  /// *that* propagator's counter, incrementing it.
  ///
  /// **Dead in 4.1.0.** A whole-tree grep of the 4.1.0 sources finds no caller; it is API kept
  /// for the (unported) `CircuitState` copy path. Ported anyway because leaving it out would be
  /// an undocumented gap, and it costs nothing.
  ///
  /// Returns `nil` where Java would throw `NullPointerException`; either state has no live
  /// propagator. D13: a null-propagator state is reachable from a torn-down circuit, so this
  /// must not trap.
  public func cloneFor(_ newState: any PropagatorCircuitState) -> PropagationEvent? {
    guard let state,
          let newProp = newState.owningPropagator,
          let oldProp = state.owningPropagator
    else { return nil }
    // `newProp.clock - state.getPropagator().clock`, int arithmetic, wraps.
    let dtime = wrap32(newProp.clockValue - oldProp.clockValue)
    let serial = newProp.takeEventSerialNumber()
    return PropagationEvent(
      timeKey: wrap32(timeKey + dtime),
      serialNumber: serial,
      state: newState,
      loc: loc,
      cause: cause,
      val: val)
  }

  // MARK: Ordering

  /// `QNode.compareTo` (`util/QNode.java:20-27`), including its overflow, verbatim:
  ///
  /// ```java
  /// // Yes, these subtractions may overflow. This is intentional, as it
  /// // avoids potential wraparound problems as the counters increment.
  /// int ret = timeKey - other.timeKey;
  /// if (ret == 0) ret = serialNumber - other.serialNumber;
  /// return ret;
  /// ```
  ///
  /// The wrap is not incidental; it is what makes a queue whose `timeKey`s have wrapped past
  /// `Int32.max` still order correctly against keys that have not. It also makes the comparator
  /// **non-transitive** over the full `Int32` range, so the heap in `PropagationHeap` reproduces
  /// Java's `PriorityQueue` sift algorithms move for move rather than relying on `sort`-style
  /// total-order assumptions that do not hold here.
  ///
  /// Returns the raw Java `int`; callers must test its *sign* with the same `>= 0` / `> 0` /
  /// `<= 0` comparisons Java's `PriorityQueue` uses.
  @inline(__always)
  public static func compare(_ lhs: PropagationEvent, _ rhs: PropagationEvent) -> Int {
    var ret = wrap32(lhs.timeKey - rhs.timeKey)
    if ret == 0 { ret = wrap32(lhs.serialNumber - rhs.serialNumber) }
    return ret
  }
}

extension PropagationEvent: CustomStringConvertible {
  /// `SimulatorEvent.toString()` (`Propagator.java:86`): `loc + ":" + val + "(" + cause + ")"`.
  public var description: String {
    "\(loc):\(val)(\(cause))"
  }
}

// MARK: - PropagationPoints

/// `com.cburch.logisim.circuit.PropagationPoints` (`circuit/PropagationPoints.java`), minus
/// drawing.
///
/// **What did not come across, and why.** `draw(ComponentDrawContext)`,
/// `drawPendingInputs(ComponentDrawContext)` and `getSingleStepMessage()` are all D9 exclusions:
/// the first two take an AWT drawing context and the third builds a localised string. Their
/// input, the two sets, is exposed instead, so `LogisimRender`/`LogisimUI` can render the
/// oscillation halo at M6 without this type learning about graphics.
///
/// **D3; the entries hold their `CircuitState` weakly.** Java holds them strongly and relies on
/// the GC. Here `Propagator` owns `oscPoints`, and a `CircuitState` owns (indirectly) the
/// propagator's lifetime, so a strong entry would close a cycle for exactly as long as a circuit
/// is left in the oscillating state, which is the state a user is most likely to close the
/// file from. Holding weakly costs nothing behaviourally: every state that can legitimately
/// appear here is reachable from the propagator's root for the whole time the set is live.
public final class PropagationPoints {

  /// `PropagationPoints.Entry<Location>`.
  ///
  /// Java's `Entry.equals` is `state.equals(o.state) && item.equals(o.item)` and `CircuitState`
  /// does **not** override `equals`, so the state half is reference identity; exactly what D4
  /// requires and what `ObjectIdentifier` gives. `hashCode` is `state.hashCode() * 31 +
  /// item.hashCode()`; the exact hash is unobservable (it only affects `HashSet` iteration
  /// order, which reaches drawing alone), so Swift's hasher is used.
  public struct LocationEntry: Hashable {
    private weak var stateRef: (any PropagatorCircuitState)?
    private let identity: ObjectIdentifier
    public let location: Location

    init(state: any PropagatorCircuitState, location: Location) {
      self.stateRef = state
      self.identity = ObjectIdentifier(state)
      self.location = location
    }

    /// The state, or `nil` if it has been deallocated since the entry was recorded.
    public var state: (any PropagatorCircuitState)? { stateRef }

    public static func == (lhs: LocationEntry, rhs: LocationEntry) -> Bool {
      lhs.identity == rhs.identity && lhs.location == rhs.location
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(identity)
      hasher.combine(location)
    }
  }

  /// `PropagationPoints.Entry<Component>`.
  public struct ComponentEntry: Hashable {
    private weak var stateRef: (any PropagatorCircuitState)?
    private let identity: ObjectIdentifier
    private weak var componentRef: (any PropagatorComponent)?
    private let componentIdentity: ObjectIdentifier

    init(state: any PropagatorCircuitState, component: any PropagatorComponent) {
      self.stateRef = state
      self.identity = ObjectIdentifier(state)
      self.componentRef = component
      self.componentIdentity = ObjectIdentifier(component)
    }

    public var state: (any PropagatorCircuitState)? { stateRef }
    public var component: (any PropagatorComponent)? { componentRef }

    public static func == (lhs: ComponentEntry, rhs: ComponentEntry) -> Bool {
      lhs.identity == rhs.identity && lhs.componentIdentity == rhs.componentIdentity
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(identity)
      hasher.combine(componentIdentity)
    }
  }

  /// `PropagationPoints.data`; the locations whose value changed during the step.
  public private(set) var data: Set<LocationEntry> = []

  /// `PropagationPoints.pendingInputs`; components whose inputs were invalidated by a tick.
  public private(set) var pendingInputs: Set<ComponentEntry> = []

  public init() {}

  /// `void add(CircuitState, Location)` (`PropagationPoints.java:55`).
  public func add(state: any PropagatorCircuitState, location: Location) {
    data.insert(LocationEntry(state: state, location: location))
  }

  /// `void addPendingInput(CircuitState, Component)` (`PropagationPoints.java:51`).
  public func addPendingInput(state: any PropagatorCircuitState, component: any PropagatorComponent) {
    pendingInputs.insert(ComponentEntry(state: state, component: component))
  }

  /// `void clear()` (`PropagationPoints.java:66`).
  public func clear() {
    data.removeAll(keepingCapacity: true)
    pendingInputs.removeAll(keepingCapacity: true)
  }

  /// The two counts `getSingleStepMessage()` formats. The message itself is localised UI text
  /// (D9) and is assembled above this module.
  public var singleStepCounts: (signalsChanged: Int, inputSignals: Int) {
    (data.count, pendingInputs.count)
  }
}
