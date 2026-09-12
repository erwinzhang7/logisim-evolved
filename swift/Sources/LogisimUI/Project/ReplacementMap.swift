// ReplacementMap.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.ReplacementMap),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// A bipartite record of "these components became those components", accumulated over the whole
// of a transaction. `map` runs removals → additions, `inverse` runs additions → removals. Both
// directions are needed: the simulator walks `map` at `TRANSACTION_DONE` to carry `componentData`
// from an old component onto its replacements, and `getInverseMap` is how a transaction produces
// its own reverse for the undo stack.
//
// A component that is purely removed has an entry in `map` with an **empty** replacement set; one
// that is purely added has an entry in `inverse` with an empty source set. That is why `isEmpty`
// has to test both dictionaries and why `getRemovals()`/`getAdditions()` return key sets rather
// than value unions.
//
// ── D4: keying ──────────────────────────────────────────────────────────────────────────────
//
// D4 forbids `Equatable`/`Hashable` on `Component`, so Java's `HashMap<Component, …>` becomes a
// dictionary keyed by `ObjectIdentifier` with the component carried alongside in the value. That
// is not a workaround; it is the invariant D4 asks for, made unforgeable by the type system.
//
// One deliberate consequence: upstream's `Wire` overrides `equals`/`hashCode` structurally, so in
// Java two distinct `Wire` objects with the same endpoints collapse to one key here. They do not
// collapse in this port. The difference is unobservable in practice because
// `CircuitWireStore.add` already deduplicates wires by endpoint before any of them reaches a
// transaction, so a second equal `Wire` never gets into the circuit to be replaced.
//
// ── Iteration order, and why it is insertion order here ─────────────────────────────────────
//
// Java iterates `HashMap`/`HashSet` in bucket order, which for components is derived from
// `System.identityHashCode`; a value that changes between JVM runs. Upstream's own output is
// therefore not reproducible at this level, and *cannot* be replicated by construction (this is
// the general problem recorded as the M3 blocker in the task list).
//
// This port uses **insertion order** throughout. That is the only deterministic choice available,
// and it is safe for the M7 byte-exact gate for a specific, checked reason: `XmlWriter.sort`
// (`XmlWriter.java:136-176`) sorts a circuit's `<comp>` and `<wire>` children by node name and
// then by attribute string before writing, so the order in which components land in
// `Circuit.componentOrder` does not reach the file.
//
// The one place order *is* observable is `Circuit.mutatorAdd`'s duplicate-label clearing, which
// scans the components already present. A batch that adds two components carrying the same label
// will blank whichever is added second. Insertion order makes that outcome stable across runs;
// Java's does not. Treat any differential failure that traces to this as an upstream
// nondeterminism, not a port bug.

import Foundation
import LogisimFile

/// `com.cburch.logisim.circuit.ReplacementMap`.
public final class ReplacementMap {

  /// One `HashMap<Component, HashSet<Component>>` entry: the key component plus its
  /// insertion-ordered, identity-deduplicated set of counterparts.
  private struct Entry {
    var component: any Component
    var counterparts: [any Component] = []
    var counterpartIdentities: Set<ObjectIdentifier> = []

    mutating func insert(_ other: any Component) {
      if counterpartIdentities.insert(ObjectIdentifier(other)).inserted {
        counterparts.append(other)
      }
    }

    mutating func remove(_ other: any Component) {
      guard counterpartIdentities.remove(ObjectIdentifier(other)) != nil else { return }
      counterparts.removeAll { $0 === other }
    }
  }

  /// A `LinkedHashMap`-shaped store: identity-keyed lookup, insertion-ordered iteration.
  /// See the header for why insertion order rather than Java's bucket order.
  private struct EntryTable {
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []

    var isEmpty: Bool { order.isEmpty }

    /// Insertion-ordered key components, `keySet()`.
    var keyComponents: [any Component] { order.compactMap { entries[$0]?.component } }

    subscript(component: any Component) -> Entry? {
      get { entries[ObjectIdentifier(component)] }
      set {
        let key = ObjectIdentifier(component)
        if let newValue {
          if entries.updateValue(newValue, forKey: key) == nil { order.append(key) }
        } else if entries.removeValue(forKey: key) != nil {
          order.removeAll { $0 == key }
        }
      }
    }

    /// `computeIfAbsent`.
    func entry(for component: any Component) -> Entry {
      self[component] ?? Entry(component: component)
    }

    @discardableResult
    mutating func removeEntry(for component: any Component) -> Entry? {
      let key = ObjectIdentifier(component)
      guard let removed = entries.removeValue(forKey: key) else { return nil }
      order.removeAll { $0 == key }
      return removed
    }

