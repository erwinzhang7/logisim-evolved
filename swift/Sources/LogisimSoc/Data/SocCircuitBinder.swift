// SocCircuitBinder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Circuit's `socSim` field and its
// three call sites), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// SEAM #17; A SoC COMPONENT PLACED NORMALLY WAS NEVER REGISTERED
//
// Java's `Circuit` owns a `SocSimulationManager socSim` and calls it from all three mutators:
//
//   `Circuit.java:778`  mutatorAdd    → `socSim.registerComponent(c)`
//   `Circuit.java:827`  mutatorRemove → `socSim.removeComponent(c)`
//   `Circuit.java:844`  mutatorClear  → `socSim.removeComponent(comp)` for every old component
//
// The port's three mutators call none of them, and **could not**: `Circuit` is `LogisimFile`'s
// and `LogisimSoc -> LogisimStd -> LogisimFile`, so the field cannot exist there without closing
// a module cycle. So every SoC component placed through the ordinary editing path, which is
// every SoC component in every `.circ` file, reached no bus fabric at all.
//
// It stayed invisible because **every SoC test registered by hand.** `SocBusFabricTests`'
// fixture even carried a comment saying `Circuit.mutatorAdd` does not do this and that the test
// performs it explicitly. A suite that does the work under test passes whatever the product
// omits; this file's own test (`SocCircuitBinderTests`) never calls `registerComponent`.
//
// ── The join: the `.add`/`.remove`/`.clear` events already fire at exactly those points ──────
//
// `Circuit.fireEvent(.add, .component(c))` is the last statement of `mutatorAdd`, `.remove` the
// last of `mutatorRemove`, and `.clear` carries the whole old component list out of
// `mutatorClear`. A `CircuitListener` living in `LogisimSoc` therefore reproduces all three
// upstream calls with **no new module edge**; the same "register from the side that can see
// both" shape as `BuiltinToolProviders`, `HdlGeneratorLookup`/`BuiltinHdlWiring` and this
// module's own `SocCircuitStateBinding`.
//
// Ordering note, checked rather than assumed: upstream calls `registerComponent` *before* the
// duplicate-label pass and `removeComponent` *before* `factory.removeComponent`, while a
// listener necessarily runs after both. Nothing observable turns on it; `registerComponent`
// and `removeComponent` read `SocBusSelection`/`SocBusIdentifier`, and the two passes they now
// follow write only `StdAttr.label` and per-factory instance data. The `.clear` payload
// preserves `componentOrder`, so the removal order upstream's loop uses is preserved too.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE OPEN DECISION: WHO OWNS THE PER-`Circuit` MANAGER'S LIFETIME
//
// In Java it is a stored field, so the manager is born and dies with its `Circuit`. Swift cannot
// reproduce that here; an extension cannot add a stored property, and the module graph forbids
// putting one on `Circuit` directly.
//
// **Decided: an explicit session object, this class, owns them. `SocCircuitBinder` IS the
// eviction owner, and there is no process-global state anywhere in this file.**
//
// The alternative, a process-global `[ObjectIdentifier: SocSimulationManager]`, is the exact
// shape D3 records as *rejected* for `SimulatedCircuit`: it has no eviction owner, so every
// circuit ever opened leaves a manager (and its `SocBusFabric`/`SocMemoryMap` graph) alive for
// the life of the process. It is also, less obviously, a **correctness** hazard rather than
// merely a leak: `ObjectIdentifier` is an address, addresses are reused after deallocation, and
// a fresh `Circuit` allocated where a dead one used to sit would silently inherit the dead
// circuit's bus fabric. Both problems are closed below;
//
//   * the table is an instance member of a session the caller owns and releases;
//   * every lookup revalidates `binding.circuit === circuit` by reference, so a reused address
//     replaces the stale binding instead of aliasing it (`bindings[key]` alone is never trusted);
//   * `prune()` drops bindings whose circuit has deallocated, on every mutating access;
//   * `deinit` releases the lot.
//
// The other option the brief allows, hanging ownership off whatever creates the simulation
// session, is what this *is*, made explicit rather than implicit: the caller that owns the
// project owns one `SocCircuitBinder`, and closing the project drops every manager with it.
//
// The manager's own edges stay as they were, and that is now load-bearing rather than
// incidental: `SocBusFabric.component`, `SocBusInfo.simulationManager` and
// `SocBusInfo.component` are all `weak`, so a binding pins neither its circuit nor its
// components. The strong edges run one way only, binder → binding → manager, which is the
// direction D3 asks for.
//
// ── `attach` BACKFILLS, and that is why session-scoped ownership is not a behaviour change ───
//
// Upstream registers at *edit* time because the field is free. A session created after a file is
// already loaded would otherwise see only subsequent edits. `attach(to:)` therefore registers
// every component already in the circuit, in `nonWires` order, which is `mutatorAdd` order, so
// the pending-list ("a `.circ` may place slaves before their bus") behaviour
// `drainPendingOnRegistration` implements is reproduced exactly as a sequential load would have
// produced it.
//
// ── What is NOT wired here ──────────────────────────────────────────────────────────────────
//
// Nothing in this file is process-global, so **an executable must create a binder and attach it**
// ; the same integrator step `SocLibrary.registerBuiltinTools()` and
// `BuiltinHdlWiring.installBuiltins()` each needed, and for the same reason. See the hand-off
// note in the task report for the exact `logisim-cli` change. `LogisimUI` cannot make it at all
// today: it does not depend on `LogisimSoc` (Package.swift:176), which is a pre-existing gap
// this file does not widen.
//
// ── Threading (D1) ──────────────────────────────────────────────────────────────────────────
//
// `circuitChanged` can arrive on the propagation thread (D1's corollary: `.invalidate` already
// reaches listeners from there). It touches only the one binding's manager and never `bindings`,
// so the table is mutated solely by `attach`/`detach`/`prune` on the editing thread; the same
// unsynchronised discipline `Circuit`'s own listener list keeps. There is no `@MainActor` type
// in this path, so D1's "hop, never assert" rule has nothing to apply to.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// Owns one `SocSimulationManager` per `Circuit`, for as long as the owner of this object lives.
///
/// This is the port's stand-in for Java's `Circuit.socSim` field, and the answer to "who evicts":
/// whoever holds the binder. Create one per project/simulation session, `attach(to:)` each
/// circuit it should cover, and release it when the project closes.
public final class SocCircuitBinder {

