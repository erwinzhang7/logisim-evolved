// IoBubbleInformation: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the `getLocalBubble*Id()` accessors of
// `com/cburch/logisim/fpga/designrulecheck/netlistComponent.java:156-178`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this protocol exists ────────────────────────────────────────────────────────────────
//
// Every std/io generator is fundamentally a mapping between a component's pins and its slice of
// the top level's `logisimInputBubbles` / `logisimOutputBubbles` / `logisimInOutBubbles` vectors,
// so `getLocalBubbleInputStartId()` and friends are load-bearing inputs to all of them. The port
// already has them, on the concrete `Netlist/NetlistComponent.swift`: but **not** on the
// `HdlNetlistComponent` protocol in `HdlNetlist.swift`, which is what a generator is handed.
//
// `HdlNetlist.swift` is not this task's to edit, so the accessors are surfaced here as a
// refinement protocol that `NetlistComponent` already satisfies member-for-member, and the
// generators go through the `localBubble…` helpers below. If the six accessors are later moved
// onto `HdlNetlistComponent` itself (the tidier end state: see this task's report), this file
// collapses to nothing and no generator changes.
//
// The `?? 0` fallbacks are not defensive padding: Java answers `0` from all six when `localId`
// is null (`netlistComponent.java:156-178`), which is exactly the state of a component that was
// never assigned a bubble range.

import LogisimKernel

/// The local-bubble index ranges a placed component occupies, as `netlistComponent` exposes them.
public protocol HdlLocalBubbleInformation {
  /// `netlistComponent.getLocalBubbleInputStartId()`.
  var localBubbleInputStartId: Int { get }
  /// `netlistComponent.getLocalBubbleInputEndId()`.
  var localBubbleInputEndId: Int { get }
  /// `netlistComponent.getLocalBubbleOutputStartId()`.
  var localBubbleOutputStartId: Int { get }
  /// `netlistComponent.getLocalBubbleOutputEndId()`.
  var localBubbleOutputEndId: Int { get }
  /// `netlistComponent.getLocalBubbleInOutStartId()`.
  var localBubbleInOutStartId: Int { get }
  /// `netlistComponent.getLocalBubbleInOutEndId()`.
  var localBubbleInOutEndId: Int { get }
}

/// `NetlistComponent` already declares all six with these exact names and semantics.
extension NetlistComponent: HdlLocalBubbleInformation {}

extension HdlNetlistComponent {
  private var bubbles: (any HdlLocalBubbleInformation)? { self as? any HdlLocalBubbleInformation }

  public var localBubbleInputStart: Int { bubbles?.localBubbleInputStartId ?? 0 }
  public var localBubbleInputEnd: Int { bubbles?.localBubbleInputEndId ?? 0 }
  public var localBubbleOutputStart: Int { bubbles?.localBubbleOutputStartId ?? 0 }
  public var localBubbleOutputEnd: Int { bubbles?.localBubbleOutputEndId ?? 0 }
  public var localBubbleInOutStart: Int { bubbles?.localBubbleInOutStartId ?? 0 }
  public var localBubbleInOutEnd: Int { bubbles?.localBubbleInOutEndId ?? 0 }
}
