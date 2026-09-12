// MoveRequest.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.{MoveRequest, MoveResult,
// MoveRequestListener}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.move.MoveRequest`; "reroute this gesture's wires for this delta".
///
/// Equality is `gesture` **by identity** plus the delta (`MoveRequest.java:24-30`), which is what
/// makes the gesture's result cache work: the same drag position asked for twice is one request,
/// and two different gestures at the same delta are not.
struct MoveRequest: Hashable, @unchecked Sendable {
  let gesture: MoveGesture
  let dx: Int
  let dy: Int

  init(_ gesture: MoveGesture, _ dx: Int, _ dy: Int) {
    self.gesture = gesture
    self.dx = dx
    self.dy = dy
  }

  static func == (lhs: MoveRequest, rhs: MoveRequest) -> Bool {
    lhs.gesture === rhs.gesture && lhs.dx == rhs.dx && lhs.dy == rhs.dy
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(gesture))
    hasher.combine(dx)
    hasher.combine(dy)
  }
}

/// `com.cburch.logisim.tools.move.MoveResult`; what the connector thread publishes.
///
/// `@unchecked Sendable` for the same reason `ReplacementMap` is: it is built on the connector
/// thread and read on the main one, with the handoff serialised by the gesture's lock.
public final class MoveResult: @unchecked Sendable {

  /// `getReplacementMap()`: the wires to add, remove and shorten.
  public let replacements: ReplacementMap

  /// `getUnsatisifiedConnections()` (upstream's spelling, typo and all). Mutable because
  /// `addUnsatisfiedConnections` folds in the connections that were pruned as impossible *after*
  /// the search ran.
  public private(set) var unsatisfiedConnections: [ConnectionData]

  /// `getUnconnectedLocations()`: the same list projected to points, which is what the canvas
  /// draws red dots at.
  public private(set) var unconnectedLocations: [Location]

  /// `getTotalDistance()`: the tie-breaker between two candidate orderings.
  let totalDistance: Int

  init(
    replacements: ReplacementMap, unsatisfiedConnections: [ConnectionData], totalDistance: Int
  ) {
    self.replacements = replacements
    self.unsatisfiedConnections = unsatisfiedConnections
    self.totalDistance = totalDistance
    self.unconnectedLocations = unsatisfiedConnections.map(\.location)
  }

  /// `addUnsatisfiedConnections(Collection<ConnectionData>)`.
  func addUnsatisfiedConnections(_ toAdd: [ConnectionData]) {
    unsatisfiedConnections.append(contentsOf: toAdd)
    unconnectedLocations.append(contentsOf: toAdd.map(\.location))
  }

  /// `getWiresToAdd()`.
  ///
  /// Upstream casts `replacements.getAdditions()` to `Collection<Wire>` unchecked, which is safe
  /// only because the move engine adds nothing but wires. The port filters instead of casting:
  /// same answer for every input the engine can produce, and no trap if that ever stops being
  /// true.
  public var wiresToAdd: [Wire] {
    replacements.additions.compactMap { $0 as? Wire }
  }
}

extension MoveResult: CustomStringConvertible {
  public var description: String { "MoveResult: \(replacements)" }
}

/// `com.cburch.logisim.tools.move.MoveRequestListener`.
///
/// **Deviation, and it removes a race rather than adding one.** Upstream calls
/// `requestSatisfied` from `MoveGesture.notifyResult`, i.e. **on the connector thread**
/// (`MoveGesture.java:182-184`), and `SelectTool.MoveRequestHandler` then reaches straight into
/// Swing: `canvas.getErrorMessage()`, `canvas.setErrorMessage(null)`, `canvas.repaint()`
/// (`SelectTool.java:126-140`). That is a plain EDT violation in upstream. Here the callback is a
/// `@Sendable` closure and `SelectTool` hops to the main actor inside it, so the notification
/// arrives at the same point in the sequence, on the thread that is allowed to act on it.
public typealias MoveRequestListener = @Sendable (_ gesture: MoveGesture, _ dx: Int, _ dy: Int) ->
  Void
