// ComponentState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). Java sources covered by this file:
//
//   com/cburch/logisim/comp/ComponentState.java              -> SimComponentState
//   com/cburch/logisim/instance/InstanceData.java            -> SimInstanceData
//   com/cburch/logisim/circuit/ComponentDataGuiProvider.java -> ComponentDataGuiProvider
//
// plus the **seam protocols** `CircuitState` needs for the objects it does not own. Everything
// from `SimComponent` downwards is a port seam, not a translation of a Java file: it is the
// minimum surface `CircuitState.java` touches on `Component`, `Circuit`, `CircuitWires`,
// `Propagator`, `Project` and `Simulator`.
//
// ── Why these are protocols and not the real types ──────────────────────────────────────────
//
// D9 fixes the module order `LogisimKernel -> LogisimFile -> ... -> LogisimUI`, and this file
// sits at the bottom of it. `Circuit`, `Component`, `EndData` and `InstanceFactory` all live in
// `LogisimFile`/`LogisimStd`, i.e. *above* the kernel, so the kernel cannot name them. Java has
// no such constraint, everything is one flat classpath, which is exactly why upstream's
// `CircuitState` reaches directly into `Clock`, `Pin`, `Ram`, `Buzzer` and `TelnetServer` from
// `com.cburch.logisim.std`. Those five reach-ins become the five behaviour hooks on
// `SimComponent` below; the control flow around them stays in `CircuitState.swift`, so the
// observable behaviour is still decided here rather than by the conformer.
//
// Naming: every seam is prefixed `Sim` so it cannot collide with the same-named concrete type
// in `LogisimFile` (`Component`, `Circuit`, `CircuitEvent`, `CircuitListener` all already exist
// there, and `LogisimFile` imports this module).

import Foundation

// MARK: - com.cburch.logisim.comp.ComponentState

/// `com.cburch.logisim.comp.ComponentState`: `Object clone()`.
///
/// Java's single `clone()` requirement, spelled explicitly because Swift has no `Object.clone`.
/// `CircuitState.copyFrom` calls it on every non-`CircuitState` value in `componentData`.
/// The return type is `Any` rather than `Self` to match Java's `Object clone()`: the value
/// goes straight back into the untyped `componentData` map and is never statically consumed.
public protocol SimComponentState: AnyObject {
  /// `clone()`.
  func cloneComponentState() -> Any
}

/// `com.cburch.logisim.instance.InstanceData`: a marker refinement, exactly as in Java, where
/// it re-declares `clone()` and adds nothing.
///
/// SEAM: `LogisimStd` already declares its own `InstanceData` protocol (with `cloneData()`),
/// because components had to be written before the kernel existed. The two must be unified by
/// the integrator: see the report. `CircuitState` conforms to *this* one, because a subcircuit's
/// component data *is* a `CircuitState`.
public protocol SimInstanceData: SimComponentState {}

/// `com.cburch.logisim.circuit.ComponentDataGuiProvider`.
///
/// Component data that owns a window/native resource and must be torn down when the state is
/// reset, cleared, or the owning component is removed. Kept UI-free per D9: the kernel only ever
/// calls `destroy()`; what that destroys is the upper layer's business.
public protocol ComponentDataGuiProvider: AnyObject {
  /// `destroy()`.
  func destroy()
}

/// SEAM for `com.cburch.logisim.std.io.TelnetServer`, which `CircuitState.reset` special-cases.
public protocol SimTelnetServerData: AnyObject {
  /// `deleteAll()`.
  func deleteAll()
}

/// SEAM for `com.cburch.logisim.std.memory.RamState`, which `CircuitState`'s
/// `TRANSACTION_DONE` handler special-cases via `Ram.closeHexFrame(state)`.
///
/// Note that upstream can never reach that call, see the `transactionDone` handler in
/// `CircuitState.swift` for why, but the branch is ported verbatim regardless.
public protocol SimHexFrameOwner: AnyObject {
  /// `Ram.closeHexFrame(RamState)`.
  func closeHexFrame()
}

// MARK: - Component seam

