//
//  WireThread.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (com.cburch.logisim.circuit.WireThread),
//  https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
//  developers. This translation is a derivative work and is therefore GPL-3.0-only.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16), read from `upstream-java-4.1.0/.../circuit/WireThread.java`,
//  NOT from main.
//
//  ---------------------------------------------------------------------------------------
//  A `WireThread` is one 1-bit electrically-contiguous trace. It traverses one or more
//  `WireBundle`s, threads pass *through* splitters, bundles do not, and holds its own position
//  within each bundle it visits. The class is a union-find node: `unite` links two traces that a
//  splitter joins, and `getRepresentative` finds the group leader with path compression.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// `com.cburch.logisim.circuit.WireThread`.
///
/// Public only because `CircuitWires.State` is public (it crosses the `CircuitState` seam) and
/// mentions this type. Every member that upstream keeps package-private stays `internal`.
public final class WireThread {

  /// `WireThread.BundlePosition` (`WireThread.java:21-28`).
  ///
  /// **D3, `bundle` is `weak`.** `WireBundle.threads` owns its `WireThread`s strongly, so a
  /// strong edge back would be a two-object retain cycle on *every thread of every bundle*,
  /// the highest-multiplicity cycle in this slice. Java's GC collects it; ARC does not.
  ///
  /// Weak rather than `unowned` deliberately. Upstream leaves *stale* bundles reachable through
  /// `CircuitWires.SplitterData.endBundle` when a splitter end loses its bundle (the
  /// `if (pb != null)` guard at `CircuitWires.java:628` never clears the old entry), so a thread
  /// from a previous connectivity generation can outlive the bundles it recorded. Under Java that
  /// is a harmless stale pointer; an `unowned` reference would trap, turning a stale-connectivity
  /// edge case into a process kill, which D13 forbids in spirit. The cost is nil on the hot path:
  /// nothing here runs during propagation; the simulator's per-step work goes through
  /// `CircuitWires.ValuedThread`, which holds plain `unowned` bus references.
  struct BundlePosition {
    let pos: Int
    weak var bundle: WireBundle?
  }

  /// `WireThread.representative`: the union-find parent.
  ///
  /// **D3: `weak`, with a `self` fallback.** A union-find node whose parent is initialised to
  /// `self` is an unconditional strong self-cycle under ARC: every `WireThread` ever created
  /// would leak. `weak` also protects the cross-generation case described on `BundlePosition`,
  /// where a stale thread's chain can reach a thread that has since been released.
  ///
  /// Reading a dangling link yields `self`, i.e. "I am my own representative", which is the
  /// same answer Java gives for a thread that was never united. `computeConnectivity` holds a
  /// strong snapshot of every thread it creates for the whole of its run, so within one
  /// connectivity generation the fallback provably never fires and the behaviour is identical to
  /// upstream's.
  private weak var representativeRef: WireThread?

  private var representative: WireThread { representativeRef ?? self }

  /// `WireThread.tempBundlePositions`.
  ///
  /// An **array**, not a set, although Java uses `HashSet<BundlePosition>`: `BundlePosition`
  /// overrides neither `equals` nor `hashCode`, so Java's set has identity semantics and every
  /// `add` is a distinct element. An array reproduces that exactly, makes `steps` come out the
  /// same, and, unlike a `HashSet`, iterates deterministically. `nil` is Java's post-
  /// construction `null`.
  private var tempBundlePositions: [BundlePosition]? = []

  /// `WireThread.steps`; the number of bundles this thread traverses. Set by
  /// `finishConstructing()`.
  public private(set) var steps: Int = 0

  /// `WireThread.bundle`: the bundles traversed, parallel to `position`.
  private var bundlePositions: [BundlePosition] = []

  /// `WireThread.position`: this thread's bit index within each traversed bundle.
  public private(set) var position: [Int] = []

  /// `WireThread()` (`WireThread.java:30-32`).
  init() {
    representativeRef = self
  }

  /// `void addBundlePosition(int pos, WireBundle b)` (`WireThread.java:34-36`).
  ///
  /// Throws where Java raises `NullPointerException`: after `finishConstructing()` the temp list
  /// is `null`, and `CircuitWires.computeConnectivity` genuinely reaches that state when a
  /// splitter's stale `endBundle` entry causes a fresh bundle's thread to be united *into* a
  /// thread from a previous generation. Java's `getConnectivity()` catches the NPE and marks the
  /// map invalid; this throw lands in the same handler (D13).
  func addBundlePosition(_ pos: Int, _ bundle: WireBundle) throws {
    guard tempBundlePositions != nil else {
      throw CircuitWiresError.threadAlreadyConstructed
    }
    tempBundlePositions?.append(BundlePosition(pos: pos, bundle: bundle))
  }

  /// `void finishConstructing()` (`WireThread.java:38-50`). Idempotent, as upstream's is.
  func finishConstructing() {
    guard let temp = tempBundlePositions else { return }
    steps = temp.count
    bundlePositions = temp
    position = temp.map(\.pos)
    tempBundlePositions = nil
  }

  /// The bundle at traversal index `i`; Java's `bundle[i]`.
  ///
  /// Returns `nil` only if the bundle has been released (see `BundlePosition`); Java would hand
  /// back a stale-but-live object. Callers convert `nil` into a thrown
  /// `CircuitWiresError.staleConnectivity` rather than trapping.
  func bundle(at index: Int) -> WireBundle? {
    guard index >= 0 && index < bundlePositions.count else { return nil }
    return bundlePositions[index].bundle
  }

  /// `WireThread getRepresentative()` (`WireThread.java:52-61`): find with path compression,
  /// reproduced move for move including the "compress only when not already the root" guard.
  func getRepresentative() -> WireThread {
    var ret = self
    if ret.representative !== ret {
      repeat {
        ret = ret.representative
      } while ret.representative !== ret
      self.representativeRef = ret
    }
    return ret
  }

  /// `void unite(WireThread other)` (`WireThread.java:63-69`).
  ///
  /// Direction matters and is preserved verbatim: `us.representative = them`, i.e. the *receiver's*
  /// group is attached under the *argument's* group. Reversing it would change which thread
  /// survives as a group leader and therefore the order in which bundle positions are recorded.
  func unite(_ other: WireThread) {
    let us = self.getRepresentative()
    let them = other.getRepresentative()
    if us !== them {
      us.representativeRef = them
    }
  }
}
