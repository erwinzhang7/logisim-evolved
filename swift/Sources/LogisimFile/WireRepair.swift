// WireRepair.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.WireRepair),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY A CODEC MILESTONE NEEDS THIS ═════════════════════════════════════════════════════════
//
// It looks like editor behaviour and it is not: `CircuitTransaction.execute()` runs it after
// EVERY transaction, and loading a file is a transaction.
//
//     // Now go through each affected circuit and repair its wires
//     for (final var circuit : modified) { new WireRepair(circuit).run(mutator); }
//                                                     ; CircuitTransaction.java:63-68
//
// So the wire set upstream saves is not the wire set it read. Measured on a 2.7.0 corpus file
// whose source carries a single `<wire from="(430,210)" to="(480,210)"/>`: the oracle writes two
// wires, split at `(450,210)`, because a J-K flip-flop has a port there. `(450,210)` appears
// nowhere in the input. 19 corpus files differed from the oracle in nothing but this.
//
// The three passes run in order and each sees the previous one's result:
//
//   doMerges    two collinear wires meeting at a point where nothing else connects become one
//   doOverlaps  wires that overlap or touch anywhere are unified, then re-cut at every point
//               where something else connects
//   doSplits    a wire is cut at every connection point strictly inside it
//
// ── Determinism ──────────────────────────────────────────────────────────────────────────────
//
// Upstream iterates `HashMap` key sets and an `IdentityHashMap` in all three passes, so the
// ORDER differs run to run. The RESULT does not, and that is what licenses this port: every
// pass computes a union of wires (order-independent), and every merge set is reduced through
// `min`/`max` of a sorted location list or through a `TreeSet`. This port iterates
// deterministically anyway, which is strictly stronger and matches the same fixed point.
//
// ── What `CircuitPoints` had to be stood in for ──────────────────────────────────────────────
//
// Upstream asks `circuit.wires.points` for the connection map. `CircuitPoints` is M3 (it also
// carries bit-width incompatibility detection, which needs the propagation model), so the two
// queries this pass makes are computed here from the circuit's own contents:
//
//   `getAllLocations()`      every location where a wire ENDS or a component has an end
//   `getComponents(loc)`     the components with an end at exactly that location
//
// Note both are about *endpoints*, not about the interior of a wire; `CircuitPoints.add(Wire)`
// records `getEnd0()` and `getEnd1()` and nothing between them. `doOverlaps` is the one pass
// that walks a wire's interior, and it does so through `Wire`'s own iterator, not through the
// point map.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.WireRepair`.
///
/// Upstream is a `CircuitTransaction` and reports its edits through a `CircuitMutator` so they
/// can be undone. Nothing is undoable during a load and the transaction machinery is M3, so this
/// applies its replacements directly, through the same `mutatorAdd`/`mutatorRemove` pair the
/// mutator would have called.
/// An unambiguous spelling of `WireRepair` for callers above this module.
///
/// **`LogisimFile.WireRepair` does not work, and cannot.** `LogisimFile` is both this module and
/// a class inside it, so Swift reads that as a member lookup on the type and reports "type
/// 'LogisimFile' has no member 'WireRepair'". Module qualification is simply unavailable when a
/// module and a type share a name.
///
/// That matters because `LogisimUI` declares its OWN `WireRepair`: an unrelated protocol, from
/// an unrelated upstream class (`com.cburch.logisim.tools.WireRepair`, "can this component absorb
/// a loose wire end", versus `com.cburch.logisim.circuit.WireRepair`, this repair pass). Inside
/// `LogisimUI` the bare name resolves to the protocol, and there is no way to spell the struct.
///
/// So the disambiguation has to be exported from here. Same shape as the two `TextTool` types and
/// `Text` against SwiftUI's: Java's package system keeps these apart for free, and Swift's flat
/// module namespace does not.
public typealias CircuitWireRepairPass = WireRepair

public struct WireRepair {
  private let circuit: Circuit

  public init(circuit: Circuit) {
    self.circuit = circuit
  }