/// Which of the five `std` factories upstream's `CircuitState` tests for with `instanceof`.
///
/// `CircuitState.java` branches on `comp.getFactory() instanceof {Clock, Pin, SubcircuitFactory,
/// Ram, Buzzer}` and on `factory instanceof InstanceFactory`. None of those types is visible from
/// the kernel (D9), so the conformer reports its roles and the branching logic stays here.
public struct SimFactoryRole: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// `getFactory() instanceof InstanceFactory`, gates `getInstanceState`.
  public static let instanceFactory = SimFactoryRole(rawValue: 1 << 0)
  /// `getFactory() instanceof SubcircuitFactory`.
  public static let subcircuit = SimFactoryRole(rawValue: 1 << 1)
  /// `getFactory() instanceof Clock`.
  public static let clock = SimFactoryRole(rawValue: 1 << 2)
  /// `getFactory() instanceof Pin`.
  public static let pin = SimFactoryRole(rawValue: 1 << 3)
  /// `getFactory() instanceof Ram`.
  public static let ram = SimFactoryRole(rawValue: 1 << 4)
  /// `getFactory() instanceof Buzzer`.
  public static let buzzer = SimFactoryRole(rawValue: 1 << 5)
}

/// The outcome of upstream's `CircuitState.temporaryClockValidateOrTick`, minus the parts that
/// need `Pin`.
///
/// The Java method does three things at once: it validates that `temporaryClock` is still a
/// 1-bit input `Pin`, it drives the pin on even/odd ticks, and it reports back. Only the middle
/// third needs `Pin`; the rest is control flow that stays in `CircuitState`. `.invalid` covers
/// **both** of Java's failure exits, the `ClassCastException` catch and the
/// `instance == null || !isInputPin || width != 1` guard, because both do exactly
/// `temporaryClock = null; return false;`.
public enum TemporaryClockOutcome: Hashable, Sendable {
  /// Java: the `catch (ClassCastException)` exit, or the `instance == null || !pin.isInputPin
  /// || pin.getWidth() != 1` guard. Caller clears `temporaryClock` and returns `false`.
  case invalid
  /// Java: fell through to `return true`. `drove` is true when `!vNew.equals(vOld)` held and
  /// `pin.driveInputPin(state, vNew)` was therefore called, which is what makes the caller mark
  /// the component dirty and register it as a pending input.
  case valid(drove: Bool)
}

/// The seam for `com.cburch.logisim.comp.Component`, restricted to what `CircuitState` uses.
///
/// D4: identity is reference identity. Do **not** add `Equatable`/`Hashable`; use `identity`.
/// **Seam unification (M3 wiring).** This protocol now *refines* the two other component seams
/// the kernel grew independently: `WireComponent` (`CircuitWires.swift`) and
/// `PropagatorComponent` (`PropagationEvent.swift`). All three describe the same Java
/// `com.cburch.logisim.comp.Component`, and before this change a conformer above the kernel had
/// to satisfy three unrelated protocols with no compiler check that it had answered them
/// consistently: e.g. `wireRole == .wire` while `isWireOrSplitter == false`, which silently
/// schedules delayed events for a wire. One protocol makes the inconsistency unrepresentable and
/// lets `CircuitWires`' component lists be marked dirty without a downcast that could fail.
public protocol SimComponent: WireComponent, PropagatorComponent {

  /// D4's sanctioned key. Defaulted; never override.
  var identity: ObjectIdentifier { get }

  /// The `instanceof` answers for `getFactory()`. See `SimFactoryRole`.
  var factoryRoles: SimFactoryRole { get }

  /// `comp.getAttributeSet()`.
  ///
  /// Non-optional, unlike `WireComponent.wireAttributeSet`: every Java `Component` has one, and
  /// `InstanceStateImpl.getAttributeSet()` returns it unconditionally. The wiring layer's
  /// optional exists only so a component can opt out of the tunnel/pull attribute listener.
  var componentAttributeSet: any AttributeSet { get }

  /// `InstanceComponent.fireInvalidated()`, reached from `InstanceState.fireInvalidated()`.
  ///
  /// Non-throwing: upstream's implementation only walks a listener array.
  func fireComponentInvalidated()

  /// `comp.getFactory().getClass()`, for the `TRANSACTION_DONE` replacement search
  /// (`repl.getFactory().getClass() == compFactory`). Conformers must return
  /// `ObjectIdentifier(type(of: factory))`: a *metatype* identity, not the factory instance's.
  var factoryTypeIdentity: ObjectIdentifier { get }