    func contains(_ component: any Component) -> Bool {
      entries[ObjectIdentifier(component)] != nil
    }

    /// Insertion-ordered entries, for `append`.
    var allEntries: [Entry] { order.compactMap { entries[$0] } }

    mutating func removeAll() {
      entries.removeAll()
      order.removeAll()
    }

    init() {}

    init(entries: [ObjectIdentifier: Entry], order: [ObjectIdentifier]) {
      self.entries = entries
      self.order = order
    }

    var rawEntries: [ObjectIdentifier: Entry] { entries }
    var rawOrder: [ObjectIdentifier] { order }
  }

  /// `frozen`. Set once a map has been handed to a `CircuitChange`, because that change is now
  /// the undo record and mutating it afterwards would rewrite history.
  private var frozen = false

  private var map = EntryTable()
  private var inverse = EntryTable()

  public init() {}

  /// `ReplacementMap(Component, Component)`, the single-replacement convenience.
  public init(old oldComponent: any Component, new newComponent: any Component) {
    var oldEntry = Entry(component: oldComponent)
    oldEntry.insert(newComponent)
    var newEntry = Entry(component: newComponent)
    newEntry.insert(oldComponent)
    map[oldComponent] = oldEntry
    inverse[newComponent] = newEntry
  }

  private init(map: EntryTable, inverse: EntryTable) {
    self.map = map
    self.inverse = inverse
  }

  /// `add(Component)`; a pure addition: it appears in `inverse` with nothing it replaced.
  ///
  /// D13: `throws` rather than trapping. Upstream raises `IllegalStateException` here, and the
  /// path is reachable from an edit, a tool that hands the same map to two changes hits it,
  /// so the caller gets to report it instead of the app dying.
  public func add(_ component: any Component) throws {
    try checkNotFrozen()
    inverse[component] = Entry(component: component)
  }

  /// `remove(Component)`; a pure removal: it appears in `map` replaced by nothing.
  public func remove(_ component: any Component) throws {
    try checkNotFrozen()
    map[component] = Entry(component: component)
  }

  /// `replace(Component, Component)`.
  public func replace(_ oldComponent: any Component, with newComponent: any Component) throws {
    try put(oldComponent, [newComponent])
  }

  /// `put(Component, Collection<? extends Component>)`.
  public func put(_ oldComponent: any Component, _ newComponents: [any Component]) throws {
    try checkNotFrozen()

    var entry = map.entry(for: oldComponent)
    for newComponent in newComponents { entry.insert(newComponent) }
    map[oldComponent] = entry

    for newComponent in newComponents {
      var sources = inverse.entry(for: newComponent)
      sources.insert(oldComponent)
      inverse[newComponent] = sources
    }
  }

  /// `append(ReplacementMap)`: compose `next` after `self`, collapsing chains.
  ///
  /// This is the subtle one, and the comments are upstream's own reasoning kept intact: if `b`
  /// was produced by `self` and is consumed by `next`, the composed map must say that whatever
  /// produced `b` now produces what `next` turned `b` into, and `b` itself must disappear from
  /// both sides. A component that `next` replaces but `self` never mentioned "replaces itself",
  /// which is how a pre-existing component enters the composition.
  ///
  /// Note this deliberately ignores `frozen` on `self`, exactly as upstream does:
  /// `CircuitMutatorImpl` appends into its per-circuit accumulator maps, which are never frozen,
  /// while the maps being appended *from* generally are.
  public func append(_ next: ReplacementMap) {
    for nextEntry in next.map.allEntries {
      let b = nextEntry.component
      let cs = nextEntry.counterparts  // what `b` is replaced by

      // What was replaced to get `b`. Absent means `b` pre-existed, so it replaces itself.
      var as_: [any Component]
      if let removed = inverse.removeEntry(for: b) {
        as_ = removed.counterparts
      } else {
        as_ = [b]
      }

      for a in as_ {
        var aDst = map.entry(for: a)
        aDst.remove(b)
        for c in cs { aDst.insert(c) }
        map[a] = aDst
      }

      for c in cs {
        var cSrc = inverse.entry(for: c)
        for a in as_ { cSrc.insert(a) }
        inverse[c] = cSrc
      }
    }

    for nextEntry in next.inverse.allEntries {
      let c = nextEntry.component
      if !inverse.contains(c) {
        if !nextEntry.counterparts.isEmpty {
          // Upstream logs this at ERROR through slf4j and carries on. Keeping it as a
          // diagnostic rather than a throw preserves that: it reports a bug in whoever built
          // the maps, and there is nothing the user did to cause it and nothing they can do
          // about it, so aborting their edit would be strictly worse.
          internalErrors.append("component replaced but not represented: \(type(of: c))")
        }
        inverse[c] = Entry(component: c)
      }
    }
  }