  /// `WireRepair.run(CircuitMutator)`. The order of the three passes is upstream's and is
  /// observable: `doOverlaps` relies on `doMerges` having already collapsed the easy cases, and
  /// `doSplits` re-cuts whatever the first two joined.
  public func run() {
    // A sink that cannot throw, so `rethrows` makes this call non-throwing and the load path
    // keeps the exact signature and behaviour it has always had.
    runRepair { replacements in
      // ALL removals, THEN all additions -- see `apply`. Not per entry.
      for wire in replacements.keys {
        circuit.mutatorRemove(wire)
      }
      for pieces in replacements.values {
        for piece in pieces {
          // `mutatorAdd`'s only throwing branch is the duplicate-label check, guarded on
          // `component is Wire`, so it cannot throw here. A `try!` would trap, which D13 forbids.
          try? circuit.mutatorAdd(piece)
        }
      }
    }
  }

  /// `WireRepair.run(CircuitMutator)`; the editor's path.
  ///
  /// **Why a sink rather than a `plan()`.** The obvious shape is "compute the replacements, hand
  /// them back, let the caller apply them", and it cannot work here: the three passes are
  /// order-dependent and each one's output is the next one's input. `doOverlaps` relies on
  /// `doMerges` having already collapsed the easy cases, and `doSplits` re-cuts whatever the
  /// first two joined, so a pure planner would have to simulate the intermediate circuits.
  /// Upstream has the same constraint and solves it the same way: it IS a `CircuitTransaction`
  /// and reports each edit through a `CircuitMutator` as it goes.
  ///
  /// **Why a closure rather than the mutator itself.** `CircuitMutator` lives in `LogisimUI`,
  /// which is above this module, and `ReplacementMap` with it. A sink typed over `LogisimFile`
  /// types lets the editor route these edits into its undo record without inverting the
  /// dependency.
  ///
  /// `run()` keeps applying directly, which is correct for the load path it was written for,
  /// nothing is undoable during a load, and is what keeps the corpus gates byte-identical.
  public func run(applying sink: (_ replacements: [Wire: [Wire]]) throws -> Void) rethrows {
    try runRepair(sink)
  }

  private func runRepair(_ sink: (_ replacements: [Wire: [Wire]]) throws -> Void) rethrows {
    try doMerges(sink)
    try doOverlaps(sink)
    try doSplits(sink)
  }

  // MARK: - The stand-in for CircuitPoints

  /// `CircuitPoints.map`, rebuilt: location → components with an end there, in the order they
  /// were added to the circuit.
  ///
  /// Insertion order is upstream's too (`LocationData.components` is an `ArrayList`), and
  /// `doMerges` reads it positionally; it takes the first two entries at a location that has
  /// exactly two. With exactly two the order between them cannot change the answer, since the
  /// test that follows (`both are wires && isParallel`) is symmetric.
  private func connectionPoints() -> [Location: [any Component]] {
    var points: [Location: [any Component]] = [:]
    for component in circuit.nonWires {
      for end in component.ends {
        points[end.location, default: []].append(component)
      }
    }
    for wire in circuit.wires {
      points[wire.endpoint0, default: []].append(wire)
      points[wire.endpoint1, default: []].append(wire)
    }
    return points
  }

  // MARK: - doMerges

  /// `doMerges(CircuitMutator)`.
  ///
  /// A location with exactly two components, both wires, both parallel, is an artificial break:
  /// nothing else connects there, so the two segments are one wire drawn as two. The whole merge
  /// set becomes a single wire from its lowest endpoint to its highest.
  private func doMerges(_ sink: (_ replacements: [Wire: [Wire]]) throws -> Void) rethrows {
    let points = connectionPoints()
    var sets = WireMergeSets()
    // Sorted, where upstream walks a HashMap key set. The union is order-independent; sorting
    // only removes the run-to-run variation upstream has.
    for location in points.keys.sorted() {
      guard let at = points[location], at.count == 2 else { continue }
      guard let w0 = at[0] as? Wire, let w1 = at[1] as? Wire else { continue }
      if w0.isParallel(to: w1) { sets.merge(w0, w1) }
    }

    var replacements: [Wire: [Wire]] = [:]
    for mergeSet in sets.mergeSets where mergeSet.count > 1 {
      var locations: [Location] = []
      for wire in mergeSet {
        locations.append(wire.endpoint0)
        locations.append(wire.endpoint1)
      }
      locations.sort()
      let merged = Wire.create(locations[0], locations[locations.count - 1])
      for wire in mergeSet where wire != merged {
        replacements[wire] = [merged]
      }
    }
    try apply(replacements, sink)
  }