  /// `Component.propagate(CircuitState)`.
  ///
  /// D1/D2: synchronous and non-reentrant; never `async`. `throws` per D13 and to match
  /// `InstanceFactory.propagate(InstanceState) throws` as already ported in `LogisimStd`:
  /// upstream lets an unchecked exception out of here and `Simulator` turns it into a circuit
  /// error the user sees, so a trap would convert a recoverable fault into a process kill.
  func propagate(in state: CircuitState) throws

  /// `Clock.tick(CircuitState, int, Component)`; returns whether the clock changed and the
  /// component must therefore be marked dirty. Only called when `factoryRoles` contains
  /// `.clock`.
  ///
  /// Non-throwing, unlike `propagate`: upstream's `Clock.tick`, `Ram.reset`,
  /// `Buzzer.stopBuzzerSound` and the `Pin` half of `temporaryClockValidateOrTick` are all
  /// housekeeping paths that no malformed `.circ` reaches, and making them throw would force
  /// `reset()` and `toggleClocks()`, both called from the non-throwing `CircuitListener`
  /// callback, to swallow errors instead of surfacing them. D13 asks for `throw` where Java
  /// throws something `Simulator.recordException` can catch; that is `propagate`, and only
  /// `propagate`.
  func clockTick(in state: CircuitState, ticks: Int) -> Bool

  /// `Ram.reset(CircuitState, Instance)`; returns the `remove` flag, i.e. whether the caller
  /// should null out this component's entry in `componentData`. Only called when `factoryRoles`
  /// contains `.ram`.
  func resetRamState(in state: CircuitState) -> Bool

  /// `Buzzer.stopBuzzerSound(Component, CircuitState)`. Only called when `factoryRoles`
  /// contains `.buzzer`.
  func stopBuzzerSound(in state: CircuitState)

  /// The `Pin`-dependent half of `temporaryClockValidateOrTick`; see `TemporaryClockOutcome`.
  ///
  /// The conformer must obtain its `InstanceState` from
  /// `state.unvalidatedReusableInstanceState(for:)`, which is the exact call upstream makes
  /// (`getReusableInstanceState(instance)`: the `Instance` overload, which performs **no**
  /// factory check). Using the validating overload here would throw on a component upstream
  /// accepts.
  func temporaryClockTick(in state: CircuitState, ticks: Int) -> TemporaryClockOutcome
}

extension SimComponent {
  public var identity: ObjectIdentifier { ObjectIdentifier(self) }

  /// The wiring layer's optional attribute set is the same object, so a conformer answers once.
  public var wireAttributeSet: (any AttributeSet)? { componentAttributeSet }

  /// `cause instanceof Wire || cause instanceof Splitter`; derived from `wireRole` so the two
  /// answers cannot disagree. See the note on `SimComponent`.
  public var isWireOrSplitter: Bool { wireRole == .wire || wireRole == .splitter }

  /// `cause.getFactory() instanceof SubcircuitFactory`: derived from `factoryRoles`, same
  /// reason.
  public var isSubcircuitComponent: Bool { factoryRoles.contains(.subcircuit) }

  /// Most components have no listeners to notify.
  public func fireComponentInvalidated() {}

  /// Defaults for the four `std` reach-ins, so an ordinary component implements `propagate`
  /// alone. Each default is the branch upstream takes when the `instanceof` fails, which is why
  /// they are unreachable rather than merely inert: `CircuitState` guards every call with the
  /// corresponding `factoryRoles` test.
  public func clockTick(in state: CircuitState, ticks: Int) -> Bool { false }
  public func resetRamState(in state: CircuitState) -> Bool { false }
  public func stopBuzzerSound(in state: CircuitState) {}
  public func temporaryClockTick(in state: CircuitState, ticks: Int) -> TemporaryClockOutcome
  {
    // Upstream's `(Pin) temporaryClock.getFactory()` cast fails here.
    .invalid
  }
}

// MARK: - Circuit seam

/// The seam for `com.cburch.logisim.circuit.Circuit`, restricted to what `CircuitState` uses.
///
/// SEAM: `LogisimFile.Circuit` must conform. See the report for the mapping.
public protocol SimCircuit: AnyObject {

  /// Apply any edits the *editing* thread has queued, on the **propagation** thread.
  ///
  /// CircuitState.processDirtyPoints drains before propagation uses connectivity, preserving
  /// edit/event order without replacing CircuitState and losing componentData. This queue is
  /// not the topology lock: CircuitWires also has query callers on other threads and protects
  /// its collections itself. CircuitState event handling remains propagation-thread-owned.
  ///
  /// The default is a no-op: a circuit with no editor behind it queues nothing.
  func applyPendingEdits()

