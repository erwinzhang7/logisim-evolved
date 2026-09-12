// HeadlessSimulation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16): the pieces of `proj/Project`, `circuit/Simulator`
// and `gui/start/TtyInterface` that a project-less run actually needs.
//
// ── What a headless run is, and what it deliberately is not ─────────────────────────────────
//
// Upstream's `TtyInterface.run` builds a real `Project`, which builds a `Simulator`, which spawns
// a `SimThread`. Almost none of that is reachable from here: `Project` is 287-of-1204 files' door
// to `AppPreferences` (D9), and D7 replaces the `Simulator` clock outright.
//
// What the kernel actually asks for is small and is provided here in full: a `SimProject` that
// can hand back a `SimSimulator` and the `<options>` set, and a `SimSimulator` that names the
// thread propagation runs on. Upstream's own headless path passes `Thread.currentThread()`
// (`TtyInterface.java:410`, `CircuitState.createRootState(proj, circuit, Thread.currentThread())`),
// so "the calling thread" is not a shortcut; it is what the oracle does.
//
// D1 is why this is a plain class with no actor and no `async`: `propagate()` is synchronous, and
// the session is confined to the thread that made it by the same assertion `Propagator` already
// enforces.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - Options

/// `com.cburch.logisim.file.Options`' attribute set, as `Propagator` reads it.
///
/// This is what makes a file's `simrand` / `simlimit` reach the engine. Without it the propagator
/// silently uses Java's defaults, which is right for a default project and wrong for any file
/// that sets either: and the oscillation heuristic (`simLimit`, `simRandomShift`) is preserved
/// verbatim precisely so those settings matter.
public final class SimulationOptionsBridge: PropagatorOptionsSource {

  /// The `<options>` set. Strong: the session owns both this bridge and the `LogisimFile` the
  /// options came from, and neither reaches back.
  private let attributes: any AttributeSet

  /// D5: the token is what keeps the subscription alive. Held here, released with the bridge.
  private var subscription: AttributeSubscription?

  /// Observers, held **weakly**; `Propagator.Listener` holds a `WeakReference<Propagator>`
  /// upstream for exactly this reason, and the kernel's own doc says the observer holds the
  /// propagator weakly, so retaining observers here cannot leak a propagator.
  private var observers: [() -> (any PropagatorOptionsObserver)?] = []

  public init(_ attributes: any AttributeSet) {
    self.attributes = attributes
    self.subscription = attributes.addAttributeListener(
      onValueChanged: { [weak self] event in
        guard let self, let name = event.attribute?.name else { return }
        switch name {
        case Options.simulationRandomness.name: self.notify(.randomness)
        case Options.simulationLimit.name: self.notify(.limit)
        default: break
        }
      })
  }

  private func notify(_ option: PropagatorSimulationOption) {
    observers = observers.filter { $0() != nil }
    for observer in observers { observer()?.simulationOptionChanged(option) }
  }

  /// `getValue(Options.ATTR_SIM_LIMIT)`. Java's default is `1000`; `Options`' own attribute set
  /// carries it, so the fallback here is only reached for a set that lacks the attribute.
  public var simulationLimitOption: Int {
    Int(attributes[Options.simulationLimit] ?? 1000)
  }

  /// `getValue(Options.ATTR_SIM_RAND)`. Java's default is `0`, randomness off.
  public var simulationRandomnessOption: Int {
    Int(attributes[Options.simulationRandomness] ?? 0)
  }

  public func addSimulationOptionsObserver(_ observer: any PropagatorOptionsObserver) {
    observers.append { [weak observer] in observer }
  }

  public func removeSimulationOptionsObserver(_ observer: any PropagatorOptionsObserver) {
    observers = observers.filter { $0() !== observer && $0() != nil }
  }
}

// MARK: - Project / Simulator

/// The project-less stand-in for `com.cburch.logisim.proj.Project`.
///
/// Named for what it is rather than `HeadlessProject`, because the UI will eventually conform its
/// real `Project` to the same protocols and this type will not be in the way.
///
/// A fourth conformance, `SubcircuitCircuitProviding`, is declared in an extension below rather
/// than added to this list, and that is not a style choice: `tools/seamcheck.py` reads
/// conformances off the declaration line, so wrapping the list across two lines to fit the column
/// limit made it report `SimProject` as a brand-new unwired seam. A ratchet whose whole value is
/// that its alarms get believed must not be made to cry wolf.
public final class SimulationHost: SimProject, SimSimulator, SimulationOptionsProviding {

  /// The thread propagation is pinned to. `Propagator` asserts against it at 62 sites, matching
  /// Java's `Thread.currentThread() != propagatorThread` checks.
  public let simulationThread: Thread?

  /// `getOptions().getAttributeSet()`.
  public let optionsAttributeSet: any AttributeSet

  private let optionsBridge: SimulationOptionsBridge

