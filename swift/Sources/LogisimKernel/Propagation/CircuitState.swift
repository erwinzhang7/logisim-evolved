// CircuitState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16): `circuit/CircuitState.java`, 773 lines.
//
// Upstream's own summary, which is worth keeping: *"CircuitState holds the simulation state of a
// Circuit (or Subcircuit), i.e. the values being carried along all wires and buses, along with
// the InstanceData for all components embedded in the circuit. Most of the dynamically-computed
// data is actually in CircuitWires. In here there is mostly just a few pointers to other data
// structures and the dirty lists."*
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// D3; ARC ownership. This type is where it matters most.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// Under Java's GC every edge below can be strong and nothing leaks. Under ARC, `CircuitState` is
// the hub of four of the nine reference cycles, and getting one wrong leaks the whole circuit,
// silently, with zero test failures, on every file close.
//
//   OWNING (strong), matching D3's list exactly:
//     * `substates`           ; the parent owns the child states. This is the tree.
//     * `componentData`       ; the state owns each component's `InstanceData`, including a
//                                subcircuit's `CircuitState`. Its *keys* are strong too, which
//                                is not a cycle; see `ComponentDataMap`'s note.
//     * `circuitListener`     ; the state owns its listener. The `Circuit` holds it weakly
//                                (`EventSourceWeakSupport`), so the loop
//                                Circuit -> listener -> CircuitState -> Circuit is broken on the
//                                Circuit's side and does not need breaking again here.
//     * `circuit`             ; a `Circuit` never strongly reaches a `CircuitState`
//                                (listeners are weak), so this edge closes no cycle, and the
//                                state must keep the circuit it is simulating alive.
//     * `basePropagator`      : see the exception below.
//
//   BACK-EDGES (weak/unowned), every one of them:
//     * `parentState`   weak    ; the child must not retain the parent. This is *the* leak D3
//                                  calls out: a state tree that retains upward keeps the root
//                                  alive from any leaf, so closing a file frees nothing.
//                                  `weak` rather than `unowned` because upstream explicitly
//                                  *nulls* it (`substate.parentState = null` on removal, and
//                                  again in `cloneAsNewRootState`), so "detached" is a
//                                  representable, expected state and must read as `nil` rather
//                                  than trap.
//     * `parentComp`    weak    ; likewise; the subcircuit component belongs to the *parent's*
//                                  `Circuit`, and upstream nulls this on removal too. Also the
//                                  component can be deleted while a detached state is still
//                                  being torn down, which `unowned` would turn into a crash.
//     * `project`       weak    ; `Project` owns the root `CircuitState`; retaining it back
//                                  would pin the entire UI object graph from the kernel.
//                                  `weak`, not `unowned`, because a substate can be reset during
//                                  the project's own deallocation.
//     * the listener's `state`  unowned; `MyCircuitListener` is owned solely by the
//                                  `CircuitState` it belongs to, so it cannot outlive it.
//     * `SimPropagator`'s root  unowned: enforced on the *conformer*, see below.
//
//   THE ONE DEVIATION FROM D3's LETTER; `base` is strong here.
//
//   D3 lists `base` (the `Propagator`) among the non-owning edges. Implemented literally, that
//   is unsafe: `createRootState(project:circuit:)` constructs the propagator inside the
//   constructor and returns *the state*, so an unowned `base` would refer to an object with a
//   zero strong count the moment the initializer returned. Something must break the
//   CircuitState <-> Propagator two-cycle, and the only side that can be broken without
//   dangling is the propagator's back-edge to its root. So:
//
//       CircuitState --(strong)--> Propagator --(unowned)--> root CircuitState
//
//   which yields the clean chain  Project -> rootState -> substates, and  anyState ->
//   propagator, with no cycle and no dangling reference.
//
//   SETTLED (M3 wiring): in this file's favour, and the code already agreed.
//   This header used to carry a ⚠ saying `Propagator.swift` had taken the opposite break. Only
//   its *doc comment* had: the declaration there is `public private(set) weak var root`, so the
//   two files were already consistent and only the prose disagreed. The direction is right for
//   the reason argued above: `createRootState(project:circuit:)` and `cloneAsNewRootState()`
//   each construct a propagator inside an initializer and hand back **only the state**, with no
//   `Simulator` in the picture (a clone is not attached to one), so under the other rule the
//   returned state's engine would have a zero strong count the instant the initializer returned.
//   `SimulationSeamJoin.swift` records the resolution alongside the conformance that depends on
//   it. `Propagator.root` is `weak` rather than `unowned` because a *detached* substate keeps its
//   old propagator (upstream nulls `parentState`, not `base`) and can outlive the root.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// D1; no Swift Concurrency.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// `dirtyLock` and `valuesLock` are `NSRecursiveLock`, not `NSLock`: they stand in for Java
// monitors, which are reentrant. `getValue` holds `valuesLock` across the `CircuitWires`
// call-out exactly as `synchronized (valuesLock)` does, and a non-reentrant lock would risk
// deadlocking on any re-entry upstream tolerates.
//
// ── Deliberate divergences, all noted at their site ─────────────────────────────────────────
//
//   * `Instance` is deleted (D3), so the `getInstanceState(Instance)` /
//     `getReusableInstanceState(Instance)` overloads collapse into the `Component` ones. The
//     *unvalidated* behaviour of the `Instance` overload is preserved as a separate entry point.
//   * `drawOscillatingPoints(ComponentDrawContext)` is not ported; D9 forbids drawing types in
//     the kernel. It is a two-line forward to `Propagator`, and belongs to the render layer.
//   * `getNonWires()` / the substate set / `componentData`'s key set are ordered here where Java
//     leaves them in JVM hash order. Same family of fix as D14: order affects the sequence in
//     which components are marked dirty and reset, and the differential harness needs two runs
//     of the same file to agree.
//   * The 200x200 fast-path grid allocates its rows lazily. Storage only: a `Value` is a 32-byte
//     struct here against a 8-byte reference in Java, so an eager grid would cost ~1.6 MB *per
//     circuit state*, i.e. per subcircuit instance at every nesting level. Every read and write
//     behaves exactly as the eager array does.
//
// ── Preserved verbatim although it looks wrong ──────────────────────────────────────────────
//
//   * The reusable `InstanceStateImpl` and its aliasing (standing rule 4).
//   * The `TRANSACTION_DONE` handler's inverted `continue`, which makes upstream's entire
//     state-transfer-on-copy/paste path dead code. See the handler.

