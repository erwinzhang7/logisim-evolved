// ComponentSet.swift: part of logisim-evolved.
//
// The container behind `SelectionBase.selected`, `.lifted` and `.suppressHandles`, which upstream
// spells `HashSet<Component>`. Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ── Two things Java's `HashSet<Component>` does that a Swift `Set` would get wrong ───────────
//
// **1. Element equality is not uniform.** `Component` has no `equals` of its own, so almost every
// component is deduplicated by *reference*, which is D4, and is what `ComponentRef` in
// `LogisimFile` expresses. `Wire` is the one deliberate exception upstream makes: it overrides
// `equals`/`hashCode` structurally on its endpoints, and `Wire.swift`'s header explains why
// (`CircuitWires.addWire` relies on structural dedup, or a file with a duplicated `<wire>` would
// round-trip with an extra wire).
//
// A selection holds both kinds at once, so neither `ComponentRef` nor `Set<Wire>` is the right
// key on its own. `SelectionComponentKey` is Java's rule written out: structural when both sides
// are wires, reference identity otherwise. This is *not* a relaxation of D4; it is the exact set
// of equalities `HashSet<Component>` already had, and it is why an undo that recreates a wire can
// still find its old selection entry.
//
// **2. Iteration order.** Java's `HashSet` order is arbitrary but stable within a JVM run;
// Swift's `Set` order is arbitrary *and reseeded every process*, because `Hasher` is randomly
// seeded and `ObjectIdentifier` hashes through it. Porting `HashSet` to `Set` would therefore be
// strictly worse than the Java: the same scripted edit sequence could produce two different
// files on two runs of the same binary, which makes the M7 byte-exact gate untestable rather
// than merely hard.
//
// So this is insertion-ordered; an array plus a key set, the same shape `Circuit.swift` uses for
// `comps` (which upstream really does declare as a `LinkedHashSet`). That is a strictly stronger
// guarantee than Java offers and cannot introduce a divergence upstream would not also show:
// every place the selection's iteration order reaches the saved file, it reaches it through
// `CircuitMutation`, and `XmlWriter.sort` normalises the component order on write.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - The key

/// A `Hashable` box over a component that reproduces `HashSet<Component>`'s notion of "same
/// element": structural for `Wire`, reference identity for everything else.
///
/// Deliberately distinct from `LogisimFile.ComponentRef`, which is identity-only. Both exist and
/// both are correct; picking one is a statement about which equality the collection needs, and
/// the selection needs this one.
public struct SelectionComponentKey: Hashable {
  public let component: any Component

  public init(_ component: any Component) { self.component = component }

  public static func == (lhs: SelectionComponentKey, rhs: SelectionComponentKey) -> Bool {
    if let a = lhs.component as? Wire, let b = rhs.component as? Wire { return a == b }
    return lhs.component === rhs.component
  }

  public func hash(into hasher: inout Hasher) {
    // Equal elements must hash equally, and the two branches are disjoint: a wire is only ever
    // equal to a wire.
    if let wire = component as? Wire {
      hasher.combine(wire)
    } else {
      hasher.combine(ObjectIdentifier(component))
    }
  }
}

// MARK: - The set

/// `HashSet<Component>`, insertion-ordered. See the file header for why the order is pinned.
public struct ComponentSet {
  private var order: [any Component] = []
  private var keys: Set<SelectionComponentKey> = []

  public init() {}

  public init(_ components: some Sequence<any Component>) {
    for component in components { _ = add(component) }
  }

  // MARK: Queries

  public var isEmpty: Bool { order.isEmpty }
  public var count: Int { order.count }

  /// Iteration order is insertion order.
  public var components: [any Component] { order }

  public func contains(_ component: any Component) -> Bool {
    keys.contains(SelectionComponentKey(component))
  }

  /// `HashSet.equals`, same membership, order irrelevant.
  public func isSameSet(as other: ComponentSet) -> Bool {
    keys == other.keys
  }

  /// `HashSet.equals` against a bare sequence, which is what `SelectionSave.isSame` needs.
  public func isSameSet(as other: some Sequence<any Component>) -> Bool {
    keys == Set(other.map(SelectionComponentKey.init))
  }

  // MARK: Mutation

  /// `Set.add`; true when the set changed.
  @discardableResult
  public mutating func add(_ component: any Component) -> Bool {
    guard keys.insert(SelectionComponentKey(component)).inserted else { return false }
    order.append(component)
    return true
  }

  /// `Set.addAll`; true when the set changed. Note this is *any* change, not all-or-nothing,
  /// which is what upstream's `if (selected.addAll(comps)) fireSelectionChanged()` tests.
  @discardableResult
  public mutating func addAll(_ components: some Sequence<any Component>) -> Bool {
    var changed = false
    for component in components where add(component) { changed = true }
    return changed
  }

  /// `Set.remove`; true when the set changed.
  @discardableResult
  public mutating func remove(_ component: any Component) -> Bool {
    let key = SelectionComponentKey(component)
    guard keys.remove(key) != nil else { return false }
    if let index = order.firstIndex(where: { SelectionComponentKey($0) == key }) {
      order.remove(at: index)
    }
    return true
  }

  /// `Set.clear`.
  public mutating func removeAll() {
    order.removeAll()
    keys.removeAll()
  }
}

extension ComponentSet: Sequence {
  public func makeIterator() -> IndexingIterator<[any Component]> {
    order.makeIterator()
  }
}

// MARK: - The union view

/// `CollectionUtil.createUnmodifiableSetUnion(selected, lifted)`.
///
/// Upstream's `UnionSet` is a live view over the two backing sets: it iterates the first then the
/// second, and inherits `contains` from `AbstractCollection`, i.e. a linear scan. Note its
/// `size()` is simply `a.size() + b.size()`, which is only correct because `selected` and
/// `lifted` are maintained disjoint; every path that moves a component between them removes it
/// from one before adding it to the other. That invariant is preserved here.
///
/// Materialised on demand rather than kept as a live view, because Swift has no cheap way to
/// express "a `Sequence` that borrows two stored properties" and every caller consumes it
/// immediately.
struct ComponentUnion {
  let anchored: ComponentSet
  let floating: ComponentSet

  /// `iterator()`: `selected` first, then `lifted`, which is `IteratorUtil.createJoinedIterator`.
  var components: [any Component] { anchored.components + floating.components }

  /// `size()`.
  var count: Int { anchored.count + floating.count }

  var isEmpty: Bool { anchored.isEmpty && floating.isEmpty }

  /// `AbstractCollection.contains`.
  func contains(_ component: any Component) -> Bool {
    anchored.contains(component) || floating.contains(component)
  }
}