  // MARK: - doOverlaps

  /// `doOverlaps(CircuitMutator)`.
  ///
  /// Groups wires that share ANY grid point, not merely an endpoint, so a wire lying on top of
  /// another, or crossing it collinearly, is unified. `doMergeSet` then re-cuts the union at
  /// every point where something outside the set connects.
  private func doOverlaps(_ sink: (_ replacements: [Wire: [Wire]]) throws -> Void) rethrows {
    var wirePoints: [Location: [Wire]] = [:]
    for wire in circuit.wires {
      for location in wire {
        wirePoints[location, default: []].append(wire)
      }
    }

    var sets = WireMergeSets()
    for location in wirePoints.keys.sorted() {
      let locWires = wirePoints[location]!
      guard locWires.count > 1 else { continue }
      for i in 0..<locWires.count {
        for j in (i + 1)..<locWires.count {
          // `overlaps(_:includeEnds: false)`: two wires that merely touch end-to-end are NOT
          // overlapping. `doMerges` above is the pass that handles that case, and only when
          // nothing else connects at the shared point.
          if locWires[i].overlaps(locWires[j], includeEnds: false) {
            sets.merge(locWires[i], locWires[j])
          }
        }
      }
    }

    let points = connectionPoints()
    var replacements: [Wire: [Wire]] = [:]
    for mergeSet in sets.mergeSets where mergeSet.count > 1 {
      mergeOne(mergeSet, into: &replacements, points: points)
    }
    try apply(replacements, sink)
  }

  /// `doMergeSet(ArrayList<Wire>, ReplacementMap, Set<Location>)`.
  private func mergeOne(
    _ mergeSet: [Wire], into replacements: inout [Wire: [Wire]],
    points: [Location: [any Component]]
  ) {
    // Java's `TreeSet<Location>`, sorted and deduplicated.
    var ends: Set<Location> = []
    for wire in mergeSet {
      ends.insert(wire.endpoint0)
      ends.insert(wire.endpoint1)
    }
    let sortedEnds = ends.sorted()
    let whole = Wire.create(sortedEnds[0], sortedEnds[sortedEnds.count - 1])

    var mids: Set<Location> = [whole.endpoint0, whole.endpoint1]
    for location in whole {
      guard let at = points[location] else { continue }
      // "some component that is not part of this merge set connects here", so the union has to
      // be cut rather than left whole. Wires compare by value (D4 does not apply to `Wire`:
      // upstream gives it a real `equals`/`hashCode` over its endpoints), everything else by
      // identity.
      let foreign = at.contains { component in
        if let wire = component as? Wire { return !mergeSet.contains(wire) }
        return true
      }
      if foreign { mids.insert(location) }
    }

    var mergeResult: [Wire] = []
    if mids.count == 2 {
      mergeResult.append(whole)
    } else {
      var previous: Location? = nil
      for location in mids.sorted() {
        if let previous { mergeResult.append(Wire.create(previous, location)) }
        previous = location
      }
    }

    for wire in mergeSet {
      replacements[wire] = mergeResult.filter { $0.overlaps(wire, includeEnds: false) }
    }
  }

  // MARK: - doSplits