import Foundation

/// `com.cburch.logisim.circuit.CircuitState`.
///
/// Implements `InstanceData` because a subcircuit component's data *is* the substate.
public final class CircuitState: SimInstanceData, CustomStringConvertible {

  // MARK: - Seams the integrator must install

  /// How a root `CircuitState` builds its `Propagator`. See `SimPropagatorFactory`.
  ///
  /// **No longer optional, and no longer unwired.** Both of these were declared `nil` with a
  /// "the integrator must install this" note, and nothing in the whole tree ever assigned them:
  /// `propagatorFactory` is reached from `createRootState`, the ordinary path for opening any
  /// `.circ`, so as shipped the *first* simulation of *any* circuit hit a `fatalError` and killed
  /// the process. That is the unwired-seam class this project has been bitten by repeatedly, and
  /// an `Optional` with a trap on the `nil` branch is what made it possible: the type system was
  /// stating the seam might legitimately be empty when it never can be.
  ///
  /// Both concrete types (`Propagator`, `InstanceStateImpl`) live in *this* module, so the
  /// default is simply the real thing. The properties stay `var` because the differential
  /// harness genuinely wants to substitute an instrumented `Propagator` (its `queue` and
  /// `noiseSeed` parameters exist for exactly that), but the *default* is now a working engine
  /// rather than a landmine.
  public static var propagatorFactory: SimPropagatorFactory = { root, thread in
    // Upstream: `new Propagator(this, thread != null ? thread : proj.getSimulator().simThread)`.
    // `Propagator.propagatorThread` is non-optional because every mutating entry point asserts
    // against it; upstream's own `TtyInterface` passes `Thread.currentThread()` for the headless
    // run, so that is the fallback when no simulator thread exists.
    Propagator(root: root, propagatorThread: thread ?? Thread.current)
  }

  /// How a `CircuitState` builds `InstanceStateImpl`s. See `SimInstanceStateFactory`.
  ///
  /// See `propagatorFactory` above for why this is no longer optional.
  public static var instanceStateFactory: SimInstanceStateFactory = { state, component in
    InstanceStateImpl(state, component)
  }

  // MARK: - MyCircuitListener

  /// Upstream's private inner class `CircuitState.MyCircuitListener`.
  private final class MyCircuitListener: SimCircuitListener {
    /// D3: unowned. The `CircuitState` is this listener's only strong owner, so the listener
    /// cannot outlive it; the `Circuit` on the other side holds listeners weakly.
    unowned let state: CircuitState

    init(_ state: CircuitState) { self.state = state }

    func circuitChanged(_ event: SimCircuitEvent) {
      state.handleCircuitEvent(event)
    }
  }

  // MARK: - Stored state

  /// `myCircuitListener`. Strong: the state owns it; the circuit refers to it weakly.
  /// Implicitly unwrapped only because it needs `self`.
  private var circuitListener: MyCircuitListener!

  /// The token returned by `SimCircuit.addCircuitListener`. Holding it *is* the subscription;
  /// releasing this state releases the token and unregisters the listener. See the initializer.
  private var circuitSubscription: CircuitSubscription?

  /// `base`: *"Inherited from base of tree of CircuitStates."* Strong; see the ownership note
  /// in the file header for why this is the one edge that deviates from D3's list.
  private var basePropagator: Propagator!

  /// `getPropagator()`.
  public var propagator: Propagator { basePropagator }

  /// `proj`: *"Project containing this circuit."* D3: weak.
  private weak var projectRef: (any SimProject)?

  /// `getProject()`.
  public var project: (any SimProject)? { projectRef }

  /// `circuit`, *"Circuit being simulated."*
  public let circuit: any SimCircuit

  /// `parentState`: *"Parent in tree of CircuitStates."* D3: weak; upstream nulls it.
  private weak var parentStateRef: CircuitState?

  /// `getParentState()`.
  public var parentState: CircuitState? { parentStateRef }

  /// `parentComp`: *"subcircuit component containing this."* D3: weak; upstream nulls it.
  private weak var parentCompRef: (any SimComponent)?

  /// `getSubcircuit()`: package-private upstream; public here because `SubcircuitFactory`
  /// lives in a different module.
  public var subcircuit: (any SimComponent)? { parentCompRef }

  /// `wireData`. Package-private upstream (`getWireData`/`setWireData`); public here because
  /// `CircuitWires` is in another module.
  public var wireData: CircuitWires.State?

  /// `componentData`. Owning, per D3.
  private var componentData = ComponentDataMap()

  private static let fastpathGridWidth = 200
  private static let fastpathGridHeight = 200

  // `slowpathValues` and `fastpathValues` store values resulting from propagation *within* this
  // circuit, i.e. the outputs of components in this circuit together with the values carried on
  // wires and buses in this circuit. When components embedded in this circuit are called upon to
  // re-calculate / propagate, the components will call `getValue()` to pick out values from
  // these data structures. These are the values you would see if you stick a probe at some
  // location on the circuit sheet. They are protected by `valuesLock`.

