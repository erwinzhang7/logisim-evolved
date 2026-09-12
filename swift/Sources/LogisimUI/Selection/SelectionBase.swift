// SelectionBase.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.SelectionBase),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── The distinction this whole file exists to maintain ──────────────────────────────────────
//
// A selection is **two** sets, not one:
//
//   * `selected`; "anchored". Components that are in the circuit and highlighted.
//   * `lifted`  ; "floating". Components that have been taken *out* of the circuit and are
//                  being carried: a paste that has not been anchored yet, a drag in progress.
//
// A lifted component exists nowhere else. The circuit does not hold it; the undo stack does not
// hold it; only this set does. That is why `clear(xn:)` puts them **back into the circuit**
// (`xn.addAll(lifted)`) before emptying the selection, and why `deleteAllHelper` does not; one
// is "stop selecting these", the other is "destroy these". Collapsing the two sets, or clearing
// `lifted` without deciding which of the two it is, silently deletes components on a cancelled
// drag. Every method below that touches `lifted` says which of the two it is doing.
//
// `unionSet` is upstream's live view over the pair, and `selected`/`lifted` are maintained
// disjoint; its `size()` is a plain sum, which is only correct because of that.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `getBounds(Graphics)`, `getComponentsContaining(Location, Graphics)` and
//     `getComponentsWithin(Bounds, Graphics)`: the text-aware variants, which need font metrics
//     to know how far a label extends. D6/D9 put that behind `RenderScene`; the geometric
//     versions are here and are what every non-drawing caller uses. M6.
//   * `print()`; two SLF4J debug dumps.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// `copyComponents` calls `ComponentFactory.createComponent`, which the port makes `throws`, so
// every helper that copies throws. `remove(_:from:)` throws where Java throws
// `IllegalStateException`; removing a lifted component with no transaction to hand it back to
// would otherwise destroy it silently.

import Foundation
import LogisimFile
import LogisimKernel

/// The errors this layer raises. D13: catchable, never a trap.
public enum SelectionError: Error, CustomStringConvertible {
  /// `SelectionBase.remove`: `throw new IllegalStateException("cannot remove")`. Raised when a
  /// *lifted* component is removed from the selection with no `CircuitMutation` to put it back
  /// into the circuit, which would destroy it.
  case cannotRemoveLiftedComponentWithoutMutation

  public var description: String {
    switch self {
    case .cannotRemoveLiftedComponentWithoutMutation:
      return "cannot remove a floating component from the selection without a circuit mutation"
    }
  }
}

/// `Selection.Listener` / `Selection.Event`.
///
/// Java's event carries only its source and every listener ignores it, so the source is the
/// selection itself and nothing else is modelled.
@MainActor
public protocol SelectionListener: AnyObject {
  func selectionChanged(_ selection: SelectionBase)
}

/// `com.cburch.logisim.gui.main.SelectionBase`.
@MainActor
public class SelectionBase {

  // MARK: - Stored state

  /// `selected`: anchored components: in the circuit, and highlighted.
  ///
  /// Module-internal rather than private because `Selection.MyListener` rewrites both sets in
  /// place when a transaction replaces components underneath the selection, exactly as upstream's
  /// inner class reaches into its outer class's fields.
  var selected = ComponentSet()

  /// `lifted`; floating components: **removed from the circuit** and held only here.
  var lifted = ComponentSet()

  /// `suppressHandles`; components the canvas must not draw selection handles for, because
  /// something else (a drag preview) is drawing them.
  private(set) var suppressHandles = ComponentSet()

  /// `unionSet`.
  var unionSet: ComponentUnion { ComponentUnion(anchored: selected, floating: lifted) }

  /// `proj`.
  ///
  /// D3: weak. The ownership runs Project → Frame → Canvas → Selection, so this edge points back
  /// up the chain and must not retain. Java's is a plain field and the GC absorbs the cycle.
  public weak var project: Project?

  /// `bounds`, with upstream's `null` sentinel meaning "recompute on next read".
  private var cachedBounds: Bounds? = Bounds.empty

  /// `shouldSnap`.
  public private(set) var shouldSnap = false

