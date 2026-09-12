// CircuitEvent.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.{CircuitEvent, CircuitListener}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `getResult()` casts the payload to a `CircuitTransactionResult`. The transaction system
//     (`CircuitTransaction`, `CircuitMutator`, `CircuitLocker`) is M3, so `TRANSACTION_DONE` is
//     declared, dropping an action would renumber nothing but would hide a case from every
//     exhaustive switch, while its payload has no case yet.
//   * `toString()`'s `LineBuffer.format` rendering. `CustomStringConvertible` gives the same
//     information without the formatting helper.

import Foundation

/// `CircuitEvent`'s `int` action constants, as a real enum.
///
/// The raw values are upstream's, so a log or a differential test can compare them directly.
/// Note `3` is absent: upstream's `ACTION_CHANGE` is commented out and the gap is preserved
/// rather than closed, because closing it would silently renumber four live constants.
public enum CircuitEventAction: Int, Sendable {
  /// `ACTION_SET_NAME`; the circuit's name changed.
  case setName = 0
  /// `ACTION_ADD`; a component was added.
  case add = 1
  /// `ACTION_REMOVE`; a component was removed.
  case remove = 2
  /// `ACTION_INVALIDATE`; a component was invalidated (its pin types changed).
  case invalidate = 4
  /// `ACTION_CLEAR`; the whole circuit was cleared.
  case clear = 5
  /// `TRANSACTION_DONE`: M3; declared so switches stay exhaustive across milestones.
  case transactionDone = 6
  /// `CHANGE_DEFAULT_BOX_APPEARANCE`.
  case changeDefaultBoxAppearance = 7
  /// `ACTION_CHECK_NAME`.
  case checkName = 8
  /// `ACTION_DISPLAY_CHANGE`, viewed/haloed status change.
  case displayChange = 9
}

/// The payload of a `CircuitEvent`.
///
/// Java's is a bare `Object` that is variously a `Component`, a `Collection<Component>`, a
/// `String` or a `CircuitTransactionResult`. Modelling it as a closed enum, the same choice
/// `LibraryEventData` makes, forces every consumer to handle every shape it can actually be,
/// which is the thing an `Object` payload silently fails to do.
public enum CircuitEventData {
  case none
  /// `ACTION_ADD`, `ACTION_REMOVE`, `ACTION_INVALIDATE`.
  case component(any Component)
  /// `ACTION_CLEAR` carries the whole set of components that were dropped.
  case components([any Component])
  /// `ACTION_SET_NAME` and `ACTION_CHECK_NAME` carry a name.
  case name(String)
}

/// `com.cburch.logisim.circuit.CircuitEvent`.
public struct CircuitEvent {
  /// D3: an event must not keep its circuit alive. Listeners run synchronously inside the
  /// circuit's own method, so the circuit is always live for the duration of the call; the
  /// same reasoning `LibraryEvent.source` is written on.
  public unowned let circuit: Circuit
  public let action: CircuitEventAction
  public let data: CircuitEventData

  public init(action: CircuitEventAction, circuit: Circuit, data: CircuitEventData) {
    self.action = action
    self.circuit = circuit
    self.data = data
  }
}

extension CircuitEvent: CustomStringConvertible {
  public var description: String {
    "\(action) { circuit=\(circuit.name) data=\(data) }"
  }
}

/// `com.cburch.logisim.circuit.CircuitListener`.
public protocol CircuitListener: AnyObject {
  func circuitChanged(_ event: CircuitEvent)
}

/// A listener built from a closure, for callers that do not want to declare a type.
///
/// D3: the circuit's listener list holds this weakly (`WeakListenerList`), so the caller must
/// keep the returned object alive for the subscription to stay live.
public final class CircuitListenerClosure: CircuitListener {
  private let handler: (CircuitEvent) -> Void

  public init(_ handler: @escaping (CircuitEvent) -> Void) {
    self.handler = handler
  }

  public func circuitChanged(_ event: CircuitEvent) { handler(event) }
}
