//
//  WireBundle.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (com.cburch.logisim.circuit.WireBundle),
//  https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
//  developers. This translation is a derivative work and is therefore GPL-3.0-only.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16), read from `upstream-java-4.1.0/.../circuit/WireBundle.java`,
//  NOT from main.
//
//  ---------------------------------------------------------------------------------------
//  A `WireBundle` is a bus or wire as the user drew it: an unbroken ribbon that acts as a
//  bundle of one or more 1-bit `WireThread`s. It has a width (or, if the width is inconsistent
//  along its length, a `WidthIncompatibilityData` instead), a set of touched `Location`s, and a
//  pull value. A bundle traverses tunnels but **not** splitters; threads do the opposite.
//
//  The class is the second union-find in this slice: `unite` joins two bundles that share a
//  point (a wire endpoint, a tunnel pair), `find` returns the group representative.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// `com.cburch.logisim.circuit.WireBundle`.
///
/// Public only because `CircuitWires.SplitterData` crosses the splitter seam and mentions this
/// type. Members upstream keeps package-private stay `internal`.
public final class WireBundle {

  /// `WireBundle.width`.
  private var widthValue: BitWidth = .unknown

  /// `WireBundle.pullValue`. Note it starts at `UNKNOWN`, never `nil`.
  private var pullValueStorage: Value = .unknownValue

  /// `WireBundle.parent`: the union-find parent.
  ///
  /// **D3: `weak`, with a `self` fallback.** `WireBundle(p)` sets `parent = this`, which under
  /// ARC is an unconditional strong self-cycle: every bundle of every circuit would leak, and a
  /// leak here is per-wire-segment, so it is one of the highest-multiplicity cycles in the app.
  ///
  /// Java's merge loop (`CircuitWires.java:587-598`) also removes non-representative bundles from
  /// the live set *while other, not-yet-visited bundles still point at them through `parent`*;
  /// the GC keeps those alive, ARC would not. `CircuitWires.computeConnectivity` therefore holds
  /// a strong snapshot across that whole loop, so within a generation the `?? self` fallback
  /// provably never fires. It exists for the cross-generation case, where a stale bundle pinned
  /// by `SplitterData.endBundle` can outlive its own group; there Java sees a stale-but-live
  /// object and `unowned` would trap, which D13 forbids in spirit.
  ///
  /// This is not the hot path: union-find runs once per circuit edit, never per propagation step.
  private weak var parentRef: WireBundle?

  private var parent: WireBundle { parentRef ?? self }

  /// `WireBundle.widthDeterminant`; the point that first fixed this bundle's width. Reported as
  /// the *first* entry of a `WidthIncompatibilityData`, so its identity is user-visible.
  private var widthDeterminant: Location?

  /// `WireBundle.isBus_`.
  private var isBusFlag = false

  /// `WireBundle.threads`; set when the connectivity map finishes constructing.
  var threads: [WireThread]?

  /// `WireBundle.xpoints`; set when the connectivity map finishes constructing.
  var xpoints: [Location]?

  /// `WireBundle.incompatibilityData`.
  private var incompatibilityData: CircuitWires.WidthIncompatibilityData?

  // MARK: tempPoints

  /// `WireBundle.tempPoints`, as an insertion-ordered set.
  ///
  /// Java uses `HashSet<Location>`; the iteration order of that set becomes `xpoints`, which in
  /// turn becomes `ValuedBus.locations` and therefore the order of `setValueByWire` calls during
  /// propagation. Java's order is JVM hash order and is not reproducible in Swift by any means
  /// short of reimplementing `HashMap`, so the port uses insertion order: deterministic, which
  /// is strictly better for the differential harness than a second unreproducible ordering.
  /// `nil` is Java's post-construction `null`.
  private var tempPointOrder: [Location]? = []
  private var tempPointSet: Set<Location> = []

  /// Whether `tempPoints` is still live (Java: `tempPoints != null`).
  var hasTempPoints: Bool { tempPointOrder != nil }

  /// The contents of `tempPoints`, in insertion order.
  var tempPoints: [Location] { tempPointOrder ?? [] }

  /// `tempPoints.add(p)`.
  func addTempPoint(_ point: Location) {
    guard tempPointOrder != nil else { return }
    if tempPointSet.insert(point).inserted {
      tempPointOrder?.append(point)
    }
  }

  /// `tempPoints.addAll(other)`.
  func addTempPoints(_ points: [Location]) {
    for point in points { addTempPoint(point) }
  }

  /// `tempPoints = null` after `xpoints` has been built.
  func clearTempPoints() {
    tempPointOrder = nil
    tempPointSet.removeAll()
  }

  // MARK: Construction