  /// `slowpathValues`: values propagated in this circuit. Protected by `valuesLock`.
  private var slowpathValues: [Location: Value] = [:]

  /// `fastpathValues`: values propagated in this circuit. Protected by `valuesLock`.
  ///
  /// Java: `new Value[FASTPATH_GRID_HEIGHT][FASTPATH_GRID_WIDTH]`, allocated eagerly. Here the
  /// rows are allocated on first write; see the header for why. `nil` row == all-`nil` row.
  private var fastpathValues: [ContiguousArray<Value?>?] =
    Array(repeating: nil, count: CircuitState.fastpathGridHeight)

  /// `valuesLock`, protects `slowpathValues` and `fastpathValues`.
  private let valuesLock = NSRecursiveLock()

  // `dirtyComponents`, `dirtyPoints`, and `substates` are components being marked as dirty. They
  // will later be shifted to the working sets to be processed. They are protected by `dirtyLock`.

  /// Protected by `dirtyLock`.
  private var dirtyComponents: [any SimComponent] = []
  /// Protected by `dirtyLock`.
  private var dirtyPoints: [PropagationEvent] = []
  /// Protected by `dirtyLock`.
  private var substates = SubstateSet()
  /// Protects `dirtyComponents`, `dirtyPoints`, and `substates`. Recursive, because Java
  /// monitors are.
  private let dirtyLock = NSRecursiveLock()

  // `dirtyComponentsWorking`, `dirtyPointsWorking`, and `substatesWorking` are those elements of
  // this circuit that are being processed.

  /// Components being processed.
  public private(set) var dirtyComponentsWorking: [any SimComponent] = []
  /// Points being processed.
  private var dirtyPointsWorking: [PropagationEvent] = []
  /// Substates being processed.
  ///
  /// Java uses `substates.toArray(substatesWorking)`, which null-terminates a reused array and
  /// is why upstream's loops read `if (substate == null) break;`. An exactly-sized Swift array
  /// makes those loops "iterate every element", which is the same sequence.
  private var substatesWorking: [CircuitState] = []
  private var substatesDirty = true

  /// `private static int lastId` / `private final int id`. Upstream increments without
  /// synchronisation; a data race on a Swift `static var` is undefined rather than merely
  /// sloppy, so the counter is locked. `id` is observable only through `description`.
  private static var lastId = 0
  private static let lastIdLock = NSLock()
  private let id: Int

  private static func nextId() -> Int {
    lastIdLock.lock()
    defer { lastIdLock.unlock() }
    let current = lastId
    // Java `int` wraps; Swift `Int` traps (see `wrap32`).
    lastId = wrap32(lastId &+ 1)
    return current
  }

  // MARK: - Construction

  /// `CircuitState(Project, Circuit, Propagator, Thread)`.
  ///
  /// When `propagator` is `nil` this state is a root and builds its own, exactly as upstream
  /// does: `new Propagator(this, thread != null ? thread : proj.getSimulator().simThread)`.
  public init(
    project: (any SimProject)?,
    circuit: any SimCircuit,
    propagator: Propagator?,
    thread: Thread? = nil
  ) {
    self.id = CircuitState.nextId()
    self.projectRef = project
    self.circuit = circuit

    // All stored properties are initialised, so `self` may now escape.
    if let propagator {
      self.basePropagator = propagator
    } else {
      self.basePropagator = CircuitState.propagatorFactory(
        self, thread ?? project?.simulator?.simulationThread)
    }

    self.circuitListener = MyCircuitListener(self)
    // D3/D5: the token is the *only* thing keeping this state registered with the circuit, and
    // this state owns it. Dropping the state drops the token and unsubscribes, so the circuit
    // never holds a strong edge to a `CircuitState`.
    self.circuitSubscription = circuit.addCircuitListener(circuitListener)
    markAllComponentsDirty()
  }

  /// `CircuitState(Project, Circuit, Propagator)`.
  public convenience init(
    project: (any SimProject)?, circuit: any SimCircuit, propagator: Propagator?
  ) {
    self.init(project: project, circuit: circuit, propagator: propagator, thread: nil)
  }

  /// `static createRootState(Project, Circuit)` / `(Project, Circuit, Thread)`.
  public static func createRootState(
    project: (any SimProject)?, circuit: any SimCircuit, thread: Thread? = nil
  ) -> CircuitState {
    // `null /* make new Propagator */`.
    CircuitState(project: project, circuit: circuit, propagator: nil, thread: thread)
  }

  /// `clone()`; upstream's `clone()` is literally `return cloneAsNewRootState();`.
  public func cloneComponentState() -> Any {
    cloneAsNewRootState()
  }

  /// `cloneAsNewRootState(Thread)` / `cloneAsNewRootState()`.
  public func cloneAsNewRootState(thread: Thread? = nil) -> CircuitState {
    let ret = CircuitState(project: projectRef, circuit: circuit, propagator: nil, thread: thread)
    ret.copyFrom(self)
    ret.parentCompRef = nil
    ret.parentStateRef = nil
    return ret
  }

