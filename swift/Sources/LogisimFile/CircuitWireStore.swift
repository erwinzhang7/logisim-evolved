// CircuitWireStore.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitWires: the storage half
// only), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── Scope: this is deliberately NOT `CircuitWires` ───────────────────────────────────────────
//
// `CircuitWires.java` is two things: a store (the wire set, its bounds, the per-wire bus-width
// position) and a connectivity engine (`CircuitPoints`, `WireBundle`, union-find, tunnel and
// splitter joining, width inference, `WidthIncompatibilityData`). M2 is the inert netlist, so
// only the store is here, under a different name so nobody mistakes it for the real thing.
//
// The connectivity engine is M3 and lands as `CircuitWires`. Objectives records one invariant it
// must carry over (D15): the `width <= 1` early return at `CircuitWires.java:348-352` guards the
// `create_unsafe` at `:377` from 400 lines away, and dropping it silently produces `ERROR` where
// Java produces a value.
//
// ── Two encodings that differ from Java on purpose ──────────────────────────────────────────
//
//   * **Ordered wires.** Java's is a `HashSet<Wire>`, so `Circuit.getWires()` iterates in hash
//     order. This keeps insertion order alongside the set. That is a strict improvement rather
//     than a fidelity risk, because `XmlWriter.sort` sorts every `<circuit>` child before writing
//     (`XmlWriter.java:164`), so wire order never reaches the file; and dedup still goes through
//     the set, i.e. still by `Wire.equals` (endpoints), which is what makes a duplicated `<wire>`
//     element a no-op.
// ── Version note: the bus-width position is post-4.1.0 ──────────────────────────────────────
//
// `Wire.BUS_WIDTH_POS_*`, `CircuitWires.wireBusWidthPos`, `Circuit.get/setWireBusWidthPos` and
// the `<wire buswidthpos="…">` attribute do not exist at v4.1.0; `git grep buswidthpos v4.1.0`
// finds nothing. They were added on `main` afterwards.
//
// This matters for the M2 gate, not for correctness here: the differential oracle is the shipped
// 4.1.0 jar, which never writes the attribute, so **the writer must not emit `buswidthpos` while
// 4.1.0 is the oracle** or byte-exact comparison fails for any file carrying one. It is latent
// rather than live, because the reader only populates it from an input file that already has the
// attribute and no 4.1.0-era file does. The storage is kept; dropping it would lose data from
// files written by newer builds, which is exactly what D8 exists to prevent.
//
//   * **`Bounds?` instead of the `EMPTY_BOUNDS` sentinel.** Java signals "cache invalid" with
//     `bounds != Bounds.EMPTY_BOUNDS`, a *reference* comparison. The port's `Bounds` is a struct
//     whose `==` deliberately ignores the empty sentinel (matching Java's `.equals`), so the
//     reference test has no Swift equivalent, and `Optional` says the same thing without one.
//     No behaviour rides on the difference: `recomputeBounds` adds 1 to both dimensions, so it
//     can never produce a zero-sized box that would be confused with "invalid".

import Foundation
import LogisimKernel

/// The storage half of `CircuitWires`: which wires exist, their bounding box, and the bus-width
/// label position of each.
final class CircuitWireStore {

  /// `CircuitWires.wires`: dedup by `Wire.equals`, i.e. by endpoints.
  private var wireSet: Set<Wire> = []

  /// Insertion order; see the file header.
  private var wireOrder: [Wire] = []

  /// `CircuitWires.bounds`. `nil` is Java's `EMPTY_BOUNDS`-as-"invalid".
  private var boundsCache: Bounds?

  /// `CircuitWires.wireBusWidthPos`.
  private var busWidthPositions: [Wire: AttributeOption] = [:]

  init() {}

  /// `getWires()`, in insertion order.
  var wires: [Wire] { wireOrder }

  var wireCount: Int { wireOrder.count }

  func contains(_ wire: Wire) -> Bool { wireSet.contains(wire) }

