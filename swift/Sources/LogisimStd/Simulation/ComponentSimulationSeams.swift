// ComponentSimulationSeams.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// `LogisimKernel.SimComponent` is the kernel's view of `com.cburch.logisim.comp.Component`. Java
// has one class; the port has the protocol down in the kernel (D9 keeps `Component` itself, in
// `LogisimFile`, out of the kernel's sight) and five conformers spread across two modules:
// `Wire`, `InstanceComponent`, `UnresolvedComponent`, `StdInstanceComponent`, `Splitter`. Every
// one of them has to answer the same questions, and every answer is derived from the component's
// factory.
//
// So the answers live once, on `SimulatableComponent` below, and the five conformances are
// near-empty declarations. That is not merely tidier: `factoryRoles` and `wireRole` are
// *classifications*, and five independently written copies of a classification is exactly how a
// component ends up simulating as a plain gate because one copy forgot `instanceof Pin`.
//
// ── Where the `instanceof` chains went ──────────────────────────────────────────────────────
//
// `CircuitState.java` and `CircuitWires.java` branch on `comp.getFactory() instanceof X` for
// nine different `X`. None of those types is visible from the kernel, so the kernel asks for the
// *answers* (`SimFactoryRole`, `WireComponentRole`) and keeps the branching. This file is where
// the questions are actually asked, in the one module that can see all nine factory types.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - The wireEnds memo

/// One cached `[EndData] -> [WireEndInfo]` projection, validated by **storage identity** rather
/// than by an invalidation callback.
///
/// ── Why a memo at all ───────────────────────────────────────────────────────────────────────
///
/// `SimulatableComponent.wireEnds` is the only shape the kernel can consume (`WireComponent`
/// declares it as `[WireEndInfo]`, so there is no single-end accessor to add from here), and
/// `InstanceStateImpl.end(at:)` calls it once per `getPortValue`/`setPort`. A `k`-port component
/// therefore allocated and threw away `k` arrays of `k` elements per propagation. That is the
/// whole of board #70.
///
/// ── Why it cannot go stale; the part that matters ──────────────────────────────────────────
///
/// Ends are **not** fixed: `StdInstanceComponent.recomputePorts` and `InstanceComponent.setEnds`
/// replace `endArray` whenever an attribute edit changes the port list, which is exactly why
/// `computePorts` exists. A memo keyed on the component would need a callback from those two
/// assignments, and neither is reachable from this file.
///
/// So the key is not the component: it is the **identity of the `[EndData]` buffer** the
/// projection was built from. `sourceEnds` holds a strong reference to that buffer, and that one
/// fact makes the address comparison sound rather than an ABA gamble:
///
///   * `endArray = newEnds` (both mutation sites do exactly this) publishes a *different* array.
///     The old buffer cannot be recycled underneath the new one, because this memo is still
///     holding it alive, so the new buffer necessarily has a different address, the comparison
///     misses, and the projection is rebuilt.
///   * An in-place edit (`endArray[i] = …`) cannot happen silently either: this memo's reference
///     makes the buffer non-uniquely-referenced, so Swift's copy-on-write hands the component a
///     fresh buffer first. Same miss.
///   * A hit therefore means the two arrays *share* storage, and shared storage means identical
///     contents. Two components that share a buffer share their ends, and map identically.
///
/// The one thing storage identity cannot see is a value change performed without touching the
/// buffer: impossible here, since `EndData` is a POD struct with `let` fields.
///
/// ── D1 ──────────────────────────────────────────────────────────────────────────────────────
///
/// The kernel opts out of Swift Concurrency, so this is a plain global guarded by an `NSLock`,
/// the same shape as `CircuitWires.connectivityLock` and `PainterShaped.inputLengths`. The lock
/// is *not* held across the projection: a miss maps outside it and then publishes, so two threads
/// racing on different components duplicate work rather than serialise. Losing that race costs a
/// wasted map, never a wrong answer; the winner's entry is self-validating for whoever reads it
/// next.
///
/// Splitters keep their own override in `Splitter.swift` and never reach here. `Wire.ends` builds
/// a fresh array on every call, so a wire always misses and always evicts: correct, and the
/// reason the table has many slots rather than one (see `slotCount`).
private enum WireEndsMemo {
  private struct Slot {
    /// The address of `sourceEnds`' storage, as a plain integer: it is only ever compared, never
    /// dereferenced, and keeping it out of pointer form makes that unmistakable. `0` is the
    /// empty slot, and no non-empty array has address 0.
    var base: UInt = 0