  /// `copyFrom(CircuitState)`.
  private func copyFrom(_ src: CircuitState) {
    self.parentCompRef = src.parentCompRef
    self.parentStateRef = src.parentStateRef

    // Maps each of `src`'s substates to its freshly built copy, so the `componentData` pass
    // below can redirect subcircuit entries at the new tree.
    var substateData: [ObjectIdentifier: CircuitState] = [:]
    self.substates = SubstateSet()

    src.dirtyLock.lock()
    // Upstream's note, preserved: *"we don't bother with our this.dirtyLock here: it isn't
    // needed (b/c no other threads have a reference to this yet), and to avoid the possibility
    // of deadlock."*
    for oldSub in src.substates.elements {
      let newSub = CircuitState(
        project: src.projectRef, circuit: oldSub.circuit, propagator: self.basePropagator)
      newSub.copyFrom(oldSub)
      newSub.parentStateRef = self
      self.substates.insert(newSub)
      self.substatesDirty = true
      substateData[ObjectIdentifier(oldSub)] = newSub
    }
    src.dirtyLock.unlock()

    for key in src.componentData.components {
      let oldValue = src.componentData.value(for: key)
      if let oldState = oldValue as? CircuitState {
        if let newValue = substateData[ObjectIdentifier(oldState)] {
          self.componentData.put(key, newValue)
        } else {
          self.componentData.remove(key)
        }
      } else {
        // `(oldValue instanceof ComponentState state) ? state.clone() : oldValue`
        let newValue: Any?
        if let state = oldValue as? any SimComponentState {
          newValue = state.cloneComponentState()
        } else {
          newValue = oldValue
        }
        self.componentData.put(key, newValue)
      }
    }

    // Upstream again declines to take `this.valuesLock`, for the same reason.
    self.slowpathValues.removeAll()  // slow path
    src.valuesLock.lock()
    self.slowpathValues = src.slowpathValues  // slow path
    self.fastpathValues = src.fastpathValues  // fast path (`System.arraycopy` per row)
    src.valuesLock.unlock()

    src.dirtyLock.lock()
    self.dirtyComponents.append(contentsOf: src.dirtyComponents)
    self.dirtyPoints.append(contentsOf: src.dirtyPoints)
    src.dirtyLock.unlock()

    if src.wireData != nil {
      // "all buses will be marked as dirty"
      // `newState` throws where upstream cannot (D13: mismatched bus widths surface as a
      // `ValueError` now). `copyFrom` is reached from `cloneComponentState()`, a non-throwing
      // protocol requirement, so the failure is absorbed here, and absorbing it is safe rather
      // than lossy: `CircuitWires.propagate` rebuilds a `nil` wire state from the connectivity
      // map on its next call, which is the same work this line was doing eagerly.
      self.wireData = try? circuit.wireStore.newState(self)
    }
  }

  // MARK: - Public accessors

  /// `getData(Component)`.
  public func getData(_ component: any SimComponent) -> Any? {
    componentData.value(for: component)
  }

  /// `isSubstate()`.
  public var isSubstate: Bool { parentStateRef != nil }

  /// `getSubstates()`.
  ///
  /// Upstream hands back the live `HashSet` with no lock, which is a race the port declines to
  /// reproduce; this is a snapshot taken under `dirtyLock`.
  public var substateList: [CircuitState] {
    dirtyLock.lock()
    defer { dirtyLock.unlock() }
    return substates.elements
  }

  // MARK: - Instance state

  /// The reusable `InstanceStateImpl`, **standing rule 4, preserved verbatim.**
  ///
  /// Upstream: `private final InstanceStateImpl reusableInstanceState = new InstanceStateImpl(this,
  /// null);`, one scratch object per circuit state, repurposed rather than reallocated. That is
  /// only safe because propagation is synchronous, single-threaded and non-reentrant (D1/D2),
  /// and it is worth roughly a 90% reduction in propagation allocation. Do not make it per-call.
  ///
  /// Built lazily rather than in the initialiser. Purely a coupling reduction; the object is
  /// private and reachable only through the two getters below, so "created eagerly" and "created
  /// on first use" are indistinguishable, and it means a `CircuitState` can exist without the
  /// upper modules having installed `instanceStateFactory`.
  private lazy var reusableInstanceState: any SimInstanceStateImpl =
    CircuitState.instanceStateFactory(self, nil)

  /// `getInstanceState(Component)`.
  ///
  /// D13: `throws` where upstream throws. Both exits are reachable during propagation, where
  /// `Simulator` converts an exception into a circuit error the user sees; trapping would kill
  /// the process and lose unsaved work instead.
  public func getInstanceState(_ component: any SimComponent) throws -> any SimInstanceStateImpl {
    guard component.factoryRoles.contains(.instanceFactory) else {
      throw CircuitStateError.notAnInstanceComponent
    }
    // Upstream's `comp != ((InstanceComponent) comp).getInstance().getComponent()` check has no
    // analogue: D3 deleted the `Instance` facade precisely because that two-object identity
    // could disagree. `CircuitStateError.instanceComponentMismatch` documents the vanished case.
    return CircuitState.instanceStateFactory(self, component)
  }

  /// `getReusableInstanceState(Component)`.
  ///
  /// *"This method returns a reused object. It should only be called using the propagate thread
  /// and with care that there is no conflict with other uses."* See `SimInstanceStateImpl` for
  /// the aliasing consequences, which are deliberate.
  public func getReusableInstanceState(_ component: any SimComponent) throws
    -> any SimInstanceStateImpl
  {
    guard component.factoryRoles.contains(.instanceFactory) else {
      throw CircuitStateError.notAnInstanceComponent
    }
    reusableInstanceState.repurpose(self, component)
    return reusableInstanceState
  }

  /// `getInstanceState(Instance)`: the overload that performs **no** factory check.
  ///
  /// Same reasoning as `unvalidatedReusableInstanceState(for:)` below: with `Instance` deleted
  /// (D3) the two upstream overloads would collapse into one, and the unchecked one would start
  /// throwing where upstream never does.
  public func unvalidatedInstanceState(for component: any SimComponent)
    -> any SimInstanceStateImpl
  {
    return CircuitState.instanceStateFactory(self, component)
  }