  /// `listeners`.
  ///
  /// **Divergence, and it is D3's.** Upstream holds these in a strong `ArrayList`. Every real
  /// listener is either the `Canvas` that owns this selection or something the canvas owns, so a
  /// strong list is a retain cycle under ARC on every open window. Held weakly instead, with the
  /// caller owning its listener; the same treatment `Circuit`'s listener list already gets.
  ///
  /// A second, smaller difference: upstream's `add` is unconditional and will happily hold the
  /// same listener twice (and fire it twice). This deduplicates. No caller registers twice.
  private let listeners = WeakSelectionListenerList()

  public init(project: Project? = nil) {
    self.project = project
  }

  // MARK: - Listener methods

  /// `addListener(Selection.Listener)`.
  public func addListener(_ listener: any SelectionListener) { listeners.add(listener) }

  /// `removeListener(Selection.Listener)`.
  public func removeListener(_ listener: any SelectionListener) { listeners.remove(listener) }

  /// `addListener` returning a token the caller retains, D3's standard subscription shape.
  ///
  /// Kept from the tools slice, which reached the same conclusion independently and recorded the
  /// reason: upstream's `SelectTool.select` guards registration with `selectionsAdded`, a
  /// `HashSet<Selection>` that is tested but **never added to** and never removed from, so a
  /// listener is registered again on every `select`, and the set grows forever. Holding one
  /// subscription and replacing it does what that code meant. The weak listener list below means
  /// there is no leak either way; the token is what makes the *duplicate registration* go away,
  /// which is the half of the upstream bug that has an observable effect.
  public func addSelectionListener(_ listener: any SelectionListener) -> ToolSubscription {
    addListener(listener)
    return ToolSubscription { [weak self, weak listener] in
      guard let self, let listener else { return }
      self.removeListener(listener)
    }
  }

  /// `fireSelectionChanged()`.
  ///
  /// Order matters and is upstream's: invalidate the bounds cache, recompute `shouldSnap`, then
  /// notify, so a listener that reads either during the callback sees the new value.
  public func fireSelectionChanged() {
    cachedBounds = nil
    computeShouldSnap()
    for listener in listeners.current() { listener.selectionChanged(self) }
  }

  // MARK: - Query methods

  /// `isEmpty()`.
  public var isEmpty: Bool { selected.isEmpty && lifted.isEmpty }

  /// `getAnchoredComponents()`; the components that are in the circuit.
  ///
  /// The distinction from `components` is not cosmetic and the tools use each for a different
  /// job: `getComponents()` is everything selected, while this excludes components that were
  /// *lifted* out of the circuit by a cut or paste and are floating over it. **The move engine is
  /// fed the anchored set** (`SelectTool.java:311`), because a floating component has no wires in
  /// the circuit to reroute; hand it the full set and the reroute search is asked to connect
  /// endpoints that do not exist.
  public var anchoredComponents: [any Component] { selected.components }

  /// `getFloatingComponents()`; the components that are **not** in the circuit and exist only
  /// in this selection.
  public var floatingComponents: [any Component] { lifted.components }

  /// `getComponents()`.
  public var components: [any Component] { unionSet.components }

  /// `Selection.contains(Component)`: declared on the subclass upstream, but it is a pure query
  /// over `unionSet` and belongs with the rest of them.
  public func contains(_ component: any Component) -> Bool { unionSet.contains(component) }

  /// `getBounds()`. Lazily recomputed after any change, exactly as upstream caches it.
  public var bounds: Bounds {
    if let cachedBounds { return cachedBounds }
    let computed = SelectionBase.computeBounds(unionSet.components)
    cachedBounds = computed
    return computed
  }

  /// `shouldSnap()` is a method upstream; a property here. Same value.
  public func snapsToGrid() -> Bool { shouldSnap }

  /// `getComponentsContaining(Location)`.
  public func componentsContaining(_ query: Location) -> [any Component] {
    unionSet.components.filter { $0.contains(query) }
  }

  /// `getComponentsWithin(Bounds)`.
  public func componentsWithin(_ box: Bounds) -> [any Component] {
    unionSet.components.filter { box.contains($0.bounds) }
  }

  /// `hasConflictWhenMoved(int, int)`. Note `selfConflicts: false`; the selection moving over
  /// its own footprint is not a conflict.
  public func hasConflictWhenMoved(dx: Int, dy: Int) -> Bool {
    hasConflictTranslated(unionSet.components, dx: dx, dy: dy, selfConflicts: false)
  }

  // MARK: - Action methods

