//
//  BundleMap.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitWires.Connectivity),
//  https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
//  developers. This translation is a derivative work and is therefore GPL-3.0-only.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16).
//
//  ---------------------------------------------------------------------------------------
//  ## There is no `BundleMap.java` in 4.1.0
//
//  `com.cburch.logisim.circuit.BundleMap` existed in Logisim 2.x / early logisim-evolution and
//  is **gone at the port target**: `ls upstream-java-4.1.0/.../circuit/` lists no `BundleMap.java`.
//  Its successor is the private static inner class `CircuitWires.Connectivity`
//  (`CircuitWires.java:71-144`), which is what this file holds. The filename is kept because the
//  slice's file list named it; the *type* is `CircuitWires.Connectivity`, matching 4.1.0.
//
//  The rename was not cosmetic. `BundleMap` used to be both the static map *and* the mutable
//  simulation state; 4.1.0 splits those, so `Connectivity` holds **no `Value`s at all**, only
//  the static netlist, and every dynamic value lives in `CircuitWires.State`, one per
//  `CircuitState`. That split is what lets one connectivity map back many simulated instances of
//  the same circuit.
//  ---------------------------------------------------------------------------------------
//

import Foundation

extension CircuitWires {

  /// `CircuitWires.Connectivity` (`CircuitWires.java:71-144`).
  ///
  /// Recomputed from scratch every time the circuit changes. Essentially read-only once
  /// construction finishes, which is what lets the simulation thread share one instance across
  /// every `CircuitState` of the circuit.
  final class Connectivity {

    // MARK: bundles

    /// `Connectivity.bundles`: Java's `HashSet<WireBundle>`.
    ///
    /// `WireBundle` overrides neither `equals` nor `hashCode`, so the Java set has *identity*
    /// semantics; this is an insertion-ordered array plus an identity index, which reproduces
    /// that and additionally makes iteration deterministic. Java's iteration order is JVM hash
    /// order and is not reproducible; insertion order is the closest deterministic stand-in and
    /// is what the differential harness will see.
    ///
    /// **D3; strong.** This is the owning edge for every `WireBundle`; `WireBundle.parent` and
    /// `WireThread.bundle` are the weak back-edges that keep it acyclic.
    private var bundleOrder: [WireBundle] = []
    private var bundleIdentities: Set<ObjectIdentifier> = []

    // MARK: pointBundles

    /// `Connectivity.pointBundles`: "given a location, the wire bundle at that location".
    private var pointBundles: [Location: WireBundle] = [:]

    /// Insertion order of `pointBundles`' keys. Java iterates `pointBundles.keySet()` when it
    /// assigns component-derived widths (`CircuitWires.java:612-618`), and *that* order decides
    /// which `Location` becomes a bundle's `widthDeterminant`; i.e. which point is named first
    /// in a width-conflict report. Deterministic order matters more here than anywhere else in
    /// the slice.
    private var pointOrder: [Location] = []

    /// `Connectivity.allLocations`: every location touched by anything in the circuit.
    var allLocations: [Location] = []

    /// `Connectivity.allComponents`: all components except wires, splitters and pull resistors.
    ///
    /// **D3: strong**, matching Java. `Circuit` owns components; nothing in a component points
    /// back at this map, so no cycle closes here. The map is discarded wholesale by
    /// `voidConnectivity()`, which is the eviction owner D3 asks for.
    var allComponents: [any WireComponent] = []

    /// `Connectivity.componentsAtLocations`: given a location, the non-wire, non-splitter
    /// components with a port there.
    var componentsAtLocations: [Location: [any WireComponent]] = [:]

    // MARK: validity

    /// `Connectivity.isValid`: `volatile boolean` in Java, guarded by a lock here.
    ///
    /// Java's `volatile` buys atomicity plus a happens-before edge between the AWT thread that
    /// writes it and the simulation thread that reads it. Swift has no `volatile`; an `NSLock`
    /// gives both properties. D1 forbids reaching for an actor to solve this.
    private let validityLock = NSLock()
    private var validFlag = true

    /// `Connectivity.incompatibilityData`: `null` until the first conflict, as upstream.
    ///
    /// Java's is a `HashSet<WidthIncompatibilityData>` deduplicated by that class's own
    /// (deliberately odd) `equals`; this is an insertion-ordered array applying the same
    /// equality, so the *contents* match and the order is deterministic.
    private var incompatibilityData: [WidthIncompatibilityData]?

    init() {}

    /// `void addWidthIncompatibilityData(WidthIncompatibilityData e)` (`CircuitWires.java:100`).
    func addWidthIncompatibilityData(_ data: WidthIncompatibilityData) {
      if incompatibilityData == nil {
        incompatibilityData = []
      }
      // HashSet.add semantics: no-op if an equal element is already present.
      if incompatibilityData!.contains(where: { $0 == data }) { return }
      incompatibilityData!.append(data)
    }

    /// `WireBundle createBundleAt(Location p)` (`CircuitWires.java:107-115`).
    func createBundleAt(_ point: Location) -> WireBundle {
      if let existing = pointBundles[point] { return existing }
      let created = WireBundle(point)
      setBundleAt(point, created)
      insertBundle(created)
      return created
    }

    /// `void setBundleAt(Location p, WireBundle b)` (`CircuitWires.java:117-119`).
    func setBundleAt(_ point: Location, _ bundle: WireBundle) {
      if pointBundles.updateValue(bundle, forKey: point) == nil {
        pointOrder.append(point)
      }
    }

    /// `WireBundle getBundleAt(Location p)` (`CircuitWires.java:121-123`).
    func getBundleAt(_ point: Location) -> WireBundle? {
      pointBundles[point]
    }

    /// `Set<Location> getBundlePoints()` (`CircuitWires.java:125-127`), in insertion order.
    func getBundlePoints() -> [Location] {
      pointOrder
    }

    /// `Set<WireBundle> getBundles()` (`CircuitWires.java:129-131`), in insertion order.
    ///
    /// Returns a **strong snapshot**. That is not incidental: `computeConnectivity`'s merge loop
    /// removes non-representative bundles from this collection while other, not-yet-visited
    /// bundles still reference them through their (weak) `parent`. Java's GC keeps those alive
    /// for the duration; the snapshot is what does the same job under ARC.
    func getBundles() -> [WireBundle] {
      bundleOrder
    }

    /// `bundles.add(b)`.
    func insertBundle(_ bundle: WireBundle) {
      if bundleIdentities.insert(ObjectIdentifier(bundle)).inserted {
        bundleOrder.append(bundle)
      }
    }

    /// The `it.remove()` of the merge loop (`CircuitWires.java:596`).
    func removeBundle(_ bundle: WireBundle) {
      guard bundleIdentities.remove(ObjectIdentifier(bundle)) != nil else { return }
      if let index = bundleOrder.firstIndex(where: { $0 === bundle }) {
        bundleOrder.remove(at: index)
      }
    }

    var bundleCount: Int { bundleOrder.count }

    /// `HashSet<WidthIncompatibilityData> getWidthIncompatibilityData()`
    /// (`CircuitWires.java:133-135`). `nil` when there are none, as upstream.
    func getWidthIncompatibilityData() -> [WidthIncompatibilityData]? {
      incompatibilityData
    }

    /// `void invalidate()` (`CircuitWires.java:137-139`).
    func invalidate() {
      validityLock.lock()
      validFlag = false
      validityLock.unlock()
    }

    /// `boolean isValid()` (`CircuitWires.java:141-143`).
    func isValid() -> Bool {
      validityLock.lock()
      defer { validityLock.unlock() }
      return validFlag
    }
  }
}