  /// `getReusableInstanceState(Instance)`: the overload that performs **no** factory check.
  ///
  /// D3 deletes `Instance`, so the two overloads would otherwise collapse into one and this
  /// call site would start throwing where upstream does not. `temporaryClockValidateOrTick` is
  /// upstream's only caller, and it reaches it after establishing only that the factory is a
  /// `Pin`; a `Pin` *is* an `InstanceFactory`, but the check upstream skipped is skipped here
  /// too rather than assumed away.
  public func unvalidatedReusableInstanceState(for component: any SimComponent)
    -> any SimInstanceStateImpl
  {
    reusableInstanceState.repurpose(self, component)
    return reusableInstanceState
  }

  // MARK: - Values

  /// `getValue(Location)`.
  public func getValue(_ p: Location) -> Value {
    var value: Value?
    if p.x >= 0 && p.y >= 0
      && p.x % 10 == 0 && p.y % 10 == 0
      && p.x < CircuitState.fastpathGridWidth * 10
      && p.y < CircuitState.fastpathGridHeight * 10
    {
      // fast path
      let x = p.x / 10
      let y = p.y / 10
      valuesLock.lock()
      value = fastpathValues[y]?[x]
      if value == nil {
        value = CircuitWires.getBusValue(self, p)
      }
      valuesLock.unlock()
    } else {
      // slow path
      valuesLock.lock()
      value = slowpathValues[p]
      if value == nil {
        value = CircuitWires.getBusValue(self, p)
      }
      valuesLock.unlock()
    }
    // Note: `busValue` never returns "absent" (upstream's `getBusValue` returns `Value.NIL` for
    // all three no-data cases), so the fallback below is dead in practice. Kept because the
    // conditional is upstream's and because a future `CircuitWires` could reintroduce it.
    return value ?? Value.createUnknown(circuit.width(at: p))
  }

  /// `setValue(Location, Value, Component, int)`.
  public func setValue(_ pt: Location, _ val: Value, _ cause: any SimComponent, _ delay: Int) {
    basePropagator.setValue(state: self, location: pt, value: val, cause: cause, delay: delay)
  }

  /// `clearFastpathGrid()`: precondition: `valuesLock` held.
  private func clearFastpathGrid() {
    for y in 0..<CircuitState.fastpathGridHeight {
      fastpathValues[y] = nil
    }
  }

  /// `setValueByWire(Value, Location[], CircuitWires.BusConnection[])`: for `CircuitWires`, to
  /// set the value at a point. Package-private upstream; public because `CircuitWires` is in a
  /// different module.
  public func setValueByWire(
    _ v: Value, _ points: [Location], _ connections: [CircuitWires.BusConnection]
  ) {
    for p in points {
      if p.x >= 0 && p.y >= 0
        && p.x % 10 == 0 && p.y % 10 == 0
        && p.x < CircuitState.fastpathGridWidth * 10
        && p.y < CircuitState.fastpathGridHeight * 10
      {
        valuesLock.lock()
        _ = fastpath(p, v)
        valuesLock.unlock()
      } else {
        valuesLock.lock()
        _ = slowpath(p, v)
        valuesLock.unlock()
      }
      basePropagator.locationTouched(state: self, location: p)
    }
    for bc in connections {
      if bc.isSink || (bc.isBidirectional && !Value.equal(v, bc.drivenValue)) {
        // `BusConnection.component` is typed `any WireComponent` by the wiring slice. Every
        // component a real circuit registers is a `SimComponent` (which refines it), so this
        // narrows without loss; see `markComponentsDirty(_: [any WireComponent])` in
        // `SimulationSeamJoin.swift` for why a failed narrowing degrades rather than traps.
        if let comp = bc.component as? any SimComponent {
          markComponentAsDirty(comp)
        }
      }
    }
  }

  /// `clearValuesByWire()`, for `CircuitWires`.
  public func clearValuesByWire() {
    valuesLock.lock()
    slowpathValues.removeAll()  // slow path
    clearFastpathGrid()  // fast path
    valuesLock.unlock()
  }

  /// `fastpath(Location, Value)`; precondition: `valuesLock` held.
  ///
  /// The `Bool` result is upstream's "did this change anything"; 4.1.0's only caller ignores it.
  @discardableResult
  private func fastpath(_ p: Location, _ v: Value) -> Bool {
    let x = p.x / 10
    let y = p.y / 10
    // Java compares against the `Value.NIL` singleton by reference; `Value` is an interned
    // Java object and a Swift struct, so structural equality against `.nilValue` is the exact
    // same predicate; `NIL` is the sole width-0 value either language can produce.
    if v == Value.nilValue {
      if fastpathValues[y]?[x] != nil {
        fastpathValues[y]?[x] = nil
        return true
      } else {
        return false
      }
    } else {
      // `!v.equals(fastpathValues[y][x])`; true when the slot is null, hence the `Value?`
      // comparison rather than a force-unwrap.
      let current: Value? = fastpathValues[y]?[x]
      if current != v {
        if fastpathValues[y] == nil {
          fastpathValues[y] = ContiguousArray(
            repeating: nil, count: CircuitState.fastpathGridWidth)
        }
        fastpathValues[y]?[x] = v
        return true
      } else {
        return false
      }
    }
  }

  /// `slowpath(Location, Value)`: precondition: `valuesLock` held.
  @discardableResult
  private func slowpath(_ p: Location, _ v: Value) -> Bool {
    if v == Value.nilValue {
      let old = slowpathValues.removeValue(forKey: p)
      return old != nil && old != Value.nilValue
    } else {
      let old = slowpathValues.updateValue(v, forKey: p)
      return v != old
    }
  }