  /// `add(Component)`; adds to the **anchored** set. Nothing here lifts anything.
  public func add(_ component: any Component) {
    if selected.add(component) { fireSelectionChanged() }
  }

  /// `addAll(Collection<? extends Component>)`.
  public func addAll(_ components: some Sequence<any Component>) {
    if selected.addAll(components) { fireSelectionChanged() }
  }

  /// `setSuppressHandles(Collection<Component>)`: `nil` clears, as upstream's null does.
  ///
  /// What it is for: hiding the drag handles of wires the edit tool is about to extend, so they
  /// do not draw on top of the new wire being dragged out of them.
  public func setSuppressHandles<S: Sequence>(_ toSuppress: S?)
  where S.Element == any Component {
    suppressHandles.removeAll()
    if let toSuppress { suppressHandles.addAll(toSuppress) }
  }

  /// The `nil` overload of `setSuppressHandles`, which Swift cannot infer an element type for.
  public func clearSuppressHandles() {
    suppressHandles.removeAll()
  }

  /// `clear(CircuitMutation)`: empties the selection, **keeping** every component alive.
  ///
  /// The floating ones are put back into the circuit first (`xn.addAll(lifted)`). This is the
  /// method that must not be confused with `deleteAllHelper`.
  func clear(_ mutation: CircuitMutation) {
    clear(mutation, dropLifted: true)
  }

  /// `clear(CircuitMutation, boolean)`.
  ///
  /// `dropLifted: false` is the caller saying it has already taken responsibility for the
  /// floating components; it is *not* permission to discard them.
  ///
  /// The mutation is deliberately **not** optional, unlike `remove`'s. Upstream's is nullable
  /// only because Java has no other way to write the signature, and every call site passes a real
  /// transaction; a `nil` here with `dropLifted: true` would silently destroy every floating
  /// component, which is the exact failure this file exists to prevent.
  func clear(_ mutation: CircuitMutation, dropLifted: Bool) {
    if selected.isEmpty && lifted.isEmpty { return }

    if dropLifted && !lifted.isEmpty {
      // Anchor them: they are in no circuit right now, and this is the only reference to them.
      mutation.addAll(lifted.components)
    }

    selected.removeAll()
    lifted.removeAll()
    shouldSnap = false
    cachedBounds = Bounds.empty

    fireSelectionChanged()
  }

  /// `remove(CircuitMutation, Component)`; removes from the **selection**, not the circuit.
  ///
  /// D13: `throws` where Java throws `IllegalStateException`. A floating component removed with
  /// no transaction to re-anchor it into would simply cease to exist, so the failure is refused
  /// rather than performed.
  func remove(_ component: any Component, using mutation: CircuitMutation?) throws {
    var removed = selected.remove(component)

    if lifted.contains(component) {
      guard let mutation else {
        throw SelectionError.cannotRemoveLiftedComponentWithoutMutation
      }
      lifted.remove(component)
      removed = true
      mutation.add(component)
    }

    if removed {
      // Upstream only recomputes when the departing component was itself a snapping one: an
      // optimisation, not a behaviour: a non-snapping component cannot have been the reason
      // `shouldSnap` was true.
      if SelectionBase.shouldSnapComponent(component) { computeShouldSnap() }
      fireSelectionChanged()
    }
  }

  /// `deleteAllHelper(CircuitMutation)`; removes the anchored components **from the circuit**
  /// and discards the floating ones.
  ///
  /// Discarding `lifted` here is correct and is the difference from `clear`: a floating component
  /// is not in the circuit, so "delete it" is exactly "stop holding it".
  func deleteAllHelper(_ mutation: CircuitMutation) {
    for component in selected { mutation.remove(component) }
    selected.removeAll()
    lifted.removeAll()
    fireSelectionChanged()
  }

  /// `dropAll(CircuitMutation)`: anchors every floating component, keeping it selected.
  func dropAll(_ mutation: CircuitMutation) {
    if !lifted.isEmpty {
      mutation.addAll(lifted.components)
      selected.addAll(lifted.components)
      lifted.removeAll()
    }
  }

  /// `duplicateHelper(CircuitMutation)`.
  ///
  /// Note it duplicates *both* sets, `oldSelected` is `selected` plus `lifted`, and then goes
  /// through `pasteHelper`, so the originals are anchored by the `clear` inside it and the copies
  /// become the new floating set.
  func duplicateHelper(_ mutation: CircuitMutation) throws {
    var oldSelected = ComponentSet(selected)
    oldSelected.addAll(lifted)
    try pasteHelper(mutation, oldSelected.components)
  }