  /// One circuit's subscription. The listener and the manager are the same lifetime, so they are
  /// one object's worth of storage rather than two.
  ///
  /// D3: `circuit` is `weak`. `Circuit` holds its listeners weakly too (`WeakListenerList`), so
  /// nothing here is a cycle in either direction; the binding is kept alive by the binder's
  /// table alone, which is precisely what makes the binder the eviction owner.
  private final class Binding: CircuitListener {
    weak var circuit: Circuit?
    let manager = SocSimulationManager()

    init(circuit: Circuit) {
      self.circuit = circuit
    }

    func circuitChanged(_ event: CircuitEvent) {
      // A binding is only ever subscribed to one circuit; the guard is what makes that a
      // checked property rather than a convention.
      guard event.circuit === circuit else { return }
      switch (event.action, event.data) {
      case (.add, .component(let component)):
        // `Circuit.java:778`. Wires reach this too; upstream's call sits inside the non-`Wire`
        // branch, and `registerComponent` reproduces that by answering `false` for any factory
        // that is not a `SocInstanceFactory`.
        manager.registerComponent(component)
      case (.remove, .component(let component)):
        // `Circuit.java:827`.
        manager.removeComponent(component)
      case (.clear, .components(let components)):
        // `Circuit.java:844`'s loop, over the payload `mutatorClear` hands out, which is
        // `componentOrder`, so upstream's iteration order is preserved.
        for component in components {
          manager.removeComponent(component)
        }
      default:
        break
      }
    }
  }

  private var bindings: [ObjectIdentifier: Binding] = [:]

  public init() {}

  /// Subscribes to `circuit` and returns the manager that will track it, registering every
  /// component the circuit already holds.
  ///
  /// Idempotent: a second call for the same circuit returns the same manager and does not
  /// re-register (`Circuit.addCircuitListener` de-duplicates by identity, and re-running the
  /// backfill would double-register every slave on its fabric).
  @discardableResult
  public func attach(to circuit: Circuit) -> SocSimulationManager {
    prune()
    let key = ObjectIdentifier(circuit)
    // Never trust the key alone: see the header on address reuse.
    if let existing = bindings[key], existing.circuit === circuit {
      return existing.manager
    }

    let binding = Binding(circuit: circuit)
    bindings[key] = binding
    circuit.addCircuitListener(binding)
    for component in circuit.nonWires {
      binding.manager.registerComponent(component)
    }
    return binding.manager
  }

  /// The manager already attached to `circuit`, or `nil`. Deliberately does **not** create one:
  /// a caller that reads a manager it never attached is asking about state it does not own, and
  /// silently minting an empty one would answer "no busses" instead of saying so.
  public func manager(for circuit: Circuit) -> SocSimulationManager? {
    let binding = bindings[ObjectIdentifier(circuit)]
    guard let binding, binding.circuit === circuit else { return nil }
    return binding.manager
  }

  /// Drops the binding for `circuit`, unsubscribing it. The manager and everything it holds go
  /// with it. Called by an owner that outlives the circuit it is discarding: deleting a circuit
  /// from a still-open project.
  public func detach(from circuit: Circuit) {
    let key = ObjectIdentifier(circuit)
    if let binding = bindings[key], binding.circuit === circuit {
      circuit.removeCircuitListener(binding)
      bindings.removeValue(forKey: key)
    }
    prune()
  }

  /// How many circuits this binder currently tracks, after pruning. Exposed so a test, and a
  /// leak check, can assert that a deallocated circuit's manager actually went away, which is
  /// the whole claim this class makes.
  public var attachedCircuitCount: Int {
    prune()
    return bindings.count
  }

  /// Drops bindings whose circuit has deallocated. This is the eviction, and it is cheap: the
  /// table holds one entry per circuit the session covers, not one per circuit ever seen.
  private func prune() {
    bindings = bindings.filter { $0.value.circuit != nil }
  }
}