  /// `CircuitWires.addWire(Wire)`; false when an equal wire is already present.
  @discardableResult
  func add(_ wire: Wire) -> Bool {
    guard wireSet.insert(wire).inserted else { return false }
    wireOrder.append(wire)
    if let cached = boundsCache {
      boundsCache = cached.add(wire.end0).add(wire.end1)
    }
    return true
  }

  /// `CircuitWires.removeWire(Wire)`.
  ///
  /// The cache is invalidated only when an endpoint sat on the border: upstream shrinks the box
  /// by 2 and checks containment, so removing a wire from the interior leaves a box that is
  /// merely too large rather than wrong. Preserved: recomputing eagerly would change
  /// `Circuit.getBounds()` for a sequence of removals.
  @discardableResult
  func remove(_ wire: Wire) -> Bool {
    guard wireSet.remove(wire) != nil else { return false }
    if let index = wireOrder.firstIndex(where: { $0 == wire }) {
      wireOrder.remove(at: index)
    }
    if let cached = boundsCache {
      let smaller = cached.expand(-2)
      if !smaller.contains(wire.end0) || !smaller.contains(wire.end1) {
        boundsCache = nil
      }
    }
    // Upstream leaves the bus-width entry behind, keyed on a wire that is no longer in the
    // circuit. Because `Wire` hashes structurally, re-adding an identical segment resurrects the
    // old position. Preserved: it is observable: delete a wire and redraw it, and its bus-width
    // label comes back.
    return true
  }

  /// `getWireBounds()`. Recomputes on demand; returns `Bounds.empty` when there are no wires,
  /// and, as upstream does, leaves the cache invalid in that case, so the empty scan repeats.
  var wireBounds: Bounds {
    if let cached = boundsCache { return cached }
    return recomputeBounds()
  }

  /// `CircuitWires.recomputeBounds()`.
  ///
  /// Note the `+ 1` on both dimensions: a single-point wire set still has a 1×1 box. And note the
  /// asymmetric initialisation, mins from the first wire's `e0`, maxes from its `e1`, which is
  /// only sound because `Wire` normalises `e0 <= e1` along its axis and the two endpoints agree
  /// on the other axis.
  @discardableResult
  private func recomputeBounds() -> Bounds {
    guard let first = wireOrder.first else {
      boundsCache = nil
      return Bounds.empty
    }
    var xMin = first.end0.x
    var yMin = first.end0.y
    var xMax = first.end1.x
    var yMax = first.end1.y
    for wire in wireOrder.dropFirst() {
      let x0 = wire.end0.x
      if x0 < xMin { xMin = x0 }
      let x1 = wire.end1.x
      if x1 > xMax { xMax = x1 }
      let y0 = wire.end0.y
      if y0 < yMin { yMin = y0 }
      let y1 = wire.end1.y
      if y1 > yMax { yMax = y1 }
    }
    let computed = Bounds.create(
      xMin, yMin, wrap32(wrap32(xMax &- xMin) &+ 1), wrap32(wrap32(yMax &- yMin) &+ 1))
    boundsCache = computed
    return computed
  }

  /// `getWireBusWidthPos(Wire)`: `BUS_WIDTH_POS_NONE` when unset.
  func busWidthPosition(of wire: Wire) -> AttributeOption {
    busWidthPositions[wire] ?? Wire.busWidthPositionNone
  }

  /// `setWireBusWidthPos(Wire, AttributeOption)`.
  ///
  /// Upstream compares `pos == Wire.BUS_WIDTH_POS_NONE` by reference, relying on
  /// `OptionAttribute.parse` returning one of the interned choices. `AttributeOption` is a value
  /// type here, so this is a value comparison: the same test, since the four choices are
  /// distinguished by name and no two share one. `WireFactory` documents the same substitution.
  func setBusWidthPosition(_ position: AttributeOption?, of wire: Wire) {
    if position == nil || position == Wire.busWidthPositionNone {
      busWidthPositions.removeValue(forKey: wire)
    } else {
      busWidthPositions[wire] = position
    }
  }

  /// `Circuit.mutatorClear` replaces the whole `CircuitWires`, which is what this mirrors.
  func removeAll() {
    wireSet.removeAll()
    wireOrder.removeAll()
    busWidthPositions.removeAll()
    boundsCache = nil
  }
}