    /// Retained on purpose; see the header. Releasing this would let the allocator recycle
    /// `base` and turn a stale entry into a hit. It outlives the component whose ends it came
    /// from, which costs one array of at most `k` PODs per slot and nothing else.
    var sourceEnds: [EndData] = []
    var projection: [WireEndInfo] = []
  }

  /// Direct-mapped, one probe, evict on collision.
  ///
  /// **The width is measured, not guessed.** Counted over the first 100,000,000 `project` calls
  /// of `2.7.1__case-438.circ::CPU`, on this tree:
  ///
  /// | slots | hits        | hit rate |
  /// |-------|-------------|----------|
  /// |     1 |  36,002,559 |   36.0 % |
  /// |    64 |  85,810,787 |   85.8 % |
  /// |  1024 |  97,159,417 |   97.2 % |
  ///
  /// One entry is not enough, which is the non-obvious part: propagating a component does *not*
  /// read its ports in an uninterrupted run. `Wire.ends` rebuilds its two-element array on every
  /// call, so every wire touched between two port reads is a guaranteed miss *and* an eviction,
  /// and a CPU-sized design walks a lot of wire between ports. Widening the table past the live
  /// working set is what converts the memo from "sometimes" to "almost always". 1,024 slots cost
  /// ~24 KB of table plus the retained arrays, and buy 11.4 points over 64.
  private static let slotCount = 1024
  private nonisolated(unsafe) static var slots = [Slot](repeating: Slot(), count: slotCount)
  private static let lock = NSLock()

  static func project(_ ends: [EndData]) -> [WireEndInfo] {
    // An empty array has no storage to take the identity of, and nothing to project.
    guard !ends.isEmpty else { return [] }
    let base = ends.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    // Allocations are at least 16-byte aligned, so the low four bits carry no information.
    let index = Int((base &>> 4) & UInt(slotCount - 1))

    lock.lock()
    // The count comparison is redundant given the header's argument, equal addresses mean
    // shared storage means equal counts, and is kept as the cheap half of the check that
    // would still be true if that argument were ever wrong.
    if slots[index].base == base, slots[index].sourceEnds.count == ends.count {
      let hit = slots[index].projection
      lock.unlock()
      return hit
    }
    lock.unlock()

    let fresh = ends.map {
      WireEndInfo(
        location: $0.location,
        width: $0.width,
        type: WireEndType(rawValue: $0.type.rawValue),
        isExclusive: $0.isExclusive)
    }

    lock.lock()
    slots[index] = Slot(base: base, sourceEnds: ends, projection: fresh)
    lock.unlock()
    return fresh
  }
}

// MARK: - Shared answers, derived from the factory

/// The join between `LogisimFile.Component` and `LogisimKernel.SimComponent`.
///
/// The shared answers below live on a protocol that refines **both**, rather than on `Component`
/// directly, because Swift will not use a member of an extension of one protocol as the witness
/// for a requirement of an unrelated protocol. Refining `SimComponent` is what makes these
/// legitimate witnesses, and it has an independent benefit: `SimulatableComponent` is a single
/// name for "a placement record the simulator can drive", so the five conformances below are the
/// complete, greppable list of what the engine can see.
public protocol SimulatableComponent: Component, SimComponent {}

extension SimulatableComponent {

  /// The `getFactory() instanceof …` answers `CircuitState.java` needs.
  ///
  /// Upstream's tests, in the order `CircuitState` performs them: `InstanceFactory`,
  /// `SubcircuitFactory`, `Clock`, `Pin`, `Ram`, `Buzzer`. `Rom` deliberately does **not** set
  /// `.ram`; upstream's guard is `getFactory() instanceof Ram`, and although `Rom` extends `Mem`
  /// it does not extend `Ram`, so a ROM's contents survive `CircuitState.reset()` exactly as they
  /// do in Java. (This is the kind of detail a per-conformer copy loses.)
  public var factoryRoles: SimFactoryRole {
    var roles: SimFactoryRole = []
    let f = factory
    if f is any InstanceFactory { roles.insert(.instanceFactory) }
    if f is any SubcircuitFactory { roles.insert(.subcircuit) }
    if f is Clock { roles.insert(.clock) }
    if f is Pin { roles.insert(.pin) }
    if f is Ram { roles.insert(.ram) }
    if f is Buzzer { roles.insert(.buzzer) }
    return roles
  }