  /// `getName()`; used only by `CircuitState.toString()`.
  var circuitName: String { get }

  /// `getNonWires()`.
  ///
  /// Upstream returns a `Set<Component>`, so its iteration order is JVM hash order. The port
  /// returns an ordered collection, which the differential harness needs: two runs of the same
  /// file must mark components dirty in the same order.
  var nonWireComponents: [any SimComponent] { get }

  /// `getClocks()`.
  var clockComponents: [any SimComponent] { get }

  /// `getWidth(Location)`.
  func width(at point: Location) -> BitWidth

  /// `isConnected(Location, Component)`; whether anything *other than* `component` has a
  /// connection point at `location`. Backs `InstanceState.isPortConnected(int)`.
  func isConnected(_ location: Location, ignoring component: any SimComponent) -> Bool

  /// `addCircuitListener` / `removeCircuitListener`.
  ///
  /// **D5's subscription pattern, made structural.** The previous shape was a bare
  /// `addCircuitListener(_:)` with a *prose* instruction that the conformer hold listeners
  /// weakly, and nothing checked it: a conformer that used a plain array would pin every
  /// `CircuitState` ever created to its `Circuit` and leak the whole state tree on file close:
  /// exactly D3's failure mode, and invisible to every test. Returning a token moves the
  /// lifetime decision to the *caller*, which is the party that actually knows it: `CircuitState`
  /// stores the token, dropping it unsubscribes, and no circuit→state strong edge can exist by
  /// construction.
  ///
  /// `removeCircuitListener` is gone with it; `token.cancel()` (or releasing the token) is the
  /// only way to unsubscribe, so there is no second, unpaired path to get it wrong.
  func addCircuitListener(_ listener: any SimCircuitListener) -> CircuitSubscription

  /// `circuit.wires`.
  ///
  /// Concrete rather than a protocol: `CircuitWires` lives in *this* module (see
  /// `CircuitWires.swift`), so the `SimCircuitWires`/`SimWireState`/`SimBusConnection` seams
  /// this file used to declare were indirection across a boundary that does not exist. Worse,
  /// their signatures had drifted from the real class, `newState` throws and takes a
  /// `WireCircuitState`, `propagate` is generic over `WireDirtyPoint`, so nothing could ever
  /// have conformed. Naming the class directly is what lets `CircuitState.wireData` be a real
  /// `CircuitWires.State?` and satisfy `WireCircuitState`.
  var wireStore: CircuitWires { get }
}

// MARK: - Circuit listener subscription

/// The token `SimCircuit.addCircuitListener` returns, mirroring `AttributeSubscription` (D5) and
/// `ComponentSubscription`.
///
/// D3: the registry holds the token weakly and the token holds the listener strongly, so
/// dropping the token unsubscribes and no circuit→listener strong edge exists.
public final class CircuitSubscription {
  /// Strong; this is the edge that keeps the listener alive.
  public let listener: any SimCircuitListener

  private let onCancel: () -> Void
  private var cancelled = false

  public init(listener: any SimCircuitListener, onCancel: @escaping () -> Void) {
    self.listener = listener
    self.onCancel = onCancel
  }

  /// Unsubscribe now. Idempotent.
  public func cancel() {
    guard !cancelled else { return }
    cancelled = true
    onCancel()
  }

  deinit { cancel() }
}

/// The listener list a `SimCircuit` conformer embeds, so every conformer gets the D3-correct
/// lifetime instead of reimplementing it.
public final class CircuitListenerRegistry {
  private struct Entry {
    let identifier: UInt64
    weak var token: CircuitSubscription?
  }

  private var entries: [Entry] = []
  private var nextIdentifier: UInt64 = 1

  public init() {}

  public func add(_ listener: any SimCircuitListener) -> CircuitSubscription {
    let identifier = nextIdentifier
    nextIdentifier += 1
    let token = CircuitSubscription(listener: listener) { [weak self] in
      self?.entries.removeAll { $0.identifier == identifier }
    }
    entries.append(Entry(identifier: identifier, token: token))
    return token
  }

  /// Snapshot before dispatching: a handler routinely mutates the circuit and therefore the list.
  public func fire(_ event: SimCircuitEvent) {
    entries.removeAll { $0.token == nil }
    for listener in entries.compactMap({ $0.token?.listener }) {
      listener.circuitChanged(event)
    }
  }
}