  /// `WireBundle(Location p)` (`WireBundle.java:30-33`).
  init(_ point: Location) {
    parentRef = self
    addTempPoint(point)
  }

  // MARK: Union-find

  /// `WireBundle find()` (`WireBundle.java:39-47`): find with path compression, verbatim.
  func find() -> WireBundle {
    var ret = self
    if ret.parent !== ret {
      repeat {
        ret = ret.parent
      } while ret.parent !== ret
      self.parentRef = ret
    }
    return ret
  }

  /// `void isolate()` (`WireBundle.java:69-71`). Unused in 4.1.0's `circuit` package but part of
  /// the class, so it comes across.
  func isolate() {
    parentRef = self
  }

  /// `void unite(WireBundle other)` (`WireBundle.java:100-104`).
  ///
  /// **Merge direction is load-bearing and is preserved exactly**: `group.parent = group2`, i.e.
  /// the *receiver's* root is attached under the *argument's* root, so the argument's group wins
  /// and keeps its `widthDeterminant`. `connectWires` calls `bundleB.unite(bundleA)` and
  /// `connectTunnels` calls `bundle.unite(foundBundle)`; reversing either would change which
  /// bundle survives the merge loop, hence which `Location` is recorded first in a
  /// `WidthIncompatibilityData`, hence which width conflict the UI reports first.
  func unite(_ other: WireBundle) {
    let group = self.find()
    let group2 = other.find()
    if group !== group2 {
      group.parentRef = group2
    }
  }

  // MARK: Width and pull

  /// `void addPullValue(Value val)` (`WireBundle.java:35-37`).
  ///
  /// Note this is `Value.combine`, which is where `combine(TRUE, UNKNOWN) == ERROR` shows up in
  /// the wiring layer. That is upstream semantics and is not to be "fixed".
  func addPullValue(_ value: Value) {
    pullValueStorage = pullValueStorage.combine(value)
  }

  /// `Value getPullValue()` (`WireBundle.java:49-51`).
  func getPullValue() -> Value { pullValueStorage }

  /// `BitWidth getWidth()` (`WireBundle.java:53-59`); a broken bundle reports `UNKNOWN`, not the
  /// width it was first told about.
  func getWidth() -> BitWidth {
    incompatibilityData != nil ? .unknown : widthValue
  }

  /// `WidthIncompatibilityData getWidthIncompatibilityData()` (`WireBundle.java:61-63`).
  func getWidthIncompatibilityData() -> CircuitWires.WidthIncompatibilityData? {
    incompatibilityData
  }

  /// `boolean isBus()` (`WireBundle.java:65-67`).
  ///
  /// **JAVA QUIRK, preserved.** `isBus_` is assigned only in `setWidth`'s *"width already set and
  /// the new width agrees"* branch (`WireBundle.java:85`). A bundle whose width is set exactly
  /// once, the common case for a bus reached from a single component port, therefore reports
  /// `isBus() == false` even at width 8. This reaches drawing only (line thickness and dot
  /// radius), never simulation, which is why it has survived upstream. Do not "fix" it: it is
  /// observable in the M6 image diff.
  func isBus() -> Bool { isBusFlag }

  /// `boolean isValid()` (`WireBundle.java:73-75`).
  func isValid() -> Bool { incompatibilityData == nil }

  /// `void setWidth(BitWidth width, Location det)` (`WireBundle.java:77-98`).
  ///
  /// Reproduced statement for statement, including the ordering of the two `add` calls that build
  /// a fresh `WidthIncompatibilityData`: the *existing* determinant and width go in first, the
  /// newly-offered pair second. `WidthIncompatibilityData.getCommonBitWidth` breaks ties by
  /// "first to reach the winning count", so this order decides which width the UI offers to
  /// propagate when the user asks it to repair the conflict.
  func setWidth(_ width: BitWidth, _ det: Location) {
    // Java compares against the `BitWidth.UNKNOWN` singleton by reference; the port's `BitWidth`
    // is a struct whose `==` is by value, and `UNKNOWN` is the only width-0 instance, so the two
    // tests coincide.
    if width == .unknown { return }
    if let existing = incompatibilityData {
      existing.add(det, width)
      return
    }
    if widthValue != .unknown {
      if width == widthValue {
        isBusFlag = width.width > 1
        // nothing to do
      } else {
        // the widths are broken: create incompatibilityData holding this info
        let data = CircuitWires.WidthIncompatibilityData()
        if let determinant = widthDeterminant {
          data.add(determinant, widthValue)
        }
        data.add(det, width)
        incompatibilityData = data
      }
      // the widths match, and the bundle is already set
      return
    }
    widthValue = width
    widthDeterminant = det
  }
}