  /// `comp.getFactory().getClass()`, for the `TRANSACTION_DONE` replacement search.
  ///
  /// A **metatype** identity, as `SimComponent` requires: upstream compares
  /// `repl.getFactory().getClass() == compFactory`, i.e. two *different* factory instances of the
  /// same class match. `ObjectIdentifier(factory)` would be the instance and would never match
  /// across a replacement.
  public var factoryTypeIdentity: ObjectIdentifier {
    ObjectIdentifier(type(of: factory))
  }

  /// Which bucket `CircuitWires.add` sorts this component into (`CircuitWires.java:538-561`).
  ///
  /// Java asks `comp instanceof Wire`, `comp instanceof Splitter`, then
  /// `comp.getFactory() instanceof Tunnel` / `instanceof PullResistor`, then falls through to
  /// "everything else". The first two are answered by the conformer (`Wire` and `Splitter`
  /// override this); the rest is here.
  public var wireRole: WireComponentRole {
    let f = factory
    if f is Tunnel { return .tunnel }
    if f is PullResistor { return .pullResistor }
    return .plain
  }

  /// `Component.getLocation()`.
  public var wireLocation: Location { location }

  /// `Component.getEnds()`, projected onto the kernel's port record.
  ///
  /// `WireEndType`'s raw values were chosen to match `EndData.EndType`'s, so this is the identity
  /// mapping its doc comment promises.
  ///
  /// **Memoised.** The projection itself is trivial, but it allocates a `k`-element array, and
  /// `InstanceStateImpl.end(at:)` calls this to read *one* end: so a component with `k` ports
  /// paid `k` array allocations per propagation instead of none, making evaluation O(k²) in port
  /// count.
  ///
  /// Measured on `2.7.1__case-438.circ::CPU` at 2,048 rows, five A/B pairs run **alternating** so drift in
  /// machine load lands on both arms: 221.69 s median without the memo, 149.34 s with it, a
  /// **1.48x** median speedup (per-pair 1.34x–1.55x). All five pairs produced byte-identical
  /// tables, both against each other and against the 4.1.0 Java golden, modulo the per-run
  /// random VHDL label suffix that `generateValidVHDLLabel` mints and the rig already masks.
  /// See `WireEndsMemo` below for why the memo cannot go stale.
  public var wireEnds: [WireEndInfo] {
    WireEndsMemo.project(ends)
  }

  /// `comp.getFactory() instanceof Pin` (`CircuitWires.java:242`).
  ///
  /// A `Pin` counts as a **sink even when it drives**, so that it is notified on every input
  /// change and can colour itself correctly. Load-bearing for `CircuitWires.State`'s
  /// driven-value carry-over.
  public var wireIsPinFactory: Bool { factory is Pin }

  /// `comp.getAttributeSet()`.
  public var componentAttributeSet: any AttributeSet { attributeSet }

  /// `comp.getAttributeSet().getValue(StdAttr.LABEL)`, **untrimmed**; `CircuitWires.java:760`
  /// does the trimming itself, so trimming here would trim twice and is harmless, but reporting
  /// a trimmed label would hide a label that is only whitespace.
  public var wireTunnelLabel: String { attributeSet[StdAttr.label] ?? "" }

  /// `PullResistor.getPullValue(instance)` (`CircuitWires.java:752`).
  ///
  /// Only read for components whose `wireRole` is `.pullResistor`, so the non-pull answer is
  /// upstream's unreachable branch rather than a guess.
  public var wirePullValue: Value {
    factory is PullResistor ? PullResistor.pullValue(for: attributeSet) : .unknownValue
  }

  // MARK: Propagation