// MARK: - Project / Simulator seam

/// The seam for `com.cburch.logisim.proj.Project`, restricted to what `CircuitState` uses:
/// `proj.getSimulator()` and (in the root constructor) `proj.getSimulator().simThread`.
///
/// D9: the kernel must not see `Project` itself: 287 of upstream's 1,204 files reach
/// `AppPreferences` through that object graph and none of that coupling comes across.
public protocol SimProject: AnyObject {
  /// `getSimulator()`.
  var simulator: (any SimSimulator)? { get }

  /// `getOptions().getAttributeSet()`, as `Propagator` reads it (`Propagator.java:138`).
  ///
  /// Routed through the project rather than asked of `CircuitState` directly because that is
  /// where upstream gets it, and because it is the one thing that makes a file's `simrand` /
  /// `simlimit` settings reach the engine. A host with no project returns `nil` and the
  /// propagator falls back to Java's own defaults, see `PropagatorCircuitState.simulationOptions`.
  var simulationOptions: (any PropagatorOptionsSource)? { get }
}

extension SimProject {
  /// Headless hosts that carry no `<options>` element get Java's defaults.
  public var simulationOptions: (any PropagatorOptionsSource)? { nil }
}

/// The seam for `com.cburch.logisim.circuit.Simulator`, restricted to what `CircuitState` uses.
///
/// SEAM: `LogisimKernel/Simulation/` is another workflow's territory (the D7 phase-anchored
/// clock). This protocol is what `CircuitState` needs from whatever `Simulator` lands there.
public protocol SimSimulator: AnyObject {
  /// `simThread`; the thread a newly created root `Propagator` is bound to. May be `nil` in a
  /// headless run, in which case `Propagator` uses the calling thread, exactly as upstream's
  /// `CircuitState(proj, circuit, prop, thread)` does.
  var simulationThread: Thread? { get }

  /// `addPendingInput(CircuitState, Component)`: single-step-mode highlighting of the
  /// components an event invalidated.
  func addPendingInput(_ state: CircuitState, _ component: any SimComponent)
}

// MARK: - Circuit event seam

/// `com.cburch.logisim.circuit.CircuitEvent`'s action codes, restricted to the five
/// `CircuitState.MyCircuitListener` handles. Every other upstream action falls through its
/// `if`/`else if` chain and does nothing, which `CircuitState` reproduces by ignoring anything
/// not in this enum.
public enum SimCircuitEventAction: Hashable, Sendable {
  /// `ACTION_ADD`.
  case add
  /// `ACTION_REMOVE`.
  case remove
  /// `ACTION_CLEAR`.
  case clear
  /// `ACTION_INVALIDATE`.
  case invalidate
  /// `TRANSACTION_DONE`.
  case transactionDone
}

/// `com.cburch.logisim.circuit.CircuitEvent`, restricted to what `CircuitState` reads.
public struct SimCircuitEvent {
  public let action: SimCircuitEventAction

  /// `(Component) event.getData()`; set for `.remove` and `.invalidate`.
  public let component: (any SimComponent)?

  /// `event.getResult().getReplacementMap(circuit)`; set for `.transactionDone`. `nil` is
  /// upstream's early return.
  public let replacementMap: (any SimReplacementMap)?

  public init(
    action: SimCircuitEventAction,
    component: (any SimComponent)? = nil,
    replacementMap: (any SimReplacementMap)? = nil
  ) {
    self.action = action
    self.component = component
    self.replacementMap = replacementMap
  }
}

/// The seam for `com.cburch.logisim.circuit.ReplacementMap`.
public protocol SimReplacementMap: AnyObject {
  /// `getRemovals()`.
  var removals: [any SimComponent] { get }
  /// `getReplacementsFor(Component)`.
  func replacements(for component: any SimComponent) -> [any SimComponent]
}

/// `com.cburch.logisim.circuit.CircuitListener`.
extension SimCircuit {
  /// Nothing queued, nothing to do; the headless and test circuits that have no editor.
  public func applyPendingEdits() {}
}

public protocol SimCircuitListener: AnyObject {
  /// `circuitChanged(CircuitEvent)`.
  func circuitChanged(_ event: SimCircuitEvent)
}

// MARK: - InstanceStateImpl seam