  /// Diagnostics collected in place of upstream's `logger.error`. Per-instance rather than
  /// static: a `static var` is global mutable state, which Swift 6 rejects outright and which
  /// would need a lock to be honest about anyway. Kept as data rather than printed so a
  /// headless differential run stays quiet, `CircuitTransactionResult` gathers these up.
  public private(set) var internalErrors: [String] = []

  public func drainInternalErrors() -> [String] {
    defer { internalErrors = [] }
    return internalErrors
  }

  /// `freeze()`.
  public func freeze() { frozen = true }

  public var isFrozen: Bool { frozen }

  /// `getAdditions()`: every component this transaction introduces.
  public var additions: [any Component] { inverse.keyComponents }

  /// `getRemovals()`; every component this transaction takes away.
  public var removals: [any Component] { map.keyComponents }

  /// `getReplacementsFor(Component)`. `nil` when the component was not removed at all, which is
  /// a different answer from "removed and replaced by nothing" (`[]`): the simulator
  /// distinguishes them when deciding whether to carry `componentData` across.
  public func replacements(for oldComponent: any Component) -> [any Component]? {
    map[oldComponent]?.counterparts
  }

  /// `getReplacedBy(Component)`.
  public func replaced(by newComponent: any Component) -> [any Component]? {
    inverse[newComponent]?.counterparts
  }

  /// `getInverseMap()`; the two dictionaries swapped. This is what makes undo cheap: the
  /// reverse of "replace A with B" is the same object read the other way round, with the same
  /// component instances, so D4 identity survives an undo/redo round trip.
  public func inverseMap() -> ReplacementMap {
    ReplacementMap(
      map: EntryTable(entries: inverse.rawEntries, order: inverse.rawOrder),
      inverse: EntryTable(entries: map.rawEntries, order: map.rawOrder))
  }

  /// `isEmpty()`. Both halves, because a pure addition lives only in `inverse` and a pure
  /// removal only in `map`.
  public var isEmpty: Bool { map.isEmpty && inverse.isEmpty }

  /// `reset()`.
  public func reset() {
    map.removeAll()
    inverse.removeAll()
  }

  private func checkNotFrozen() throws {
    if frozen { throw CircuitMutationError.mapIsFrozen }
  }
}

extension ReplacementMap: CustomStringConvertible {
  /// `toString()` / `print(PrintStream)`, merged; Java only has the stream form because it
  /// predates text blocks.
  public var description: String {
    var lines: [String] = []

    let removed = removals
    if removed.isEmpty {
      lines.append("  removals: none")
    } else {
      lines.append("  removals:")
      for component in removed {
        lines.append("    \(component)")
        for b in replacements(for: component) ?? [] {
          lines.append("     `--> \(b)")
        }
      }
    }

    let added = additions
    if added.isEmpty {
      lines.append("  additions: none")
    } else {
      lines.append("  additions:")
      for component in added {
        lines.append("    \(component)")
        for a in replaced(by: component) ?? [] {
          lines.append("     ^-- \(a)")
        }
      }
    }

    return lines.joined(separator: "\n")
  }
}

/// The errors the transaction machinery raises. D13: all of these are reachable from an edit,
/// a tool building a malformed mutation, or a change type that cannot be reversed, so they
/// throw and the editing layer reports them, rather than trapping and losing unsaved work.
public enum CircuitMutationError: Error, CustomStringConvertible {
  /// `IllegalStateException("cannot change map after frozen")`.
  case mapIsFrozen
  /// `IllegalArgumentException("unknown change type " + type)`: raised by `execute` and
  /// `getReverseChange` on a change kind neither knows. Unreachable while `CircuitChange.Kind`
  /// stays a closed enum, and kept only so the exhaustiveness is stated rather than assumed.
  case unknownChangeKind(String)
  /// A transaction tried to write a circuit it never declared in `accessedCircuits`, which is
  /// upstream's `CircuitLocker.LockException`.
  case writeWithoutLock(circuitName: String)

  public var description: String {
    switch self {
    case .mapIsFrozen:
      return "cannot change map after frozen"
    case .unknownChangeKind(let kind):
      return "unknown change type \(kind)"
    case .writeWithoutLock(let circuitName):
      return "circuit \"\(circuitName)\" mutated outside a transaction"
    }
  }
}