  /// `markDirtyComponents(Location, Component[])`.
  ///
  /// Private and **uncalled** in 4.1.0; upstream keeps it around, so the port does too rather
  /// than silently dropping a method a later version may reconnect.
  func markDirtyComponents(_ p: Location, _ affected: [any SimComponent]) {
    for comp in affected {
      markComponentAsDirty(comp)
    }
    if !affected.isEmpty {
      basePropagator.locationTouched(state: self, location: p)
    }
  }

  // MARK: - Dirty lists

  /// `markAllComponentsDirty()`.
  private func markAllComponentsDirty() {
    dirtyLock.lock()
    dirtyComponents.append(contentsOf: circuit.nonWireComponents)
    dirtyLock.unlock()
  }

  /// `markComponentAsDirty(Component)`.
  public func markComponentAsDirty(_ comp: any SimComponent) {
    dirtyLock.lock()
    dirtyComponents.append(comp)
    dirtyLock.unlock()
  }

  /// `markComponentsDirty(Collection<Component>)`.
  public func markComponentsDirty(_ comps: [any SimComponent]) {
    dirtyLock.lock()
    dirtyComponents.append(contentsOf: comps)
    dirtyLock.unlock()
  }

  /// `markPointAsDirty(Propagator.SimulatorEvent)`.
  public func markPointAsDirty(_ ev: PropagationEvent) {
    dirtyLock.lock()
    dirtyPoints.append(ev)
    dirtyLock.unlock()
  }

  /// `processDirtyComponents()`.
  ///
  /// D13: `throws`. Upstream's comment on the `try` is *"comp.propagate() can fail if external
  /// (or std) library is buggy"*, and `Simulator` catches it and records a circuit error.
  public func processDirtyComponents() throws {
    if !dirtyComponentsWorking.isEmpty {
      throw CircuitStateError.dirtyComponentsWorkingNotEmpty
    }
    dirtyLock.lock()
    do {
      let other = dirtyComponents
      dirtyComponents = dirtyComponentsWorking  // `dirtyComponents` is now empty
      dirtyComponentsWorking = other  // working set is now ready to process
      if substatesDirty {
        substatesDirty = false
        substatesWorking = substates.elements
      }
    }
    dirtyLock.unlock()

    do {
      // Java's `finally`. Note that when `propagate` throws, the substate recursion below is
      // skipped, the exception leaves the method, which is upstream's behaviour too.
      defer { dirtyComponentsWorking.removeAll() }
      for comp in dirtyComponentsWorking {
        try comp.propagate(in: self)
        // pin values also get propagated to parent state
        if comp.factoryRoles.contains(.pin), let parent = parentStateRef {
          // Upstream would NPE here if `parentComp` were null while `parentState` was not; the
          // weak reference makes that case a no-op instead of a crash (D13's spirit: no traps
          // on a path a user can reach).
          try parentCompRef?.propagate(in: parent)
        }
      }
    }

    for substate in substatesWorking {
      try substate.processDirtyComponents()
    }
  }

  /// `processDirtyPoints()`.
  public func processDirtyPoints() throws {
    // Edits the editing thread queued, applied here because here is on the propagation thread.
    // See `SimCircuit.applyPendingEdits` for why this call sits in the path rather than in the
    // drivers. `Propagator.propagate` and `.step` both reach this before touching the wire map,
    // and both have already asserted the thread.
    circuit.applyPendingEdits()
    if !dirtyPointsWorking.isEmpty {
      throw CircuitStateError.dirtyPointsWorkingNotEmpty
    }
    dirtyLock.lock()
    do {
      let other = dirtyPoints
      dirtyPoints = dirtyPointsWorking  // `dirtyPoints` is now empty
      dirtyPointsWorking = other  // working set is now ready to process
      if substatesDirty {
        substatesDirty = false
        substatesWorking = substates.elements
      }
    }
    dirtyLock.unlock()

    // Upstream's note, preserved because it explains why the splitter-dirtying hack is gone:
    // *"When a new wire map is created (because wires or splitters have changed, for example),
    // we need to mark all the splitter locations as dirty. This used to be handled here by
    // detecting when the map was voided, and explicitly marking all the splitter locations as
    // dirty. But we can't reliably touch circuit.wires.points.getAllLocations(), because we are
    // on the simulator thread here, and the UI/AWT thread owns that data structure. [...]
    // Instead, we now put the splitter location list in the wire map itself when it is created."*
    //
    // There is deliberately no `defer` around this call: upstream clears `dirtyPointsWorking`
    // only on the success path, so a throwing `CircuitWires.propagate` leaves the working list
    // populated and the next call fails the "not empty" check. That is upstream's behaviour and
    // the port keeps it.
    try circuit.wireStore.propagate(self, dirtyPoints: dirtyPointsWorking)
    dirtyPointsWorking.removeAll()

    for substate in substatesWorking {
      try substate.processDirtyPoints()
    }
  }

  // MARK: - Reset

  /// `reset()`.
  public func reset() {
    temporaryClock = nil
    wireData = nil
    // Snapshot: upstream iterates `keySet()` while calling `put` on existing keys, which a Java
    // `HashMap` tolerates because it is not a structural modification. Swift needs the snapshot.
    for comp in componentData.components {
      if comp.factoryRoles.contains(.ram) {
        let remove = comp.resetRamState(in: self)
        if remove { componentData.put(comp, nil) }
      } else if comp.factoryRoles.contains(.buzzer) {
        comp.stopBuzzerSound(in: self)
      } else if !comp.factoryRoles.contains(.subcircuit) {
        if let guiProvider = componentData.value(for: comp) as? any ComponentDataGuiProvider {
          guiProvider.destroy()
        }
        if let telnetServer = componentData.value(for: comp) as? any SimTelnetServerData {
          telnetServer.deleteAll()
        }
        componentData.put(comp, nil)
      }
    }
    valuesLock.lock()
    slowpathValues.removeAll()  // slow path
    clearFastpathGrid()  // fast path
    valuesLock.unlock()

    dirtyLock.lock()
    dirtyComponents.removeAll()
    dirtyPoints.removeAll()
    for sub in substates.elements {
      sub.reset()
    }
    dirtyLock.unlock()

    markAllComponentsDirty()
  }