/// The seam for `com.cburch.logisim.instance.InstanceStateImpl`.
///
/// Only `repurpose` is declared, because that is the only method `CircuitState` calls on it,
/// and it is the whole point of standing rule 4. The full `InstanceState` surface (ports,
/// attributes, data, tick count) already exists one module up in
/// `LogisimStd/Instance/InstanceState.swift`; the concrete `InstanceStateImpl` conforms to
/// both, and callers there see the richer protocol.
///
/// **Aliasing warning, preserved deliberately.** `CircuitState.reusableInstanceState(for:)`
/// returns one object per `CircuitState`, repurposed in place. Two live references to "different"
/// reusable instance states within one circuit state are the *same object*, so the second call
/// silently invalidates the first. Upstream documents this as *"should only be called using the
/// propagate thread and with care that there is no conflict with other uses"*, and D1/D2 exist
/// to keep it true: propagation is synchronous, single-threaded and non-reentrant, which is the
/// only reason a shared mutable scratch object is safe. Do not "fix" it by allocating per call:
/// upstream measures that as roughly a 90% slowdown on the propagation path.
///
/// **ARC contract.** The conformer must hold its `CircuitState` `unowned` (or `weak`).
/// `CircuitState` owns exactly one of these per state and hands it back repeatedly, so a strong
/// field here is an unconditional two-cycle on *every* circuit state in the tree: one of D3's
/// nine, and the one the propagation fast path would hit most often. Its `component` reference,
/// by contrast, should be **strong**: upstream's reference keeps a just-removed component alive
/// for as long as the scratch object still points at it, and `unowned` would turn that into a
/// crash the next time the object is read.
public protocol SimInstanceStateImpl: AnyObject {
  /// `repurpose(CircuitState, Component)`.
  ///
  /// Note that upstream's *constructor* additionally calls
  /// `instComp.setInstanceStateImpl(this)` while `repurpose` does **not**. Conformers must
  /// reproduce that asymmetry: the reusable object is never registered on the component.
  func repurpose(_ state: CircuitState, _ component: (any SimComponent)?)
}

/// How `CircuitState` builds `InstanceStateImpl`s. Injected because the concrete type needs
/// `Component`, `EndData`, `AttributeSet` and `InstanceFactory`, which live above the kernel.
///
/// SEAM: the integrator must install this once at start-up (see the report).
public typealias SimInstanceStateFactory =
  (_ state: CircuitState, _ component: (any SimComponent)?) -> any SimInstanceStateImpl

/// How `CircuitState` builds a root `Propagator`, for the same reason.
///
/// SEAM: the integrator must install this once at start-up. `thread` is upstream's
/// `thread != null ? thread : proj.getSimulator().simThread`, already resolved.
public typealias SimPropagatorFactory =
  (_ root: CircuitState, _ thread: Thread?) -> Propagator

// MARK: - Errors

/// D13: the exceptions `CircuitState` can raise, as `throw`s rather than traps.
///
/// `getInstanceState` is on the propagation path and upstream's `Simulator` wraps propagation in
/// `catch (Exception err) -> recordException(err)`, so a `preconditionFailure` here would turn a
/// circuit error the user can see into an app crash with unsaved work lost.
public enum CircuitStateError: Error, CustomStringConvertible, Equatable {
  /// `throw new RuntimeException("getInstanceState requires instance component")`.
  case notAnInstanceComponent

  /// `throw new IllegalStateException("instanceComponent.getInstance().getComponent() is wrong")`.
  ///
  /// Unreachable in the port: D3 deletes the `Instance` facade, so there is no second object
  /// whose `getComponent()` could disagree. Kept as a case so the seam can report the condition
  /// if a conformer ever reintroduces the split.
  case instanceComponentMismatch

  /// `throw new IllegalStateException("INTERNAL ERROR: dirtyComponentsWorking not empty")`.
  case dirtyComponentsWorkingNotEmpty

  /// `throw new IllegalStateException("INTERNAL ERROR: dirtyPointsWorking not empty")`.
  case dirtyPointsWorkingNotEmpty

  public var description: String {
    switch self {
    case .notAnInstanceComponent:
      return "getInstanceState requires instance component"
    case .instanceComponentMismatch:
      return "instanceComponent.getInstance().getComponent() is wrong"
    case .dirtyComponentsWorkingNotEmpty:
      return "INTERNAL ERROR: dirtyComponentsWorking not empty"
    case .dirtyPointsWorkingNotEmpty:
      return "INTERNAL ERROR: dirtyPointsWorking not empty"
    }
  }
}