  /// `doSplits(CircuitMutator)`.
  ///
  /// The pass that produced the measured divergence: a wire is cut at every connection point
  /// strictly inside it, so a segment drawn straight through a component's port arrives as one
  /// wire and is saved as two.
  private func doSplits(_ sink: (_ replacements: [Wire: [Wire]]) throws -> Void) rethrows {
    let allLocations = Set(connectionPoints().keys)
    var replacements: [Wire: [Wire]] = [:]
    for wire in circuit.wires {
      let e0 = wire.endpoint0
      let e1 = wire.endpoint1
      var splits: [Location] = []
      for location in allLocations
      where wire.contains(location) && location != e0 && location != e1 {
        splits.append(location)
      }
      guard !splits.isEmpty else { continue }
      splits.append(e1)
      splits.sort()
      var start = e0
      var pieces: [Wire] = []
      pieces.reserveCapacity(splits.count)
      for end in splits {
        pieces.append(Wire.create(start, end))
        start = end
      }
      replacements[wire] = pieces
    }
    try apply(replacements, sink)
  }

  // MARK: - Applying a replacement map

  /// `CircuitMutator.replace(Circuit, ReplacementMap)`, reduced to wires.
  ///
  /// Removals happen before additions, because a merge maps several wires onto one and the
  /// replacement is in the removal set of every other member. Doing it the other way round would
  /// add the merged wire and then delete it again.
  ///
  /// `mutatorAdd` cannot throw for a wire, its only throwing branch is the duplicate-label
  /// check, which is guarded on `component is Wire`, but the signature does, so the error is
  /// discarded here rather than propagated through three private passes that have no way to
  /// report it. A `try!` would trap, which D13 forbids on the file path.
  /// Hands the sink the WHOLE batch, not one replacement at a time.
  ///
  /// **That is not a style choice and I got it wrong first.** A merged wire's replacement is in
  /// the removal set of every other member of its merge set, so all removals must precede all
  /// additions; applying one entry at a time adds the merged wire and then deletes it again. My
  /// first version of this split passed `(remove, add)` pairs, which silently moved that ordering
  /// out of the algorithm and into whatever the caller happened to do -- caught by re-reading the
  /// note the original `apply` already carried, before the corpus gate had a chance to.
  ///
  /// The sink owns applying, and in the editor also recording, which is what makes a repair
  /// undoable. `run()` supplies one that applies directly, exactly as this did before the
  /// parameter existed.
  private func apply(
    _ replacements: [Wire: [Wire]],
    _ sink: (_ replacements: [Wire: [Wire]]) throws -> Void
  ) rethrows {
    guard !replacements.isEmpty else { return }
    try sink(replacements)
  }
}

// MARK: - MergeSets

/// `WireRepair.MergeSets`; a disjoint-set forest over wires, in upstream's exact shape.
///
/// Upstream stores `HashMap<Wire, ArrayList<Wire>>` and relies on the *identity* of the lists to
/// enumerate distinct sets (`getMergeSets` collects them into an `IdentityHashMap`). Swift arrays
/// are value types, so the equivalent is a plain union-find keyed on the wires themselves. The
/// two agree on every input: both compute the transitive closure of the merge relation.
///
/// One upstream detail deliberately not reproduced: its union-by-size (`if set0.size() >
/// set1.size()` swap) is a performance measure, and the resulting partition is identical either
/// way.
private struct WireMergeSets {
  private var parent: [Wire: Wire] = [:]
  /// Insertion order, so `mergeSets` is deterministic rather than dictionary-ordered.
  private var order: [Wire] = []

  private mutating func find(_ wire: Wire) -> Wire {
    if parent[wire] == nil {
      parent[wire] = wire
      order.append(wire)
      return wire
    }
    var root = wire
    while let next = parent[root], next != root { root = next }
    // Path compression, which upstream gets for free from its list representation.
    var current = wire
    while let next = parent[current], next != root {
      parent[current] = root
      current = next
    }
    return root
  }

  mutating func merge(_ a: Wire, _ b: Wire) {
    let rootA = find(a)
    let rootB = find(b)
    if rootA != rootB { parent[rootA] = rootB }
  }

  /// Every set with its members in insertion order. Singletons are included, matching upstream:
  /// both callers filter on `count > 1`.
  var mergeSets: [[Wire]] {
    var copy = self
    var grouped: [Wire: [Wire]] = [:]
    var roots: [Wire] = []
    for wire in order {
      let root = copy.find(wire)
      if grouped[root] == nil { roots.append(root) }
      grouped[root, default: []].append(wire)
    }
    return roots.map { grouped[$0]! }
  }
}