  /// `pasteHelper(CircuitMutation, Collection<Component>)`.
  ///
  /// The copies land in `lifted`, not `selected`: a paste is floating until it is anchored, which
  /// is what lets it be dragged into place and what makes `Anchor`/`Drop` coalesce onto it.
  func pasteHelper(_ mutation: CircuitMutation, _ comps: [any Component]) throws {
    clear(mutation)

    let newLifted = try copyComponents(comps, translate: false)
    lifted.addAll(newLifted.map(\.copy))
    fireSelectionChanged()
  }

  /// `translateHelper(CircuitMutation, int, int)`.
  ///
  /// Two things here look like bugs and are not:
  ///
  /// 1. The originals are **left in `selected`** after their replacements are added. Upstream
  ///    relies on the transaction result coming back through `Selection.MyListener`, which sees
  ///    the replacement map and swaps them out. Removing them here instead would look tidier and
  ///    would break that hand-off.
  /// 2. Formerly-floating components end up in `selected`, not `lifted`: translating anchors
  ///    them, because `xn.add` puts them into the circuit.
  ///
  /// `translate: true` on both copies means the replacements **share** the originals' attribute
  /// sets rather than cloning them. That is deliberate upstream: a move must not fork a
  /// component's attributes, or a moved component would stop responding to the attribute table.
  func translateHelper(_ mutation: CircuitMutation, dx: Int, dy: Int) throws {
    let translated = try copyComponents(selected.components, dx: dx, dy: dy, translate: true)
    for entry in translated {
      mutation.replace(entry.original, with: entry.copy)
      selected.add(entry.copy)
    }

    let liftedAfter = try copyComponents(lifted.components, dx: dx, dy: dy, translate: true)
    lifted.removeAll()
    for entry in liftedAfter {
      mutation.add(entry.copy)
      selected.add(entry.copy)
    }
    fireSelectionChanged()
  }

  // MARK: - Copying

  /// One entry of the `HashMap<Component, Component>` upstream's `copyComponents` returns.
  ///
  /// A list of pairs rather than a dictionary, so the iteration order the callers depend on is
  /// the input order rather than a hash order. See `ComponentSet`'s header: Java's is arbitrary
  /// but stable per run, Swift's would be arbitrary *and reseeded per process*.
  struct ComponentCopy {
    let original: any Component
    let copy: any Component
  }