  /// `Component.propagate(CircuitState)`.
  ///
  /// Upstream's `InstanceComponent.propagate` is
  /// `((InstanceFactory) getFactory()).propagate(state.getInstanceState(this))`, and `Wire` /
  /// `Splitter` override it to do nothing (their values are resolved by `CircuitWires` during
  /// `processDirtyPoints`, which is also why `isWireOrSplitter` makes `Propagator.setValue` a
  /// no-op for them).
  ///
  /// The instance state is the **reusable** one; standing rule 4. Upstream calls
  /// `state.getInstanceState(this)`, which allocates; `InstanceComponent.propagate` in 4.1.0
  /// reads:
  ///
  /// ```java
  /// public void propagate(CircuitState state) {
  ///   ((InstanceFactory) getFactory()).propagate(state.getInstanceState(this));
  /// }
  /// ```
  ///
  /// and `CircuitState.getInstanceState` is the allocating overload, so the allocation is
  /// upstream's. It is preserved rather than optimised into `getReusableInstanceState`: the
  /// reusable object is aliased per `CircuitState`, and a component whose `propagate` recurses
  /// into a subcircuit (which propagates *its* components against the same state tree) would
  /// have its scratch object repurposed underneath it. Upstream's choice here is not an
  /// oversight, and the differential gate compares behaviour.
  ///
  /// **The subcircuit branch is not an optimisation, it is the only route.** In Java
  /// `SubcircuitFactory extends InstanceFactory`, so a subcircuit placement satisfies the cast
  /// below and needs no special case. It cannot here: D9 puts `CircuitSubcircuitFactory` in
  /// `LogisimFile` (a `Circuit` builds its own factory in its initialiser) and `InstanceFactory`
  /// in this module, which depends on `LogisimFile`; the conformance would need the dependency
  /// arrow to point backwards. So a subcircuit is the one component in the tree that falls out of
  /// the guard, and before this branch existed every hierarchical design read all-`U`: the ends
  /// were computed correctly and then nothing ever drove them. See `SubcircuitPropagation.swift`.
  public func propagate(in state: CircuitState) throws {
    if let subcircuitFactory = factory as? CircuitSubcircuitFactory {
      try SubcircuitPropagation.propagate(self, factory: subcircuitFactory, in: state)
      return
    }
    guard let instanceFactory = factory as? any InstanceFactory else { return }
    let instanceState = try state.getInstanceState(self)
    guard let bridged = instanceState as? InstanceStateImpl else { return }
    try instanceFactory.propagate(bridged)
  }

  /// `Clock.tick(CircuitState, int, Component)` (`Clock.java:136-148`), transcribed from the
  /// call recipe `Clock.swift`'s own header records:
  ///
  /// ```java
  /// static boolean tick(CircuitState circState, int ticks, Component comp) {
  ///   final var attrs = (ClockAttributes) comp.getAttributeSet();
  ///   var state = (ClockState) circState.getData(comp);
  ///   if (state == null) {
  ///     state = new ClockState(ticks, attrs);
  ///     circState.setData(comp, state);
  ///     return true;
  ///   }
  ///   return state.updateTick(ticks, attrs);
  /// }
  /// ```
  ///
  /// Only reached when `factoryRoles` contains `.clock`; `CircuitState` guards the call.
  public func clockTick(in state: CircuitState, ticks: Int) -> Bool {
    if let existing = state.getData(self) as? Clock.ClockState {
      return existing.updateTick(ticks, attributeSet)
    }
    state.setData(self, Clock.ClockState(ticks: ticks, attrs: attributeSet))
    return true
  }

  /// `InstanceComponent.fireInvalidated()`. Only `StdInstanceComponent` and `InstanceComponent`
  /// have listeners; the rest inherit the kernel's no-op default.
  public func fireComponentInvalidated() {}
}

// MARK: - The five conformances

// Each is empty: everything is answered above, or (for `Wire` and `Splitter`) overridden on the
// type itself. Declaring them here rather than on the types keeps the simulation coupling in one
// directory, which is what lets `LogisimFile` stay the inert-netlist module it says it is.

extension Wire: SimulatableComponent {
  /// `comp instanceof Wire` (`CircuitWires.java:538`).
  public var wireRole: WireComponentRole { .wire }

  /// A wire's value is resolved by `CircuitWires`, never by propagation.
  public func propagate(in state: CircuitState) throws {}
}

/// `Wire` is also `CircuitWires`' `Wire`.
extension Wire: WireSegmentComponent {
  public var wireEnd0: Location { end0 }
  public var wireEnd1: Location { end1 }
}

extension InstanceComponent: SimulatableComponent {
  public func fireComponentInvalidated() { fireInvalidated() }
}

extension StdInstanceComponent: SimulatableComponent {
  public func fireComponentInvalidated() { fireInvalidated() }
}

extension UnresolvedComponent: SimulatableComponent {
  /// D8's round-tripped placeholder. It has no factory behaviour by construction, so it
  /// contributes nothing to propagation, which is strictly better than upstream, where the
  /// component would already have been deleted on load.
  public func propagate(in state: CircuitState) throws {}
}

extension Splitter: SimulatableComponent {
  /// A splitter's value is resolved by `CircuitWires`, never by propagation
  /// (`Splitter.java` has no `propagate`; `CircuitWires` routes bits between its ends).
  public func propagate(in state: CircuitState) throws {}
}