  // MARK: - Substates

  /// `createCircuitSubstateFor(Component, Circuit)`.
  ///
  /// This is the *only* place a substate is created, and the removal handler below is the only
  /// place one is detached; keeping the pair exact is what stops a substate outliving its
  /// component (a leak) or dying while its component is still placed (a wrong-value bug).
  @discardableResult
  public func createCircuitSubstateFor(_ comp: any SimComponent, _ circ: any SimCircuit)
    -> CircuitState
  {
    if let oldState = componentData.value(for: comp) as? CircuitState,
      oldState.parentCompRef === comp
    {
      // Upstream: `System.out.println("fixme: removed stale circuitstate... should never
      // happen")`. Kept as a behaviour (the detach), dropped as a print; the kernel does not
      // write to stdout (that would corrupt `logisim-cli --tty table` output, which must
      // byte-match the oracle).
      dirtyLock.lock()
      substates.remove(oldState)
      substatesDirty = true
      dirtyLock.unlock()
      oldState.parentStateRef = nil
      oldState.parentCompRef = nil
    }
    let newState = CircuitState(
      project: projectRef, circuit: circ, propagator: basePropagator)
    dirtyLock.lock()
    substates.insert(newState)
    substatesDirty = true
    dirtyLock.unlock()
    newState.parentStateRef = self
    newState.parentCompRef = comp
    componentData.put(comp, newState)
    return newState
  }

  /// `replaceData(Component, Object)`.
  ///
  /// *"This happens when subcirc is copy/paste/moved, which causes a new component to be
  /// created, and we want to transfer the now-defunct component's state over to the
  /// newly-created component."*
  private func replaceData(_ comp: any SimComponent, _ data: Any?) {
    if let sub = data as? CircuitState {
      // data was already removed from componentData[orig]; it is registered under
      // componentData[comp] below. `parentComp` must be set; `substates` need not be added to,
      // because it should already be there.
      sub.parentCompRef = comp
      let old = componentData.put(comp, data) as? CircuitState
      dirtyLock.lock()
      if let old {
        substates.remove(old)
        old.parentStateRef = nil
      }
      sub.parentStateRef = self
      substates.insert(sub)
      substatesDirty = true
      dirtyComponents.append(comp)
      dirtyLock.unlock()
    } else {
      componentData.put(comp, data)
    }
  }

  /// `setData(Component, Object)`.
  public func setData(_ comp: any SimComponent, _ data: Any?) {
    if let state = data as? CircuitState {
      // Upstream prints "fixme: setData with circuitstate... should never happen" and dumps the
      // stack. The kernel does not write to stdout; the assignment it performs is kept.
      state.parentCompRef = comp
    }
    componentData.put(comp, data)
  }

  // MARK: - Clocks

  private var knownClocks = false
  private var temporaryClock: (any SimComponent)?

  /// `hasKnownClocks()`.
  public var hasKnownClocks: Bool { knownClocks || temporaryClock != nil }

  /// `markKnownClocks()`.
  public func markKnownClocks() { knownClocks = true }

  /// `setTemporaryClock(Component)`.
  @discardableResult
  public func setTemporaryClock(_ clk: (any SimComponent)?) -> Bool {
    temporaryClock = clk
    return clk == nil || temporaryClockValidateOrTick(-1)
  }

  /// `getTemporaryClock()`.
  public var temporaryClockComponent: (any SimComponent)? { temporaryClock }

  /// `toggleClocks(int)`.
  @discardableResult
  public func toggleClocks(_ ticks: Int) -> Bool {
    var hasClocks = false
    if temporaryClock != nil {
      // Java: `hasClocks |= ...`, a non-short-circuiting or. The right-hand side has side
      // effects (it can null `temporaryClock` and drive the pin), so it must always run.
      let temporary = temporaryClockValidateOrTick(ticks)
      hasClocks = hasClocks || temporary
    }

    for clock in circuit.clockComponents {
      hasClocks = true
      let dirty = clock.clockTick(in: self, ticks: ticks)
      if dirty {
        markComponentAsDirty(clock)
        // If simulator is in single step mode, we want to highlight the invalidated components
        // (which are likely Pins, Buttons, or other inputs), so pass this component to the
        // simulator for display.
        projectRef?.simulator?.addPendingInput(self, clock)
      }
    }

    dirtyLock.lock()
    if substatesDirty {
      substatesDirty = false
      substatesWorking = substates.elements
    }
    dirtyLock.unlock()

    for substate in substatesWorking {
      // Java: `hasClocks |= substate.toggleClocks(ticks)`: a *non*-short-circuiting or, so
      // every substate is visited even once one has reported a clock. `||` would skip them.
      let sub = substate.toggleClocks(ticks)
      hasClocks = hasClocks || sub
    }
    return hasClocks
  }

  /// `temporaryClockValidateOrTick(int)`.
  ///
  /// The `Pin` half lives behind `SimComponent.temporaryClockTick` (D9: `Pin` is in `LogisimStd`
  /// and the kernel cannot name it); the control flow, including which exits null the temporary
  /// clock, stays here.
  private func temporaryClockValidateOrTick(_ ticks: Int) -> Bool {
    guard let clock = temporaryClock else { return false }
    switch clock.temporaryClockTick(in: self, ticks: ticks) {
    case .invalid:
      // Covers both upstream exits: the `ClassCastException` catch and the
      // `instance == null || !isInputPin || width != 1` guard.
      temporaryClock = nil
      return false
    case .valid(let drove):
      if drove {
        markComponentAsDirty(clock)
        // Single-step highlighting, as above.
        projectRef?.simulator?.addPendingInput(self, clock)
      }
      return true
    }
  }