  /// `copyComponents(Collection<Component>, boolean)`; the offset search.
  ///
  /// **This is where duplicate's and paste's coordinates come from, so it is byte-exact
  /// territory.** The rule: try candidate offsets along successively larger squares radiating out
  /// from the origin, in units of 10, and take the first that (a) keeps the whole group at
  /// non-negative coordinates and (b) does not collide with anything already in the circuit.
  ///
  /// Index 0 is `(0, 0)`. For a *paste* into empty space that succeeds immediately, so a paste
  /// lands exactly where it was copied from. For a *duplicate* it always collides, the original
  /// is still there with identical bounds, so the search advances to index 1, which is `(10,
  /// 10)`. That is the "fixed offset" a duplicated component appears at, and it is emergent from
  /// this loop rather than a constant, which is why the loop is reproduced rather than shortcut.
  ///
  /// The bound check uses the group's *untranslated* bounds, as upstream's does.
  ///
  /// ── THE FLOOR IS THE GROUP'S OWN CORNER, NOT THE ORIGIN ─────────────────────────────────
  ///
  /// Upstream's condition is `bds.getX() + dx >= 0 && bds.getY() + dy >= 0`, and it was verbatim
  /// here. Now that this port has no origin wall (`SelectTool.computeDxDy` records why), a
  /// literal `0` would stop being "keep the copy on the sheet" and become "drag the copy back to
  /// the sheet": copy a gate at (−200, −140), paste, and the search would walk outward for
  /// twenty rings and land it at x ≈ 0, nowhere near the thing it was copied from.
  ///
  /// **The relaxation is exactly nothing for every circuit upstream can produce.** For a group
  /// already in the non-negative quadrant `min(bds.x, 0)` IS `0`, so the condition is character
  /// for character upstream's and the emergent offsets are untouched: including the one that
  /// matters, paste-into-empty-space landing at index 0 and duplicate falling through to index 1
  /// at (10, 10). `NoOriginWallTests.duplicateStillLandsAtTenTen` pins that, and it stays green
  /// with the floor forced back to a literal `0`, which is the measurement that makes "no-op"
  /// a fact rather than an argument.
  /// For a group that is *already* above or left of the origin the floor moves with it, so the
  /// same two offsets come out mirrored instead of the group being dragged back.
  func copyComponents(
    _ components: [any Component], translate: Bool
  ) throws -> [ComponentCopy] {
    let bds = SelectionBase.computeBounds(components)
    let floorX = min(bds.x, 0)
    let floorY = min(bds.y, 0)
    var index = 0
    while true {
      var dx: Int
      var dy: Int
      if index == 0 {
        dx = 0
        dy = 0
      } else {
        // The smallest odd `side` with `side * side > index`; `offs` is the position along the
        // ring between that square and the previous one.
        var side = 1
        while wrap32(side &* side) <= index { side += 2 }
        var offs = wrap32(index &- wrap32((side &- 2) &* (side &- 2)))
        dx = side / 2
        dy = side / 2
        if offs < side - 1 {  // top edge of the square
          dx = wrap32(dx &- offs)
        } else if offs < 2 * (side - 1) {  // left edge
          offs = wrap32(offs &- (side &- 1))
          dx = wrap32(0 &- dx)
          dy = wrap32(dy &- offs)
        } else if offs < 3 * (side - 1) {  // right edge
          offs = wrap32(offs &- 2 &* (side &- 1))
          dx = wrap32(wrap32(0 &- dx) &+ offs)
          dy = wrap32(0 &- dy)
        } else {  // bottom edge
          offs = wrap32(offs &- 3 &* (side &- 1))
          dy = wrap32(wrap32(0 &- dy) &+ offs)
        }
        dx = wrap32(dx &* 10)
        dy = wrap32(dy &* 10)
      }

      if wrap32(bds.x &+ dx) >= floorX, wrap32(bds.y &+ dy) >= floorY,
        !hasConflictTranslated(components, dx: dx, dy: dy, selfConflicts: true)
      {
        return try copyComponents(components, dx: dx, dy: dy, translate: translate)
      }
      index = wrap32(index &+ 1)
    }
  }

  /// `copyComponents(Collection<Component>, int, int, boolean)`.
  ///
  /// Two attribute rules, both upstream's and both observable in the saved file:
  ///
  /// * `translate == true` (a move) **shares** the original attribute set. A move is not a fork.
  /// * RAM and ROM share it too, even on a copy. Their `contents` is a memory image upstream
  ///   refuses to duplicate, so a copied RAM aliases the original's contents. See
  ///   `SelectionFactoryTests.sharesAttributesWhenCopied` for how the `instanceof` test is
  ///   spelled here.
  ///
  /// Everything else gets `attrs.clone()`, which is what makes cut/copy/paste carry attributes
  /// exactly rather than by reference.
  ///
  /// Note the snap decision is taken against the **new** attribute set, and the resulting
  /// `Location` is built with `hasToSnap: false`; the snapping has already happened, and D14
  /// makes that flag meaningful in this port where upstream's interning made it accidental.
  func copyComponents(
    _ components: [any Component], dx: Int, dy: Int, translate: Bool
  ) throws -> [ComponentCopy] {
    var result: [ComponentCopy] = []
    result.reserveCapacity(components.count)
    for comp in components {
      let oldLoc = comp.location
      let factory = comp.factory
      let attrs: any AttributeSet =
        (translate || SelectionFactoryTests.sharesAttributesWhenCopied(factory))
        ? comp.attributeSet
        : comp.attributeSet.copy()
      var newX = wrap32(oldLoc.x &+ dx)
      var newY = wrap32(oldLoc.y &+ dy)
      let snap = factory.feature(.shouldSnap, attrs) as? Bool
      if snap == nil || snap == true {
        newX = SelectionBase.snapXToGrid(newX)
        newY = SelectionBase.snapYToGrid(newY)
      }
      let newLoc = Location.create(newX, newY, hasToSnap: false)
      let copy = try factory.createComponent(location: newLoc, attributes: attrs)
      result.append(ComponentCopy(original: comp, copy: copy))
    }
    return result
  }

  // MARK: - Private helpers