// MARK: - componentData storage

/// `HashMap<Component, Object>` with reference-identity keys (D4) and a stable iteration order.
///
/// Two properties of the Java map are load-bearing and easy to lose:
///
///  1. **A `null` value is not a removal.** `CircuitState.reset()` does
///     `componentData.put(comp, null)` and then `copyFrom` iterates `keySet()`, so the
///     component must still be *present* with a `nil` value. A plain `[K: Any?]` in Swift
///     collapses that distinction on subscript assignment, hence the explicit `Entry`.
///  2. **The key is held strongly.** Upstream's map pins the `Component` until the entry is
///     removed, and `copyFrom`/`reset` both iterate the key set. This is not a D3 violation:
///     the owning edge is `CircuitState -> componentData`, and nothing a component holds points
///     back at a `CircuitState` strongly (`InstanceComponent.instanceState` is weak per D3), so
///     no cycle exists. The eviction owner is the `TRANSACTION_DONE`/`ACTION_CLEAR` handler,
///     matching upstream exactly.
///
/// Iteration order is insertion order rather than Java's hash order. That is a deliberate
/// determinism fix of the same family as D14: `reset()` and the `ACTION_CLEAR` handler iterate
/// `keySet()`, and their side effects (RAM reset, buzzer stop, GUI teardown) should not depend
/// on JVM hash layout.
struct ComponentDataMap {
  struct Entry {
    /// Strong, mirroring the Java map key. See the note above.
    let component: any SimComponent
    var data: Any?
  }

  private var storage: [ObjectIdentifier: Entry] = [:]
  private var order: [ObjectIdentifier] = []

  init() {}

  /// `keySet()`, in insertion order.
  var components: [any SimComponent] {
    order.compactMap { storage[$0]?.component }
  }

  var isEmpty: Bool { storage.isEmpty }

  /// `get(comp)`.
  func value(for component: any SimComponent) -> Any? {
    storage[component.identity]?.data
  }

  /// `containsKey(comp)`.
  func contains(_ component: any SimComponent) -> Bool {
    storage[component.identity] != nil
  }

  /// `put(comp, data)`; inserts the key even when `data` is `nil`. Returns the previous value,
  /// as Java's `put` does.
  @discardableResult
  mutating func put(_ component: any SimComponent, _ data: Any?) -> Any? {
    let key = component.identity
    if let existing = storage[key] {
      storage[key] = Entry(component: existing.component, data: data)
      return existing.data
    }
    storage[key] = Entry(component: component, data: data)
    order.append(key)
    return nil
  }

  /// `remove(comp)`. Returns the removed value.
  @discardableResult
  mutating func remove(_ component: any SimComponent) -> Any? {
    let key = component.identity
    guard let existing = storage.removeValue(forKey: key) else { return nil }
    if let index = order.firstIndex(of: key) { order.remove(at: index) }
    return existing.data
  }

  /// `clear()`.
  mutating func removeAll() {
    storage.removeAll()
    order.removeAll()
  }
}

/// An identity-keyed, insertion-ordered stand-in for `HashSet<CircuitState>`.
///
/// `CircuitState` does not override `equals`/`hashCode`, so upstream's set is an identity set;
/// D4 says the port keys on `ObjectIdentifier` and never on structural equality. Order is
/// insertion order for the same determinism reason as `ComponentDataMap`: upstream's
/// `substates.toArray(substatesWorking)` hands `processDirtyComponents` the substates in JVM
/// hash order, which is not reproducible across runs.
struct SubstateSet {
  private var storage: [ObjectIdentifier: CircuitState] = [:]
  private var order: [ObjectIdentifier] = []

  init() {}

  var isEmpty: Bool { storage.isEmpty }

  var elements: [CircuitState] {
    order.compactMap { storage[$0] }
  }

  mutating func insert(_ state: CircuitState) {
    let key = ObjectIdentifier(state)
    if storage.updateValue(state, forKey: key) == nil {
      order.append(key)
    }
  }

  mutating func remove(_ state: CircuitState) {
    let key = ObjectIdentifier(state)
    guard storage.removeValue(forKey: key) != nil else { return }
    if let index = order.firstIndex(of: key) { order.remove(at: index) }
  }

  mutating func removeAll() {
    storage.removeAll()
    order.removeAll()
  }
}