  // MARK: - Circuit events

  /// The body of upstream's `MyCircuitListener.circuitChanged(CircuitEvent)`.
  private func handleCircuitEvent(_ event: SimCircuitEvent) {
    switch event.action {
    case .add:
      // Component was added.
      // Nothing to do: CircuitWires.Connectivity will be voided, causing everything to be
      // marked dirty.
      break

    case .remove:
      // Component was removed.
      guard let comp = event.component else { return }
      if comp === temporaryClock { temporaryClock = nil }
      if comp.factoryRoles.contains(.clock) {
        knownClocks = false  // just in case, will be recomputed by simulator
      }
      if comp.factoryRoles.contains(.subcircuit) {
        knownClocks = false  // just in case, will be recomputed by simulator
        // disconnect from tree
        if let substate = getData(comp) as? CircuitState, substate.parentCompRef === comp {
          dirtyLock.lock()
          substates.remove(substate)
          substatesDirty = true
          dirtyLock.unlock()
          substate.parentStateRef = nil
          substate.parentCompRef = nil
          substate.reset()
        }
      } else if let guiProvider = getData(comp) as? any ComponentDataGuiProvider {
        guiProvider.destroy()
      }
      // Upstream distinguishes `comp instanceof Wire` (nothing to do) from everything else, and
      // its comment says the same thing in both arms: CircuitWires.Connectivity will be voided,
      // causing everything to be marked dirty. Only the non-wire arm purges the dirty list. A
      // `Wire` is never in `dirtyComponents` (it is not in `getNonWires()` and nothing marks it
      // dirty), so removing the distinction would be safe, but the port keeps the guard
      // explicit via `isWire` rather than relying on that reasoning.
      if !comp.isWire {
        dirtyLock.lock()
        // Java: `while (dirtyComponents.remove(comp)) {}`; the list can hold the same component
        // several times, and `ArrayList.remove` drops one occurrence per call.
        dirtyComponents.removeAll { $0 === comp }
        dirtyLock.unlock()
      }

    case .clear:
      // Whole circuit was cleared.
      temporaryClock = nil
      knownClocks = false
      wireData = nil
      for comp in componentData.components {
        if let dataGuiProvider = componentData.value(for: comp) as? any ComponentDataGuiProvider {
          dataGuiProvider.destroy()
        } else if let circuitState = componentData.value(for: comp) as? CircuitState {
          circuitState.reset()
        }
      }
      componentData.removeAll()
      valuesLock.lock()
      slowpathValues.removeAll()  // slow path
      clearFastpathGrid()  // fast path
      valuesLock.unlock()
      dirtyLock.lock()
      dirtyComponents.removeAll()
      dirtyPoints.removeAll()
      substates.removeAll()
      substatesWorking = []
      substatesDirty = true
      dirtyLock.unlock()

    case .invalidate:
      // Component ends changed.
      guard let comp = event.component else { return }
      markComponentAsDirty(comp)
      // If simulator is in single step mode, we want to highlight the invalidated components
      // (which are likely Pins, Buttons, or other inputs), so pass this component to the
      // simulator for display.
      projectRef?.simulator?.addPendingInput(self, comp)

    case .transactionDone:
      guard let map = event.replacementMap else { return }
      for comp in map.removals {
        let compState = componentData.remove(comp)
        // ─────────────────────────────────────────────────────────────────────────────────
        // PRESERVED VERBATIM; this `continue` is upstream's, and it is inverted.
        //
        // The comment on `replaceData` says the point of this loop is to *transfer* a defunct
        // component's state to its replacement. But the guard skips the rest of the body
        // exactly when there IS state to transfer, so:
        //
        //   * `replaceData(repl, compState)` is only ever reached with `compState == nil`,
        //     i.e. it only ever writes a null entry;
        //   * the `RamState` -> `Ram.closeHexFrame` branch is unreachable;
        //   * the `CircuitState` -> detach-substate branch is unreachable.
        //
        // Net effect in 4.1.0: a copy/pasted or moved subcircuit does NOT carry its state over,
        // and the map entry is simply dropped. Do not "fix" this; the differential gate holds
        // the port to upstream's behaviour, not to upstream's intent.
        // ─────────────────────────────────────────────────────────────────────────────────
        if compState != nil { continue }
        let compFactory = comp.factoryTypeIdentity
        var found = false
        for repl in map.replacements(for: comp) {
          if repl.factoryTypeIdentity == compFactory {
            found = true
            replaceData(repl, compState)
            break
          }
        }
        if !found, let ramState = compState as? any SimHexFrameOwner {
          ramState.closeHexFrame()
        }
        if !found, let sub = compState as? CircuitState {
          sub.parentStateRef = nil
          dirtyLock.lock()
          substates.remove(sub)
          substatesDirty = true
          dirtyLock.unlock()
        }
      }
    }
  }

  // MARK: - Description

  /// `toString()`, `"State" + id + "[" + circuit.getName() + "]"`.
  public var description: String {
    "State\(id)[\(circuit.circuitName)]"
  }
}

extension SimComponent {
  /// `comp instanceof Wire`, for the removal handler.
  ///
  /// Defaulted `false` so only `Wire` itself has to say otherwise. `Wire` lives in `LogisimFile`
  /// and cannot be named from the kernel (D9).
  public var isWire: Bool { false }
}