  /// `computeBounds(Collection<Component>)`.
  static func computeBounds(_ components: [any Component]) -> Bounds {
    guard let first = components.first else { return Bounds.empty }
    var result = first.bounds
    for comp in components.dropFirst() { result = result.add(comp.bounds) }
    return result
  }

  /// `shouldSnapComponent(Component)`; absent feature means yes.
  static func shouldSnapComponent(_ comp: any Component) -> Bool {
    let value = comp.factory.feature(.shouldSnap, comp.attributeSet) as? Bool
    return value == nil || value == true
  }

  /// `computeShouldSnap()`: true when *any* member snaps.
  private func computeShouldSnap() {
    shouldSnap = false
    for comp in unionSet.components where SelectionBase.shouldSnapComponent(comp) {
      shouldSnap = true
      return
    }
  }

  /// `hasConflictTranslated(Collection<Component>, int, int, boolean)`.
  ///
  /// Wires are exempt on the outer loop: they overlap by design. For everything else two things
  /// count as a conflict at the translated position: an *exclusive* end landing on another
  /// exclusive end, and a component already there with **identical bounds** (upstream's stand-in
  /// for "the same thing is already here").
  ///
  /// `selfConflicts` distinguishes the two callers. `copyComponents` passes true; landing on the
  /// original counts, which is what pushes a duplicate off to (10, 10). `hasConflictWhenMoved`
  /// passes false; the selection sliding over its own footprint does not.
  ///
  /// See `SelectionCircuitQueries`: the exclusive-end half is inert until M3 lands
  /// `CircuitPoints`, and errs permissive.
  func hasConflictTranslated(
    _ components: [any Component], dx: Int, dy: Int, selfConflicts: Bool
  ) -> Bool {
    guard let circuit = project?.currentCircuit else { return false }
    let membership = ComponentSet(components)

    for comp in components where !(comp is Wire) {
      for endData in comp.ends where endData.isExclusive {
        let endLoc = endData.location.translate(dx, dy)
        if let conflict = circuit.exclusiveComponent(at: endLoc) {
          if selfConflicts || !membership.contains(conflict) { return true }
        }
      }
      let newLoc = comp.location.translate(dx, dy)
      let newBounds = comp.bounds.translate(dx, dy)
      for other in circuit.componentsContaining(newLoc) where other.bounds == newBounds {
        if selfConflicts || !membership.contains(other) { return true }
      }
    }
    return false
  }

  // MARK: - Grid snapping

  /// `Canvas.snapXToGrid(int)`.
  ///
  /// Kept here rather than on the canvas because it is model arithmetic that decides saved
  /// coordinates, and D9 keeps the canvas out of anything the headless side has to reproduce.
  /// The asymmetric negative branch is upstream's and is not a rounding idiom Swift's `/`
  /// reproduces on its own, so it is written out.
  public static func snapXToGrid(_ x: Int) -> Int {
    x < 0
      ? wrap32(0 &- wrap32(wrap32(wrap32(0 &- x) &+ 5) / 10 &* 10))
      : wrap32(wrap32(wrap32(x &+ 5) / 10) &* 10)
  }

  /// `Canvas.snapYToGrid(int)`.
  public static func snapYToGrid(_ y: Int) -> Int {
    snapXToGrid(y)
  }
}

// MARK: - Weak listener list

/// The selection's own listener list. See `SelectionBase.listeners` for why it is weak where
/// upstream's is strong.
///
/// `LogisimFile` has an identical `WeakListenerList`, but it is internal to that module, so this
/// is a local copy rather than a new public API added to somebody else's file.
@MainActor
final class WeakSelectionListenerList {
  private final class Box {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  private var boxes: [Box] = []

  func add(_ listener: any SelectionListener) {
    purge()
    let object = listener as AnyObject
    guard !boxes.contains(where: { $0.value === object }) else { return }
    boxes.append(Box(object))
  }

  func remove(_ listener: any SelectionListener) {
    let object = listener as AnyObject
    boxes.removeAll { $0.value == nil || $0.value === object }
  }

  /// Snapshot before dispatch: a listener may unsubscribe from inside its own callback.
  func current() -> [any SelectionListener] {
    purge()
    return boxes.compactMap { $0.value as? any SelectionListener }
  }

  private func purge() {
    boxes.removeAll { $0.value == nil }
  }
}
