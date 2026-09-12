// ProjectEvent.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.{ProjectEvent, ProjectListener}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// Java's `ProjectEvent` is a record carrying two bare `Object` payloads whose meaning depends on
// the action code; `getData()` is a `Tool` for `ACTION_SET_TOOL`, an `Action` for the six undo
// codes, a `LogisimFile` for `ACTION_SET_FILE`, a `Circuit` *or* an `HdlModel` for
// `ACTION_SET_CURRENT`, and a `Selection` for `ACTION_SELECTION`. Every consumer casts.
//
// This follows the same choice `CircuitEvent`/`LibraryEvent` already made in `LogisimFile`: a
// closed payload enum, so a switch over it is exhaustive at compile time and a listener cannot
// silently miss a shape. The action codes keep upstream's raw values so a trace lines up with
// Java's.

import Foundation
import LogisimFile

/// `ProjectEvent`'s `int` action constants.
public enum ProjectEventAction: Int, Sendable {
  /// `ACTION_SET_FILE`; the project's `LogisimFile` was replaced.
  case setFile = 0
  /// `ACTION_SET_CURRENT`; a different circuit (or HDL model) is being edited.
  case setCurrent = 1
  case setTool = 2
  case selection = 3
  /// `ACTION_SET_STATE`; the active simulation state changed.
  case setState = 4
  /// `ACTION_START`; an action is about to be applied.
  case actionStart = 5
  case actionComplete = 6
  /// `ACTION_MERGE`; one action was coalesced into another. `oldData` is the action that was
  /// on the stack, `data` the combined result (which may be absent if the append annihilated).
  case actionMerge = 7
  case undoStart = 8
  case undoComplete = 9
  /// `REPAINT_REQUEST`; something changed that affects only what is drawn.
  case repaintRequest = 10
  case redoStart = 11
  case redoComplete = 12
}

/// The payload of a `ProjectEvent`. See the file header for why this is an enum.
@MainActor
public enum ProjectEventData {
  case none
  case action(Action)
  case file(LogisimFile)
  case circuit(Circuit)
  case tool(Tool)
  /// `ACTION_SET_STATE`'s payload. Boxed behind the seam in `Project.swift` because the
  /// simulation state type is M3's.
  case circuitState((any ProjectCircuitState)?)
  /// `ACTION_SELECTION`'s payload; the canvas selection object. Untyped here because
  /// `Selection` belongs to the selection/tools slice; it is passed straight through.
  case selection(AnyObject)
}

/// `com.cburch.logisim.proj.ProjectEvent`.
@MainActor
public struct ProjectEvent {
  /// D3: **unowned**. Listeners run synchronously inside the project's own method, so the
  /// project is always live for the duration of the call; the same reasoning
  /// `CircuitEvent.circuit` and `LibraryEvent.source` are written on. A strong edge would put
  /// the project in a cycle with any listener that retains the event.
  public unowned let project: Project
  public let action: ProjectEventAction
  public let oldData: ProjectEventData
  public let data: ProjectEventData

  public init(
    action: ProjectEventAction,
    project: Project,
    oldData: ProjectEventData = .none,
    data: ProjectEventData = .none
  ) {
    self.action = action
    self.project = project
    self.oldData = oldData
    self.data = data
  }

  // Upstream's convenience accessors.
  public var logisimFile: LogisimFile? { project.logisimFile }
  public var circuit: Circuit? { project.currentCircuit }
  public var tool: Tool? { project.tool }
}

/// `com.cburch.logisim.proj.ProjectListener`.
@MainActor
public protocol ProjectListener: AnyObject {
  func projectChanged(_ event: ProjectEvent)
}

/// A listener built from a closure, matching `CircuitListenerClosure` in `LogisimFile`.
///
/// D3: the project's listener list holds this weakly, so the caller must keep the returned
/// object alive for the subscription to stay live. That is deliberate and is the whole reason
/// upstream's `EventSourceWeakSupport` exists; a window that closes should stop hearing about
/// the project it was showing, without anybody having to remember to unregister it.
@MainActor
public final class ProjectListenerClosure: ProjectListener {
  private let handler: (ProjectEvent) -> Void

  public init(_ handler: @escaping (ProjectEvent) -> Void) {
    self.handler = handler
  }

  public func projectChanged(_ event: ProjectEvent) { handler(event) }
}

/// `com.cburch.logisim.util.EventSourceWeakSupport`.
///
/// `LogisimFile` has an identical type but keeps it internal, so this is a local copy rather
/// than a cross-module dependency on somebody else's private helper. Compacts on every read,
/// which is the eviction owner D3 asks for.
/// Unconstrained in `Listener` on purpose, matching `LogisimFile`'s own `WeakListenerList`:
/// the listeners here are class-constrained *existentials* (`any ProjectListener`), and a Swift
/// 6 existential does not itself satisfy an `AnyObject` generic constraint even though every
/// value it can hold is a class. `as AnyObject` recovers the reference, and identity is
/// compared on that.
struct WeakListeners<Listener> {
  private final class Box {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  private var boxes: [Box] = []

  mutating func add(_ listener: Listener) {
    compact()
    let object = listener as AnyObject
    guard !boxes.contains(where: { $0.value === object }) else { return }
    boxes.append(Box(object))
  }

  mutating func remove(_ listener: Listener) {
    let object = listener as AnyObject
    boxes.removeAll { $0.value == nil || $0.value === object }
  }

  /// A snapshot, so a listener may add or remove listeners while being notified, which
  /// upstream's iteration over a copied array also permits, and which the canvas relies on.
  mutating func current() -> [Listener] {
    compact()
    return boxes.compactMap { $0.value as? Listener }
  }

  private mutating func compact() {
    boxes.removeAll { $0.value == nil }
  }
}