  /// - Parameters:
  ///   - options: the loaded file's `<options>` set. Pass `LogisimFile.options.attributeSet` so
  ///     `simrand`/`simlimit` are honoured; omit it and the run uses Java's defaults.
  ///   - thread: the propagation thread. Defaults to the calling thread, which is what
  ///     `TtyInterface` passes.
  ///
  /// **The `nil` fallback builds a fresh set; it must not be the shared
  /// `HeadlessSimulationOptions.defaults`.** It used to be, and that was a memory-corruption bug
  /// rather than a tidiness one: `SimulationOptionsBridge` *subscribes* to whatever set it is
  /// handed, so every default-constructed host appended a listener to one process-wide
  /// `AttributeSet`'s registry. Two hosts built concurrently is then an unsynchronised
  /// `Array.append` on shared storage: it reproducibly `SIGSEGV`ed the whole test bundle inside
  /// `objc_destructInstance`, from a stack that named nothing but `SimulationHost.init`. That
  /// `defaults` set's own doc comment claimed it was "immutable in practice; nothing on the
  /// headless path writes to it", which was true of its *values* and false of its listener list;
  /// the two uses had drifted apart without anyone noticing, because a single-host run never
  /// shows it.
  ///
  /// A per-host set is also just correct independently of threads: options are per-project, and
  /// sharing one set meant a `simlimit` written through one host would be seen by every other
  /// host in the process. `Options()`'s defaults are cheap and this runs once per run.
  public init(options: (any AttributeSet)? = nil, thread: Thread? = nil) {
    let resolved = options ?? Options().attributeSet
    self.optionsAttributeSet = resolved
    self.optionsBridge = SimulationOptionsBridge(resolved)
    self.simulationThread = thread ?? Thread.current
  }

  /// `getSimulator()`; the host is its own simulator; there is only one of each.
  public var simulator: (any SimSimulator)? { self }

  /// `getOptions().getAttributeSet()`, as `Propagator` reads it.
  public var simulationOptions: (any PropagatorOptionsSource)? { optionsBridge }

  /// `addPendingInput(CircuitState, Component)`; single-step-mode highlighting. There is no
  /// single-step mode in a headless run, so this is upstream's no-op branch rather than a stub.
  public func addPendingInput(_ state: CircuitState, _ component: any SimComponent) {}

  /// Backing store for `simulatedCircuit(for:)`, which is in the extension below. `fileprivate`
  /// rather than `public`; nothing outside this file may reach past the accessor, because the
  /// accessor's *cache miss* path is the invariant (one wrapper per circuit, ever).
  fileprivate var circuitCache: [ObjectIdentifier: SimulatedCircuit] = [:]
}

// MARK: - SubcircuitCircuitProviding

extension SimulationHost: SubcircuitCircuitProviding {

  /// One `SimulatedCircuit` per `Circuit`, for the life of this host.
  ///
  /// **Why the cache lives here rather than on `SimulationSession`, where it started.** Nothing
  /// about *caching* wanted to move; the requirement is that
  /// `SubcircuitFactory.getSubstate`, which runs deep inside propagation, holding only a
  /// `CircuitState`, can reach it. The kernel's one weak edge out of a `CircuitState` towards
  /// the layer that owns simulation is `project`, and `SimulationHost` is what sits on the far
  /// end of it. So the cache moved one hop, onto the object the kernel can already name.
  ///
  /// The alternative was a `weak var session` back-edge on the host, which D3 would permit with a
  /// reason. It was rejected as strictly worse: a host outliving its session would leave that
  /// reference `nil`, and the whole failure mode of a subcircuit that cannot find its substate is
  /// *silence*; the child never propagates and the parent reads `UNKNOWN`. Moving the storage
  /// removes the possibility rather than documenting it.
  ///
  /// Ownership is unchanged, so `SimulationSession`'s claim to be the eviction owner still holds:
  /// the session owns the host, the host owns the cache, and dropping the session drops both.
  /// There is no new back-edge in either direction; `SimulatedCircuit` reaches nothing above it.
  public func simulatedCircuit(for circuit: Circuit) -> SimulatedCircuit {
    let key = ObjectIdentifier(circuit)
    if let existing = circuitCache[key] { return existing }
    let made = SimulatedCircuit(circuit)
    circuitCache[key] = made
    return made
  }
}

// MARK: - Session

/// Owns everything a headless simulation of one loaded `LogisimFile` needs.
///
/// **The identity cache is the point.** `CircuitState` keys substates, dirty lists and
/// `componentData` on the objects it is handed (D4), so every `Circuit` must map to exactly one
/// `SimulatedCircuit` for the life of a run. A second wrapper around the same circuit is a
/// second, silently divergent circuit: no error, wrong values. The session is also the eviction
/// owner D3 demands: dropping it drops every wrapper, every `CircuitWires` and, through the
/// subscription tokens, every listener registration.
public final class SimulationSession {

  /// The host acting as `Project` and `Simulator`, and, since subcircuit propagation was wired,
  /// the object that physically holds the identity cache. See `SimulationHost.simulatedCircuit`
  /// for why it is a hop further down than this class's header implies, and why the eviction
  /// story below is unaffected.
  public let host: SimulationHost

  public init(host: SimulationHost) {
    self.host = host
  }

  /// Convenience for a run over a loaded file: picks up the file's `<options>` so `simrand` and
  /// `simlimit` are honoured.
  public convenience init(file: LogisimFile?, thread: Thread? = nil) {
    self.init(host: SimulationHost(options: file?.options.attributeSet, thread: thread))
  }

  /// The one `SimulatedCircuit` for this `Circuit`. Built on first ask.
  ///
  /// Delegates to the host, which is where the storage lives; this stays the name callers use,
  /// and it is deliberately the *same* cache subcircuit propagation reaches through
  /// `CircuitState.project`. Two caches would be two wrappers per circuit, which is the exact
  /// divergence this class exists to prevent.
  public func simulated(_ circuit: Circuit) -> SimulatedCircuit {
    host.simulatedCircuit(for: circuit)
  }

  /// `CircuitState.createRootState(proj, circuit, Thread.currentThread())`.
  public func createRootState(for circuit: Circuit) -> CircuitState {
    CircuitState.createRootState(
      project: host, circuit: simulated(circuit), thread: host.simulationThread)
  }
}
